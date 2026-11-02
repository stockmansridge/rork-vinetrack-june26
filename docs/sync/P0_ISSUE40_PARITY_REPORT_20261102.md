# VineTrack 3.1.9 P0 — Issue #40 iOS/Android parity report (2 November 2026)

Verdict: **NOT ACCEPTED — production release blocked.** Latest user authorises controlled Play Internal Testing and TestFlight recovery candidates only. Source parity is implemented and checked by automated tests and builds only. No original-device, live-server or authenticated Portal acceptance has been executed. Parity is not claimed from compilation or simulator results.

## Controlled delivery update — 2 November 2026

- Verified recovery managed revision `4e177a9109f3f729d16c11a527cf64e3fe443611` against public GitHub `64516a77082f3eb4b3917c7cf10170dbf3c31b19`. All 16 recorded application/test SHA-256 values match both; all tracked app blobs match public source. All four retained passing Android XML hashes match and total 53 tests, zero failures/errors/skips.
- Added `issue41-rc1` diagnostic-only overlay: verified recovery revision in Android Copy Trip status and Phase 5 traces; same revision plus installed version/build in iOS Copy Trip status. This identifies the verified recovery source, not a self-referential claim about the overlay's future commit. Overlay hashes and full tracked-app manifest digests are retained in `validation-current.json.issue41.controlledDelivery`.
- After overlay: Android normal build PASS; iOS simulator build PASS. Prior 53 JVM / 23 aggregate iOS test evidence is reused within its original limits; no new device/network test or final-binary equivalence claimed.
- **iOS 3.1.9 build 201 signed and uploaded**, submission `96c48871-12f0-4c7e-a3e0-d71fa1d5b87e`, existing team/bundle route, supplied source snapshot, Xcode 27.1. Managed environment identity unchanged (`77512c8744941d43de74978b0c1291c3bb06d8da`). Apple processing and TestFlight availability remain unconfirmed: immediate ASC read still returned build 200. Build 201's What to Test metadata cannot yet be attached; no new App Store review submitted. No source snapshot ID/archive checksum exposed by the tool; source is verified recovery revision plus the exact fingerprinted diagnostic overlay, not yet a new committed SHA.
- **Android signed export not created**: package access succeeds and all listed existing bundles are stale. `generatePlayAab` refused: “The current project has unsynced source changes. Finish this turn, then retry publishing.” No version code/run/submission allocated, no validation or publication, no older artifact substituted. Resume after automatic sync, code above 1793582624 and later uploads, validate and publish Internal only. Existing package/signing/configuration were not changed.
- **Issue #40 remains outstanding on iOS:** original-device cancellation receipt/readback, lost-response and 3.1.8 refusal acceptance; full dependent/closure lifecycle and interruption/reopen acceptance; per-entry reconciliation of four historical Trip operations and one orphan actual; independent labour proof; named owner-level occurrence UUID correction. Build 201 does not claim these gaps resolved.

### Protected original-Android recovery checklist — not executed here

1. Update the original installation in place only after the new signed Internal candidate is confirmed. No uninstall, storage clearing, cancellation, queue-count clearing or replacement records.
2. Copy Trip status before replay for Trip `b1dd59ab-ff1b-4ff4-9af6-a9688425db22`; preserve exact local start/end, GPS, entered water and chemicals, and operation evidence. Confirm candidate version/code and `verified_recovery_source`/overlay labels.
3. Online on the original account/vineyard, observe Phase 5 admission and parent waits. Unrelated identified legacy jobs may remain held on their original Pending Sync entries. Same/unknown evidence must remain held; stop on a conflict rather than relax guards.
4. Verify server Tank session `fdb6a4b8-5cbf-41a9-a780-816a5e5fa401` matches the complete retained session; verify actual `c4b5f982-e3e9-467d-9067-e36736699026` with exact entered water/chemical values and identities. Do not substitute planned values. Require independent server readback, not zero queue count or HTTP success alone.
5. Verify GPS/labour evidence through authorised receipts/readback. Labour's current void RPC is not independent proof; unresolved proof keeps acceptance blocked. Replay original finalisation `fff1638c-ac5f-4546-bc1f-c74026b03c2f`, never a replacement. Require original-operation receipt, terminal Trip row and claim release.
6. Close/reopen and independently read server state; require exact linked records, no duplicates/missing quantities, all dependents acknowledged, verified CLOSED_SYNCED. If any stage fails, retain every original byte/operation and return candidate identity, original operation ID, stage and fixed code. Repeat complete lifecycle acceptance on iOS before any production decision.

## Supabase dependencies
- `sql/281_trip_activity_cancellation_v1.sql` deployed after a rolled-back 16/16 dry run.
  - `cancel_trip_activity_v1` md5 `f14c6be3c8053ce31d35fffa0894de6c`, SECURITY DEFINER, owner postgres, ACL authenticated + service_role.
  - `guard_cancelled_trip_v1` md5 `0a4b2f8663682ef33cc89bf342e3a225`; tombstone and immutability triggers enabled.
  - Receipt/archive tables held 0 rows at verification; incident Trip `3bfb7f81-…` unchanged (ACTIVE, `end_time` NULL, `tank_sessions=[]`, 0 actuals).
