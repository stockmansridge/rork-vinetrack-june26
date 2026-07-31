-- =====================================================================
-- 156_vineyard_access_matrix.sql
-- =====================================================================
-- Phase 2F (2 of 2) — separate ACCOUNT access from VINEYARD access.
--
-- CONFIRMED ROOT CAUSE OF THE GLOBAL PAYWALL:
--   get_my_vinetrack_access() collapses every entitlement the user can
--   reach into ONE user-level has_supabase_access boolean (best single
--   subscription / account trial). There is NO per-vineyard decision and
--   NOTHING joins vineyard_members to a vineyard's funding entitlement.
--   When a user's own trial/subscription expires, has_supabase_access
--   flips false for the WHOLE account and both apps show a whole-app
--   paywall — even when another vineyard they belong to is fully funded
--   by its Owner's subscription, trial, or a vineyard-wide grant.
--
-- WHAT THIS MIGRATION CHANGES:
--   A. _user_level_access(user) — EXACT copy of the SQL 144
--      _admin_effective_access body (subscriptions + account trial only).
--      It is the recursion-safe "own entitlement" primitive used by the
--      vineyard resolver below (a vineyard's owner check must never
--      recurse back through vineyard-backed access).
--   B. _vineyard_entitlement_for(vineyard) — the single server source for
--      "which entitlement currently funds this vineyard":
--        1. active VINEYARD-SCOPED manual grant (sql/155) anchored to it;
--        2. active MULTI-SEAT subscription (team/enterprise/legacy, non-
--           manual provider) anchored to it via primary_vineyard_id —
--           a user-scoped manual grant or a solo/store subscription with
--           an informational primary vineyard NEVER funds the vineyard
--           this way (scope is never inferred from Primary Vineyard);
--        3. any active vineyard OWNER (membership role 'owner' or legacy
--           vineyards.owner_id) whose OWN user-level entitlement is
--           valid — including the Owner's account trial. This preserves
--           the existing commercial trial rule: the Owner's ONE account
--           trial (anchored to auth.users.created_at + 3 calendar
--           months, sql/143) backs EVERY vineyard they own during the
--           trial, and its expiry affects exactly those vineyards.
--   C. get_my_vineyard_access_matrix() -> jsonb — one row per active
--      membership/ownership plus an account summary (auth.uid() only).
--   D. get_my_vineyard_access(p_vineyard_id) -> jsonb — single-vineyard
--      decision; membership verified; non-members get a safe
--      not_a_member result with no vineyard details.
--   E. get_my_vinetrack_access() — SAME 34-column signature; ONE new
--      granting step strictly BELOW the account trial and ABOVE denial:
--      when the user has no own entitlement but at least one of their
--      vineyards is funded (B), access is granted with
--      access_source='vineyard', reason_code='vineyard_entitlement',
--      plan_tier='vineyard', billing_provider='vineyard', vineyard_id =
--      the funded vineyard, plan_code/plan_name/status/expiry from the
--      funding entitlement. Released clients keep parsing unchanged —
--      an expired vineyard can no longer blank the whole account.
--      Funding subscription_id is NOT exposed to plain members.
--   F. _admin_effective_access(user) — SAME signature, now =
--      _user_level_access + the IDENTICAL vineyard-backed step, so the
--      admin surface (admin_access_users / detail / refresh) can never
--      drift from the resolver and entitlement-state writes never churn.
--   G. admin_explain_vineyard_access(user, vineyard) -> jsonb — System
--      Admin diagnostics: why can/can't this user access this vineyard,
--      which entitlement funds it, who inherits a vineyard-wide grant,
--      cached vs computed result and mismatch_type. No tokens/receipts.
--
-- ROLLBACK (non-destructive):
--   drop function if exists public.admin_explain_vineyard_access(uuid, uuid);
--   drop function if exists public.get_my_vineyard_access(uuid);
--   drop function if exists public.get_my_vineyard_access_matrix();
--   re-run sql/144 sections A+B (resolver + _admin_effective_access);
--   drop function if exists public._vineyard_entitlement_for(uuid);
--   drop function if exists public._user_level_access(uuid);
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public._admin_effective_access(uuid)') is null
     or to_regprocedure('public._account_trial_for(uuid)') is null then
    raise exception 'SQL 156 precondition failed: apply sql/143/144 first';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'vinetrack_subscriptions'
      and column_name = 'grant_scope'
  ) then
    raise exception 'SQL 156 precondition failed: apply sql/155 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. _user_level_access — recursion-safe own-entitlement primitive.
