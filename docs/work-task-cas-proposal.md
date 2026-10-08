# Work Task CAS contract v1 — complete review proposal

**Status: proposed only; not applied, deployed, SQL-executed or behaviorally verified.**

Prepared 2026-10-08 against the accepted live-inspection findings and current local schema/model definitions. A fresh metadata request in this turn could not run because `SUPABASE_ACCESS_TOKEN` was not available to the process. This is not a claim of a fresh live-schema match. Review the assumptions below against your live database before deployment.

## Deliverables

- `docs/work-task-cas-proposed.sql`: complete expansion DDL, receipt/RLS design, private helpers, revision trigger, full seven-argument RPC and read-only discovery queries. No client RPC EXECUTE grant.
- `docs/work-task-cas-cutover-proposed.sql`: physically separate enforcement cutover, vintage trigger replacement, bypass guard and privilege revocations. Requires independent compatibility sign-off.
- `docs/work-task-cas-acceptance-proposed.sql`: rollback-only SQL behavior tests for a disposable full-schema clone. These tests have **not** been executed.
- This document: ownership, compatibility decisions, rollout/rollback, concurrent acceptance and deployment-verification requirements.

Nothing is placed in `supabase/migrations/` or an automatic migration directory. No existing SQL file, Portal code, mobile code, queue/replay switch, Pruning CAS function or calculator is changed by providing these files.

## Important deployment decision

The expansion can be staged with the new RPC **not executable by clients**. Expansion is NOT stale-write protection: older unconditional writers remain unsafe until cutover.

The enforcement cutover is intentionally fail-closed. It blocks protected Work Task header writes by ordinary REST clients **and** older SECURITY DEFINER functions with a different owner. That includes any existing server function which creates a Work Task, archives/deletes it, or changes protected planning/completion fields. In particular, a pruning-to-Work-Task function which INSERTs a header will be blocked even if its pruning/allocation implementation itself is unchanged.

**Do not deploy the cutover until those dependencies have been reviewed and a compatible integration path or deliberate feature freeze has been approved.** This proposal does not modify those functions and cannot promise uninterrupted legacy behavior. Allowing them to unconditionally change protected columns would reopen the exact bypass the contract must close. A safe transparent conversion of an old write with no base revision/operation identity does not exist.

## 1. Schema assumptions to verify

The RPC uses existing `public.work_tasks` columns:

