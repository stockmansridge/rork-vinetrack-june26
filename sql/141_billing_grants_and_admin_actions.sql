-- =====================================================================
-- 141_billing_grants_and_admin_actions.sql
-- =====================================================================
-- Phase 2C (2 of 2) — typed manual Billing Grants + safe, audited admin
-- WRITE actions for the Access & Entitlements portal page.
--
-- Depends on: sql/096 (manual grant columns), sql/132–135 (resolver +
-- audit), sql/140 (_admin_effective_access helper).
-- The shared resolver get_my_vinetrack_access() is NOT modified — every
-- grant shape below is expressed in terms the existing resolver already
-- honours (status, started_at, current_period_end, unlimited_licences,
-- manual_grant_expires_at / _revoked_at).
--
-- What this migration adds (all ADDITIVE):
--   A. vinetrack_subscriptions.manual_grant_type (nullable, checked):
--        internal_unlimited | complimentary_solo | complimentary_team |
--        beta_tester | temporary_access | support_access |
--        enterprise_contract
--   B. admin_create_billing_grant(user, type, reason, start, expiry,
--      vineyard) — typed grant creation. Reason REQUIRED. Permanent link
--      is auth.users.id (never email). Grant-type → plan mapping:
--        internal_unlimited / beta_tester        → internal_unlimited (unlimited)
--        temporary_access / support_access       → internal_unlimited (unlimited, expiry REQUIRED)
--        complimentary_solo                      → solo   (manual provider)
--        complimentary_team                      → team   (manual provider)
--        enterprise_contract                     → enterprise (manual provider)
--      Expiring non-unlimited grants use status 'active' +
--      current_period_end (read-time enforced by the resolver); open-ended
--      ones use status 'manual'. Future starts use started_at (resolver
--      denies until reached).
--   C. admin_extend_billing_grant(sub, new_expiry, reason)
--   D. admin_revoke_billing_grant(sub, reason, revoke_licences)
--      B/C/D operate ONLY on billing_provider = 'manual' rows — verified
--      Apple/Google/Stripe records can never be altered through them.
--   E. admin_assign_licence(sub, user, reason, vineyard) /
--      admin_remove_licence(licence, reason) — seat-checked; store
--      (apple/google) subscriptions are not licence-assignable.
--   F. admin_refresh_user_entitlement(user) — recomputes and persists the
--      user's entitlement state (change-detected audit, same event shapes
--      as the resolver). Also runs automatically after every mutation
--      above so effective access updates immediately.
--   G. admin_list_billing_grants() — grants list v2 for the portal:
--      every manual grant (all types) with licences_display ('Unlimited'
--      for unlimited grants — never '0') and platforms_display.
--
-- AUDIT: every mutation writes an append-only vinetrack_billing_events
-- row (manual_grant_created / manual_grant_extended /
-- manual_grant_revoked / licence_assigned / licence_removed) carrying the
-- acting admin id and the required reason; entitlement state changes land
-- in vinetrack_entitlement_audit via the refresh step.
--
-- ROLLBACK:
--   drop function if exists public.admin_list_billing_grants();
--   drop function if exists public.admin_refresh_user_entitlement(uuid);
--   drop function if exists public.admin_remove_licence(uuid, text);
--   drop function if exists public.admin_assign_licence(uuid, uuid, text, uuid);
--   drop function if exists public.admin_revoke_billing_grant(uuid, text, boolean);
--   drop function if exists public.admin_extend_billing_grant(uuid, timestamptz, text);
--   drop function if exists public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid);
--   drop function if exists public._admin_refresh_entitlement_state(uuid);
--   -- manual_grant_type column may simply remain (nullable, additive):
--   -- alter table public.vinetrack_subscriptions drop column manual_grant_type;
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public._admin_effective_access(uuid)') is null then
    raise exception 'SQL 141 precondition failed: apply sql/140 first';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'vinetrack_subscriptions'
      and column_name = 'manual_grant_reason'
  ) then
    raise exception 'SQL 141 precondition failed: apply sql/096 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. Grant type column (additive, nullable — existing rows unaffected).
-- ---------------------------------------------------------------------------
alter table public.vinetrack_subscriptions
  add column if not exists manual_grant_type text null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'vinetrack_subscriptions_manual_grant_type_check'
      and conrelid = 'public.vinetrack_subscriptions'::regclass
  ) then
    alter table public.vinetrack_subscriptions
      add constraint vinetrack_subscriptions_manual_grant_type_check
      check (manual_grant_type is null or manual_grant_type in (
        'internal_unlimited',
        'complimentary_solo',
        'complimentary_team',
        'beta_tester',
        'temporary_access',
        'support_access',
        'enterprise_contract'
      ));
  end if;
