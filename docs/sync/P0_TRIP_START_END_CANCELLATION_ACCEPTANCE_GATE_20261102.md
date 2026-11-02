# P0: Trip start → tank actuals → end → sync / cancellation acceptance contract

**Date:** 2026-11-02. **Status:** original-device FAIL, product acceptance criteria and engineering handoff, NOT code deployed. Scope: iOS / Android 3.1.8 and 3.1.9, Portal, live Supabase. Built on [CANONICAL_SYNC_CONTRACT_V1.md](CANONICAL_SYNC_CONTRACT_V1.md) and [TRIP_DELETION_CASCADE_CONTRACT_V1.md](TRIP_DELETION_CASCADE_CONTRACT_V1.md).

## 1. Current reproducible case (Android 3.1.9 / build 1793578439)

- Original device and scope: vineyard `59973ced-1fb9-42ec-a66d-9eaad3172824`; original Trip `3bfb7f81-2ae2-4f33-8fd8-6666b2b45393`. On device: `device_active_trip_id_matches=true`, `selected_vineyard_uuid_equal=true`, `persisted_claim_*_matches=true`, `trip_locally_ended=true`. UI reason `LOCAL_END_PENDING` (NOT a different-device claim).
- On server (read-only verified 2 Nov): Trip ACTIVE, `end_time=NULL`, 8 occurrence items, 3 GPS points, `tank_sessions=[]`. Only create/activate receipts; NO accepted finalise receipt `3a999293-5734-44ee-9a58-fb8abb61ef99`; zero `spray_tank_actuals` for this Trip.
- Local `trip_labour` create and `trip_tank` update are unresolved `PENDING`, **attempts=0** (two outbox operations, not two Trips). Actual `2b07a0ce-2086-441c-9d36-8a387e3e397d` for spray `6d44c888-32fb-4a04-9dc7-5d6e2f5910ea`, original tank session ID `30259f0a-e2e2-41a2-8fbf-4569028a6f45`, Tank 1 has water recorded and one chemical line locally, NOT server-acknowledged. `session_presence: ui_trip=false; active_snapshot=false; start_tank_journal=absent`; `session_evidence=actual_only_session_missing_held_no_fabrication`.
- **Code-proven interlock:** `AppViewModel.canStartDeviceTrip()` sees the retained active `ActiveTripStore` claim and refuses independent new Trip. `AppViewModel.deleteTrip()` refuses an active server Trip when `state.activeTrip` is excluded due to locally-ended status, treating it as another device. End/occurrence journal correctly refuses full finalisation with pending actual/tank changes. The device has **no safe user-visible terminal outcome** for a local end with irrecoverably missing session, despite owning the exact original Trip.
- Current `TripTankSync` uses a marker with no frozen session payload; its full payload is in the Stage A snapshot. An empty snapshot with a pending actual referencing an absent session is NOT a safe 'nothing changed' acknowledgement. Test the code's `!merged.addsSomething(server)` branch against a same-trip pending actual and original frozen journal evidence. Pending-attempts=0 need per-stage trace; do not assume an HTTP failure.
- iOS build 200 has 4 old Trip upload markers not in selected slice (mixed vineyards, 3 server soft-deleted/1 missing) and 1 locally pending tank actual awaiting parent. Different issue, but same terminal receipt/anti-resurrection policy must apply.

## 2. Required operator-visible states (single vocabulary on iOS/Android/Portal)

