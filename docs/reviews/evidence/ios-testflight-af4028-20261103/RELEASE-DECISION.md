# iOS internal TestFlight preparation — af4028 — HOLD

Requested GitHub source: `af4028a9b12630fbf515133cb7930d34880bec38`. No outdated PR #50 source imported. No Android, Supabase, production-record or retained-device-data mutation. No signed build requested or uploaded in this pass.

## Exact source verification
The GitHub archive at the requested SHA was downloaded read-only to `/tmp/af4028.tgz`, SHA-256 `2bfde319e2ce88a4c5511bff0ed5d3bd023c86a02df564a05dc133fe539fc02e`. Every pinned iOS file matches the workspace byte-for-byte, excluding the ignored generated `ios/VineTrack/Config.swift`. The two PR #50 corrections and integration tests are present. Managed HEAD at inspection was `2f881b58cfd13012e47d6f90043f3b6e7ceebfbb`; that is not being represented as the requested GitHub SHA. GitHub main subsequently read as `9fef5adcf6ebba03233f0e86f886884b22c30f0f`; no later source was adopted.

## Current native validation
- Normal managed iOS simulator build: PASS. Not a signed device/Release archive.
- Managed native selection on the unchanged pinned iOS source: **188 passed / 1 failed**.
- Selection: TripLocalEndAntiResurrectionTests, TankSessionTimestampEncodingTests, TripQueuedUploadScopeTests, TripOccurrenceJournalTests, TripJournalAbsenceIntegrationTests, TripDeletionRecoveryTests, SprayTripPhase5FinalisationTests, TankDependencyVerificationTests, SpraySaveForLaterTests, ActiveTripRouteRecoveryTests, TripActivityCancellationTests, LegacySprayPairReceiptTests, TrackedSprayCompletionSyncTests.
- Only reported failure: `TripDeletionRecoveryTests/pendingUploadInspectionIncludesQueueWithNoRecordedFailureAndPreservesIt()`, asserting `queued_trip_uploads: 1`. Production emits `queued_trip_uploads_global_legacy: 1`, `queue_marked_failed_global_legacy: 0`, and `TRIP_ACCOUNT_NOT_VERIFIED: 1`.
- This is the previously recorded independent baseline diagnostics-label mismatch, not a Trip-sync behavior failure. Both expected labels are obsolete. Correcting them requires a new committed test-source revision; no test/source change was made so the requested SHA stays exact. The failure remains a failure and is not silently excluded or counted as passed.
- Native runner supplies aggregate results; no passing-case XML/xcresult exposed. Counts overlap earlier runs and are not added.

## Exact-SHA GitHub native workflows
Both were still in progress after a bounded 200-second final observation; neither is certified as passed:
- Recovery v3: https://github.com/stockmansridge/rork-vinetrack-june26/actions/runs/41553992721 — exact head SHA af4028; source/toolchain and simulator selection succeeded; native build/tests in progress.
- Issue 43 retained queue: https://github.com/stockmansridge/rork-vinetrack-june26/actions/runs/41553992704 — exact head SHA af4028; source/toolchain and simulator selection succeeded; native build/tests in progress.
Both workflows pin Xcode 26.3 and disable parallel testing. Recovery v3 selects only four helper/journal methods, not the new complete integration suites; the managed selection above provides additional bounded coverage. No new workflow dispatch or unchanged test retry was performed.

## App Store Connect readback
App ID `6761143377`, bundle `app.rork.nt0v48tayl7v8noxcfe74`, version 3.1.9. Setup succeeded. Latest returned build is **208**, VALID, ID `a59ade0d-a705-4ca9-a708-5920626d5887`, uploaded 2026-11-02T15:52:13-08:00. The existing Rork submission is `0f2718d9-a4c9-42ad-b48a-ad99a97c8c09` (build 208, complete). That is an earlier receipt, NOT a new delivery from af4028. The 202-vs-208 historical delivery uncertainty is now resolved: 208 exists in ASC. The next candidate must be at least 209, with all existing build numbers rechecked before allocation.

## Release decision: HOLD, no exception granted
1. Exact-SHA GitHub native CI is not terminal yet. Its historic malloc failure cannot be declared resolved merely from a managed-tool run.
2. The independent baseline diagnostics assertion is documented, not fixed or waived as a pass. No all-green native selection is claimed.
3. The documented managed publisher combines signed archive creation and upload in `submitBuild`. Its schema has no exact GitHub source checkout, build-setting injection, archive-only stage, or pre-upload signed-archive inspection. `buildId` is a preflight label, not proof of embedded source identity. The pinned app reads `VineTrackSourceRevision`, but project build settings do not define it. Only the Debug simulator GitHub workflow injects it; that does not establish a signed Release archive's embedded SHA.

Therefore the required signed archive identity check cannot currently be completed BEFORE upload through the available publishing flow. No source label was hardcoded to manufacture proof, no signing/capability mutation was started, and no combined build/upload was invoked. New build number, archive SHA/embedded revision, ASC upload receipt and internal group distribution are all **not available** for this request.

## Remaining action
Obtain terminal results/artifacts for both exact-SHA GitHub workflows; investigate any failure. Resolve the two obsolete assertions in a separately identified source revision if green tests are required, or explicitly review the baseline exception without relabeling it. Use an authorised archive-only signing path that pins af4028, passes the verified SHA as a build-time value, and exposes the signed artifact for embedded Info.plist verification before upload. Then allocate a number above all ASC builds and deliver to internal testing only.

This pass did not perform original-device completion, historical queue reconciliation on retained customer data, linked backend/Portal acceptance, process-death recovery or physical scrolling profiling. Those are the purpose of the candidate, not established acceptance results.
