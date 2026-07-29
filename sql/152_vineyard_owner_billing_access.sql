-- =====================================================================
-- 152_vineyard_owner_billing_access.sql — Phase 2E (1 of 2)
-- Vineyard Owner portal Billing page: owner-only billing RPCs.
-- =====================================================================
-- Context
--   The portal gets a customer Billing page at /account/billing that is
--   available ONLY to authenticated users holding an ACTIVE Vineyard
--   Owner membership (public.vineyard_members.role = 'owner' — the exact
--   stored value) for the selected vineyard. System Admins do NOT get
--   customer Billing access unless they also hold an Owner membership
--   (admin billing stays in /admin/access-entitlements).
--
--   Membership role and Stripe billing ownership are NOT identical:
--   a vineyard may have several Owner-role members, but exactly one user
--   anchors the money (vinetrack_subscriptions.owner_user_id). Owners who
--   are not the billing owner see safe summary data only — never invoices
--   or the Stripe Customer Portal ('billing_managed_by_another_owner').
--
-- What this migration creates (all additive):
--   A. public._is_active_vineyard_owner(p_user, p_vineyard)   [helper]
--   B. public._vineyard_billing_subscription_id(p_vineyard)   [helper]
--   C. public.get_my_billing_vineyards()
--   D. public.get_my_vineyard_billing_summary(p_vineyard_id)
--   E. public.get_my_vineyard_billing_licences(p_vineyard_id)
--
-- Error message convention (portal maps these verbatim):
--   'authentication_required'            — no auth.uid()
--   'vineyard_not_found'                 — vineyard missing / soft-deleted
--   'owner_required'                     — caller is not an active Owner
--   'no_billing_relationship'            — no subscription for the vineyard
--   'billing_managed_by_another_owner'   — Owner without billing authority
--
-- Money note: all monetary values in this phase are INTEGER MINOR UNITS
-- (cents), matching Stripe and vinetrack_invoice_records *_cents columns.
--
-- Rollback (dev only):
--   drop function if exists public.get_my_vineyard_billing_licences(uuid);
--   drop function if exists public.get_my_vineyard_billing_summary(uuid);
--   drop function if exists public.get_my_billing_vineyards();
--   drop function if exists public._vineyard_billing_subscription_id(uuid);
--   drop function if exists public._is_active_vineyard_owner(uuid, uuid);
-- =====================================================================

-- ---------------------------------------------------------------------------
-- A. _is_active_vineyard_owner — the single Owner-membership check.
-- ---------------------------------------------------------------------------
-- Active membership means: the vineyard exists and is not soft-deleted AND a
-- vineyard_members row exists with role = 'owner'. (vineyard_members has no
-- soft-delete column — revoking a membership deletes the row, which this
-- check honours automatically.)
create or replace function public._is_active_vineyard_owner(
  p_user     uuid,
  p_vineyard uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.vineyard_members m
    join public.vineyards v on v.id = m.vineyard_id
    where m.vineyard_id = p_vineyard
      and m.user_id     = p_user
      and m.role        = 'owner'
      and v.deleted_at is null
  );
$$;

revoke all on function public._is_active_vineyard_owner(uuid, uuid) from public;
grant execute on function public._is_active_vineyard_owner(uuid, uuid) to service_role;

comment on function public._is_active_vineyard_owner(uuid, uuid) is
  'Phase 2E: true when p_user holds an active Owner membership (role=''owner'') for a non-deleted vineyard. Internal helper — called by billing RPCs and Stripe Edge Functions (service role).';

