# Shared access recovery

This rollout makes the app, administration view, and derived entitlement state use the same access decision. A valid complimentary or inherited vineyard grant takes precedence over an expired account trial. Vineyard grants remain limited to their vineyard and its actual members.

## Deployment

Use the owning database administrator role. Capture the current `use_shared_supabase_entitlement` row and the existing function definitions in the deployment record. Keep the captured flag JSON outside source control; it may contain an account allowlist.

Apply these migrations in order:

1. `supabase/migrations/20261021040736_shared_access_correction.sql` corrects resolution, preserves the existing public RPC contract, fixes flag updates, and changes the existing cohort to `all` in the same transaction.
2. `supabase/migrations/20261021040836_access_health_monitor.sql` adds the private monitor, admin health RPC, and its five-minute cron job.

These filenames match the migration versions assigned in the applied Supabase history; the tested SQL bytes are unchanged.

Before applying the first migration, lock the flag row with `SELECT ... FOR UPDATE` and assert that its full value still matches the freshly captured snapshot. Keep that assertion and migration in one transaction. The migration requires an enabled flag with valid structured configuration and preserves its allowlist, other JSON fields, and `updated_by`. Do not substitute a synthetic administrator identity. Record migration history through the normal deployment runner.

After deployment, run one scan as the database owner, then verify the scheduled job completes a later run:

```sql
BEGIN;
SET LOCAL statement_timeout = '60s';
SELECT vinetrack_private.run_access_health_scan();
COMMIT;
```

Expected completed status is `succeeded`, with zero mismatches and errors. Initial corrections are expected when derived state is stale. A repeated scan should report zero corrections unless an entitlement changed in between. A signed-in system administrator can call `admin_access_health()` to check rollout, scheduler, last success, and open issue count. This RPC intentionally rejects anonymous and ordinary users.

## Validation

Tests call the actual functions and roll back every fixture, flag change, cache update, and audit entry. Before testing fixture writes on a different database, inspect its triggers: the validated installation had no outbound hooks on fixture or induced tables. The signup trigger only writes local trial and billing-event rows.

From the repository root, assemble predeployment tests from the exact migration files:

```bash
python - <<'PY'
from pathlib import Path

correction = Path('supabase/migrations/20261021040736_shared_access_correction.sql').read_text()
monitor = Path('supabase/migrations/20261021040836_access_health_monitor.sql').read_text()
cases = [
    ('tests/shared_access_rollback.sql', correction, '/tmp/vinetrack-access-test.sql'),
    ('tests/access_health_rollback.sql', correction + '\n' + monitor, '/tmp/vinetrack-health-test.sql'),
]
for harness_path, ddl, output in cases:
    harness = Path(harness_path).read_text()
    assert harness.count('\nBEGIN;\n') == 1
    assert harness.rstrip().endswith('ROLLBACK;')
    Path(output).write_text(harness.replace('\nBEGIN;\n', '\nBEGIN;\n' + ddl + '\n', 1))
    print(output)
PY
```

Run each generated file through the administrator SQL runner as a single request, or use an already configured PostgreSQL service:

```bash
psql 'service=vinetrack_admin' -X -v ON_ERROR_STOP=1 -f /tmp/vinetrack-access-test.sql
psql 'service=vinetrack_admin' -X -v ON_ERROR_STOP=1 -f /tmp/vinetrack-health-test.sql
```

Require `failed = 0` in each result; boolean assertion failures are returned as rows. SQL execution errors abort the transaction. The monitor harness uses a guarded continuation cursor reaching only two synthetic accounts. Do not prepend monitor table-creation DDL to an installation that already has those tables; use the standalone harness on the installed schema when no unfinished scan exists.

## Verification record

The actual-function regression suites passed: 71 backend checks and 25 monitoring checks. The original implementation fails 25 of the same backend cases. Repeated scans, caller-context restoration, emergency disable, original trial dates, grant terms, and client permissions are covered by the test fixtures.

Run deployment-specific population checks and retain their outputs in the authorized deployment record. Do not add customer identities, allowlists, usage statistics, or live scan outputs to this repository. The signed-in system-admin health RPC provides the current aggregate result.