| State | Meaning and allowed action | What is NOT allowed |
|---|---|---|
| `PREPARED` | Original planned Trip/recipe and row path frozen, device operation IDs committed. Start can be retried with same IDs. | Claim live coverage or actual application just from planned recipe. |
| `START_REQUESTED` | Durable original owner/vineyard Trip, occurrence create/activate and Spray Record may be awaiting exact server receipts. Display Start pending/recover. | Duplicate IDs/parent creation, silently resume on other device. |
| `READY_FOR_TANK_1` | Start acknowledged (or explicitly offline-authorised), correct plan, original Tank 1 actual-entry screen open. | Start spraying/mark rows treated without real tank confirmation and durable original session. |
| `OPERATING` | Original Tank session and operator-entered actuals are durable, route/action evidence belongs to same Trip. Distinguish local accepted vs server accepted. | Overwrite actuals with plan or steal another device claim. |
| `END_REQUESTED_LOCAL` | Operator has stopped; original stop time, GPS/occurrence states and all pending dependents retained. Show `End pending sync`, with scoped inspect/retry or authorised cancellation. | Call it server-complete, resume GPS implicitly, say 'another device'. |
| `CLOSED_SYNCED` | Server accepted exact terminal operation and readback proves Trip inactive/ended, original GPS/occurrence state and Tank/Actual/linked Spray data; needed labour/cost attachments reconciled or independently reported. Durable exact acknowledgements; no remaining relevant pending operations. | Mark closed solely from HTTP 2xx, a local flag or zero queue counter. |
| `CANCEL_REQUESTED` | Owner/manager has requested whole-activity cancellation, original Trip & dependency IDs frozen; identify if real pesticide application occurred and archive any legally required record BEFORE operational deletion. | Direct hard-delete first, clear all queues by count, let old client resurrect parent. |
| `CANCELLED_ACKED` | Authorised server transaction removed the complete Trip-owned *operational* graph, persisted anti-resurrection receipt and permitted local exact-ID queue and claim release after receipt readback. | Delete unrelated equipment/chemical catalogue/blocks; remove required compliance archive. |
| `HELD_NEEDS_REVIEW` | Original evidence missing, conflict, revoked membership, corrupted journal, unknown accept/reject. Display precise scope, dependency and safe options. | Fabricate Tank session or complete a physically sprayed Trip with unknown actual evidence. |

Distinguish **local stopped / server active** from genuinely **remote-owned**, and a terminal cancelled test from a physically performed spray application.

## 3. Mandatory first-tank start contract

- Persist immutable Original Trip UUID, Spray Record UUID, first Tank UUID, planned chemical/water snapshot, original operator *actual* water and chemical quantities, equipment, blocks, area, route and operation ID in an atomic or recoverable multi-journal transaction BEFORE signalling successful Start to UI.
- Required ordering: `create_trip_with_occurrences_v1` exact ID receipt → `activate_trip_occurrences_v1` receipt → linked Spray Record accepted → **original Tank session persisted and uploadable** → corresponding confirmed actuals persisted and reconciled → first spray path operational. Offline status must explicitly distinguish awaiting server from locally durable.
- If the Start Tank journal is absent but the original Tank session exists in original account-scoped snapshot, recover by exact ID; if only an actual exists with a tank-session UUID, **do not infer missing start timestamp, start row, or state**. Present recover/cancel decision, retain quantities as evidence. Do not claim a normal completed application.
- `TripTankSync` may clear a no-op marker only after confirming **no pending actual, start-tank intent or occurrence reference requiring that exact Tank session**. Persist a server receipt/readback and validate original client revision; payload-less marker alone is insufficient proof.
- Sync each parent and child in a crash-resumable order. Never erase a newer local revision because an older upload returned.

## 4. Mandatory Trip end contract

- End can record a valid **partial** job with some paths incomplete/skipped, provided their original statuses, covered/treatable area and an explicit reason are recorded; never silently mark unvisited paths done. Ending an empty/non-started Trip is a **Cancel**, not a completed chemical application.
- On end request: stop local capture safely, freeze actual GPS/coverage/tank state and exact stop time, then publish `END_REQUESTED_LOCAL`. A locally ended Trip remains manageable on its original device through **Status/Retry/Cancel/Export diagnostics**, not active spraying controls.
- Dependency graph: parent Trip/occurrence receipts → Spray Record → original real Tank session(s) → matching operator-entered Tank actual(s) → GPS/occurrence actions and required labour/cost snapshots → exact original `finalize_trip_occurrences_v1` → server readback `is_active=false`, end time and accepted matching coverage. Finalisation must never bypass missing mandatory children. Labour capture is a separate original-fact journal and should not block tank upload or falsely appear synced.
- A failed/held child must display **which** child and why; counts represent unique operations, not Trips. A pending operation with `attempts=0` requires a stage/dependency reason, not 'Retry All'.
- On terminal server receipt only: release matching `ActiveTripStore` claim, clear exact acknowledged outbox revisions, remove the local ending flag and report `CLOSED_SYNCED`; no destructive cache reset or cross-vineyard clearance.

## 5. Safe exit for the CURRENT stuck original Trip

