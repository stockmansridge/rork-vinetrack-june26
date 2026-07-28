-- =====================================================================
-- tests/132_entitlement_resolver_tests.sql
-- =====================================================================
-- Database tests for the SQL 132 hardened get_my_vinetrack_access().
--
-- HOW TO RUN: paste the whole file into the Supabase SQL editor and run.
-- Everything happens inside one transaction that is ROLLED BACK at the
-- end — no production data is created, modified, or kept.
--
-- NOT an auto-applied migration (it fabricates auth.users rows), which is
-- why it lives in sql/tests/ rather than the numbered stream.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Fixtures: two throwaway users + plans lookup.
-- ---------------------------------------------------------------------
do $$
declare
  u1 uuid := '00000000-0000-4000-8000-000000000101'; -- primary test user
  u2 uuid := '00000000-0000-4000-8000-000000000102'; -- "other user"
  plan_internal uuid;
  plan_team     uuid;
  plan_solo     uuid;
  sub_id uuid;
  r record;

  procedure_impersonate constant text := '';
begin
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at, aud, role)
  values
    (u1, 'sql132-test-user-1@example.invalid', now(), now(), now(), 'authenticated', 'authenticated'),
    (u2, 'sql132-test-user-2@example.invalid', now(), now(), now(), 'authenticated', 'authenticated');

  select id into plan_internal from public.vinetrack_plans where code = 'internal_unlimited';
  select id into plan_team     from public.vinetrack_plans where tier = 'team'   and is_active limit 1;
  select id into plan_solo     from public.vinetrack_plans where tier = 'solo'   and is_active limit 1;
  assert plan_internal is not null, 'internal_unlimited plan missing (sql/096 not applied)';
  assert plan_team is not null, 'team plan missing';
  assert plan_solo is not null, 'solo plan missing';

  -- Impersonate u1 for the resolver (auth.uid() reads request.jwt.claims).
  perform set_config('request.jwt.claims',
    json_build_object('sub', u1, 'role', 'authenticated')::text, true);

  -- ------------------------------------------------------------------
  -- T1. No entitlement at all → no access, solo check required,
  --     reason_code = no_entitlement, uses server time.
  -- ------------------------------------------------------------------
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T1 access';
  assert r.solo_check_required = true, 'T1 solo_check';
  assert r.reason_code = 'no_entitlement', 'T1 reason: ' || r.reason_code;
  assert r.last_verified_at between now() - interval '5 seconds' and now() + interval '5 seconds', 'T1 server time';

  -- ------------------------------------------------------------------
  -- T2. Active Internal Unlimited grant → access, internal_unlimited.
  -- ------------------------------------------------------------------
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, seats_purchased,
     unlimited_licences, manual_grant_reason, started_at, created_by, updated_by)
  values (u1, plan_internal, 'manual', 'manual', 0, 0, true, 'sql132 test', now(), u1, u1)
  returning id into sub_id;

  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true, 'T2 access';
  assert r.reason_code = 'internal_unlimited', 'T2 reason: ' || r.reason_code;
  assert r.is_unlimited = true, 'T2 unlimited';
  assert r.can_use_ios_app = true and r.can_use_android_app = true, 'T2 platforms';
  assert r.enforcement_enabled = true, 'T2 enforcement (internal cohort must include grant holders)';

  -- ------------------------------------------------------------------
  -- T3. Expired grant → no access, reason expired.
  -- ------------------------------------------------------------------
  update public.vinetrack_subscriptions
  set manual_grant_expires_at = now() - interval '1 day' where id = sub_id;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T3 access';
  assert r.reason_code = 'expired', 'T3 reason: ' || r.reason_code;

  -- ------------------------------------------------------------------
  -- T4. Revoked grant → no access, reason revoked.
  -- ------------------------------------------------------------------
  update public.vinetrack_subscriptions
  set manual_grant_expires_at = null, manual_grant_revoked_at = now() where id = sub_id;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T4 access';
  assert r.reason_code = 'revoked', 'T4 reason: ' || r.reason_code;

  -- ------------------------------------------------------------------
  -- T5. Future-starting grant → no access.
  -- ------------------------------------------------------------------
  update public.vinetrack_subscriptions
  set manual_grant_revoked_at = null, started_at = now() + interval '1 day' where id = sub_id;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T5 future start must not grant';

  -- Restore the grant to active for the precedence test later.
  update public.vinetrack_subscriptions set started_at = now() where id = sub_id;

  -- ------------------------------------------------------------------
  -- T6. Active portal (team/stripe) subscription → access,
  --     portal_subscription.
  -- ------------------------------------------------------------------
  -- Temporarily revoke the grant so team is the only source.
  update public.vinetrack_subscriptions set manual_grant_revoked_at = now() where id = sub_id;

  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, seats_purchased,
     current_period_end, started_at, created_by, updated_by)
  values (u1, plan_team, 'stripe', 'active', 5, 0, now() + interval '30 days', now(), u1, u1);

  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true, 'T6 access';
  assert r.reason_code = 'portal_subscription', 'T6 reason: ' || r.reason_code;

  -- ------------------------------------------------------------------
  -- T7. Past current_period_end → no access, reason expired.
  -- ------------------------------------------------------------------
  update public.vinetrack_subscriptions
  set current_period_end = now() - interval '1 hour'
  where owner_user_id = u1 and plan_id = plan_team;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T7 expired period must not grant';
  assert r.reason_code = 'expired', 'T7 reason: ' || r.reason_code;

  -- ------------------------------------------------------------------
  -- T8. Active server-side trial → access, active_trial; expired trial
  --     → no access.
  -- ------------------------------------------------------------------
  update public.vinetrack_subscriptions
  set status = 'trialing', trial_end = now() + interval '10 days', current_period_end = null
  where owner_user_id = u1 and plan_id = plan_team;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'active_trial', 'T8a active trial';

  update public.vinetrack_subscriptions
  set trial_end = now() - interval '1 minute'
  where owner_user_id = u1 and plan_id = plan_team;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = false, 'T8b expired trial must not grant';

  -- ------------------------------------------------------------------
  -- T9. Multiple sources → highest-priority VALID source wins; a revoked
  --     high-priority grant falls through to a valid lower source.
  -- ------------------------------------------------------------------
  -- Valid team + restored valid internal grant → internal wins.
  update public.vinetrack_subscriptions
  set status = 'active', trial_end = null, current_period_end = now() + interval '30 days'
  where owner_user_id = u1 and plan_id = plan_team;
  update public.vinetrack_subscriptions set manual_grant_revoked_at = null where id = sub_id;

  select * into r from public.get_my_vinetrack_access();
  assert r.reason_code = 'internal_unlimited', 'T9a precedence: ' || r.reason_code;

  -- Revoke the grant → falls through to the valid team subscription.
  update public.vinetrack_subscriptions set manual_grant_revoked_at = now() where id = sub_id;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'portal_subscription',
    'T9b fallthrough: ' || r.reason_code;

  -- ------------------------------------------------------------------
  -- T10. Apple (solo) subscription recorded in Supabase → access,
  --      app_store_subscription.
  -- ------------------------------------------------------------------
  delete from public.vinetrack_subscriptions where owner_user_id = u1 and plan_id = plan_team;
  insert into public.vinetrack_subscriptions
    (owner_user_id, plan_id, billing_provider, status, seats_included, seats_purchased,
     current_period_end, started_at, created_by, updated_by)
  values (u1, plan_solo, 'apple', 'active', 1, 0, now() + interval '30 days', now(), u1, u1);
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true and r.reason_code = 'app_store_subscription',
    'T10 apple: ' || r.reason_code;

  -- ------------------------------------------------------------------
  -- T11. A user cannot see another user's entitlement.
  -- ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  assert r.user_id = u2, 'T11 identity';
  assert r.has_supabase_access = false, 'T11 isolation — u2 must not inherit u1 access';

  -- ------------------------------------------------------------------
  -- T12. Changing email does not break a user-ID-linked entitlement.
  -- ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  update auth.users set email = 'sql132-renamed@example.invalid' where id = u1;
  select * into r from public.get_my_vinetrack_access();
  assert r.has_supabase_access = true, 'T12 email change must not affect uuid-keyed access';

  -- ------------------------------------------------------------------
  -- T13. Audit: state row exists and events were only written on change.
  -- ------------------------------------------------------------------
  assert (select count(*) from public.vinetrack_entitlement_state where user_id = u1) = 1,
    'T13 single state row';
  -- Re-run without a state change → no new audit rows.
  declare
    before_count bigint;
    after_count bigint;
  begin
    select count(*) into before_count from public.vinetrack_entitlement_audit where user_id = u1;
    perform * from public.get_my_vinetrack_access();
    perform * from public.get_my_vinetrack_access();
    select count(*) into after_count from public.vinetrack_entitlement_audit where user_id = u1;
    assert before_count = after_count, 'T13 no audit rows for unchanged state';
  end;

  -- ------------------------------------------------------------------
  -- T14. Mismatch report: throttled to one row per platform per 24h.
  -- ------------------------------------------------------------------
  perform public.report_entitlement_mismatch('ios', '1.0-test', '{"rc_pro":true}'::jsonb);
  perform public.report_entitlement_mismatch('ios', '1.0-test', '{"rc_pro":true}'::jsonb);
  assert (
    select count(*) from public.vinetrack_entitlement_audit
    where user_id = u1 and event_type = 'entitlement_mismatch_detected'
  ) = 1, 'T14 mismatch throttle';

  -- ------------------------------------------------------------------
  -- T15. Enforcement flag: non-cohort user gets enforcement_enabled=false
  --      while the flag cohort is internal (u1 lost the grant in T9b and
  --      is not a system admin; if u1 *is* somehow in the cohort in your
  --      environment this assert reports it rather than failing silently).
  -- ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  select * into r from public.get_my_vinetrack_access();
  if (select coalesce(f.is_enabled, false) and lower(coalesce(f.value->>'cohort','internal')) = 'internal'
      from public.system_feature_flags f where f.key = 'use_shared_supabase_entitlement') then
    assert r.enforcement_enabled = false, 'T15 non-cohort user must not be enforced yet';
  end if;

  raise notice 'SQL 132 resolver tests: ALL PASSED';
end$$;

rollback;
