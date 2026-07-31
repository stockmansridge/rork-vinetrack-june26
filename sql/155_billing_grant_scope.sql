-- =====================================================================
-- 155_billing_grant_scope.sql
-- =====================================================================
-- Phase 2F (1 of 2) — explicit Billing Grant SCOPE (user | vineyard),
-- plus two contract fixes exposed by testing:
--   * admin_list_user_vineyards returned NULL is_owner (SQL 017 computed
--     (v.owner_id = p_user_id) which is NULL for orphaned owner_id) —
--     the iOS Grant Unlimited screen decodes is_owner as a strict Bool
--     and failed with "The data couldn't be read because it isn't in the
--     correct format."
--   * invited users could NOT see the vineyard name on invitation cards:
--     the apps read invitations with an embedded vineyards(name) join,
--     but RLS (vineyards_select_members) hides the vineyard row from a
--     user who is not YET a member — the join silently returns NULL.
--
-- WHAT THIS MIGRATION CHANGES (all ADDITIVE):
--   A. vinetrack_subscriptions.grant_scope text not null default 'user'
--      check ('user','vineyard'). Every EXISTING row (manual or store)
--      backfills to 'user' — existing grants are NEVER silently converted
--      to vineyard scope. Store/Stripe rows keep 'user' (ignored).
--   B. _billing_grant_allowed_scopes(grant_type) — the explicit
--      allowed-scope matrix (server-enforced):
--        internal_unlimited  -> user | vineyard
--        complimentary_solo  -> user
--        complimentary_team  -> vineyard
--        beta_tester         -> user | vineyard
--        temporary_access    -> user | vineyard
--        support_access      -> user | vineyard
--        enterprise_contract -> vineyard
--   C. _refresh_vineyard_member_entitlements(vineyard) — best-effort
--      entitlement-state refresh for every member of a vineyard (used
--      after vineyard-scoped grant mutations). No client grant.
--   D. admin_create_billing_grant — DROPPED and recreated with ONE
--      appended parameter p_grant_scope text default 'user'. Old clients
--      that omit it keep creating user-scoped grants (fail-safe default);
--      grant types whose policy does not allow 'user' scope now FAIL for
--      old clients rather than creating the wrong scope. Vineyard scope
--      REQUIRES a valid, non-deleted vineyard.
--   E. admin_extend_billing_grant / admin_revoke_billing_grant — same
--      signatures; vineyard-scoped mutations now refresh every affected
--      member's cached entitlement state.
--   F. admin_list_billing_grants — recreated with ONE appended column
--      grant_scope text (portal ignores unknown columns until updated).
--   G. admin_list_user_vineyards — same signature; is_owner and
--      member_count are now guaranteed NON-NULL (coalesced); role falls
--      back to 'owner' for legacy owner_id-only rows. Gate widened to
--      is_admin() OR is_system_admin().
--   H. list_my_pending_invitations() — NEW shared invitation RPC for the
--      invited user (security definer): returns vineyard_name (and
--      country) even though the invitee is not yet a member. Keyed on
--      the caller's JWT email; pending + unexpired + vineyard not
--      deleted only. iOS, Android and the portal all use this so every
--      invitation card can identify its vineyard.
--
-- HOW A VINEYARD-SCOPED GRANT GRANTS ACCESS: it does NOT create licences
-- for members. sql/156 resolves it per-vineyard: an active subscription
-- row with grant_scope='vineyard' and primary_vineyard_id = V makes V an
-- entitled vineyard for ALL its active members (newly accepted members
-- inherit automatically; removed members lose it; revocation/expiry ends
-- it). It never unlocks any other vineyard.
--
-- ROLLBACK (non-destructive):
--   drop function if exists public.list_my_pending_invitations();
--   re-run sql/017 (admin_list_user_vineyards) and sql/141 sections B–D/G;
--   drop function if exists public._refresh_vineyard_member_entitlements(uuid);
--   drop function if exists public._billing_grant_allowed_scopes(text);
--   -- grant_scope column may simply remain (defaulted, additive):
--   -- alter table public.vinetrack_subscriptions drop column grant_scope;
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid)') is null then
    raise exception 'SQL 155 precondition failed: apply sql/141 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. grant_scope column (additive; every existing row backfills to 'user').
-- ---------------------------------------------------------------------------
alter table public.vinetrack_subscriptions
  add column if not exists grant_scope text not null default 'user';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'vinetrack_subscriptions_grant_scope_check'
      and conrelid = 'public.vinetrack_subscriptions'::regclass
  ) then
    alter table public.vinetrack_subscriptions
      add constraint vinetrack_subscriptions_grant_scope_check
      check (grant_scope in ('user', 'vineyard'));
  end if;
