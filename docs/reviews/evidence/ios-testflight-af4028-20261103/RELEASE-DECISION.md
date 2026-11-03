# iOS internal TestFlight — af4028 — build 209 uploaded

Requested GitHub source: `af4028a9b12630fbf515133cb7930d34880bec38`. No outdated PR #50 source imported. No Android, Supabase, production-record or retained-device-data mutation.

## Latest authorisation and delivery — 3 November 2026
The user explicitly authorised the existing Rork compile/sign/upload process for internal TestFlight, superseding the earlier pre-upload archive-inspection gate. No application-code changes were made. The historical HOLD findings below remain historical evidence, not the current delivery status.

- Rechecked the original GitHub tar archive (SHA-256 `2bfde319e2ce88a4c5511bff0ed5d3bd023c86a02df564a05dc133fe539fc02e`), not merely its previously extracted directory: **all 1,298 non-generated iOS files match byte-for-byte**, no missing files and no extra tracked iOS files. Rechecked again after upload: zero mismatches. Exact paths/hashes are in `publish-source-files.sha256`, manifest SHA-256 `4034503c2cbaf75b3fbfbe72414e4193ae65708e4e6304f6fe8f5a657fdd4527`.
- Explicit limitation: the archive also contains `ios/VineTrack/Config.swift`; the ignored Rork-managed workspace copy differs. It was preserved, not replaced or disclosed. Publishing supplies managed environment configuration. Thus full-tree equality including generated configuration, remote generated-config bytes and signed-binary/source equivalence are not independently established. Managed HEAD before publishing was `50367f858a40ee385100e123fba2d5281522a45d`; it is not the requested GitHub SHA. The byte comparison establishes the non-generated iOS source identity; the publisher uses a captured workspace snapshot, not an explicitly selected GitHub checkout.
- Fresh ASC readback before allocation showed highest iOS build **208**, version **3.1.9**, VALID. Requested **209** explicitly through `submitBuild`; no project version setting was edited.
- Apple session valid. `ensureCertificate`: `ok`, distribution certificate ready. `ensureApp`: existing app `6761143377`, not created. `syncCapabilities`: `ok`, enabled/disabled/extension lists empty, `capabilitiesChanged: false`.
- `submitBuild` returned **status ok**, build **209**, message: “App Store build succeeded! Build 209 has been uploaded to App Store Connect and is now processing. The app will be available on TestFlight shortly.” Upload receipt/submission **`a0c0cd14-93d5-4981-90ff-4a33f2a9a7b2`**.
- Persisted receipt readback: iOS Swift app path `ios`, version **3.1.9**, bundle **`app.rork.nt0v48tayl7v8noxcfe74`**, team **`8Y879855VK`**, build **209**, builder **limrun**, source mode **supplied-snapshot**, toolchain identity **Xcode 27.1**, `currentBuildStep: complete`, no error message/details. Created **2026-11-03T01:15:33.792Z**, build-step completion **2026-11-03T01:20:49.030Z**. This is managed build/sign/upload evidence, not an independently inspected signature/provisioning/archive/IPA checksum receipt.
- Immediate ASC build-209 query returned no indexed build yet. Persisted receipt has `buildProcessingState: null`; Apple VALID status, internal-group availability and installed-device acceptance are **not yet confirmed**. No duplicate upload was attempted. Rork handles the TestFlight invite automatically; no external group, beta-review or App Store review/public-release submission was requested.
- GitHub runs remain **FAILURE** with unresolved malloc aborts. Earlier managed selection remains **188 passed / 1 failed**; no new passing test claim. No physical iPhone/Portal acceptance was performed here.

