# Existing-schema Work Task parity and minimal conflict protection

Updated 2026-10-09. Review proposal only: no SQL applied, no Portal source changed, no release submitted.

## Superseding decision

The `save_work_task_cas` expansion, receipt tables, new revision/date columns, enforcement gate and vintage trigger replacement are WITHDRAWN. Do not apply any of the four prior `work-task-cas-*` files. Existing `work_tasks` fields, RLS, costing authority and generated-task functions remain authoritative. Feature parity does not require a new Work Task schema or RPC.

User-reviewed Portal findings are accepted: ordinary edits advance `sync_version` without an expected-version predicate; completion has a conditional version check but does not fully honour the originally loaded revision; database internal-assignee membership enforcement is incomplete. Portal source has now been read from `stockmansridge/vinetrack-a0d975b1` at immutable commit `2bed6ee35f44be381c5b5ae87dbae4c9c5065046`: query, schedule and completion helpers directly; page orchestration and completion section via extracted source. The user verified the deployed vintage trigger. This is source evidence plus user-verified deployment evidence, not a fresh live database inspection.

## Mobile implementation in this pass

Both apps now retain the actual server `sync_version` in task models/caches. Missing older cache versions remain absent; they are never defaulted to 1 or invented from timestamps.

Both native task editors now use **Save planning online** / their main Save action for new tasks, assignment, scheduling and editable header metadata. Explicit Complete, Reopen and completed-date correction use the same durable original-baseline boundary. They:

1. Captures a scoped online read against the version and selection/lifecycle/header values originally loaded by the editor. Missing/mismatching version, keys, pending header mutations, offline state or unreadable draft prevents capture. This is not a save-time refresh/rebase.
2. Persists the full account/vineyard/task-scoped draft and original raw baseline before mutation. Resumed drafts keep that baseline; old drafts without it are not automatically upgraded. Dates retain original raw server precision in predicates.
3. Checks the author is a current operational vineyard member, exclusive assignment, selected member membership and active/nondeleted same-vineyard external resource. These dependency reads improve mobile validation but are NOT an atomic database membership guarantee: revocation/deactivation may race them. Existing RLS and external-link validation still run on the PATCH.
4. INSERTs new stable IDs only (never upsert). E-L creates omit `date` and `vintage_year`, clear `start_date`, and start unfinalized; the database default/trigger owns the anchor/vintage. Date creates send the selected YYYY-MM-DD day as `date` and `start_date`. Edits PATCH header metadata and deliberate planning changes with original N+1. Date→E-L preserves raw stored `date`, clears `start_date` and sets the catalogue target. E-L→Date sets selected day in both date fields and clears target. Unchanged historical assignment and schedules are omitted. No planned end field is written.
5. Filters the UPDATE by task/vineyard, original `sync_version`, raw `updated_at`, deletion and all observed scalar planning/header/lifecycle values, including nulls. This catches relevant changes by completion/legacy writers which fail to advance the version; read-before-write comparison alone is not used as protection.
6. Requires exactly one returned row, the requested selection/version and unchanged observed nonowned values. No canonical cache update is made for a zero-row, transformed, malformed, failed or account-switched response. Such outcomes remain unknown/conflicted, not acknowledged. A transformed write might already have committed; response verification cannot roll it back.
7. Persists a one-shot `WorkTaskWriteIntent` (raw baseline plus exact payload) before network initiation. An earlier unacknowledged intent blocks replacement/retry even after restart. Completion payload includes authenticated `completed_by`/`finalized_by`, actual press instant in both audit timestamps, and independent YYYY-MM-DD `end_date`; reopen clears all five completion values plus finalization state; correction owns only finalization state/end date plus editor/version metadata. No `status` write is used for completion. Account/vineyard/pending-header changes prevent acknowledgement. Full planning drafts remain separate; created drafts are archived under the acknowledged task ID. An explicit discard-planning-draft action does not delete an unknown write intent. No automatic rebase/replay or unknown-outcome resolution is provided.
8. Reconciles selected block joins only after a verified header response using the existing separate allocation mechanism. Header success is not atomic block/cost-child success. Existing commercial fields, created timestamps, pruning link and scalar costing snapshots are now included in observed predicates; resource JSON, child costing and Trips are not rewritten. Legacy iOS inline labour-resource edits stay in the complete draft rather than being silently added to this header PATCH.

