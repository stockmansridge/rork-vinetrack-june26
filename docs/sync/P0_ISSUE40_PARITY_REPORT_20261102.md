# VineTrack 3.1.9 P0 — Issue #40 iOS/Android parity report (2 November 2026)

Verdict: **NOT ACCEPTED — release blocked.** Source parity is implemented and checked by automated tests and builds only. No original-device, live-server or authenticated Portal acceptance has been executed. Parity is not claimed from compilation or simulator results.

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
- Issue #41 supersedes the next-build step: no new Internal/TestFlight store candidate until investigation/correction/test/source identity are reported and further delivery is authorised. Normal validation builds are not store delivery.

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

**OPEN / NOT RECOVERED / NO STORE CANDIDATE.** Read-only issue evidence confirms Trip `b1dd59ab-ff1b-4ff4-9af6-a9688425db22`, retained Tank session `fdb6a4b8-5cbf-41a9-a780-816a5e5fa401`, actual `c4b5f982-e3e9-467d-9067-e36736699026` and finalisation `fff1638c-ac5f-4546-bc1f-c74026b03c2f`. Creation/activation/Spray Record had been accepted; the reported server remained Active with no sessions/actuals or finalisation receipt. This is incident evidence, not a fresh live read performed here.

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
- Working source is fingerprinted in `validation-current.json.issue41`. Managed base **`ad33558da35fc9681d377f2a2912bd740c884c1c`** is the preceding #40 commit, **not** the repaired commit. Automatic managed sync has not yet supplied a repaired commit identity in this turn; verify it against these hashes before any store candidate. No manual staging/commit/push, package/signing/version/configuration change, backend mutation or store publication performed.