- `id`, `vineyard_id`, `paddock_id`, `paddock_name`, `date`, `task_type`, `duration_hours`, `notes`, `description`, `start_date`, `end_date`.
- `assigned_to`, `assigned_external_resource_id`, `schedule_basis`, `target_el_stage`, `vintage_year`.
- `completed_by`, `completed_at`, `is_finalized`, `finalized_at`, `finalized_by`, `status`.
- `is_archived`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`, `client_updated_at`, `sync_version`.
- Financial/provenance fields exist but are not RPC patch fields. Tests also reference `resources`, `costing_method`, `piece_rate_per_vine`, `piece_vine_count`, `pruning_activity_id`.

Assumed types: UUID identities; timestamptz date/instant fields; TEXT legacy finaliser/status; INTEGER stage/vintage; boolean lifecycle flags; double precision duration hours. Current source evidence is SQL 014, 050 and 119 plus current native models, not authority to recreate older migrations.

Assumed references/helpers:

- Native Supabase `auth.uid()` and real `auth.users` identities.
- `vineyard_members(vineyard_id,user_id,role)` is authoritative membership. If the live table has active/deleted/expiry conditions, add them to **both** actor and internal-assignee helper checks before deployment.
- `vineyards(id,timezone)`; an existing same-vineyard `paddocks(id,vineyard_id,deleted_at)` table.
- `vineyard_external_resources(id,vineyard_id,is_active,deleted_at)` and profiles keyed by UUID.
- `public.has_vineyard_role(uuid,text[])` preserves existing operational permission restrictions. Audit the actual helper body; if additional capabilities/billing restrictions apply outside it, add those checks rather than widening access.
- Existing `public.resolve_vineyard_vintage_year(uuid,date)` and `public.work_tasks_resolve_vintage()` definitions must be saved and diffed before replacement.
- Proposed new incomplete status is `planned`, completed status is `completed`. Confirm Portal status vocabulary and any live CHECK constraints. Do not silently replace a production enum/constraint with this vocabulary.

The role, schema, constraints and indexes use one-shot names. Collisions deliberately abort expansion. Do not hide an incompatible partial install behind `IF NOT EXISTS`.

## 2. New schema and invariants

### Authoritative revision

`work_tasks.server_revision bigint NOT NULL DEFAULT 1`; positive CHECK. A BEFORE trigger sets INSERT revision to 1 and UPDATE revision to old+1, including no-op and approved trusted cost-only header updates. Client-supplied revision values do not control it. `updated_at`, `client_updated_at` and `sync_version` retain their previous meaning; they are not CAS tokens.

An existing PK on task ID already supports row lock/CAS lookup. Additional proposed partial indexes support stage/vintage and internal/external assignment reads. Index choices should be reviewed with production query plans; build large indexes separately with `CREATE INDEX CONCURRENTLY` outside a transaction if required.

### Separate planned and completion dates

Current code uses `end_date` as both planned range end and completed work business day. The proposal adds:

- `planned_end_date timestamptz`: actual planned range end.
- `completion_business_date date`: vineyard-local work completion day, independent of canonical audit instant.

For incomplete v1 date tasks, `end_date` mirrors `planned_end_date`. For completed tasks, it mirrors completion business day at vineyard-local midnight for existing read compatibility. Reopen restores the known planned range mirror, rather than discarding it. Stage tasks have no planned range; their legacy `end_date` may still hold a completed-day mirror.

No bulk history rewrite is proposed. A legacy incomplete date task's old range is captured on first schedule edit or completion. An already-completed historical task does not have an inferable old planned range; do not invent one from its completion day.

### Legacy preservation

`scheduling_contract_version` and `completion_contract_version` are independently 0/1:

- Existing rows start at 0; untouched historical scheduling/lifecycle values remain unchanged.
- Creates are v1 for both.
- Explicit schedule edits validate and adopt v1 scheduling.
- Complete/reopen adopt v1 completion; date-only correction does not fabricate missing historical identity/instant.

Conditional CHECK constraints enforce supported stages, no E-L planned range, vintage/range validity and coherent new lifecycle values without pretending all history was already compliant. NOT VALID avoids an initial whole-table validation scan; it still checks new/updated rows. `VALIDATE CONSTRAINT` may be run separately after auditing legacy data. Old version-0 rows remain intentional exceptions until a separately approved repair.

Mutual internal/external exclusion is retained. Existing identity FKs and external-link triggers remain installed. The RPC UPDATE mentions only actually changed columns, so an unchanged historical soft-deleted/inactive resource does not accidentally invoke an `UPDATE OF assigned_external_resource_id` trigger.

## 3. RPC interface and patch ownership

```sql
public.save_work_task_cas(
  p_task_id uuid,
  p_vineyard_id uuid,
  p_operation_id uuid,
  p_authored_by uuid,
  p_base_revision bigint,
  p_action text,
  p_patch jsonb
) RETURNS jsonb
```

All seven arguments are required; there are no overloads/defaults. Create uses null base; other actions require a positive captured revision. Stable task ID and operation ID are client-generated and persisted before submission. Same operation must retain author, vineyard, action, base and JSON request through restart/retry. An explicit conflict resolution is a **new** operation, not a changed retry.

Allowed actions/fields:

| Action | Patch fields |
|---|---|
| `create`, `edit` | `task_type`, `description`, `notes`, `paddock_id`, `paddock_name`, `duration_hours`, `assigned_to`, `assigned_external_resource_id`, `schedule_basis`, `target_el_stage`, `date`, `start_date`, `planned_end_date`, `vintage_year` |
| `complete` | required `completed_at`; optional `completion_business_date` |
| `reopen` | empty object, optionally expected predicates |
| `completion_date` | required `completion_business_date` |

Optional `expected` object is permitted only for existing-row actions. It can test owned planning fields plus revision, status/finalisation and completion audit fields. Expected values are **additional** predicates; a matching expected selection never overrides a stale base revision.

Absent keys are untouched; JSON null deliberately clears allowed nullable fields. Required fields reject null. Unknown audit, server version, rate, costing, resources, allocation, pruning-provenance, archive and deletion fields are rejected. Internal/external switching requires explicitly clearing the opposite identity. Nested objects/arrays/boolean coercions, string-as-number and decimal stages/vintages are rejected. Timestamp strings must include ISO time plus Z/offset; business dates must be ISO date strings.

No `status` field is accepted from an edit: complete/reopen own lifecycle transitions. Archive/delete and child labour/machine/material/block operations are intentionally outside this v1 API. `paddock_id` remains the existing singular header reference; this is not a hidden replacement of multi-block child authority or the existing allocation APIs. `duration_hours` is an authored planning input, not an accepted frozen rate or total. If its ownership actually belongs to a costing/child rollup trigger, remove it from this allowlist and guard only after a reviewed split of authority.

Create requires nonempty task type and explicit scheduling basis. Date create/mode switch requires an explicit planned `date`; E-L create requires supported target and explicit vintage. There is no silent create-to-edit recovery.

### Example request

```json
{
  "p_task_id": "<stable-task-uuid>",
  "p_vineyard_id": "<vineyard-uuid>",
  "p_operation_id": "<persisted-operation-uuid>",
  "p_authored_by": "<authenticated-user-uuid>",
  "p_base_revision": 17,
  "p_action": "edit",
  "p_patch": {
    "assigned_to": null,
    "assigned_external_resource_id": "<acknowledged-resource-uuid>",
    "expected": { "assigned_to": "<previous-person-uuid>" }
  }
}
```

Success returns `applied:true`, `conflict:false`, contract version, exact operation/author/task/vineyard identities, revision and full canonical row with explicit nullable fields. Decode revisions as 64-bit integers (or losslessly as decimal strings at a Portal transport boundary); never round PostgreSQL timestamps for expected comparisons. A duplicate returns **the identical saved response**, with no newly added `idempotent` field and no substituted current row.

A conflict returns `applied:false`, `conflict:true`, reason, operation/task/vineyard identifiers, current revision/canonical or null if unavailable. Reasons include `already_exists`, `not_available`, `deleted`, `revision_mismatch`, `expected_mismatch`, `identity_unavailable`. No receipt is inserted for a conflict and no automatic rebase occurs. Invalid requests raise 22023 (native invalid UUID/date casts may raise their normal 22xxx errors); denied access raises 42501. Transient serialization/deadlock failures roll back and can be retried with the **same immutable** operation.

`expected` uses exact JSONB comparisons against the canonical snapshot. This preserves absent/null distinctions. Timestamp predicates should be copied from the raw PostgreSQL JSON snapshot; semantically equivalent differently formatted instants conservatively conflict. Integer spellings must be canonical. JSONB equality ignores object key order, not absent-versus-null intent.

## 4. Transaction, revision and receipt guarantees

Order:

1. Require authenticated author to match `auth.uid()` and real owner/manager/supervisor/operator membership. Hold the member row with FOR SHARE against concurrent revocation; verify existing permission helper and vineyard timezone.
2. Serialize operation ID using transaction advisory lock. Read global receipt as the non-login owner; equality-check entire immutable request before returning any data. Different author/vineyard/action/base/patch with the same ID is rejected without disclosing the other receipt.
3. Lock stable task ID with a second advisory lock (covers absent-row create), then lock existing same-vineyard row FOR UPDATE.
4. Reject existing creates, deleted rows, missing baseline, stale revision or mismatching expected values without changing row/children/receipt.
5. Validate/apply only allowlisted values; lock newly selected membership/resource/block dependencies against concurrent deletion/deactivation. Unchanged historical identities are not silently cleared.
6. Mutate only the header. Revision advances. Read canonical after synchronous trigger effects and reject any changed owned value rather than acknowledging a transformed/suppressed request.
7. Insert receipt and exact acknowledgement in the same transaction. Receipt failure rolls back mutation, revision and all synchronous effects.

Receipts have a UUID primary operation ID, task/vineyard/author references, action, base revision, full JSONB request, applied revision, exact canonical acknowledgement and server creation time. They are immutable, with no client INSERT/UPDATE/DELETE privilege. Client reads are limited to the author and currently operationally permitted vineyard. The isolated RPC owner can inspect global collisions only through the fixed RPC body. The task's current row may legitimately diverge from an earlier receipt; a client must not replace a newer cache with an old receipt snapshot. It should acknowledge only that persisted generation, then independently pull current state.

**Retention:** no receipt TTL, cascade deletion or operation-ID reuse is proposed. Deleting receipts breaks retry proof. RESTRICT references intentionally affect hard deletion of vineyards/tasks/users, including cascades from older tables. Review account erasure, vineyard deletion and audit/retention policies; use a separately designed receipt tombstone/archive that preserves exact retry identity if deletion is required. Do not deploy a cleanup job which removes evidence while released clients can still replay.

## 5. RLS, ownership and bypass protection

- Dedicated `vinetrack_work_task_cas_owner`: NOLOGIN, NOINHERIT, NOBYPASSRLS; not table owner; no role grantees, no schema CREATE after setup. Only the new public RPC is owned by it.
- RPC executes as this role with fixed pg_catalog search path and qualified identifiers. It cannot rely on a forgeable custom GUC such as `app.cas_allowed=true`.
- Work Task role SELECT/INSERT/UPDATE policies use existing vineyard-role helper. Existing member/support read policies remain unchanged. No broader admin mutation access is added.
- Private migration-administrator-owned security-definer helpers provide narrow membership/timezone/link/resolver operations without granting unrestricted directory/profile table reads to the RPC role. Private schema/functions have no public/client access.
- Internal newly chosen assignee must have actual same-vineyard membership and a profile. Admin status alone is insufficient. Unchanged former-member history is preserved; an explicit clear followed by reselect requires current membership.
- External newly chosen resource must be same-vineyard, active and nondeleted. It is held against concurrent deactivation while the task transaction commits. Unchanged inactive/deleted history can remain.
- Header gate is SECURITY INVOKER and validates execution owner, not JWT role strings. Direct client INSERT/UPDATE/DELETE/upsert privileges are revoked, including existing column grants. Audit inherited privileges and custom integration roles.
- An ALWAYS trigger blocks protected changes by other SECURITY DEFINER owners too. Nonprotected trusted server cost/provenance-only updates may continue **only when every protected field stays unchanged**, and still advance the header revision. This does not grant any new financial write authority or assert those older costing operations are now CAS-protected.
- INSERT/DELETE/TRUNCATE by client roles are denied. RPC role has no DELETE/TRUNCATE grant. Administrative schema owners/superusers capable of disabling triggers, altering functions or granting role membership remain a trusted infrastructure boundary; SQL cannot defend against its own privileged administrator.

Protected header fields are listed in the SQL gate, including identities, planning inputs, schedule/vintage, lifecycle, archive/soft delete and immutable task scope/creator. `updated_at`, `updated_by`, legacy sync metadata and existing nonprotected financial/provenance fields are outside that projection to preserve existing server-owned costing writes. Audit all new columns on future migrations: new planning/completion columns must be added to the protected projection and RPC allowlist as appropriate, not accidentally treated as cost-only.

A revision trigger alone is NOT bypass closure. There is deliberately no grant which permits old protected PATCH/upsert to continue alongside CAS.

## 6. E-L, dates and vintage convention

Supported catalogue targets are exactly:

`1,2,3,4,7,9,11,12,13,14,15,16,17,18,19,20,21,23,25,26,27,29,31,32,33,34,35,36,37,38,39,41,43`.

New/touched E-L schedules require one of these targets and no planned start/end range. Legacy mandatory `date` remains a compatibility storage value, never a planned/overdue/calendar date.

**Proposed convention requiring your approval:** for new E-L tasks or switching to E-L, mandatory compatibility `date` is local noon on January 1 of the explicitly selected vintage year. Noon avoids routine midnight DST ambiguities. Existing E-L compatibility dates remain unchanged on unrelated edits or stage/vintage edits. E-L vintage is not derived from compatibility `date`; explicit vineyard scope and supported year bounds 1900–9998 are enforced. There is no verified separate per-vineyard vintage registry in the accepted inspection, so this proposal does not fabricate one. If you have such a registry or a different range, add its membership check and approve that convention before deployment.

Date creates and explicit changes to the legacy planned `date` derive vintage with the existing vineyard resolver; an explicitly conflicting vintage is rejected. Unrelated edits preserve the frozen vintage even if season preferences changed. A mode-only transition preserves the existing frozen vintage unless an explicit validated vintage is supplied. This means a stage-to-date transition can retain a previously selected costing vintage even if the newly required date would normally resolve differently; that is a deliberate review decision, not a hidden trigger assumption. A subsequent explicit date edit re-resolves it. If reporting must instead always follow date on mode transition, revise this rule explicitly before deployment.

The work_tasks-specific vintage trigger replacement returns the RPC-validated vintage unchanged and blocks other scheduling/create attempts. It does not modify the shared resolver, pruning vintage triggers or any pruning lifecycle. Save its exact live old definition for rollback.

Potential calendar edge: extreme historical timezone date discontinuities can normalize a local noon. Verify your supported historical range/timezones. Consumers must ignore compatibility date on stage schedules regardless of its value.

## 7. Completion/reopen identity and historical records

Complete action:

- Requires an incomplete, nonarchived, nondeleted task at the captured revision.
- Sets `completed_by` to the authenticated persisted author, NEVER assignee, creator, arbitrary request field or replaying different account.
- Requires immutable authored `completed_at`, with explicit offset, finite instant and at most five minutes ahead of server clock. Proposal permits past instants from 1900 onward with no offline-age cutoff. It does not pretend a client-reported clock is cryptographic proof of when work occurred.
- Does **not** require authored instant to be after server `created_at`: a task and its completion can both be authored offline and the create can arrive later.
- Uses supplied business day or derives vineyard-local day of the authored instant. Business day must be finite and on/after 1900-01-01, cannot exceed that local day, and date-scheduled work cannot precede its planned start/date. E-L compatibility date is never a bound.
- Stores coherent status/finalisation and mirrors legacy finaliser UUID text/instant; new canonical completer/timestamp are independent from assignee and business day.

Reopen clears current completer/instant/business day/finalisation, resets status to approved incomplete vocabulary, preserves assignment, target, vintage and known planned range. Prior completion remains in immutable receipts; the current row represents current lifecycle only.

Date-only correction changes business day and legacy mirror only. It preserves canonical instant/completer/finaliser, including historical unknown identity. It requires a known historical completion/finalisation instant and otherwise rejects for a separately reviewed correction workflow. It does not invent identity or use current server replay time for old records.

This RPC is for manual Work Task header actions. It does not rewrite Trip, Spray, Stop or Tank finalisation. Read-only historical fallback attribution remains recorded completer → verified unambiguous same-vineyard finished Trip operator → independently verified finaliser → unknown. A future automatic Trip-authoritative task completion API must validate the linked Trip in the database and join this gate; do not pass a Trip operator as an arbitrary `p_authored_by` to bypass authenticated manual identity.

## 8. Existing Portal / released-client compatibility

| Writer/workflow | Expansion | Enforcement |
|---|---|---|
| Existing task reads | Additive fields; check strict decoders and SELECT views | Retained under existing read RLS |
| Old REST task INSERT/PATCH/upsert | Still possible, still unsafe | Rejected; no auto-conversion |
| New Portal/mobile CAS adapter | Must remain disabled | Permitted after deployed verification |
| Old complete/reopen/date PATCH | Still legacy behavior | Rejected; switch to RPC or deliberate freeze |
| Existing archive/soft-delete RPC | Existing behavior | Protected mutation blocked; needs separately reviewed CAS lifecycle extension |
| Pruning RPC allocating/progressing without writing a task header | Unchanged | Unchanged unless a dependent trigger writes a protected task header |
| Pruning-to-Work-Task header INSERT or protected rollup update | Existing behavior | Blocked; must resolve before cutover if this workflow must remain available |
| Trusted cost-only updates with protected projection unchanged | Existing authority retained; revision added | Existing authority retained; revision advances |
| Child labour/machinery/material/block APIs | Not rewritten | Unchanged unless their triggers change protected header fields |
| External resource directory CRUD / existing pruning resource CAS | Unchanged | Unchanged |

Full legacy upsert payloads often include old `date`, `end_date`, `is_finalized` and status values; allowing only selected new assignment columns to be protected is insufficient. Released clients with no captured revision and receipt cannot safely replay these payloads. Do not infer a safe baseline from their timestamp or current server row. Their unsent data must be retained/exportable/conflicted, not silently acknowledged/dropped.

No source changes to Pruning CAS or costing are requested in this proposal. Nevertheless, strict header enforcement may block existing generators/rollups as described. If keeping those entire workflows uninterrupted is mandatory, cutover is blocked until their boundary is approved; no exception is concealed in a role-name allowlist.

## 9. Migration / deployment sequence

1. Save exact schema, role/column grants, RLS policies, all Work Task triggers, the old vintage function, public/private SECURITY DEFINER functions, API/integration writer inventory and fingerprints of all pruning/costing functions. Confirm backups/PITR and a disposable full-schema clone.
2. Run discovery against the live schema with read-only queries. Resolve every assumption/status/vintage/capability difference. Check function-owner role membership, schema CREATE exposure, restrictive policies and publication/replication paths. Re-read metadata after any change.
3. Review expansion lock/rewrite/index costs and RESTRICT receipt references. Stage A-C in the clone, then separately approved production expansion. Do not advertise the guarded contract or enable offline replay during expansion. Old writes still advance revision, providing the new baseline read token.
4. Confirm minimum Portal/mobile versions, feature gates, error handling and user-visible pending/conflict retention. Update Portal/integration adapters separately under your control. Do not erase or translate old queued intent into a guessed CAS baseline.
5. Exercise both supplied SQL tests and concurrent/HTTP/dependency acceptance below on the clone. Resolve archive/delete/generator/rollup compatibility. If any needed protected writer remains legacy, do not cut over.
6. In a controlled maintenance window, apply the separate cutover file in one transaction; it locks task headers, replaces the task vintage trigger, installs ALWAYS guards, closes table/column grants and grants the one RPC. Check default grants have not reintroduced access, and reload PostgREST schema.
7. Confirm live deployed body/signature/grants/role graph/trigger ordering and agreed staging acceptance. Retain offline replay off until explicit verification. Approved live acceptance requires designated records, actors and a cleanup/audit policy; this proposal does not perform it.
8. Only a subsequent explicitly approved client integration may persist/submit new CAS operations. Preserve exact author/account dependency order, resource acknowledgement, immutable base/payload, and receipt-aware generations. Never replay old snapshots as new operations automatically.

Existing BEFORE triggers must run before the final header gate; PostgreSQL orders same-kind triggers by name. Inspect any trigger sorted after `zzzz_work_task_cas_header_gate`, AFTER trigger, partition trigger, rule or deferred write. The RPC verifies owned fields after synchronous effects, but unguarded integration paths still require this inventory. New trusted mutating functions must not be owned by the isolated RPC role just to avoid designing a proper CAS boundary.

## 10. Rollback

### Before enforcement / before any receipts

Because client EXECUTE is not granted, expansion can be rolled back after checking no new-role activity/receipts: drop only proposed objects in reverse dependency order, remove revision trigger, then drop added columns/role/schema. Do not use CASCADE against unrelated dependencies. Column removal and receipt deletion are destructive and require separate approval; retaining additive fields is usually safer.

### After enforcement / after receipts

Preferred operational rollback is **freeze**, not reopening stale writes:

```sql
BEGIN;
REVOKE EXECUTE ON FUNCTION public.save_work_task_cas(uuid,uuid,uuid,uuid,bigint,text,jsonb)
  FROM authenticated, anon, PUBLIC, service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
