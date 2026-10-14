# Inventory / Upcoming Tasks — Option B correction and transfer report

## Outcome and scope

Ported/adapted only Chemical Inventory and the Upcoming Tasks hub into the registered Rork apps. Both native builds pass, the iOS focused selection passes, and all seven added Android host cases plus two real-preference Android instrumentation cases pass. **The expanded Android host selection is not all-green:** five existing completion-suite failures reproduce unchanged at the starting revision. They were not fixed, removed, skipped or weakened by this port.

No SQL/migration, production-data request/mutation, unrelated Trip/tank/calculator/auth changes, version/build-number change, branch merge, deployment, distribution, App Store/TestFlight/Play submission or release-candidate preparation was performed. Native build checks necessarily produce validation artifacts; none is designated or distributed as a release candidate. The external PR was NOT updated.

## 1. Exact source identity and conflict protection

- Starting clean Rork workspace and HEAD observed at final source packaging: `3dc0f247c092be10e2a5514754ce41a4aedf2854`.
- Tested application changes are the working-tree/index delta on that revision, **not code already contained in that commit**. Rork's later managed commit is not yet available at report time; no final commit SHA is invented.
- PR #2 / branch `fix/inventory-active-and-upcoming-work-20261014`: `0889a6614bc77fa9ece468d5020f83fc288884ff`. Read-only `git ls-remote` verified both the branch and `refs/pull/2/head` still resolve to that SHA.
- PR comparison base: `537a1ab17e3de9517ccc304a373a060509e34101`.
- All eight PR-touched files have identical Git blobs in the clean Rork starting revision and the PR comparison base. There was no overlapping newer change in those eight files. All other current Rork source was retained; there was no checkout, wholesale file replacement from the external app, reset or rollback.
- Linked repository remains clean at the same PR SHA.
- Exact 16-file transfer-source SHA-256 manifest: `docs/reviews/inventory-upcoming-option-b-source.json`.
- Aggregate manifest fingerprint: `29228d43e0187ab9518e186bcc2fbb53db1d28d3dc32caff3c27bafabc1312b9`.
- PR-relative patch: `docs/reviews/inventory-upcoming-option-b-pr2.patch`, SHA-256 `37ba35d7dbb1ab217370894920cb771758c2dd1d22c37919c5827f23f7795a7c`.
- `git apply --check` PASSED against an isolated export of exact PR HEAD. The patch has NOT been applied to the linked repository or GitHub.

## 2. Corrections and differences from PR #2

### Chemical Inventory, both platforms

- Inventory and purchase selection now use the existing active-only Chemical Store projection, scoped to the selected vineyard. Archived/history rows are not deleted or rewritten.
- Overview counts and per-currency stock totals consume only summaries for currently visible active IDs. An archived chemical cannot remain in totals just because its old summary is cached.
- Removed/archived selections close or cease rendering their action form. Scope changes clear selection and cached summaries; a delayed action-refresh callback cannot rebind the old scope.
- Added a screen-local serialized summary worker. Repeated unchanged catalogue publication performs no new RPCs. Added/changed chemicals invalidate only their summaries; inventory mutations invalidate only the affected ID. Archive-only removal does not refetch every remaining product. Explicit Retry is a deliberate full active-summary refresh.
- Account, vineyard and permission context fence cached data. Per-ID revisions reject old responses after edits/explicit mutation refreshes; generations reject responses from replaced account/vineyard/permission scopes. Only one summary fetch runs at a time in each screen-owned worker. Errors from obsolete operations cannot overwrite current error state.
- The existing member/cost/purchase/management permission gates and authorized RPCs remain unchanged. Scope invalidation additionally prevents previously privileged summaries being reused after a permission change.
- The cache is not another persistent record store or outbox. Reentry reloads summaries from the existing RPC; complete retained chemical rows continue to resolve history.

**Beyond PR:** the PR reloads all summaries after ID changes and has separate overlapping iOS loading hooks. This version replaces those hooks with the serialized, incrementally invalidated state above and observes complete chemical values, not IDs alone.

### Upcoming Tasks, both platforms

