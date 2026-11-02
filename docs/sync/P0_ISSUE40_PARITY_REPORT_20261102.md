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
- Play Internal candidate and new TestFlight build (>200) not yet produced: both must be built from synced source after this turn.

## Original-device tests — NOT EXECUTED
- Android: cancel `3bfb7f81-…` on the original handset after in-place upgrade; confirm receipt, Start Trip re-enabled, 3.1.8 refused.
- iOS: in-place upgrade from build 200; per-entry reconciliation of 4 historical Trip ops and 1 orphan Tank actual (never send `2be68a70-…` to the RPC, never clear evidence).
- Both: fresh controlled Spray Trip from plan → Start → Tank Actuals → End → Sync → verified CLOSED_SYNCED.

## Blockers
- No original handsets, authenticated Portal session or live account in this environment.
- iOS stuck-queue per-entry diagnostics: not yet implemented.
- `androidTest` infrastructure timed out twice; Robolectric unavailable.
- Backend UUID fix awaits a named owner-level operator.
