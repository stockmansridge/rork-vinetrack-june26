-- =====================================================================
-- tests/132_live_jonathan_single_result.sql
-- =====================================================================
-- Phase 2A §2 — Jonathan live validation returned as ONE JSON object,
-- because the Supabase SQL editor only displays the LAST statement's
-- result (which is why the earlier block-by-block script appeared to
-- show only the feature-flag query).
--
-- HOW TO RUN: paste the WHOLE script into the Supabase SQL editor and
-- run it once. The final SELECT is the last statement, so the editor
-- shows the complete combined result.
--
-- Impersonation safety (resolver check):
--   * public.get_my_vinetrack_access() decides from auth.uid(), so the
--     DO block below sets request.jwt.claims to Jonathan's auth user id
--     with is_local = true (transaction-scoped), calls the resolver,
--     and IMMEDIATELY resets the claims to '' — no later statement in
--     this session runs as Jonathan, and nothing persists afterwards.
--   * The script modifies no billing/auth data. The only possible write
--     is the resolver's own change-detected audit; if Jonathan's
--     effective state is unchanged since the last call (expected), it
--     writes nothing.
--
-- Do NOT hard-code this email into any application logic — it is used
-- here only as a one-off diagnostic lookup key.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Impersonated resolver call, captured into a temp table so the
--    final SELECT can include it. Temp table dies with the session.
-- ---------------------------------------------------------------------
do $$
declare
  v_uid uuid;
begin
  create temp table if not exists _jonathan_resolver (result jsonb);
  delete from _jonathan_resolver;

  select id into v_uid
  from auth.users
  where lower(email) = lower('jonathan@stockmansridge.com.au');

  if v_uid is not null then
    -- Impersonate Jonathan (transaction-local setting).
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub', v_uid, 'role', 'authenticated')::text,
      true
    );

    insert into _jonathan_resolver (result)
    select to_jsonb(r) from public.get_my_vinetrack_access() r;

    -- Reset impersonation immediately — auth.uid() is NULL again from here.
    perform set_config('request.jwt.claims', '', true);
  end if;
end$$;

-- ---------------------------------------------------------------------
-- 2. One combined result. This MUST remain the last statement so the
--    SQL editor displays it.
-- ---------------------------------------------------------------------
with u as (
  select id, email_confirmed_at
  from auth.users
  where lower(email) = lower('jonathan@stockmansridge.com.au')
),
g as (
  -- Best internal/manual grant OWNED BY that exact auth user id.
  -- (Grants are linked by owner_user_id, so grant_exists = true here
  --  also proves auth_user_id_matches_grant.)
  select s.status,
         p.code as plan_code,
         s.started_at,
         s.manual_grant_expires_at,
         s.manual_grant_revoked_at,
         (s.deleted_at is null
          and coalesce(s.unlimited_licences, false)
          and s.status in ('trialing','active','manual','past_due')
          and s.manual_grant_revoked_at is null
          and (s.manual_grant_expires_at is null or s.manual_grant_expires_at > now())
          and (s.started_at is null or s.started_at <= now())) as is_live
  from public.vinetrack_subscriptions s
  join public.vinetrack_plans p on p.id = s.plan_id
  join u on u.id = s.owner_user_id
  where s.deleted_at is null
    and (coalesce(s.unlimited_licences, false)
         or p.code = 'internal_unlimited'
         or s.manual_grant_reason is not null)
  order by (s.manual_grant_revoked_at is null) desc, s.updated_at desc, s.id
  limit 1
),
vm as (
  select v.name as vineyard_name, m.role
  from public.vineyard_members m
  join public.vineyards v on v.id = m.vineyard_id
  join u on u.id = m.user_id
  order by m.joined_at asc nulls last
  limit 1
),
sa as (
  select exists (
    select 1
    from public.system_admins s
    join u on u.id = s.user_id
    where s.is_active = true
  ) as is_admin
),
ff as (
  select is_enabled, value
  from public.system_feature_flags
  where key = 'use_shared_supabase_entitlement'
),
r as (
  select result from _jonathan_resolver limit 1
)
select jsonb_pretty(jsonb_build_object(
  -- Auth
  'auth_user_exists',              exists (select 1 from u),
  'email_confirmed',               coalesce((select email_confirmed_at is not null from u), false),
  -- Grant (linked by auth.users.id, never by email)
  'auth_user_id_matches_grant',    exists (select 1 from g),
  'grant_exists',                  exists (select 1 from g),
  'grant_status',                  (select status from g),
  'plan_code',                     (select plan_code from g),
  'grant_started',                 coalesce((select started_at is null or started_at <= now() from g), false),
  'grant_expired',                 coalesce((select manual_grant_expires_at is not null
                                                and manual_grant_expires_at <= now() from g), false),
  'grant_revoked',                 coalesce((select manual_grant_revoked_at is not null from g), false),
  'manual_grant_expires_at',       (select manual_grant_expires_at from g),
  -- Vineyard membership + role
  'vineyard_membership_exists',    exists (select 1 from vm),
  'vineyard_name',                 (select vineyard_name from vm),
  'membership_role',               (select role from vm),
  -- Rollout cohort
  'is_system_admin',               (select is_admin from sa),
  'qualifies_for_internal_cohort', (
      (select is_admin from sa)
      or coalesce((select is_live from g), false)
      or lower(coalesce((select value->>'cohort' from ff), 'internal')) = 'all'
      or exists (
           select 1
           from ff, u,
                jsonb_array_elements_text(coalesce(ff.value->'user_ids', '[]'::jsonb)) t(uid)
           where t.uid = u.id::text
         )
  ),
  'feature_flag_enabled',          coalesce((select is_enabled from ff), false),
  -- Resolver output (executed AS Jonathan via auth.uid() impersonation)
  'resolver_has_access',           (select (result->>'has_supabase_access')::boolean from r),
  'resolver_reason_code',          (select result->>'reason_code' from r),
  'resolver_plan_code',            (select result->>'plan_code' from r),
  'resolver_is_unlimited',         (select (result->>'is_unlimited')::boolean from r),
  'resolver_ios_access',           (select (result->>'can_use_ios_app')::boolean from r),
  'resolver_android_access',       (select (result->>'can_use_android_app')::boolean from r),
  'resolver_portal_access',        (select (result->>'can_use_portal')::boolean from r),
  'resolver_enforcement_enabled',  (select (result->>'enforcement_enabled')::boolean from r),
  'resolver_last_verified_at',     (select result->>'last_verified_at' from r),
  -- Server timestamp of this check
  'checked_at',                    now()
)) as jonathan_live_validation;