### Existing-installation next step
When **3.1.9 (209)** becomes available in the existing internal TestFlight account, update in place. Do not delete/uninstall VineTrack, clear storage, reset queues or discard retained Trips. Preserve the existing protected diagnostic export before exercising recovery. The purpose of this candidate is real-iPhone Trip Sync validation; successful compilation/signing/upload is not proof of that runtime behaviour.

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
Both runs are now terminal **FAILURE**, with exact head SHA `af4028a9b12630fbf515133cb7930d34880bec38`. Compilation progressed through linking and into native test execution; these are runtime malloc aborts, not the obsolete diagnostics assertion or compiler failures.
- Recovery v3: https://github.com/stockmansridge/rork-vinetrack-june26/actions/runs/41553992721 — job 125648259850 completed 2026-11-03T01:00:11Z. Native build/test step failed. Two malloc aborts; two named XCTest cases passed after runner restarts. The final two-test passing summary does not make the run pass.
- Issue 43 retained queue: https://github.com/stockmansridge/rork-vinetrack-june26/actions/runs/41553992704 — job 125648259093 completed 2026-11-03T00:59:01Z. Native build/test step failed. Nine malloc aborts across eight distinct cases. The log has 63 XCTest pass events for 61 distinct XCTest cases (restart repeats are not new coverage), plus a separate Swift Testing summary of 19 tests passed. Neither the final zero-XCTest summary nor the separate 19-test pass overrides the failed run.

Both logs end `** TEST FAILED **`. Each abort reports `pointer being freed was not allocated`. The historical `TripQueuedUploadScopeTests/testScopeClassificationDoesNotMutatePersistedQueue` crash recurs in Issue 43 at line 17013. The crash signature therefore remains reproduced on the exact requested source with Xcode 26.3. Its underlying cause is not established; it is not safely attributable to infrastructure alone, nor proven a production Release crash.

### Checksum-verified evidence
Direct GitHub run-log download returned HTTP 403. Public receipt-artifact downloads succeeded, and both ZIP SHA-256 values exactly match GitHub's artifact digests. ZIPs, full logs and bundled xcresults remain outside the repository under `/tmp`; no credentials/configuration were copied into this report. Artifacts expire 17 November 2026 according to GitHub metadata.
- Recovery artifact 13194502620, `ios-trip-sync-recovery-v3-native-receipts`, 71,006,755 bytes; ZIP SHA-256 `46fef23421f5a8233380c34df01b69ccb64c47c99513762bbdf9c74a4aedf71c`. Extracted `ios-trip-recovery-v3.log` SHA-256 `154c47d5d051083ee4d247ef4f4ee050de4b6e73bccb9965f332e4b672c60a19`.
- Issue 43 artifact 13193838779, `issue43-main-ios-trip-queue-native-receipts`, 71,564,664 bytes; ZIP SHA-256 `cf72ac70965b3118e9d755c560cd69b15d2f34e881582b4e8fb5b814c8f19235`. Extracted `issue43-main-trip-queue.log` SHA-256 `198e6596d9291e6e482957e94f239b286f945f34a9d9e7cadc298ddba4aa98e0`.

Crash-associated currently running cases (association from the preceding started-case line, not a symbolicated root-cause attribution):
- Recovery log 16754: `TripOccurrenceJournalTests/testBackendUpgradeRefusesChangedLocalCoverageAndKeepsHold`.
- Recovery log 16770: `TripOccurrenceJournalTests/testBackendUpgradeRetriesUppercaseOriginalHeldCreateWithoutChangingFrozenIDs`.
- Issue 43 log 16765 and 16790: `SprayOccurrenceRecoveryHotfixTests/testOverlappingUnconfirmedStartRequiresDistinctWorkConsentWithoutDiscardingOriginal`.
- Issue 43 log 16828: `TrackedSprayCompletionSyncTests/testFailedPrepareDoesNotPublishQueuedSuccess`.
- Issue 43 log 16844: `TrackedSprayCompletionSyncTests/testFirstEndAndIdentitySurviveReloadAndLaterRetry`.
- Issue 43 log 16864: `TrackedSprayCompletionSyncTests/testMissingAmbiguousManualTemplateAndWrongVineyardAreHeld`.
- Issue 43 log 16880: `TrackedSprayCompletionSyncTests/testNonSprayAndHistoricalEndDoNotCreateCompletionIntent`.
- Issue 43 log 16910: `TrackedSprayCompletionSyncTests/testUnreadableOutboxNeverBecomesEmptyAndOriginalBytesRemain`.
- Issue 43 log 17013: `TripQueuedUploadScopeTests/testScopeClassificationDoesNotMutatePersistedQueue`.
- Issue 43 log 17033: `TripQueuedUploadScopeTests/testVerifiedCompletedTripReceiptRequiresDurableQueueAcknowledgement`.
Both workflows pin Xcode 26.3 and disable parallel testing. Recovery v3 selects only four helper/journal methods, not the new complete integration suites; the managed selection above provides additional bounded coverage. No new workflow dispatch or unchanged test retry was performed.

