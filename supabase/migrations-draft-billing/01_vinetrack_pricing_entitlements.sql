-- =====================================================================
-- 01_vinetrack_pricing_entitlements.sql   (DRAFT — billing/entitlements)
-- =====================================================================
-- VineTrack July 2026 pricing & billing foundation.
--
-- ⚠️  DRAFT ONLY. This file lives in supabase/migrations-draft-billing/,
--     NOT in sql/. It is intentionally kept out of the numbered migration
--     stream so it does not run automatically and does NOT change any
--     existing app/portal access behaviour. Nothing here is read by the
--     current iOS app or Portal yet. Existing entitlement checks (legacy
--     RevenueCat in BackendV2Subscription) keep working untouched.
--
--     The new tables/RPC become "live" only once the app and portal are
--     updated to call public.get_my_vinetrack_access(). Until then the
--     tables sit empty/seeded and have no effect.
--
-- Plans being modelled:
--   * Legacy monthly / yearly  — RevenueCat (Apple). Available until
--     2026-06-30. Receipts stay with Apple.
--   * Solo   — from 2026-07-01, Apple/RevenueCat, 3-month free trial,
--     1 user licence, basic portal access. Receipts stay with Apple.
--   * Team   — from 2026-07-01, Stripe, $799/year ex GST, includes 3 user
--     licences, additional users $99/year ex GST. Invoices via Stripe,
--     displayed in the portal.
--   * Enterprise — from 2026-07-01, manual/Stripe, from $1,499/year ex GST,
--     custom limits. Invoices via Stripe/manual, displayed in the portal.
--
-- Access model:
--   * Licence per USER (not per physical device).
--   * iOS should eventually check Supabase Team/Enterprise access first,
--     then fall back to RevenueCat Solo access.
--   * Portal access is active while the owner/business has an active
--     subscription or trial.
--
-- Reuses helpers from sql/001 + sql/062:
--   public.set_updated_at()        -- trigger fn
--   public.is_system_admin()       -- platform admin gate
--   public.is_vineyard_member(uuid)
--   public.has_vineyard_role(uuid, text[])
--
-- Money is stored in integer minor units (cents) + ISO currency to avoid
-- float drift. All listed prices are ex-GST; tax handling is recorded via
-- tax_mode and computed at invoice time by the billing provider (Stripe).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------------
-- A. public.vinetrack_plans — plan catalogue
-- ---------------------------------------------------------------------------
-- One row per sellable plan/tier. `code` is the stable machine key used by
-- the app/portal; `id` is a uuid for FK stability. Availability windows let
-- legacy plans expire (available_until) and new plans switch on
-- (available_from) without deleting history.
create table if not exists public.vinetrack_plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                       -- 'legacy_monthly','legacy_yearly','solo','team','enterprise'
  name text not null,
  description text null,
  tier text not null check (tier in ('legacy', 'solo', 'team', 'enterprise')),
  billing_provider text not null check (billing_provider in ('apple', 'stripe', 'manual')),
  billing_cycle text not null check (billing_cycle in ('monthly', 'yearly', 'custom')),
  -- Pricing (ex GST). base_price_cents is the recurring price; for Enterprise
  -- this is the "from" floor. additional_user_price_cents is per extra licence.
  currency text not null default 'AUD',
  tax_mode text not null default 'ex_gst' check (tax_mode in ('ex_gst', 'inc_gst', 'none')),
  base_price_cents integer null check (base_price_cents is null or base_price_cents >= 0),
  is_price_from boolean not null default false,     -- true => "from $X" (Enterprise)
  additional_user_price_cents integer null check (additional_user_price_cents is null or additional_user_price_cents >= 0),
  -- Entitlements
  included_user_licences integer null check (included_user_licences is null or included_user_licences >= 0),
  max_user_licences integer null,                   -- null => unlimited / custom
  trial_days integer not null default 0 check (trial_days >= 0),
  portal_access_level text not null default 'none'
    check (portal_access_level in ('none', 'basic', 'full', 'custom')),
  -- Availability window
  available_from timestamptz null,
  available_until timestamptz null,
  is_active boolean not null default true,
  -- Provider product mapping (RevenueCat product/entitlement, Stripe price).
  apple_product_ids text[] null,
  revenuecat_entitlement text null,
  stripe_price_id text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_vinetrack_plans_tier on public.vinetrack_plans (tier);
