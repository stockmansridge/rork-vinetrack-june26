-- =====================================================================
-- 096_internal_unlimited_licensing.sql
-- =====================================================================
-- Internal / manual "unlimited licences" access for VineTrack.
--
-- Purpose:
--   Some vineyards/accounts (Stockman Admin, selected power testers) need
--   unlimited access until manually revoked. This is granted BY HAND from
--   the System Admin area and does NOT involve Stripe, Apple, or RevenueCat.
--
-- Design goals:
--   * Purely additive & backwards compatible. Existing subscriptions,
--     licences, plans, and get_my_vinetrack_access() callers keep working.
--   * Reuses the billing tables from
--     supabase/migrations-draft-billing/01_vinetrack_pricing_entitlements.sql
--     (public.vinetrack_plans / vinetrack_subscriptions / vinetrack_user_licences).
--   * All admin write paths are gated by public.is_system_admin()
--     (sql/062_system_admin_and_feature_flags.sql) and run SECURITY DEFINER.
--
-- iOS is the source of truth for the data contract; the portal/Lovable
-- mirrors the columns + RPCs added here.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------------
-- A. Additive columns on public.vinetrack_subscriptions
-- ---------------------------------------------------------------------------
-- All optional/defaulted so existing rows and existing INSERTs are unaffected.
alter table public.vinetrack_subscriptions
  add column if not exists unlimited_licences boolean not null default false;

alter table public.vinetrack_subscriptions
  add column if not exists manual_grant_reason text null;

alter table public.vinetrack_subscriptions
  add column if not exists manual_grant_expires_at timestamptz null;

alter table public.vinetrack_subscriptions
  add column if not exists manual_grant_revoked_at timestamptz null;

alter table public.vinetrack_subscriptions
  add column if not exists manual_grant_revoked_by uuid null references auth.users(id);

create index if not exists idx_vinetrack_subscriptions_unlimited
  on public.vinetrack_subscriptions (unlimited_licences)
  where unlimited_licences = true;

-- ---------------------------------------------------------------------------
-- B. Allow an 'internal' plan tier
-- ---------------------------------------------------------------------------
-- The plan catalogue tier check originally only allows
-- ('legacy','solo','team','enterprise'). Add 'internal' so the manual
-- unlimited plan has its own tier without masquerading as enterprise.
do $$
begin
  if exists (
    select 1 from pg_constraint
    where conname = 'vinetrack_plans_tier_check'
      and conrelid = 'public.vinetrack_plans'::regclass
  ) then
    alter table public.vinetrack_plans drop constraint vinetrack_plans_tier_check;
  end if;

  alter table public.vinetrack_plans
    add constraint vinetrack_plans_tier_check
    check (tier in ('legacy', 'solo', 'team', 'enterprise', 'internal'));
end$$;

-- ---------------------------------------------------------------------------
-- C. Seed the Internal Unlimited plan
-- ---------------------------------------------------------------------------
-- Not customer-facing pricing. billing_provider = manual, custom cycle,
-- no price, no seat caps, full portal access.
insert into public.vinetrack_plans
  (code, name, description, tier, billing_provider, billing_cycle, currency, tax_mode,
   base_price_cents, is_price_from, additional_user_price_cents,
   included_user_licences, max_user_licences, trial_days, portal_access_level,
   available_from, available_until, is_active)
values
  ('internal_unlimited', 'Internal Unlimited',
   'Manually granted unlimited access (internal / power testers). Not customer-facing pricing. No Stripe/Apple/RevenueCat.',
   'internal', 'manual', 'custom', 'AUD', 'none',
   null, false, null,
   null, null, 0, 'full',
   null, null, true)
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
  is_active = excluded.is_active,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- D. get_my_vinetrack_access() — add unlimited fields + ranking + validity
-- ---------------------------------------------------------------------------
-- The return shape grows by three columns, so we DROP + recreate (CREATE OR
-- REPLACE cannot change the OUT signature).
drop function if exists public.get_my_vinetrack_access();

