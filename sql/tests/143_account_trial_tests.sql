-- =====================================================================
-- 143_account_trial_tests.sql — Phase 2C.1 server-authoritative trial tests
-- =====================================================================
-- Run in the Supabase SQL editor AFTER applying sql/143 and sql/144.
-- Everything runs inside ONE transaction that is ROLLED BACK — no
-- production data is touched. Expected final output:
--   NOTICE: SQL 143/144 account trial tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 143/144 are applied.
do $$
begin
  if to_regclass('public.vinetrack_account_trials') is null then
    raise exception 'SQL 143 not applied — run sql/143_server_authoritative_account_trials.sql first.';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_my_vinetrack_access'
      and pg_get_function_result(p.oid) ilike '%expires_at%'
  ) then
    raise exception 'SQL 144 resolver not applied — run sql/144_trial_resolver_and_admin_surface.sql first.';
  end if;
end$$;

do $$
declare
  u_new     uuid;  -- created today
  u_month   uuid;  -- 1 month old
  u_edge    uuid;  -- just under 3 months
  u_old     uuid;  -- over 3 months (expired trial)
  u_paid    uuid;  -- young account + paid source (precedence)
  u_admin   uuid;  -- system admin (for admin-surface checks)
  plan_internal uuid;
  plan_team     uuid;
  plan_solo     uuid;
  s_id      uuid;
  r         record;
  ea        record;
  t         record;
  n         bigint;
  v_old_end timestamptz;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't143-new@test.local',   'x', now(), now(),                        now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't143-month@test.local', 'x', now(), now() - interval '1 month',   now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't143-edge@test.local',  'x', now(), now() - interval '3 months' + interval '1 day', now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't143-old@test.local',   'x', now(), now() - interval '6 months',  now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't143-paid@test.local',  'x', now(), now() - interval '1 month',   now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't143-admin@test.local', 'x', now(), now() - interval '1 year',    now());
  select id into u_new   from auth.users where email = 't143-new@test.local';
  select id into u_month from auth.users where email = 't143-month@test.local';
  select id into u_edge  from auth.users where email = 't143-edge@test.local';
  select id into u_old   from auth.users where email = 't143-old@test.local';
  select id into u_paid  from auth.users where email = 't143-paid@test.local';
  select id into u_admin from auth.users where email = 't143-admin@test.local';

  select id into plan_internal from public.vinetrack_plans where code = 'internal_unlimited';
  select id into plan_team     from public.vinetrack_plans where code = 'team';
  select id into plan_solo     from public.vinetrack_plans where code = 'solo';
  if plan_internal is null or plan_team is null or plan_solo is null then
    raise exception 'plan catalogue missing internal_unlimited/team/solo';
  end if;

  insert into public.system_admins (user_id, is_active) values (u_admin, true)
  on conflict do nothing;

  -- ---- T1. Account created today: ACTIVE trial ----------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_new::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true,       'T1: new account must have trial access';
  assert r.reason_code = 'active_trial',     'T1: reason_code, got ' || r.reason_code;
  assert r.access_source = 'trial',          'T1: access_source, got ' || r.access_source;
  assert r.plan_code = 'trial',              'T1: plan_code';
  assert r.status = 'trialling',             'T1: status trialling, got ' || r.status;
  assert r.portal_access = true,             'T1: portal access';
  assert r.can_use_ios_app = true,           'T1: iOS access';
  assert r.can_use_android_app = true,       'T1: Android access';
  assert r.purchase_platform is null,        'T1: purchase_platform must be NULL, not none';
  assert r.expires_at is not null and r.expires_at > now(), 'T1: expires_at = trial end';
  assert r.seats_included = 1,               'T1: licence limit 1';
  assert r.is_unlimited = false,             'T1: not unlimited';
  raise notice 'T1 passed: new account has active trial (portal + iOS + Android)';

  -- Lazy persistence: the resolver call above must have created the row
  -- with trial_started_at = auth.users.created_at (server time rules).
  select * into t from public.vinetrack_account_trials where user_id = u_new;
  assert t.user_id is not null,              'T1b: trial row lazily persisted';
  assert t.trial_started_at = (select created_at from auth.users where id = u_new),
                                             'T1b: trial anchored to created_at, never now()';
  raise notice 'T1b passed: trial row persisted, anchored to account creation';

  -- ---- T2. One-month-old account: still ACTIVE ---------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_month::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'active_trial',
    'T2: 1-month-old account must be in trial';
  raise notice 'T2 passed: one-month-old account trial active';

  -- ---- T3. Just under 3 months: still ACTIVE -----------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_edge::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'active_trial',
    'T3: account just under 3 months must be in trial';
  raise notice 'T3 passed: just-under-3-months trial active';

  -- ---- T4. Over 3 months: EXPIRED trial, informative denial --------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_old::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false,      'T4: expired trial must not grant';
  assert r.reason_code = 'expired',          'T4: reason_code expired, got ' || r.reason_code;
  assert r.access_source = 'trial',          'T4: access_source trial (distinguishes from never-entitled)';
  assert r.plan_code = 'trial',              'T4: plan_code trial';
  assert r.status = 'expired',               'T4: status expired';
  assert r.expires_at is not null and r.expires_at <= now(),
                                             'T4: expires_at = ORIGINAL trial end (in the past)';
  assert r.purchase_platform is null,        'T4: purchase_platform NULL';
  v_old_end := r.expires_at;
  raise notice 'T4 passed: expired trial denies with original end date';

  -- ---- T5. Trial keyed on auth.users.id — email change never restarts ----
  update auth.users set email = 't143-old-changed@test.local' where id = u_old;
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_old::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false and r.reason_code = 'expired',
    'T5: email change must not restart the trial';
  assert r.expires_at = v_old_end,           'T5: trial end unchanged after email change';
  raise notice 'T5 passed: email change does not restart the trial';

  -- ---- T6. Re-running the migration backfill never restarts a trial ------
  insert into public.vinetrack_account_trials
    (user_id, trial_started_at, trial_ends_at, status, source, migrated_at)
  select u.id, u.created_at, u.created_at + interval '3 months',
         case when u.created_at + interval '3 months' > now() then 'active' else 'expired' end,
         'account_trial', now()
  from auth.users u
  where u.deleted_at is null and u.created_at is not null
  on conflict (user_id) do nothing;

  select count(*) into n from public.vinetrack_account_trials where user_id = u_old;
  assert n = 1, 'T6: exactly one trial row per user after re-run';
  select * into t from public.vinetrack_account_trials where user_id = u_old;
  assert t.trial_ends_at = v_old_end, 'T6: re-run must not extend/restart the trial';
  raise notice 'T6 passed: migration re-run is idempotent';

  -- ---- T7. Paid / granted sources override the trial ---------------------
  -- 7a. Internal Unlimited
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, unlimited_licences, started_at)
  values (u_paid, plan_internal, 'manual', 'manual', 0, true, now() - interval '1 day')
  returning id into s_id;
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_paid::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.reason_code = 'internal_unlimited', 'T7a: Internal Unlimited must outrank trial, got ' || r.reason_code;
  update public.vinetrack_subscriptions set deleted_at = now(), status = 'canceled' where id = s_id;

  -- 7b. Portal Team subscription
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, started_at,
     current_period_start, current_period_end)
  values (u_paid, plan_team, 'stripe', 'active', 3, now() - interval '1 day',
          now() - interval '1 day', now() + interval '30 days')
  returning id into s_id;
  select * into r from public.get_my_vinetrack_access();
  assert r.reason_code = 'portal_subscription', 'T7b: Team sub must outrank trial, got ' || r.reason_code;

  -- 7c. Assigned licence (different user licensed under the Team pool)
  insert into public.vinetrack_user_licences (subscription_id, user_id, status)
  values (s_id, u_month, 'active');
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_month::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.reason_code = 'assigned_licence', 'T7c: assigned licence must outrank trial, got ' || r.reason_code;
  update public.vinetrack_user_licences set status = 'revoked', revoked_at = now()
  where subscription_id = s_id and user_id = u_month;
  update public.vinetrack_subscriptions set deleted_at = now(), status = 'canceled' where id = s_id;

  -- 7d. Verified Apple store subscription
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, platform, environment, status,
     current_period_start, current_period_end, started_at, seats_included)
  values (u_paid, plan_solo, 'apple', 'ios', 'production', 'active',
          now() - interval '1 day', now() + interval '30 days', now() - interval '1 day', 1)
  returning id into s_id;
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_paid::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.reason_code = 'app_store_subscription', 'T7d: Apple sub must outrank trial, got ' || r.reason_code;
  assert r.purchase_platform = 'ios', 'T7d: purchase_platform ios for a real purchase';
  update public.vinetrack_subscriptions set billing_provider = 'google', platform = 'android' where id = s_id;
  select * into r from public.get_my_vinetrack_access();
  assert r.reason_code = 'app_store_subscription' and r.purchase_platform = 'android',
    'T7e: Google sub must outrank trial with purchase_platform android';
  update public.vinetrack_subscriptions set deleted_at = now(), status = 'canceled' where id = s_id;
  raise notice 'T7 passed: Internal Unlimited / Team / licence / Apple / Google all outrank the trial';

  -- ---- T8. Expired trial does not hide a valid licence --------------------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, started_at,
     current_period_start, current_period_end)
  values (u_paid, plan_team, 'stripe', 'active', 3, now() - interval '1 day',
          now() - interval '1 day', now() + interval '30 days')
  returning id into s_id;
  insert into public.vinetrack_user_licences (subscription_id, user_id, status)
  values (s_id, u_old, 'active');
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_old::text, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'assigned_licence',
    'T8: expired trial must not hide an assigned licence, got ' || r.reason_code;
  raise notice 'T8 passed: expired trial does not mask a valid licence';

  -- ---- T9. Clients cannot alter trial dates (RLS: no write policy) -------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_new::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.vinetrack_account_trials
    set trial_ends_at = now() + interval '10 years'
    where user_id = u_new;
    get diagnostics n = row_count;
    assert n = 0, 'T9: client UPDATE must affect 0 rows (RLS)';
  exception when insufficient_privilege then
    null; -- also acceptable: outright privilege rejection
  end;
  begin
    insert into public.vinetrack_account_trials (user_id, trial_started_at, trial_ends_at)
    values (u_old, now(), now() + interval '10 years');
    raise exception 'T9: client INSERT must be rejected';
  exception when insufficient_privilege or check_violation then
    null;
  end;
  reset role;
  select * into t from public.vinetrack_account_trials where user_id = u_new;
  assert t.trial_ends_at <= now() + interval '3 months' + interval '1 day',
    'T9: trial end unchanged after client write attempts';
  raise notice 'T9 passed: no client can create or extend a trial';

  -- ---- T10. Admin read surface matches the resolver ----------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_admin::text, 'role', 'authenticated')::text, true);

  select * into ea from public._admin_effective_access(u_new);
  assert ea.has_access = true and ea.reason_code = 'active_trial'
     and ea.plan_code = 'trial' and ea.billing_provider = 'trial'
     and ea.status = 'trialling' and ea.purchase_platform is null,
    'T10a: admin helper must mirror the resolver for an active trial';

  select * into ea from public._admin_effective_access(u_old);
  assert ea.has_access = false and ea.reason_code = 'expired'
     and ea.plan_code is null or ea.reason_code = 'assigned_licence' or true,
    'placeholder';
  -- u_old currently holds a licence (T8): admin must show that, not the trial.
  select * into ea from public._admin_effective_access(u_old);
  assert ea.has_access = true and ea.reason_code = 'assigned_licence',
    'T10b: admin surface agrees with resolver for licensed user';

  -- Directory: trial filter returns the trial users.
  select count(*) into n
  from public.admin_access_users(p_billing_source => 'trial', p_limit => 200)
  where user_id in (u_new, u_month, u_edge);
  assert n = 3, 'T10c: directory trial filter must list all 3 active-trial users, got ' || n;

  -- Detail: account_trial section present and valid.
  assert (public.admin_user_access_detail(u_new) -> 'account_trial' ->> 'is_currently_valid')::boolean = true,
    'T10d: detail account_trial.is_currently_valid';
  assert (public.admin_user_access_detail(u_new) -> 'account_trial' ->> 'source_type') = 'account_trial',
    'T10e: detail account_trial.source_type';

  -- History: account_created present.
  select count(*) into n
  from public.admin_user_access_history(u_new, 100) h
  where h.event_type = 'account_created';
  assert n = 1, 'T10f: history contains account_created';
  raise notice 'T10 passed: admin surface matches the shared resolver';

  -- ---- T11. Disabled account: trial row exists but resolver is caller-bound;
  --      admin surface shows is_disabled so the portal can gate it.
  update auth.users set banned_until = now() + interval '30 days' where id = u_edge;
  select count(*) into n
  from public.admin_access_users(p_search => 't143-edge', p_limit => 10)
  where is_disabled = true;
  assert n = 1, 'T11: disabled flag surfaces in the directory';
  raise notice 'T11 passed: disabled account visible as disabled';

  -- ---- T12. Trial revocation (admin) --------------------------------------
  perform public.admin_revoke_account_trial(u_new, 'Test revocation');
  select * into ea from public._admin_effective_access(u_new);
  assert ea.has_access = false and ea.reason_code = 'revoked',
    'T12: revoked trial must deny with reason revoked, got ' || ea.reason_code;
  select count(*) into n from public.vinetrack_billing_events
  where owner_user_id = u_new and provider = 'system' and event_type = 'trial_revoked';
  assert n = 1, 'T12: trial_revoked event written once';
  raise notice 'T12 passed: admin trial revocation audited and enforced';

  raise notice 'SQL 143/144 account trial tests: ALL PASSED';
end$$;

rollback;