```

Keep revision, receipts, read access and bypass guard. Pending new operations stay unresolved until fixed code/server contract is restored. Do not drop receipts, reset revisions or roll back a success already returned to clients.

A full unsafe legacy-writer rollback requires a separately approved maintenance decision:

1. Keep replay disabled and suspend all task writers.
2. Export/preserve receipts and acknowledged canonical data; verify which operations committed. Stop new adapters.
3. Restore the **exact saved** old vintage definition and exact old table/column grants/policies; remove the new header gate only as part of that explicit decision. Do not guess `GRANT ALL`.
4. Keep revision/receipt storage where possible. Switching back to legacy lifecycle can destroy new identities/plan-range semantics; review per-record compatibility before allowing it.
5. Treat stale-write protection as withdrawn. Re-verification is mandatory before CAS/replay resumes.

PITR restores database state but not external clients' knowledge of acknowledgements; it requires reconciliation of receipts/generations rather than silently retrying everything as new.

## 11. Verification queries (read-only)

Run these after your approved deployment. Record exact outputs, not just an HTTP 200:

```sql
SELECT oid::regprocedure, pronargdefaults, prosecdef,
       pg_get_userbyid(proowner) AS owner, proconfig, proacl,
       pg_get_functiondef(oid)
FROM pg_proc
WHERE oid='public.save_work_task_cas(uuid,uuid,uuid,uuid,bigint,text,jsonb)'::regprocedure;

