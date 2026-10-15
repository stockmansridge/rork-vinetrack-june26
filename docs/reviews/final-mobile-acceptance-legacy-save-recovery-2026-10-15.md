# Mobile source closeout / legacy Save for Later — 15 October 2026

## Urgent A/B/C sync corrections — newest checkpoint, 15 October 2026

### Scope and evidence boundary

Owner-reported production observations concern Stockmans Ridge legacy Growth buttons and completed trip `a3d88bdb-a9a4-497d-9a5c-7d14166ddc04`. This pass implements targeted mobile corrections only. The production row was not fetched, changed, reopened or deleted. No production SQL/data operation, backend deployment, queue purge, store action, release build, version increment or handset installation was performed. Other completed features remain frozen except the specifically necessary GPS sync/reconciliation seams below.

The two recorded tank-session JSON objects and raw legacy Growth array were not attached or found in the checked local docs/migration fixtures. Tests reproduce the described shapes with explicitly synthetic values. They are **not exact recorded-object acceptance**. The actual objects are required to close that gate; no test data was presented as production data.

### A. iOS Button Config

- Decode missing nested button `id` and `vineyardId` using the enclosing vineyard and a deterministic vineyard/config-type/slot identity. Existing supplied IDs, names, colour tokens, indices, mode and growth-stage flags are retained. Missing required values, invalid UUIDs, foreign scope and duplicate identities/slots fail visibly instead of generating default button configurations. Existing standalone/local ButtonConfig decoding is unchanged.
- Pull never replaces a real dirty Repairs/Growth edit or clears its marker merely because a remote timestamp is newer. The distant-past marker used only for generated initial defaults can still yield to a real server row.
- Existing server row IDs and creator identities are retained. Existing rows use conditional PATCH by vineyard/type/id, undeleted status and **exact server-issued `updated_at` text**, preserving microseconds. `sync_version` is not assumed to advance: checked source schema only guarantees a timestamp trigger. Missing concurrency evidence holds the edit. New rows use INSERT, not merge-upsert, so concurrent first creation cannot replace the winner.
- Require one returned server row matching IDs/scope/type and the exact sent button array. Zero-row CAS failures, forbidden/errors, malformed responses and mismatches retain dirty state. Clear only the exact pending timestamp and matching current local values; edits made during suspension remain pending. Dirty metadata saves use checked durable persistence, and failed acknowledgement persistence restores the pending state.
- A serialized full sync cannot show success or advance the displayed sync date while button changes or metadata failures remain. Account/sign-out-sequence/vineyard changes block local acknowledgement/publication. Existing server RLS still owns owner/manager write authorization; no role bypass was added.
- Synthetic iOS writer/shared-row/second-reader tests and Android LauncherButton wire decoding prove local compatibility. They do **not** confirm an authenticated owner/manager edit propagated between real devices or prove deployed RLS/trigger behavior.

### B. iOS tank sessions

- Read both camelCase local/iOS fields and the stored Android snake_case fields for tank number, start/end time, paths, start/end row and fill start/end time.
- Accept ISO8601 fractional/nonfractional strings and timezone offsets independently of the surrounding JSON date strategy. Numeric historical cache dates continue using the caller's existing Date decoder strategy. Invalid dates and contradictory aliases throw; dates/IDs/coverage are not guessed.
- Existing camelCase encoding is unchanged. No migration, historical rewrite, GPS/path derivation, session-ID reminting or completed-state change was introduced.
- Regression decodes two synthetic Android-shaped sessions and a synthetic full BackendTrip → Trip containing **4,584 points, 109 completed paths and two sessions**, then checks completed status and evidence counts/values. Numeric cache and ISO encoding/read-back are separately covered. The count match to the reported trip is a synthetic reproduction, not evidence that its actual objects were tested.

### C. Android interrupted GPS recovery

- Repository recreation changes only interrupted TRIP_GPS (alongside the pre-existing Work Task exception) from IN_PROGRESS to FAILED with a recovery explanation. ID/client ID, original payload, timestamps of the original operation, baseline and attempts remain retained; status/update timestamp changes only. No generic queue reset/clear or unrelated-operation recovery was added.
- Replay requires the current account incarnation, matching marker/trip, original owner, vineyard and exact current queue version. Old markers require a readable matching owned snapshot. Missing, unreadable, empty, foreign or mismatched evidence becomes a retained actionable hold, never a successful no-op.
- New markers persist the captured GPS observations and scope. When an owned snapshot contains a newer tail, retain that full evidence before any request and embed the original payload once as `originalPayloadJson`; the operation ID is unchanged. Snapshot divergence holds both sources. Same-trip completed restoration no longer replaces local GPS merely because the server path is longer, or blanket-deletes sibling trip markers.
- Fetch uses a captured-account request scope and original-claim admission. Verify server ID, vineyard, undeleted status, current claim/account and unchanged owned snapshot after suspension. Compare ordered **exact** coordinates, duplicate multiplicity and locally available bearing/speed/accuracy. Count, total distance or completion status alone cannot prove inclusion.
- If every retained observation is present remotely, durably retire only the exact GPS marker as SYNCED, retaining its payload/proof explanation. It no longer counts as pending. No completed-trip PATCH or active-trip publication occurs. If evidence is missing/divergent, retain it and show support/review instructions; never reopen or automatically merge into completed history.
- Active-trip GPS replay is separate: upload only a path containing all fetched server evidence, without jitter deduplication/discard. Require exact fetched `updated_at`, vineyard and still-active/unfinished/undeleted predicates in the PATCH, captured-account scope, complete returned evidence and current queue/snapshot before acknowledgement. Concurrent edits cannot be overwritten by a stale replay. A changed snapshot remains retryable. Existing normal live-capture equations/traversal and ordinary online autosave transport remain unchanged; new enqueue failures are contained in autosave and surfaced without dropping capture evidence.
- Retiring a verified marker is not a queue purge. Unrelated unresolved markers/holds are not silently cleared to make the overall Sync Status green.

### Focused executed evidence

| Surface | Result | Evidence level |
|---|---|---|
| iOS | **26 passed / 0 failed**, latest 56s | `VineTrackTests/SyncCompatibilityTests` (9 new cases) + `TankSessionLifecycleTests` (17 existing cases). Real temporary-file dirty metadata restart, failed disk acknowledgement, conflict/mismatch/newer-edit retention, full-sync failure→success, synthetic second-device row read, legacy identities, exact timestamp token, two tank/date/cache/full-trip decoding. Skipped count not exposed by runner. |
| Android host | **84 passed / 0 failures / 0 errors / 0 skipped**, seven XML suites | Final stable-source runner exit 0, 3m31s, independently XML-counted. Includes 11 new GPS/wire cases plus ActiveTripStore, ReplayVersionIntegrity, AtomicPendingReplacement, AuthRetentionGate, RetentionReview and TankSessionLifecycle. Final GPS XML timestamp `2026-10-15T13:43:01.658Z`. Overlapping runs are not summed. |
| Android process instrumentation | **Final 1 passed / 0 failed / 0 skipped**, 10s | `com.rork.vinetrack.data.TripGpsRecoveryAndroidTest`. Actually kills a separate debug Android app process, relaunches with a different PID, recreates real scoped preferences and the old marker shape, verifies all 4,584 synthetic observations against a synthetic completed response, retains original bytes/path and asserts pending count zero without PATCH/publication. Not real backend/network/main-authenticated-app or physical acceptance. Earlier 14s passing run overlaps and is not added. |
| iOS correctness build | **PASS** | Final `runChecks(ios)`, simulator only. No signed iOS handset build or IPA produced. Existing unrelated asset-URL notices left unchanged. |
| Android correctness build | **PASS**, final `:app:assembleDebug --build-cache --console=plain`, 11s | Final stable source; Debug only. Android runChecks was not invoked: it unconditionally builds Release, which the owner forbids. Latest instrumentation also compiled/installed debug app/test APKs on its isolated test emulator, not a handset. |
| Actual cross-device/handset/complete Sync Status UI | **NOT RUN** | Synthetic shared-row reading, decoder compatibility, coordinator state and pending-count assertions are not an authenticated three-device UI journey. |

