-- =====================================================================
-- 134_store_subscription_catalog.sql
-- =====================================================================
-- Phase 2B (2 of 3) — server-side product→plan catalogue and additive
-- verified-store-subscription columns on vinetrack_subscriptions.
--
-- What this migration does (all ADDITIVE / backward compatible):
--   A. Widens the vinetrack_subscriptions.billing_provider CHECK to add
--      'google' (Google Play purchases verified via RevenueCat). Existing
--      values ('apple','stripe','manual') are untouched.
--   B. Adds additive columns to public.vinetrack_subscriptions so a
--      verified store subscription carries full provider linkage:
--        platform, environment, external_subscription_id,
--        external_transaction_id, grace_period_end, expired_at,
--        last_provider_event, last_provider_event_at, last_verified_at
--      A partial UNIQUE index on (billing_provider,
--      external_subscription_id) guarantees one live row per provider
--      subscription (renewals update, never duplicate).
--   C. Creates public.billing_product_catalog — the SINGLE server-side
--      store-product → VineTrack plan mapping used by the webhook and the
--      backfill. Unknown products never grant access; inactive products
--      never create NEW access; environment is explicit.
--   D. Seeds the catalogue with the PLACEHOLDER product ids found in the
--      draft webhook, all is_active = false. ⚠️ Phase 2B rule: no mapping
--      is activated until the live RevenueCat product audit confirms the
--      real Apple/Google product ids. Activate by updating
--      external_product_id + is_active = true (service role / SQL editor).
--
-- What does NOT change:
--   * No table renamed/dropped, no historical subscription rows modified.
--   * vinetrack_plans and existing RLS policies untouched.
--   * Old Android/Portal callers keep parsing (columns are additive).
--
-- ROLLBACK:
--   drop table if exists public.billing_product_catalog;
--   alter table public.vinetrack_subscriptions
--     drop column if exists platform,
--     drop column if exists environment,
--     drop column if exists external_subscription_id,
--     drop column if exists external_transaction_id,
--     drop column if exists grace_period_end,
--     drop column if exists expired_at,
--     drop column if exists last_provider_event,
--     drop column if exists last_provider_event_at,
--     drop column if exists last_verified_at;
--   -- then re-add the original billing_provider check ('apple','stripe','manual').
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.vinetrack_subscriptions') is null
     or to_regclass('public.vinetrack_plans') is null then
    raise exception 'SQL 134 precondition failed: billing tables missing';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. Allow 'google' as a billing provider (Play purchases via RevenueCat).
-- ---------------------------------------------------------------------------
do $$
declare
  v_conname text;
begin
  select c.conname into v_conname
  from pg_constraint c
  where c.conrelid = 'public.vinetrack_subscriptions'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%billing_provider%';

  if v_conname is not null then
    execute format('alter table public.vinetrack_subscriptions drop constraint %I', v_conname);
  end if;

  alter table public.vinetrack_subscriptions
    add constraint vinetrack_subscriptions_billing_provider_check
    check (billing_provider in ('apple', 'google', 'stripe', 'manual'));
end$$;

-- ---------------------------------------------------------------------------
-- B. Additive verified-store columns on vinetrack_subscriptions.
-- ---------------------------------------------------------------------------
alter table public.vinetrack_subscriptions
  add column if not exists platform text null
    check (platform is null or platform in ('ios', 'android', 'web'));
alter table public.vinetrack_subscriptions
  add column if not exists environment text null
    check (environment is null or environment in ('production', 'sandbox'));
alter table public.vinetrack_subscriptions
  add column if not exists external_subscription_id text null;   -- original transaction id / purchase-token ref
alter table public.vinetrack_subscriptions
  add column if not exists external_transaction_id text null;    -- latest transaction id
alter table public.vinetrack_subscriptions
  add column if not exists grace_period_end timestamptz null;    -- billing-issue grace (provider-supplied)
alter table public.vinetrack_subscriptions
  add column if not exists expired_at timestamptz null;
alter table public.vinetrack_subscriptions
  add column if not exists last_provider_event text null;        -- e.g. 'RENEWAL'
