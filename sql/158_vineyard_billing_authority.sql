-- =====================================================================
-- 158_vineyard_billing_authority.sql
-- =====================================================================
-- Phase 2F.2 — role-aware restricted-vineyard messaging support.
--
-- WHY:
--   The restricted-vineyard screens (iOS / Android / portal) must show a
--   different message to:
--     * the Owner who can actually fix billing for that vineyard
--       (Solo -> Team upgrade explanation + an upgrade action), and
--     * a co-Owner who holds the 'owner' role but does NOT control this
--       vineyard's billing (no purchase action, no billing-owner identity).
--
--   SQL 156/157 already return:
--     can_manage_billing = (membership_role = 'owner')     -- true for BOTH
--     is_billing_owner   = (funding subscription owner = me)
--   but a DENIED vineyard has no funding subscription, so
--   billing_owner_user_id is null and is_billing_owner is false for every
--   Owner. The clients therefore cannot distinguish the two audiences.
--
-- WHAT THIS MIGRATION CHANGES (purely additive — no access decision, no
-- data and no existing key changes):
--   ONE new boolean key on get_my_vineyard_access_matrix() rows and on
--   get_my_vineyard_access(uuid):
--
--     is_billing_authority
--       = membership_role = 'owner'
--         AND ( I am the vineyard's owner of record (vineyards.owner_id)
--               OR I own the entitlement currently funding it )
--
--   It is a PRESENTATION signal only. Entitlement precedence, has_vineyard_
--   access, reason codes and every other key are byte-for-byte identical to
--   SQL 157 — the function bodies below are SQL 157's with the single extra
--   key added, so the resolver remains the one source of truth.
--
--   Never exposes WHO the other billing owner is: a co-Owner simply gets
--   is_billing_authority=false.
--
-- ROLLBACK (non-destructive):
--   re-run sql/157 sections D1 and D2.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public._vineyard_entitlement_for(uuid)') is null
     or to_regprocedure('public._user_level_access(uuid)') is null then
    raise exception 'SQL 158 precondition failed: apply sql/156 and sql/157 first';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- A. get_my_vineyard_access_matrix — SQL 157 body + is_billing_authority.
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
      vy.id       as m_vineyard_id,
      vy.name     as m_vineyard_name,
      vy.owner_id as m_owner_of_record,
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
      -- NEW (sql/158): presentation-only. Owner role AND (owner of record
      -- OR the funding entitlement is mine). A co-Owner without billing
      -- authority gets false and never sees a purchase action.
      'is_billing_authority',   (
                                  d.m_role = 'owner'
                                  and (
                                    coalesce(d.billing_owner_user_id = v_uid, false)
                                    or coalesce(d.m_owner_of_record = v_uid, false)
                                  )
                                ),
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
  'SQL 158 (SQL 157 contract + one additive key): per-vineyard access matrix for the AUTHENTICATED caller. NEW is_billing_authority = owner role AND (vineyard owner of record OR owner of the funding entitlement) — presentation only, used by the restricted-vineyard screens to show the Solo->Team upgrade action to the responsible Owner and a "managed by another Owner" message to co-Owners. Access decisions, reason codes (incl. owner_plan_not_vineyard_funding) and every other key are unchanged.';

-- ---------------------------------------------------------------------------
-- B. get_my_vineyard_access(p_vineyard_id) — same single additive key.
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
  v_role  text;
  v_name  text;
  v_owner uuid;
  v_has   boolean;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_vineyard_id is null then
    raise exception 'vineyard_required' using errcode = '22023';
  end if;

  select coalesce(vm.role, case when vy.owner_id = v_uid then 'owner' end),
         vy.name,
         vy.owner_id
    into v_role, v_name, v_owner
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
    'is_billing_authority',   (
                                v_role = 'owner'
                                and (
                                  coalesce(ve.billing_owner_user_id = v_uid, false)
                                  or coalesce(v_owner = v_uid, false)
                                )
                              ),
    'can_enter_vineyard',     v_has,
    'requires_billing_attention', (not v_has and v_role = 'owner'),
    'last_verified_at',       now()
  );
end;
$$;

revoke all on function public.get_my_vineyard_access(uuid) from public;
grant execute on function public.get_my_vineyard_access(uuid) to authenticated;

comment on function public.get_my_vineyard_access(uuid) is
  'SQL 158 (SQL 157 contract + one additive key): single-vineyard access decision for the AUTHENTICATED caller, identical rules to the matrix, plus is_billing_authority for role-aware restricted-vineyard messaging. Non-members still receive has_vineyard_access=false / reason not_a_member with no vineyard details.';

commit;