This is **one-sided, narrow online conflict mitigation**, not universal cross-client CAS or exact retry proof. An old unconditional Portal/mobile writer can still overwrite a newer row after a guarded save. No new offline replay was enabled.

Android duplicate create recovery now retains a 409 as a BLOCKED local intent. It never converts that response to a header PATCH, nor calls it successful acknowledgement. This includes non-primary-key uniqueness conflicts. Successful original INSERT behavior is unchanged; lost-response recovery needs explicit review.

## Operation status — feature availability is not release certification

| Operation | Available implementation now | Safety / remaining gate |
|---|---|---|
| Read assignments, E-L catalogue/filter/order, completion attribution | Both apps, existing fields | Existing read/display work; rendered/export/calendar acceptance still open |
| Durable local planning drafts | Both apps, all planning controls | Local only; no canonical overlay, queue, automatic rebase or replay |
| Contractor directory creation and quick-add | Existing stable-ID INSERT-only path | Does not overwrite tasks; exact directory comparison, RLS and scope checks; live acceptance pending |
| Directory edits | Existing full-observed-field online PATCH | No offline replay; field-state mitigation, not an operation receipt; live acceptance pending |
| Existing-task assignment selection/clear | Guarded online planning PATCH on both apps | Original version+observed predicates; target membership read is not atomic enforcement; live acceptance pending |
| Existing E-L task target change | Guarded planning PATCH | Catalogue validated; unchanged date/vintage/lifecycle preserved; live acceptance pending |
| New assigned/E-L task, Date↔E-L switch, Work Date edit | Stable-ID INSERT / guarded PATCH on both apps | Verified Portal payload convention implemented; server trigger execution, rendered and live acceptance pending |
| Planned range end | Not authored by either new path | Portal has no separate planned end; historical end_date retained and owned only by completion |
| Complete, reopen, completed-date correction | Guarded one-shot online lifecycle writes on both apps | Exact payload and originally loaded predicates; durable unknown/offline intent; mocked tests, not live acceptance |
| Existing generic metadata/completion queues | Legacy behavior remains | Not certified conflict-safe; not expanded with new planning fields. Still a release blocker until audited/guarded or deliberately held locally |
| Pruning resource linking | Existing deployed pruning CAS path unchanged | Prior focused acceptance stands; Android real coordinator interruption and live contention acceptance remain outstanding |
| Costing/Trip/generated tasks | Unchanged | No calculators, pricing snapshots, costing RPCs or generation functions edited |

**No Work Task offline UPDATE replay is newly safe to enable. Neither app is approved for release.** New planning and lifecycle code is compiled and has focused contract/coordinator coverage, not live-write acceptance. Do not equate preview availability with release readiness or certify internal-assignee database enforcement from picker tests.

## Minimal cooperative cross-client `sync_version` proposal

### All three interactive clients

Use the existing direct-table contract, not a new endpoint:

