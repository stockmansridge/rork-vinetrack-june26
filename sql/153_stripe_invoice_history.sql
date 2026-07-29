-- =====================================================================
-- 153_stripe_invoice_history.sql — Phase 2E (2 of 2)
-- Stripe invoice history: hardened storage + Owner-only history RPC.
-- =====================================================================
-- Context
--   The base billing schema already has public.vinetrack_invoice_records
--   (Stripe/manual invoice metadata in integer cents). Nothing populates
--   it yet — this phase adds the stripe-webhook Edge Function that upserts
--   invoices by Stripe invoice ID, and this migration:
--
--   A. Adds additive linkage/lifecycle columns (vineyard, Stripe customer/
--      subscription refs, amount_due, voided/refunded timestamps,
--      last_synced_at, metadata_safe).
--   B. REMOVES the customer-facing direct-read RLS policy. Customer access
--      now flows ONLY through get_my_vineyard_billing_history() — the
--      table itself is readable by System Admins alone. Stripe hosted /
--      PDF URLs are never returned to the browser; fresh links are minted
--      on demand by the get-stripe-invoice-link Edge Function.
--   C. Creates public.get_my_vineyard_billing_history(uuid, int, int).
--
-- Money: INTEGER MINOR UNITS (cents), exactly as Stripe reports them.
--
-- Rollback (dev only):
--   drop function if exists public.get_my_vineyard_billing_history(uuid, integer, integer);
--   -- additive columns can stay; to restore direct owner reads re-create
--   -- policy "vinetrack_invoice_records_select_owner" from
--   -- supabase/migrations-draft-billing/01_vinetrack_pricing_entitlements.sql
-- =====================================================================

-- ---------------------------------------------------------------------------
-- A. Additive columns + indexes.
-- ---------------------------------------------------------------------------
alter table public.vinetrack_invoice_records
  add column if not exists vineyard_id uuid null references public.vineyards(id) on delete set null;
alter table public.vinetrack_invoice_records
  add column if not exists external_customer_id text null;      -- Stripe customer id (server-side only)
alter table public.vinetrack_invoice_records
  add column if not exists external_subscription_id text null;  -- Stripe subscription id (server-side only)
alter table public.vinetrack_invoice_records
  add column if not exists description text null;               -- safe display line
alter table public.vinetrack_invoice_records
  add column if not exists amount_due_cents integer null
    check (amount_due_cents is null or amount_due_cents >= 0);
alter table public.vinetrack_invoice_records
  add column if not exists voided_at timestamptz null;
alter table public.vinetrack_invoice_records
  add column if not exists refunded_at timestamptz null;
alter table public.vinetrack_invoice_records
  add column if not exists last_synced_at timestamptz null;
alter table public.vinetrack_invoice_records
  add column if not exists metadata_safe jsonb not null default '{}'::jsonb;

create index if not exists idx_vinetrack_invoice_vineyard
  on public.vinetrack_invoice_records (vineyard_id, issued_at desc);
create index if not exists idx_vinetrack_invoice_external_customer
  on public.vinetrack_invoice_records (external_customer_id)
  where external_customer_id is not null;

comment on column public.vinetrack_invoice_records.metadata_safe is
  'Phase 2E: sanitised display metadata only (e.g. refund/credit-note summaries in cents). NEVER receipts, tokens, signatures or raw webhook payloads.';

-- ---------------------------------------------------------------------------
-- B. RLS hardening — no customer-facing direct table reads.
-- ---------------------------------------------------------------------------
-- The draft-billing policy let subscription owners select rows directly,
-- which would expose hosted_invoice_url / invoice_pdf_url / external ids to
-- the browser. Customer reads now go through the RPC below (sanitised
-- fields only). System Admins keep direct read for support.
drop policy if exists "vinetrack_invoice_records_select_owner" on public.vinetrack_invoice_records;
drop policy if exists "vinetrack_invoice_records_select_admin" on public.vinetrack_invoice_records;
create policy "vinetrack_invoice_records_select_admin"
on public.vinetrack_invoice_records for select
to authenticated
using (public.is_system_admin());

-- (No INSERT/UPDATE/DELETE policies: with RLS enabled, only the service
-- role — the stripe-webhook Edge Function — can write invoice rows.)

-- ---------------------------------------------------------------------------
-- C. get_my_vineyard_billing_history — Owner-only, paginated, sanitised.
-- ---------------------------------------------------------------------------
-- Error messages match SQL 152: authentication_required / vineyard_not_found
-- / owner_required / no_billing_relationship /
-- billing_managed_by_another_owner.
--
-- Invoices remain visible after cancellation (history is never deleted).
-- can_view_invoice / can_download_invoice mark rows the
-- get-stripe-invoice-link Edge Function can mint fresh URLs for.
drop function if exists public.get_my_vineyard_billing_history(uuid, integer, integer);