Observed development failures, not hidden as passing/skipped: initial Swift test compile used an actor for a MainActor-isolated protocol; changed the test probe to a MainActor class. First executed Swift selection had 22 passes/1 failure because the new test had not created its temporary persistence directory; fixed the fixture directory and retained the assertion. Initial Android narrowed compilation omitted `RetentionReviewTest` shared helpers; added the required test source. First executed Android selection exposed the existing audit asserting GPS must remain stranded: updated only its explicit GPS expectations to preserve original bytes/attempts while checking the new FAILED recovery, and kept all other queue types stranded. Final selections above supersede overlapping development runs.

### Source and device-artifact identity

- Clean application/index baseline: **`354004cb0bd23e686eaa3f29a8eec9df4e517451`**. All prior receipt/calculator/keyboard/Inventory/Upcoming work preserved.
- Final native patch SHA-256 (`git diff HEAD --binary -- ios android-vinetrack`): **`c58d0181fa7e21a57ac121df9ad14f8b4595575a755e264d8d46227968bb4c11`**. This is baseline-plus-patch source identity, not a claim that baseline HEAD alone contains the fixes. Final managed end-of-turn commit SHA is not yet exposed. No manual commit/push.
- iOS: `app.rork.nt0v48tayl7v8noxcfe74`, **3.1.7 (139)**, unchanged. Simulator correctness build only. **A fresh signed physical-device artifact/build identifier is unavailable in this pass**; do not treat the old installed build or simulator output as handset acceptance of these changes.
- Android: `com.rork.vinetrack`, **3.1.7 / versionCode 11**, unchanged. Final APK `android-vinetrack/app/build/outputs/apk/debug/app-debug.apk`, SHA-256 **`2639e23934e374c20f091ba2bc9a051d18f71e8d9387b4cd7e5ece92135ab95f`**. Verified Android Debug certificate SHA-256 **`2be3dd871ef1b19723becbf8d556099274af3b740fd98ae3e5cfdaa6a3c000ce`**, API24+, target36. Earlier intermediate APK hashes are not this artifact. Debug signing may differ from an existing release install: never uninstall/clear data to overcome a mismatch while offline evidence exists. No APK/IPA upload, distribution or installation was performed.

### Exact changed-file inventory

All paths are project-relative; existing files except those labelled new.

**iOS**
1. `ios/VineTrack/Backend/Models/BackendButtonConfig.swift`
2. `ios/VineTrack/Backend/Repositories/ButtonConfigSyncRepositoryProtocol.swift`
3. `ios/VineTrack/Backend/Repositories/SupabaseButtonConfigSyncRepository.swift`
4. `ios/VineTrack/Backend/Sync/ButtonConfigSyncError.swift` (new)
5. `ios/VineTrack/Backend/Sync/ButtonConfigSyncService.swift`
6. `ios/VineTrack/LegacyImported/Models/Trip.swift` (TankSession reader only)
7. `ios/VineTrackTests/SyncCompatibilityTests.swift` (new)

