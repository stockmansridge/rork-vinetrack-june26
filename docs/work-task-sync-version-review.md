# Existing-schema Work Task parity and minimal conflict protection

Updated 2026-10-09. Review proposal only: no SQL applied, no Portal source changed, no release submitted.

## Superseding decision

The `save_work_task_cas` expansion, receipt tables, new revision/date columns, enforcement gate and vintage trigger replacement are WITHDRAWN. Do not apply any of the four prior `work-task-cas-*` files. Existing `work_tasks` fields, RLS, costing authority and generated-task functions remain authoritative. Feature parity does not require a new Work Task schema or RPC.

User-reviewed Portal findings are accepted: ordinary edits advance `sync_version` without an expected-version predicate; completion has a conditional version check but does not fully honour the originally loaded revision; database internal-assignee membership enforcement is incomplete. Portal code is not present locally. These findings are not a fresh agent inspection of production.

## Mobile implementation in this pass

Both apps now retain the actual server `sync_version` in task models/caches. Missing older cache versions remain absent; they are never defaulted to 1 or invented from timestamps.

An explicit **Save assignment / E-L target online** action is available on existing-task editors when an original baseline is available. It:

1. Captures a scoped online read against the version and selection/lifecycle/header values originally loaded by the editor. Missing/mismatching version, keys, pending header mutations, offline state or unreadable draft prevents capture. This is not a save-time refresh/rebase.
2. Persists the full account/vineyard/task-scoped draft and original raw baseline before mutation. Resumed drafts keep that baseline; old drafts without it are not automatically upgraded. Dates retain original raw server precision in predicates.
3. Checks the author is a current operational vineyard member, exclusive assignment, selected member membership and active/nondeleted same-vineyard external resource. These dependency reads improve mobile validation but are NOT an atomic database membership guarantee: revocation/deactivation may race them. Existing RLS and external-link validation still run on the PATCH.
4. PATCHes only deliberately changed assignment IDs and/or an existing E-L target, with `sync_version = original + 1`. Explicit null clears assignment. Unchanged historical inactive external links are omitted, avoiding revalidation/clearing by a target-only edit.
5. Filters the UPDATE by task/vineyard, original `sync_version`, raw `updated_at`, deletion and all observed scalar planning/header/lifecycle values, including nulls. This catches relevant changes by completion/legacy writers which fail to advance the version; read-before-write comparison alone is not used as protection.
6. Requires exactly one returned row, the requested selection/version and unchanged observed nonowned values. No canonical cache update is made for a zero-row, transformed, malformed, failed or account-switched response. Such outcomes remain unknown/conflicted, not acknowledged. A transformed write might already have committed; response verification cannot roll it back.
7. Does not retry automatically, rebase expectations, mutate child allocations, or clear the full local draft. It clearly says other form edits remain local. After any attempt, the current session disables further online selection save. Reopening a persisted draft retains its old baseline, so an explicit retry still uses the original predicates and may conflict; it never obtains a newer baseline automatically. Review server state before resolving an unknown outcome.

This is **one-sided, narrow online conflict mitigation**, not universal cross-client CAS or exact retry proof. An old unconditional Portal/mobile writer can still overwrite a newer row after a guarded save. No new offline replay was enabled.

Android duplicate create recovery now retains a 409 as a BLOCKED local intent. It never converts that response to a header PATCH, nor calls it successful acknowledgement. This includes non-primary-key uniqueness conflicts. Successful original INSERT behavior is unchanged; lost-response recovery needs explicit review.

## Operation status — feature availability is not release certification