end$$;

-- Vineyard-scoped rows are resolved per vineyard — index the lookup.
create index if not exists idx_vinetrack_subscriptions_vineyard_scope
  on public.vinetrack_subscriptions (primary_vineyard_id)
  where grant_scope = 'vineyard' and deleted_at is null;

comment on column public.vinetrack_subscriptions.grant_scope is
  'SQL 155: ''user'' (default — the entitlement belongs to owner_user_id / assigned licences) or ''vineyard'' (manual grants only — ALL active members of primary_vineyard_id inherit access while the grant is valid). Existing rows were backfilled to user scope; scope is never inferred from primary_vineyard_id.';

-- ---------------------------------------------------------------------------
-- B. Allowed-scope matrix (single source of truth; also used by tests).
-- ---------------------------------------------------------------------------
create or replace function public._billing_grant_allowed_scopes(p_grant_type text)
returns text[]
language sql
immutable
as $$
  select case p_grant_type
    when 'internal_unlimited'  then array['user', 'vineyard']
    when 'complimentary_solo'  then array['user']
    when 'complimentary_team'  then array['vineyard']
    when 'beta_tester'         then array['user', 'vineyard']
    when 'temporary_access'    then array['user', 'vineyard']
    when 'support_access'      then array['user', 'vineyard']
    when 'enterprise_contract' then array['vineyard']
    else array[]::text[]
  end;
$$;

revoke all on function public._billing_grant_allowed_scopes(text) from public;

-- ---------------------------------------------------------------------------
-- C. Best-effort member entitlement refresh (vineyard-scoped mutations).
-- ---------------------------------------------------------------------------
create or replace function public._refresh_vineyard_member_entitlements(p_vineyard_id uuid)
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  rec record;
  v_count integer := 0;
begin
  if p_vineyard_id is null then
    return 0;
  end if;
  for rec in
    select distinct vm.user_id
    from public.vineyard_members vm
    where vm.vineyard_id = p_vineyard_id
    limit 500
  loop
    begin
      perform public._admin_refresh_entitlement_state(rec.user_id);
      v_count := v_count + 1;
    exception when others then
      null;  -- best-effort: one failed member never blocks the mutation
    end;
  end loop;
  return v_count;
end;
$$;

revoke all on function public._refresh_vineyard_member_entitlements(uuid) from public;

-- ---------------------------------------------------------------------------
-- D. admin_create_billing_grant — appended p_grant_scope (default 'user').
--    Old 6-arg callers keep working (user scope); the old signature is
--    dropped so PostgREST never sees an ambiguous overload.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid);

