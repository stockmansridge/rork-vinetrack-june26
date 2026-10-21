-- Monitor regression tests against the production functions, with a seeded
-- continuation cursor that reaches ONLY two synthetic users. Every write,
-- including scheduler DDL when prepended, must remain inside this rollback.
-- Run after both migrations, or prepend them immediately after BEGIN.
BEGIN;
SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';

CREATE TEMP TABLE vt_health_test_results (
  name text PRIMARY KEY, passed boolean NOT NULL, observed jsonb
) ON COMMIT DROP;

CREATE FUNCTION pg_temp.vt_health_check(p_name text, p_condition boolean, p_observed jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO vt_health_test_results(name, passed, observed)
  VALUES (p_name, p_condition IS TRUE, p_observed);
END;
$$;

DO $tests$
DECLARE
  -- UUID ordering is explicit. The guard below aborts rather than allowing the
  -- scanner to process any pre-existing account beyond this synthetic cursor.
  v_cursor uuid := 'ffffffff-ffff-4fff-afff-000000000000';
  u_entitled uuid := ('ffffffff-ffff-4fff-afff-' || right(replace(gen_random_uuid()::text,'-',''),12))::uuid;
  u_denied uuid := ('ffffffff-ffff-4fff-afff-' || right(replace(gen_random_uuid()::text,'-',''),12))::uuid;
  s_grant uuid := gen_random_uuid();
  v_plan uuid;
  v_first_run jsonb;
  v_second_run jsonb;
  v_health jsonb;
  v_before_sub jsonb;
  v_before_trial jsonb;
  v_before_flag jsonb;
  v_issues_after_first jsonb;
  v_claims text;
  v_subject text;
  v_before_states text;
  v_after_states text;
  v_before_audit_count bigint;
  v_billing_count bigint;
  v_role text;
  v_rejected boolean;
BEGIN
  IF EXISTS (SELECT 1 FROM auth.users WHERE id > v_cursor)
     OR u_entitled = u_denied OR u_entitled <= v_cursor OR u_denied <= v_cursor THEN
    RAISE EXCEPTION 'Synthetic cursor is not isolated; abort rather than scan an existing account';
  END IF;
  IF EXISTS (SELECT 1 FROM vinetrack_private.access_health_runs WHERE status='running') THEN
    RAISE EXCEPTION 'Monitor already has an unfinished run; test on a clean rollback migration';
  END IF;

  INSERT INTO auth.users
    (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  VALUES
    (u_entitled,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
     'health-rollback-'||u_entitled::text||'@example.invalid','invalid-test-hash',
     now(),now()-interval '2 years',now()),
    (u_denied,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
     'health-rollback-'||u_denied::text||'@example.invalid','invalid-test-hash',
     now(),now()-interval '2 years',now());
  INSERT INTO public.profiles(id,email,full_name) VALUES
    (u_entitled,'health-rollback-'||u_entitled::text||'@example.invalid','Monitor test grant'),
    (u_denied,'health-rollback-'||u_denied::text||'@example.invalid','Monitor test denial');
  INSERT INTO public.system_admins(user_id,is_active) VALUES (u_entitled,true);

  SELECT id INTO v_plan FROM public.vinetrack_plans WHERE code='team';
  IF v_plan IS NULL THEN RAISE EXCEPTION 'Team catalogue missing'; END IF;
  INSERT INTO public.vinetrack_subscriptions
    (id,owner_user_id,plan_id,billing_provider,status,started_at,current_period_end,
     unlimited_licences,manual_grant_type,manual_grant_expires_at,grant_scope)
  VALUES (s_grant,u_entitled,v_plan,'manual','manual',now()-interval '1 year',
    now()+interval '365 days',false,'complimentary_team',now()+interval '60 days','user');
  SELECT to_jsonb(s) INTO v_before_sub FROM public.vinetrack_subscriptions s WHERE id=s_grant;

  -- One legacy account is missing its persisted trial record. The other has
  -- a stale active status with an unchanged historical, already-expired window.
  DELETE FROM public.vinetrack_account_trials WHERE user_id=u_entitled;
  UPDATE public.vinetrack_account_trials SET status='active' WHERE user_id=u_denied;
  SELECT jsonb_build_object('start',trial_started_at,'end',trial_ends_at)
  INTO v_before_trial FROM public.vinetrack_account_trials WHERE user_id=u_denied;

  PERFORM public._admin_refresh_entitlement_state(u_entitled);
  PERFORM public._admin_refresh_entitlement_state(u_denied);
  UPDATE public.vinetrack_entitlement_state SET plan_code='rollback_stale_plan'
  WHERE user_id=u_entitled;
  INSERT INTO vinetrack_private.access_health_issues
    (user_id,issue_type,occurrences,detail)
  VALUES
    (u_entitled,'decision_mismatch',3,'{"seeded_by_rollback_test":true}'),
    (u_entitled,'scan_error',2,'{"sqlstate":"TEST0"}');

  PERFORM set_config('request.jwt.claim.sub',u_entitled::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',u_entitled,'role','authenticated','test_context','must survive scan')::text,true);
  -- An emergency disable is deliberate configuration, never a monitor repair.
  PERFORM public.set_system_feature_flag('use_shared_supabase_entitlement',false);
  SELECT to_jsonb(f) INTO v_before_flag FROM public.system_feature_flags f
  WHERE key='use_shared_supabase_entitlement';
  v_claims := current_setting('request.jwt.claims',true);
  v_subject := current_setting('request.jwt.claim.sub',true);

  SELECT md5(coalesce(string_agg(to_jsonb(es)::text,'|' ORDER BY es.user_id),''))
  INTO v_before_states FROM public.vinetrack_entitlement_state es
  WHERE user_id NOT IN (u_entitled,u_denied);
  SELECT count(*) INTO v_before_audit_count FROM public.vinetrack_entitlement_audit
  WHERE user_id NOT IN (u_entitled,u_denied);

  -- Resume a deliberately bounded two-account page, exercising the real cursor.
  INSERT INTO vinetrack_private.access_health_runs(total_accounts,last_user_id)
  VALUES (2,v_cursor);
  v_first_run := vinetrack_private.run_access_health_scan();
  PERFORM pg_temp.vt_health_check('first_scan_succeeds_and_checks_only_fixture_page',
    v_first_run->>'status'='succeeded'
    AND (v_first_run->>'total_accounts')::integer=2
    AND (v_first_run->>'checked_accounts')::integer=2
    AND (v_first_run->>'mismatch_count')::integer=0
    AND (v_first_run->>'error_count')::integer=0, v_first_run);
  PERFORM pg_temp.vt_health_check('monitor_repairs_plan_only_cache_mismatch',
    (v_first_run->>'stale_states_corrected')::integer=1
    AND (SELECT plan_code='team' FROM public.vinetrack_entitlement_state WHERE user_id=u_entitled),
    v_first_run);
  PERFORM pg_temp.vt_health_check('scan_restores_exact_caller_auth_context',
    current_setting('request.jwt.claims',true) IS NOT DISTINCT FROM v_claims
    AND current_setting('request.jwt.claim.sub',true) IS NOT DISTINCT FROM v_subject);
  PERFORM pg_temp.vt_health_check('monitor_preserves_intentional_emergency_disable',
    (SELECT to_jsonb(f)=v_before_flag FROM public.system_feature_flags f
     WHERE key='use_shared_supabase_entitlement'));
  PERFORM pg_temp.vt_health_check('monitor_does_not_modify_grant_or_subscription_terms',
    (SELECT to_jsonb(s)=v_before_sub FROM public.vinetrack_subscriptions s WHERE id=s_grant));
  PERFORM pg_temp.vt_health_check('stale_trial_status_expires_without_extending_window',
    (SELECT status='expired'
      AND jsonb_build_object('start',trial_started_at,'end',trial_ends_at)=v_before_trial
     FROM public.vinetrack_account_trials WHERE user_id=u_denied));
  PERFORM pg_temp.vt_health_check('missing_legacy_trial_uses_original_signup_window',
    (SELECT t.status='expired' AND t.trial_started_at=u.created_at
      AND t.trial_ends_at=u.created_at+interval '3 months'
     FROM public.vinetrack_account_trials t JOIN auth.users u ON u.id=t.user_id
     WHERE t.user_id=u_entitled));
  PERFORM pg_temp.vt_health_check('healthy_scan_resolves_prior_issue_rows',
    (SELECT count(*)=2 AND bool_and(resolved_at IS NOT NULL)
       AND min(occurrences)=2 AND max(occurrences)=3
     FROM vinetrack_private.access_health_issues WHERE user_id=u_entitled));
  SELECT jsonb_agg(to_jsonb(i) ORDER BY issue_type) INTO v_issues_after_first
  FROM vinetrack_private.access_health_issues i WHERE user_id=u_entitled;
  SELECT count(*) INTO v_billing_count FROM public.vinetrack_billing_events
  WHERE owner_user_id IN (u_entitled,u_denied);

  INSERT INTO vinetrack_private.access_health_runs(total_accounts,last_user_id)
  VALUES (2,v_cursor);
  v_second_run := vinetrack_private.run_access_health_scan();
  PERFORM pg_temp.vt_health_check('second_scan_is_idempotent',
    v_second_run->>'status'='succeeded'
    AND (v_second_run->>'checked_accounts')::integer=2
    AND (v_second_run->>'stale_states_corrected')::integer=0
    AND (v_second_run->>'mismatch_count')::integer=0
    AND (v_second_run->>'error_count')::integer=0,v_second_run);
  PERFORM pg_temp.vt_health_check('second_scan_does_not_duplicate_or_rewrite_resolved_issues',
    (SELECT jsonb_agg(to_jsonb(i) ORDER BY issue_type)=v_issues_after_first
     FROM vinetrack_private.access_health_issues i WHERE user_id=u_entitled));
  PERFORM pg_temp.vt_health_check('second_scan_does_not_duplicate_trial_billing_events',
    v_billing_count=(SELECT count(*) FROM public.vinetrack_billing_events
                    WHERE owner_user_id IN (u_entitled,u_denied)));
  SELECT md5(coalesce(string_agg(to_jsonb(es)::text,'|' ORDER BY es.user_id),''))
  INTO v_after_states FROM public.vinetrack_entitlement_state es
  WHERE user_id NOT IN (u_entitled,u_denied);
  PERFORM pg_temp.vt_health_check('synthetic_cursor_leaves_all_real_cached_states_and_audits_untouched',
    v_before_states=v_after_states
    AND v_before_audit_count=(SELECT count(*) FROM public.vinetrack_entitlement_audit
                             WHERE user_id NOT IN (u_entitled,u_denied)));

  v_health := public.admin_access_health();
  PERFORM pg_temp.vt_health_check('admin_health_reports_disabled_flag_and_successful_job',
    (v_health#>>'{rollout,is_enabled}')::boolean=false
    AND (v_health#>>'{rollout,configuration_valid}')::boolean
    AND (v_health#>>'{scheduler,active}')::boolean
    AND NOT (v_health#>>'{scheduler,overdue}')::boolean
    AND v_health#>>'{latest_scan,status}'='succeeded',v_health);
  PERFORM pg_temp.vt_health_check('health_summary_does_not_expose_account_ids',
    position(u_entitled::text IN v_health::text)=0
    AND position(u_denied::text IN v_health::text)=0,v_health);

  -- Inspect effective grants for every public/client role. The runner and its
  -- private records are never available through a client PostgREST request.
  FOREACH v_role IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
    PERFORM pg_temp.vt_health_check('private_runner_unavailable_to_'||v_role,
      NOT has_function_privilege(v_role,'vinetrack_private.run_access_health_scan()','EXECUTE'));
    PERFORM pg_temp.vt_health_check('private_monitor_tables_unavailable_to_'||v_role,
      NOT has_table_privilege(v_role,'vinetrack_private.access_health_runs','SELECT,INSERT,UPDATE,DELETE')
      AND NOT has_table_privilege(v_role,'vinetrack_private.access_health_issues','SELECT,INSERT,UPDATE,DELETE'));
  END LOOP;
  PERFORM pg_temp.vt_health_check('scheduler_owner_can_execute_private_runner',
    has_function_privilege(current_user,'vinetrack_private.run_access_health_scan()','EXECUTE'));
  PERFORM pg_temp.vt_health_check('private_monitor_tables_have_row_level_security',
    (SELECT count(*)=2 AND bool_and(relrowsecurity)
     FROM pg_class WHERE oid IN ('vinetrack_private.access_health_runs'::regclass,
                                 'vinetrack_private.access_health_issues'::regclass)));
  PERFORM pg_temp.vt_health_check('authenticated_admin_rpc_grant_and_anon_revoke',
    has_function_privilege('authenticated','public.admin_access_health()','EXECUTE')
    AND NOT has_function_privilege('anon','public.admin_access_health()','EXECUTE'));

  PERFORM set_config('request.jwt.claim.sub',u_denied::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',u_denied,'role','authenticated')::text,true);
  v_rejected := false;
  BEGIN
    PERFORM public.admin_access_health();
  EXCEPTION WHEN SQLSTATE '42501' THEN v_rejected := true;
  END;
  PERFORM pg_temp.vt_health_check('nonadmin_health_summary_is_denied',v_rejected);
  PERFORM set_config('request.jwt.claim.sub','',true);
  PERFORM set_config('request.jwt.claims','{}',true);
  v_rejected := false;
  BEGIN
    PERFORM public.admin_access_health();
  EXCEPTION WHEN SQLSTATE '42501' THEN v_rejected := true;
  END;
  PERFORM pg_temp.vt_health_check('anonymous_health_summary_is_denied',v_rejected);
END;
$tests$;

SELECT count(*) AS tests,
       count(*) FILTER (WHERE passed) AS passed,
       count(*) FILTER (WHERE NOT passed) AS failed,
       jsonb_agg(jsonb_build_object('name',name,'passed',passed,
         'observed',CASE WHEN passed THEN NULL ELSE observed END) ORDER BY name) AS results
FROM vt_health_test_results;
ROLLBACK;