The monitor's security design intentionally combines RLS without client policies on its private tables with an authenticated admin RPC. Explicit privileges deny client access to the private runner and tables; the RPC independently checks system-admin status. Review database advisories after applying the migrations and verify these restrictions with the regression suite.

## Monitor behavior

The job `vinetrack-access-health-every-five-minutes` checks at most 250 accounts per invocation, yields after an account when 45 seconds have elapsed, and has a 60-second statement timeout. An unfinished run resumes from its saved UUID cursor. An advisory lock prevents overlapping scans.

The monitor refreshes derived state, compares the app RPC and vineyard matrix with canonical decisions, deduplicates issues by account and issue type, and resolves issues after healthy scans. It preserves an intentional emergency flag disable. It does not create grants, extend subscriptions, change memberships, or extend/reset trial dates. The existing app RPC may persist a missing trial using the original signup date plus three calendar months, or mark an already-expired trial's status expired. Repeated scans do not repeat those bookkeeping events.

Run history is retained for 30 days and resolved issues for 90 days. Private tables and the runner are unavailable to anonymous, authenticated, and service-role clients. The owner-run scheduler is the execution path; the admin RPC exposes aggregate health.

## Pause and resume

To pause monitoring, run this as the job's owning database role. It affects only the exact named job in the current database:

```sql
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'vinetrack-access-health-every-five-minutes'
  AND database = current_database()
  AND username = current_user;
```

Unscheduling prevents subsequent runs; an already-running scan may finish. Access resolution and the rollout flag remain active. Resume with the original command so the health RPC recognizes the schedule:

```sql
SELECT cron.schedule(
  'vinetrack-access-health-every-five-minutes',
  '*/5 * * * *',
  'SET statement_timeout = ''60s''; SELECT vinetrack_private.run_access_health_scan();'
);
```

## Rollback

`rollback/access_health_monitor.sql` is a transaction body that removes only the named job, `admin_access_health()`, the private runner, and the two new monitor tables and their owned indexes/sequence. It preserves the existing `vinetrack_private` schema, unrelated jobs, entitlement state, and commercial records. It acquires the scanner's advisory lock and stops on unexpected dependencies. Run it inside `BEGIN`/`COMMIT`, or with `psql --single-transaction -v ON_ERROR_STOP=1 -f rollback/access_health_monitor.sql`.

For a complete access rollback, assemble one transaction in this order:

1. Execute the monitor rollback body.
2. Lock the shared-entitlement flag row and compare it with the expected current deployment configuration. Stop if an administrator changed it after the snapshot being used.
3. Execute `rollback/shared_access_functions.sql`. It restores the captured originals of `_user_level_access`, `_vineyard_entitlement_for`, `admin_user_access_detail`, `_admin_refresh_entitlement_state`, `get_my_vinetrack_access`, and `set_system_feature_flag`, then removes the new shared validity helper.
4. Restore the captured predeployment flag's `value`, `is_enabled`, `value_type`, `updated_at`, and `updated_by` on the existing row. Use the captured values; do not reconstruct the allowlist or assign an administrator identity.
5. Verify the restored function signatures and flag snapshot, then commit. Roll back the whole transaction on any discrepancy.

Do not run the function rollback separately from flag restoration: scope semantics and the staged cohort must change together. Keep ordinary migration history accurate using the deployment runner's rollback procedure. Derived entitlement rows can be refreshed under the restored resolver; do not restore historical grants or trial dates from cache records.

## Client compatibility limits

The public app RPC keeps all 34 column names, types, and order; the canonical helper keeps its 22-column contract. Inherited non-trial expiry is also returned in `current_period_end`, which released clients already read. Inherited responses redact the funding subscription and licence identifiers.

The server change helps clients that call the shared RPC and honor its rollout flag. An offline device receives a corrected decision when it reconnects and refreshes. A build that does not call the shared resolver still needs a supported app update. Mobile refresh/cache changes and portal health UI changes require their separate build and distribution workflows; a SQL migration does not publish a mobile binary. Missing mobile-version telemetry is a coverage gap, not evidence that access is broken or that a handset received an update.
