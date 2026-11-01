# VineTrack Canonical Synchronisation Contract v1 — 2 November 2026

**Status:** GOVERNANCE DRAFT / P0 RELEASE BLOCKED. This document defines mandatory expected behaviour; it does **not** claim iOS, Android, Portal, legacy 3.1.8 or live SQL currently satisfy all clauses. Source of truth for verified DB column types: [live-public-schema-snapshot-20261102.json](live-public-schema-snapshot-20261102.json) (26 tables / 718 column definitions; metadata only). This contract supplements, does not replace, [OPERATIONAL_REPAIR_CONTRACT.md](OPERATIONAL_REPAIR_CONTRACT.md), [sync-compatibility-register.json](sync-compatibility-register.json), [sync-concurrency-contract.md](../sync-concurrency-contract.md), and the domain-specific specifications.

## 0. Purpose, scope, baseline

A changed writer, DTO, RPC, migration, queue, read, cache, access policy, or Portal form is a **cross-platform contract change** even if only one component is edited. Changes need a documented source-version comparison, before/after durable fixtures, explicit older-client compatibility check, and evidence of device-to-server-to-other-device convergence. No uncontrolled "fix until it looks green".

**Authoritative backend:** Supabase project `tbafuqwruefgkbyxrxyb`, Postgres public schema and explicitly authorised RPCs. Postgres is authoritative for accepted shared state; the device's durable outbox is authoritative for *unacknowledged locally authored work*. A Portal "Hard Stop" changes server state but does not extinguish locally retained work. Do not use server force-stop, UI disappearance, cache refresh or an arbitrary retry to claim the device has reconciled.

**Release baseline:** main at audit `b45f909ad658fc2dc96f0e5736129d2c646b5d55`. Open PRs #29, #31, #33, #37 and incident documents must be reviewed against CURRENT main; do not cherry-pick an old tree. Android 3.1.8 / 3.1.9, iOS 3.1.8 / 3.1.9, Portal, and every backend version still serving older clients belong in the compatibility matrix. No minimum-version hike is authorised here.

## 1. Non-negotiable invariants

1. **Stable identity.** Every operational entity has a stable UUID; a retry reuses the *same* entity and idempotency/operation IDs. Parent/child references never match by display name, time, route text, or fuzzy UUID spelling.
2. **Durable intent before transport.** Atomic local commit includes original scope, requested payload, operation identity, dependency, and retry stage. The data remains readable after app kill/restart. Never clear until verified matching acknowledgement *and* no newer local revision.
3. **Account fences.** A journal belongs to account incarnation + original user + vineyard + entity + operation. Revalidate membership, write entitlement and selected scope before and after every awaited network operation. Failed or missing access is not an empty account.
4. **Server result is not device acknowledgement.** An accepted server row/receipt is reconciled against the original request and current local revision; only then may the device mark the operation acknowledged.
5. **Unknown result is not failure to create.** HTTP timeout, cancellation, crash or lost response after commit => unknown outcome; query existing server state/receipt using original IDs. Never mint a second Trip, spray, tank or saved pair.
6. **Old/new compatibility.** 3.1.8 requests, encoders, old nullable fields and recovery representations remain valid until explicit tested deprecation. Additive/versioned contracts; no required new argument in a legacy RPC. Unknown fields in newer server payloads must not be destructively erased by older clients.
7. **No lossy reads.** Offline, 401/403, expired token, truncated page, parse failure, missing permission, partial response, missing table, or pending remote load is UNKNOWN/HELD—not an empty list or deletion instruction.
8. **Typed equality.** UUIDs compare as UUIDs (canonical lower-case when serialised); timestamps UTC ISO-8601 with offsets and preserved precision; numbers finite with explicit units; a missing/null field never means zero or false unless the documented domain says so.
9. **No device-clock concurrency authority.** `client_updated_at` is human-edit metadata. For `resistance_plans`, `pruning_seasons`, `pruning_yield_settings`, use verified `base_revision` / server `server_revision` as in sql/198. For all other tables, record CURRENT actual merge policy rather than falsely asserting universal revision safety.
10. **No data loss on conflicts.** Keep the local version, remote version and reason; allow user reconciliation where necessary. A 409, 401, constraint error, incomplete create, blocked parent or journal decode failure is not permission to drop/recreate data.
11. **Scoped dependency ordering.** Enforce parent creation => Trip occurrence creation/activation => spray record linkage => exact session => actual chemical/water row => ended-state completion, with domain-specific exceptions documented and proven. A held unrelated historic entity must not globally block a truly independent new operation, but no pending duplicate/same-parent/active claim may be bypassed.
12. **Explicit deletes.** Only a matching authorised tombstone or validated deletion receipt may remove server-backed local data. Hard Stop != delete != parent/child acknowledgement.
13. **Proof, not appearance.** "Synced" requires eligible uploads acknowledged, pull/reconciliation completed, and no unreported holds, conflicts or outstanding child dependencies. Show per-category counts with clear semantics: operations, unique entities and issues are not interchangeable.
14. **Protected actuals.** Calculated chemical/water quantities are guidance; separately confirmed operator-entered actuals, their base units, original tank session and immutable planned recipe must survive path changes, queue retries and cross-device fetch.
15. **Source/build provenance.** A green source test is not signed build, device acceptance or release approval. Every shipped candidate must map to exact commit, binary/version code, schema/RPC hash and device tests.

