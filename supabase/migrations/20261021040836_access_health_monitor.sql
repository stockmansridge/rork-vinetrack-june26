-- Automated reconciliation of derived access state. Commercial grants,
-- memberships and the emergency feature switch are never edited. The normal
-- get_my RPC also maintains trial bookkeeping from the original signup date;
-- it can persist a missing trial or mark its status expired, without extending
-- or resetting the original trial window.
-- Each invocation checks at most 250 accounts and yields after 45 seconds.

CREATE SCHEMA IF NOT EXISTS vinetrack_private;

CREATE TABLE vinetrack_private.access_health_runs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  status text NOT NULL DEFAULT 'running'
    CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
  total_accounts integer NOT NULL DEFAULT 0,
  checked_accounts integer NOT NULL DEFAULT 0,
  stale_states_corrected integer NOT NULL DEFAULT 0,
  mismatch_count integer NOT NULL DEFAULT 0,
  unknown_client_accounts integer NOT NULL DEFAULT 0,
  error_count integer NOT NULL DEFAULT 0,
  last_user_id uuid
);

CREATE TABLE vinetrack_private.access_health_issues (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  issue_type text NOT NULL CHECK (issue_type IN ('decision_mismatch', 'scan_error')),
  first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  resolved_at timestamptz,
  occurrences integer NOT NULL DEFAULT 1,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (user_id, issue_type)
);

CREATE INDEX access_health_runs_completed_idx
  ON vinetrack_private.access_health_runs (completed_at DESC)
  WHERE status = 'succeeded';
CREATE INDEX access_health_issues_open_idx
  ON vinetrack_private.access_health_issues (last_seen_at DESC)
  WHERE resolved_at IS NULL;

ALTER TABLE vinetrack_private.access_health_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE vinetrack_private.access_health_issues ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON vinetrack_private.access_health_runs,
  vinetrack_private.access_health_issues FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE vinetrack_private.access_health_runs_id_seq
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION vinetrack_private.run_access_health_scan()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_run vinetrack_private.access_health_runs%rowtype;
  v_user record;
  v_effective record;
  v_user_access record;
  v_rpc record;
  v_matrix jsonb;
  v_refresh jsonb;
  v_issues jsonb;
  v_membership_count integer;
  v_matrix_mismatches integer;
  v_unknown boolean;
  v_checked integer := 0;
  v_corrected integer := 0;
  v_mismatches integer := 0;
  v_unknown_count integer := 0;
  v_errors integer := 0;
  v_last_user_id uuid;
  v_started timestamptz := clock_timestamp();
  v_claims text := current_setting('request.jwt.claims', true);
  v_subject text := current_setting('request.jwt.claim.sub', true);
  v_expected_enforcement boolean;
  v_finished boolean;