1. Snapshot the exact original local Trip, occurrence journal (including pending finalise ID), 2 outbox entries, the actual and its values, spray link, raw diagnostic status and owner/vineyard account-incarnation. Confirm whether **physical chemical application happened**; unknown = hold, not a test-only erasure.
2. Recheck for original Tank session evidence from every *original* durable source (including previous-version on-device backup if accessible safely) and current server. Preserve original IDs; do not recover from a guessed planned tank.
3. If session evidence is sufficient, reconcile original session → actual → GPS/coverage/optional labour → original finalise receipt. Same Trip ID, no duplicate; verify server readback. If insufficient, do NOT call the job complete.
4. For a confirmed **non-applied testing/abandoned Trip**, provide an **authorised Cancel/Delete whole activity** action **while `LOCAL_END_PENDING`**, so it is not impossible merely because `state.activeTrip` is null. Authenticate original account/vineyard, current owner/manager rights and original on-device claim; transact server cancellation with all Trip-owned dependents and durable deletion ledger outside Trip FK graph. Only after receipt, reconcile this exact device's Trip/tank/actual/labour/finalise pending operations and release its active claim. Preserve sufficient technical deletion evidence to prevent 3.1.8 re-uploads. No bulk cleanup.
5. If a real application occurred or evidence is ambiguous, create/retain the legally required compliance record and an auditable exception/recovery decision before operational cancellation; never silently remove pesticide-use history. Preserve original amounts and conflict state.
6. If network/permissions unavailable, show scoped pending cancellation and do not pretend new starts are safe while a locally/remote active claim is unresolved. Once terminal receipt verified, independent Start becomes available with no app reset.

## 6. Release-blocking test matrix (actual original-device proof required)

| Case | iOS | Android | Backend / other device | Expected |
|---|---|---|---|---|
| A. Fresh planned one-off Spray with 8 paths | ☐ | ☐ | ☐ | Start, first tank session + actual, GPS, rows, end, all original IDs and receipts |
| B. Multiple tanks / changed actuals | ☐ | ☐ | ☐ | Exact actual quantities and tank identities, no planned-value substitution |
| C. End with incomplete/partial paths | ☐ | ☐ | ☐ | Path status preserved, partial outcome and reason |
| D. Interrupted start after parent commit | ☐ | ☐ | ☐ | Recover original, no duplicate |
| E. Interrupted Start Tank after actual persisted, before session | ☐ | ☐ | ☐ | Recover only from original evidence or safe HOLD, never fabricate |
| F. End pending with tank marker and actual | ☐ | ☐ | ☐ | `END_REQUESTED_LOCAL`, not remote-owned and not falsely closed |
| G. Authorised Cancel from end-pending test Trip | ☐ | ☐ | ☐ | Complete operational cascade + original deletion receipt; old client cannot resurrect; new Start unblocked |
| H. Physically applied Trip cancellation | ☐ | ☐ | ☐ | Required compliance archive remains authorised/exportable |
| I. In-place update, offline/force-close/restart | ☐ | ☐ | ☐ | Preserved IDs, actuals, claims, stages, final outcomes |
| J. iOS ↔ Android ↔ Portal convergence | ☐ | ☐ | ☐ | Remote read-only while other's active, completed and deleted states converge |
| K. Prior 3.1.8 binary request against live backend | ☐ | ☐ | ☐ | Backward-compatible writes or explicit non-destructive rejection |
| L. Cross-vineyard old pending uploads and archived Trips | ☐ | ☐ | ☐ | No global block/no resurrection/receipt-based local queue convergence |

**Release verdict: FAIL until ALL required rows have original-device and backend evidence.** A working compile, source test, TestFlight upload, unsigned simulator, server Trip creation or apparent green Sync badge does not pass the matrix. Each row records the specific build, source SHA, original device, original IDs, server receipts and readback values. The signed binary must be provably built from the checked commit.

## 7. Change scope / evidence requirements

- Do not modify source of the live current P0 fixes merely to match this document. Implement as reviewed, minimal PRs with frozen 3.1.8/3.1.9 writer fixtures and the shared sync contract. Fix Android **local-end-pending deletion control** and **Tank marker/actual missing session** as separate tests from the iOS mixed-vineyard queue recovery.
- Do not deploy SQL or hard-delete any current Trip/actual from a diagnostic. Source PR #38 is governance only. Backend function UUID comparison in PR #31 remains a separate authorised-owner dependency.
- New diagnostics must show one complete original-operation dependency graph (Trip, Spray, each Tank, actual, GPS, row/occurrence, labour, finalise or cancel), status, attempts, last cause, original receipt and full-sweep status, in owner/vineyard scope, without copying chemical amounts or personal info by default.