create or replace function public.admin_create_billing_grant(
  p_owner_user_id uuid,
  p_grant_type    text,
  p_reason        text,
  p_starts_at     timestamptz default null,
  p_expires_at    timestamptz default null,
  p_vineyard_id   uuid default null,
  p_grant_scope   text default 'user'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_admin      uuid := auth.uid();
  v_scope      text := coalesce(nullif(btrim(p_grant_scope), ''), 'user');
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

  -- SQL 155: explicit scope validation (server-authoritative).
  if v_scope not in ('user', 'vineyard') then
    raise exception 'invalid_grant_scope' using errcode = '22023';
  end if;
  if not (v_scope = any (public._billing_grant_allowed_scopes(p_grant_type))) then
    raise exception 'grant_scope_not_allowed_for_type' using errcode = '22023';
  end if;
  if v_scope = 'vineyard' then
    if p_vineyard_id is null then
      raise exception 'vineyard_required_for_vineyard_scope' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.vineyards v
      where v.id = p_vineyard_id and v.deleted_at is null
    ) then
      raise exception 'vineyard_not_found' using errcode = 'P0002';
    end if;
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

  -- Reuse only a MATCHING-SCOPE manual row (a user-scoped grant is never
  -- silently converted to vineyard scope, and vice versa).
  select id into v_sub_id
  from public.vinetrack_subscriptions
  where owner_user_id = p_owner_user_id
    and plan_id = v_plan_id
    and billing_provider = 'manual'
    and grant_scope = v_scope
    and (v_scope = 'user' or primary_vineyard_id = p_vineyard_id)
  order by (deleted_at is null) desc, created_at desc
  limit 1;

  if v_sub_id is null then
    insert into public.vinetrack_subscriptions
      (owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
       seats_included, seats_purchased, unlimited_licences,
       manual_grant_type, manual_grant_reason, manual_grant_expires_at,
       manual_grant_revoked_at, manual_grant_revoked_by,
       started_at, current_period_end, grant_scope,
       created_by, updated_by)
    values
      (p_owner_user_id, p_vineyard_id, v_plan_id, 'manual', v_status,
       case when v_unlimited then 0 else v_plan_seats end, 0, v_unlimited,
       p_grant_type, btrim(p_reason), p_expires_at,
       null, null,
       coalesce(p_starts_at, now()), v_period_end, v_scope,
       v_admin, v_admin)
    returning id into v_sub_id;
  else
    update public.vinetrack_subscriptions
    set primary_vineyard_id     = case when v_scope = 'vineyard' then p_vineyard_id
                                       else coalesce(p_vineyard_id, primary_vineyard_id) end,
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
        grant_scope             = v_scope,
        updated_by              = v_admin,
        updated_at              = now()
    where id = v_sub_id;
  end if;

  -- (Re)assert the billing anchor's own licence under this grant.
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

  insert into public.vinetrack_billing_events
    (subscription_id, owner_user_id, provider, event_type, payload)
  values
    (v_sub_id, p_owner_user_id, 'manual', 'manual_grant_created',
     jsonb_build_object(
       'granted_by', v_admin,
       'grant_type', p_grant_type,
       'grant_scope', v_scope,
       'plan_code', v_plan_code,
       'reason', btrim(p_reason),
       'starts_at', coalesce(p_starts_at, now()),
       'expires_at', p_expires_at,
       'vineyard_id', p_vineyard_id
     ));

  perform public._admin_refresh_entitlement_state(p_owner_user_id);
  if v_scope = 'vineyard' then
    perform public._refresh_vineyard_member_entitlements(p_vineyard_id);
  end if;

  return v_sub_id;
end;
$$;

revoke all on function public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid, text) from public;
grant execute on function public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid, text) to authenticated;

comment on function public.admin_create_billing_grant(uuid, text, text, timestamptz, timestamptz, uuid, text) is
  'SQL 155: typed Billing Grant creation with EXPLICIT scope. p_grant_scope=user (default — only the target account) or vineyard (requires p_vineyard_id; all active members of that vineyard inherit access via the sql/156 vineyard resolver). Allowed-scope matrix enforced server-side (_billing_grant_allowed_scopes). Old 6-arg callers default to user scope (fail-safe). Reason required; store/Stripe rows never touched; audited to vinetrack_billing_events with grant_scope.';

-- ---------------------------------------------------------------------------
-- E. Extend / revoke — same signatures; vineyard-scoped grants now refresh
--    every affected member's cached entitlement state.
-- ---------------------------------------------------------------------------
create or replace function public.admin_extend_billing_grant(
  p_subscription_id uuid,
  p_new_expires_at  timestamptz,
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
         s.manual_grant_revoked_at, s.grant_scope, s.primary_vineyard_id,
         coalesce(s.unlimited_licences, false) as unlimited
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
       'grant_scope', v_row.grant_scope,
       'vineyard_id', case when v_row.grant_scope = 'vineyard'
                           then v_row.primary_vineyard_id end,
       'reason', btrim(p_reason)
     ));

  perform public._admin_refresh_entitlement_state(v_row.owner_user_id);
  if v_row.grant_scope = 'vineyard' then
    perform public._refresh_vineyard_member_entitlements(v_row.primary_vineyard_id);
  end if;

  return p_subscription_id;
end;
$$;

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

  select s.id, s.owner_user_id, s.billing_provider,
         s.grant_scope, s.primary_vineyard_id
  into v_row
  from public.vinetrack_subscriptions s
  where s.id = p_subscription_id;

  if v_row.id is null then
    raise exception 'subscription_not_found' using errcode = 'P0002';
  end if;
  if v_row.billing_provider <> 'manual' then
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
       'grant_scope', v_row.grant_scope,
       'vineyard_id', case when v_row.grant_scope = 'vineyard'
                           then v_row.primary_vineyard_id end,
       'revoked_licences', coalesce(p_revoke_licences, true)
     ));

  perform public._admin_refresh_entitlement_state(v_row.owner_user_id);
  if v_row.grant_scope = 'vineyard' then
    -- Recalculate every member the vineyard-wide grant was funding.
    perform public._refresh_vineyard_member_entitlements(v_row.primary_vineyard_id);
  end if;

  return p_subscription_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- F. admin_list_billing_grants — appended grant_scope column (return type
--    changes -> drop + recreate; everything else identical to SQL 141 G).
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_billing_grants();

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
  licences_display        text,
  platforms_display       text,
  is_active               boolean,
  created_at              timestamptz,
  updated_at              timestamptz,
  -- ---- NEW (SQL 155, appended — additive only) ----
  grant_scope             text
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
      when s.grant_scope = 'vineyard' then 'Vineyard-wide'
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
    s.updated_at,
    s.grant_scope
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
  'SQL 155: Billing Grants list (SQL 141 contract + appended grant_scope). licences_display shows Vineyard-wide for vineyard-scoped grants, Unlimited for unlimited user grants, else n of m.';

