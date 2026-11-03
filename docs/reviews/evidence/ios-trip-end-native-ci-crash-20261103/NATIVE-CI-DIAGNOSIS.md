# Native Trip End replay CI: red run diagnosed (3 Nov 2026)

Scope: iOS only. Android untouched. No production data read or written. This note is evidence for the
Trip End recovery incident (Trip `492ebafc-b996-4ec4-8ea9-4261a3056810`, vineyard JH Testing
`59973ced-1fb9-42ec-a66d-9eaad3172824`). **The incident stays OPEN.** Nothing here proves the Trip is repaired.

## 1. The run

- Workflow `ios-trip-end-replay-native`, run `41728287675`, job `126238701494`.
- GitHub commit `915985124d3ae540013c9d3d6626fb0eac73ea85`.
- Runner `macos-15`, Xcode 26.3 (17C529), iPhone 16 Pro simulator, iOS 18.5. `xcodebuild` exit 65.
- Sibling workflow `Occurrence SQL contracts` (run `41728287686`) on the same commit: **success**.

## 2. Result: no assertion failed; one suite lost 29 of its 37 cases to a process abort

Produced with `python3 scripts/native-ci-case-summary.py <log> --expect-suites 7 --expect-cases 136`:

| Suite (VineTrackTests) | started | passed | failed | crashed |
|---|---|---|---|---|
| TankDependencyVerificationTests | 12 | 12 | 0 | 0 |
| TripClosureStatusTests | 11 | 11 | 0 | 0 |
| TripEndServerReplayTests | 23 | 23 | 0 | 0 |
| **TripOccurrenceJournalTests** | 37 | 8 | 0 | **29** |
| TripQueuedUploadScopeTests | 15 | 15 | 0 | 0 |
| TripSyncDeterministicFailureTests | 8 | 8 | 0 | 0 |
| TripSyncStageFailureTests | 30 | 30 | 0 | 0 |
| **Total** | 136 | 107 | **0** | **29** |

- "Crashed" means the case logged `started` and never logged `passed` or `failed`: the test process died and
  `xcodebuild` restarted it. The log has 32 restart lines and 32 `pointer being freed was not allocated` lines.
- Every one of the 136 cases was started, so no other suite was silently skipped.
- The run is **not** a pass and is not described as one. It is also not a logic failure: zero failed assertions.

## 3. The crash

- 48 `.ips` reports across 25 distinct processes, all SIGABRT:
  `malloc: *** error for object 0x...: pointer being freed was not allocated`.
- Every symbolicated stack ends the same way:

  ```
  swift::TaskLocal::StopLookupScope::~StopLookupScope()
  swift_task_deinitOnExecutorImpl
  swift_task_deinitOnExecutorMainActorBackDeploy
  TripOccurrenceJournal.__deallocating_deinit
  ```

- `TripOccurrenceJournal` is a `@MainActor final class` with no explicit `deinit`, in a target built with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The compiler therefore synthesises an **isolated deinit**, and the
  stack shows the isolated-deinit hop running on release.
- Which cases die is itself evidence (read from `ios/VineTrackTests/TripOccurrenceJournalTests.swift` and the log):
  all 37 cases are `@MainActor`. The 29 that aborted are all **synchronous** and all create and release a journal.
  The only two journal-creating cases that passed are the two **async** ones
  (`testBackendUpgradeRefusesChangedLocalCoverageAndKeepsHold`,
  `testBackendUpgradeRetriesUppercaseOriginalHeldCreateWithoutChangingFrozenIDs`). The other six passing cases never
  create a journal. This matches swiftlang/swift#85663, whose workarounds are an async test or a nonisolated deinit.
  It is an observation about 37 cases, not a proof of the exact release condition.

## 4. Upstream confirmation (fetched, not recalled)

