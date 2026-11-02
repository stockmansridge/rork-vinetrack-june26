# VineTrack Trip deletion is a whole-activity deletion — approved product contract

**Decision date:** 2026-11-02. **Status:** user-approved behavioural requirement, not implemented, migrated or released. Read alongside [CANONICAL_SYNC_CONTRACT_V1.md](CANONICAL_SYNC_CONTRACT_V1.md). The active iOS 3.1.9 and Android 3.1.9 incidents remain separate P0 release blockers.

## Product decision

**A Trip is the parent operational activity. Deleting a Trip deletes its exclusively associated operational records.** The user does not need to separately delete spray records, tank fills, tank actuals, GPS, path work, evidence, costs or reports. There must be **no orphaned operational rows and no infinite retry loop**, regardless of iOS/Android/Portal version or vineyard switch. An admin *Force Stop* or normal *Finish Trip* is not Delete.

**Legal record retention exception:** NSW EPA requires records of *actual occupational/commercial pesticide application* to be kept at least **three years** after creation (plus any applicable stricter product label, customer, QA, workplace or legal obligations). https://www.epa.nsw.gov.au/Your-environment/Pesticides/compulsory-record-keeping . A legitimately performed chemical application may be removed entirely from the **normal Trip/operational UI** with all ordinary child records, but a sufficient, access-controlled compliance record must survive in a separate archive until the retention period passes. This archive is not an active Trip or a synched spray. **Never claim regulatory-compliant complete erasure when a real application occurred and records remain legally required.**

An abandoned/draft/test Trip with verifiable evidence that **no actual pesticide application took place** may be permanently purged together with its exclusively owned children after the deletion is reconciled. The minimum deletion receipt (below) must remain to prevent old clients recreating the same UUID.

## Current live schema discrepancies (read-only verified 2026-11-02)

`public.soft_delete_trip(p_trip_id uuid)` currently updates only `public.trips.deleted_at`. It does **not** cascade to `spray_records`, locally persisted journals or Storage objects. Security-definer owner is `postgres`; caller checks `auth.uid()` and vineyard role owner/manager/supervisor. Preserve this or equivalent authorization: *operator cannot delete*.

**Postgres direct relationships:**
- Existing `ON DELETE CASCADE`: `spray_tank_actuals`, `spray_tank_actual_amendments`, `spray_trip_corrections`, `spray_trip_correction_operations`, `spray_trip_correction_amendments`, `spray_row_assignment_evidence`, `spray_row_recovery_operations`, `spray_row_recovery_trip_guard`, `trip_cost_allocations`, `trip_occurrence_operations`, `trip_report_assets`, `trip_weather_observations`, `trip_weather_retrieval_attempts`. These rows will physically disappear if the Trip parent is hard-deleted: **archive legally required records/receipts first**.
- Existing `ON DELETE SET NULL`: `damage_records.trip_id`. Review ownership: if exclusively created as part of the Trip, it is a child and should delete; if it has an independent vineyard record, unlink with an auditable reason and retain it.
- Existing `trip_id` columns **without a protecting FK to Trip**: `spray_records` (high priority; currently orphanable), `pins`, `pin_capture_evidence`, `manual_spray_tombstones`. Check whether each record is exclusively Trip-owned vs independently persistent. Never leave an active, dangling `spray_records.trip_id`. Read-only manual deletion receipts may need retention independent of Trip for safe old-client sync.
- Reference entities **not owned by the Trip** must survive: vineyard, paddock/block, shared tractor/spray unit/equipment, chemical catalogue/product/rates, people, independently created Work Task and Spray Job. Remove or invalidate only the Trip-owned link; do NOT cascade delete these shared master records.
- Delete associated generated report files, photos and uploads from operational Storage only after verifying all references and retention constraints; DB `ON DELETE CASCADE` does not automatically delete Storage objects.

**Already observed:** Trip `2be68a70-9582-4981-8a87-e727f113cdf6` is absent in Postgres yet retained as pending on iOS. Three soft-deleted Trips also retain iOS queue entries; two still have confirmed tank actuals and linked spray records. **Hard deleting those server rows now would not clear the device queues and would CASCADE-delete confirmed actuals.** Do not mutate these historical live records by this contract.

## Authoritative delete protocol

