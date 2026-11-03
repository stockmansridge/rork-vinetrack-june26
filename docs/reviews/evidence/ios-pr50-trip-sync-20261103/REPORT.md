# iOS PR #50 — build-208 Trip Sync follow-up validation (3 November 2026)

Scope: iOS only. No Android, Supabase, production-record or retained-device-data change. No merge, no TestFlight upload, no manual Git operation.

## Tested source identity
- PR #50 head `39bdc353fe7f7079e9b2df9a43c321d21b00430d` (`fix/ios-p0-trip-sync-build208-reconciliation`), base/main `5c3be39b4dcd7b8687d439c380768241e48858e9`. Draft, open, not merged.
- PR archive SHA-256 `19df913d46dd309347254c72b8e5298ca91bb008cc6c53d498cc0a660c4f0f7f`; base archive SHA-256 `72acffc3fdc0b4adcbf25fa5870ff416698a061a499de4b0b1dcbad1e7827309`.
- Workspace equalled base before the review; the 5 PR files were then copied byte-for-byte (verified with `cmp`). All tracked iOS files then matched PR head except the ignored generated config.
- **Validated source = PR head + two minimal fixes in `TripSyncService.swift` (`fix-over-pr50-head.diff`) + two new test files.** This is NOT the PR head SHA. The fixes have to reach the PR branch by managed sync or the user before any PR re-run.
- `ios-source-fingerprints.sha256`: 1,298 iOS files (ignored `ios/VineTrack/Config.swift` excluded), SHA-256 `bc12712fcb9ec151813b6711d8a4e24396f719e5870d9201ff53339dc8e8086f`.

## Findings and fixes
1. **PR head does not compile (blocking).** `TripSyncService.swift:1841`: `let timeMatches = legacyArchiveSeconds ? archivedSecondMatches : sameTime` crashes the compiler's diagnostic pass ("failed to produce diagnostic for expression"). 0 tests executed. Log: `raw/01-pr50-head-compile-crash.log` (SHA-256 `2c087325…4ae2`). Fix: the same choice made inside an explicit closure. No behaviour change.
2. **Stale anti-resurrection hold (defect).** The occurrence branch sets `TRIP_LOCAL_END_AWAITING_ORIGINAL_FINALISE` but never removes it. After the original finalise receipt is verified, the Trip still shows "Original local record held" until the app restarts. Reproduced by the new integration test before the fix: 18 passed / 1 failed, failing only on `receiptReconciliationHolds[trip] == nil`. Log: `raw/02-hold-defect-reproduction.log` (SHA-256 `b2d8beb0…f1c0`). Fix: once the trip is no longer preserved as ended-pending, remove only that exact hold reason. Other hold reasons are untouched.

## Native results (managed iOS simulator, Swift Testing/XCTest; terminal tool responses)
- Run A (PR head as published): COMPILE FAILURE, 0 tests.
- Run B (compile fix only): 18 passed / 1 failed (expected reproduction above).
- Run C (both fixes, 13 classes): **188 passed / 1 failed**. Log: `raw/03-focused-13-class-after-fix.log` (SHA-256 `013d460b…40c3`). Classes: TripLocalEndAntiResurrectionTests (new), TankSessionTimestampEncodingTests (new), TripQueuedUploadScopeTests, TripOccurrenceJournalTests, TripJournalAbsenceIntegrationTests, TripDeletionRecoveryTests, SprayTripPhase5FinalisationTests, TankDependencyVerificationTests, SpraySaveForLaterTests, ActiveTripRouteRecoveryTests, TripActivityCancellationTests, LegacySprayPairReceiptTests, TrackedSprayCompletionSyncTests.
  - The single failure, `TripDeletionRecoveryTests/pendingUploadInspectionIncludesQueueWithNoRecordedFailureAndPreservesIt`, **pre-exists on main `5c3be39b` and is unrelated to PR #50.** Production already emits `queued_trip_uploads_global_legacy` on base and PR alike; the test file is unchanged from base and still expects `queued_trip_uploads:`. PR #50 does not touch that function. It is left unmodified and recorded as a failure, not a pass.
  - Run counts overlap; do not add them together. No named XML/xcresult is exposed by the managed runner.
- Normal iOS simulator build (`runChecks`): PASS. Device/Release build is not verified.

## Required verifications
1. Compile + focused regressions: PASS after fix 1 (PR head itself FAILS). See Run C.
2. Legacy whole-second vs fractional tank dates: `legacyComparatorBridgesOnlyWholeSecondTruncationOfTheSameInstant` covers this. Truncation is accepted only on the terminal legacy path. The exact path stays strict. The next second, a fractional local value and a rounded-up local value are rejected. Trip end time still requires ≤1 ms (static review).
3. Anti-resurrection: a stale server-active pull restores the exact original End from the retained claim plus the finalise operation. The End survives a cold restart (new store/metadata/service on the same disk) and a second stale pull. Without a matching claim (missing, foreign owner, foreign vineyard) no End is fabricated.
4. Original replay: the journal keeps the same finalise operation (ID and body); history IDs are unchanged and no operation is minted. The Trip is re-queued in `pendingUpserts`, and pull performs no upload or delete. After the server's original receipt, the journal drains, dirty clears and (with fix 2) the hold clears. Spray Record / Actual Use acknowledgement ordering is covered by the existing Phase5/TrackedSprayCompletion/TankDependency classes, not re-proven end-to-end here.
5. Timestamp encoding: fractional ISO strings round-trip under the iso8601, deferredToDate and secondsSince1970 archive strategies. Keys are unchanged and nil dates stay omitted. Whole-second ISO archives, historical numeric caches and server snake_case payloads all still decode.
6. Trips list during sync (code review, NOT profiled): the PR skips unchanged-trip writes and turns off list animation while syncing. Remaining risk: each *changed* trip still runs `TripRepository.saveSlice` → `loadAll()` + full JSON encode + atomic write synchronously on the main actor (O(n) per changed trip). A cold pull of many changed trips can still stall scrolling. No Instruments/device trace was available.
7. Protections: the cancellation, deletion-journal, legacy pair receipt, foreign-scope and route-recovery classes passed in Run C. No retained-data migration was introduced.

## Not established here
- Physical-device, original-handset, process-death, authenticated backend and Portal acceptance.
- The build-208 vs 202 delivery history is not reconciled from this environment.
- The GitHub run `41428788604` malloc crash (Xcode 26.3) remains unresolved. This pass ran on the managed simulator toolchain, so whether the PR head's compile crash also reproduces on Xcode 26.3 is not established.