end$$;

-- Label pre-existing Internal Unlimited grants (best-effort, idempotent).
update public.vinetrack_subscriptions s
set manual_grant_type = 'internal_unlimited'
from public.vinetrack_plans p
where p.id = s.plan_id
  and p.code = 'internal_unlimited'
  and s.manual_grant_type is null;

-- ---------------------------------------------------------------------------
-- Internal: refresh + persist one user's entitlement state (change-detected
-- audit; same event shapes as the resolver). No client grant.
-- ---------------------------------------------------------------------------
create or replace function public._admin_refresh_entitlement_state(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  ea record;
  v_source      text;
  v_prev_has    boolean;
  v_prev_source text;
  v_prev_reason text;
  v_event       text;
  v_changed     boolean := false;
begin
  select * into ea from public._admin_effective_access(p_user_id);
  v_source := coalesce(ea.plan_tier, 'none');

  select es.has_access, es.access_source, es.reason_code
    into v_prev_has, v_prev_source, v_prev_reason
  from public.vinetrack_entitlement_state es
  where es.user_id = p_user_id;

  if not found then
    insert into public.vinetrack_entitlement_state
      (user_id, has_access, access_source, reason_code, plan_code, updated_at)
    values (p_user_id, ea.has_access, v_source, ea.reason_code, ea.plan_code, now());

    insert into public.vinetrack_entitlement_audit
      (user_id, event_type, previous_state, new_state, platform)
    values (
      p_user_id,
      case when ea.has_access then 'entitlement_granted' else 'entitlement_denied' end,
      null,
      jsonb_build_object(
        'has_access', ea.has_access, 'access_source', v_source,
        'reason_code', ea.reason_code, 'plan_code', ea.plan_code
      ),
      'server'
    );
    v_changed := true;
  elsif v_prev_has is distinct from ea.has_access
     or v_prev_source is distinct from v_source
     or v_prev_reason is distinct from ea.reason_code then

    v_event := case
      when ea.has_access and not coalesce(v_prev_has, false) then 'entitlement_granted'
      when not ea.has_access and coalesce(v_prev_has, false) then
        case ea.reason_code
          when 'expired' then 'entitlement_expired'
          when 'revoked' then 'entitlement_revoked'
          else 'entitlement_denied'
        end
      else 'entitlement_source_changed'
    end;

    update public.vinetrack_entitlement_state es
    set has_access    = ea.has_access,
        access_source = v_source,
        reason_code   = ea.reason_code,
        plan_code     = ea.plan_code,
        updated_at    = now()
    where es.user_id = p_user_id;

    insert into public.vinetrack_entitlement_audit
      (user_id, event_type, previous_state, new_state, platform)
    values (
      p_user_id,
      v_event,
      jsonb_build_object(
        'has_access', v_prev_has, 'access_source', v_prev_source,
        'reason_code', v_prev_reason
      ),
      jsonb_build_object(
        'has_access', ea.has_access, 'access_source', v_source,
        'reason_code', ea.reason_code, 'plan_code', ea.plan_code
      ),
      'server'
    );
    v_changed := true;
  end if;

  return jsonb_build_object(
    'user_id', p_user_id,
    'has_access', ea.has_access,
    'access_source', v_source,
    'reason_code', ea.reason_code,
    'plan_code', ea.plan_code,
    'changed', v_changed,
    'refreshed_at', now()
  );
end;
$$;

revoke all on function public._admin_refresh_entitlement_state(uuid) from public;
-- No client grant — called by the SECURITY DEFINER RPCs below.

-- ---------------------------------------------------------------------------
-- B. admin_create_billing_grant — typed grant creation. Reason REQUIRED.
-- ---------------------------------------------------------------------------
create or replace function public.admin_create_billing_grant(
  p_owner_user_id uuid,
  p_grant_type    text,
  p_reason        text,
  p_starts_at     timestamptz default null,
  p_expires_at    timestamptz default null,
  p_vineyard_id   uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin      uuid := auth.uid();
  v_plan_code  text;
  v_unlimited  boolean;
  v_plan_id    uuid;
  v_plan_seats integer;
  v_sub_id     uuid;
  v_status     text;
  v_period_end timestamptz;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_owner_user_id is null then
    raise exception 'user_required' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users where id = p_owner_user_id) then
    -- Portal shows "Account setup required" for this error. NEVER silently
    -- create an Auth user, and never key a grant on email alone.
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_grant_type is null or p_grant_type not in (
    'internal_unlimited', 'complimentary_solo', 'complimentary_team',
    'beta_tester', 'temporary_access', 'support_access', 'enterprise_contract'
  ) then
    raise exception 'invalid_grant_type' using errcode = '22023';
  end if;
  if p_grant_type in ('temporary_access', 'support_access') and p_expires_at is null then
    raise exception 'expiry_required_for_grant_type' using errcode = '22023';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'expiry_must_be_future' using errcode = '22023';
  end if;
  if p_starts_at is not null and p_expires_at is not null and p_starts_at >= p_expires_at then
    raise exception 'start_after_expiry' using errcode = '22023';
  end if;

  -- Grant type -> plan + shape.
  v_plan_code := case p_grant_type
    when 'complimentary_solo'  then 'solo'
    when 'complimentary_team'  then 'team'
    when 'enterprise_contract' then 'enterprise'
    else 'internal_unlimited'
  end;
  v_unlimited := (v_plan_code = 'internal_unlimited');

  select id, coalesce(included_user_licences, 1)
    into v_plan_id, v_plan_seats
  from public.vinetrack_plans
  where code = v_plan_code
  limit 1;

  if v_plan_id is null then
    raise exception 'plan_missing: %', v_plan_code using errcode = 'P0002';
  end if;

  -- Shape the row so the EXISTING resolver enforces it:
  --  * unlimited grants: status 'manual', expiry via manual_grant_expires_at
  --  * expiring non-unlimited grants: status 'active' + current_period_end
  --  * open-ended non-unlimited grants: status 'manual'
  if v_unlimited then
    v_status := 'manual';
    v_period_end := null;
  elsif p_expires_at is not null then
    v_status := 'active';
    v_period_end := p_expires_at;
  else
    v_status := 'manual';
    v_period_end := null;
  end if;

  -- Reuse an existing MANUAL-provider subscription for this owner + plan
  -- (never touches apple/google/stripe rows), else create.
  select id into v_sub_id
  from public.vinetrack_subscriptions
  where owner_user_id = p_owner_user_id
    and plan_id = v_plan_id
    and billing_provider = 'manual'
  order by (deleted_at is null) desc, created_at desc
  limit 1;

  if v_sub_id is null then
    insert into public.vinetrack_subscriptions
      (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
       seats_included, seats_purchased, unlimited_licences,
       manual_grant_type, manual_grant_reason, manual_grant_expires_at,
       manual_grant_revoked_at, manual_grant_revoked_by,
       started_at, current_period_end,
       created_by, updated_by)
    values
      (p_owner_user_id, p_vineyard_id, v_plan_id, 'manual', v_status,
       case when v_unlimited then 0 else v_plan_seats end, 0, v_unlimited,
       p_grant_type, btrim(p_reason), p_expires_at,
       null, null,
       coalesce(p_starts_at, now()), v_period_end,
       v_admin, v_admin)
    returning id into v_sub_id;
  else
    update public.vinetrack_subscriptions
    set primary_vineyard_id     = coalesce(p_vineyard_id, primary_vineyard_id),
        status                  = v_status,
        seats_included          = case when v_unlimited then 0 else v_plan_seats end,
        unlimited_licences      = v_unlimited,
        manual_grant_type       = p_grant_type,
        manual_grant_reason     = btrim(p_reason),
        manual_grant_expires_at = p_expires_at,
        manual_grant_revoked_at = null,
        manual_grant_revoked_by = null,
        deleted_at              = null,
        canceled_at             = null,
        started_at              = coalesce(p_starts_at, started_at, now()),
        current_period_end      = v_period_end,
        updated_by              = v_admin,
        updated_at              = now()
    where id = v_sub_id;
  end if;

  -- (Re)assert the owner's active licence under this grant.
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

  -- Append-only audit trail.
  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (v_sub_id, p_owner_user_id, 'manual', 'manual_grant_created',
     jsonb_build_object(
       'granted_by', v_admin,
       'grant_type', p_grant_type,
       'plan_code', v_plan_code,
       'reason', btrim(p_reason),
       'starts_at', coalesce(p_starts_at, now()),
       'expires_at', p_expires_at,
       'vineyard_id', p_vineyard_id
     ));

  -- Effective access updates immediately (entitlement state + audit).
  perform public._admin_refresh_entitlement_state(p_owner_user_id);

  return v_sub_id;
end;
$$;

revoke all on function public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid) from public;
grant execute on function public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid) to authenticated;