1. **Explicit action and classification**: user chooses `Delete Trip` and confirms the entire activity plus all associated records will disappear. Display child summary (spray, tank actual, reports, tracking). Determine whether a real application occurred from authoritative/local records, not from a user-interface default or merely whether tank actuals are null. For a real chemical application, create a complete compliance record before operational removal. For ambiguous or missing evidence, hold and ask an authorised reviewer rather than erasing.
2. **Durable local intent**: before hiding anything, persist immutable `delete_operation_id`, exact original `trip_id`, account incarnation, vineyard, actor/role, Trip baseline revision, intent timestamp, evidence classification and retention outcome. This intent takes precedence over all earlier/newer ordinary Trip/spray/tank uploads. Do not clear local drafts until authoritative acknowledgement.
3. **Authoritative server deletion endpoint**: idempotent, role-checked, vineyard-scoped, all-or-nothing transaction. On the same original ID, verify dependencies and archive if required; remove/deactivate all **exclusively Trip-owned operational children**, delete the parent when safe, revoke operational report file visibility and create a **small persistent deletion ledger/receipt outside the Trip FK graph**. Neither `admin_force_stop_trip` nor today's `soft_delete_trip` is enough.
4. **Minimal server tombstone/receipt**: preserve `original_trip_id`, original account/vineyard, delete operation UUID, authorisation/provenance, deletion server revision/time, status and compliance archive pointer (if any), with no unneeded operational payload. An identical replay returns the **same acknowledged result**; other identities/scope or a new operation with the same Trip ID are rejected. The ledger must survive hard deletion. Guard legacy direct `trips` INSERT/UPSERT and occurrence/actual/spray writers against deleted Trip IDs. Test older 3.1.8 client behaviour; a missing Trip row is **not sufficient evidence of a successful deletion**.
5. **Client acknowledgement and cleanup**: on iOS/Android/Portal, verify the receipt's original ID, vineyard/account, operation ID and revision, then atomically mark deletion acknowledged and purge/hide the matching Trip-owned local records, pending upload markers, journals, sessions and cached reports **without touching other Trips' data**. Preserve only the minimal local receipt and required compliance evidence. Clients in another vineyard may see the tombstone but cannot alter other-vineyard records. No account switch, crash, missing page or 401 may be misread as deletion.
6. **Offline and in-flight protections**: local Delete while offline queues deletion, suppresses *future* upload/recreation of the Trip and children, and retains evidence until server decision. A previous in-flight request may finish late; the deletion revision must win. Timeout after committed deletion must read back the original receipt; replay the SAME operation key, not create new. A permanently rejected deletion remains visible as Needs Review, not silent success.
7. **Legal retention**: the separate compliance archive must preserve the compulsory pesticide application facts (product, rate/amount, when, where, crop, applicator, weather/wind as applicable) and permit authorised export until at least the applicable retention end, with immutable audit. The operational Trip and its children remain deleted/unavailable to ordinary sync. Explicit final purge after retention is a separate policy action; no automated deletion merely because 3 years have passed if another hold applies.

## Data ownership / deletion disposition (to certify per domain)

| Trip-related records | On delete |
|---|---|
| Trip row, GPS tracks, occurrence/path actions, route completion, fuel usage and Trip-only allocations | Remove from operational state; minimal deletion receipt only |
| Spray Record directly created by Trip and its planned chemical mix | Remove from operational state; archive real legally required application facts first |
| Tank 1..N sessions, initial mix handoff, operator-entered water/chemical actuals, corrections and amendments | Remove from operational state after retention classification and original-session acknowledgement; legal archive when required |
| Linked row evidence, weather observations, generated Trip reports, photos and cost allocations | Remove if owned exclusively by Trip; archive mandatory source facts beforehand; remove exclusive Storage objects |
| Trip-created pin/damage observation | Remove if exclusively Trip-owned; otherwise unlink with verified independent ownership |
| Spray Job, Work Task, chemicals/cat catalogue, vineyard blocks, equipment, people | Retain as independent entities; only remove Trip-specific association |
| Local outbox, pending upsert/delete, old occurrence journal and older client cache | Do not clear until original receipt verified; thereafter remove all Trip-owned operation entries and retain only anti-resurrection tombstone |

## Mandatory acceptance tests

- Delete empty/not-started Trip: all exclusive children disappear, no user-visible sync errors, no resurrection after reopen.
- Delete real application: operational view is clean and ordinary children deleted; compliant archive remains exportable to authorised persons for retention duration.
- Delete with two tanks, actuals, weather, GPS, work-task link and report attachments: exact child counts and independent record survival.
- Delete while offline; in-place update from 3.1.8 to 3.1.9; two devices with one delayed older upsert; original user/vineyard changes.
- Deleted Trip with legacy `spray_records.trip_id` but no FK: no orphan or recreated spray; no cascading to shared chemical/equipment.
- Crash before/after server commit and before/after local receipt: same ID, idempotent outcome, no partial child row state.
- Deletion of Trip with uncertain original occurrence create, missing parent, mismatched spray, missing tank-session or outstanding operator actuals: hold for review, do not auto-ack or erase.
- Deletion in original vineyard when currently viewing another vineyard: preserved scope, no unrelated cache clearing, accurate per-vineyard counts and status.
- Direct old-client insert after deletion: server rejects resurrection without affecting other old-client operations.
- RLS/auth: only correct vineyard owner/manager/supervisor role; unauthorised/not member/revoked/other-vineyard user gets no receipt or data leak; preserve existing access rules.
- Existing iOS/Android normal Start/Resume/End and Spray/Tank Actual flows still pass; delete is not confused with Finish or admin Force Stop.
- Legacy soft-deleted rows: migrate to terminal deletion only after human-reviewed evidence retention and proven local queue reconciliation. No retroactive blanket hard-delete.

**Release gate:** explicit owner-reviewed backend migration, Portal, iOS, Android and 3.1.8 compatibility; signed original-device tests and full server readback. **This document authorises no live deletes, no irreversible migration and no production release.**
