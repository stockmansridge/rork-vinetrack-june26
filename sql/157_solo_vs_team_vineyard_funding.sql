-- =====================================================================
-- 157_solo_vs_team_vineyard_funding.sql
-- =====================================================================
-- Phase 2F.1 — enforce SOLO vs TEAM vineyard funding.
--
-- CONFIRMED DEFECT IN SQL 156:
--   _vineyard_entitlement_for step 3 funded a vineyard from ANY active
--   Owner whose OWN user-level entitlement was valid — regardless of what
--   that entitlement was. A single-user Solo (or grandfathered legacy)
--   store/Stripe subscription, a USER-scoped manual grant, or even an
--   assigned licence therefore unlocked the vineyard for EVERY member
--   (Managers, Supervisors, Operators, co-Owners and every newly accepted
--   member). Commercially, a Solo subscription covers ONE user only.
--
-- POLICY IMPLEMENTED HERE (server-authoritative, one source for every
-- client — mobile apps and the portal never re-implement it):
--
--   FUNDS A VINEYARD (all active members inherit):
--     1. active VINEYARD-scoped manual grant (sql/155 grant_scope
--        ='vineyard'): internal_unlimited | complimentary_team |
--        enterprise_contract | beta_tester | temporary_access |
--        support_access, per _billing_grant_allowed_scopes;
--     2. active MULTI-SEAT subscription (plan tier 'team' | 'enterprise',
--        any non-manual provider) anchored to the vineyard through
--        primary_vineyard_id;
--     3. active MULTI-SEAT subscription (plan tier 'team' | 'enterprise')
--        OWNED by an active vineyard Owner (owner_user_id = that Owner —
--        an assigned licence does NOT count);
--     4. an active OWNER ACCOUNT TRIAL (sql/143, auth.users.created_at +
--        3 calendar months) — funds EVERY vineyard that Owner owns, for
--        the original trial window only. Evaluated INDEPENDENTLY of the
--        Owner's subscriptions, so buying Solo mid-trial no longer
--        silently strips the invited staff's evaluation access.
--
--   NEVER FUNDS A VINEYARD (the subscriber/grantee only):
--     * plan tier 'solo'   (Solo — store, Stripe or complimentary_solo);
--     * plan tier 'legacy' (grandfathered single-user store plans, e.g.
--       legacy_monthly — sql/137);
--     * ANY user-scoped manual grant (grant_scope='user'), including
--       internal_unlimited — scope is explicit and never inferred;
--     * an ASSIGNED LICENCE — it entitles the assignee only, even when
--       the assignee happens to own another vineyard.
--   Those users still enter EVERY vineyard where their own user-level
--   entitlement plus membership permit it (get_my_vinetrack_access ->
--   has_supabase_access=true opens all of their memberships).
--
-- WHAT THIS MIGRATION CHANGES (additive; no data is modified):
--   A. NEW  public._plan_funds_vineyard(plan_code, plan_tier, provider)
--      — the single allowed-funding-plan predicate.
--   B. NEW  public._vineyard_owner_ids(vineyard) — active Owners
--      (vineyard_members.role='owner' plus legacy vineyards.owner_id).
--   C. REPLACES public._vineyard_entitlement_for(uuid) — SAME 13-column
--      contract. Anchored subscriptions and Owner-backed subscriptions
--      now require _plan_funds_vineyard; Owner-subscription funding also
--      requires the Owner to be the SUBSCRIPTION owner; the Owner account
--      trial is resolved separately (so a Solo purchase cannot mask it).
--      NEW reason_code 'owner_plan_not_vineyard_funding' distinguishes
--      "this vineyard's Owner is entitled, but only for themselves" from
--      "nothing funds this vineyard at all".
--   D. REPLACES get_my_vineyard_access_matrix() / get_my_vineyard_access()
--      / admin_explain_vineyard_access() — identical contracts, except
--      the denial reason is now passed through from the resolver instead
--      of being hard-coded to 'no_vineyard_entitlement', so the matrix,
--      the single-vineyard RPC and the admin diagnostics can never
--      disagree. admin_explain_vineyard_access additionally reports
--      funding_reason_code and account_funds_vineyard.
--
--   get_my_vinetrack_access() and _admin_effective_access() are NOT
--   redefined: both already delegate to _vineyard_entitlement_for, so
--   they pick up the corrected rule with zero contract change.
--
-- ROLLBACK (non-destructive):
--   re-run sql/156 sections B, C, D and G;
--   drop function if exists public._vineyard_owner_ids(uuid);
--   drop function if exists public._plan_funds_vineyard(text, text, text);
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public._vineyard_entitlement_for(uuid)') is null
     or to_regprocedure('public._user_level_access(uuid)') is null
     or to_regprocedure('public._account_trial_for(uuid)') is null then
    raise exception 'SQL 157 precondition failed: apply sql/143/144/155/156 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. Which PLANS may fund a whole vineyard?