## 2. Canonical transport and storage types

| Kind | Wire contract / constraints |
|---|---|
| Entity identity | UUID string lowercase canonical on outbound wire. Comparison by UUID identity, not JSON string case. Preserve original entity/operation identity across replay. |
| Account / vineyard | UUID with authenticated account-incarnation fence, verified membership; never trust mutable user metadata for authorisation. |
| Created/updated timestamps | RFC3339/ISO8601 UTC, explicit timezone; Postgres `timestamptz`. Preserve server precision. `client_updated_at` cannot order author edits from different devices. |
| Quantity | Finite number; preserve explicit unit, conversion basis and numeric precision. Reject undefined/nonfinite, never silently assign planned value to actual. |
| Null, omitted, zero | Three distinct meanings. `upsert_spray_tank_actual.p_water_volume_l` is a required argument and may explicitly be null ("not recorded"); null is not 0, omission is not valid. |
| JSON documents | Contract-specific version and owner; preserve unknown read-only/future fields where writer supports them. Never whole-document overwrite an unsupported future occurrence or catalogue revision. |
| Deletion | `deleted_at` and explicit authorised tombstone/receipt where supported; a missing list element is not deletion. |
| Revisions | `sync_version` appears in many tables; it is **not** a universal optimistic-concurrency token. Only verified domain-specific CAS or server_revision paths may be described as such. |
| Source/display preferences | Existing varchar/text enums and unit settings remain compatible; clients must not rewrite saved code values just to satisfy a parser. |

The 718-field live snapshot gives database column spellings, types and nullability, not device serializer equality or RPC acceptance. Every entity record in the registry below must link to an exact iOS encoder, Android serializer, Portal query and backend decoder/constraint before its certification can move to VERIFIED.

## 3. Write lifecycle: mandatory state machine

```text
USER ACTION -> durable local SNAPSHOT + intent
  -> QUEUED -> ADMITTED(scope+permission+deps)
  -> SENT(original ID + idempotency) -> {ACKNOWLEDGED | UNKNOWN | RETRYABLE | HELD | CONFLICT}
     ACKNOWLEDGED -> verify matching receipt + persisted original revision -> READBACK/RECONCILE
                  -> clear only acknowledged operation; publish remote to other devices
     UNKNOWN -> check exact server identity/receipt; resend SAME operation only if authorised safe
     RETRYABLE -> bounded backoff without discarding payload
     HELD -> durable named reason, retain payload, no automatic unsafe replay
     CONFLICT -> persist both versions, no blind retry or silent overwrite
```

A local journal may have more specific substates: occurrence CREATE/ACTIVATE/ACTION/FINALISE; legacy SPRAY PAIR; first-Tank handoff; photo object-upload. State name, original ID and valid transitions must be explicitly mapped to these universal classes. Crash before or after every durable transition is a required test. All queue-clearing code must test exact operation/current revision, not just entity ID or any 2xx.

## 4. Verified operational Trip/Spray/Tank dependency paths

**iOS source** `NewMainTabView.swift` currently performs equipment -> pins/blocks -> Trip initial sync -> SprayRecord sync -> reconcile initial mix -> TankActual push+pull -> Trip final second pass; then other domains. `TripSyncService` has separate parent-created and finalisation-only gates; `SprayTankActualStore` retains drafted actuals until an exact real session/recorded amount. `TripTrackingService.requireResolvedOccurrenceStarts()` scans retained occurrence journals for an unconfirmed create and can block a new Trip; this must be assessed against truly independent operations without erasing old evidence.

**Android source** `TripStartSync.kt` queues original trip UUID first, followed by metadata/GPS/row/tank/end dependent markers. `TripOccurrenceJournal.kt` persists scope, pending operation IDs and reversible evidence. The inspected main `AppViewModel.kt` calls legacy `retainedStart` before independent qualified start; PR #37 proposes a scoped fix, NOT merged in this audit.

**Server sources:** `trips` has `id`, `vineyard_id`, `occurrence_coverage jsonb`, `tank_sessions jsonb`, activation flags and `sync_version`. `trip_occurrence_operations` holds `operation_id`, `trip_id`, `vineyard_id`, `actor_id`, request/result and `accepted_at`. `spray_records` has `trip_id`, planned `tanks jsonb`, and optional `spray_job_id`. `spray_tank_actuals` has original `trip_id`, `spray_record_id`, `tank_session_id text`, `tank_number`, `water_volume_l`, `chemicals jsonb`, `confirmed_at`, correction version. Its actual FK requires parent Trip + spray record (confirmed in live schema). `create_trip_with_occurrences_v1` is owned by `vinetrack_occurrence_writer`; live function MD5 `b0e166d78be75c8ba770b` at audit and SQL identity correction in PR #31 is NOT deployed. The backend owner must deploy through an existing authorised path; never alter privileges as a workaround.