create or replace function public.get_my_vinetrack_access()
returns table (
  user_id                 uuid,
  has_supabase_access     boolean,
  access_source           text,     -- 'enterprise' | 'internal' | 'team' | 'legacy' | 'solo' | 'none'
  is_owner                boolean,
  subscription_id         uuid,
  plan_code               text,
  plan_tier               text,
  plan_name               text,
  billing_provider        text,     -- 'apple' | 'stripe' | 'manual'
  status                  text,
  trial_end               timestamptz,
  current_period_end      timestamptz,
  portal_access           boolean,
  portal_access_level     text,
  can_use_ios_app         boolean,
  can_use_portal          boolean,
  seats_included          integer,
  seats_purchased         integer,
  active_licences         integer,
  vineyard_id             uuid,
  licence_id              uuid,
  unlimited_licences      boolean,
  manual_grant_reason     text,
  manual_grant_expires_at timestamptz,
  solo_check_required     boolean
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
      coalesce(s.unlimited_licences, false) as unlimited_licences,
      s.manual_grant_reason,
      s.manual_grant_expires_at,
      p.code as plan_code,
      p.tier as plan_tier,
      p.name as plan_name,
      p.portal_access_level,
      (
        select count(*)::integer
        from public.vinetrack_user_licences cl
        where cl.subscription_id = s.id
          and cl.status = 'active'
      ) as active_licences,
      (
        select ul.id
        from public.vinetrack_user_licences ul
        where ul.subscription_id = s.id
          and ul.user_id = v_uid
          and ul.status = 'active'
        limit 1
      ) as caller_licence_id,
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
      -- Ranking: enterprise > internal_unlimited > team > legacy > solo.
      case
        when p.tier = 'enterprise'        then 5
        when p.code = 'internal_unlimited' then 4
        when p.tier = 'team'              then 3
        when p.tier = 'legacy'            then 2
        when p.tier = 'solo'              then 1
        else 0
      end as tier_rank
    from public.vinetrack_subscriptions s
    join public.vinetrack_plans p on p.id = s.plan_id
    where s.deleted_at is null
      and (
        s.owner_user_id = v_uid
        or exists (
          select 1 from public.vinetrack_user_licences l
          where l.subscription_id = s.id
            and l.user_id = v_uid
            and l.status = 'active'
        )
      )
      and (
        -- Normal entitlement statuses (unchanged) ...
        s.status in ('trialing', 'active', 'manual')
        -- ... plus past_due is acceptable while a manual unlimited grant holds.
        or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
      )
      -- Manual unlimited grants honour their expiry window. Non-unlimited rows
      -- are unaffected (first OR branch is always true for them).
      and (
        coalesce(s.unlimited_licences, false) = false
        or s.manual_grant_expires_at is null
        or s.manual_grant_expires_at > now()
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
    (b.id is not null and coalesce(b.portal_access_level, 'none') <> 'none') as portal_access,
    coalesce(b.portal_access_level, 'none') as portal_access_level,
    (b.id is not null) as can_use_ios_app,
    (b.id is not null and coalesce(b.portal_access_level, 'none') <> 'none') as can_use_portal,
    b.seats_included,
    b.seats_purchased,
    coalesce(b.active_licences, 0) as active_licences,
    b.resolved_vineyard_id as vineyard_id,
    b.caller_licence_id as licence_id,
    coalesce(b.unlimited_licences, false) as unlimited_licences,
    b.manual_grant_reason,
    b.manual_grant_expires_at,
    (b.id is null) as solo_check_required
  from (select 1) one
  left join best b on true;
end;
$$;

revoke all on function public.get_my_vinetrack_access() from public;
grant execute on function public.get_my_vinetrack_access() to authenticated;

-- ---------------------------------------------------------------------------
-- E. Admin RPC: list current manual unlimited grants
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_manual_unlimited_grants()
returns table (
  subscription_id         uuid,
  owner_user_id           uuid,
  owner_email             text,
  owner_full_name         text,
  primary_vineyard_id     uuid,
  vineyard_name           text,
  status                  text,
  unlimited_licences      boolean,
  manual_grant_reason     text,
  manual_grant_expires_at timestamptz,
  manual_grant_revoked_at timestamptz,
  active_licences         integer,
  is_active               boolean,
  created_at              timestamptz,
  updated_at              timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;

  return query
  select
    s.id,
    s.owner_user_id,
    coalesce(pr.email, u.email)::text as owner_email,
    pr.full_name as owner_full_name,
    s.primary_vineyard_id,
    v.name as vineyard_name,
    s.status,
    coalesce(s.unlimited_licences, false),
    s.manual_grant_reason,
    s.manual_grant_expires_at,
    s.manual_grant_revoked_at,
    (
      select count(*)::integer
      from public.vinetrack_user_licences l
      where l.subscription_id = s.id and l.status = 'active'
    ) as active_licences,
    (
      s.deleted_at is null
      and coalesce(s.unlimited_licences, false) = true
      and s.status in ('trialing', 'active', 'manual', 'past_due')
      and (s.manual_grant_expires_at is null or s.manual_grant_expires_at > now())
    ) as is_active,
    s.created_at,
    s.updated_at
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  left join auth.users u on u.id = s.owner_user_id
  left join public.profiles pr on pr.id = s.owner_user_id
  left join public.vineyards v on v.id = s.primary_vineyard_id
  where p.code = 'internal_unlimited'
     or coalesce(s.unlimited_licences, false) = true
  order by (s.deleted_at is null) desc, s.updated_at desc;
end;
$$;

revoke all on function public.admin_list_manual_unlimited_grants() from public;
grant execute on function public.admin_list_manual_unlimited_grants() to authenticated;

-- ---------------------------------------------------------------------------
-- F. Admin RPC: grant unlimited access
-- ---------------------------------------------------------------------------
-- Creates or reactivates an internal_unlimited subscription for the owner and
-- (re)asserts the owner's active licence. Returns the subscription id.
create or replace function public.admin_grant_unlimited_access(
  p_owner_user_id uuid,
  p_vineyard_id   uuid default null,
  p_reason        text default null,
  p_expires_at    timestamptz default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_plan_id uuid;
  v_sub_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_owner_user_id is null then
    raise exception 'owner_required' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users where id = p_owner_user_id) then
    raise exception 'user_not_found' using errcode = '22023';
  end if;

  select id into v_plan_id
  from public.vinetrack_plans
  where code = 'internal_unlimited'
  limit 1;

  if v_plan_id is null then
    raise exception 'internal_unlimited_plan_missing' using errcode = 'P0002';
  end if;

  -- Reuse an existing internal_unlimited subscription for this owner if present
  -- (active or previously revoked), otherwise create a fresh one.
  select id into v_sub_id
  from public.vinetrack_subscriptions
  where owner_user_id = p_owner_user_id
    and plan_id = v_plan_id
  order by (deleted_at is null) desc, created_at desc
  limit 1;

  if v_sub_id is null then
    insert into public.vinetrack_subscriptions
      (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
       seats_included, seats_purchased, unlimited_licences,
       manual_grant_reason, manual_grant_expires_at,
       manual_grant_revoked_at, manual_grant_revoked_by,
       started_at, created_by, updated_by)
    values
      (p_owner_user_id, p_vineyard_id, v_plan_id, 'manual', 'manual',
       0, 0, true,
       p_reason, p_expires_at,
       null, null,
       now(), v_admin, v_admin)
    returning id into v_sub_id;
  else
    update public.vinetrack_subscriptions
    set primary_vineyard_id     = coalesce(p_vineyard_id, primary_vineyard_id),
        billing_provider        = 'manual',
        status                  = 'manual',
        seats_included          = 0,
        seats_purchased         = 0,
        unlimited_licences      = true,
        manual_grant_reason     = p_reason,
        manual_grant_expires_at = p_expires_at,
        manual_grant_revoked_at = null,
        manual_grant_revoked_by = null,
        deleted_at              = null,
        canceled_at             = null,
        started_at              = coalesce(started_at, now()),
        updated_by              = v_admin,
        updated_at              = now()
    where id = v_sub_id;
  end if;

  -- (Re)assert the owner's active licence under this subscription.
  if exists (
    select 1 from public.vinetrack_user_licences
    where subscription_id = v_sub_id and user_id = p_owner_user_id
  ) then
    update public.vinetrack_user_licences
    set status      = 'active',
        revoked_at  = null,
        vineyard_id = coalesce(p_vineyard_id, vineyard_id),
        assigned_by = v_admin,
        updated_at  = now()
    where subscription_id = v_sub_id and user_id = p_owner_user_id;
  else
    insert into public.vinetrack_user_licences
      (subscription_id, user_id, vineyard_id, status, assigned_by)
    values
      (v_sub_id, p_owner_user_id, p_vineyard_id, 'active', v_admin);
  end if;

  -- Audit trail.
  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (v_sub_id, p_owner_user_id, 'manual', 'manual_unlimited_granted',
     jsonb_build_object(
       'granted_by', v_admin,
       'reason', p_reason,
       'expires_at', p_expires_at,
       'vineyard_id', p_vineyard_id
     ));

  return v_sub_id;
end;
$$;

revoke all on function public.admin_grant_unlimited_access(uuid, uuid, text, timestamptz) from public;
grant execute on function public.admin_grant_unlimited_access(uuid, uuid, text, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- G. Admin RPC: revoke unlimited access
-- ---------------------------------------------------------------------------
create or replace function public.admin_revoke_unlimited_access(
  p_subscription_id uuid,
  p_revoke_licences boolean default true
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_owner uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_subscription_id is null then
    raise exception 'subscription_required' using errcode = '22023';
  end if;

  select owner_user_id into v_owner
  from public.vinetrack_subscriptions
  where id = p_subscription_id;

  if v_owner is null then
    raise exception 'subscription_not_found' using errcode = 'P0002';
  end if;

  update public.vinetrack_subscriptions
  set deleted_at              = now(),
      status                  = 'canceled',
      unlimited_licences      = false,
      manual_grant_revoked_at = now(),
      manual_grant_revoked_by = v_admin,
      canceled_at             = now(),
      updated_by              = v_admin,
      updated_at              = now()
  where id = p_subscription_id;

  if coalesce(p_revoke_licences, true) then
    update public.vinetrack_user_licences
    set status     = 'revoked',
        revoked_at = now(),
        updated_at = now()
    where subscription_id = p_subscription_id
      and status = 'active';
  end if;

  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (p_subscription_id, v_owner, 'manual', 'manual_unlimited_revoked',
     jsonb_build_object('revoked_by', v_admin, 'revoked_licences', coalesce(p_revoke_licences, true)));

  return p_subscription_id;
end;
$$;

revoke all on function public.admin_revoke_unlimited_access(uuid, boolean) from public;
grant execute on function public.admin_revoke_unlimited_access(uuid, boolean) to authenticated;

commit;