SELECT rolname,rolcanlogin,rolinherit,rolsuper,rolbypassrls,rolcreaterole
FROM pg_roles WHERE rolname='vinetrack_work_task_cas_owner';
SELECT m.* FROM pg_auth_members m
JOIN pg_roles r ON r.oid=m.roleid
WHERE r.rolname='vinetrack_work_task_cas_owner'; -- expect zero rows

SELECT c.relname,c.relrowsecurity,c.relforcerowsecurity,pg_get_userbyid(c.relowner)
FROM pg_class c
WHERE c.oid IN ('public.work_tasks'::regclass,'public.work_task_write_receipts'::regclass);
SELECT * FROM pg_policies WHERE schemaname='public'
AND tablename IN ('work_tasks','work_task_write_receipts');
SELECT tgname,tgenabled,pg_get_triggerdef(oid),pg_get_functiondef(tgfoid)
FROM pg_trigger WHERE tgrelid IN ('public.work_tasks'::regclass,
  'public.work_task_write_receipts'::regclass) AND NOT tgisinternal ORDER BY tgname;

SELECT conname,convalidated,pg_get_constraintdef(oid)
FROM pg_constraint WHERE conrelid IN ('public.work_tasks'::regclass,
  'public.work_task_write_receipts'::regclass);
SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='public'
AND tablename IN ('work_tasks','work_task_write_receipts');