-- ---------------------------------------------------------------------------
-- G. admin_list_user_vineyards — NON-NULL is_owner/member_count (iOS Grant
--    Unlimited screen decodes strictly). Same signature and columns.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_user_vineyards(p_user_id uuid)
returns table (
  id uuid,
  name text,
  role text,
  is_owner boolean,
  country text,
  created_at timestamptz,
  deleted_at timestamptz,
  member_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.is_admin() or public.is_system_admin()) then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'user_required' using errcode = '22023';
  end if;

  return query
  select
    v.id,
    v.name,
    coalesce(vm.role, case when v.owner_id = p_user_id then 'owner' else null end) as role,
    coalesce((v.owner_id = p_user_id), false) as is_owner,
    v.country,
    v.created_at,
    v.deleted_at,
    coalesce((select count(*)::bigint from public.vineyard_members vm2
              where vm2.vineyard_id = v.id), 0) as member_count
  from public.vineyards v
  left join public.vineyard_members vm
    on vm.vineyard_id = v.id and vm.user_id = p_user_id
  where v.owner_id = p_user_id or vm.user_id = p_user_id
  order by v.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_user_vineyards(uuid) from public;
grant execute on function public.admin_list_user_vineyards(uuid) to authenticated;

comment on function public.admin_list_user_vineyards(uuid) is
  'SQL 155: vineyards a user belongs to (owner or member). is_owner and member_count are guaranteed non-null (strict mobile decoders). Admin or System Admin only.';

-- ---------------------------------------------------------------------------
-- H. list_my_pending_invitations — shared invitation identity for the
--    INVITED user (vineyard name visible before membership exists).
-- ---------------------------------------------------------------------------
create or replace function public.list_my_pending_invitations()
returns table (
  id              uuid,
  vineyard_id     uuid,
  vineyard_name   text,
  vineyard_country text,
  email           text,
  role            text,
  status          text,
  invited_by_name text,
  expires_at      timestamptz,
  created_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if v_email = '' then
    return;
  end if;

  return query
  select
    i.id,
    i.vineyard_id,
    v.name,
    v.country,
    i.email,
    i.role,
    i.status,
    pr.full_name,
    i.expires_at,
    i.created_at
  from public.invitations i
  join public.vineyards v on v.id = i.vineyard_id and v.deleted_at is null
  left join public.profiles pr on pr.id = i.invited_by
  where i.status = 'pending'
    and lower(i.email) = v_email
    and (i.expires_at is null or i.expires_at > now())
  order by i.created_at desc;
end;
$$;

revoke all on function public.list_my_pending_invitations() from public;
grant execute on function public.list_my_pending_invitations() to authenticated;

comment on function public.list_my_pending_invitations() is
  'SQL 155: pending invitations for the AUTHENTICATED caller (JWT email match), including vineyard_name/country even though the invitee is not yet a member (RLS on vineyards hides the row from non-members — root cause of nameless invitation cards). Pending + unexpired + non-deleted vineyards only.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit, as a System Admin):
--   select public.admin_create_billing_grant(
--     '<user-uuid>', 'internal_unlimited', 'Vineyard-wide beta',
--     null, null, '<vineyard-uuid>', 'vineyard');
--   select grant_scope, licences_display from public.admin_list_billing_grants();
--   select * from public.admin_list_user_vineyards('<user-uuid>');
-- Expected failures:
--   * complimentary_solo + scope vineyard  -> grant_scope_not_allowed_for_type
--   * complimentary_team + scope user      -> grant_scope_not_allowed_for_type
--   * scope vineyard w/o vineyard          -> vineyard_required_for_vineyard_scope
--   * scope vineyard + deleted vineyard    -> vineyard_not_found
--   * scope 'both'                         -> invalid_grant_scope
-- =====================================================================
