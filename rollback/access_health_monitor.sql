-- Monitor rollback TRANSACTION BODY. Run inside BEGIN/COMMIT, or with
-- psql --single-transaction --set ON_ERROR_STOP=1 --file <this file>.
-- Use the database role that owns this named cron job. This removes only
-- this monitor and its history; access resolution and rollout stay unchanged.
-- The existing vinetrack_private schema and unrelated jobs are preserved.
SET LOCAL lock_timeout = '5s';

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'vinetrack-access-health-every-five-minutes'
  AND database = current_database()
  AND username = current_user;

DO $ownership_guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM cron.job
    WHERE jobname = 'vinetrack-access-health-every-five-minutes'
      AND database = current_database()
  ) THEN
    RAISE EXCEPTION 'Access health job belongs to another role; run rollback as its owning role';
  END IF;
END;
$ownership_guard$;

-- Coordinate with the scanner's existing advisory lock. A running scan must
-- finish before its functions/tables are removed; lock timeout aborts cleanly.
SELECT pg_advisory_xact_lock(876324, 451901);

DROP FUNCTION IF EXISTS public.admin_access_health();
DROP FUNCTION IF EXISTS vinetrack_private.run_access_health_scan();
DROP TABLE IF EXISTS vinetrack_private.access_health_issues;
DROP TABLE IF EXISTS vinetrack_private.access_health_runs;

-- No CASCADE and no DROP SCHEMA: an unexpected dependency must stop rollback.