SELECT role_name,has_table_privilege(role_name,'public.work_tasks','INSERT') AS can_insert,
  has_table_privilege(role_name,'public.work_tasks','UPDATE') AS can_update,
  has_table_privilege(role_name,'public.work_tasks','DELETE') AS can_delete,
  has_table_privilege(role_name,'public.work_tasks','TRUNCATE') AS can_truncate,
  has_any_column_privilege(role_name,'public.work_tasks','UPDATE') AS any_column_update
FROM (VALUES ('anon'),('authenticated'),('service_role')) r(role_name);
-- All above mutation checks must be false; also audit custom inherited roles.

SELECT p.oid::regprocedure,pg_get_userbyid(p.proowner) AS owner
FROM pg_proc p WHERE pg_get_userbyid(p.proowner)='vinetrack_work_task_cas_owner';
-- Only the intended RPC; no arbitrary SQL wrappers.

SELECT p.oid::regprocedure,md5(pg_get_functiondef(p.oid)) AS definition_fingerprint
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE p.prokind='f' AND n.nspname='public'
AND (p.proname ILIKE '%pruning%' OR p.proname ILIKE '%cost%');
-- Compare with pre-migration fingerprints: unchanged.
```

Check EXECUTE grants for anon/PUBLIC/service role are absent; authenticated has the intended RPC only. `has_function_privilege` can additionally verify inherited effective privileges. Review the schema-qualified receipt/private helper ACLs and table triggers, not just public signature text. Inspect app/integration code separately; PostgreSQL function-body search does not identify every external REST writer.

## 12. Supplied SQL behavior acceptance

The rollback-only script exercises actual tables/RLS/RPC under `SET LOCAL ROLE authenticated` with disposable fixture users/vineyards/resources:

- Create, initial revision, exact lost-response retry, duplicate stable ID without receipt.
- Operation-ID payload reuse and cross-author reuse rejection.
- Expected null mismatch, stale revision and exact receipt after newer edits.
- Scoped internal/external selection, deliberate clearing, mutual exclusion, foreign/inactive rejection.
- Supported/unsupported stages, strict types, mode-switch required date, explicit E-L vintage preserved by trigger.
- Canonical authored completion instant independent of later server create/replay, deterministic UTC→Sydney next-day boundary, assignment/stage retention, correction preserving audit and reopen clearing current lifecycle.
- Planned-range preservation/reopen mirror and frozen piece rate/count/resource/provenance comparison.
- Preservation of unchanged soft-deleted historical external resource through unrelated edit.
- Real role-based read/receipt isolation, operational writer versus memberless/outsider denial (and a read-only member role separately if your schema supports one), author impersonation rejection.
- Direct PATCH/upsert/delete/receipt mutation denial and legacy privileged protected UPDATE denial.
- Revision increment on trusted nonprotected no-op write.
- Injected receipt failure proving entire task mutation/revision rollback.

Fixture constraints, profile-creation triggers and auth columns must match the clone. The script includes administrator-only receipt failure injection **inside the rollback transaction**; never use it in production. A parser pass is not a substitute for running these assertions.

## 13. Additional mandatory acceptance

### Two-session stale-write contention

Use separately approved clone test IDs, a member JWT identity and fresh operation IDs. Create a task via CAS and COMMIT to make the fixture visible to both sessions. Capture revision `N`. Session A:

```sql
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','<writer-uuid>',true);
SELECT set_config('request.jwt.claims','{"sub":"<writer-uuid>","role":"authenticated"}',true);
SELECT public.save_work_task_cas('<task>','<vineyard>','<operation-A>',
  '<writer>',<N>,'edit','{"notes":"writer A"}');