- Phase B/C need no backend change (they read existing `trips` and `spray_tank_actuals`).
- Outstanding: occurrence-setup UUID fix needs a named owner-level operator (live md5 `b0e166d78be75c8ba770b2dccfd14256`).

## Phase A — Cancel Trip (same RPC, contract and codes)
- Android: complete in source. JVM `TripActivityCancellationTest` 17/17 (XML sha256 `2ca249a0…`).
- iOS: complete in source. `swiftTest TripActivityCancellationTests` 19 passed (simulator).
- Shared behaviour: original device only (durable End claim), LOCAL_END_PENDING only, Owner/Manager/Supervisor, Applied / Not applied / Not sure (held), extra confirmation with actuals, evidence and quantities preserved, durable intent with original operation ID, receipt verification and readback/replay recovery, scoped cleanup only after ACKED is saved, claim release, tombstone refuses 3.1.8.

## Phase B — Tank dependency verification
- Android: `TankDependencyVerification.kt`, `TripTankSync`, `ScopedTankActualSync`. JVM `TankDependencyPhaseBTest` 10/10 (re-run 2 Nov, still 10/10) plus regression suites.
- iOS: `TankDependencyVerification.swift`, `TripSyncService`, `SprayTankActualStore`. `swiftTest TankDependencyVerificationTests` 7/7 (re-run with Phase C: 18 combined passes).
- Shared codes: `TRIP_TANK_REQUIRED_SESSION_MISSING`, `TRIP_TANK_REQUIRED_SESSIONS_UNREADABLE` (Android marker path), `TRIP_TANK_PATCH_READBACK_MISMATCH`, `TANK_ACTUAL_SESSION_NOT_ON_SERVER`, `TANK_ACTUAL_READBACK_MISMATCH`.
- Gap: iOS `SprayTankActualStore.syncPending` checks are not unit-testable (returns early without Supabase).

## Phase C — CLOSED_SYNCED
- Same derivation on both platforms (`TripClosureStatus`): states ACTIVE, LOCAL_END_PENDING, SERVER_STATE_UNCONFIRMED, ENDED_DEPENDENTS_PENDING, ENDED_DEPENDENTS_HELD, CLOSED_SYNCED.
- CLOSED_SYNCED requires: End acknowledged (not local-only), server row terminal, no unresolved Trip/tank/GPS/spray-record markers, no pending occurrence operations or holds, no pending tank actuals, and every actual's tank session present on the server row.
- "Verified with server" is shown only after a fresh server read (Check with server). Without it, evidence is labelled `acknowledged_local_row`.
- Trip list/header "Synced" badge no longer shows while tank actuals are unacknowledged (both platforms).
- Android: JVM `TripClosureStatusPhaseCTest` 11/11 (XML sha256 `22337dad0b1a45c59d4727eba21cff8dd342af9d10c438f9b0222fd3030afb5c`). Shown in Trip detail and Copy Trip status.
- iOS: `swiftTest TripClosureStatusTests` 11/11 (with Phase B, 18 passed in 158s). Shown as Trip detail "Sync status" section with Copy Trip status.
- Known difference: iOS cannot see the private per-record "held" flag on Trip/spray queues, so a held queue entry reports ENDED_DEPENDENTS_PENDING rather than HELD. It is still never CLOSED_SYNCED.

## Builds
- Android `runChecks` PASS; iOS `runChecks` PASS (simulator build only; device/Release unverified).
- Latest controlled-delivery authorisation supersedes the prior investigation-only gate: Internal/TestFlight only; see current delivery update. Normal validation builds are not store delivery.

## Original-device tests — NOT EXECUTED
- Android update from the user: build `1793582624` cancelled `3bfb7f81-…` and permitted the new Trip to start. This is reported handset success, not our independent receipt/readback verification. 3.1.8 refusal remains unverified.
- iOS: in-place upgrade from build 200; per-entry reconciliation of 4 historical Trip ops and 1 orphan Tank actual (never send `2be68a70-…` to the RPC, never clear evidence).
- Both: fresh controlled Spray Trip from plan → Start → Tank Actuals → End → Sync → verified CLOSED_SYNCED.

## Blockers
- No original handsets, authenticated Portal session or live account in this environment.
- iOS stuck-queue per-entry diagnostics: not yet implemented.
- `androidTest` infrastructure timed out twice; Robolectric unavailable.
- Backend UUID fix awaits a named owner-level operator.

## Issue #41 investigation and bounded correction

**OPEN / NOT RECOVERED.** Controlled recovery delivery now authorised; see current update (iOS 201 uploaded, Android awaiting automatic source sync). Read-only issue evidence confirms Trip `b1dd59ab-ff1b-4ff4-9af6-a9688425db22`, retained Tank session `fdb6a4b8-5cbf-41a9-a780-816a5e5fa401`, actual `c4b5f982-e3e9-467d-9067-e36736699026` and finalisation `fff1638c-ac5f-4546-bc1f-c74026b03c2f`. Creation/activation/Spray Record had been accepted; the reported server remained Active with no sessions/actuals or finalisation receipt. This is incident evidence, not a fresh live read performed here.