## App Store Connect readback
App ID `6761143377`, bundle `app.rork.nt0v48tayl7v8noxcfe74`, version 3.1.9. Setup succeeded. Latest returned build is **208**, VALID, ID `a59ade0d-a705-4ca9-a708-5920626d5887`, uploaded 2026-11-02T15:52:13-08:00. The existing Rork submission is `0f2718d9-a4c9-42ad-b48a-ad99a97c8c09` (build 208, complete). That is an earlier receipt, NOT a new delivery from af4028. The 202-vs-208 historical delivery uncertainty is now resolved: 208 exists in ASC. Fresh paginated iOS build readback on 3 November still returns 208 as the highest existing build number. The next candidate is at least 209, subject to another read immediately before allocation; no number has been allocated.

## Historical release decision before latest authorisation: HOLD
1. Both exact-SHA GitHub native workflows failed with runtime malloc aborts. The historical failing case recurs; managed-tool results do not resolve or override those failures.
2. The independent baseline diagnostics assertion is documented, not fixed or waived as a pass. No all-green native selection is claimed.
3. The documented managed publisher combines signed archive creation and upload in `submitBuild`. Its schema has no exact GitHub source checkout, build-setting injection, archive-only stage, or pre-upload signed-archive inspection. `buildId` is a preflight label, not proof of embedded source identity. The pinned app reads `VineTrackSourceRevision`, but project build settings do not define it. Only the Debug simulator GitHub workflow injects it; that does not establish a signed Release archive's embedded SHA.

Additional read-only capability discovery confirmed the sandbox host is Linux and has no `xcodebuild`. Installed `asc xcode archive` and `asc xcode export --ipa-path` support a distinct local archive/export flow and raw build-time setting flags, but the CLI explicitly requires macOS/Xcode. No authorised remote macOS execution target with the existing signing identities/profiles is available here. `rork-agent publish --help` exposes only a combined publishing payload; `publish-limrun --help` exposes private request/result files and a source directory, with no documented archive-only/no-upload mode, build-setting interface or signed-artifact retrieval contract. No private payload schema or undocumented no-upload flag was invented, and neither publishing command was invoked.

The precise missing capability is an authorised macOS/Xcode archive-and-export execution surface using the existing signing arrangements, accepting the exact source/build-time SHA and returning the signed `.xcarchive` plus exported IPA for inspection and checksums **without uploading**. Apple API authentication is working; it is not this blocker.

Therefore the required signed archive identity check cannot currently be completed BEFORE upload through the available publishing flow. No source label was hardcoded to manufacture proof, no signing/capability mutation was started, and no combined build/upload was invoked. New build number, archive SHA/embedded revision, ASC upload receipt and internal group distribution are all **not available** for this request.

## Historical remaining action before latest authorisation
Terminal workflow results and checksum-verified receipt logs have been obtained. Diagnose the reproduced malloc aborts using symbolicated crash/xcresult evidence on an authorised Xcode host; do not speculate, silently waive them, or change Trip Sync code to bypass the gate. Any source correction would require separate authorisation and a new explicitly identified revision. The independent obsolete diagnostics assertions remain a separate recorded failure, not an explanation for these crashes. Use an authorised archive-only signing path that pins af4028, passes the verified SHA as a build-time value, and exposes the signed artifact for embedded Info.plist verification before upload. Then allocate a number above all ASC builds and deliver to internal testing only.

This pass did not perform original-device completion, historical queue reconciliation on retained customer data, linked backend/Portal acceptance, process-death recovery or physical scrolling profiling. Those are the purpose of the candidate, not established acceptance results.