create or replace function public.get_my_vineyard_billing_history(
  p_vineyard_id uuid,
  p_limit       integer default 50,
  p_offset      integer default 0
)
returns table (
  record_id            uuid,
  record_type          text,        -- 'invoice'
  provider             text,        -- 'stripe' | 'manual'
  purchase_platform    text,        -- 'web' for Stripe
  product_id           text,        -- plan code (safe display), not raw store id
  plan_code            text,
  description          text,
  invoice_id           text,        -- Stripe invoice id (needed to request a link)
  invoice_number       text,
  invoice_status       text,
  currency             text,
  subtotal             integer,     -- minor units (cents)
  tax                  integer,
  total                integer,
  amount_paid          integer,
  amount_due           integer,
  period_start         timestamptz,
  period_end           timestamptz,
  created_at           timestamptz,
  paid_at              timestamptz,
  voided_at            timestamptz,
  refunded_at          timestamptz,
  subscription_status  text,
  can_view_invoice     boolean,
  can_download_invoice boolean,
  redacted_reference   text,
  total_count          bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_sub      record;
  v_limit    integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset   integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_uid is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.vineyards v
    where v.id = p_vineyard_id and v.deleted_at is null
  ) then
    raise exception 'vineyard_not_found' using errcode = 'P0002';
  end if;

  if not public._is_active_vineyard_owner(v_uid, p_vineyard_id) then
    raise exception 'owner_required' using errcode = '42501';
  end if;

  select s.id, s.owner_user_id, s.status as sub_status,
         s.stripe_customer_id, s.billing_provider,
         p.code as plan_code
  into v_sub
  from public.vinetrack_subscriptions s
  left join public.vinetrack_plans p on p.id = s.plan_id
  where s.id = public._vineyard_billing_subscription_id(p_vineyard_id);

  if v_sub.id is null then
    raise exception 'no_billing_relationship' using errcode = 'P0002';
  end if;

  -- Billing authority: only the subscription's billing owner may see money.
  if v_sub.owner_user_id is distinct from v_uid then
    raise exception 'billing_managed_by_another_owner' using errcode = '42501';
  end if;

  return query
  with linked as (
    select i.*
    from public.vinetrack_invoice_records i
    where
      -- Invoice must belong to THIS vineyard's billing account:
      i.subscription_id = v_sub.id
      or i.vineyard_id = p_vineyard_id
      or (v_sub.stripe_customer_id is not null
          and i.external_customer_id = v_sub.stripe_customer_id)
  ),
  counted as (select count(*)::bigint as n from linked)
  select
    i.id                                   as record_id,
    'invoice'::text                        as record_type,
    i.provider                             as provider,
    case when i.provider = 'stripe' then 'web' else null end as purchase_platform,
    v_sub.plan_code                        as product_id,
    v_sub.plan_code                        as plan_code,
    coalesce(i.description,
             case when i.invoice_number is not null
                  then 'Invoice ' || i.invoice_number
                  else 'Subscription invoice' end) as description,
    i.external_invoice_id                  as invoice_id,
    i.invoice_number                       as invoice_number,
    i.status                               as invoice_status,
    i.currency                             as currency,
    i.subtotal_cents                       as subtotal,
    i.tax_cents                            as tax,
    i.total_cents                          as total,
    i.amount_paid_cents                    as amount_paid,
    i.amount_due_cents                     as amount_due,
    i.period_start                         as period_start,
    i.period_end                           as period_end,
    coalesce(i.issued_at, i.created_at)    as created_at,
    i.paid_at                              as paid_at,
    i.voided_at                            as voided_at,
    i.refunded_at                          as refunded_at,
    v_sub.sub_status                       as subscription_status,
    (i.provider = 'stripe' and i.external_invoice_id is not null) as can_view_invoice,
    (i.provider = 'stripe' and i.external_invoice_id is not null) as can_download_invoice,
    case
      when i.external_invoice_id is null then null
      when length(i.external_invoice_id) <= 8 then '…'
      else left(i.external_invoice_id, 4) || '…' || right(i.external_invoice_id, 4)
    end                                    as redacted_reference,
    (select n from counted)                as total_count
  from linked i
  order by coalesce(i.issued_at, i.created_at) desc, i.id desc
  limit v_limit offset v_offset;
end;
$$;

revoke all on function public.get_my_vineyard_billing_history(uuid, integer, integer) from public;
grant execute on function public.get_my_vineyard_billing_history(uuid, integer, integer) to authenticated;

comment on function public.get_my_vineyard_billing_history(uuid, integer, integer) is
  'Phase 2E: paginated, sanitised Stripe invoice history for the vineyard''s billing owner. Amounts are INTEGER MINOR UNITS (cents). Never returns hosted/PDF URLs — links are minted on demand by get-stripe-invoice-link.';

-- ---------------------------------------------------------------------------
-- D. Self-check.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cols integer;
begin
  select count(*) into v_cols
  from information_schema.columns
  where table_schema = 'public'
    and table_name   = 'vinetrack_invoice_records'
    and column_name in ('vineyard_id','external_customer_id','external_subscription_id',
                        'description','amount_due_cents','voided_at','refunded_at',
                        'last_synced_at','metadata_safe');
  if v_cols <> 9 then
    raise exception 'SQL 153 self-check failed — expected 9 additive invoice columns, found %', v_cols;
  end if;
  if to_regprocedure('public.get_my_vineyard_billing_history(uuid,integer,integer)') is null then
    raise exception 'SQL 153 self-check failed — history RPC missing';
  end if;
  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'vinetrack_invoice_records'
      and policyname = 'vinetrack_invoice_records_select_owner'
  ) then
    raise exception 'SQL 153 self-check failed — direct owner-read policy still present';
  end if;
  raise notice 'SQL 153 stripe invoice history: applied OK';
end$$;