**Android**
1. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/PendingWriteRepository.kt`
2. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripGpsSync.kt`
3. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripRepository.kt`
4. `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/Models.kt` (read-only Trip updated_at token)
5. `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt` (GPS autosave error containment and completed restoration only)
6. `android-vinetrack/app/src/debug/java/com/rork/vinetrack/data/LegacySprayProcessProbeActivity.kt` (isolated GPS fixture extension)
7. `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/RetentionReviewTest.kt` (explicit GPS recovery expectation)
8. `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/TripGpsRecoveryTest.kt` (new)
9. `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/TripGpsRecoveryAndroidTest.kt` (new)

**Supporting**
- `scripts/run-sync-recovery-tests.py` (new bounded runner; transient logs outside project)
- `scripts/sync-recovery-tests.init.gradle` (new source-narrowed host selection; no app build/version config change)
- `.rork/plans/android-live-trip-safe-automatic-complet_1791964262830.plan.md`
- `docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md` (this existing report)

SQL, Edge, app build/version config, frozen GPS traversal/occurrence evaluator, TripsScreen, calculator formulas, keyboards, legacy receipt authority, Inventory and Upcoming source remain unchanged. Source-scoped whitespace checks pass.

### Remaining acceptance and operational risks

1. Supply the actual two tank-session objects and legacy Growth array; rerun exact-fixture regression without reconstructing production values. No credentials are needed for this.
2. With owner/manager handset access, change Repairs colour on iOS A, verify successful config sync, relaunch/sync iOS B and Android, and verify identity/colour and pin colour consumers. Confirm unauthorized writes are rejected by existing RLS without losing the local edit. No live test was performed here.
3. On the device retaining the interrupted GPS marker, restart then retry sync. If original evidence is readable and exactly included remotely, it becomes verified SYNCED; if its snapshot was already lost/replaced by older software, this fix cannot reconstruct it from a count. Keep the installation and retained evidence for support; do not clear the queue.
4. Review the completed trip on iOS and Android: server-completed state, GPS/coverage and both exact tank sessions unchanged. Confirm complete Sync Status independently; unrelated legitimate holds must remain visible, not be purged.
5. Deployed timestamp trigger/RLS and real-network CAS behavior were not queried or exercised. Exact-evidence policy can conservatively hold old paths if optional GPS metadata was historically discarded; this is intentional, not permission to drop observations. New frozen GPS evidence increases scoped local storage/write size; it prevents snapshot replacement from silently losing the queued route.
6. Fresh appropriately signed handset artifacts are required before physical acceptance. Current simulator/debug source verification is not a release, installed-handset result or authorization to distribute.

## Receipt-v1 integration closeout — historical checkpoint

This supersedes the historical containment-only checkpoint below. Allowed legacy no-route Save for Later now uses the deployed atomic RPC on both platforms. This is **mobile source integration plus synthetic/native evidence**, not authenticated backend or physical-handset acceptance. No SQL was executed, no backend deployed, no customer records mutated, no store access/distribution/version increment/release build or paid interactive simulator session was performed in this pass.

### 1. Exact source and preservation

- Current exposed committed HEAD: `a3aad9c287103e2f0904f25d75767120ddf62bc9`; application source/index initially clean. This preserves the prior keyboard, quantity, legacy containment, Inventory and Upcoming Tasks fixes from `041d72744229917046cff6d2619631b74a9ff7b3`.
- Native changes are identified by `git diff HEAD --binary -- ios android-vinetrack` SHA-256 **`16021a14dd8d30e19c56c5bde26da5e7a05049d93c0c54c25fe563404fcab608`**. The baseline HEAD is not misrepresented as the completed change commit. The final Rork-managed end-of-turn commit SHA is not exposed inside this turn; no manual commit/push was performed.
- Requested `99875fc2051fac1c3d55931a7d53ba71cb4cb61d` was unavailable to Git in this checkout. No reset/cherry-pick, older draft PR #2 restoration, linked-repo pointer update or external PR change was performed.
- Exact contract source: GitHub `stockmansridge/rork-vinetrack-june26` commit `bb72aa15335e51c30cdafbdedde1ff6a967695f2`, `docs/contracts/legacy_spray_pair_v1_handoff.md`, `legacy_spray_pair_v1_applied_migration.sql`, `legacy_spray_pair_v1_golden.json`. All three fetched/read as references only. Migration `20261015102804_legacy_spray_pair_receipts_v1` was already deployed by backend owner; Rork did not inspect/alter the live catalog or reapply it.
- Both platform golden fixtures are exact copies of the supplied synthetic file. Its fake UUIDs were never sent to a live server.

### 2. Request/receipt contract used on both platforms

Authenticated POST `/rest/v1/rpc/save_legacy_spray_pair_v1` and `/rest/v1/rpc/recover_legacy_spray_pair_v1` use exactly:

```json
{"p_operation_id":"<original durable UUID>","p_trip":{"...":"frozen typed Trip INSERT projection"},"p_record":{"...":"frozen typed Spray Record INSERT projection"}}
```

- No client actor parameter, client hash parameter, current-row adoption, HTTP409 acceptance, regenerated IDs or rebuilt timestamps. The current authorized user's JWT and normal anon API key are used; never service role. iOS captures token/user/refresh-session and checks its persistent actor/session/vineyard fence around transport/publication. Android uses account-access request attributes plus durable identity epoch and pre/post publication fences; the HTTP refresh interceptor cannot substitute another account.
- New allowed operations freeze original operation UUID and insert bodies durably before any send. A second durable claim precedes the first create request. Every subsequent uncertain/new-session-restoration attempt uses **recovery only**, never automatic create replay, even on `unknown`. This is deliberately more conservative than the contract's optional identical RPC-only retry allowance.
- iOS derives the insert from existing `BackendTrip.upsert`/`BackendSprayRecord.upsert` typed projections, excludes only known-empty non-insert runtime Trip fields after checking they are empty, and fails closed on additional fields. UUID identities are normalized to lowercase in the original insert projection because the deployed SQL compares text to `uuid::text`; identities are not changed. Full original native models and exact wire Data are retained separately.
- Android reuses the existing typed `ImportedTripInsert` and extracted shared `SprayInsert` constructor, including existing geometry/planning-wire projection. No full native model is serialized as an insert. Request JSON objects and original TripIntent/SprayInput are durably retained in the existing scoped store.
- Final receipts must have integer version 1; status `accepted` or `rejected`; exact operation/vineyard/Trip/Spray Record UUIDs; 64 lowercase hex `request_sha256`; valid `committed_at`; and valid status/code combination. Rejection codes accepted by v1 are `identity_conflict` and `validation_or_reference_conflict`. Arrays, errors, malformed bodies, unknown versions, conflicts, `unknown`, invalid IDs/hash/time and non-2xx responses cannot release a hold.
- Initial accepted/rejected receipt is retained as a candidate. Exact-request recovery must return the same complete receipt, including the SHA and committed timestamp. Recovery after a lost initial response can return a validated terminal receipt directly: the authenticated server has compared actor, immutable bodies, operation/scope/record IDs and PostgreSQL fingerprint. A different candidate/recovery hash or any lost follow-up remains held.
- There is **no native JSONB canonicalization implementation**. Golden tests hash only the supplied PostgreSQL canonical string and confirm 944 UTF-8 bytes and `f1950e94f85c8c3c3c431d74fcc83a17b7428a0b13e38a6c23f33aedab992a23`. This is not a claim that Swift sorted JSON/Kotlin serialization matches PostgreSQL.
- Verified acceptance is durably retained before dependent holds are released. Existing operational/compliance, Start, task-link, tank and authentication gates still apply. Android UI row reads occur only after acceptance and merely hydrate display. iOS skips generic original CREATE/upsert replay and cannot recreate a missing original through initial-sync fallback, including after later login/edit; an absent accepted row's dirty update remains pending/failed rather than recreating it. Unrelated eligible sync continues.
- A verified rejection is terminal, shown in native status and retained without deletion/reset/replacement. No new operation is silently minted. Old RPC-less evidence, including old Android REST `COMPLETE`, remains held; a local-complete flag or two historical REST echoes is not an immutable receipt. Arbitrary unjournaled historical records are not newly classified or rewritten.

### 3. Focused executed tests — current pass only

| Surface | Final result | Scope and evidence level |
|---|---|---|
| iOS unit/native | **106 passed / 0 failed**, 67s | Final disjoint class selection listed below. Includes 12 new receipt contract/file tests and production sync/task-link/fallback regression. Skipped metric not exposed. No live HTTP. Earlier 41/105/106 passing runs overlap and are not added. |
| iOS UI batch | **NOT ACCEPTED: runner overall failed/interrupted after 4 reported passes, 0 reported assertion failures** | Requested `KeyboardInteractionUITests` + `LegacySprayRecoveryUITests`. Output stops after test-product synchronization/run and gives no test names or cause. Managed `/tmp/rork-swift-test-ios.log` is inaccessible locally. No unchanged automatic rerun. Cannot attribute four passes to specific cases or claim the new RPC app-termination journey executed. New debug fixture/test is compiled, but current UI acceptance is unverified. Historical full keyboard/recovery UI successes below remain historical, not new passes. |
| Android host | **193 tests / 0 failures / 0 errors / 0 skipped**, 16 XML suites | Existing bounded calculator runner plus five new golden/decoder/request tests. Final runner exit 0, 3m28s including compilation. XML independently counted. All synthetic, not authenticated backend execution. |
| Android instrumentation | **84 passed / 0 failed / 0 skipped**, 20s | Final classes: LegacySpraySaveAndroidTest, data.auth.AuthRetentionAndroidTest, data.auth.FieldSaveContentionAndroidTest, ChemicalConditionPersistenceAndroidTest, InventoryUpcomingPersistenceAndroidTest. Includes 15 legacy tests, seven new receipt cases, and the existing real secondary-process kill test extended with RPC_CLAIMED/exact-request synthetic recovery. These are included in 84, not additional passes. |

Final iOS selection: `LegacySprayPairReceiptTests`, `SpraySaveForLaterTests`, `SyncStatusTimestampTests`, `SyncQueueRegressionTests`, `SprayTripStartAdmissionTests`, `SprayCalculationContractTests`, `SprayCalculatorUXPassTests`, `KeyboardSceneCoordinatorTests`, `ChemicalInventorySummaryTests`, `WorkTaskPlanningParityTests`.

Android host runner: `scripts/run-calculator-completion.py --launch` using the existing bounded init script plus `LegacySprayPairReceiptTest`; existing calculator/guided/carrier/rate/planning/first-tank selections retained. Exact XML output under ignored `android-vinetrack/app/build/test-results/testDebugUnitTest/` confirms 193/0/0/0.

Development failures retained: first Swift compile lacked the Supabase import; the next debug restart-fixture compile needed two explicit `try` expressions. Both corrected before final passing tests. Initial Android instrumentation used incorrect package names for two auth test classes (17 passes plus two class-load failures); corrected selectors to `.data.auth.*`, then final full 84 passed. This was a test-selection error, not a hidden passing business assertion. The separate iOS UI-run interruption remains unresolved and is not described as a pass. Final audit also found conditional accepted-ID suppression could vanish after a session/edit; fixed persistent accepted identity suppression, absent-row dirty-write containment and both Trip/record initial fallbacks, then final 106 tests passed.

### 4. Required scenario matrix and limits

| Requested scenario | Mobile synthetic/native evidence | Live authenticated authority |
|---|---|---|
| Initial atomic pair save | Requires validated create candidate plus matching exact-body recovery before release | BLOCKED: transaction/trigger/orphan behavior not independently exercised by Rork |
| Identical operation replay | Frozen operation/body equality, verified repeats do not resend, recovery receipt equality | BLOCKED: identical server stored-receipt replay not called |
| Lost successful response | Recreated native stores recover the exact claimed body with no create replay | BLOCKED: synthetic lost response/receipt, not real HTTP post-commit loss |
| Concurrent duplicate | Reentrant/connect overlap preserves IDs, one create claim; recovery-only competing path | BLOCKED: real database concurrent-lock/idempotency acceptance |
| Same operation / changed body | Original journal cannot be replaced; server conflict response cannot release hold | BLOCKED: real server changed-body call |
| Reused Trip/Record IDs | `identity_conflict` response is terminal and retained | BLOCKED: real cross-operation ID contention |
| Missing/revoked/foreign scope | Native account/epoch and original-scope checks prevent send/ack; errors do not become receipts | BLOCKED: real users A/B and current membership revocation |
| Reconnect / actual termination | Android real secondary process death retains RPC operation/body/claim and recovers via synthetic transport; iOS real-termination test authored/compiled, current UI run unaccepted | BLOCKED: main authenticated app network/lifecycle and physical handset |
| Old REST uncertainty/completion | Never adopted into RPC or automatically replayed; retained identity holds including old COMPLETE | No live old-row lookup used as evidence |
| Second-record failure / no orphan | Native client uses one atomic RPC; stored rejection/errors retain hold and original evidence; no compensating DELETE | BLOCKED: only backend owner transaction definition, no authenticated rollback test |
| Dependent Task/spray/Trip/Start | iOS production sync/task-link probes and native journals hold until verified acceptance; release still subject to all safety gates | BLOCKED: end-to-end authenticated operational dependency acceptance |
| Unrelated sync | Production iOS probes prove unrelated uploads while held; existing Android queues remain separate; retention/contention regressions pass | BLOCKED: combined deployed-main-app network acceptance |

No synthetic receipt, raw SQL review, golden hash, store recreation or secondary-process fixture is represented as authenticated backend acceptance, physical navigation, full cross-platform handover or real GPS evidence.

### 5. Native builds

- iOS final `runChecks(ios)`: **PASS, simulator build**. No device/release/App Store build.
- Android final `./gradlew :app:assembleDebug --build-cache --console=plain`: **PASS, 11s**; instrumentation also builds debug app/test APKs. Android `runChecks` was deliberately not invoked because that tool unconditionally builds `assembleRelease`, contrary to the explicit no-release-build restriction. No release APK was rebuilt or distributed in this pass.
- Versions/build numbers unchanged. Protected-source and application whitespace audits pass. Existing iOS legacy asset URL notices are unrelated and left unchanged.

### 6. Authenticated backend results and integration discrepancies

**Authenticated live calls: NOT RUN / BLOCKED.** The owner explicitly confirms there are no provisioned/verified genuine test users and isolated vineyard. No customer mutation, synthetic golden request submission, service-role validation, credential request, SQL Editor test, deployment or live authenticated receipt claim occurred. Provision/verify isolated genuine JWT users A/B, membership/reference fixtures and safe cleanup before executing the handoff's server matrix.

**Actual client/contract discrepancy:** v1's exact allowlists omit newer fields that the existing validated spray insert can emit: `sprayer_configuration`, `spray_planning_method`, `full_tank_specification`, `planning_input_provenance`, `planning_intended_tank_litres`, `planning_target_area_ha`, `planning_calibrated_litres_per_hectare`, `planned_application_area_ha`, `resolved_planning_carrier_litres`, `resolved_planning_litres_per_hectare`, `resolved_planning_physical_row_litres_per_100m`, `resolved_planning_concentration_factor`, `controller_litres_per_100m_travel`, `effective_working_width_metres` (and any explicit-cleared versions). A request carrying these is rejected **locally before transmission**, retaining the complete original native mix and a contract-review status. Exact shape is the same three-argument envelope above, but `p_record` includes the additional planning keys; no server result was observed. Failure classification: **local unsupported insert contract**, not accepted/rejected/unknown/HTTP failure. Removing necessary planning evidence, reclassifying it as manual, changing calculations or widening the server allowlist was not authorized and was not done. Similarly, an occurrence-backed or work-task-linked Trip is not routed through this legacy RPC. Backend-owner alignment is required before those out-of-contract mixes can be sent through v1.

There is no observed live server behavioral discrepancy to report, because no live authenticated tests were authorized or possible in this pass.

### 7. Changed native files

Android:
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/LegacySprayPairReceipt.kt` (new)
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/LegacySpraySaveStore.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/SprayRecordRepository.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/TripRepository.kt`
- `android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/AppViewModel.kt` (legacy no-route creation/reconnect only)
- `android-vinetrack/app/src/androidTest/java/com/rork/vinetrack/data/LegacySpraySaveAndroidTest.kt`
- `android-vinetrack/app/src/debug/java/com/rork/vinetrack/data/LegacySprayProcessProbeActivity.kt`
- `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/LegacySprayPairReceiptTest.kt` (new)
- `android-vinetrack/app/src/test/resources/legacy-spray-pair-v1-golden.json` (new exact supplied fixture)

iOS:
- `ios/VineTrack/LegacyImported/Services/LegacySprayPairReceipt.swift` (new)
- `ios/VineTrack/LegacyImported/Services/LegacySpraySaveRecovery.swift`
- `ios/VineTrack/LegacyImported/Services/MigratedDataStore.swift`
- `ios/VineTrack/Backend/Sync/TripSyncService.swift`
- `ios/VineTrack/Backend/Sync/SprayRecordSyncService.swift`
- `ios/VineTrack/App/BackendSettingsView.swift` (receipt/rejection status)
- `ios/VineTrack/App/Keyboard/LegacySprayRecoveryValidationView.swift` (debug-only synthetic restart fixture, not keyboard production behavior)
- `ios/VineTrackTests/LegacySprayPairReceiptTests.swift` (new)
- `ios/VineTrackTests/SpraySaveForLaterTests.swift`
- `ios/VineTrackTests/legacy-spray-pair-v1-golden.json` (new exact supplied fixture)
- `ios/VineTrackUITests/LegacySprayRecoveryUITests.swift`

Supporting updates: existing approved plan, this existing report, `.rork-tmp/calculator-completion.init.gradle` focused test selection and its existing runner log. No SQL/Edge/build configuration/linked-source changes. Rork-managed history/state remains tracked and untouched by manual edits.

### 8. Release-readiness and physical checklist — still open

**Not declared release-ready.** Remaining: isolated authenticated server matrix; v1/newer insert-field alignment for affected mixes; interrupted iOS UI batch; physical acceptance; final managed commit SHA exposure. Existing broader occurrence/Portal/full-schema gates remain separate and were not activated or resolved by this legacy-only pass.

Physical owner checklist (all unexecuted here):
- [ ] iOS VoiceOver focus/traversal and keyboard-only Done, retained prompt/draft, separate Confirm/Cancel.
- [ ] Small iPhone, larger Dynamic Type and dark mode; quantity text retains 0.525 kg → 0.53 kg.
- [ ] Archived Chemical Inventory remains excluded after actual device restart, both platforms.
- [ ] Upcoming Tasks refresh correctly after foreground resume and vineyard-local midnight/day rollover.
- [ ] Offline Save for Later retains original operation/IDs/payload after real main-app termination; authenticated recovery in isolated scope releases only matching accepted receipts; revoked/foreign accounts cannot adopt it.

Calculations/CF/rate safeguards, eight-step calculator UI, Single Row/Over-Row/Only Full Tanks, warning-only policy, native keyboard production dialog, Chemical Inventory archive logic, Upcoming Tasks/local-day logic, auth recovery, frozen Live Trip source and existing historical records/Actuals are protected and unchanged. New planning and occurrence creation were not activated. No store/publishing action is authorized by these results.

## Historical checkpoint — prior code-only containment

### Previous checkpoint — code only

This checkpoint supersedes the earlier status/evidence below. Store authentication/access, TestFlight/Play distribution, version increments and device installation are cancelled. No store workflow was called after the owner's STOP correction. No store build was submitted or distributed. No interactive simulator rental, production backend call/deployment, dosing arithmetic change or frozen Live Trip change was performed during this development pass.

| Deliverable | Current result |
|---|---|
| iOS editable-prompt keyboard | **PASS.** SwiftUI system alert was replaced only for editable prompts with an app-owned native modal input dialog. Done is a real button inside the dialog's accessibility hierarchy, resigns only the input and preserves the dialog/draft. Confirm/Save and Cancel remain separate. The global keyboard coordinator and existing focus-transfer implementation are unchanged. Full original keyboard XCTest class: **6/0**, including the corrected popup journey; only the popup container/Done locator changed for the approved alternative, all dismissal/draft/no-submit assertions remain. Actual physical VoiceOver traversal remains unverified. |
| iOS legacy recovery/status | **Local implementation PASS; immutable remote acceptance remains held.** Eligible push/pull success is distinguished from held pairs via a partial-sync state; full-sync/server-ready stamps do not advance. Per-pair local repair conflicts and foreign-session evidence do not veto unrelated synchronization. Retained IDs are excluded from upload/delete/pull and direct work-task link mutation; parent readiness and Start remain refused. Original WAL is not replaced or erased. |
| Android legacy recovery | **Provably-unsent recovery PASS.** PREPARED is the only first-send-admissible stage. Startup/vineyard load/reconnect reuse original IDs, timestamp, frozen Trip/input and captured authenticated authority. UNKNOWN is durably committed before transport, so cancellation/lost/malformed/409 outcomes never revert to PREPARED. No uncertain-stage replay, remint or rollback. Device-only saved/pending status is explicit; account-session changes remain fenced. |
| Calculator/UI freeze | Eight steps, Step 6 cards/illustrations, Single Row/Over-Row, By Area/Only Full Tanks, WARNING-only policy and rate/draft/regional corrections preserved. All new planning operational gates remain disabled. Final regressions exposed a quantity-display tie rounding error (0.525 kg was shown as 0.52 kg); product quantity formatting now rounds that tie to 0.53 kg, retaining local decimal separators. No dose/CF/conversion equation changed. An informational canopy-comparison flag now requires actual dilute-reference evidence rather than assuming canonical L/ha means a canopy comparison occurred. |
| iOS automated regressions | **525 unit/native tests passed, 0 failed** across two disjoint final selections (368 core + 157 recovery/regional/planning/keyboard). **12 UI tests passed, 0 failed** across two disjoint bounded selections (6 keyboard + 6 editing/presentation/restart). Final direct-link/held-status hardening: **30/0**, overlapping the 157 and not added. |
| Android automated regressions | **188 host tests / 0 failures/errors/skips**, 15 suites; **93 instrumentation tests / 0 failures/skips**, including editor/planning/chemical-condition persistence, legacy original first-send/lost-response containment, actual secondary-process death, occurrence persistence, account retention and field-store contention. Eight legacy tests are included, not extra. |
| Native correctness builds | **Both passed.** iOS simulator compilation and Android native build only; no signed iOS handset/TestFlight or Play release acceptance claim. App versions and release numbers unchanged. |
| Source | Current exposed HEAD `3331302aa4ceb023431df404d43eea238d1e5a13` plus the final native diff SHA-256 `74594230ef75462ef39ed4357a445184237d8ea6a752c8781f52ff1e743ff41b`. This HEAD alone is not the final changed source. Rork creates the final commit at turn completion; its final SHA is not exposed during this turn and cannot honestly be invented. Requested `59242a2568d485769db5b882be0a0c950441c34f` is unavailable to Git here; recovery source was reconciled by content without reset/cherry-pick or replacement of newer work. |
| Remaining external acceptance | Backend owner (ChatGPT/backend): authenticated immutable legacy paired-create receipt/recovery authority and real ambiguous-HTTP/reconnect/concurrent-server acceptance. Handset owner: separately authorised physical VoiceOver, small-screen/dark/larger-text and real screen timings. These are not unresolved automated mobile assertion failures. |

### Exact final selections

Core iOS 368/0: SprayCalculationContractTests, SprayCalculationParityTests, SprayCanopyAndRatePresetTests, SprayCanopyCarrierRoutingTests, SprayGuidedFlowTests, SprayGuidedWorkflowParityTests, SprayRegisteredUseRateTests, ChemicalLabelRateNormalizerTests, CropSilRateRegressionTests, SprayEditChemicalRegisteredRateDisplayTests, SprayRateBasisPreferenceTests, SprayLegacyRateUnitBoundaryTests, SprayApplicationGeometryTests, SprayApplicationSnapshotTests, SprayCarrierProductBasisTests, SprayVolumeDecisionTests, SprayManualVolumeTests, SprayBandedGroundCarrierTests, SprayCustomSprayerBasisHotfixTests, SprayEquipmentAndCarrierHandoffTests.

Recovery/regional iOS 157/0: SprayGrowthStageDecisionTests, SprayRegionClosureTests, RegionalInputTests, SprayPlanningIntentTests, SprayPlanningAttemptTests, SprayPlanningDraftTransitionTests, SpraySaveForLaterTests, SyncStatusTimestampTests, SyncQueueRegressionTests, KeyboardSceneCoordinatorTests, SprayCalculatorUXPassTests, SprayCarrierProvenanceTests, SprayTripStartAdmissionTests, SprayStartPresentationTests, SprayTripSetupTests.

UI: KeyboardInteractionUITests 6/0, 200s; SprayEditingAcceptanceUITests + SprayPresentationUITests + LegacySprayRecoveryUITests 6/0, 209s. The restart test covers all four original local boundaries using real app termination/relaunch and isolated storage; no authenticated server recovery is implied. iOS runner does not expose a separate skipped count.

Android host: `scripts/run-calculator-completion.py --launch`, final exit 0, 30s; XML independently confirms 188 tests / 0 failures/errors/skips. Instrumentation: LegacySpraySaveAndroidTest, SprayChemicalEditorAndroidTest, SprayPlanningAndroidTest, ChemicalConditionPersistenceAndroidTest, TripOccurrencePersistenceAndroidTest, AuthRetentionAndroidTest, FieldSaveContentionAndroidTest: 93/0/0, 47s. Secondary-process kill is genuine Android process evidence, not proof of main authenticated Activity/network recovery.

### Development failures retained, not hidden

- Accessory installation alone still failed the original popup query (9 passes/1 failure). Replaced affected editable prompts with the native dialog; the focused original journey plus native tests then passed 10/0, and final full keyboard class passed 6/0.
- The wider core selection exposed 23 failures: outdated prerequisite fixtures (explicit equipment/canopy/ground decisions, valid product before persistable snapshot), old stock-unit equivalent wording, locale-sensitive text and manual entry-versus-canonical-carrier metadata. Fixtures now reflect approved production contracts; unknown new canopy remains unconfirmed. Label-rate units are retained in equivalents; liquids use original canonical mL. No quantity assertions were relaxed or dose formulas changed. Valid display half-tie rounding and informational comparison metadata were corrected in source. The final core selection passed 368/0.
- Three later cross-surface failures were fixture-only: invalid `Kilograms` wire literal instead of `Kg`, liquid values entered as litres in a base-mL fixture, and an advisory Save test without authenticated WAL scope. The latter now also asserts that WARNING-only chemistry cannot bypass the separate receipt hold.
- One combined runner stopped after 162 passes with no reported assertion failures and was not counted as successful; the reported remote log path did not exist in this sandbox. Splitting unit and UI execution into bounded selections produced the explicit successful results above. Selector-validation errors executed no tests.

### Precise server dependency (unchanged)

Only uncertain remote outcomes and iOS receipt-held local pairs still require backend authority. Acceptance must bind the authenticated actor, vineyard, original operation/record/Trip IDs, complete immutable payload and any existing occurrence-parent dependencies; serialize same-request duplicates and reject same-ID/different-payload; atomically create the pair or retain an immutable conflict/rejection result. Recovery must return the original accepted/rejected/unknown result and exact request identity, not mutable current row existence or HTTP 409. Lost replies remain unknown until that receipt is verified. Historical valid rows remain compatible and must never be adopted as a new operation by inference. No tracking, actual coverage, tank, labour, inventory or current-geometry reconstruction effects belong to Save for Later recovery. Native integration against that contract and authenticated transport fixtures remains Rork's follow-up once the backend owner supplies the verified authority.

Application-scoped whitespace checks pass. SQL/Edge, frozen tracking/TripsScreen, new planning journals and version/build configuration have no changes in this pass. Existing asset-URL advisory warnings are nonblocking and were left outside the requested scope.

## Historical checkpoint — superseded status table

| Item | Result | Exact qualification |
|---|---|---|
| Six iOS canopy regressions | **PASS — all six** | The 96-test affected calculator/recovery selection passes. Only obsolete wording and outdated fixtures changed; production canopy calculations/validation unchanged. New selection still has no assumed VSP; historical/prefilled selection retains intentional confirmation. |
| SwiftUI alert Done | **OPEN** | Focused hosted-SwiftUI native diagnostic initially passed, then failed native visibility in the wider run (103 passes/1 failure). Original full XCTest still fails to find `keyboard.dismiss`. This is not established as a query-only defect. Real VoiceOver navigation unverified. |
| Legacy Save for Later | **Production local recovery / containment implemented; remote acceptance BLOCKED** | Both platforms retain the complete original attempt before dependent writes and integrate startup/sync admission. iOS repairs interrupted local files; Android retains uncertain REST stages without automatic resend/rollback. Receipt-based remote recovery is not implemented or claimed. |
| Android editor / label parity | **Preserved; focused regressions PASS** | Combined instrumentation 16/0/0; later recovery-only hardening run 5/0/0. Existing dot/comma, invalid-draft, Done and label-selection policies unchanged. iOS production editing/Step 6 UI passes. |
| Five Start Spray presentation decisions | **Unchanged** | No redesign or duplicate controls. Summary adds truthful device-local save status, not a CF acknowledgement or new planning gate. |
| New planning | **Operational gates remain closed** | New planning attempt journals/activation state unchanged. No planning RPC exercised; Review remains one intention-only selector and three distinct groups. |
| Source / native candidates | **Identified below; final managed commit pending** | Current exposed source is `a7fadaf856afa002c96ffd38cbbae8ffe52aa575` plus this pass's patch. Requested `0ab37a6ca5b008cdf5712fbf38ccb486710ad62c` object unavailable; no rollback to it. Both final builds pass. |
| Controlled handset UI acceptance | **Checklist READY; execution BLOCKED** | Independent of legacy recovery. Need separately authorised, exact-artifact handset session; no latest signed iOS device artifact or verified handset installation is available. Do not assume TestFlight 168/169 or old APKs contain this patch. |
| Full operational release acceptance | **BLOCKED** | Alert visibility/accessibility, verified legacy paired-create receipts/real HTTP reconnect, physical handset journeys and remaining broader backend acceptance are unaccepted. No release is authorised. |

## Source protection

Initial application/index state was clean at `a7fadaf856afa002c96ffd38cbbae8ffe52aa575`; only pre-existing managed Rork state/history differed and was left untouched. `git show` for the supplied 0ab37a6… revision returned “bad object / not our ref”. The current production files contain the consolidated numeric/label corrections; no attempt was made to restore an older tree or overwrite newer source.

Source-scoped whitespace checks pass. No SQL, Edge, chemical catalogue, GPS/row locking, coverage/tank Actual authorities, frozen `TripTrackingService.swift`, Android `OccurrenceTraversalTracker.kt` or `TripsScreen.kt` changes. Both new `SprayPlanningAttemptJournal` implementations are unchanged. The Android ViewModel edits are limited to legacy no-route creation, its admission/start hold and startup/dependent-sync containment; no traversal/ETA/tank tuning.

## Canopy reconciliation

All six named tests pass after source-backed fixture reconciliation:
- `foliarRequiresCanopyConfirmation`: matches “Select canopy type, size and density”.
- `canopyStepPrecedesProducts`: matches “Canopy & Spray Volume”; preserves eight-step ordering.
- `selectionUsesTheExistingTable`: explicitly chooses VSP before size/density, then compares the existing table.
- `touchingAPickerConfirms`: explicitly chooses a type before expecting a picker to resolve the complete canopy.
- `confirmingUnchangedValuesCounts`: explicitly chooses a type; confirming defaults without type remains unresolved in the opening-position assertion.
- `completingProductsDoesNotEndTheStep`: supplies an explicit confirmed canopy, target/head target, growth-stage decision, equipment selection/confirmation/capacity and volume decision, rather than bypassing genuine earlier prerequisites.

No new spray assumes VSP. Historical `prefilled` compatibility remains tested. Neither production validation nor equations changed.

## Alert diagnostic and genuine remaining defect

Hypothesis: SwiftUI presentation may replace/hide the accessory despite working native UIKit installation. Added one hosted SwiftUI `.alert` diagnostic using an app-owned scene window and the production coordinator. It finds the real text field across same-scene windows, checks its accessory/window, native visibility, accessibility-element label, keyboard-only dismissal and unchanged alert/draft/submission state.

Observed results:
- Initial focused diagnostic + original UI journey: **1 passed / 1 failed**. Native diagnostic passed; original XCTest failed its Button lookup for `keyboard.dismiss`.
- Subsequent wider selection: initially **104/0**, then **103/1**. The sole later failure was `swiftUIAlertOwnsAccessoryAndDismissesWithoutSubmitting`: `nativeVisible` failed. Its separate accessibility-label and programmatic dismissal assertions did not fail.
- Thus labelled native-control configuration and programmatic keyboard-only dismissal are demonstrated in the fixture, but reliable visible presentation is NOT. Actual VoiceOver traversal/publication cannot be inferred from native accessibility properties.
- The complete original XCTest remains **FAIL**: `Failed to no matches found for first query match sequence: Descendants matching type Button -> Elements matching predicate '"keyboard.dismiss" IN identifiers'`.
- Original assertions remain; production coordinator/accessory were not rewritten, and no unsupported workaround or additional dedicated simulator inspection was used. No unchanged failure was repeatedly retried to find a green result.

A later final calculator/recovery selection deliberately excludes the separately known failing keyboard diagnostic; its 96 passes do not erase the 103/1 wider result or full UI failure. Owner: Rork. Required closeout: establish reliable SwiftUI accessory presentation and real accessibility publication/tap without changing alert confirmation semantics.

## Legacy recovery implementation and exact containment

### iOS production integration

Files: `LegacyImported/Services/LegacySpraySaveRecovery.swift`, `MigratedDataStore.swift`, `NewBackendAuthService.swift`, `SprayCalculatorView.swift`, `SprayTripSetupSheet.swift`, Trip/SprayRecord sync services.

- A separate checked atomic local write-ahead record captures actor, vineyard, a durable session UUID, complete original record/Trip, stable IDs and frozen occurrence evidence. This is NOT a planning-protocol receipt/journal.
- Preparation now precedes even existing occurrence-parent preparation. The existing occurrence machinery is not replaced, reminted or enabled.
- A restored same-actor session uses its persisted UUID; explicit sign-out must durably rotate it first or sign-out is refused. Foreign actors/sessions never repair an old attempt.
- Original record/Trip are encoded into nested bytes preserving fractional dates. The legacy cache ISO-second projection is compared using its existing codec, not by relaxing chemical/route fields or rewriting historical codecs.
- Recipe and inactive Trip are checked/repaired from the original WAL, followed by a completion marker. Neither dirty callback fires before all three writes are durable. Existing differing values are held, not overwritten. Active/ended/tank-session/coverage-bearing attempts are refused.
- Hydration attempts reconciliation; both production sync writers reconcile again before dependent writes. Initial empty-server fallback, dirty upserts, deletes, remote replacement and work-task-clear admission exclude retained IDs. Unrelated records retain their normal sync path. A held sweep is not labelled server-success.
- Ordinary REST last-write-wins upsert cannot prove immutable original acceptance. New retained pairs therefore stay **device-local / remote-held**; generic upload, automatic recovery and saved-job activation are refused pending verified paired-create recovery. The summary explicitly states device-local status. Existing unjournalled eligible saved jobs keep their existing path.
- A locally completed but remotely held attempt cannot be bypassed with a new ID/session for that actor/vineyard. Retained evidence is never deleted automatically.

This is safe client containment, **not full legacy server completion**. There is intentionally no invented remote receipt or automatic LWW replay. Device-local completion does not imply synchronization or operational readiness.

### Android production integration

Files: `data/LegacySpraySaveStore.kt`, `TripRepository.kt`, `SprayRecordRepository.kt`, `auth/AccountTransitionEvidence.kt`, and narrowly scoped `AppViewModel.kt` seams.

- The no-route branch mints Trip/record IDs and timestamp once, captures full original accepted input/Trip intent, actor and persistent identity epoch, and durably commits before its first request. Qualified occurrence-backed flow remains separate and unchanged.
- Stages: Prepared → Trip Unknown → Trip Confirmed → Record Unknown → Complete. Every advance requires a checked synchronous preference commit/read-back under existing account admission. Failed commits never report success.
- Captured token/actor are used for both initial sends, never a newer login's credentials; tokens are not persisted. Publication is fenced by the original `AccountAccess`.
- Successful initial `return=representation` responses must echo submitted fields, including nested quantities/conditions, with only numeric/ISO timestamp representation equivalence. This validates that initial response; it is NOT acceptance of a later current-state read. 409/malformed/changed/lost replies remain uncertain.
- Startup/vineyard load surfaces retained work before reconnect replay. It never inserts this envelope into the generic outbox. Dependent queued references are held; unrelated pipelines are not globally disabled. A retained incomplete Trip cannot be started through Start Spray Job.
- No ambiguous rollback via `soft_delete_trip`, no fresh-ID resend and no automatic outcome inference. Sign-out evidence inspection includes the new retained store and fails conservatively; cross-account recovery is not adopted.
- Known offline preparation is retained and returns false, not server success. Unfinished attempts block a newly minted retry in that actor/vineyard. The original payload/IDs remain available for receipt-based reconciliation.

### Remaining essential backend dependency

ChatGPT/backend owns a validated authenticated legacy **paired-create acceptance/recovery contract** (or an explicitly approved mapping to existing immutable authority) that can establish:
1. Exact original actor/vineyard/operation and complete payload identity, including record/Trip IDs and occurrence-parent dependencies.
2. Authoritative immutable original acceptance versus rejection/unknown, not mere current row existence or HTTP409.
3. Atomic/idempotent acceptance of the same request, same-ID/different-payload refusal and conflict-safe parent/recipe ordering.
4. No tracking, coverage, tank/labour/inventory effects in Save for Later recovery; no route reconstruction from current geometry.

No signature/RPC installation, credentials, backend access or deployment is assumed. Rork still owns transport-failure/reconnect integration against approved receipt fixtures/authority once available. Full authenticated ambiguous-HTTP recovery and concurrent-server duplicate prevention are NOT claimed by these tests.

## Executed evidence — do not sum overlapping selections

| Surface | Latest result | Evidence limit |
|---|---|---|
| iOS final calculator/recovery unit selection | **96 passed / 0 failed**, 88s | Six calculator/recovery suites, excluding separately known keyboard failure. Includes all six canopy fixes and production sync fallback/containment regression. |
| iOS recovery-only final hardening | **9 passed / 0 failed**, 62s | WAL failure boundaries, conflict/scope guards, exact fractional-date evidence, dirty/fallback/delete containment and unrelated-record sync. Overlaps 96. |
| iOS final UI selection | **3 passed / 0 failed**, 190s | Two existing production chemical/regional tests plus one real app terminate/relaunch test looping four local boundaries. |
| iOS app-process restart fixture | **Pass at prepared, recipe, Trip and completed-local boundaries** | XCTest terminates/relaunches the real app with production store/WAL in isolated debug storage. Not abrupt OS kill during a disk write, not authenticated server reconnect. |
| Android combined instrumentation | **16 passed / 0 failed / 0 skipped**, 49s | Five legacy containment tests plus three editor and eight existing planning UI/persistence tests. Synthetic account and transport-free state scenarios. |
| Android final recovery hardening | **5 passed / 0 failed / 0 skipped**, 16s | Production checked preferences; failed commits, scope revocation, changed echoes, recreation and actual secondary-process death. Overlaps 16. |
| Android process-death probe | **Pass at all four unfinished stages** | `Process.killProcess` kills a debug-only `:legacySaveProbe` Android process; a newly launched process independently reads original IDs/payload/stage and retains the hold. Not a host JVM child, but also not the main authenticated Activity/ViewModel lifecycle or actual server reconnect. |
| Android host calculator regressions | **188 passed / 0 failures/errors/skips**, 15 suites | Existing bounded runner; model/state evidence only. No new screen timings inferred. |
| Original iOS full alert UI journey | **Failed** | Assertion retained. Native visibility diagnostic also has the later failure described above. |
| Final iOS build | **Passed** | Simulator build only, no new signed handset/TestFlight artifact. |
| Final Android build | **Passed** | Release APK only; no handset install/distribution/upload. |

New process fixtures are debug-only, use isolated synthetic scoped storage and never call live backend, create vineyard data or start recording. Standard native tests ran in the managed test environment; no dedicated interactive simulator rental or handset deployment was performed. Assertion failures during development are not hidden: initial date-equality tests exposed the legacy ISO-seconds codec; original WAL now preserves full dates and existing-store comparison uses the exact legacy codec. One throw-expression compile error in the sync fallback guard was corrected before the final passing build/tests.

## Exact candidate identities

- Visible HEAD: `a7fadaf856afa002c96ffd38cbbae8ffe52aa575` **plus this pass's managed native patch**, not HEAD alone.
- SHA-256 of `git diff HEAD --binary -- ios android-vinetrack`: `b4543b33c2cea2ace1dc6f65d39fe04a42f4dbdf3fb1925a9f944314707a094f`.
- Final managed commit is not exposed during this turn. No manual commit/push; post-finalization attribution is required for an immutable source-commit candidate.
- iOS: `app.rork.nt0v48tayl7v8noxcfe74`, project version 3.1.7/build 139; final simulator build passed. There is **no new exact signed IPA/TestFlight handset artifact** for this patch. 168/169 are not assumed current.
- Android: `com.rork.vinetrack`, release version 3.1.7/code 11; `android-vinetrack/app/build/outputs/apk/release/app-release.apk`.
- Android APK SHA-256: `eaab1e61e4bb8c13bc7044964dd3ac60f5b27dfc1e53d981ab26bbda0e4ced83`.
- This is the new calculator/legacy-containment candidate, not frozen Live Trip APK `8836a3025c30a779c04a0e1207490687f3d73a55ebf05eab1babb3eae4a538bb`. Shared version numbers do not identify code. Handset installation and independent new signer verification unexecuted.

## Controlled handset checklist — independent of legacy recovery

Checklist prepared; **do not install/upload/distribute without separate authorisation**. Use only an existing approved synthetic/non-operational account and an artifact whose installed identity is verified against this candidate. Never clear pending data/uninstall to overcome signature/version mismatch. No Trip creation or operational button activation is needed for these checks.

Record device/model, OS, installed commit/artifact identity, region, dark/light mode, text-size setting, approximate timestamps and screen recording before starting. Repeat on the smallest authorised display at default and larger accessibility text.

1. Navigate all eight guided steps; verify Back retains drafts and Continue unlocks only after actual prerequisites. Explicitly choose canopy type/size/density; do not assume VSP.
2. Step 6: retain the two inline cards, Single Row / Over-Row, original vines/sprayer and vine-facing cyan/blue arrowheads. At 600 L/ha and 2.8 m, controller travel is 16.8 / 33.6 L/100 m; physical rate/chemical dose stay unchanged.
3. By Area / Only Full Tanks: inspect existing Target area and Calibrated rate fields. 1500 L over 3 ha gives 500 L/ha; 1500 L at 600 L/ha gives 2.5 ha. Separate tank-load Full Tanks labels remain.
4. Open the existing label-rate sheet; confirm large numeric rate/unit and all crop/target, condition/direction/restriction/withholding/re-entry text. Select an explicit valid REVUS/Crop Sil condition or offered preset; do not guess missing rates. Incompatible DiPel dimension remains noncalculable.
5. Open/close orange WARNING details, including an eligible CF2/unknown-permission scenario. It changes no values and requires no acknowledgement; invalid calculations remain invalid. Do not activate disabled new planning.
6. Enter dot/comma pairs 25.75/25,75; 0.75/0,75; 1250.5/1250,5. Try incomplete trailing separators and malformed nonblank text; original draft remains visible and no old/recommended dose becomes executable. Inspect per-100 L and per-hectare independently.
7. Use Done, re-focus, Back and reconstruction in chemical editing. Done only dismisses keyboard. Change regional units: complete values convert together; incomplete groups retain original units and guidance.
8. Inspect the alert while typing: separately capture whether Done is visually present, VoiceOver reaches it, it dismisses keyboard only, alert/text persist and Confirm/Cancel/Save counters do not change. The automated failure is open; do not presume success.
9. Scroll all controls at large text/dark mode; no obscured fields, overlapping labels, clipped buttons or tiny forced text. Stop before any Save/Start effect.
10. Review contains Planned Spray Mix, Selected Physical Work and Actual Spray Coverage. Selection describes intention only, Over-Row is one travel occurrence/two controller equivalents, and no actual coverage is manufactured. No duplicate selector or tracking shortcut.
11. Confirm the existing eligible entry workflow is presented, but do not create Trips or invoke new planning to test it. Device-local legacy-held work must be labelled pending, not server-ready.
12. In the authorised authenticated session, capture timestamps for calculator opening, Step 6, numeric edit/Done, rate-sheet opening and Review rendering. Report actual visible-screen durations with device/network/context separately from model/I/O benchmarks. Do not add a performance refactor without a measured bottleneck.

No physical screen captures, VoiceOver navigation or genuine handset screen timings were collected in this pass. Existing Android caching and iOS product mapping optimisations are unchanged. Controlled UI inspection must not be delayed for backend recovery once an exact authorised handset artifact/session is available; operational Save/Start remains separately blocked where receipt evidence is missing.