- swiftlang/swift#88036, "Crash in swift_task_deinitOnExecutorImpl / TaskLocal::StopLookupScope / malloc on iOS 26.2
  and older when deinitializing a default-MainActor class with task-local storage". Reproduced with Xcode 26.3 and
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Verified workaround: an explicit empty `deinit {}`. Runtime fix
  ships in the iOS 26.4 runtime (PR #87967, "Fix the stack nesting of task-local values").
- swiftlang/swift#85663, "isolated deinit unexpectedly crashing in unit test" (iOS 18.6 and 26.0 simulators).
  Workarounds listed: an async test or an explicit nonisolated deinit.
- SE-0371: an explicit `deinit` is nonisolated unless it is marked isolated, so `deinit {}` removes the hop.

## 5. The same abort has been seen before in this repository

- `docs/reviews/evidence/ios-tracked-spray-completion-20261102/pinned-baseline-runtime-crash.log`, lines 16713 and
  16731 (pinned baseline, the same malloc message).
- `docs/reviews/evidence/ios-testflight-af4028-20261103/RELEASE-DECISION.md`: "Its underlying cause is not
  established". That record is historical and is left as written. This note supplies a cause that matches the
  symbolicated stack and an upstream bug report. It does not rewrite that decision.

## 6. Production exposure (not a claim that production crashed)

- `TripOccurrenceJournal(` is created in 12 production places: `TripSyncService` (7), `SupabaseTripSyncRepository`
  (2), `TripTrackingService` (2), `LegacySpraySaveRecovery` (1). In `TripTrackingService`, line 708 sits inside a
  `Task { @MainActor in }` and line 2565 is the synchronous helper `occurrenceJournal(for:)`, whose callers release
  the journal when they return. That is the same synchronous release pattern that aborted in CI.
- Whether any production device has aborted this way is **not established**: no crash report from the original iPhone
  has been seen. The defect needs an iOS 26.3 or older runtime. Build 215 was compiled by the managed builder
  (Xcode 27.1, per the build 215 receipt), but the defect is in the device runtime, not the compiler.
- This crash is not shown to be the cause of the incident: build 214 reached the network and was rejected with
  HTTP 400 (bare `+` in the CAS filter, fixed in 215 with `%2B`, never exercised). The server defect found and
  reproduced locally is the tank-link UUID case comparison (`OCCURRENCE_TANK_LINK_CONFLICT`, HTTP 500, SQLSTATE
  40001). It has not been observed on production, because no tank request has ever reached the server.

## 7. Correction

`ios/VineTrack/Backend/Sync/TripOccurrenceJournal.swift`: an explicit empty `deinit {}` with a comment. The class has
no stored state that needs releasing by hand, so behaviour is unchanged. Nothing else changed in app code for this
item. Two stale tests (`TripDeletionRecoveryTests`, `TripStabilisationTests`) were updated in the same working tree.

## 8. What is and is not validated

Validated (static or build only):

- Managed `swiftTest` on the same 7 suites: 136 passed, 0 failed.
- `runChecks` (iOS simulator build) passed.
- Python contracts: tank-link case contract (13 tests), authority suite (56), PR52, real-HTTP contract
  (PostgREST 16.5, PostgreSQL 17).

**Not validated:** the managed simulator did not abort on these cases before the change either (the earlier managed
selection that included `TripOccurrenceJournalTests` passed 188 of 189, see the af4028 `RELEASE-DECISION.md`), so its
136 passes do not show the crash is gone. The only valid proof is the native workflow re-running on Xcode 26.3 with
the iOS 18.5 simulator after this change is pushed. Acceptance bar: `python3 scripts/native-ci-case-summary.py <log> --expect-suites 7
--expect-cases 136` prints `CLEAN` (0 failed, 0 crashed) and the workflow concludes `success`.

## 9. Retrieving the receipts without a GitHub token

```
curl -L -o receipts.zip \
  https://nightly.link/stockmansridge/rork-vinetrack-june26/actions/runs/41728287675/ios-trip-end-replay-native-receipts.zip
sha256sum receipts.zip   # 46c885e671eda8af608df95685cfa3ff0283056bc72334bf765e50a69b5e27d3 (matches GitHub's digest)
```

The 113 MB archive (log, source listing, xcresult, 48 crash reports) is kept outside the repository.

## 10. Next

1. The change is pushed at the end of the turn; the native workflow re-runs on its `paths:` filter.
2. Green (acceptance bar above): internal-only build 216, as authorised "once CI is green".
3. Red: diagnose from the new receipts the same way, per suite, before any further change.