create index if not exists idx_vinetrack_plans_active on public.vinetrack_plans (is_active);

create or replace trigger vinetrack_plans_set_updated_at
before update on public.vinetrack_plans
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- B. public.vinetrack_subscriptions — one per owner/business
-- ---------------------------------------------------------------------------
-- A subscription belongs to an owner (account holder). It optionally points
-- at a "primary" vineyard for convenience, but access is licence-per-user so
-- the subscription is the billing anchor, not the vineyard.
create table if not exists public.vinetrack_subscriptions (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  primary_vineyard_id uuid null references public.vineyards(id) on delete set null,
  plan_id uuid not null references public.vinetrack_plans(id) on delete restrict,
  billing_provider text not null check (billing_provider in ('apple', 'stripe', 'manual')),
  status text not null default 'trialing'
    check (status in ('trialing', 'active', 'past_due', 'canceled', 'expired', 'paused', 'manual')),
  -- Trial / period windows.
  trial_start timestamptz null,
  trial_end timestamptz null,
  current_period_start timestamptz null,
  current_period_end timestamptz null,
  cancel_at_period_end boolean not null default false,
  started_at timestamptz null,
  canceled_at timestamptz null,
  -- Seats: how many licences this subscription is paying for.
  seats_included integer not null default 1 check (seats_included >= 0),
  seats_purchased integer not null default 0 check (seats_purchased >= 0),
  -- Provider linkage.
  revenuecat_app_user_id text null,
  revenuecat_entitlement text null,
  stripe_customer_id text null,
  stripe_subscription_id text null,
  notes text null,
  metadata jsonb not null default '{}'::jsonb,
  -- Standard sync envelope.
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

create index if not exists idx_vinetrack_subscriptions_owner on public.vinetrack_subscriptions (owner_user_id);
create index if not exists idx_vinetrack_subscriptions_plan on public.vinetrack_subscriptions (plan_id);
create index if not exists idx_vinetrack_subscriptions_status on public.vinetrack_subscriptions (status);
create index if not exists idx_vinetrack_subscriptions_vineyard on public.vinetrack_subscriptions (primary_vineyard_id);
create index if not exists idx_vinetrack_subscriptions_stripe_sub on public.vinetrack_subscriptions (stripe_subscription_id);
create index if not exists idx_vinetrack_subscriptions_rc_app_user on public.vinetrack_subscriptions (revenuecat_app_user_id);
create index if not exists idx_vinetrack_subscriptions_deleted_at on public.vinetrack_subscriptions (deleted_at);

create or replace trigger vinetrack_subscriptions_set_updated_at
before update on public.vinetrack_subscriptions
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- C. public.vinetrack_user_licences — per-user licence assignment
-- ---------------------------------------------------------------------------
-- Licence per user. A subscription grants N seats; each active row consumes
-- one seat for a specific user. A user may be assigned to an optional vineyard
-- context but the licence travels with the user, not the device.
create table if not exists public.vinetrack_user_licences (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.vinetrack_subscriptions(id) on delete cascade,
  user_id uuid null references auth.users(id) on delete set null,
  -- email lets an owner pre-assign a seat before the invitee has an account.
  invited_email text null,
  vineyard_id uuid null references public.vineyards(id) on delete set null,
  status text not null default 'active' check (status in ('active', 'revoked', 'pending')),
  assigned_at timestamptz not null default now(),
  revoked_at timestamptz null,
  assigned_by uuid references auth.users(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One active licence per (subscription, user). Revoked/pending rows excluded.
create unique index if not exists uniq_vinetrack_user_licences_active_user
  on public.vinetrack_user_licences (subscription_id, user_id)
  where status = 'active' and user_id is not null;

create index if not exists idx_vinetrack_user_licences_subscription on public.vinetrack_user_licences (subscription_id);
create index if not exists idx_vinetrack_user_licences_user on public.vinetrack_user_licences (user_id);
create index if not exists idx_vinetrack_user_licences_status on public.vinetrack_user_licences (status);
create index if not exists idx_vinetrack_user_licences_email_lower on public.vinetrack_user_licences (lower(invited_email));

create or replace trigger vinetrack_user_licences_set_updated_at
before update on public.vinetrack_user_licences
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- D. public.vinetrack_invoice_records — Stripe/manual invoices (Team/Ent)
-- ---------------------------------------------------------------------------
-- Solo receipts stay with Apple and are NOT recorded here. This table holds
-- Stripe (and manual Enterprise) invoices to display in the portal.
create table if not exists public.vinetrack_invoice_records (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid null references public.vinetrack_subscriptions(id) on delete set null,
  owner_user_id uuid null references auth.users(id) on delete set null,
  provider text not null default 'stripe' check (provider in ('stripe', 'manual')),
  external_invoice_id text null,                   -- Stripe invoice id
  invoice_number text null,
  status text not null default 'open'
    check (status in ('draft', 'open', 'paid', 'void', 'uncollectible', 'refunded')),
  currency text not null default 'AUD',
  subtotal_cents integer null check (subtotal_cents is null or subtotal_cents >= 0),
  tax_cents integer null check (tax_cents is null or tax_cents >= 0),
  total_cents integer null check (total_cents is null or total_cents >= 0),
  amount_paid_cents integer null check (amount_paid_cents is null or amount_paid_cents >= 0),
  period_start timestamptz null,
  period_end timestamptz null,
  issued_at timestamptz null,
  due_at timestamptz null,
  paid_at timestamptz null,
  hosted_invoice_url text null,
  invoice_pdf_url text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uniq_vinetrack_invoice_external
  on public.vinetrack_invoice_records (provider, external_invoice_id)
  where external_invoice_id is not null;
create index if not exists idx_vinetrack_invoice_subscription on public.vinetrack_invoice_records (subscription_id);
create index if not exists idx_vinetrack_invoice_owner on public.vinetrack_invoice_records (owner_user_id);
create index if not exists idx_vinetrack_invoice_status on public.vinetrack_invoice_records (status);
create index if not exists idx_vinetrack_invoice_issued_at on public.vinetrack_invoice_records (issued_at desc);

create or replace trigger vinetrack_invoice_records_set_updated_at
before update on public.vinetrack_invoice_records
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- E. public.vinetrack_billing_events — append-only audit / webhook log
-- ---------------------------------------------------------------------------
-- Raw billing events from RevenueCat / Stripe webhooks plus manual admin
-- actions. Append-only; never updated. Useful for reconciliation and debugging.
create table if not exists public.vinetrack_billing_events (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid null references public.vinetrack_subscriptions(id) on delete set null,
  owner_user_id uuid null references auth.users(id) on delete set null,
  provider text not null check (provider in ('apple', 'revenuecat', 'stripe', 'manual', 'system')),
  event_type text not null,                        -- e.g. 'INITIAL_PURCHASE','invoice.paid','seat_assigned'
  external_event_id text null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index if not exists uniq_vinetrack_billing_events_external
  on public.vinetrack_billing_events (provider, external_event_id)
  where external_event_id is not null;
create index if not exists idx_vinetrack_billing_events_subscription on public.vinetrack_billing_events (subscription_id);
create index if not exists idx_vinetrack_billing_events_owner on public.vinetrack_billing_events (owner_user_id);
create index if not exists idx_vinetrack_billing_events_type on public.vinetrack_billing_events (event_type);
create index if not exists idx_vinetrack_billing_events_created_at on public.vinetrack_billing_events (created_at desc);

-- ---------------------------------------------------------------------------
-- F. RLS
-- ---------------------------------------------------------------------------
-- Read-friendly, write-locked. Mutating financial rows is reserved for the
-- service role (webhooks/back office), which bypasses RLS. Clients can read
-- their own data so the app/portal can render entitlement + invoices.
alter table public.vinetrack_plans            enable row level security;
alter table public.vinetrack_subscriptions    enable row level security;
alter table public.vinetrack_user_licences    enable row level security;
alter table public.vinetrack_invoice_records  enable row level security;
alter table public.vinetrack_billing_events   enable row level security;

-- Plans: catalogue is readable by any authenticated user. Writes service-role only.
drop policy if exists "vinetrack_plans_select_all" on public.vinetrack_plans;
create policy "vinetrack_plans_select_all"
on public.vinetrack_plans for select
to authenticated
using (true);

-- Subscriptions: owner can read their own; assigned licence holders can read
-- the subscription that licences them; system admins can read all.
drop policy if exists "vinetrack_subscriptions_select_owner_or_licensee" on public.vinetrack_subscriptions;
create policy "vinetrack_subscriptions_select_owner_or_licensee"
on public.vinetrack_subscriptions for select
to authenticated
using (
  owner_user_id = auth.uid()
  or public.is_system_admin()
  or exists (
    select 1 from public.vinetrack_user_licences l
    where l.subscription_id = id
      and l.user_id = auth.uid()
      and l.status = 'active'
  )
);

-- User licences: the assigned user can read their own; the subscription owner
-- can read all licences under their subscription; system admins can read all.
drop policy if exists "vinetrack_user_licences_select_scoped" on public.vinetrack_user_licences;
create policy "vinetrack_user_licences_select_scoped"
on public.vinetrack_user_licences for select
to authenticated
using (
  user_id = auth.uid()
  or public.is_system_admin()
  or exists (
    select 1 from public.vinetrack_subscriptions s
    where s.id = subscription_id
      and s.owner_user_id = auth.uid()
  )
);

-- Invoices: owner of the subscription / invoice can read; system admins read all.
drop policy if exists "vinetrack_invoice_records_select_owner" on public.vinetrack_invoice_records;
create policy "vinetrack_invoice_records_select_owner"
on public.vinetrack_invoice_records for select
to authenticated
using (
  owner_user_id = auth.uid()
  or public.is_system_admin()
  or exists (
    select 1 from public.vinetrack_subscriptions s
    where s.id = subscription_id
      and s.owner_user_id = auth.uid()
  )
);

-- Billing events: system admins only (raw webhook payloads may contain
-- provider-side detail not intended for end users).
drop policy if exists "vinetrack_billing_events_select_admin" on public.vinetrack_billing_events;
create policy "vinetrack_billing_events_select_admin"
on public.vinetrack_billing_events for select
to authenticated
using (public.is_system_admin());

-- NOTE: No INSERT/UPDATE/DELETE policies are defined for any of these tables.
-- With RLS enabled and no permissive write policy, authenticated clients
-- cannot mutate billing data. All writes flow through the service role
-- (Stripe/RevenueCat webhook functions, back-office RPCs) which bypasses RLS.
-- This keeps the draft safe: it cannot be abused before the proper
-- server-side billing endpoints are built.

-- ---------------------------------------------------------------------------
-- G. RPC: public.get_my_vinetrack_access()
-- ---------------------------------------------------------------------------
-- Returns the effective VineTrack access for the CURRENT user (auth.uid()).
-- It resolves Supabase-side Team/Enterprise/legacy entitlement only — Solo
-- receipts live with Apple/RevenueCat, so the client should treat
-- solo_check_required = true as "now verify RevenueCat Solo entitlement".
--
-- Resolution order (mirrors the intended client logic):
--   1. Team/Enterprise: an active/trialing subscription that either the user
--      OWNS, or that grants the user an active licence.
--   2. Legacy: an active/trialing legacy subscription (owned).
--   3. Otherwise no Supabase access => solo_check_required = true so the app
--      falls back to RevenueCat Solo.
--
-- Read-only, single row. SECURITY DEFINER so licence/subscription joins work
-- regardless of RLS, but it ONLY ever reports the caller's own access.
create or replace function public.get_my_vinetrack_access()
returns table (
  user_id               uuid,
  has_supabase_access   boolean,
  access_source         text,     -- 'team' | 'enterprise' | 'legacy' | 'none'
  is_owner              boolean,
  subscription_id       uuid,
  plan_code             text,
  plan_tier             text,
  plan_name             text,
  billing_provider      text,     -- 'apple' | 'stripe' | 'manual'
  status                text,
  trial_end             timestamptz,
  current_period_end    timestamptz,
  portal_access         boolean,
  portal_access_level   text,
  can_use_ios_app       boolean,
  can_use_portal        boolean,
  seats_included        integer,
  seats_purchased       integer,
  active_licences       integer,
  vineyard_id           uuid,
  licence_id            uuid,
  solo_check_required   boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  return query
  with candidate as (
    -- Active/trialing subscriptions the user owns OR is licensed under.
    select
      s.id,
      s.owner_user_id,
      (s.owner_user_id = v_uid) as is_owner,
      s.status,
      s.billing_provider,
      s.primary_vineyard_id,
      s.trial_end,
      s.current_period_end,
      s.seats_included,
      s.seats_purchased,
      p.code as plan_code,
      p.tier as plan_tier,
      p.name as plan_name,
      p.portal_access_level,
      -- Count of active licences consumed under this subscription.
      (
        select count(*)::integer
        from public.vinetrack_user_licences cl
        where cl.subscription_id = s.id
          and cl.status = 'active'
      ) as active_licences,
      -- The caller's own active licence under this subscription (if any).
      (
        select ul.id
        from public.vinetrack_user_licences ul
        where ul.subscription_id = s.id
          and ul.user_id = v_uid
          and ul.status = 'active'
        limit 1
      ) as caller_licence_id,
      -- The vineyard the caller's licence is scoped to, else the subscription's
      -- primary vineyard.
      coalesce(
        (
          select ul.vineyard_id
          from public.vinetrack_user_licences ul
          where ul.subscription_id = s.id
            and ul.user_id = v_uid
            and ul.status = 'active'
          limit 1
        ),
        s.primary_vineyard_id
      ) as resolved_vineyard_id,
      -- Ranking: prefer enterprise > team > legacy, owner over licensee.
      case p.tier
        when 'enterprise' then 3
        when 'team' then 2
        when 'legacy' then 1
        else 0
      end as tier_rank
    from public.vinetrack_subscriptions s
    join public.vinetrack_plans p on p.id = s.plan_id
    where s.deleted_at is null
      and s.status in ('trialing', 'active', 'manual')
      and (
        s.owner_user_id = v_uid
        or exists (
          select 1 from public.vinetrack_user_licences l
          where l.subscription_id = s.id
            and l.user_id = v_uid
            and l.status = 'active'
        )
      )
  ),
  best as (
    select * from candidate
    order by tier_rank desc, is_owner desc, current_period_end desc nulls last
    limit 1
  )
  select
    v_uid as user_id,
    (b.id is not null) as has_supabase_access,
    coalesce(b.plan_tier, 'none') as access_source,
    coalesce(b.is_owner, false) as is_owner,
    b.id as subscription_id,
    b.plan_code,
    b.plan_tier,
    b.plan_name,
    b.billing_provider,
    b.status,
    b.trial_end,
    b.current_period_end,
    -- Portal access while the subscription is active/trialing and the plan
    -- grants any portal level beyond 'none'.
    (b.id is not null and coalesce(b.portal_access_level, 'none') <> 'none') as portal_access,
    coalesce(b.portal_access_level, 'none') as portal_access_level,
    -- Capability flags. iOS app access mirrors having a backend entitlement;
    -- portal access mirrors portal_access above.
    (b.id is not null) as can_use_ios_app,
    (b.id is not null and coalesce(b.portal_access_level, 'none') <> 'none') as can_use_portal,
    b.seats_included,
    b.seats_purchased,
    coalesce(b.active_licences, 0) as active_licences,
    b.resolved_vineyard_id as vineyard_id,
    b.caller_licence_id as licence_id,
    -- If no Supabase Team/Enterprise/legacy access was found, the client must
    -- fall back to RevenueCat Solo verification.
    (b.id is null) as solo_check_required
  from (select 1) one
  left join best b on true;
end;
$$;

revoke all on function public.get_my_vinetrack_access() from public;
grant execute on function public.get_my_vinetrack_access() to authenticated;

-- ---------------------------------------------------------------------------
-- H. Seed the plan catalogue
-- ---------------------------------------------------------------------------
-- Idempotent upsert keyed on `code`. Prices in cents, ex GST, AUD.
-- Legacy plans expire 2026-06-30 23:59:59 (UTC stored). New plans switch on
-- 2026-07-01. Adjust apple_product_ids / stripe_price_id when the real
-- product/price identifiers exist.
insert into public.vinetrack_plans
  (code, name, description, tier, billing_provider, billing_cycle, currency, tax_mode,
   base_price_cents, is_price_from, additional_user_price_cents,
   included_user_licences, max_user_licences, trial_days, portal_access_level,
   available_from, available_until, is_active)
values
  ('legacy_monthly', 'Legacy Monthly', 'Legacy monthly plan (RevenueCat/Apple). Available until 30 June 2026.',
   'legacy', 'apple', 'monthly', 'AUD', 'inc_gst',
   null, false, null,
   1, 1, 0, 'basic',
   null, '2026-06-30T23:59:59Z', true),

  ('legacy_yearly', 'Legacy Yearly', 'Legacy yearly plan (RevenueCat/Apple). Available until 30 June 2026.',
   'legacy', 'apple', 'yearly', 'AUD', 'inc_gst',
   null, false, null,
   1, 1, 0, 'basic',
   null, '2026-06-30T23:59:59Z', true),

  ('solo', 'Solo', 'Solo plan (Apple/RevenueCat). 3-month free trial, 1 user licence, basic portal access. From 1 July 2026. Receipts stay with Apple.',
   'solo', 'apple', 'yearly', 'AUD', 'inc_gst',
   null, false, null,
   1, 1, 90, 'basic',
   '2026-07-01T00:00:00Z', null, true),

  ('team', 'Team', 'Team plan (Stripe). $799/year ex GST, includes 3 user licences, additional users $99/year ex GST. From 1 July 2026.',
   'team', 'stripe', 'yearly', 'AUD', 'ex_gst',
   79900, false, 9900,
   3, null, 0, 'full',
   '2026-07-01T00:00:00Z', null, true),

  ('enterprise', 'Enterprise', 'Enterprise plan (manual/Stripe). From $1,499/year ex GST, custom limits. From 1 July 2026.',
   'enterprise', 'stripe', 'custom', 'AUD', 'ex_gst',
   149900, true, null,
   null, null, 0, 'custom',
   '2026-07-01T00:00:00Z', null, true)
on conflict (code) do update set
  name = excluded.name,
  description = excluded.description,
  tier = excluded.tier,
  billing_provider = excluded.billing_provider,
  billing_cycle = excluded.billing_cycle,
  currency = excluded.currency,
  tax_mode = excluded.tax_mode,
  base_price_cents = excluded.base_price_cents,
  is_price_from = excluded.is_price_from,
  additional_user_price_cents = excluded.additional_user_price_cents,
  included_user_licences = excluded.included_user_licences,
  max_user_licences = excluded.max_user_licences,
  trial_days = excluded.trial_days,
  portal_access_level = excluded.portal_access_level,
  available_from = excluded.available_from,
  available_until = excluded.available_until,
  is_active = excluded.is_active,
  updated_at = now();

commit;