| Operation | Available implementation now | Safety / remaining gate |
|---|---|---|
| Read assignments, E-L catalogue/filter/order, completion attribution | Both apps, existing fields | Existing read/display work; rendered/export/calendar acceptance still open |
| Durable local planning drafts | Both apps, all planning controls | Local only; no canonical overlay, queue, automatic rebase or replay |
| Contractor directory creation and quick-add | Existing stable-ID INSERT-only path | Does not overwrite tasks; exact directory comparison, RLS and scope checks; live acceptance pending |
| Directory edits | Existing full-observed-field online PATCH | No offline replay; field-state mitigation, not an operation receipt; live acceptance pending |
| Existing-task assignment selection/clear | New explicit online-only narrow PATCH | Original version+observed predicates; member validation is client-side plus existing RLS, not atomic target-membership enforcement; cross-client/live acceptance pending |
| Existing E-L task target change | Same new explicit action | Catalogue validation, date/vintage/lifecycle untouched; live acceptance pending |
| New task with assignment/E-L, schedule-mode switch, date/range changes | Editor/durable draft only for new planning fields | Exact Portal create/compatibility-date/vintage/range ownership must be supplied; no proposal-specific date convention used |
| Complete, reopen, completion-business-date correction | Existing legacy controls/lifecycle retained | No new attribution payload or replay extension; originally loaded version and exact Portal completion payload not yet integrated/verified |
| Existing generic metadata/completion queues | Legacy behavior remains | Not certified conflict-safe; not expanded with new planning fields. Still a release blocker until audited/guarded or deliberately held locally |
| Pruning resource linking | Existing deployed pruning CAS path unchanged | Prior focused acceptance stands; Android real coordinator interruption and live contention acceptance remain outstanding |
| Costing/Trip/generated tasks | Unchanged | No calculators, pricing snapshots, costing RPCs or generation functions edited |

**No Work Task offline UPDATE replay is newly safe to enable. Neither app is approved for release.** Online selection code is compiled, not live-write accepted. Do not equate preview availability with release readiness or certify internal-assignee database enforcement from picker tests.

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
4. Target-only edit preserves mandatory date, date range, vintage, completion, Trip links and costing snapshots exactly. Date↔E-L/create testing waits for actual Portal payload and compatibility date/vintage convention, not the withdrawn January-1 convention.
5. Inject lost response after successful INSERT/PATCH, restart, switch account/vineyard, deny draft persistence and race local header save. No duplicate PATCH fallback, automatic rebase or queued selection replay; unknown outcome remains visible.
6. Generated pruning/Trip work and financial rollups continue unchanged. Compare labour/piece-rate/machinery/fuel/material/link totals and rate snapshots; include noninteractive update contention without relying on `sync_version` advancing for those functions.
7. Small-screen, accessibility, filters/export/calendar and both platform cache restart acceptance. Compile checks are not these tests.

## Validation this pass

- iOS: `runChecks` passed; simulator build. Initial compile rejected Int64 as a Supabase filter value; corrected to a decimal string before successful rebuild.
- Android: `runChecks` passed; managed build.
- No new automated tests or live PostgREST/Portal/device mutation acceptance run this pass. Prior passing tests concern the previously accepted safe phase; they do not certify this new online repository.
- No database changes, Portal edits, release submission, costing or production pruning source changes.

## Changed-file inventory

- iOS: `Backend/Models/BackendOperations.swift`, new `Backend/Repositories/SupabaseWorkTaskPlanningRepository.swift`, `LegacyImported/Models/WorkTask.swift`, `LegacyImported/Models/WorkTaskPlanning.swift`, `LegacyImported/Views/Tasks/AddEditWorkTaskView.swift` (relative to `ios/VineTrack/`).
- Android: `data/WorkTaskCreateSync.kt`, new `data/WorkTaskPlanningRepository.kt`, `data/model/Models.kt`, `data/model/WorkTaskPlanning.kt`, `ui/AppViewModel.kt`, `ui/screens/WorkTasksScreen.kt` (relative to `android-vinetrack/app/src/main/java/com/rork/vinetrack/`).
- Documentation: withdrawn banners on the three old CAS SQL files and guide; this replacement guide; existing approved plan updated. No other SQL/migration changes.

## Inputs needed to finish remaining functional writes

Provide the Portal Work Task create/edit, complete/reopen and date-correction mutation functions (sanitised source or exact request examples), especially the E-L create `date`/`vintage_year` convention, planned range ownership and completion `status`/finalisation/identity fields. Existing live schema columns and RLS need not be resupplied. User-reviewed capability is accepted; undocumented request values and lifecycle transitions cannot safely be guessed from column names.
