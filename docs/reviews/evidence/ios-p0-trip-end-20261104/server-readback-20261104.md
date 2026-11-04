# Server readback, original Trip 492ebafc-b996-4ec4-8ea9-4261a3056810

Source: `sql/trip_end_recovery_readback.sql` (read-only), run by the project owner on production and pasted into the
chat on 2026-11-04. The agent did not run it and cannot independently verify it.

## Server state at readback

- Trip: found, vineyard `59973ced-1fb9-42ec-a66d-9eaad3172824`, `is_active=false`, `end_time=2026-11-03T13:41:29+00:00`,
  `deleted_at=null`, `sync_version=3`, `updated_at=2026-11-03T22:25:41Z`.
- Tank sessions on the Trip: 1, id `0EFE511B-4B25-49DF-AF82-08BEAE22B23A` (uppercase, original).
- Tank actual: 1, `4e06a410-fe8f-44d8-a54a-450ec5429e58`, tank 1, 300 L, `confirmed_at=2026-11-03T13:40:42Z`,
  tank_session_id equals the session above, spray_record_id `33ccca24-e259-405b-bdf8-af3b8777aa26`.
- Spray record `33ccca24-...`: completed, `end_time=2026-11-03T13:41:29Z`, not deleted, `sync_version=2`.
- Occurrence ledger, 3 accepted operations:
  - create `ed906961-9f65-435a-bc5e-043ec4b332b5` at 2026-11-03T13:40:41.834Z
  - activate `2c42cf71-9e42-4599-9f9d-3b562fc9189e` at 2026-11-03T13:40:41.970Z
  - finalize `06ecace9-d457-4591-aa7d-6ecb17ee768b` accepted 2026-11-03T22:25:40.949Z,
    requested end `2026-11-03T13:41:29Z` (the original local End time), result `isActive=false`.
- Occurrence coverage: revision 2, 8 incomplete, no linked tank sessions. No setStatus or tank-link operation was ever
  accepted, so the tank-link UUID-case defect was never exercised by this Trip.

## What it shows

- Server side, the original Trip is complete: tank session, tank actual, finalise receipt with the original end time,
  `is_active=false`, Spray completed.
- The finalise was accepted about 8h45m after the original End. That is the first server write of the End.

## Not yet established

- That finalize `06ecace9...` is the same operation ID as the one retained in the iPhone journal (needs device diagnostics).
- Which build and which client sent it.
- Device acknowledgement, persistence after reopening, and absence of a sync warning.
- Why `sync_version` is 3 (create, activate, finalise) with a tank session already present; the path by which the tank
  session reached the row is not shown by this readback.

Incident status: OPEN until the device-side items above are confirmed.

## Device diagnostics, 2026-11-04T01:21:06Z (pasted by the owner; selected vineyard Stockmans Ridge)

- The two attempt records are build 3.1.9 (215) on vineyard `59973CED` (JH Testing): started 2026-11-03T22:25:27Z (stage
  `sync-failed` 22:25:46Z) and 22:32:09Z (`sync-failed` 22:32:24Z). The server accepted finalize `06ecace9...` at
  22:25:40.949Z, inside the first attempt. Build 215 therefore reached the server for this Trip once JH Testing was
  selected. This matches the vineyard-scope hypothesis; it is an inference from timestamps, not a logged confirmation.
- The retained Trip-upload list now has 7 entries (was 8); `492EBAFC` is no longer in it, and pending Trip upserts went
  from 2 to 1. No pending tank actual references `492EBAFC` (the 3 pending are legacy `0A5466DF`, `A3C31B89`, `DEAD3350`).
- What ended each attempt as `sync-failed` is not shown. The Trips entity is still `held`, `last_sync: never`,
  pending_upserts 1, pending_deletes 1 (deletion `2BE68A70`, `TRIP_DELETE_CREATE_OUTCOME_UNKNOWN`, correctly held).
- Not shown: the build number running now, the local state of `492EBAFC` (ended, no warning), persistence after reopen.
- Incident remains OPEN.

## Device Trip closure status, build 3.1.9 (216), 2026-11-04 ~01:00 local (pasted by the owner, screenshot IMG_3825)

- `trip=492ebafc-b996-4ec4-8ea9-4261a3056810 state=CLOSED_SYNCED evidence=fresh_server_read`
- server_terminal active=false, end_time_set=true; locally_ended=false; unresolved_markers 0; occurrence_pending 0, held=false;
  tank_actuals total_sessions 1, pending 0; server_sessions 1; linked_spray matching_completion; reasons none.
- UI: "Synced" badge, ended 4 Nov 2026 12:41 am, "Closed and synced, verified with server".
- Combined with the server readback above, the original Trip passes server and device checks on build 216.
- Caveats: `source_revision` is `unknown_no_verified_build_receipt` (signed binary not attested). Force-quit/reopen persistence
  and the Trips-entity "held / last sync never" status are not yet re-checked. Legacy queue items remain unreconciled.