- Ported hub-only eligibility: exclude archived/finalized and past dated tasks; retain E-L tasks without interpreting their compatibility date as their schedule.
- Preserved descending E-L priority, upcoming vineyard business dates and stable ID tie-breaking. Existing full Task Log ordering, completion/end_date semantics, role rules and sync/write/replay contracts are untouched.
- Hubs observe the canonical task collection, so create/edit/Complete/Reopen and successful sync publication recalculate the projection rather than maintaining another list cache. Visible hub tasks are explicitly selected-vineyard scoped.
- Fixed the iOS `upcomingSection` / `recentSection` mismatch by using `upcomingSection` consistently in both call and declaration.
- Added foreground-only local day clocks keyed by account/vineyard/configured zone. Calculate the next **local calendar** midnight (including 23/25-hour DST days), not a fixed 24-hour interval. Midnight reprojects cached tasks without a network call. Background cancels the day clock; resume recalculates immediately. iOS significant-time-change notifications re-arm the clock.
- iOS reuses the existing `NewMainTabView.runFullSweep` foreground/reconnect/vineyard-selection sync, including WorkTaskSync, rather than adding a second foreground network sweep. Its existing three-minute active sweep is unchanged.
- Android refreshes once when the Work Tasks area enters/resumes online, and when reconnecting while resumed; no new network polling. Existing captured-account/authorization-epoch/vineyard checks and pending-write overlays in `refreshWorkTasks` are unchanged.
- Zone sources remain the selected vineyard's existing settings: iOS `store.settings.resolvedTimeZone`; Android `state.seasonZone`, resolved from selected vineyard timezone. Not solely device time. The existing fallback for missing/invalid zone configuration remains unchanged and should be checked on the owner's vineyard.

**Beyond PR:** the PR has no midnight state dependency or lifecycle refresh. This version adds local day-boundary/resume handling and scopes hub eligibility while preserving existing scheduling/storage semantics.

## 3. Modified application and test files

Paths are project-root relative.

### iOS (7)

1. `ios/VineTrack/App/ChemicalIntelligence/ChemicalInventoryView.swift`
2. `ios/VineTrack/App/ChemicalIntelligence/ChemicalInventorySummaryState.swift` — new
3. `ios/VineTrack/LegacyImported/Models/WorkTaskPlanning.swift`
4. `ios/VineTrack/LegacyImported/Views/Tasks/WorkTasksHubView.swift`
5. `ios/VineTrackTests/ChemicalInventorySummaryTests.swift` — new
6. `ios/VineTrackTests/WorkTaskPlanningParityTests.swift`
7. `ios/VineTrackTests/WorkTaskHeaderFullPullTests.swift`

### Android (7)

1. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/chemical/ChemicalInventorySummaryState.kt` — new
2. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/WorkTaskPlanning.kt`
3. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/ChemicalInventoryScreen.kt`
4. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/WorkTasksScreen.kt`
5. `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/ChemicalInventorySummaryTest.kt` — new
6. `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/WorkTaskPlanningParityTest.kt`
7. `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/InventoryUpcomingPersistenceAndroidTest.kt` — new

### Repeatable validation / evidence

- `scripts/inventory-upcoming-tests.init.gradle` — external scoped test-source/filter configuration; no Gradle/release configuration changes in either app.
- `scripts/run-inventory-upcoming-regressions.py` — current/baseline host runner; isolated baseline archive and logs stay under `/tmp`.
- `scripts/package-inventory-upcoming-review.py` — read-only Git/source/results comparison and patch packaging.
- This report, its source JSON and PR-relative patch under `docs/reviews/`.
- Existing approved plan `.rork/plans/complete-android-clean-sign-out-on-popul_1791783138683.plan.md` updated to record explicit Option B authorization/results. Rork-managed history is not implementation content to transfer.

## 4. Tests and build results

### iOS

Final seven-suite `swiftTest(appPath: ios)` selection:

- `VineTrackTests/ChemicalInventorySummaryTests`
- `VineTrackTests/ChemicalStorePresentationTests`
- `VineTrackTests/ChemicalInventoryTraceabilityTests`
- `VineTrackTests/WorkTaskPlanningParityTests`
- `VineTrackTests/WorkTaskCompletionTests`
- `VineTrackTests/WorkTaskHeaderFullPullTests`
- `VineTrackTests/WorkTaskWriteParityTests`

**61 passed / 0 failed, 26 seconds.** Prior first six-suite selection was 51/0, 135 seconds. A later added full-pull test initially failed compilation before assertions because WorkTask is not Equatable; the test now compares full sorted-key Codable bytes, retaining the full-state equality contract. Final 61/0 includes the corrected fixture and new sync-to-upcoming coverage; no production compiler setting was changed.

Coverage includes real temporary-directory archived chemical preservation/reload, inventory totals eviction, changed-only fetches, generation/revision fencing and serialization, offline read failure/retry, permissions, date/E-L order, Sydney midnight vs UTC, DST, Complete/Reopen, cache codec recreation, and actual production WorkTaskSyncService pull with synthetic create/edit/complete/reopen responses and off-selected-vineyard publication protection. These are not authenticated operator-screen journeys.

Final `runChecks(ios)`: **PASSED, native simulator build**. No device/App Store Release validation claimed. Two existing unrelated asset-address advisories remain unchanged.

### Android host

Selection: ChemicalInventorySummaryTest, ChemicalStorePresentationTest, ChemicalInventoryTraceabilityTest, WorkTaskPlanningParityTest, WorkTaskCompletionTest, WorkTaskFullRefreshParityTest, WorkTaskWriteParityTest, WorkTaskEditorLifecycleTest.