alter table public.vinetrack_subscriptions
  add column if not exists last_provider_event_at timestamptz null; -- provider event timestamp (out-of-order guard)
alter table public.vinetrack_subscriptions
  add column if not exists last_verified_at timestamptz null;    -- server time the webhook last verified this row

-- One live subscription row per provider subscription: renewals and
-- lifecycle events UPDATE this row; duplicates are structurally impossible.
create unique index if not exists uniq_vinetrack_subscriptions_external
  on public.vinetrack_subscriptions (billing_provider, external_subscription_id)
  where external_subscription_id is not null and deleted_at is null;

-- ---------------------------------------------------------------------------
-- C. billing_product_catalog — single server-side product→plan mapping.
-- ---------------------------------------------------------------------------
create table if not exists public.billing_product_catalog (
  id                  uuid primary key default gen_random_uuid(),
  provider            text not null default 'revenuecat'
    check (provider in ('revenuecat', 'stripe', 'manual')),
  platform            text not null check (platform in ('ios', 'android', 'any')),
  environment         text not null default 'production'
    check (environment in ('production', 'sandbox', 'any')),
  external_product_id text not null,                 -- store product id (App Store / Play)
  plan_code           text not null references public.vinetrack_plans(code) on update cascade,
  entitlement_id      text not null default 'pro',   -- RevenueCat entitlement that must be active
  is_active           boolean not null default false,-- inactive products create no NEW access
  licence_quantity    integer not null default 1 check (licence_quantity >= 0),
  starts_at           timestamptz null,
  ends_at             timestamptz null,
  metadata            jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create unique index if not exists uniq_billing_product_catalog_product
  on public.billing_product_catalog (provider, platform, environment, external_product_id);

create or replace trigger billing_product_catalog_set_updated_at
before update on public.billing_product_catalog
for each row execute function public.set_updated_at();

alter table public.billing_product_catalog enable row level security;

-- Catalogue rows are non-sensitive plan mappings: authenticated users may
-- read (paywall/diagnostic display); NO client write policy exists — only
-- the service role (webhook/backfill/admin SQL) can change mappings.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'billing_product_catalog'
      and policyname = 'billing_product_catalog_select_authenticated'
  ) then
    create policy billing_product_catalog_select_authenticated
      on public.billing_product_catalog
      for select
      to authenticated
      using (true);
  end if;
end$$;

comment on table public.billing_product_catalog is
  'SQL 134: single server-side store-product → VineTrack plan mapping used by the RevenueCat webhook and backfill. Unknown products never grant access; is_active=false products create no new access; environment is explicit. Clients cannot write.';

-- ---------------------------------------------------------------------------
-- D. Seed PLACEHOLDER mappings (all inactive until the live RevenueCat
--    product audit confirms real product ids — Phase 2B §10 rule).
-- ---------------------------------------------------------------------------
insert into public.billing_product_catalog
  (provider, platform, environment, external_product_id, plan_code, entitlement_id, is_active, metadata)
values
  ('revenuecat', 'ios',     'production', 'com.vinetrack.solo.yearly',    'solo',           'pro', false,
   '{"note":"PLACEHOLDER from draft webhook — replace with the real App Store product id from the RevenueCat dashboard audit, then set is_active=true"}'::jsonb),
  ('revenuecat', 'ios',     'production', 'com.vinetrack.legacy.monthly', 'legacy_monthly', 'pro', false,
   '{"note":"PLACEHOLDER — confirm real legacy monthly App Store product id before activating"}'::jsonb),
  ('revenuecat', 'ios',     'production', 'com.vinetrack.legacy.yearly',  'legacy_yearly',  'pro', false,
   '{"note":"PLACEHOLDER — confirm real legacy yearly App Store product id before activating"}'::jsonb),
  ('revenuecat', 'android', 'production', 'vinetrack_solo_yearly',        'solo',           'pro', false,
   '{"note":"PLACEHOLDER — replace with the real Google Play product id (subscription:basePlan) before activating"}'::jsonb)
on conflict (provider, platform, environment, external_product_id) do nothing;

commit;