BEGIN
  IF NOT pg_try_advisory_xact_lock(876324, 451901) THEN
    RETURN jsonb_build_object('status', 'already_running');
  END IF;

  SELECT * INTO v_run
  FROM vinetrack_private.access_health_runs
  WHERE status = 'running'
  ORDER BY id DESC LIMIT 1 FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO vinetrack_private.access_health_runs (total_accounts)
    SELECT count(*)::integer FROM auth.users
    RETURNING * INTO v_run;
  END IF;
  v_last_user_id := v_run.last_user_id;

  FOR v_user IN
    SELECT u.id, u.email FROM auth.users u
    WHERE v_run.last_user_id IS NULL OR u.id > v_run.last_user_id
    ORDER BY u.id LIMIT 250
  LOOP
    -- No identities or JWTs leave this private function. Restore the caller's
    -- context after each account and on every exception path. This exercises
    -- the actual public RPCs with the same auth.uid() as an app request.
    BEGIN
      PERFORM set_config('request.jwt.claim.sub', v_user.id::text, true);
      PERFORM set_config('request.jwt.claims', jsonb_build_object(
        'sub', v_user.id, 'role', 'authenticated', 'email', v_user.email
      )::text, true);

      SELECT * INTO STRICT v_effective FROM public._admin_effective_access(v_user.id);
      SELECT * INTO STRICT v_user_access FROM public._user_level_access(v_user.id);

      -- Do this before get_my_vinetrack_access, which also performs best-effort
      -- reconciliation, so corrections are counted accurately and only once.
      v_refresh := public._admin_refresh_entitlement_state(v_user.id);
      SELECT * INTO STRICT v_rpc FROM public.get_my_vinetrack_access();
      v_matrix := public.get_my_vineyard_access_matrix();
      v_issues := '{}'::jsonb;

      IF v_rpc.has_supabase_access IS DISTINCT FROM v_effective.has_access
         OR v_rpc.can_use_ios_app IS DISTINCT FROM v_effective.has_access
         OR v_rpc.can_use_android_app IS DISTINCT FROM v_effective.has_access
         OR v_rpc.access_source IS DISTINCT FROM coalesce(v_effective.plan_tier, 'none')
         OR v_rpc.reason_code IS DISTINCT FROM v_effective.reason_code
         OR v_rpc.plan_code IS DISTINCT FROM v_effective.plan_code
         OR v_rpc.vineyard_id IS DISTINCT FROM v_effective.vineyard_id
         OR v_rpc.can_use_portal IS DISTINCT FROM
            (v_effective.has_access AND coalesce(v_effective.portal_access_level, 'none') <> 'none') THEN
        v_issues := v_issues || jsonb_build_object('app_rpc', true);
      END IF;

      v_expected_enforcement := public._entitlement_enforcement_enabled(
        v_user.id, v_effective.has_access AND v_effective.reason_code = 'internal_unlimited'
      );
      IF v_rpc.enforcement_enabled IS DISTINCT FROM v_expected_enforcement THEN
        v_issues := v_issues || jsonb_build_object('rollout_rpc', true);
      END IF;

      SELECT count(*)::integer INTO v_membership_count
      FROM public.vineyards vy
      WHERE vy.deleted_at IS NULL AND (
        vy.owner_id = v_user.id OR EXISTS (
          SELECT 1 FROM public.vineyard_members vm
          WHERE vm.vineyard_id = vy.id AND vm.user_id = v_user.id
        )
      );

      WITH actual AS (
        SELECT (x->>'vineyard_id')::uuid AS vineyard_id,
               (x->>'has_vineyard_access')::boolean AS has_access,
               (x->>'can_enter_vineyard')::boolean AS can_enter
        FROM jsonb_array_elements(v_matrix->'vineyards') x
      ), expected AS (
        SELECT vy.id AS vineyard_id,
          (v_user_access.has_access OR ve.has_entitlement) AS has_access
        FROM public.vineyards vy
        CROSS JOIN LATERAL public._vineyard_entitlement_for(vy.id) ve
        WHERE vy.deleted_at IS NULL AND (
          vy.owner_id = v_user.id OR EXISTS (
            SELECT 1 FROM public.vineyard_members vm
            WHERE vm.vineyard_id = vy.id AND vm.user_id = v_user.id
          )
        )
      )
      SELECT count(*)::integer INTO v_matrix_mismatches
      FROM expected e FULL JOIN actual a USING (vineyard_id)
      WHERE e.vineyard_id IS NULL OR a.vineyard_id IS NULL
         OR e.has_access IS DISTINCT FROM a.has_access
         OR e.has_access IS DISTINCT FROM a.can_enter;

      IF v_matrix_mismatches > 0
         OR jsonb_typeof(v_matrix->'vineyards') IS DISTINCT FROM 'array'
         OR jsonb_array_length(v_matrix->'vineyards') IS DISTINCT FROM v_membership_count
         OR (v_matrix#>>'{account,has_account_entitlement}')::boolean
             IS DISTINCT FROM v_user_access.has_access
         OR (v_user_access.has_access OR
             coalesce((v_matrix#>>'{account,has_any_accessible_vineyard}')::boolean, false))
             IS DISTINCT FROM v_effective.has_access THEN
        v_issues := v_issues || jsonb_build_object('vineyard_matrix', true);
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM public.vinetrack_entitlement_state es
        WHERE es.user_id = v_user.id
          AND es.has_access IS NOT DISTINCT FROM v_effective.has_access
          AND es.access_source IS NOT DISTINCT FROM coalesce(v_effective.plan_tier, 'none')
          AND es.reason_code IS NOT DISTINCT FROM v_effective.reason_code
          AND es.plan_code IS NOT DISTINCT FROM v_effective.plan_code
      ) THEN
        v_issues := v_issues || jsonb_build_object('derived_state', true);
      END IF;

      -- Coverage is separate from access correctness: portal-only accounts
      -- and never-seen apps have no mobile version to verify. An observed
      -- version proves telemetry coverage, not installation or handset login.
      SELECT NOT EXISTS (
        SELECT 1 FROM public.vinetrack_user_clients c
        WHERE c.user_id = v_user.id AND c.platform IN ('ios', 'android')
          AND nullif(btrim(c.app_version), '') IS NOT NULL
      ) INTO v_unknown;

      IF v_issues <> '{}'::jsonb THEN
        INSERT INTO vinetrack_private.access_health_issues AS i
          (user_id, issue_type, detail)
        VALUES (v_user.id, 'decision_mismatch', v_issues)
        ON CONFLICT (user_id, issue_type) DO UPDATE SET
          last_seen_at = clock_timestamp(), resolved_at = NULL,
          occurrences = i.occurrences + 1, detail = excluded.detail;
        v_mismatches := v_mismatches + 1;
      ELSE
        UPDATE vinetrack_private.access_health_issues
        SET resolved_at = clock_timestamp()
        WHERE user_id = v_user.id AND issue_type = 'decision_mismatch'
          AND resolved_at IS NULL;
      END IF;

      UPDATE vinetrack_private.access_health_issues
      SET resolved_at = clock_timestamp()
      WHERE user_id = v_user.id AND issue_type = 'scan_error'
        AND resolved_at IS NULL;

      v_corrected := v_corrected + CASE WHEN (v_refresh->>'changed')::boolean THEN 1 ELSE 0 END;
      v_unknown_count := v_unknown_count + CASE WHEN v_unknown THEN 1 ELSE 0 END;
    EXCEPTION WHEN OTHERS THEN
      -- The per-user subtransaction rolls back its attempted repair and writes.
      -- Store only SQLSTATE, never a raw error that could contain customer data.
      INSERT INTO vinetrack_private.access_health_issues AS i
        (user_id, issue_type, detail)
      VALUES (v_user.id, 'scan_error', jsonb_build_object('sqlstate', SQLSTATE))
      ON CONFLICT (user_id, issue_type) DO UPDATE SET
        last_seen_at = clock_timestamp(), resolved_at = NULL,
        occurrences = i.occurrences + 1, detail = excluded.detail;
      v_errors := v_errors + 1;
    END;

    PERFORM set_config('request.jwt.claim.sub', coalesce(v_subject, ''), true);
    PERFORM set_config('request.jwt.claims', coalesce(v_claims, ''), true);
    v_checked := v_checked + 1;
    v_last_user_id := v_user.id;
    EXIT WHEN clock_timestamp() - v_started > interval '45 seconds';
  END LOOP;

  SELECT NOT EXISTS (
    SELECT 1 FROM auth.users u
    WHERE v_last_user_id IS NULL OR u.id > v_last_user_id
  ) INTO v_finished;

  UPDATE vinetrack_private.access_health_runs r SET
    checked_accounts = r.checked_accounts + v_checked,
    stale_states_corrected = r.stale_states_corrected + v_corrected,
    mismatch_count = r.mismatch_count + v_mismatches,
    unknown_client_accounts = r.unknown_client_accounts + v_unknown_count,
    error_count = r.error_count + v_errors,
    last_user_id = v_last_user_id,
    completed_at = CASE WHEN v_finished THEN clock_timestamp() ELSE NULL END,
    status = CASE WHEN NOT v_finished THEN 'running'
      WHEN r.error_count + v_errors > 0
        OR r.mismatch_count + v_mismatches > 0
        OR r.checked_accounts + v_checked <> r.total_accounts THEN 'partial'
      ELSE 'succeeded' END
  WHERE r.id = v_run.id RETURNING * INTO v_run;

  -- Retain one month of aggregate runs and three months of resolved issues.
  DELETE FROM vinetrack_private.access_health_runs
  WHERE completed_at < clock_timestamp() - interval '30 days';
  DELETE FROM vinetrack_private.access_health_issues
  WHERE resolved_at < clock_timestamp() - interval '90 days';

  RETURN jsonb_build_object(
    'status', v_run.status, 'checked_accounts', v_run.checked_accounts,
    'total_accounts', v_run.total_accounts,
    'stale_states_corrected', v_run.stale_states_corrected,
    'mismatch_count', v_run.mismatch_count, 'error_count', v_run.error_count
  );
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_subject, ''), true);
  PERFORM set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  RAISE;
END;
$function$;
REVOKE ALL ON FUNCTION vinetrack_private.run_access_health_scan()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_access_health()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_flag public.system_feature_flags%rowtype;
  v_run vinetrack_private.access_health_runs%rowtype;
  v_success timestamptz;
  v_active boolean;
  v_valid boolean;
  v_overdue boolean;
  v_open integer;
  v_interval interval;
BEGIN
  IF NOT public.is_system_admin() THEN
    RAISE EXCEPTION 'System admin required' USING errcode = '42501';
  END IF;

  SELECT * INTO v_flag FROM public.system_feature_flags
  WHERE key = 'use_shared_supabase_entitlement';
  v_valid := coalesce(jsonb_typeof(v_flag.value) = 'object'
    AND v_flag.value->>'cohort' IN ('internal', 'beta', 'all')
    AND (NOT (v_flag.value ? 'user_ids')
      OR jsonb_typeof(v_flag.value->'user_ids') = 'array'), false);
  IF v_valid AND v_flag.value ? 'user_ids' THEN
    v_valid := NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_flag.value->'user_ids') x
      WHERE jsonb_typeof(x) <> 'string'
         OR (x #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    );
  END IF;

  SELECT * INTO v_run FROM vinetrack_private.access_health_runs
  ORDER BY id DESC LIMIT 1;
  SELECT max(completed_at) INTO v_success
  FROM vinetrack_private.access_health_runs WHERE status = 'succeeded';
  SELECT EXISTS (
    SELECT 1 FROM cron.job
    WHERE jobname = 'vinetrack-access-health-every-five-minutes'
      AND active AND schedule = '*/5 * * * *'
      AND command = 'SET statement_timeout = ''60s''; SELECT vinetrack_private.run_access_health_scan();'
  ) INTO v_active;
  v_interval := (10 + 5 * greatest(1, ceil(coalesce(v_run.total_accounts, 0) / 250.0)))
    * interval '1 minute';
  v_overdue := v_success IS NULL OR now() - v_success > v_interval;
  SELECT count(*)::integer INTO v_open
  FROM vinetrack_private.access_health_issues WHERE resolved_at IS NULL;

  RETURN jsonb_build_object(
    'generated_at', now(),
    'rollout', jsonb_build_object(
      'is_enabled', coalesce(v_flag.is_enabled, false),
      'cohort', v_flag.value->>'cohort', 'configuration_valid', v_valid
    ),
    'scheduler', jsonb_build_object(
      'active', v_active, 'last_success_at', v_success, 'overdue', v_overdue
    ),
    'latest_scan', CASE WHEN v_run.id IS NULL THEN NULL ELSE jsonb_build_object(
      'started_at', v_run.started_at, 'completed_at', v_run.completed_at,
      'status', v_run.status, 'total_accounts', v_run.total_accounts,
      'checked_accounts', v_run.checked_accounts,
      'stale_states_corrected', v_run.stale_states_corrected,
      'mismatch_count', v_run.mismatch_count,
      'unknown_client_accounts', v_run.unknown_client_accounts,
      'error_count', v_run.error_count
    ) END,
    'open_issue_count', v_open
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.admin_access_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_access_health() TO authenticated;

-- Idempotent by name. This never touches the existing webhook-dispatch job.
SELECT cron.schedule(
  'vinetrack-access-health-every-five-minutes',
  '*/5 * * * *',
  'SET statement_timeout = ''60s''; SELECT vinetrack_private.run_access_health_scan();'
);