- On load, retain the original server `sync_version` and raw observed values for fields the action depends on. Missing version means refresh before beginning a new edit; never use a save-time refreshed version to authorise an older draft.
- For ordinary edits, completion, reopen and completion-date correction: `PATCH work_tasks` with `id`, `vineyard_id`, `deleted_at IS NULL`, `sync_version = originallyLoadedVersion`, and original relevant planning/lifecycle/header predicates. Set `sync_version = originallyLoadedVersion + 1` in the same PATCH. Do not use a separately read latest version or retry loop. Include observed fields which noninteractive/generated writers may change without advancing the version; raw `updated_at` is supplemental only, not a strictly increasing token.
- Send a narrow intent: omitted fields are untouched; null is an intentional clear. Ordinary assignment/notes edits must not rewrite completion, dates, commercial terms, links or child rows. Completion/date corrections follow EXACT existing Portal ownership; do not normalise existing records or add date columns.
- Use `Prefer: return=representation`. Exactly one returned row plus matching requested owned fields/version is required. Zero rows means conflict, deleted row or revoked permission; show it without silently discarding intent. Inspect a scoped current row for display, not automatic rebase/acknowledgement.
- Concurrent clients loaded at N: one PATCH changes N→N+1; another with N must affect zero rows. Portal ordinary edits must adopt this predicate. Portal completion must use the user's original N, not a refreshed value just before completion.
- INSERT with stable UUID only. No upsert and no 409→PATCH. An INSERT cannot overwrite an existing task. A duplicate/lost response does not prove the entire intended create+later lifecycle state was applied; retain intent and review canonical state.
- A network timeout after PATCH is an **unknown outcome**. Read current state to show the user, but matching fields do not prove authorship/exact operation acknowledgement. No automatic retry for unknown outcomes. This proposal deliberately trades seamless replay for retaining intent without introducing receipts.
- Account/vineyard boundaries apply on draft persistence, initiation, every network dependency and response. Child/resource dependencies must be acknowledged before linking; do not bundle cost children into header writes.

No backend version-column expansion or generic version-increment trigger is necessary for this cooperative rollout. Do not claim protection against older/noncooperating unconditional writers. Inventory all interactive entry points and minimum supported client versions; until adoption is complete, keep offline task updates as drafts and keep releases gated. If enforcement against arbitrary direct writers is later required, that is a separate approved scope, not a hidden feature-parity prerequisite.

### Minimal internal-assignee validation improvement (separate review, not applied)

Propose one narrowly scoped validation trigger on INSERT / UPDATE OF `assigned_to, vineyard_id`, using existing membership tables/helper rules:

- Nonnull newly selected `assigned_to` must be a member of the row's vineyard; apply actual live active/deleted/expiry rules if those exist. Preserve the existing exclusive internal/external constraint and external validation.
- Skip an UPDATE when vineyard and internal identity are both unchanged, so unrelated costing/generated-task updates and historical inactive assignments remain valid.
- Validate a new link and scope changes for every caller, not just mobile. Do not broaden RLS, invent roles, rewrite historical tasks or change costing/generation functions.
- Confirm null assignment inserts and generated task shapes on a clone; if a generator intentionally inserts a now-invalid internal link, surface that compatibility conflict rather than adding a silent bypass or changing the generator.

No executable SQL is supplied/applied in this pass. Confirm exact membership lifecycle and privileges before drafting this small change. Dependency-read validation on mobile cannot replace it.

## Acceptance before release

Use approved disposable records/accounts; this pass performed no production mutations.

1. Portal/iOS/Android load one task at N; each ordered pair edits from N. Exactly one applies N→N+1; loser retains complete draft and original N. Verify PATCH predicates on actual requests, not just UI labels.
2. Portal completion from a stale editor must conflict after a mobile edit; mobile completion from stale N must conflict after Portal edit. Verify actual `completed_by`, `completed_at`, finalisation, status and business-date ownership against the existing Portal, including reopen and date-only correction.
3. Assignment internal→external→unassigned; deliberate nulls; unchanged inactive history; cross-vineyard attempt; member removal between dependency read and UPDATE. Distinguish client validation from database rejection.
4. Target-only edit preserves mandatory date, date range, vintage, completion, Trip links and costing snapshots exactly. Verify E-L create omits date/vintage and the real default/trigger supplies both. Verify Date↔E-L preserves or changes the date exactly as specified; no January-1 convention.
5. Inject lost response after successful INSERT/PATCH, restart, switch account/vineyard, deny draft persistence and race local header save. No duplicate PATCH fallback, automatic rebase or queued selection replay; unknown outcome remains visible.
6. Generated pruning/Trip work and financial rollups continue unchanged. Compare labour/piece-rate/machinery/fuel/material/link totals and rate snapshots; include noninteractive update contention without relying on `sync_version` advancing for those functions.
7. Small-screen, accessibility, filters/export/calendar and both platform cache restart acceptance. Compile checks are not these tests.

