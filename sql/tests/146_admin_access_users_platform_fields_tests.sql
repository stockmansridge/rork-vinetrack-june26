-- =====================================================================
-- 146_admin_access_users_platform_fields_tests.sql — Phase 2C.2 tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/146. Everything runs
-- inside ONE transaction that is ROLLED BACK — no production data is
-- touched. Expected final output:
--   NOTICE: SQL 146 platform-field tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 146 is applied.
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_access_users'
      and pg_get_function_result(p.oid) ilike '%can_use_android_app%'
  ) then
    raise exception 'SQL 146 not applied — run sql/146_admin_access_users_platform_fields.sql first.';
  end if;
end$$;

do $$
declare
  u_admin   uuid;  -- system admin (caller)
  u_trial   uuid;  -- created today -> active account trial
  u_expired uuid;  -- 6 months old, no entitlement -> expired trial
  u_internal uuid; -- 6 months old + Internal Unlimited
  u_apple   uuid;  -- 6 months old + valid Apple purchase
  u_google  uuid;  -- 6 months old + valid Google purchase
  u_lic     uuid;  -- 6 months old + assigned Team licence
  u_revoked uuid;  -- 6 months old + revoked manual grant, nothing else
  plan_internal uuid;
  plan_team     uuid;
  plan_solo     uuid;
  s_team    uuid;
  r         record;
  ea        record;
  d         jsonb;
  n         bigint;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't146-admin@test.local',    'x', now(), now() - interval '1 year',   now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't146-trial@test.local',    'x', now(), now(),                        now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't146-expired@test.local',  'x', now(), now() - interval '6 months',  now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't146-internal@test.local', 'x', now(), now() - interval '6 months',  now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't146-apple@test.local',    'x', now(), now() - interval '6 months',  now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't146-google@test.local',   'x', now(), now() - interval '6 months',  now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't146-lic@test.local',      'x', now(), now() - interval '6 months',  now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't146-revoked@test.local',  'x', now(), now() - interval '6 months',  now());
  select id into u_admin    from auth.users where email = 't146-admin@test.local';
  select id into u_trial    from auth.users where email = 't146-trial@test.local';
  select id into u_expired  from auth.users where email = 't146-expired@test.local';
  select id into u_internal from auth.users where email = 't146-internal@test.local';
  select id into u_apple    from auth.users where email = 't146-apple@test.local';
  select id into u_google   from auth.users where email = 't146-google@test.local';
  select id into u_lic      from auth.users where email = 't146-lic@test.local';
  select id into u_revoked  from auth.users where email = 't146-revoked@test.local';

  select id into plan_internal from public.vinetrack_plans where code = 'internal_unlimited';
  select id into plan_team     from public.vinetrack_plans where code = 'team';
  select id into plan_solo     from public.vinetrack_plans where code = 'solo';
  if plan_internal is null or plan_team is null or plan_solo is null then
    raise exception 'plan catalogue missing internal_unlimited/team/solo';
  end if;

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  -- Internal Unlimited grant.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, unlimited_licences, started_at)
  values (u_internal, plan_internal, 'manual', 'manual', 0, true, now() - interval '1 day');

  -- Valid verified Apple purchase.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     current_period_start, current_period_end, started_at, seats_included)
  values (u_apple, plan_solo, 'apple', 'ios', 'production', 'active',
          now() - interval '1 day', now() + interval '30 days', now() - interval '1 day', 1);

  -- Valid verified Google purchase.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     current_period_start, current_period_end, started_at, seats_included)
  values (u_google, plan_solo, 'google', 'android', 'production', 'active',
          now() - interval '1 day', now() + interval '30 days', now() - interval '1 day', 1);

  -- Team pool owned by the admin; licence assigned to u_lic.
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, started_at,
     current_period_start, current_period_end)
  values (u_admin, plan_team, 'stripe', 'active', 3, now() - interval '1 day',
          now() - interval '1 day', now() + interval '30 days')
  returning id into s_team;
  insert into public.vinetrack_user_licences (subscription_id, user_id, status)
  values (s_team, u_lic, 'active');

  -- Revoked manual grant with no fallback (account is 6 months old, so the
  -- trial is expired too — the more specific 'revoked' denial must win).
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included,
     unlimited_licences, started_at, manual_grant_revoked_at)
  values (u_revoked, plan_internal, 'manual', 'manual', 0, true,
          now() - interval '2 months', now() - interval '1 month');

  -- ---- T1. Non-admin call remains rejected -------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_trial::text, 'role', 'authenticated')::text, true);
  begin
    perform * from public.admin_access_users(p_limit => 1);
    raise exception 'T1: non-admin call must be rejected';
  exception when insufficient_privilege then
    null;
  end;
  raise notice 'T1 passed: non-admin call rejected (42501)';

  -- All remaining calls as the System Admin.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  -- ---- T2. Active account trial: all three platforms true ----------------
  select * into r from public.admin_access_users(p_search => 't146-trial@');
  assert r.user_id = u_trial,                'T2: trial user found';
  assert r.has_access = true and r.reason_code = 'active_trial',
                                             'T2: active trial grants, got ' || r.reason_code;
  assert r.portal_access = true,             'T2: portal_access true';
  assert r.can_use_ios_app = true,           'T2: can_use_ios_app true';
  assert r.can_use_android_app = true,       'T2: can_use_android_app true';
  raise notice 'T2 passed: active trial -> portal + iOS + Android';

  -- ---- T3. Internal Unlimited: all three true -----------------------------
  select * into r from public.admin_access_users(p_search => 't146-internal@');
  assert r.reason_code = 'internal_unlimited', 'T3: reason, got ' || r.reason_code;
  assert r.portal_access and r.can_use_ios_app and r.can_use_android_app,
                                             'T3: Internal Unlimited -> all three true';
  raise notice 'T3 passed: Internal Unlimited -> all three true';

  -- ---- T4. Valid Apple purchase: all three true ---------------------------
  select * into r from public.admin_access_users(p_search => 't146-apple@');
  assert r.reason_code = 'app_store_subscription' and r.purchase_platform = 'ios',
                                             'T4: Apple source, got ' || r.reason_code;
  assert r.portal_access and r.can_use_ios_app and r.can_use_android_app,
                                             'T4: Apple purchase -> all three true';
  raise notice 'T4 passed: Apple purchase -> all three true (cross-platform)';

  -- ---- T5. Valid Google purchase: all three true --------------------------
  select * into r from public.admin_access_users(p_search => 't146-google@');
  assert r.reason_code = 'app_store_subscription' and r.purchase_platform = 'android',
                                             'T5: Google source, got ' || r.reason_code;
  assert r.portal_access and r.can_use_ios_app and r.can_use_android_app,
                                             'T5: Google purchase -> all three true';
  raise notice 'T5 passed: Google purchase -> all three true (cross-platform)';

  -- ---- T6. Assigned licence: exactly the resolver-approved values ---------
  select * into r  from public.admin_access_users(p_search => 't146-lic@');
  select * into ea from public._admin_effective_access(u_lic);
  assert r.reason_code = 'assigned_licence',  'T6: licence source, got ' || r.reason_code;
  assert r.portal_access = (ea.has_access and ea.portal_access),
                                             'T6: portal_access matches resolver expression';
  assert r.can_use_ios_app = ea.has_access,  'T6: can_use_ios_app = has_access';
  assert r.can_use_android_app = ea.has_access, 'T6: can_use_android_app = has_access';
  assert r.portal_access and r.can_use_ios_app and r.can_use_android_app,
                                             'T6: valid licence -> all three true';
  raise notice 'T6 passed: assigned licence -> resolver-approved values (all true)';

  -- ---- T7. Expired trial, no other entitlement: all three false ----------
  select * into r from public.admin_access_users(p_search => 't146-expired@');
  assert r.has_access = false and r.reason_code = 'expired',
                                             'T7: expired trial denies, got ' || r.reason_code;
  assert r.portal_access = false and r.can_use_ios_app = false and r.can_use_android_app = false,
                                             'T7: expired trial -> all three false';
  raise notice 'T7 passed: expired trial -> all three false';

  -- ---- T8. Revoked grant, no fallback: all three false --------------------
  select * into r from public.admin_access_users(p_search => 't146-revoked@');
  assert r.has_access = false and r.reason_code = 'revoked',
                                             'T8: revoked grant denies, got ' || r.reason_code;
  assert r.portal_access = false and r.can_use_ios_app = false and r.can_use_android_app = false,
                                             'T8: revoked grant -> all three false';
  raise notice 'T8 passed: revoked grant -> all three false';

  -- ---- T9. Higher-priority entitlement overrides an expired trial ---------
  -- u_apple, u_google and u_lic are all 6 months old (trial expired), yet
  -- T4/T5/T6 proved they resolve TRUE via their paid/licensed source.
  select count(*) into n
  from public.admin_access_users(p_search => 't146-')
  where user_id in (u_apple, u_google, u_lic)
    and has_access and portal_access and can_use_ios_app and can_use_android_app;
  assert n = 3, 'T9: paid/licensed sources must override the expired trial, got ' || n;
  raise notice 'T9 passed: higher-priority sources override the expired trial';

  -- ---- T10. Directory matches admin_user_access_detail for EVERY fixture --
  for r in
    select * from public.admin_access_users(p_search => 't146-', p_limit => 200)
  loop
    assert r.portal_access is not null
       and r.can_use_ios_app is not null
       and r.can_use_android_app is not null,
      'T10: platform booleans must be non-null for ' || r.email;

    d := public.admin_user_access_detail(r.user_id) -> 'effective_access';
    assert r.portal_access = (d ->> 'portal_access')::boolean,
      'T10: portal_access mismatch vs detail for ' || r.email;
    assert r.can_use_ios_app = (d ->> 'can_use_ios_app')::boolean,
      'T10: can_use_ios_app mismatch vs detail for ' || r.email;
    assert r.can_use_android_app = (d ->> 'can_use_android_app')::boolean,
      'T10: can_use_android_app mismatch vs detail for ' || r.email;
  end loop;
  raise notice 'T10 passed: directory booleans non-null and identical to admin_user_access_detail';

  raise notice 'SQL 146 platform-field tests: ALL PASSED';
end$$;

rollback;