--    Multi-seat commercial tiers only, and never a manual grant (a manual
--    grant funds a vineyard exclusively through explicit vineyard scope,
--    sql/155) and never the account trial (resolved separately).
-- ---------------------------------------------------------------------------
create or replace function public._plan_funds_vineyard(
  p_plan_code        text,
  p_plan_tier        text,
  p_billing_provider text
)
returns boolean
language sql
immutable
as $$
  select coalesce(p_billing_provider, '') not in ('manual', 'trial', 'vineyard')
     and (
       coalesce(p_plan_tier, '') in ('team', 'enterprise')
       or coalesce(p_plan_code, '') in ('team', 'enterprise')
     );
$$;

revoke all on function public._plan_funds_vineyard(text, text, text) from public;

comment on function public._plan_funds_vineyard(text, text, text) is
  'SQL 157: true only for MULTI-SEAT commercial plans (tier/code team or enterprise) on a non-manual provider — the plans that may fund a whole vineyard. Solo and legacy single-user plans return false (they entitle the subscriber only). Manual grants return false here: they fund a vineyard only through explicit grant_scope=''vineyard'' (sql/155). The account trial is resolved separately by _vineyard_entitlement_for.';

-- ---------------------------------------------------------------------------
-- B. Active Owners of a vineyard (membership role + legacy owner_id).
-- ---------------------------------------------------------------------------
create or replace function public._vineyard_owner_ids(p_vineyard_id uuid)
returns table (owner_uid uuid)
language sql
stable
security definer
set search_path = public
as $$
  select vm.user_id
  from public.vineyard_members vm
  where vm.vineyard_id = p_vineyard_id
    and vm.role = 'owner'
  union
  select vy.owner_id
  from public.vineyards vy
  where vy.id = p_vineyard_id
    and vy.owner_id is not null;
$$;

revoke all on function public._vineyard_owner_ids(uuid) from public;

comment on function public._vineyard_owner_ids(uuid) is
  'SQL 157 internal: active Owner user ids for a vineyard (vineyard_members.role=''owner'' plus the legacy vineyards.owner_id). No client execute grant.';