## Validation this pass

- Final iOS `runChecks`: simulator build passed. Device/release build not verified. Final `swiftTest` selection: `VineTrackTests/WorkTaskWriteParityTests`, `WorkTaskPlanningParityTests`, `WorkTaskMachineCostingTests`, `PruningResourceCASTests`: **46 passed in 105 seconds**.
- Final Android `runChecks`: managed build passed. Focused host JVM Gradle selection: `WorkTaskWriteParityTest` **11**, `WorkTaskPlanningParityTest` **10**, unchanged `PruningResourceCASTest` **9**, unchanged `WorkTaskMachineCostingTest` **18**: **48 passed**, zero failures/errors/skips; Gradle successful in **4m7s**. Log `.rork-tmp/work-task-parity-verified-20261009.log`. Command-only 6GB heap override; no project memory setting changes. Final UI-only account/vineyard guard was subsequently compiled in `runChecks`; host tests were not rerun for that UI-only refinement.
- New tests exercise real production payload builders, predicate encoding, strict acknowledgement, one-shot coordinators and persisted intentions with controlled transport. They cover E-L date/vintage omission and accepting a fixture's server vintage, switches, backdated completion, audit-preserving correction, reopen, timezone boundaries, stale versions/changed preserved values, missing predicate keys, lost-response/restart/no-rebase, persistence failure and account changes. iOS uses actual temp-directory persistence; Android coordinator tests use injected storage callbacks and prior planning tests exercise real host disk restart. They do not execute live triggers/PostgREST/RLS, native rendered flows, actual network response-loss or coordinated Portal/device contention.
- Initial iOS build timeout recovered on later successful build. Android missing JSON-extension imports corrected; an intermediate host compile saw predicates added during compilation and failed before test execution, then the final run compiled and passed. No failed run is treated as acceptance.
- No database changes, Portal edits, release submission, costing or production pruning source changes.

## Changed-file inventory

- Current iOS pass (relative to `ios/VineTrack/`): `Backend/Repositories/SupabaseWorkTaskPlanningRepository.swift`; new `Backend/Sync/WorkTaskWriteCoordinator.swift`, `LegacyImported/Models/WorkTaskWriteContract.swift`; `LegacyImported/Models/WorkTaskPlanning.swift`, `WorkTaskCompletion.swift`; `LegacyImported/Views/Tasks/AddEditWorkTaskView.swift`, `WorkTaskCompletionSheet.swift`, `WorkTaskAttributionView.swift`. New `ios/VineTrackTests/WorkTaskWriteParityTests.swift`.
- Current Android pass (relative to `android-vinetrack/app/src/main/java/com/rork/vinetrack/`): `data/WorkTaskPlanningRepository.kt`, `WorkTaskPlanningDraftStore.kt`, `WorkTaskCompletion.kt`; new `data/WorkTaskWriteContract.kt`, `WorkTaskWriteCoordinator.kt`; `data/model/WorkTaskPlanning.kt`; `ui/AppViewModel.kt`, `ui/screens/WorkTasksScreen.kt`, `ui/components/WorkTaskAttribution.kt`. New `app/src/test/java/com/rork/vinetrack/data/WorkTaskWriteParityTest.kt`; `app/build.gradle.kts` focused-source selection. Prior sync_version model and duplicate-create fixes retained, not redone.
- Documentation: withdrawn banners on the three old CAS SQL files and guide; this replacement guide; existing approved plan updated. No other SQL/migration changes.

## Inputs required for live acceptance

Portal payload questions are resolved. To execute mutation acceptance, provide an explicitly approved disposable test vineyard/task set, test-user authenticated sessions for the operational roles on both clients, and a way to coordinate Portal/device contenders and response-loss injection. Service-role credentials or unrelated lookup JWTs are not a substitute for authenticated-user/RLS acceptance. No production rows have been read or mutated in this pass. Unknown intents currently require deliberate manual review; there is no automatic retry or completed human-resolution UI. Legacy generic header queues and rendered/accessibility/export/calendar acceptance remain release blockers.