### Confirmed source cause

`AppViewModel.replayPhase5Writes` called `LegacySpraySaveStore.pending(vineyard)` before modern replay. `pending` strictly decoded and validated **all** retained entries before vineyard filtering. Any incompatible entry therefore threw, published a global `sprayError`, and returned from the whole replay stage. Labour, tank, actual and End dispatch were never reached. A second retained-ID whole-pass return could also veto unrelated modern operations. Vineyard hydration published the same unrelated legacy warning into the current review. The exact handset payload/failed decode field is unavailable; the source control-flow defect is confirmed, not the byte-level corruption reason.

### Changes in checked source

- Android identity-only `LegacyReplayIsolation` indexes retained original bytes without rewriting them. Fully identified unrelated jobs no longer veto modern replay; matching Trip/Spray/nested UUID references, duplicate identities and unresolved identity evidence remain held. Strict original legacy writers/recovery are unchanged; this index grants no receipt or permission to send the old job.
- Frozen versions exclude conflicting Trip/Spray writes, and every production outbox claim rechecks current retained evidence. Direct Spray creation, labour, actual and occurrence replay also apply scoped guards. Account/vineyard/permission, actual-entry and tank-conflict guards remain.
- Pending Sync shows retained original-job identities and fixed hold reasons. Background legacy recovery no longer publishes its warning/busy state into the current Spray Review; explicit user recovery keeps its own errors.
- Phase 5 records in-process entry/legacy/start/labour/tank/actual/End/occurrence stages, admission holds and parent waits. These are not upload counters or acknowledgement evidence. After dependents it awaits the same original occurrence journal again, then labour replay; it never creates a replacement finalisation.
- Android tank verification now compares complete retained session projections, not only IDs, and production performs a separate GET after PATCH before removing the marker. Existing actual amount/chemical readback gates remain intact.
- iOS parity: read-only retained-byte index understands base64 Trip/Record bodies. Failed whole-journal preflight no longer aborts unrelated dirty-record admission. Same/unknown evidence is held, and an unreadable journal produces **no** accepted identity or dirty-marker acknowledgement. Strict original recovery/mutation remains unchanged. This is containment parity, not proof of the original iOS queue recovery or full lifecycle parity.

### Executed checks

- Android initial selection: **53 executed, 1 failed**. The new malformed-modern-payload case exposed that JSON primitive input could pass the identity scanner. Corrected admission to require an object; original failing XML retained under `docs/reviews/evidence/p0-trip-start/issue41/first-android/`.
- Android corrected selection: **53 passed, 0 failed/errors/skipped**: `LegacyReplayIsolationTest` 13, `TankDependencyPhaseBTest` 10, `TripClosureStatusPhaseCTest` 11, `ReplayVersionIntegrityTest` 19. Passing XML retained separately under `issue41/passing-android/`.
- New cases cover attributed incompatible legacy evidence, malformed/unidentified content, same and nested identities, duplicate identities, foreign owner containment, original-byte fingerprints, re-admission after evidence changes and real Tank replay using an incident-shaped retained session plus independent fake readback. These use isolated data, not the handset's private quantities or live server.
- iOS selection `LegacyReplayIsolationTests`, `TankDependencyVerificationTests`, `TripClosureStatusTests`: **23 aggregate passes in 143s**. New coverage includes unchanged original bytes, held identity versus independent admission, no accepted-marker clearing, unknown protection and no directory/decode-hook side effect from raw inspection. The runner returns aggregate results, not named per-case receipts.
- Separate normal checks: Android build **PASS**; iOS simulator build **PASS**, device/Release unverified. No device/UI workflow executed; previous instrumentation timeouts have not been retried.

### Remaining recovery and acknowledgement gaps

- No original Android installation, authenticated account or Portal session is available. The exact Trip/session/actual/finalisation have **not** been replayed or acknowledged here. Never recreate them, substitute planned quantities, clear storage, drain by count or cancel the new Trip to hide this failure.
- Labour still uses existing `capture_trip_labour_start_v1` / `finalise_trip_labour_v1` RPC success. SQL 253 returns `void`; operational operators intentionally cannot SELECT financial allocations. Independent labour readback/receipt proof is **not implemented or verified** by this correction. Do not claim end-to-end verified CLOSED_SYNCED from these checks. A scoped, authorised verification contract or operator evidence is still required.
- The complete ViewModel/real-network ordered lifecycle, interrupted/lost-response/reopen matrix and exact server quantities/terminal row/original finalisation receipt remain unexecuted. iOS build 200's four historical Trip operations and orphan actual still require separate per-entry reconciliation.
- Recovery source is fingerprinted in `validation-current.json.issue41`. Managed base `ad33558da35fc9681d377f2a2912bd740c884c1c` is not the repair; repaired managed/public revisions and diagnostic-only overlay are verified and recorded above. No manual staging/commit/push, package/signing/configuration change, backend mutation, App Store review or production publication performed. iOS build 201 is a controlled recovery upload, not original-device acceptance.