-- ---------------------------------------------------------------------------
-- C. _vineyard_entitlement_for — SAME contract, Solo/Team funding enforced.
-- ---------------------------------------------------------------------------
create or replace function public._vineyard_entitlement_for(p_vineyard_id uuid)
returns table (
  has_entitlement       boolean,
  access_source         text,   -- vineyard_grant | vineyard_subscription | owner_subscription | owner_trial | none
  reason_code           text,   -- same values; no_vineyard_entitlement | owner_plan_not_vineyard_funding
  plan_code             text,
  plan_tier             text,
  plan_name             text,
  subscription_status   text,
  subscription_id       uuid,
  billing_owner_user_id uuid,
  starts_at             timestamptz,
  expires_at            timestamptz,
  is_trial              boolean,
  is_vineyard_wide      boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  best  record;
  own   record;
  tro   record;
  v_src text;
  v_user_only_owner boolean := false;
begin
  if p_vineyard_id is null then
    return query select false, 'none'::text, 'no_vineyard_entitlement'::text,
      null::text, null::text, null::text, null::text, null::uuid, null::uuid,
      null::timestamptz, null::timestamptz, false, false;
    return;
  end if;

  -- 1+2. Entitlements anchored DIRECTLY to the vineyard. A vineyard-scoped
  --      grant outranks an anchored multi-seat subscription. A user-scoped
  --      grant, a Solo/legacy subscription or a store subscription with an
  --      informational primary vineyard NEVER funds the vineyard here.
  select
    s.id             as sub_id,
    s.owner_user_id  as b_owner,
    s.grant_scope    as b_scope,
    s.status         as b_status,
    s.started_at     as b_started,
    p.code           as b_plan_code,
    p.tier           as b_plan_tier,
    p.name           as b_plan_name,
    (s.status = 'trialing') as b_is_trial,
    (
      select min(cand) from unnest(array[
        s.manual_grant_expires_at,
        s.trial_end,
        case
          when s.current_period_end is not null and s.grace_period_end is not null
            then greatest(s.current_period_end, s.grace_period_end)
          else coalesce(s.current_period_end, s.grace_period_end)
        end
      ]) cand
      where cand is not null and cand > now()
    ) as b_expires
  into best
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  where s.primary_vineyard_id = p_vineyard_id
    and s.deleted_at is null
    and (s.environment is null or s.environment <> 'sandbox')
    and (
      s.grant_scope = 'vineyard'
      or public._plan_funds_vineyard(p.code, p.tier, s.billing_provider)
    )
    and (
      s.status in ('trialing', 'active', 'manual')
      or (coalesce(s.unlimited_licences, false) = true and s.status = 'past_due')
      or (s.status = 'past_due' and s.grace_period_end is not null and s.grace_period_end > now())
    )
    and (s.started_at is null or s.started_at <= now())
    and (s.status <> 'trialing' or s.trial_end is null or s.trial_end > now())
    and (
      coalesce(s.unlimited_licences, false) = true
      or s.status not in ('active', 'past_due')
      or s.current_period_end is null
      or s.current_period_end > now()
      or (s.grace_period_end is not null and s.grace_period_end > now())
    )
    and (coalesce(s.unlimited_licences, false) = false or s.manual_grant_revoked_at is null)
    and (
      coalesce(s.unlimited_licences, false) = false
      or s.manual_grant_expires_at is null
      or s.manual_grant_expires_at > now()
    )
  order by
    (s.grant_scope = 'vineyard') desc,
    case
      when p.code = 'internal_unlimited' then 6
      when p.tier = 'enterprise'         then 5
      when p.tier = 'team'               then 4
      else 1
    end desc,
    (s.status = 'trialing') asc,
    s.current_period_end desc nulls last,
    s.created_at desc,
    s.id
  limit 1;

  if best.sub_id is not null then
    v_src := case when best.b_scope = 'vineyard'
                  then 'vineyard_grant' else 'vineyard_subscription' end;
    return query select
      true, v_src, v_src,
      best.b_plan_code, best.b_plan_tier, best.b_plan_name, best.b_status,
      best.sub_id, best.b_owner,
      best.b_started, best.b_expires, best.b_is_trial,
      (best.b_scope = 'vineyard');
    return;
  end if;

  -- 3. Owner-backed MULTI-SEAT subscription. The Owner must be the
  --    SUBSCRIPTION owner (an assigned licence entitles the assignee only)
  --    and the plan must be team/enterprise (Solo never funds members).
  select o.owner_uid, ua.*
  into own
  from public._vineyard_owner_ids(p_vineyard_id) o
  cross join lateral public._user_level_access(o.owner_uid) ua
  where ua.has_access
    and coalesce(ua.is_owner, false) = true
    and public._plan_funds_vineyard(ua.plan_code, ua.plan_tier, ua.billing_provider)
  order by
    coalesce(ua.manual_grant_expires_at, ua.current_period_end, ua.trial_end)
      desc nulls first,
    o.owner_uid
  limit 1;

  if own.owner_uid is not null then
    return query select
      true, 'owner_subscription'::text, 'owner_subscription'::text,
      own.plan_code, own.plan_tier, own.plan_name, own.status,
      own.subscription_id, own.owner_uid,
      null::timestamptz,
      (
        select min(cand) from unnest(array[
          own.trial_end,
          case
            when own.current_period_end is not null and own.grace_period_end is not null
              then greatest(own.current_period_end, own.grace_period_end)
            else coalesce(own.current_period_end, own.grace_period_end)
          end
        ]) cand
        where cand is not null and cand > now()
      ),
      (own.status in ('trialing', 'trialling')),
      false;
    return;
  end if;

  -- 4. Owner ACCOUNT TRIAL (sql/143). Resolved independently of the
  --    Owner's subscriptions so a Solo purchase during the trial cannot
  --    strip the invited staff's evaluation access. Funds every vineyard
  --    that Owner owns, for the original three-calendar-month window.
  select o.owner_uid, tr.trial_ends_at
  into tro
  from public._vineyard_owner_ids(p_vineyard_id) o
  cross join lateral public._account_trial_for(o.owner_uid) tr
  where coalesce(tr.is_active, false)
  order by tr.trial_ends_at desc, o.owner_uid
  limit 1;

  if tro.owner_uid is not null then
    return query select
      true, 'owner_trial'::text, 'owner_trial'::text,
      'trial'::text, 'trial'::text, 'Account Trial'::text, 'trialling'::text,
      null::uuid, tro.owner_uid,
      null::timestamptz, tro.trial_ends_at, true, false;
    return;
  end if;

  -- 5. Nothing funds the vineyard. Distinguish "the Owner is entitled, but
  --    only for their own account" (Solo / legacy / user-scoped grant /
  --    assigned licence) from "no entitlement anywhere".
  select exists (
    select 1
    from public._vineyard_owner_ids(p_vineyard_id) o
    cross join lateral public._user_level_access(o.owner_uid) ua
    where ua.has_access
  ) into v_user_only_owner;

  return query select
    false, 'none'::text,
    case when v_user_only_owner then 'owner_plan_not_vineyard_funding'
         else 'no_vineyard_entitlement' end,
    null::text, null::text, null::text, null::text, null::uuid, null::uuid,
    null::timestamptz, null::timestamptz, false, false;
