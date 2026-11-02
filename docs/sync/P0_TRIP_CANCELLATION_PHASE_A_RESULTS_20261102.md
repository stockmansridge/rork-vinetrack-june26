# P0 Phase A — Cancel Trip recovery: results, 2 November 2026

Verdict: **NOT ACCEPTED.** These are server and build/JVM results only. Nothing has been run on a real phone yet, so public release stays blocked.

## Target
- Trip `3bfb7f81-2ae2-4f33-8fd8-6666b2b45393` in vineyard `59973ced-1fb9-42ec-a66d-9eaad3172824`. The original Android install shows it as LOCAL_END_PENDING.
- Server state for this Trip:
  - ACTIVE, with `end_time` NULL and `tank_sessions=[]`;
  - zero server actuals;
  - no finalise receipt `3a999293-…`.
- Local state: actual `2b07a0ce-…` is retained, pointing at missing session `30259f0a-…`.

## Backend (sql/281, deployed)
- Dry run: `DRYRUN_OK passed=16 failures=none`, fully rolled back. The tests are in `sql/tests/281_trip_activity_cancellation_dryrun.sql`.
- Live read-only verification, recorded in `sql/281_trip_activity_cancellation_v1_verify.sql`:
  - `cancel_trip_activity_v1`:
    - SECURITY DEFINER, owned by postgres, granted to authenticated and service_role;
    - md5 `f14c6be3c8053ce31d35fffa0894de6c`.
  - `guard_cancelled_trip_v1`: md5 `0a4b2f8663682ef33cc89bf342e3a225`.
  - Triggers: 4 tombstone triggers and 2 immutability triggers, all enabled.
  - Receipts 0, archive 0. The incident Trip is unchanged.

## Android client (3.1.9, not yet built into an AAB)
- `data/TripActivityCancellation.kt` holds the eligibility check, the write planner, receipt verification, the durable intent, fsynced evidence and the coordinator.
- Offered only when all of these hold:
  - the Trip is LOCAL_END_PENDING;
  - this device holds the Trip claim for the same account and vineyard;
  - the user's role is Owner, Manager or Supervisor;
  - the device is online.
- The operator must answer "Applied" or "Not applied". "Not sure" changes nothing. "Not applied" with recorded tank amounts also needs an explicit checkbox.
- Order of operations:
  1. Write and fsync the evidence file.
  2. Commit the REQUESTED intent with a stable operation ID.
  3. Send the request to the server.
  4. Verify the receipt.
  5. Commit ACKED.
  6. Clean up only this Trip's dependents.
  7. Commit CLEANED.
- After a lost response, readback runs first, then a replay with the same operation ID. While an intent is open, occurrence, tank and spray-parent replay for that Trip is held.
- **Defect found and fixed by the new test:** compliance facts were dropping the recorded water volume. `put()` returns the previous value (null), so the `?:` fallback overwrote it with null.

## Validation receipts
- JVM `TripActivityCancellationTest`: 17 passed, 0 failed, 0 skipped. XML sha256 `2ca249a0504f8abc85271a3d4138042a8bf8e5db6ad3a4e88d25c775149688f7`.
  - The run before the fix had 1 failure (the water-volume defect). It is kept as a failing run and not relabelled.
- Regression on the same source before the fix:
  - `P0DeviceTripRecoveryTest` 16/16;
  - `OccurrenceTankConflictHoldTest` 3/3.
- Android runChecks (release compile): PASS.
- Not executed:
  - instrumentation;
  - the ViewModel or UI path on a device;
  - a live RPC call from the app.

## Device acceptance steps (original Android install, in-place upgrade only)
1. Install the new Play Internal build over 3.1.9 without uninstalling or clearing data. Open the Trip and tap Copy Trip status; save the text.
2. On the Trip card, tap Cancel Trip and pick the truthful answer:
   - Applied: the recorded tank amounts are kept as a 3-year compliance record.
   - Not applied: tick the checkbox.
3. Expected results:
   - the Trip disappears;
   - Start Trip is enabled;
   - no unresolved queue items remain for this Trip;
   - the server receipt has status CANCELLED_ACKED with the operation ID shown in diagnostics.
4. Interruption: repeat the flow on a fresh test Trip with the network cut right after tapping. Reopen the app online. It must finish with the same operation ID, and no duplicate receipt may appear.
5. Open the app on a 3.1.8 device that still holds the Trip. Its writes must be refused with TRIP_CANCELLED_TOMBSTONE, and the Trip must not come back.

## Remaining (Phase B/C)
- TRIP_TANK no-op marker block while an actual depends on a session the server lacks.
- Tank Actual readback verification before marking it synced.
- CLOSED_SYNCED gating on dependents.
- Fresh Spray Trip lifecycle and the full device matrix (in-place upgrade, offline, restart, 3.1.8).
- Android AAB above 1793578439, Play Internal only.