--    EXACT SQL 144 _admin_effective_access logic (subscriptions + trial).
-- ---------------------------------------------------------------------------
create or replace function public._user_level_access(p_user_id uuid)
returns table (
  has_access              boolean,
  reason_code             text,
  subscription_id         uuid,
  plan_code               text,
  plan_tier               text,
  plan_name               text,
  billing_provider        text,
  status                  text,
  purchase_platform       text,
  environment             text,
  trial_end               timestamptz,
  current_period_end      timestamptz,
  cancel_at_period_end    boolean,
  grace_period_end        timestamptz,
  unlimited_licences      boolean,
  manual_grant_reason     text,
  manual_grant_expires_at timestamptz,
  is_owner                boolean,
  licence_id              uuid,
  vineyard_id             uuid,
  portal_access           boolean,
  portal_access_level     text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r record;
  tr record;
  v_reason text;
begin
  select
    s.id            as sub_id,
    p.code          as plan_code,
    p.tier          as plan_tier,
    p.name          as plan_name,
    p.portal_access_level,
    s.billing_provider,
    s.status,
    s.platform,
    s.environment,
    s.trial_end,
    s.current_period_end,
    coalesce(s.cancel_at_period_end, false) as cancel_at_period_end,
    s.grace_period_end,
    coalesce(s.unlimited_licences, false)   as unlimited,
    s.manual_grant_reason,
    s.manual_grant_expires_at,
    (s.owner_user_id = p_user_id)           as is_owner,
    (
      select ul.id from public.vinetrack_user_licences ul
      where ul.subscription_id = s.id
        and ul.user_id = p_user_id
        and ul.status = 'active'
      order by ul.id limit 1
    ) as licence_id,
    coalesce(
      (
        select ul2.vineyard_id from public.vinetrack_user_licences ul2
        where ul2.subscription_id = s.id
          and ul2.user_id = p_user_id
          and ul2.status = 'active'
        order by ul2.id limit 1
      ),
      s.primary_vineyard_id
    ) as vineyard_id
  into r
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  where s.deleted_at is null
    and (s.environment is null or s.environment <> 'sandbox')
    and (
      s.owner_user_id = p_user_id
      or exists (
        select 1 from public.vinetrack_user_licences l
        where l.subscription_id = s.id
          and l.user_id = p_user_id
          and l.status = 'active'
      )
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
    case
      when p.code = 'internal_unlimited' then 6
      when p.tier = 'enterprise'         then 5
      when p.tier = 'team'               then 4
      when p.tier = 'legacy'             then 3
      when p.tier = 'solo'               then 2
      else 1
    end desc,
    (s.status = 'trialing') asc,
    (s.owner_user_id = p_user_id) desc,
    s.current_period_end desc nulls last,
    s.created_at desc,
    s.id
  limit 1;

  if r.sub_id is not null then
    v_reason := case
      when r.plan_code = 'internal_unlimited'                 then 'internal_unlimited'
      when r.plan_tier = 'enterprise'                         then 'enterprise_subscription'
      when r.status = 'trialing'
           and r.billing_provider not in ('apple', 'google')  then 'active_trial'
      when r.licence_id is not null
           and coalesce(r.is_owner, false) = false
           and r.billing_provider not in ('apple', 'google')  then 'assigned_licence'
      when r.billing_provider in ('apple', 'google')          then 'app_store_subscription'
      else 'portal_subscription'
    end;

    return query select
      true, v_reason, r.sub_id, r.plan_code, r.plan_tier, r.plan_name,
      r.billing_provider, r.status, r.platform, r.environment,
      r.trial_end, r.current_period_end, r.cancel_at_period_end,
      r.grace_period_end, r.unlimited, r.manual_grant_reason,
      r.manual_grant_expires_at, coalesce(r.is_owner, false),
      r.licence_id, r.vineyard_id,
      (coalesce(r.portal_access_level, 'none') <> 'none'),
      coalesce(r.portal_access_level, 'none');
    return;
  end if;

  select * into tr from public._account_trial_for(p_user_id);

  if coalesce(tr.is_active, false) then
    return query select
      true, 'active_trial'::text, null::uuid,
      'trial'::text, 'trial'::text, 'Account Trial'::text,
      'trial'::text, 'trialling'::text,
      null::text, null::text,
      tr.trial_ends_at, null::timestamptz, false,
      null::timestamptz, false, null::text,
      null::timestamptz, false,
      null::uuid, null::uuid,
      true, 'basic'::text;
    return;
  end if;

  select case
    when s2.manual_grant_revoked_at is not null
      or s2.status = 'canceled'
      or s2.deleted_at is not null                                  then 'revoked'
    when s2.status = 'expired'                                      then 'expired'
    when s2.status = 'trialing'
      and s2.trial_end is not null and s2.trial_end <= now()        then 'expired'
    when s2.status in ('active', 'past_due')
      and s2.current_period_end is not null
      and s2.current_period_end <= now()                            then 'expired'
    when coalesce(s2.unlimited_licences, false) = true
      and s2.manual_grant_expires_at is not null
      and s2.manual_grant_expires_at <= now()                       then 'expired'
    else null
  end
  into v_reason
  from public.vinetrack_subscriptions s2
  where s2.owner_user_id = p_user_id
     or exists (
       select 1 from public.vinetrack_user_licences l2
       where l2.subscription_id = s2.id and l2.user_id = p_user_id
     )
  order by s2.updated_at desc, s2.id
  limit 1;

  if v_reason is null and tr.status is not null then
    return query select
      false,
      case when tr.status = 'revoked' then 'revoked' else 'expired' end,
      null::uuid,
      'trial'::text, 'trial'::text, 'Account Trial'::text,
      'trial'::text,
      case when tr.status = 'revoked' then 'revoked' else 'expired' end,
      null::text, null::text,
      tr.trial_ends_at,
      null::timestamptz, false,
      null::timestamptz, false, null::text,
      null::timestamptz, false,
      null::uuid, null::uuid,
      false, 'none'::text;
    return;
  end if;

  return query select
    false, coalesce(v_reason, 'no_entitlement'),
    null::uuid, null::text, null::text, null::text,
    null::text, null::text, null::text, null::text,
    null::timestamptz, null::timestamptz, false,
    null::timestamptz, false, null::text,
    null::timestamptz, false,
    null::uuid, null::uuid,
    false, 'none'::text;
end;
$$;

revoke all on function public._user_level_access(uuid) from public;

comment on function public._user_level_access(uuid) is
  'SQL 156 internal: recursion-safe OWN-entitlement resolver (exact SQL 144 logic — subscriptions, licences, manual grants, account trial). Used by _vineyard_entitlement_for owner checks. No client execute grant.';

-- ---------------------------------------------------------------------------
-- B. _vineyard_entitlement_for — which entitlement funds this vineyard?
--    Always returns EXACTLY one row.
-- ---------------------------------------------------------------------------
create or replace function public._vineyard_entitlement_for(p_vineyard_id uuid)
returns table (
  has_entitlement       boolean,
  access_source         text,   -- vineyard_grant | vineyard_subscription | owner_subscription | owner_trial | owner_grant | none
  reason_code           text,   -- same values; 'no_vineyard_entitlement' when none
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
  best record;
  own  record;
  v_src text;
begin
  if p_vineyard_id is null then
    return query select false, 'none'::text, 'no_vineyard_entitlement'::text,
      null::text, null::text, null::text, null::text, null::uuid, null::uuid,
      null::timestamptz, null::timestamptz, false, false;
    return;
  end if;

  -- 1+2. Entitlements anchored DIRECTLY to the vineyard (vineyard-scoped
  --      grants outrank anchored subscriptions). Same validity rules as
  --      the shared resolver. IMPORTANT: a user-scoped manual grant or a
  --      solo/store subscription with an informational primary vineyard
  --      never funds the vineyard here — scope is explicit (sql/155).
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
      or (s.billing_provider not in ('manual', 'apple', 'google')
          and p.tier in ('team', 'enterprise', 'legacy'))
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
      when p.tier = 'legacy'             then 3
      when p.tier = 'solo'               then 2
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

  -- 3. Owner-backed: any active vineyard owner with a valid OWN
  --    entitlement (subscription, grant, licence or account trial).
  select o.owner_uid, ua.*
  into own
  from (
    select vm.user_id as owner_uid
    from public.vineyard_members vm
    where vm.vineyard_id = p_vineyard_id and vm.role = 'owner'
    union
    select vy.owner_id
    from public.vineyards vy
    where vy.id = p_vineyard_id and vy.owner_id is not null
  ) o
  cross join lateral public._user_level_access(o.owner_uid) ua
  where ua.has_access
  order by
    (ua.billing_provider = 'trial') asc,   -- prefer paid over trial funding
    coalesce(ua.manual_grant_expires_at, ua.current_period_end, ua.trial_end)
      desc nulls first,
    o.owner_uid
  limit 1;

  if own.owner_uid is not null then
    v_src := case
      when own.billing_provider = 'trial'  then 'owner_trial'
      when own.billing_provider = 'manual' then 'owner_grant'
      else 'owner_subscription'
    end;
    return query select
      true, v_src, v_src,
      own.plan_code, own.plan_tier, own.plan_name, own.status,
      own.subscription_id, own.owner_uid,
      null::timestamptz,
      (
        select min(cand) from unnest(array[
          own.manual_grant_expires_at,
          own.trial_end,
          case
            when own.current_period_end is not null and own.grace_period_end is not null
              then greatest(own.current_period_end, own.grace_period_end)
            else coalesce(own.current_period_end, own.grace_period_end)
          end
        ]) cand
        where cand is not null and cand > now()
      ),
      (own.billing_provider = 'trial' or own.status in ('trialing', 'trialling')),
      false;
    return;
  end if;

  return query select false, 'none'::text, 'no_vineyard_entitlement'::text,
    null::text, null::text, null::text, null::text, null::uuid, null::uuid,
    null::timestamptz, null::timestamptz, false, false;
end;
$$;

revoke all on function public._vineyard_entitlement_for(uuid) from public;

comment on function public._vineyard_entitlement_for(uuid) is
  'SQL 156 internal: single source for "which entitlement funds this vineyard". Precedence: vineyard-scoped manual grant > subscription anchored via primary_vineyard_id > any active vineyard Owner''s own valid entitlement (incl. their account trial). Always one row. No client execute grant.';

-- ---------------------------------------------------------------------------
-- C. get_my_vineyard_access_matrix() -> jsonb
--    { generated_at, account:{...}, vineyards:[{...}] }
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
                                  when d.has_entitlement then d.reason_code
                                  else 'no_vineyard_entitlement'
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
  'SQL 156: per-vineyard access matrix for the AUTHENTICATED caller. jsonb { generated_at, account:{account_access_state full|vineyard_only|restricted|no_vineyards, has_any_accessible_vineyard, accessible_vineyard_count, vineyard_count, pending_invitation_count, can_create_vineyard, ...}, vineyards:[one row per active membership/ownership with has_vineyard_access, vineyard_access_reason/source, plan, expiry, is_vineyard_wide, is_billing_owner, can_manage_billing, requires_billing_attention] }. A user''s own entitlement (source account) opens every membership; otherwise access follows _vineyard_entitlement_for. Never exposes another owner''s funding subscription id.';

-- ---------------------------------------------------------------------------
-- D. get_my_vineyard_access(p_vineyard_id) -> jsonb (single vineyard).
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
    -- Not a member: safe denial, no vineyard details leaked.
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
                                when ve.has_entitlement then ve.reason_code
                                else 'no_vineyard_entitlement'
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
  'SQL 156: single-vineyard access decision for the AUTHENTICATED caller — identical rules to the matrix. Non-members receive has_vineyard_access=false / reason not_a_member with no vineyard details.';

-- ---------------------------------------------------------------------------
-- E. get_my_vinetrack_access — SAME 34-column signature; NEW vineyard-backed
--    granting step strictly below the account trial, above denial.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_vinetrack_access()
returns table (
  user_id                 uuid,
  has_supabase_access     boolean,
  access_source           text,     -- tier | 'trial' | 'vineyard' | 'none'
  is_owner                boolean,
  subscription_id         uuid,
  plan_code               text,
  plan_tier               text,
  plan_name               text,
  billing_provider        text,
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
  solo_check_required     boolean,
  reason_code             text,
  is_unlimited            boolean,
  can_use_android_app     boolean,
  last_verified_at        timestamptz,
  enforcement_enabled     boolean,
  purchase_platform       text,
  cancel_at_period_end    boolean,
  grace_period_end        timestamptz,
  expires_at              timestamptz
)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();

  v_sub_id          uuid;
  v_is_owner        boolean;
  v_status          text;
  v_provider        text;
  v_trial_end       timestamptz;
  v_period_end      timestamptz;
  v_seats_included  integer;
  v_seats_purchased integer;
  v_unlimited       boolean;
  v_grant_reason    text;
  v_grant_expires   timestamptz;
  v_plan_code       text;
  v_plan_tier       text;
  v_plan_name       text;
  v_portal_level    text;
  v_active_licences integer;
  v_licence_id      uuid;
  v_vineyard_id     uuid;
  v_platform        text;
  v_cancel_at_end   boolean;
  v_grace_end       timestamptz;
  v_expires_at      timestamptz;

  tr record;
  vb record;   -- SQL 156: best vineyard-backed entitlement

  v_has     boolean := false;
  v_source  text := 'none';
  v_reason  text := 'no_entitlement';
  v_enforce boolean := false;

  v_prev_has    boolean;
  v_prev_source text;
  v_prev_reason text;
  v_event       text;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- ---- 1. Best VALID own subscription entitlement (unchanged from SQL 144).
  select
    b.id, b.b_is_owner, b.b_status, b.b_provider, b.b_trial_end, b.b_period_end,
    b.b_seats_included, b.b_seats_purchased, b.b_unlimited, b.b_grant_reason,
    b.b_grant_expires, b.b_plan_code, b.b_plan_tier, b.b_plan_name,
    b.b_portal_level, b.b_active_licences, b.b_licence_id, b.b_vineyard_id,
    b.b_platform, b.b_cancel_at_end, b.b_grace_end
  into
    v_sub_id, v_is_owner, v_status, v_provider, v_trial_end, v_period_end,
    v_seats_included, v_seats_purchased, v_unlimited, v_grant_reason,
    v_grant_expires, v_plan_code, v_plan_tier, v_plan_name,
    v_portal_level, v_active_licences, v_licence_id, v_vineyard_id,
    v_platform, v_cancel_at_end, v_grace_end
  from (select 1) one
  left join (
    select
      s.id,
      (s.owner_user_id = v_uid)             as b_is_owner,
      s.status                               as b_status,
      s.billing_provider                     as b_provider,
      s.trial_end                            as b_trial_end,
      s.current_period_end                   as b_period_end,
      s.seats_included                       as b_seats_included,
      s.seats_purchased                      as b_seats_purchased,
      coalesce(s.unlimited_licences, false)  as b_unlimited,
      s.manual_grant_reason                  as b_grant_reason,
      s.manual_grant_expires_at              as b_grant_expires,
      p.code                                 as b_plan_code,
      p.tier                                 as b_plan_tier,
      p.name                                 as b_plan_name,
      p.portal_access_level                  as b_portal_level,
      s.platform                             as b_platform,
      coalesce(s.cancel_at_period_end, false) as b_cancel_at_end,
      s.grace_period_end                     as b_grace_end,
      (
        select count(*)::integer
        from public.vinetrack_user_licences cl
        where cl.subscription_id = s.id
          and cl.status = 'active'
      ) as b_active_licences,
      (
        select ul.id
        from public.vinetrack_user_licences ul
        where ul.subscription_id = s.id
          and ul.user_id = v_uid
          and ul.status = 'active'
        order by ul.id
        limit 1
      ) as b_licence_id,
      coalesce(
        (
          select ul2.vineyard_id
          from public.vinetrack_user_licences ul2
          where ul2.subscription_id = s.id
            and ul2.user_id = v_uid
            and ul2.status = 'active'
          order by ul2.id
          limit 1
        ),
        s.primary_vineyard_id
      ) as b_vineyard_id,
      case
        when p.code = 'internal_unlimited' then 6
        when p.tier = 'enterprise'         then 5
        when p.tier = 'team'               then 4
        when p.tier = 'legacy'             then 3
        when p.tier = 'solo'               then 2
        else 1
      end as tier_rank
    from public.vinetrack_subscriptions s
    join public.vinetrack_plans p on p.id = s.plan_id
    where s.deleted_at is null
      and (s.environment is null or s.environment <> 'sandbox')
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
      tier_rank desc,
      (s.status = 'trialing') asc,
      (s.owner_user_id = v_uid) desc,
      s.current_period_end desc nulls last,
      s.created_at desc,
      s.id
    limit 1
  ) b on true;

  -- ---- 2. Account trial (sql/143).
  select * into tr from public._account_trial_for(v_uid);

  -- ---- 3. Reason code + precedence (subscription > trial > VINEYARD > denial).
  if v_sub_id is not null then
    v_has := true;
    v_source := coalesce(v_plan_tier, 'none');
    v_reason := case
      when v_plan_code = 'internal_unlimited'            then 'internal_unlimited'
      when v_plan_tier = 'enterprise'                    then 'enterprise_subscription'
      when v_status = 'trialing'
           and v_provider not in ('apple', 'google')     then 'active_trial'
      when v_licence_id is not null
           and coalesce(v_is_owner, false) = false
           and v_provider not in ('apple', 'google')     then 'assigned_licence'
      when v_provider in ('apple', 'google')             then 'app_store_subscription'
      else 'portal_subscription'
    end;
    select min(cand) into v_expires_at
    from unnest(array[
      v_grant_expires,
      v_trial_end,
      case
        when v_period_end is not null and v_grace_end is not null
          then greatest(v_period_end, v_grace_end)
        else coalesce(v_period_end, v_grace_end)
      end
    ]) cand
    where cand is not null and cand > now();

  elsif coalesce(tr.is_active, false) then
    v_has          := true;
    v_source       := 'trial';
    v_reason       := 'active_trial';
    v_plan_code    := 'trial';
    v_plan_tier    := 'trial';
    v_plan_name    := 'Account Trial';
    v_provider     := 'trial';
    v_status       := 'trialling';
    v_trial_end    := tr.trial_ends_at;
    v_portal_level := 'basic';
    v_seats_included := 1;
    v_expires_at   := tr.trial_ends_at;

  else
    -- ---- SQL 156: vineyard-backed access. When the user has no own
    --      entitlement, any of their vineyards funded by a vineyard-wide
    --      grant, an anchored subscription, or an active Owner's own
    --      entitlement still grants access. The funding subscription id
    --      is NOT exposed to plain members.
    select mv.m_vineyard_id, ve.*
    into vb
    from (
      select vy.id as m_vineyard_id
      from public.vineyards vy
      left join public.vineyard_members vm
        on vm.vineyard_id = vy.id and vm.user_id = v_uid
      where vy.deleted_at is null
        and (vm.user_id = v_uid or vy.owner_id = v_uid)
    ) mv
    cross join lateral public._vineyard_entitlement_for(mv.m_vineyard_id) ve
    where ve.has_entitlement
    order by ve.is_trial asc, ve.expires_at desc nulls first, mv.m_vineyard_id
    limit 1;

    if vb.m_vineyard_id is not null then
      v_has          := true;
      v_source       := 'vineyard';
      v_reason       := 'vineyard_entitlement';
      v_plan_code    := vb.plan_code;
      v_plan_tier    := 'vineyard';
      v_plan_name    := vb.plan_name;
      v_provider     := 'vineyard';
      v_status       := vb.subscription_status;
      v_vineyard_id  := vb.m_vineyard_id;
      v_portal_level := 'basic';
      v_seats_included := 1;
      v_expires_at   := vb.expires_at;
      if vb.is_trial then
        v_trial_end := vb.expires_at;
      end if;
      -- subscription_id / licence stay NULL for members.

    else
      -- ---- Denial classification (unchanged from SQL 144).
      select case
        when s2.manual_grant_revoked_at is not null
          or s2.status = 'canceled'
          or s2.deleted_at is not null                                  then 'revoked'
        when s2.status = 'expired'                                      then 'expired'
        when s2.status = 'trialing'
          and s2.trial_end is not null and s2.trial_end <= now()        then 'expired'
        when s2.status in ('active', 'past_due')
          and s2.current_period_end is not null
          and s2.current_period_end <= now()                            then 'expired'
        when coalesce(s2.unlimited_licences, false) = true
          and s2.manual_grant_expires_at is not null
          and s2.manual_grant_expires_at <= now()                       then 'expired'
        else null
      end
      into v_reason
      from public.vinetrack_subscriptions s2
      where s2.owner_user_id = v_uid
         or exists (
           select 1 from public.vinetrack_user_licences l2
           where l2.subscription_id = s2.id and l2.user_id = v_uid
         )
      order by s2.updated_at desc, s2.id
      limit 1;

      if v_reason is null and tr.status is not null then
        v_reason     := case when tr.status = 'revoked' then 'revoked' else 'expired' end;
        v_source     := 'trial';
        v_plan_code  := 'trial';
        v_plan_tier  := 'trial';
        v_plan_name  := 'Account Trial';
        v_provider   := 'trial';
        v_status     := case when tr.status = 'revoked' then 'revoked' else 'expired' end;
        v_trial_end  := tr.trial_ends_at;
        v_expires_at := tr.trial_ends_at;
      end if;

      v_reason := coalesce(v_reason, 'no_entitlement');
    end if;
  end if;

  -- ---- 4. Per-caller rollout flag (unchanged).
  v_enforce := public._entitlement_enforcement_enabled(
    v_uid,
    v_has and v_reason = 'internal_unlimited'
  );

  -- ---- 5. Guarded maintenance + change-detected audit (unchanged).
  begin
    perform public._ensure_account_trial(v_uid);

    select es.has_access, es.access_source, es.reason_code
      into v_prev_has, v_prev_source, v_prev_reason
    from public.vinetrack_entitlement_state es
    where es.user_id = v_uid;

    if not found then
      insert into public.vinetrack_entitlement_state
        (user_id, has_access, access_source, reason_code, plan_code, updated_at)
      values (v_uid, v_has, v_source, v_reason, v_plan_code, now());

      insert into public.vinetrack_entitlement_audit
        (user_id, event_type, previous_state, new_state, platform)
      values (
        v_uid,
        case when v_has then 'entitlement_granted' else 'entitlement_denied' end,
        null,
        jsonb_build_object(
          'has_access', v_has, 'access_source', v_source,
          'reason_code', v_reason, 'plan_code', v_plan_code
        ),
        'server'
      );
    elsif v_prev_has is distinct from v_has
       or v_prev_source is distinct from v_source
       or v_prev_reason is distinct from v_reason then

      v_event := case
        when v_has and not coalesce(v_prev_has, false) then 'entitlement_granted'
        when not v_has and coalesce(v_prev_has, false) then
          case v_reason
            when 'expired' then 'entitlement_expired'
            when 'revoked' then 'entitlement_revoked'
            else 'entitlement_denied'
          end
        else 'entitlement_source_changed'
      end;

      update public.vinetrack_entitlement_state es
      set has_access    = v_has,
          access_source = v_source,
          reason_code   = v_reason,
          plan_code     = v_plan_code,
          updated_at    = now()
      where es.user_id = v_uid;

      insert into public.vinetrack_entitlement_audit
        (user_id, event_type, previous_state, new_state, platform)
      values (
        v_uid,
        v_event,
        jsonb_build_object(
          'has_access', v_prev_has, 'access_source', v_prev_source,
          'reason_code', v_prev_reason
        ),
        jsonb_build_object(
          'has_access', v_has, 'access_source', v_source,
          'reason_code', v_reason, 'plan_code', v_plan_code
        ),
        'server'
      );
    end if;
  exception when others then
    null;
  end;

  -- ---- 6. Response (same 34 columns as SQL 144).
  return query select
    v_uid,
    v_has,
    v_source,
    coalesce(v_is_owner, false),
    v_sub_id,
    v_plan_code,
    v_plan_tier,
    v_plan_name,
    v_provider,
    v_status,
    v_trial_end,
    v_period_end,
    (v_has and coalesce(v_portal_level, 'none') <> 'none'),
    coalesce(v_portal_level, 'none'),
    v_has,
    (v_has and coalesce(v_portal_level, 'none') <> 'none'),
    v_seats_included,
    v_seats_purchased,
    coalesce(v_active_licences, 0),
    v_vineyard_id,
    v_licence_id,
    coalesce(v_unlimited, false),
    v_grant_reason,
    v_grant_expires,
    (not v_has),
    v_reason,
    coalesce(v_unlimited, false),
    v_has,
    now(),
    v_enforce,
    v_platform,
    coalesce(v_cancel_at_end, false),
    v_grace_end,
    v_expires_at;
end;
$$;

revoke all on function public.get_my_vinetrack_access() from public;
grant execute on function public.get_my_vinetrack_access() to authenticated;

comment on function public.get_my_vinetrack_access() is
  'SQL 156 shared entitlement resolver. Backward compatible with SQL 144 (same 34 columns). Precedence: own subscription/licence/grant > account trial > VINEYARD-BACKED access (any membership vineyard funded by a vineyard-wide grant, anchored subscription, or an active Owner''s own entitlement -> access_source=vineyard, reason_code=vineyard_entitlement, vineyard_id = funded vineyard) > denial. An expired vineyard can no longer blank the whole account.';

-- ---------------------------------------------------------------------------
-- F. _admin_effective_access — same signature; identical vineyard step so
--    the admin surface and entitlement-state writes never drift.
-- ---------------------------------------------------------------------------
create or replace function public._admin_effective_access(p_user_id uuid)
returns table (
  has_access              boolean,
  reason_code             text,
  subscription_id         uuid,
  plan_code               text,
  plan_tier               text,
  plan_name               text,
  billing_provider        text,
  status                  text,
  purchase_platform       text,
  environment             text,
  trial_end               timestamptz,
  current_period_end      timestamptz,
  cancel_at_period_end    boolean,
  grace_period_end        timestamptz,
  unlimited_licences      boolean,
  manual_grant_reason     text,
  manual_grant_expires_at timestamptz,
  is_owner                boolean,
  licence_id              uuid,
  vineyard_id             uuid,
  portal_access           boolean,
  portal_access_level     text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ua record;
  vb record;
begin
  select * into ua from public._user_level_access(p_user_id);

  if ua.has_access then
    return query select
      ua.has_access, ua.reason_code, ua.subscription_id, ua.plan_code,
      ua.plan_tier, ua.plan_name, ua.billing_provider, ua.status,
      ua.purchase_platform, ua.environment, ua.trial_end,
      ua.current_period_end, ua.cancel_at_period_end, ua.grace_period_end,
      ua.unlimited_licences, ua.manual_grant_reason,
      ua.manual_grant_expires_at, ua.is_owner, ua.licence_id,
      ua.vineyard_id, ua.portal_access, ua.portal_access_level;
    return;
  end if;

  -- SQL 156: vineyard-backed access — identical rules to the resolver.
  select mv.m_vineyard_id, ve.*
  into vb
  from (
    select vy.id as m_vineyard_id
    from public.vineyards vy
    left join public.vineyard_members vm
      on vm.vineyard_id = vy.id and vm.user_id = p_user_id
    where vy.deleted_at is null
      and (vm.user_id = p_user_id or vy.owner_id = p_user_id)
  ) mv
  cross join lateral public._vineyard_entitlement_for(mv.m_vineyard_id) ve
  where ve.has_entitlement
  order by ve.is_trial asc, ve.expires_at desc nulls first, mv.m_vineyard_id
  limit 1;

  if vb.m_vineyard_id is not null then
    return query select
      true, 'vineyard_entitlement'::text, null::uuid,
      vb.plan_code, 'vineyard'::text, vb.plan_name,
      'vineyard'::text, vb.subscription_status,
      null::text, null::text,
      case when vb.is_trial then vb.expires_at end,
      case when vb.is_trial then null::timestamptz else vb.expires_at end,
      false, null::timestamptz,
      false, null::text, null::timestamptz,
      false, null::uuid, vb.m_vineyard_id,
      true, 'basic'::text;
    return;
  end if;

  -- Own denial row (expired/revoked/no_entitlement classification).
  return query select
    ua.has_access, ua.reason_code, ua.subscription_id, ua.plan_code,
    ua.plan_tier, ua.plan_name, ua.billing_provider, ua.status,
    ua.purchase_platform, ua.environment, ua.trial_end,
    ua.current_period_end, ua.cancel_at_period_end, ua.grace_period_end,
    ua.unlimited_licences, ua.manual_grant_reason,
    ua.manual_grant_expires_at, ua.is_owner, ua.licence_id,
    ua.vineyard_id, ua.portal_access, ua.portal_access_level;
end;
$$;

revoke all on function public._admin_effective_access(uuid) from public;

comment on function public._admin_effective_access(uuid) is
  'SQL 156 internal: read-only mirror of the SQL 156 resolver — _user_level_access (subscriptions + account trial) plus the IDENTICAL vineyard-backed step (plan_tier/billing_provider=vineyard, reason_code=vineyard_entitlement). Never writes state/audit. No client execute grant.';

-- ---------------------------------------------------------------------------
-- G. admin_explain_vineyard_access — System Admin access diagnostics.
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
        when ve.has_entitlement then ve.reason_code
        else 'no_vineyard_entitlement'
      end,
      'access_source', case
        when v_role is null then 'none'
        when ua.has_access then 'account'
        when ve.has_entitlement then ve.access_source
        else 'none'
      end
    ),
    'account_access', jsonb_build_object(
      'has_access', ua.has_access,
      'reason_code', ua.reason_code,
      'access_source', coalesce(ua.plan_tier, 'none'),
      'plan_code', ua.plan_code,
      'subscription_id', ua.subscription_id,
      'trial_end', ua.trial_end,
      'current_period_end', ua.current_period_end,
      'manual_grant_expires_at', ua.manual_grant_expires_at
    ),
    'vineyard_entitlement', jsonb_build_object(
      'has_entitlement', ve.has_entitlement,
      'access_source', ve.access_source,
      'grant_scope', case when ve.is_vineyard_wide then 'vineyard' else 'user' end,
      'plan_code', ve.plan_code,
      'subscription_id', ve.subscription_id,
      'subscription_status', ve.subscription_status,
      'billing_owner_user_id', ve.billing_owner_user_id,
      'starts_at', ve.starts_at,
      'expires_at', ve.expires_at,
      'is_trial', ve.is_trial
    ),
    'inheriting_members', case
      when ve.has_entitlement and ve.is_vineyard_wide then coalesce((
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
  'SQL 156: System-Admin diagnostics — why can/can''t this user access this vineyard, which entitlement funds it, who inherits a vineyard-wide grant (cap 200), cached vs computed entitlement state and mismatch_type. No tokens, receipts or device identifiers.';

commit;

-- =====================================================================
-- VERIFICATION (run after commit):
--   select public.get_my_vineyard_access_matrix();           -- as any user
--   select public.get_my_vineyard_access('<vineyard-uuid>');
--   select access_source, reason_code, vineyard_id
--     from public.get_my_vinetrack_access();
--   select public.admin_explain_vineyard_access('<user>', '<vineyard>');
-- Expected:
--   * member of an Owner-trial vineyard with own expired trial:
--       has_supabase_access=true, access_source='vineyard'
--   * user whose only vineyard expired:
--       account_access_state='restricted', matrix row has_vineyard_access=false
--   * expired Vineyard A + funded Vineyard B:
--       A row false, B row true, has_any_accessible_vineyard=true
-- =====================================================================