end;
$$;

revoke all on function public._vineyard_entitlement_for(uuid) from public;

comment on function public._vineyard_entitlement_for(uuid) is
  'SQL 157: single source for "which entitlement funds this vineyard". Precedence: vineyard-scoped manual grant > multi-seat (team/enterprise) subscription anchored via primary_vineyard_id > multi-seat subscription OWNED by an active vineyard Owner > that Owner''s active account trial. Solo/legacy plans, user-scoped grants and assigned licences NEVER fund other members (reason_code owner_plan_not_vineyard_funding). Always one row. No client execute grant.';

-- ---------------------------------------------------------------------------
-- D1. get_my_vineyard_access_matrix — identical contract; the denial reason
--     is now passed through from the resolver.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_vineyard_access_matrix()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  ua record;
  v_rows       jsonb;
  v_total      integer := 0;
  v_accessible integer := 0;
  v_pending    integer := 0;
  v_state      text;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select * into ua from public._user_level_access(v_uid);

  with mv as (
    select
      vy.id   as m_vineyard_id,
      vy.name as m_vineyard_name,
      coalesce(vm.role,
               case when vy.owner_id = v_uid then 'owner' end) as m_role
    from public.vineyards vy
    left join public.vineyard_members vm
      on vm.vineyard_id = vy.id and vm.user_id = v_uid
    where vy.deleted_at is null
      and (vm.user_id = v_uid or vy.owner_id = v_uid)
  ),
  decided as (
    select
      mv.*,
      ve.*,
      (ua.has_access or ve.has_entitlement) as m_has_access
    from mv
    cross join lateral public._vineyard_entitlement_for(mv.m_vineyard_id) ve
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'vineyard_id',            d.m_vineyard_id,
      'vineyard_name',          d.m_vineyard_name,
      'membership_role',        d.m_role,
      'membership_status',      'active',
      'has_vineyard_access',    d.m_has_access,
      'vineyard_access_reason', case
                                  when ua.has_access then ua.reason_code
                                  else coalesce(d.reason_code,
                                                'no_vineyard_entitlement')
                                end,
      'vineyard_access_source', case
                                  when ua.has_access then 'account'
                                  when d.has_entitlement then d.access_source
                                  else 'none'
                                end,
      'plan_code',              case
                                  when ua.has_access then ua.plan_code
                                  else d.plan_code
                                end,
      'subscription_status',    case
                                  when ua.has_access then ua.status
                                  else d.subscription_status
                                end,
      'starts_at',              d.starts_at,
      'expires_at',             case
                                  when ua.has_access then coalesce(
                                    ua.manual_grant_expires_at,
                                    ua.current_period_end,
                                    ua.trial_end)
                                  else d.expires_at
                                end,
      'is_trial',               case
                                  when ua.has_access
                                    then (ua.billing_provider = 'trial'
                                          or ua.status in ('trialing', 'trialling'))
                                  else d.is_trial
                                end,
      'is_vineyard_wide',       d.is_vineyard_wide,
      'is_billing_owner',       coalesce(d.billing_owner_user_id = v_uid, false),
      'can_manage_billing',     (d.m_role = 'owner'),
      'can_enter_vineyard',     d.m_has_access,
      'requires_billing_attention', (not d.m_has_access and d.m_role = 'owner'),
      'last_verified_at',       now()
    ) order by d.m_vineyard_name), '[]'::jsonb),
    count(*)::integer,
    count(*) filter (where d.m_has_access)::integer
  into v_rows, v_total, v_accessible
  from decided d;

  select count(*)::integer into v_pending
  from public.invitations i
  join public.vineyards vy on vy.id = i.vineyard_id and vy.deleted_at is null
  where i.status = 'pending'
    and lower(i.email) = v_email
    and (i.expires_at is null or i.expires_at > now());

  v_state := case
    when ua.has_access      then 'full'
    when v_accessible > 0   then 'vineyard_only'
    when v_total > 0        then 'restricted'
    else 'no_vineyards'
  end;

  return jsonb_build_object(
    'generated_at', now(),
    'account', jsonb_build_object(
      'user_id',                     v_uid,
      'account_access_state',        v_state,
      'has_account_entitlement',     ua.has_access,
      'account_reason_code',         ua.reason_code,
      'account_access_source',       coalesce(ua.plan_tier, 'none'),
      'account_plan_code',           ua.plan_code,
      'account_expires_at',          coalesce(ua.manual_grant_expires_at,
                                              ua.current_period_end,
                                              ua.trial_end),
      'has_any_accessible_vineyard', (v_accessible > 0),
      'accessible_vineyard_count',   v_accessible,
      'vineyard_count',              v_total,
      'pending_invitation_count',    v_pending,
      'can_create_vineyard',         true,
      'last_verified_at',            now()
    ),
    'vineyards', v_rows
  );