**Cross-device:** Operator A writes original IDs and gets matching server acknowledgements. Server rows are authoritative to B only after B authenticates in the same permitted vineyard and completes the relevant dependency-scoped pull. B cannot "own" A's live tracking claim merely by seeing the server Trip. A remains responsible for protected pending actuals until accepted, and B must not substitute plan quantities for A's actuals. A server-side admin force-stop does not touch either local queue.

## 5. Domain contract register and owners

See [sync-domain-contracts-v1.json](sync-domain-contracts-v1.json) for machine-checkable rows. A domain record requires source paths for iOS, Android, Portal, database and declared compatibility, merge, deletion, status and tests. `review_status: unverified` is intentional. Known specialised paths include:
- vineyards / membership / selected account / logo / region settings / access;
- paddock geometry, rows, variety/planting allocations;
- pins, locations, pin growth mirrors, photo storage;
- spray programmes, jobs, legacy saves, chemical catalogue versioning and rates;
- Trips, occurrence operation receipts, path coverage, fuel, GPS, work task links;
- tank session and separately operator-entered chemical/water actuals;
- work tasks, labour, equipment, pruning, yield, growth, maintenance;
- irrigation/fertigation/rain, weather and alert read-caches; billing entitlements;
- media, documents and external integrations.

Each subdocument must enumerate every JSON field, its wire name, null/missing/default rules, who can edit, who owns the merge, old-client behavior, schema version, dependency prerequisites and output acknowledgement. A change in any of those is a contract change.

## 6. Mandatory compatibility / change-control workflow

1. Create a **Sync Change Record** using [SYNC_CHANGE_REQUEST_TEMPLATE.md](SYNC_CHANGE_REQUEST_TEMPLATE.md) *before touching a write path*, listing touched tables, endpoints, DTO/codec, old/new clients, local store, queue lifecycle, downstream fields and Portal readers.
2. Prove the old contract with frozen real-writer shapes from released 3.1.8 and current 3.1.9. Do not reconstruct historical payloads from newer models. Confidential fixtures are synthetic with exact shapes (no secrets/customer data).
3. Produce iOS encode/decode and Android encode/decode parity; verify Portal and live DB/RPC name, unit/null/default, optional/unknown-field handling and permissions with rollback-only backend tests.
4. For each entity: create/update/delete, offline/restart, same-ID replay, lost response, server commit followed by timeout, 401/403, malformed payload, partial page, concurrent edit, old-client write after new-client write, account/vineyard switch, revoked membership, newer-local-edit during old ack, duplicate and out-of-order delivery.
5. For dependent operations: verify Trip parent/occurrence create+activate, spray link, first/subsequent tank, explicit actuals, finished state; test cross-platform A->server->B and B->server->A.
6. Verify UI diagnostics, never-cleared-on-retry failures, retained counts, ability to distinguish not yet synced from confirmed, and no unrelated global trip start blockers.
7. Mark per-domain VERIFIED only with source SHA, native test report, authorised backend test, old/new compatibility result and original-device acceptance. Record every failure; no inferred green.
8. Changes to `docs/sync/`, sync/RPC/schema source, or a new endpoint must pass `scripts/validate_sync_contract.py` and existing `scripts/audit_sync_inventory.py --verify-inventory`; CI blocks unreviewed contract drift. CI alone does not certify data migration.
9. Merge and release only after reviewed PR, backend/Portal deployed first if required, signed binaries mapped to exact commits and original-device A/B testing. Older clients must remain functional unless separately approved.

## 7. Diagnostics and operations

Use a sanitised, privacy-safe record: platform, app version/build/source hash, account/vineyard scope verified **boolean** (not credential), entity type, local operation kind and stable *hashed* support correlation ID, parent dependency category, current stage, last attempt, retry count, backend error code, receipt/readback state, newest-local-revision-vs-ack comparison and separate counts (unique pending operations, held operations, failed operations, conflicts, unacknowledged tank drafts). Never dump tokens, chemicals quantities, customers or raw payloads in support text by default. A read-only System Admin Portal inspection can show server presence/receipt, but not assert device-local acknowledgement from server evidence alone.

## 8. Incident findings and no-release blockers

- iOS Cab Franc 1 Nov 2026 occurrence journal held; original Trip/Tank actuals not reconciled; do not clear or remake.
- Android retained legacy paired-create starts block new qualifying routes on main; PR #37 unmerged at audit.
- Live `create_trip_with_occurrences_v1` UUID JSON textual membership mismatch candidate (PR #31); backend deploy rejected due to function ownership. Auth/security must remain intact.
- Older iOS/Android sync inventory checker documents 37 coordinator calls / 38 Android pending discriminators but **does not** verify semantics. At audit `released_318_source_verified=false`, `native_319_acceptance_complete=false`.
- Previous `docs/ios-sync-status-parity-status.md` records a superseded Android-only direction; do not treat it as governing later authorised iOS changes.

**Do not modify the active emergency repair PRs in order to adopt this governance draft.** Contract definitions/CI have no runtime database, local-queue or app behaviour changes. Freeze public release until the P0 start/sync incident is accepted independently.