comment on function public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid) is
  'SQL 141: System-Admin-only typed Billing Grant creation. Keyed on auth.users.id (never email); reason required; temporary/support grants require expiry; store/Stripe rows never touched. Audited to vinetrack_billing_events; entitlement state refreshed immediately.';

-- ---------------------------------------------------------------------------
-- C. admin_extend_billing_grant
-- ---------------------------------------------------------------------------
create or replace function public.admin_extend_billing_grant(
  p_subscription_id uuid,
  p_new_expires_at  timestamptz,   -- null = grant no longer expires
  p_reason          text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_row   record;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_new_expires_at is not null and p_new_expires_at <= now() then
    raise exception 'expiry_must_be_future' using errcode = '22023';
  end if;

  select s.id, s.owner_user_id, s.billing_provider, s.status,
         s.manual_grant_revoked_at, coalesce(s.unlimited_licences, false) as unlimited
  into v_row
  from public.vinetrack_subscriptions s
  where s.id = p_subscription_id;

  if v_row.id is null then
    raise exception 'subscription_not_found' using errcode = 'P0002';
  end if;
  if v_row.billing_provider <> 'manual' then
    raise exception 'not_a_manual_grant' using errcode = '22023';
  end if;
  if v_row.manual_grant_revoked_at is not null then
    raise exception 'grant_revoked_create_new' using errcode = '22023';
  end if;

  update public.vinetrack_subscriptions
  set manual_grant_expires_at = p_new_expires_at,
      -- Expiring non-unlimited grants are enforced via current_period_end.
      current_period_end = case
        when coalesce(unlimited_licences, false) then current_period_end
        when p_new_expires_at is not null then p_new_expires_at
        else null
      end,
      status = case
        when coalesce(unlimited_licences, false) then status
        when p_new_expires_at is not null then 'active'
        else 'manual'
      end,
      updated_by = v_admin,
      updated_at = now()
  where id = p_subscription_id;

  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (p_subscription_id, v_row.owner_user_id, 'manual', 'manual_grant_extended',
     jsonb_build_object(
       'extended_by', v_admin,
       'new_expires_at', p_new_expires_at,
       'reason', btrim(p_reason)
     ));

  perform public._admin_refresh_entitlement_state(v_row.owner_user_id);

  return p_subscription_id;
end;
$$;

revoke all on function public.admin_extend_billing_grant(uuid, timestamptz, text) from public;
grant execute on function public.admin_extend_billing_grant(uuid, timestamptz, text) to authenticated;

-- ---------------------------------------------------------------------------
-- D. admin_revoke_billing_grant
-- ---------------------------------------------------------------------------
create or replace function public.admin_revoke_billing_grant(
  p_subscription_id uuid,
  p_reason          text,
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
  v_row   record;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  select s.id, s.owner_user_id, s.billing_provider
  into v_row
  from public.vinetrack_subscriptions s
  where s.id = p_subscription_id;

  if v_row.id is null then
    raise exception 'subscription_not_found' using errcode = 'P0002';
  end if;
  if v_row.billing_provider <> 'manual' then
    -- Verified Apple/Google/Stripe records can never be altered here.
    raise exception 'not_a_manual_grant' using errcode = '22023';
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
    (p_subscription_id, v_row.owner_user_id, 'manual', 'manual_grant_revoked',
     jsonb_build_object(
       'revoked_by', v_admin,
       'reason', btrim(p_reason),
       'revoked_licences', coalesce(p_revoke_licences, true)
     ));

  perform public._admin_refresh_entitlement_state(v_row.owner_user_id);

  return p_subscription_id;
end;
$$;

revoke all on function public.admin_revoke_billing_grant(uuid, text, boolean) from public;
grant execute on function public.admin_revoke_billing_grant(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- E. Licence assignment / removal (seat-checked, audited).
-- ---------------------------------------------------------------------------
create or replace function public.admin_assign_licence(
  p_subscription_id uuid,
  p_user_id         uuid,
  p_reason          text,
  p_vineyard_id     uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin      uuid := auth.uid();
  v_sub        record;
  v_active     integer;
  v_seats      integer;
  v_licence_id uuid;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  select s.id, s.owner_user_id, s.billing_provider, s.deleted_at,
         coalesce(s.unlimited_licences, false) as unlimited,
         coalesce(s.seats_included, 0) + coalesce(s.seats_purchased, 0) as seats
  into v_sub
  from public.vinetrack_subscriptions s
  where s.id = p_subscription_id;

  if v_sub.id is null then
    raise exception 'subscription_not_found' using errcode = 'P0002';
  end if;
  if v_sub.deleted_at is not null then
    raise exception 'subscription_revoked' using errcode = '22023';
  end if;
  if v_sub.billing_provider in ('apple', 'google') then
    -- Store subscriptions are personal; seats are never admin-assigned.
    raise exception 'store_subscription_not_licence_assignable' using errcode = '22023';
  end if;

  if not v_sub.unlimited then
    select count(*)::integer into v_active
    from public.vinetrack_user_licences
    where subscription_id = p_subscription_id and status = 'active';

    if v_active >= greatest(v_sub.seats, 1)
       and not exists (
         select 1 from public.vinetrack_user_licences
         where subscription_id = p_subscription_id
           and user_id = p_user_id and status = 'active'
       ) then
      raise exception 'no_seats_available' using errcode = '22023';
    end if;
  end if;

  if exists (
    select 1 from public.vinetrack_user_licences
    where subscription_id = p_subscription_id and user_id = p_user_id
  ) then
    update public.vinetrack_user_licences
    set status      = 'active',
        revoked_at  = null,
        vineyard_id = coalesce(p_vineyard_id, vineyard_id),
        assigned_by = v_admin,
        updated_at  = now()
    where subscription_id = p_subscription_id and user_id = p_user_id
    returning id into v_licence_id;
  else
    insert into public.vinetrack_user_licences
      (subscription_id, user_id, vineyard_id, status, assigned_by)
    values
      (p_subscription_id, p_user_id, p_vineyard_id, 'active', v_admin)
    returning id into v_licence_id;
  end if;

  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (p_subscription_id, v_sub.owner_user_id, 'manual', 'licence_assigned',
     jsonb_build_object(
       'assigned_by', v_admin,
       'licence_id', v_licence_id,
       'assigned_user_id', p_user_id,
       'vineyard_id', p_vineyard_id,
       'reason', btrim(p_reason)
     ));

  perform public._admin_refresh_entitlement_state(p_user_id);

  return v_licence_id;
end;
$$;

revoke all on function public.admin_assign_licence(uuid, uuid, text, uuid) from public;
grant execute on function public.admin_assign_licence(uuid, uuid, text, uuid) to authenticated;

create or replace function public.admin_remove_licence(
  p_licence_id uuid,
  p_reason     text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_lic   record;
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'reason_required' using errcode = '22023';
  end if;

  select l.id, l.subscription_id, l.user_id, s.owner_user_id
  into v_lic
  from public.vinetrack_user_licences l
  join public.vinetrack_subscriptions s on s.id = l.subscription_id
  where l.id = p_licence_id;

  if v_lic.id is null then
    raise exception 'licence_not_found' using errcode = 'P0002';
  end if;

  update public.vinetrack_user_licences
  set status     = 'revoked',
      revoked_at = now(),
      updated_at = now()
  where id = p_licence_id;

  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (v_lic.subscription_id, v_lic.owner_user_id, 'manual', 'licence_removed',
     jsonb_build_object(
       'removed_by', v_admin,
       'licence_id', p_licence_id,
       'affected_user_id', v_lic.user_id,
       'reason', btrim(p_reason)
     ));

  if v_lic.user_id is not null then
    perform public._admin_refresh_entitlement_state(v_lic.user_id);
  end if;

  return p_licence_id;
end;
$$;

revoke all on function public.admin_remove_licence(uuid, text) from public;
grant execute on function public.admin_remove_licence(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- F. admin_refresh_user_entitlement — on-demand recompute for the drawer.
-- ---------------------------------------------------------------------------
create or replace function public.admin_refresh_user_entitlement(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not public.is_system_admin() then
    raise exception 'System admin required' using errcode = '42501';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  return public._admin_refresh_entitlement_state(p_user_id);
end;
$$;

revoke all on function public.admin_refresh_user_entitlement(uuid) from public;
grant execute on function public.admin_refresh_user_entitlement(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- G. admin_list_billing_grants — grants list v2 (all grant types).
--    licences_display is 'Unlimited' for unlimited grants — NEVER '0'.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_billing_grants()
returns table (
  subscription_id         uuid,
  owner_user_id           uuid,
  owner_email             text,
  owner_full_name         text,
  grant_type              text,
  plan_code               text,
  plan_name               text,
  primary_vineyard_id     uuid,
  vineyard_name           text,
  status                  text,
  unlimited_licences      boolean,
  manual_grant_reason     text,
  starts_at               timestamptz,
  manual_grant_expires_at timestamptz,
  manual_grant_revoked_at timestamptz,
  active_licences         integer,
  seats_total             integer,
  licences_display        text,   -- 'Unlimited' | 'n of m'
  platforms_display       text,   -- 'Portal, iOS, Android' | 'iOS, Android'
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
    coalesce(pr.email, u.email)::text,
    pr.full_name,
    coalesce(s.manual_grant_type,
             case when p.code = 'internal_unlimited' then 'internal_unlimited' end),
    p.code,
    p.name,
    s.primary_vineyard_id,
    v.name,
    s.status,
    coalesce(s.unlimited_licences, false),
    s.manual_grant_reason,
    s.started_at,
    s.manual_grant_expires_at,
    s.manual_grant_revoked_at,
    (
      select count(*)::integer from public.vinetrack_user_licences l
      where l.subscription_id = s.id and l.status = 'active'
    ),
    (coalesce(s.seats_included, 0) + coalesce(s.seats_purchased, 0)),
    case
      when coalesce(s.unlimited_licences, false) then 'Unlimited'
      else (
        select count(*)::text from public.vinetrack_user_licences l2
        where l2.subscription_id = s.id and l2.status = 'active'
      ) || ' of ' || (coalesce(s.seats_included, 0) + coalesce(s.seats_purchased, 0))::text
    end,
    case
      when coalesce(p.portal_access_level, 'none') <> 'none' then 'Portal, iOS, Android'
      else 'iOS, Android'
    end,
    (
      s.deleted_at is null
      and s.manual_grant_revoked_at is null
      and (
        s.status in ('trialing', 'active', 'manual')
        or (coalesce(s.unlimited_licences, false) and s.status = 'past_due')
      )
      and (s.started_at is null or s.started_at <= now())
      and (s.manual_grant_expires_at is null or s.manual_grant_expires_at > now())
      and (
        coalesce(s.unlimited_licences, false)
        or s.status <> 'active'
        or s.current_period_end is null
        or s.current_period_end > now()
      )
    ),
    s.created_at,
    s.updated_at
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  left join auth.users u on u.id = s.owner_user_id
  left join public.profiles pr on pr.id = s.owner_user_id
  left join public.vineyards v on v.id = s.primary_vineyard_id
  where s.billing_provider = 'manual'
    and (s.manual_grant_type is not null
         or p.code = 'internal_unlimited'
         or coalesce(s.unlimited_licences, false))
  order by (s.deleted_at is null) desc, s.updated_at desc;
end;
$$;

revoke all on function public.admin_list_billing_grants() from public;
grant execute on function public.admin_list_billing_grants() to authenticated;

comment on function public.admin_list_billing_grants() is
  'SQL 141: System-Admin-only Billing Grants list v2 (all grant types, manual provider only). licences_display shows Unlimited for unlimited grants (never 0). Backs both the Access & Entitlements grants filter and the legacy Billing Grants page.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit, as a System Admin):
--   select public.admin_create_billing_grant(
--     '<user-uuid>', 'support_access', 'Support case #123',
--     null, now() + interval '7 days', null);
--   select * from public.admin_list_billing_grants();
--   select public.admin_refresh_user_entitlement('<user-uuid>');
--   select public.admin_revoke_billing_grant('<sub-uuid>', 'Case closed');
--   select * from public.admin_user_access_history('<user-uuid>', 20);
-- Expected failures:
--   * non-admin caller               -> 42501 on every RPC
--   * empty reason                   -> reason_required
--   * temporary/support w/o expiry   -> expiry_required_for_grant_type
--   * revoke on apple/google/stripe  -> not_a_manual_grant
--   * assign seat on store sub       -> store_subscription_not_licence_assignable
--   * grant for non-existent user    -> user_not_found ("Account setup required")
-- =====================================================================