-- ---------------------------------------------------------------------------
-- B. _vineyard_billing_subscription_id — deterministic subscription pick.
-- ---------------------------------------------------------------------------
-- A vineyard's billing subscription is resolved server-side, never trusted
-- from the browser:
--   1. Prefer subscriptions whose primary_vineyard_id is the vineyard.
--   2. Otherwise fall back to subscriptions owned by any Owner-role member
--      of the vineyard (store purchases are user-anchored and may not carry
--      primary_vineyard_id).
--   3. Among candidates prefer live statuses, then the newest row.
create or replace function public._vineyard_billing_subscription_id(
  p_vineyard uuid
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select s.id
  from public.vinetrack_subscriptions s
  where s.deleted_at is null
    and (
      s.primary_vineyard_id = p_vineyard
      or s.owner_user_id in (
        select m.user_id
        from public.vineyard_members m
        where m.vineyard_id = p_vineyard
          and m.role = 'owner'
      )
    )
  order by
    (s.primary_vineyard_id = p_vineyard) desc,
    (s.status in ('active', 'trialing', 'past_due', 'manual')) desc,
    s.created_at desc
  limit 1;
$$;

revoke all on function public._vineyard_billing_subscription_id(uuid) from public;
grant execute on function public._vineyard_billing_subscription_id(uuid) to service_role;

comment on function public._vineyard_billing_subscription_id(uuid) is
  'Phase 2E: deterministic billing subscription for a vineyard (primary_vineyard_id first, then Owner-member-owned; live statuses preferred). Internal helper.';

-- ---------------------------------------------------------------------------
-- C. get_my_billing_vineyards — the portal route guard + vineyard selector.
-- ---------------------------------------------------------------------------
-- Uses the AUTHENTICATED user only (no user-id parameter, ever). Returns one
-- row per non-deleted vineyard where the caller has an Owner membership.
-- Non-Owner callers get ZERO rows (not an error) so the portal can hide the
-- Billing navigation item from a single call.
drop function if exists public.get_my_billing_vineyards();

create or replace function public.get_my_billing_vineyards()
returns table (
  vineyard_id             uuid,
  vineyard_name           text,
  role                    text,
  has_stripe_customer     boolean,
  has_active_subscription boolean,
  plan_code               text,
  subscription_status     text,
  can_manage_billing      boolean
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
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  return query
  select
    v.id                                   as vineyard_id,
    v.name                                 as vineyard_name,
    m.role                                 as role,
    (s.billing_provider = 'stripe'
       and s.stripe_customer_id is not null) as has_stripe_customer,
    (s.id is not null
       and s.status in ('active', 'trialing', 'past_due', 'manual')) as has_active_subscription,
    p.code                                 as plan_code,
    s.status                               as subscription_status,
    (s.id is not null
       and s.owner_user_id = v_uid
       and s.billing_provider = 'stripe'
       and s.stripe_customer_id is not null) as can_manage_billing
  from public.vineyard_members m
  join public.vineyards v on v.id = m.vineyard_id and v.deleted_at is null
  left join public.vinetrack_subscriptions s
    on s.id = public._vineyard_billing_subscription_id(v.id)
  left join public.vinetrack_plans p on p.id = s.plan_id
  where m.user_id = v_uid
    and m.role = 'owner'
  order by v.name asc;
end;
$$;

revoke all on function public.get_my_billing_vineyards() from public;
grant execute on function public.get_my_billing_vineyards() to authenticated;

comment on function public.get_my_billing_vineyards() is
  'Phase 2E: billing-eligible vineyards for the AUTHENTICATED user (Owner memberships only). Zero rows for non-Owners — drives portal Billing nav visibility and the vineyard selector.';

-- ---------------------------------------------------------------------------
-- D. get_my_vineyard_billing_summary — the Current Plan card.
-- ---------------------------------------------------------------------------
-- Verifies active Owner membership server-side on EVERY call. Returns safe
-- display fields only: no Stripe customer IDs, no receipts, no raw provider
-- payloads. Booleans drive the portal (has_stripe_customer,
-- can_manage_billing, can_view_invoices).
drop function if exists public.get_my_vineyard_billing_summary(uuid);

create or replace function public.get_my_vineyard_billing_summary(
  p_vineyard_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_sub  record;
  v_plan record;
  v_trial record;

  v_is_billing_owner boolean := false;
  v_live             boolean := false;
  v_limit            integer;
  v_assigned         integer := 0;
  v_authority_code   text;
  v_access_source    text := 'none';
  v_platform         text;
  v_receipt_by       text;
  v_expires_at       timestamptz;
  v_has_invoices     boolean := false;
  v_owner_name       text;
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

  select s.* into v_sub
  from public.vinetrack_subscriptions s
  where s.id = public._vineyard_billing_subscription_id(p_vineyard_id);

  -- Always assign v_plan (null-row record when there is no subscription) so
  -- the jsonb build below can reference it safely on every path.
  select p.* into v_plan
  from public.vinetrack_plans p
  where p.id = v_sub.plan_id;

  if v_sub.id is not null then
    v_is_billing_owner := (v_sub.owner_user_id = v_uid);
    -- Live = billing status is a live one AND the (grace-extended) period has
    -- not ended. cancel_at_period_end stays live until the period end.
    v_live := v_sub.status in ('active', 'trialing', 'past_due', 'manual')
      and (coalesce(v_sub.grace_period_end, v_sub.current_period_end) is null
           or coalesce(v_sub.grace_period_end, v_sub.current_period_end) > now());

    -- Seats (same server-side calculation as admin_available_licence_pools).
    if coalesce(v_sub.unlimited_licences, false) then
      v_limit := null;
    else
      v_limit := coalesce(v_sub.seats_included, 0) + coalesce(v_sub.seats_purchased, 0);
    end if;

    select count(*)::integer into v_assigned
    from public.vinetrack_user_licences l
    where l.subscription_id = v_sub.id
      and l.status = 'active';

    v_access_source := case
      when v_sub.billing_provider = 'manual'
        then coalesce(v_sub.manual_grant_type, 'manual_grant')
      when v_sub.status = 'trialing' then 'trial'
      else 'subscription'
    end;

    v_platform := coalesce(
      v_sub.platform,
      case v_sub.billing_provider
        when 'apple'  then 'ios'
        when 'google' then 'android'
        when 'stripe' then 'web'
        else null
      end);

    v_receipt_by := case v_sub.billing_provider
      when 'apple'  then 'apple'
      when 'google' then 'google'
      when 'stripe' then 'stripe'
      else null
    end;

    v_expires_at := coalesce(v_sub.grace_period_end, v_sub.current_period_end,
                             v_sub.manual_grant_expires_at, v_sub.trial_end);

    if v_sub.billing_provider = 'stripe' and not v_is_billing_owner then
      v_authority_code := 'billing_managed_by_another_owner';
    end if;

    -- Invoice history existence (base-schema columns only; the invoice RPC
    -- itself lands in SQL 153).
    select exists (
      select 1 from public.vinetrack_invoice_records i
      where i.subscription_id = v_sub.id
         or (i.owner_user_id = v_sub.owner_user_id and i.provider = 'stripe')
    ) into v_has_invoices;

    select coalesce(pr.full_name, pr.email) into v_owner_name
    from public.profiles pr
    where pr.id = v_sub.owner_user_id;
  else
    -- No subscription: surface the Owner's own account trial where present
    -- so the portal can show the trial state honestly.
    select t.* into v_trial
    from public.vinetrack_account_trials t
    where t.user_id = v_uid
      and t.status = 'active'
      and t.trial_ends_at > now();

    if v_trial.user_id is not null then
      v_access_source := 'trial';
      v_expires_at := v_trial.trial_ends_at;
    else
      v_access_source := 'none';
    end if;
    v_authority_code := 'no_billing_relationship';
  end if;

  return jsonb_build_object(
    'vineyard_id', p_vineyard_id,
    'vineyard_name', (select v.name from public.vineyards v where v.id = p_vineyard_id),
    'user_role', 'owner',
    'is_vineyard_owner', true,
    'can_manage_billing',
      (v_sub.id is not null and v_is_billing_owner
       and v_sub.billing_provider = 'stripe'
       and v_sub.stripe_customer_id is not null),
    'can_view_invoices',
      (v_sub.id is not null and v_is_billing_owner
       and v_sub.billing_provider = 'stripe'),
    'billing_authority_code', v_authority_code,
    'billing_owner_user_id', v_sub.owner_user_id,
    'billing_owner_display_name', v_owner_name,
    'effective_plan', coalesce(v_plan.name, case when v_access_source = 'trial' then 'Account trial' else null end),
    'access_source', v_access_source,
    'purchase_platform', v_platform,
    'receipt_managed_by', v_receipt_by,
    'subscription_id', v_sub.id,
    'subscription_status', v_sub.status,
    'provider', v_sub.billing_provider,
    'product_id', v_plan.code,  -- safe display value; raw store/Stripe ids stay server-side
    'plan_code', v_plan.code,
    'current_period_start', v_sub.current_period_start,
    'current_period_end', v_sub.current_period_end,
    'cancel_at_period_end', coalesce(v_sub.cancel_at_period_end, false),
    'cancelled_at', v_sub.canceled_at,
    'expires_at', v_expires_at,
    'licence_limit', v_limit,
    'assigned_licences', v_assigned,
    'available_licences',
      case when v_sub.id is null then null
           when coalesce(v_sub.unlimited_licences, false) then null
           else greatest(v_limit - v_assigned, 0) end,
    'is_unlimited', coalesce(v_sub.unlimited_licences, false),
    'portal_access',
      (v_sub.id is not null and v_live
       and coalesce(v_plan.portal_access_level, 'none') <> 'none')
      or v_access_source = 'trial',
    'can_use_ios_app', v_live or v_access_source = 'trial',
    'can_use_android_app', v_live or v_access_source = 'trial',
    'has_stripe_customer',
      (v_sub.id is not null and v_sub.billing_provider = 'stripe'
       and v_sub.stripe_customer_id is not null),
    'has_invoice_history', v_has_invoices,
    'money_unit', 'minor_units'
  );
end;
$$;

revoke all on function public.get_my_vineyard_billing_summary(uuid) from public;
grant execute on function public.get_my_vineyard_billing_summary(uuid) to authenticated;

comment on function public.get_my_vineyard_billing_summary(uuid) is
  'Phase 2E: Owner-only billing summary for one owned vineyard. Enforces role=''owner'' server-side; billing authority (Stripe actions) requires being the subscription''s owner_user_id. No Stripe customer IDs are returned.';

-- ---------------------------------------------------------------------------
-- E. get_my_vineyard_billing_licences — seat assignments (billing authority).
-- ---------------------------------------------------------------------------
drop function if exists public.get_my_vineyard_billing_licences(uuid);

create or replace function public.get_my_vineyard_billing_licences(
  p_vineyard_id uuid
)
returns table (
  licence_id        uuid,
  user_display_name text,
  user_email        text,
  vineyard_id       uuid,
  vineyard_name     text,
  assigned_at       timestamptz,
  status            text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_sub_id uuid;
  v_owner  uuid;
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

  v_sub_id := public._vineyard_billing_subscription_id(p_vineyard_id);
  if v_sub_id is null then
    raise exception 'no_billing_relationship' using errcode = 'P0002';
  end if;

  select s.owner_user_id into v_owner
  from public.vinetrack_subscriptions s
  where s.id = v_sub_id;

  if v_owner is distinct from v_uid then
    raise exception 'billing_managed_by_another_owner' using errcode = '42501';
  end if;

  return query
  select
    l.id                                        as licence_id,
    coalesce(pr.full_name, pr.email, l.invited_email) as user_display_name,
    coalesce(pr.email, l.invited_email)         as user_email,
    l.vineyard_id                               as vineyard_id,
    vy.name                                     as vineyard_name,
    l.assigned_at                               as assigned_at,
    l.status                                    as status
  from public.vinetrack_user_licences l
  left join public.profiles pr on pr.id = l.user_id
  left join public.vineyards vy on vy.id = l.vineyard_id
  where l.subscription_id = v_sub_id
    and l.status in ('active', 'pending')
  order by (l.status = 'active') desc, l.assigned_at desc;
end;
$$;

revoke all on function public.get_my_vineyard_billing_licences(uuid) from public;
grant execute on function public.get_my_vineyard_billing_licences(uuid) to authenticated;

comment on function public.get_my_vineyard_billing_licences(uuid) is
  'Phase 2E: seat assignments for the vineyard''s billing subscription. Requires active Owner membership AND billing authority (subscription owner_user_id).';

-- ---------------------------------------------------------------------------
-- F. Self-check.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.get_my_billing_vineyards()') is null
     or to_regprocedure('public.get_my_vineyard_billing_summary(uuid)') is null
     or to_regprocedure('public.get_my_vineyard_billing_licences(uuid)') is null
     or to_regprocedure('public._is_active_vineyard_owner(uuid,uuid)') is null
     or to_regprocedure('public._vineyard_billing_subscription_id(uuid)') is null then
    raise exception 'SQL 152 self-check failed — a billing RPC is missing';
  end if;
  raise notice 'SQL 152 vineyard owner billing access: applied OK';
end$$;
