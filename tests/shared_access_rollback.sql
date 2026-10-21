-- Actual-function regression tests; every fixture, flag edit and audit entry
-- is rolled back. Run after the correction, or prepend the correction DDL
-- immediately after BEGIN to validate the migration without committing it.
-- A passing run returns failed = 0 and the individual test results.
-- Trigger audit on 2026-10-21: fixture and induced tables have no outbound
-- hooks. Auth signup creates only local trial/billing-event rows.
BEGIN;
SET LOCAL statement_timeout = '45s';
SET LOCAL lock_timeout = '5s';

CREATE TEMP TABLE vt_access_test_results (
  name text PRIMARY KEY,
  passed boolean NOT NULL,
  observed jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

CREATE FUNCTION pg_temp.vt_check(p_name text, p_condition boolean, p_observed jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO vt_access_test_results(name, passed, observed)
  VALUES (p_name, p_condition IS TRUE, coalesce(p_observed, '{}'::jsonb));
END;
$$;

CREATE FUNCTION pg_temp.vt_as_user(p_user uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), true);
  PERFORM set_config('request.jwt.claims',
    CASE WHEN p_user IS NULL THEN '{}'::jsonb
      ELSE jsonb_build_object('sub', p_user, 'role', 'authenticated') END::text, true);
END;
$$;

CREATE TEMP TABLE vt_access_fixture_users (
  id uuid PRIMARY KEY,
  label text NOT NULL,
  account_created_at timestamptz NOT NULL
) ON COMMIT DROP;

DO $tests$
DECLARE
  u_admin uuid := gen_random_uuid();
  u_owner uuid := gen_random_uuid();
  u_member uuid := gen_random_uuid();
  u_other_member uuid := gen_random_uuid();
  u_stranger uuid := gen_random_uuid();
  u_personal uuid := gen_random_uuid();
  u_personal_member uuid := gen_random_uuid();
  u_paid uuid := gen_random_uuid();
  u_paid_member uuid := gen_random_uuid();
  u_licence uuid := gen_random_uuid();
  u_licence_member uuid := gen_random_uuid();
  u_old_denied uuid := gen_random_uuid();
  u_trial_owner uuid := gen_random_uuid();
  u_trial_member uuid := gen_random_uuid();
  v_granted uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_personal uuid := gen_random_uuid();
  v_paid uuid := gen_random_uuid();
  v_licence uuid := gen_random_uuid();
  v_trial uuid := gen_random_uuid();
  s_granted uuid := gen_random_uuid();
  s_personal uuid := gen_random_uuid();
  s_paid uuid := gen_random_uuid();
  l_paid uuid := gen_random_uuid();
  p_solo uuid;
  p_team uuid;
  t_grant_end timestamptz := now() + interval '60 days';
  t_paid_end timestamptz := now() + interval '300 days';
  r record;
  a record;
  ve record;
  f record;
  v_case text;
  v_json jsonb;
  v_flag_value jsonb;
  v_bad_value jsonb;
  v_rejected boolean;
  v_count bigint;
  v_boolean_key text := 'access_rollback_boolean_' || gen_random_uuid()::text;
  v_json_key text := 'access_rollback_json_' || gen_random_uuid()::text;
  v_expected_names text[] := ARRAY[
    'user_id','has_supabase_access','access_source','is_owner','subscription_id',
    'plan_code','plan_tier','plan_name','billing_provider','status','trial_end',
    'current_period_end','portal_access','portal_access_level','can_use_ios_app',
    'can_use_portal','seats_included','seats_purchased','active_licences','vineyard_id',
    'licence_id','unlimited_licences','manual_grant_reason','manual_grant_expires_at',
    'solo_check_required','reason_code','is_unlimited','can_use_android_app',
    'last_verified_at','enforcement_enabled','purchase_platform','cancel_at_period_end',
    'grace_period_end','expires_at'
  ];
  v_expected_types regtype[] := ARRAY[
    'uuid','boolean','text','boolean','uuid','text','text','text','text','text',
    'timestamptz','timestamptz','boolean','text','boolean','boolean','integer',
    'integer','integer','uuid','uuid','boolean','text','timestamptz','boolean',
    'text','boolean','boolean','timestamptz','boolean','text','boolean','timestamptz',
    'timestamptz'
  ]::regtype[];
BEGIN
  INSERT INTO vt_access_fixture_users(id, label, account_created_at) VALUES
    (u_admin,'admin',now()-interval '2 years'),
    (u_owner,'grant-owner',now()-interval '2 years'),
    (u_member,'grant-member',now()-interval '2 years'),
    (u_other_member,'other-member',now()-interval '2 years'),
    (u_stranger,'nonmember-anchor-licensee',now()-interval '2 years'),
    (u_personal,'personal-grant',now()-interval '2 years'),
    (u_personal_member,'personal-grant-colleague',now()-interval '2 years'),
    (u_paid,'paid-owner',now()-interval '2 years'),
    (u_paid_member,'paid-member',now()-interval '2 years'),
    (u_licence,'assigned-licensee',now()-interval '2 years'),
    (u_licence_member,'licensee-colleague',now()-interval '2 years'),
    (u_old_denied,'old-unentitled',now()-interval '2 years'),
    (u_trial_owner,'trial-owner',now()-interval '1 month'),
    (u_trial_member,'trial-member',now()-interval '2 years');

  INSERT INTO auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  SELECT id, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'access-rollback-' || id::text || '@example.invalid',
    'invalid-test-password-hash', now(), account_created_at, now()
  FROM vt_access_fixture_users;

  INSERT INTO public.profiles(id, email, full_name)
  SELECT id, 'access-rollback-' || id::text || '@example.invalid',
    'Access rollback test: ' || label FROM vt_access_fixture_users;
  INSERT INTO public.system_admins(user_id, is_active) VALUES (u_admin, true);

  INSERT INTO public.vineyards(id, name, owner_id) VALUES
    (v_granted, 'Access rollback grant ' || v_granted::text, u_owner),
    (v_other, 'Access rollback unfunded ' || v_other::text, u_owner),
    (v_personal, 'Access rollback personal ' || v_personal::text, u_personal),
    (v_paid, 'Access rollback paid ' || v_paid::text, u_paid),
    (v_licence, 'Access rollback licence ' || v_licence::text, u_licence),
    (v_trial, 'Access rollback trial ' || v_trial::text, u_trial_owner);
  INSERT INTO public.vineyard_members(vineyard_id, user_id, role) VALUES
    (v_granted,u_owner,'owner'), (v_granted,u_member,'operator'),
    (v_other,u_owner,'owner'), (v_other,u_other_member,'operator'),
    (v_personal,u_personal,'owner'), (v_personal,u_personal_member,'manager'),
    (v_paid,u_paid,'owner'), (v_paid,u_paid_member,'operator'),
    (v_licence,u_licence,'owner'), (v_licence,u_licence_member,'operator'),
    (v_trial,u_trial_owner,'owner'), (v_trial,u_trial_member,'operator');

  SELECT id INTO p_solo FROM public.vinetrack_plans WHERE code = 'solo';
  SELECT id INTO p_team FROM public.vinetrack_plans WHERE code = 'team';
  IF p_solo IS NULL OR p_team IS NULL THEN
    RAISE EXCEPTION 'Required Solo/Team plan catalogue missing';
  END IF;

  INSERT INTO public.vinetrack_subscriptions
    (id, owner_user_id, primary_vineyard_id, plan_id, billing_provider, status,
     seats_included, started_at, current_period_end, environment,
     manual_grant_type, manual_grant_reason, manual_grant_expires_at,
     unlimited_licences, grant_scope)
  VALUES
    (s_granted,u_owner,v_granted,p_team,'manual','manual',5,
     now()-interval '1 year',now()+interval '365 days','production',
     'complimentary_team','Rollback fixture',t_grant_end,false,'vineyard'),
    (s_personal,u_personal,v_personal,p_team,'manual','manual',5,
     now()-interval '1 year',now()+interval '365 days','production',
     'complimentary_team','Rollback fixture',t_grant_end,false,'user'),
    (s_paid,u_paid,NULL,p_team,'stripe','active',5,
     now()-interval '1 year',t_paid_end,'production',NULL,NULL,NULL,false,'user');
  INSERT INTO public.vinetrack_user_licences
    (id, subscription_id, user_id, vineyard_id, status, assigned_by)
  VALUES
    (gen_random_uuid(),s_granted,u_owner,v_granted,'active',u_admin),
    (gen_random_uuid(),s_granted,u_stranger,v_granted,'active',u_admin),
    (l_paid,s_paid,u_licence,v_paid,'active',u_paid);

  -- All rollout changes below use a synthetic admin and remain uncommitted.
  PERFORM pg_temp.vt_as_user(u_admin);
  SELECT value INTO v_flag_value FROM public.system_feature_flags
  WHERE key = 'use_shared_supabase_entitlement';
  v_flag_value := coalesce(v_flag_value, '{}'::jsonb)
    || jsonb_build_object('cohort','all');
  PERFORM public.set_system_feature_flag('use_shared_supabase_entitlement',true,v_flag_value);

  SELECT * INTO r FROM pg_proc WHERE oid = 'public.get_my_vinetrack_access()'::regprocedure;
  PERFORM pg_temp.vt_check('rpc_34_column_names_and_order',
    r.proargnames = v_expected_names, to_jsonb(r.proargnames));
  PERFORM pg_temp.vt_check('rpc_34_column_types_and_order',
    r.proallargtypes = v_expected_types::oid[], to_jsonb(r.proallargtypes));
  PERFORM pg_temp.vt_check('canonical_22_column_contract',
    (SELECT cardinality(proallargtypes) - pronargs = 22
     FROM pg_proc WHERE oid = 'public._admin_effective_access(uuid)'::regprocedure));

  PERFORM pg_temp.vt_as_user(u_member);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  SELECT * INTO a FROM public._admin_effective_access(u_member);
  PERFORM pg_temp.vt_check('expired_trial_valid_complimentary_member',
    r.has_supabase_access AND r.can_use_ios_app AND r.enforcement_enabled
    AND r.reason_code = 'vineyard_entitlement'
    AND r.has_supabase_access = a.has_access, to_jsonb(r));
  PERFORM pg_temp.vt_check('legacy_client_receives_actual_inherited_expiry',
    r.current_period_end = t_grant_end AND r.expires_at = t_grant_end
    AND r.current_period_end = a.current_period_end, to_jsonb(r));
  PERFORM pg_temp.vt_check('inherited_member_funding_ids_redacted',
    r.subscription_id IS NULL AND r.licence_id IS NULL AND NOT r.is_owner
    AND r.vineyard_id = v_granted, to_jsonb(r));

  PERFORM pg_temp.vt_as_user(u_owner);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  SELECT * INTO a FROM public._user_level_access(u_owner);
  PERFORM pg_temp.vt_check('vineyard_grant_owner_is_scoped_to_vineyard',
    r.has_supabase_access AND NOT a.has_access AND r.access_source = 'vineyard'
    AND r.subscription_id IS NULL AND r.vineyard_id = v_granted, to_jsonb(r));
  SELECT * INTO ve FROM public._vineyard_entitlement_for(v_other);
  PERFORM pg_temp.vt_check('vineyard_grant_does_not_fund_owners_other_vineyard',
    NOT ve.has_entitlement, to_jsonb(ve));
  PERFORM pg_temp.vt_as_user(u_other_member);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('unfunded_other_vineyard_member_denied',
    NOT r.has_supabase_access, to_jsonb(r));
  PERFORM pg_temp.vt_as_user(u_stranger);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('vineyard_anchor_licence_does_not_entitle_nonmember',
    NOT r.has_supabase_access, to_jsonb(r));

  PERFORM pg_temp.vt_as_user(u_personal);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('expired_trial_valid_personal_complimentary_grant',
    r.has_supabase_access AND r.is_owner AND r.subscription_id = s_personal
    AND r.manual_grant_expires_at = t_grant_end, to_jsonb(r));
  PERFORM pg_temp.vt_as_user(u_personal_member);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('personal_manual_team_grant_does_not_fund_colleagues',
    NOT r.has_supabase_access, to_jsonb(r));

  -- Exercise the two real resolution paths for every validity boundary.
  FOREACH v_case IN ARRAY ARRAY[
    'expired_grant','revoked_grant','future_start','sandbox','deleted',
    'canceled','paused','expired_trial','expired_period','past_due_without_grace'
  ] LOOP
    UPDATE public.vinetrack_subscriptions s
    SET status = CASE v_case
          WHEN 'canceled' THEN 'canceled' WHEN 'paused' THEN 'paused'
          WHEN 'expired_trial' THEN 'trialing'
          WHEN 'expired_period' THEN 'active'
          WHEN 'past_due_without_grace' THEN 'past_due' ELSE 'manual' END,
        manual_grant_expires_at = CASE WHEN v_case='expired_grant'
          THEN now()-interval '1 second' ELSE t_grant_end END,
        manual_grant_revoked_at = CASE WHEN v_case='revoked_grant' THEN now() END,
        started_at = CASE WHEN v_case='future_start'
          THEN now()+interval '1 day' ELSE now()-interval '1 year' END,
        environment = CASE WHEN v_case='sandbox' THEN 'sandbox' ELSE 'production' END,
        deleted_at = CASE WHEN v_case='deleted' THEN now() END,
        trial_end = CASE WHEN v_case='expired_trial' THEN now()-interval '1 day' END,
        current_period_end = CASE WHEN v_case IN ('expired_period','past_due_without_grace')
          THEN now()-interval '1 day' ELSE now()+interval '365 days' END,
        grace_period_end = NULL
    WHERE s.id IN (s_granted,s_personal);

    PERFORM pg_temp.vt_as_user(u_member);
    SELECT * INTO r FROM public.get_my_vinetrack_access();
    SELECT * INTO ve FROM public._vineyard_entitlement_for(v_granted);
    PERFORM pg_temp.vt_check('vineyard_denies_' || v_case,
      NOT r.has_supabase_access AND NOT ve.has_entitlement,
      jsonb_build_object('rpc',to_jsonb(r),'vineyard',to_jsonb(ve)));
    PERFORM pg_temp.vt_as_user(u_personal);
    SELECT * INTO r FROM public.get_my_vinetrack_access();
    SELECT * INTO a FROM public._admin_effective_access(u_personal);
    PERFORM pg_temp.vt_check('account_denies_' || v_case,
      NOT r.has_supabase_access AND NOT a.has_access, to_jsonb(r));
    PERFORM pg_temp.vt_as_user(u_admin);
    v_json := public.admin_user_access_detail(u_personal);
    PERFORM pg_temp.vt_check('admin_billing_source_denies_' || v_case,
      NOT (v_json->'effective_access'->>'has_access')::boolean
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_json->'billing_sources') source
        WHERE source->>'subscription_id'=s_personal::text
          AND (source->>'is_currently_valid')::boolean=false
      ), v_json->'billing_sources');
  END LOOP;

  UPDATE public.vinetrack_subscriptions s
  SET status='manual', manual_grant_expires_at=t_grant_end,
      manual_grant_revoked_at=NULL,started_at=now()-interval '1 year',
      environment='production',deleted_at=NULL,trial_end=NULL,
      current_period_end=now()+interval '365 days',grace_period_end=NULL
  WHERE s.id IN (s_granted,s_personal);

  UPDATE public.vineyards SET deleted_at=now() WHERE id=v_granted;
  SELECT * INTO ve FROM public._vineyard_entitlement_for(v_granted);
  PERFORM pg_temp.vt_check('deleted_vineyard_cannot_resolve_entitlement',
    NOT ve.has_entitlement, to_jsonb(ve));
  UPDATE public.vineyards SET deleted_at=NULL WHERE id=v_granted;

  UPDATE public.vinetrack_subscriptions
  SET status='past_due',current_period_end=now()-interval '1 day',
      grace_period_end=now()+interval '3 days'
  WHERE id=s_personal;
  PERFORM pg_temp.vt_as_user(u_personal);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('valid_grace_period_preserved',
    r.has_supabase_access AND r.expires_at=now()+interval '3 days', to_jsonb(r));
  UPDATE public.vinetrack_subscriptions
  SET status='manual',current_period_end=now()+interval '365 days',grace_period_end=NULL
  WHERE id=s_personal;

  PERFORM pg_temp.vt_as_user(u_paid_member);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('owner_backed_paid_team_funds_members',
    r.has_supabase_access AND r.current_period_end=t_paid_end, to_jsonb(r));
  UPDATE public.vinetrack_subscriptions
  SET manual_grant_expires_at=t_grant_end WHERE id=s_paid;
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('owner_backed_expiry_includes_grant_cap',
    r.has_supabase_access AND r.current_period_end=t_grant_end
    AND r.expires_at=t_grant_end, to_jsonb(r));
  UPDATE public.vinetrack_subscriptions
  SET manual_grant_expires_at=NULL,cancel_at_period_end=true,canceled_at=now()
  WHERE id=s_paid;
  PERFORM pg_temp.vt_as_user(u_paid);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('cancel_at_period_end_keeps_paid_access_until_end',
    r.has_supabase_access AND r.cancel_at_period_end AND r.current_period_end=t_paid_end,
    to_jsonb(r));

  PERFORM pg_temp.vt_as_user(u_licence);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('active_assigned_account_licence_preserved',
    r.has_supabase_access AND NOT r.is_owner AND r.licence_id=l_paid, to_jsonb(r));
  PERFORM pg_temp.vt_as_user(u_licence_member);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('assigned_licence_does_not_fund_licensees_vineyard',
    NOT r.has_supabase_access, to_jsonb(r));
  UPDATE public.vinetrack_user_licences SET revoked_at=now() WHERE id=l_paid;
  PERFORM pg_temp.vt_as_user(u_licence);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('revoked_timestamp_blocks_stale_active_licence',
    NOT r.has_supabase_access, to_jsonb(r));
  UPDATE public.vinetrack_user_licences SET revoked_at=NULL WHERE id=l_paid;

  UPDATE public.vinetrack_subscriptions SET plan_id=p_solo WHERE id=s_paid;
  PERFORM pg_temp.vt_as_user(u_paid);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('paid_solo_owner_keeps_account_access',
    r.has_supabase_access AND r.plan_code='solo', to_jsonb(r));
  PERFORM pg_temp.vt_as_user(u_paid_member);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('paid_solo_does_not_fund_members',
    NOT r.has_supabase_access, to_jsonb(r));
  UPDATE public.vinetrack_subscriptions SET plan_id=p_team WHERE id=s_paid;

  PERFORM pg_temp.vt_as_user(u_trial_member);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  SELECT * INTO a FROM public._account_trial_for(u_trial_owner);
  PERFORM pg_temp.vt_check('owner_trial_inheritance_preserved',
    r.has_supabase_access AND r.trial_end=a.trial_ends_at
    AND r.current_period_end IS NULL AND r.expires_at=a.trial_ends_at, to_jsonb(r));
  PERFORM pg_temp.vt_as_user(u_old_denied);
  SELECT * INTO r FROM public.get_my_vinetrack_access();
  PERFORM pg_temp.vt_check('cohort_all_does_not_grant_unentitled_old_account',
    NOT r.has_supabase_access AND r.enforcement_enabled AND r.reason_code='expired',
    to_jsonb(r));
  PERFORM pg_temp.vt_check('old_account_trial_windows_are_not_extended',
    NOT EXISTS (
      SELECT 1 FROM public.vinetrack_account_trials t
      JOIN vt_access_fixture_users u ON u.id=t.user_id
      WHERE t.trial_started_at IS DISTINCT FROM u.account_created_at
         OR t.trial_ends_at IS DISTINCT FROM u.account_created_at + interval '3 months'
    ));

  -- Derived-state repair detects a plan-only mismatch and does not duplicate audit.
  PERFORM pg_temp.vt_as_user(u_personal);
  PERFORM public.get_my_vinetrack_access();
  UPDATE public.vinetrack_entitlement_state
  SET plan_code='rollback_stale_plan' WHERE user_id=u_personal;
  v_json := public._admin_refresh_entitlement_state(u_personal);
  PERFORM pg_temp.vt_check('cached_plan_only_mismatch_is_repaired',
    (v_json->>'changed')::boolean
    AND (SELECT plan_code='team' FROM public.vinetrack_entitlement_state WHERE user_id=u_personal),
    v_json);
  SELECT count(*) INTO v_count FROM public.vinetrack_entitlement_audit WHERE user_id=u_personal;
  v_json := public._admin_refresh_entitlement_state(u_personal);
  PERFORM pg_temp.vt_check('unchanged_refresh_is_idempotent_without_duplicate_audit',
    NOT (v_json->>'changed')::boolean
    AND v_count=(SELECT count(*) FROM public.vinetrack_entitlement_audit WHERE user_id=u_personal),
    v_json);

  -- Released admin clients omit p_value when toggling a flag.
  PERFORM pg_temp.vt_as_user(u_admin);
  v_flag_value := jsonb_build_object(
    'cohort','beta','user_ids',jsonb_build_array(u_member::text),
    'metadata',jsonb_build_object('retained',true));
  PERFORM public.set_system_feature_flag('use_shared_supabase_entitlement',true,v_flag_value);
  PERFORM public.set_system_feature_flag('use_shared_supabase_entitlement',false);
  SELECT * INTO f FROM public.system_feature_flags WHERE key='use_shared_supabase_entitlement';
  PERFORM pg_temp.vt_check('flag_disable_preserves_cohort_allowlist_and_metadata',
    NOT f.is_enabled AND f.value=v_flag_value
    AND NOT public._entitlement_enforcement_enabled(u_member,false), to_jsonb(f));
  PERFORM public.set_system_feature_flag('use_shared_supabase_entitlement',true);
  SELECT * INTO f FROM public.system_feature_flags WHERE key='use_shared_supabase_entitlement';
  PERFORM pg_temp.vt_check('flag_reenable_preserves_and_applies_allowlist',
    f.is_enabled AND f.value=v_flag_value
    AND public._entitlement_enforcement_enabled(u_member,false)
    AND NOT public._entitlement_enforcement_enabled(u_personal,false), to_jsonb(f));

  FOR v_bad_value IN SELECT value FROM jsonb_array_elements(
    '[true,null,"all",{}, {"cohort":"unknown"}, {"cohort":"all","user_ids":true},
      {"cohort":"all","user_ids":[12]}, {"cohort":"all","user_ids":["invalid"]}]'::jsonb
  ) LOOP
    v_rejected := false;
    BEGIN
      PERFORM public.set_system_feature_flag('use_shared_supabase_entitlement',true,v_bad_value);
    EXCEPTION WHEN SQLSTATE '22023' THEN
      v_rejected := true;
    END;
    PERFORM pg_temp.vt_check('reject_invalid_flag_' || v_bad_value::text,
      v_rejected AND (SELECT value=v_flag_value FROM public.system_feature_flags
                     WHERE key='use_shared_supabase_entitlement'), v_bad_value);
  END LOOP;

  PERFORM public.set_system_feature_flag(v_boolean_key,true);
  PERFORM public.set_system_feature_flag(v_boolean_key,false);
  SELECT * INTO f FROM public.system_feature_flags WHERE key=v_boolean_key;
  PERFORM pg_temp.vt_check('ordinary_boolean_flag_toggle_semantics_preserved',
    f.value='false'::jsonb AND NOT f.is_enabled AND f.value_type='boolean', to_jsonb(f));
  PERFORM public.set_system_feature_flag(v_json_key,true,'{"threshold":7}'::jsonb);
  PERFORM public.set_system_feature_flag(v_json_key,false);
  SELECT * INTO f FROM public.system_feature_flags WHERE key=v_json_key;
  PERFORM pg_temp.vt_check('new_structured_flag_retains_json_type_and_value',
    f.value='{"threshold":7}'::jsonb AND f.value_type='json' AND NOT f.is_enabled,
    to_jsonb(f));

  -- Restore a valid flag even when this harness is intentionally run on the old
  -- implementation to demonstrate failed regression cases.
  PERFORM public.set_system_feature_flag('use_shared_supabase_entitlement',true,v_flag_value);
  PERFORM pg_temp.vt_as_user(u_personal);
  v_rejected := false;
  BEGIN
    PERFORM public.set_system_feature_flag('use_shared_supabase_entitlement',false);
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_rejected := true;
  END;
  PERFORM pg_temp.vt_check('ordinary_user_cannot_edit_rollout_flag',
    v_rejected AND (SELECT value=v_flag_value AND is_enabled
                   FROM public.system_feature_flags WHERE key='use_shared_supabase_entitlement'));

  PERFORM pg_temp.vt_as_user(NULL);
  v_rejected := false;
  BEGIN
    PERFORM public.get_my_vinetrack_access();
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_rejected := true;
  END;
  PERFORM pg_temp.vt_check('public_access_rpc_requires_authenticated_user',v_rejected);
END;
$tests$;

SELECT count(*) AS tests,
       count(*) FILTER (WHERE passed) AS passed,
       count(*) FILTER (WHERE NOT passed) AS failed,
       jsonb_agg(jsonb_build_object('name',name,'passed',passed,
         'observed',CASE WHEN passed THEN NULL ELSE observed END) ORDER BY name) AS results
FROM vt_access_test_results;
ROLLBACK;