-- Leave transaction open until Session B has begun its conflicting call.
```

Session B uses the same captured N but a different operation and `{"notes":"writer B"}`. It must block until A commits, then return revision conflict and A's canonical notes. A COMMIT; B COMMIT. Assert one task mutation/receipt, not two acknowledgements. Repeat with different authenticated permitted actors and both directions Portal-shaped/mobile-shaped.

### Same-operation concurrent retry

A submits an edit and leaves transaction open; B submits identical author/task/vineyard/operation/base/patch. B waits. After A commits B returns byte-equivalent JSONB acknowledgement; one receipt and one mutation. Repeat with A ROLLBACK: B may apply once. Repeat with B's payload/actor different: reject 22023, no mutation. Repeat simultaneous creates with same stable task ID and different operation IDs: one create, one conflict, never edit. Repeated advisory-hash collisions may serialize but must not produce a false acknowledgement.

### Role/membership changes and dependencies

- Hold actor/assignee/resource locks in A; try actor revocation/internal member removal/resource deactivation in B. Mutations must serialize; next new task operation must fail scope/selection validation as appropriate.
- A permitted user removed after successful write cannot obtain a receipt by retrying; no mutation occurs. Another account cannot replay that author's queued intent.
- Test unknown task, deleted task, foreign-vineyard ID collision, missing base and missing auth. No foreign canonical data is returned.
- Directory creation must be acknowledged before assigning its ID; incomplete/failed resource INSERT cannot be acknowledged by task RPC.
- Review support-admin account without vineyard membership: must be denied even if read support policies grant visibility.

### Historic variants / schedule edge cases

- Load actual-shape historical fixtures **before cutover** in the disposable clone: inactive/former-member identities, unknown completer, free-text finaliser, legacy date range, legacy E-L compatibility values, unsupported legacy target and frozen vintage.
- Notes-only edits must not change date/stage/vintage/history; newly touched invalid schedule must fail until explicitly corrected.
- Date→E-L and E-L→date explicit choices, target clear, range clear/set, selected vintage convention and season-start preference changes.
- Date-only historical correction preserves unknown identity; missing historical instant rejects visibly.
- Future authored completion, invalid offsets, invalid business day, date planned lower bound, no E-L lower bound, DST midnight and clock-tolerance edges.

### Existing protected workflows / unchanged costing and Pruning CAS

Inventory and exercise every discovered task-writing function with designated clone fixtures. Verify no legacy protected UPDATE, INSERT/upsert, inherited role, SECURITY DEFINER wrapper or external service PATCH succeeds outside the contract. Do not consider a caught error in a pruning generator successful compatibility: it is a deployment blocker if that workflow must remain operational.

Compare before/after all frozen labour/piece-rate/machinery/fuel/material snapshots, linked Trip totals and existing rollup/export results under assignment/stage/complete/reopen actions. Compare function-definition fingerprints and run existing SQL calculator regressions on the clone as agreed. Cost-only trusted mutations should advance revision and conflict with a pending old task edit. No assignment creates costs or modifies child records.

Run existing `set_pruning_activity_resource_cas` acceptance unchanged: baseline expectations, selection, conflict, retry and allocation counts. This is a separate contract; the new task RPC must never invoke it or redo allocation work.

### PostgREST and device/network acceptance

- Verify named-argument resolution (one exact signature/no defaults), JWT identity, schema cache, nullable keys and bigint/timestamp codec handling via actual HTTPS RPC calls.
- Assert old REST PATCH/upsert rejects and a zero-row/missing canonical HTTP result is never acknowledged.
- Drop the success response after a committed operation; restart the authoring client, retry unchanged operation and assert exact receipt and no extra row/child mutation. Pull newer Portal change and retry old receipt: acknowledge only old generation, do not replace new canonical state.
- Test account/vineyard switch, revocation, child/resource dependency delays and disk write failure; no request before intent is durable, no wrong-account replay, visible pending/conflict.
- Live Portal/iOS/Android contention requires separately authorised records/access. SQL fixtures or mocked transports are not live acceptance.

## Verification status and replay gate

These are supplied proposals/tests, not deployed guarantees. No application builds are rerun because no application source changed. Standalone PostgreSQL SQL/PL/pgSQL parsing passed: expansion **54 statements / 8 bodies**, cutover **14 / 2**, acceptance **54 / 11**. This is syntax review only. Catalog-bound `%ROWTYPE` declarations are substituted with `record` solely in parser input because the parser has no live catalog; the proposal files retain their actual types. This does not validate live column/type resolution, RLS, grants, trigger behavior, dynamic UPDATE execution or acceptance outcomes. Database tests, PostgREST calls and compatibility still require your clone/live review.

**Work Task offline replay stays disabled until the exact deployed contract and bypass closure have been re-inspected and acceptance has passed. Existing Pruning CAS and costing calculations remain unchanged.**