end;
$$;

revoke all on function public.get_my_vineyard_access_matrix() from public;
grant execute on function public.get_my_vineyard_access_matrix() to authenticated;

comment on function public.get_my_vineyard_access_matrix() is
  'SQL 157 (contract unchanged from SQL 156): per-vineyard access matrix for the AUTHENTICATED caller. vineyard_access_reason now passes the resolver reason through, so a vineyard whose Owner holds only a Solo/user-scoped entitlement reports owner_plan_not_vineyard_funding instead of no_vineyard_entitlement. The caller''s own user-level entitlement still opens every membership.';

-- ---------------------------------------------------------------------------
-- D2. get_my_vineyard_access(p_vineyard_id) — identical contract.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_vineyard_access(p_vineyard_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  ua record;
  ve record;
  v_role text;
  v_name text;
  v_has  boolean;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_vineyard_id is null then
    raise exception 'vineyard_required' using errcode = '22023';
  end if;

  select coalesce(vm.role, case when vy.owner_id = v_uid then 'owner' end),
         vy.name
    into v_role, v_name
  from public.vineyards vy
  left join public.vineyard_members vm
    on vm.vineyard_id = vy.id and vm.user_id = v_uid
  where vy.id = p_vineyard_id
    and vy.deleted_at is null
    and (vm.user_id = v_uid or vy.owner_id = v_uid);

  if v_role is null then
    return jsonb_build_object(
      'vineyard_id', p_vineyard_id,
      'has_vineyard_access', false,
      'vineyard_access_reason', 'not_a_member',
      'vineyard_access_source', 'none',
      'can_enter_vineyard', false,
      'last_verified_at', now()
    );
  end if;

  select * into ua from public._user_level_access(v_uid);
  select * into ve from public._vineyard_entitlement_for(p_vineyard_id);
  v_has := (ua.has_access or ve.has_entitlement);

  return jsonb_build_object(
    'vineyard_id',            p_vineyard_id,
    'vineyard_name',          v_name,
    'membership_role',        v_role,
    'membership_status',      'active',
    'has_vineyard_access',    v_has,
    'vineyard_access_reason', case
                                when ua.has_access then ua.reason_code
                                else coalesce(ve.reason_code,
                                              'no_vineyard_entitlement')
                              end,
    'vineyard_access_source', case
                                when ua.has_access then 'account'
                                when ve.has_entitlement then ve.access_source
                                else 'none'
                              end,
    'plan_code',              case when ua.has_access then ua.plan_code
                                   else ve.plan_code end,
    'subscription_status',    case when ua.has_access then ua.status
                                   else ve.subscription_status end,
    'starts_at',              ve.starts_at,
    'expires_at',             case
                                when ua.has_access then coalesce(
                                  ua.manual_grant_expires_at,
                                  ua.current_period_end, ua.trial_end)
                                else ve.expires_at
                              end,
    'is_trial',               case
                                when ua.has_access
                                  then (ua.billing_provider = 'trial'
                                        or ua.status in ('trialing', 'trialling'))
                                else ve.is_trial
                              end,
    'is_vineyard_wide',       ve.is_vineyard_wide,
    'is_billing_owner',       coalesce(ve.billing_owner_user_id = v_uid, false),
    'can_manage_billing',     (v_role = 'owner'),
    'can_enter_vineyard',     v_has,
    'requires_billing_attention', (not v_has and v_role = 'owner'),
    'last_verified_at',       now()
  );
end;
$$;

revoke all on function public.get_my_vineyard_access(uuid) from public;
grant execute on function public.get_my_vineyard_access(uuid) to authenticated;

comment on function public.get_my_vineyard_access(uuid) is
  'SQL 157 (contract unchanged from SQL 156): single-vineyard access decision for the AUTHENTICATED caller — identical rules to the matrix, including the owner_plan_not_vineyard_funding reason. Non-members receive has_vineyard_access=false / reason not_a_member with no vineyard details.';

-- ---------------------------------------------------------------------------
-- D3. admin_explain_vineyard_access — same contract + funding diagnostics.
-- ---------------------------------------------------------------------------
create or replace function public.admin_explain_vineyard_access(
  p_user_id     uuid,
  p_vineyard_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ua record;
  ve record;
  v_role   text;
  v_name   text;
  v_cached record;
  v_server record;
  v_has    boolean;
begin
  if not public.is_system_admin() then
    raise exception 'System Admin only' using errcode = '42501';
  end if;
  if p_user_id is null or p_vineyard_id is null then
    raise exception 'user_and_vineyard_required' using errcode = '22023';
  end if;

  select coalesce(vm.role, case when vy.owner_id = p_user_id then 'owner' end),
         vy.name
    into v_role, v_name
  from public.vineyards vy
  left join public.vineyard_members vm
    on vm.vineyard_id = vy.id and vm.user_id = p_user_id
  where vy.id = p_vineyard_id;

  select * into ua from public._user_level_access(p_user_id);
  select * into ve from public._vineyard_entitlement_for(p_vineyard_id);
  v_has := (v_role is not null) and (ua.has_access or ve.has_entitlement);

  select es.has_access, es.access_source, es.reason_code, es.updated_at
    into v_cached
  from public.vinetrack_entitlement_state es
  where es.user_id = p_user_id;

  select ea.has_access, ea.reason_code, ea.plan_tier
    into v_server
  from public._admin_effective_access(p_user_id) ea;

  return jsonb_build_object(
    'generated_at', now(),
    'user_id', p_user_id,
    'vineyard_id', p_vineyard_id,
    'vineyard_name', v_name,
    'membership_role', v_role,
    'decision', jsonb_build_object(
      'has_vineyard_access', v_has,
      'reason_code', case
        when v_role is null then 'not_a_member'
        when ua.has_access then ua.reason_code
        else coalesce(ve.reason_code, 'no_vineyard_entitlement')
      end,
      'access_source', case
        when v_role is null then 'none'
        when ua.has_access then 'account'
        when ve.has_entitlement then ve.access_source
        else 'none'
      end,
      -- SQL 157: did the user get in on their OWN entitlement only?
      'account_funds_vineyard', (ua.has_access and not ve.has_entitlement)
    ),
    'account_access', jsonb_build_object(
      'has_access', ua.has_access,
      'reason_code', ua.reason_code,
      'access_source', coalesce(ua.plan_tier, 'none'),
      'plan_code', ua.plan_code,
      'subscription_id', ua.subscription_id,
      'trial_end', ua.trial_end,
      'current_period_end', ua.current_period_end,
      'manual_grant_expires_at', ua.manual_grant_expires_at,
      -- SQL 157: would this account's plan fund a whole vineyard?
      'plan_funds_vineyard', coalesce(
        public._plan_funds_vineyard(ua.plan_code, ua.plan_tier, ua.billing_provider),
        false)
    ),
    'vineyard_entitlement', jsonb_build_object(
      'has_entitlement', ve.has_entitlement,
      'access_source', ve.access_source,
      'funding_reason_code', ve.reason_code,
      'grant_scope', case when ve.is_vineyard_wide then 'vineyard' else 'user' end,
      'plan_code', ve.plan_code,
      'plan_tier', ve.plan_tier,
      'subscription_id', ve.subscription_id,
      'subscription_status', ve.subscription_status,
      'billing_owner_user_id', ve.billing_owner_user_id,
      'starts_at', ve.starts_at,
      'expires_at', ve.expires_at,
      'is_trial', ve.is_trial
    ),
    'inheriting_members', case
      when ve.has_entitlement and ve.access_source <> 'none' then coalesce((
        select jsonb_agg(jsonb_build_object(
          'user_id', vm.user_id,
          'role', vm.role,
          'display_name', vm.display_name
        ) order by vm.role, vm.user_id)
        from (
          select * from public.vineyard_members vm0
          where vm0.vineyard_id = p_vineyard_id
          limit 200
        ) vm
      ), '[]'::jsonb)
      else '[]'::jsonb
    end,
    'cached_result', case when v_cached.updated_at is not null then jsonb_build_object(
      'has_access', v_cached.has_access,
      'access_source', v_cached.access_source,
      'reason_code', v_cached.reason_code,
      'updated_at', v_cached.updated_at
    ) end,
    'server_result', jsonb_build_object(
      'has_access', v_server.has_access,
      'reason_code', v_server.reason_code,
      'access_source', coalesce(v_server.plan_tier, 'none')
    ),
    'mismatch_type', case
      when v_cached.updated_at is null then 'no_cached_state'
      when v_cached.has_access is distinct from v_server.has_access then 'access_mismatch'
      when v_cached.reason_code is distinct from v_server.reason_code then 'reason_mismatch'
      else null
    end
  );
end;
$$;

revoke all on function public.admin_explain_vineyard_access(uuid, uuid) from public;
grant execute on function public.admin_explain_vineyard_access(uuid, uuid) to authenticated;

comment on function public.admin_explain_vineyard_access(uuid, uuid) is
  'SQL 157: System-Admin access diagnostics (SQL 156 contract + funding_reason_code, plan_funds_vineyard, account_funds_vineyard, plan_tier). Answers why a user can/cannot enter a vineyard, which entitlement funds it, who inherits vineyard-wide access (cap 200), cached vs computed state and mismatch_type. No tokens, receipts or device identifiers.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit):
--   -- Solo Owner's vineyard is NOT funded for members:
--   select * from public._vineyard_entitlement_for('<solo-owner-vineyard>');
--     -> has_entitlement=false, reason_code='owner_plan_not_vineyard_funding'
--   -- Team/Enterprise Owner's vineyard IS funded:
--     -> has_entitlement=true, access_source='owner_subscription'
--   -- Owner still inside the 3-month account trial:
--     -> has_entitlement=true, access_source='owner_trial'
--   select public.admin_explain_vineyard_access('<member>', '<vineyard>');
-- =====================================================================