**67 executed: 62 passed / 5 failed / 0 errors / 0 skipped.** New summary cases 4/0 and new upcoming cases 3/0. Host compilation covered the actual app; no test uses a live transport. Existing permission and guarded-write/reopen/pending-overlay regression assertions were retained.

Read-only export of exact starting revision `3dc0f247c092be10e2a5514754ce41a4aedf2854` to `/tmp/vinetrack-inventory-upcoming-baseline`; **all 1,081 tracked Android files byte-verified**. Only an inert, noncredential Config companion was added because Rork's generated Config is untracked; original tracked sources remained unchanged. Baseline ran the same existing selection: **60 executed: 55 passed / 5 failed / 0 errors / 0 skipped**, 183.63 seconds including build.

Machine comparison: **60 common testcase identities, zero missing, zero changed status/failure-message results; seven added tests all pass**. This establishes the five failures predate this port; it does NOT turn the expanded suite green.

Unchanged WorkTaskCompletionTest failures:

| Test | First failure / relevance |
| --- | --- |
| Sydney Work Date selection round trips the UTC picker calendar day | expected 2026-10-05, actual 2026-10-04; older instant-style expectation vs existing leading-component business-date contract |
| customer A B C keeps work date and separate audit | expected 2026-09-30, actual 2026-09-29; same legacy completion-date boundary |
| new local midnight Work Date resolves through vineyard timezone | expected 2026-10-04, actual 2026-10-05; conflicts with existing leading-component date semantics tested by WorkTaskWriteParityTest |
| duplicate pending create patches folded completion before acknowledgement | empty updates list after arbitrary 409; current duplicate safety path does not treat a 409 as verified acknowledgement |
| offline update survives restart overlay full refresh and replay with original audit | legacy overlay drops completedBy/completedAt in this test; exact mismatch retained in source JSON |

No completion/date/duplicate-acknowledgement/overlay production change or assertion weakening was made to conceal these failures. Reconciling these older contracts is separately scoped work before claiming a whole-suite green result.

Host logs: `/tmp/vinetrack-inventory-upcoming-validation/{stdout,stderr}.log`. Baseline report/logs: `/tmp/vinetrack-inventory-upcoming-baseline/`. Failure comparison is retained durably in the source JSON; `/tmp` files themselves are not committed.

### Android instrumentation and native build

`androidTest(appPath: android-vinetrack, onlyTesting: com.rork.vinetrack.data.InventoryUpcomingPersistenceAndroidTest)`: **2 passed / 0 failed / 0 skipped, 11 seconds**.

Uses namespaced synthetic real Context-backed preferences, production SavedChemicalLocalStore, DomainCacheRepository, ChemicalInventorySummaryState and WorkTaskPlanning/Completion. Verifies archive retention/active visibility and totals after store recreation, account/vineyard isolation, offline cached day rollover and Complete/Reopen persistence/reprojection. No network fallback or customer installation data. Store recreation is **not** Android process death, a foreground UI journey, or successful server replay.

Final `runChecks(android-vinetrack)`: **PASSED, native build** after application and instrumentation source corrections. Two existing unrelated asset-address advisories remain unchanged. No native app source changed after final tests/build checks.

## 5. Remaining device / acceptance gaps

- Physical iPhone/Android: archive -> refresh -> leave/return -> actual OS process termination/relaunch -> purchase picker/totals inspection.
- Rendered foreground/background/resume at vineyard midnight, including a device in a different timezone and a correctly configured vineyard zone. Lifecycle wiring is inspected/build-validated; the automated tests advance supplied clock instants/projections, not the real device clock or OS lifecycle.
- Authenticated remote create/edit/Complete/Reopen, reconnect/server sync and cross-device inventory stock updates. Automated sync is synthetic; no production request/data mutation occurred.
- Live account A -> B sign-out/sign-in and role changes with an in-flight real summary response. Automated scope and store-isolation tests do not replace full UI acceptance.
- Process-kill durability and live RLS/cost redaction/permissions: existing boundaries remain unchanged, not newly certified through production access.
- The five baseline-existing Android completion failures remain unresolved. Do not label this a fully green whole-app acceptance or release candidate.

## 6. Exact transfer back to PR #2

Use **only** `docs/reviews/inventory-upcoming-option-b-pr2.patch` against PR HEAD `0889a6614bc77fa9ece468d5020f83fc288884ff`. It contains the exact differences from the already-prepared PR to the tested Rork source: the 14 application/test files above plus the two scoped runner/init scripts. It does not include Rork history/plans, unrelated newer application code, SQL, release configuration or generated build outputs.

The isolated exact-PR patch check passed. The person applying it should re-check the PR HEAD and run `git apply --check` again in their own branch workspace; if the branch has advanced, review hunks instead of overwriting current files. Then apply/review there and run the recorded test selections/builds in that workspace. Do not claim Rork's native validation is a GitHub branch CI result. The packaging utility and report/source manifest may also be transferred as review evidence, but are not required application changes.

No external PR commit, push, merge or update was performed by this work.
