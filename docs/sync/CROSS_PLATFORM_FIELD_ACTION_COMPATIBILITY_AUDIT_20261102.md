# VineTrack cross-platform field, action and compatibility audit — first evidence-backed pass

**Audit date:** 2026-11-02. **Status:** **P0 IN PROGRESS / NOT CERTIFIED / PRODUCTION RELEASE BLOCKED**. Read-only audit; no client code, live data, RPC definition, security grants or Portal deployment changed. This is the evidence-backed starting point for the 26-domain certification programme, **not** a claim that every field and action has been validated.

## 0. Pinned source and what was actually inspected

- Public mobile source: `stockmansridge/rork-vinetrack-june26` **main `510348760de2b61a060e47ce19e7420d363b8e6e`** (source audit, not an installed-binary SHA).
- Governance contract: PR #38 `docs/sync/CANONICAL_SYNC_CONTRACT_V1.md`, `sync-domain-contracts-v1.json`, `live-public-schema-snapshot-20261102.json`, `SYNC_CHANGE_REQUEST_TEMPLATE.md`, `scripts/validate_sync_contract.py`, `scripts/audit_sync_inventory.py`. Branch's canonical contract is not in main and 26/26 domain rows are `unverified`. The inventory script checks names/route declarations, NOT serializer correctness.
- Backend: live Supabase project `tbafuqwruefgkbyxrxyb` as of 2026-11-02. Examined current `information_schema.columns`, `pg_proc` function source and MD5, `pg_constraint` and `pg_trigger` READ ONLY; ran pure `validate_spray_tank_actual_chemicals(jsonb)` against **synthetic non-customer** values without write side effects.
- Portal: connected Lovable project `VineTrack Portal` id `9b5a08c7-4e98-403e-aabb-9adeb50cdc93`, source revision `9f7b647d3472dc910c631fdf6a6163daad313521`, initial file inventory/read of `src/components/trips/TripDetailSheet.tsx`, `ManageTrip.tsx`, `src/components/spray/SprayTripWorksheet.tsx`, `src/components/spray/wizard/SprayJobWizard.tsx`. **Portal CRUD serializers/endpoints and Report RPC projections are not yet certified.** Portal is separately versioned; it must be pinned alongside both mobile builds and backend schema.
- Released iOS/Android **3.1.8 exact signed-binary source + frozen original writer payloads are NOT verified**. `sync-compatibility-register.json` explicitly says `released_318_source_verified=false`, `native_319_acceptance_complete=false`. No GitHub release evidence resolved the exact 3.1.8 binaries. Do **not** simulate old-client compatibility with the current 3.1.9 serializers; obtain signed 3.1.8 fixture captures without secrets.
- Historical active production data/actuals were **not** changed to validate test behaviour. Use rollback-only authenticated server tests in a controlled schema/test tenant and actual signed-device tests for certification.

## 1. Audit unit — every user action, not just a table

For **each of 26 registry domains** enumerate every Create, Update, Delete, Confirm, Finish, Pause, Resume, Reopen, Switch Vineyard, import, and background refresh action, when applicable. Each action record must map:

```
UI trigger / input fields / explicit user confirmation
 → validation + calculated vs operator-entered distinctions
 → immutable local snapshot + account-incarnation fence + stable entity/operation ID
 → outbox/journal bytes and crash/restart recovery
 → iOS wire encoder and Android wire serializer (both old 3.1.8 and new 3.1.9)
 → RPC/REST endpoint, accepted argument names, SQL defaults, RLS, checks, triggers and actual result
 → receipt and exact original-revision readback (ack not just HTTP 200)
 → Portal reader/writer, iOS decoder, Android decoder and merge rules
 → offline, switch, conflict, old-device replay, tombstone and finished UI status
```

**Field inventory for each node:** semantic identity, wire key, SQL type, JSON nesting/array shape, unit, finite/range rule, enum version, timezone/precision, absent vs explicit `null` vs zero, default, original/planned/actual, required vs optional, authority, merge/concurrent revision, source-code lines, tests and exact result. A field is not 'compatible' merely because a DB column exists or a local object can decode. Include media Storage keys and delete receipts in graph.

Status vocabulary: `CONFIRMED_MISMATCH` (a real incompatible pure wire shape or server validator), `CONFIRMED_SOURCE_RISK` (observable source path that can lose/reject data, but reproduction not yet proven), `PARTIAL_SOURCE_REVIEW`, `UNVERIFIED`, `PASS_SOURCE_ONLY`, `PASS_CONTROLLED_BACKEND`, `PASS_ORIGINAL_DEVICE`, `PASS_CROSS_DEVICE`. **Nothing is release-certified yet.**

## 2. First field-level findings — live source vs database

### P0-F01: iOS Tank Actual chemical `null` versus omitted key — CONFIRMED_MISMATCH

- Backend `public.validate_spray_tank_actual_chemicals(jsonb)` checks each chemical line has keys `id`, `plannedChemicalId`, `savedChemicalId`, `name`, `actualAmountBase`, `unit`. It permits **JSON null** ID values but **rejects omission** of either key. CHECK constraint `spray_tank_actuals_chemicals_contract_check` and `upsert_spray_tank_actual` both enforce the function.
- iOS `ios/VineTrack/LegacyImported/Models/SprayTankActual.swift` defines `SprayTankActualChemical: Codable` with optional UUIDs `plannedChemicalId`, `savedChemicalId` and no custom encode(to:); Swift synthesised optional encoding omits nil. `ios/VineTrack/Backend/Sync/SprayTankActualStore.swift` `SprayTankActualUpsertRequest` encodes the chemicals array without forcing these two JSON keys to explicit `null`.
- Android `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/model/SprayTankActual.kt` declares those as nullable with default null; its actual serialized output/null policy under configured `SupabaseClient.json` requires a **captured real writer fixture**, not inference from the Kotlin declaration.
- Pure SQL check with synthetic UUIDs returned **false** when `savedChemicalId` was omitted; returned **true** when explicitly `"savedChemicalId":null`. No DB writes.
- User-visible risk: iOS confirmation of a separately added product, substitution or planned line with absent optional linkage can fail upload despite valid local operator amounts. Test ALL 3 usage kinds and both optional keys, not only a typical planned product. **Do not relax validation or overwrite existing original quantities without contract review.**
- Remediation candidate: explicit cross-platform canonical `SprayTankActualChemical` JSON codec producing both nullable keys, plus server backward acceptance of legacy omission when *semantically safe*. Decide whether omission can be canonicalised to null by a versioned server adapter; preserve audit provenance. Verify old-client compatibility with actual 3.1.8 writer fixtures.

### P0-F02: Android-only Tank Actual chemical evidence fields — CONFIRMED_SOURCE_RISK

- Android `SprayTankActualChemical` additionally has `productCategory`, `physicalForm`, `snapshotAt`; iOS `SprayTankActualChemical` has none. Names including `plannedChemicalId`, `savedChemicalId`, `usageKind`, `actualAmountBase` are otherwise near-equivalent with UUID/String and enum units to check.
- Server `spray_tank_actuals.chemicals jsonb` can store extra attributes, but live `upsert_spray_tank_actual` replaces the WHOLE `chemicals` array on conflict if eligible. An iOS read/encode/edit after an Android write could erase unknown provenance. **Not yet device-reproduced**. A newer-version read-only client must not rewrite nested fields it cannot represent.
- Remediation: preserve unknown JSON fields on decode and write, or limit app corrections to independently versioned explicit patches with server-owned retention of unknown keys; test Android→Server→iOS→Server→Android exact JSON equality and corrective workflows.

### P0-F03: Tank Actual update concurrency uses device wall clocks — CONFIRMED_SOURCE_RISK

- Live function MD5 `afcbc340565f6917ec48245998808ca6` for `upsert_spray_tank_actual`; `ON CONFLICT(trip_id,tank_session_id) DO UPDATE SET water_volume_l=excluded.water_volume_l, chemicals=excluded.chemicals, confirmed_at=excluded.confirmed_at, client_updated_at=excluded.client_updated_at ... WHERE correction_version=0 AND excluded.client_updated_at >= existing.client_updated_at`.
- This is **not** a server-authoritative revision compare, and an older or clock-skewed device could win or silently fail while a reply still returns another row. The existing `docs/sync-concurrency-contract.md` warns against device clock authority; sql/198 protected other specific tables, **not this actual RPC**.
- Need exact original submit-and-ack tests (including a NEWER local edit after an older HTTP response; negative clock skew; equal timestamps; correction_version>0). Preserve original operator-entered quantities and approved amendments; design a compatible CAS or immutable base actual + separate correction receipt without dropping 3.1.8 clients.

### P0-F04: 14 mobile Spray Planning wire fields absent as SQL columns — CONFIRMED_SCHEMA_GAP / conditional writer risk

- iOS `ios/VineTrack/App/SprayEngine/SprayPlanningWireFields.swift`, `BackendSprayRecordUpsert+Encoding.swift`; Android `android-vinetrack/.../data/spray/SprayPlanningWireFields.kt`, `SprayRecordRepository.kt` declare the v2 tuple:
  `sprayer_configuration`, `spray_planning_method`, `full_tank_specification`, `planning_input_provenance`, `planning_intended_tank_litres`, `planning_target_area_ha`, `planning_calibrated_litres_per_hectare`, `planned_application_area_ha`, `resolved_planning_carrier_litres`, `resolved_planning_litres_per_hectare`, `resolved_planning_physical_row_litres_per_100m`, `resolved_planning_concentration_factor`, `controller_litres_per_100m_travel`, `effective_working_width_metres`.
- **None** is a current `public.spray_records` column (read-only catalog query). The supported By Area branch normally uses `LegacySpraySetup.notes` to append a versioned JSON block in the existing `notes` field; this fallback is implemented in both apps. Other branches in `SprayPlanningWireFields.encode`/ `.merging` can emit the new column names (e.g. explicit clear/template), potentially rejected by PostgREST. This is **not proven to affect the successful By Area route**.
- Required matrix: old/no-planning, new By Area, full tank blocked, template, explicit clear, edit old record, plus future read-and-resave, with actual PostgREST body/DB readback; establish whether supported plan must remain notes-based, or deploy additive nullable backend columns first under safe old-client policy. Never infer old clients will preserve new column values on whole-row upsert.

### P0-F05: Completion, Trip session and route dependency contract — PARTIAL SOURCE + LIVE ACCEPTANCE OF ONE TRIP

- DB `trips`: 50 columns including `occurrence_coverage jsonb`, `row_sequence jsonb`, `tank_sessions jsonb`, `path_points jsonb`, `completed_paths`, `skipped_paths`. `spray_records`: 56 columns. `spray_tank_actuals`: 19 columns. `trip_occurrence_operations` original IDs/receipts.
- Android `TripRepository.kt` has distinct `TripInsert`, `ImportedTripInsert`, `TripMetadataPatch`, `TripStartPatch`, `TripEndPatch`, `TripProgressPatch`, `TripRowPlanPatch`, `TripCoveragePatch`; `TripStartSync`, `TripTankSync`, `ScopedTankActualSync`, `TripEndSync` and `TripOccurrenceJournal` are separate replay contracts. **Do not use a single 'Trip DTO matches all' assertion**; the correct comparison is per verb/operation.
- iOS `BackendTripUpsert` and `SupabaseTripSyncRepository` with occurrence RPC; separate `TripSyncService`, `SprayRecordSyncService`, `SprayTankActualStore` and legacy `TripTrackingService`. Entry review from `SprayTripStartConfirmationSheet.swift`.
- Live original Android Trip `b1dd59ab-ff1b-4ff4-9af6-a9688425db22` accepted original parent create/activate, original Tank session `fdb6a4b8-5cbf-41a9-a780-816a5e5fa401`, original Tank actual `c4b5f982-e3e9-467d-9067-e36736699026` (water 670 L, one chemical line), and original finalise `fff1638c-ac5f-4546-bc1f-c74026b03c2f`. One observed recovery is **not** a cross-platform pass, not a guarantee of matching chemical amount, and not proof of all old writers.
- Live `create_trip_with_occurrences_v1` MD5 remains `b0e166d78be75c8ba770b2dccfd14256` (owner `vinetrack_occurrence_writer`, known separately gated UUID/setup scope fix in PR #31). Full signature, payload field whitelist and accepted JSON `occurrence_coverage` need exact Swift/Kotlin frozen request comparison. Owner-only deployment separate.
- Server `spray_records.trip_id` lacks direct FK, while actuals reference BOTH Trip and Spray and have cascade delete; cancellation and retention must follow `TRIP_DELETION_CASCADE_CONTRACT_V1.md`.

### P0-F06: Historical queue and progress diagnostics — KNOWN UNSOLVED

- iOS build 201: four old pending Trip uploads (one cross-vineyard, several deleted/never accepted) and two initial-mix handoffs; iOS `TripSyncService` globally considers selected-slice absences as failed 'orphan' upserts. Needs exact original account/vineyard/op-vs-server tombstone receipt reconciliation; do not assume iOS build 201 fixed this by legacy containment.
- Android build 1793590250: zero ordinary pending outbox items, **but** old `LEGACY_ORIGINAL_HELD` original Trip `d9604cde-1544-47e2-b3d1-8d7f1361128a`/Spray `1b69e888-6a97-4d31-8fbb-ae047a0aff9d` still needs a receipt and operator decision. Issue #42. Zero queue != full sync.
- Neither platform records fully durable whole-sweep/upload-clear acknowledgement in the current retained diagnostic. Full sweep must state per-domain end revision, held-original counts and exact receipt, not just a latest download time.
- `TripClosureStatus` current source is a derived display evaluator, not a standalone proof that all service operations and Portal data match. Do not release based solely on the badge.

## 3. Source path matrix for the first operational flow

| Stage/action | iOS producer / local | Android producer / local | Endpoint/server and Portal | Audit state |
|---|---|---|---|---|
| Guided selection / chemical/area/rate | `SprayTripSetupSheet.swift`, `SprayPlanningWireFields.swift`, `BackendSprayRecordUpsert+Encoding.swift` | `SprayTripSetupScreen.kt`, `SprayCalculatorScreen.kt`, `SprayPlanningWireFields.kt` | `spray_jobs`, `spray_records`; Portal `SprayJobWizard.tsx` | partial; v2 planning non-column risk |
| Review and operator actual confirmation | `SprayTripStartConfirmationSheet.swift`, `SprayInitialTankAmounts`, `SprayStartRateReview.swift` | `SprayTripStartConfirmation.kt`, `SprayStartActualFields.kt`, `SprayStartActualAmounts` | immutable planned recipe versus separately confirmed `spray_tank_actuals` | partial; needs frozen fixture |
| Prepare/create Trip/occurrence | `TripTrackingService.swift`, `TripOccurrenceJournal.swift`, `SupabaseTripSyncRepository.swift` | `AppViewModel.kt`, `TripStartSync.kt`, `TripOccurrenceJournal.kt`, `TripRepository.kt` | `create_trip_with_occurrences_v1`, `trip_occurrence_operations`, `trips` | partial; RPC owner fix pending |
| Store/activate Trip | `TripTrackingService.swift`, `TripSyncService.swift` | `TripStartSync.kt`, `ActiveTripStore.kt` | `activate_trip_occurrences_v1` | partial |
| Link/freeze Spray Record | `SprayRecordSyncService.swift`, `BackendSprayRecordUpsert` | `SprayRecordRepository.kt`, `SprayRecordCreateSync.kt` | `spray_records` + linked `trip_id`; Portal reads linked Trip | partial |
| Start Tank 1 (atomic local chain) | `StartTankCommitCoordinator.swift`, `SprayTankActualStore.swift` | `StartTankCommitCoordinator.kt`, `SprayTankActualStore.kt`, `TripTankSync.kt` | `trips.tank_sessions` | partial; original-session survival essential |
| Upload operator actuals | `SprayTankActualUpsertRequest` / `SprayTankActualStore.syncPending` | `SprayTankActualRepository.kt`, `ScopedTankActualSync.kt` | `upsert_spray_tank_actual`, `spray_tank_actuals` | **P0-F01/F02/F03** |
| GPS/route/row/fuel | `TripTrackingService.swift`, `TripSyncService.swift` | `TripGpsSync.kt`, `TripRowSync.kt`, `TripMetadataSync.kt` | `trips.path_points`, `occurrence_coverage` | unverified field equality and partial-job logic |
| End/close, labour | `TripEndGate.swift`, `TripLabourSnapshotJournal.swift`, `TripClosureStatus.swift` | `TripEndSync.kt`, `TripLabourSnapshotSync.kt`, `TripClosureStatus.kt` | `finalize_trip_occurrences_v1`, `trip_cost_allocations` and readback | partial; snapshot cost vs labour receipt |
| Read on other device / Portal | `BackendTrip`, `BackendSprayRecord`, `SprayTankActualStore` | `TripRepository.fetchTrip`, `SprayRecordRepository`, `SprayTankActualRepository` | Portal `src/components/trips/TripDetailSheet.tsx`, `src/components/spray/SprayTripWorksheet.tsx` reads `get_spray_report_v1` for canonical worksheet | first source read only; not certified |
| Cancel/Delete/recover old | `TripActivityCancellationService.swift`, `TripDeletionJournal.swift` + legacy queue | `TripActivityCancellation.kt`, `LegacySpraySaveStore.kt`, original journal | `cancel_trip_activity_v1` / protected compliance archive, historical soft delete separate | incomplete iOS and Android old records |

This table describes actual identified source files, **not** proof of every state transition or field mapping.

## 4. Required audit order, domain coverage and work divisions

**Gate 0 (must be resolved before any app release):** freeze exact binary/source receipts for currently installed builds iOS 3.1.8/3.1.9, Android 3.1.8/3.1.9 and live Portal commit; capture actual 3.1.8 read/write payload shapes and local persisted snapshots. Confirm existing production schema, API grants, RLS, triggers, RPC function hashes and returned fields. No deprecation floor or destructive migration.

**Gate 1 — P0 operational core (audit full field coverage, then fix):** `trip`, `trip_occurrence`, `spray_job`, `spray_record`, `tank_session`, `tank_actual`, `chemical_store`, `chemical_catalogue`, `equipment`, `tractors`, `machines`, `account_vineyard_access`, `blocks_geometry`. Include all user actions, every nested JSON member and every outbox stage, plus correction/deletion/legacy start. Explicit iOS/Android/RPC/Portal traces required.

**Gate 2 — mobile operational records:** `pin`, `work_tasks`, `yield` (original bunch-per-vine and System Admin quadrant method), `pruning`, `growth`, `maintenance`, `fertiliser`, `images_documents`, `other_mobile_queues`; examine existing photo/Storage and soft-delete dependencies. One per-domain report with exact fixtures and authenticated readback.

**Gate 3 — supporting/stateful services:** `irrigation`, `weather`, `settings_preferences`, `entitlement` and imported/MAIT/provider relationships. Not every backend-owned or read-only provider model is mobile-bidirectional; distinguish supported operations from unsupported ones. Verify regional rates/units/timezones, expired trial read-only local queues and Portal sync.

All **26** rows of the existing registry remain `unverified` until the respective actual old/new device and backend evidence passes; **do not change their status merely because the code file is found**.

## 5. Mandatory compatibility test matrix (every domain and every action)

| Matrix axis | Cases that MUST run |
|---|---|
| Old to new | Frozen iOS 3.1.8 -> current server -> Android 3.1.9 and Portal; Android 3.1.8 -> server -> iOS 3.1.9; older persisted journal in-place upgrade |
| New to old | iOS 3.1.9 and Android 3.1.9 -> current server -> 3.1.8 reader, AND **3.1.8 writer after 3.1.9 fields**, no loss of unknown data |
| Normal actions | Create, update, delete/tombstone, import, pause/resume/finish, actual confirmation, complete/reopen/cancel as applicable |
| Wire fields | Required/optional, omitted/null/zero, old/new enum values, nested unknown JSON, unit precision/round-trip, UUID canonicality, timestamp UTC precision, large records, JSON arrays |
| Failure/recovery | Offline/online, process death every journal step, server accepted then response lost, duplicate request, out-of-order acks, late old write, 400/401/403/409/5xx and RLS-empty result |
| Reconciliation | Same original IDs, scoped account/vineyard, per-record receipt plus fresh readback, no future-field loss, no cross-vineyard corruption; other device and Portal fetch in both directions |
| Performance | Small/large vineyard pages and many pending records, bounded retry, batch and memory constraints, full-sweep receipts |
| Security/compatibility | Operator/supervisor/manager/owner permissions, account switch, expired trial, original claimant, new cancellation tombstone rejects old resurrection |
| Release | signed source SHA + exact backend hash, native old binaries, actual devices, evidence and independently verified Portal result |

**No tests of production write acceptance against live customer records.** Use controlled seeded test vineyard plus rollback-only SQL for validation; any server migration needs separate review and deployment authority. No force stop, no journal clearing, no blanket hard-delete.

## 6. Correction governance and acceptance checklist

1. Record the exact failing **source-version / operation / original request JSON** with confidential values redacted and wire-shape unchanged. Compare iOS vs Android encoding, old vs new signed binary, current Portal reader, DB schema and SQL function code/privileges.
2. Annotate `PASS`, `MISMATCH`, `UNKNOWN` for **each wire field and each action transition**; include null/omission precision, default, old-client behavior and actual/readback receipts.
3. Separate **deployed-backend-first additive compatibility migrations** from device fixes. Do not tighten old required fields or silently collapse missing to 0; for unknown future JSON prefer lossless read-only or patch with server-side preservation.
4. Add **golden fixture contract tests** executed by native Swift/Kotlin serializers using a shared JSON expected response (not hand-constructed payloads): old iOS, old Android, current iOS, current Android, Portal. Validate payloads at the actual RPC/REST boundary; reject any fixture mismatch in CI.
5. Create a source-to-field ownership matrix: input authority, writer, server normalisation, latest revision, readable legacy representation and deletion lineage. Every changed field triggers the contract test gate for every affected reader/writer.
6. Add CI gating to the actual default branch pipeline, then verify it runs and rejects a deliberately incompatible synthetic change. A script sitting only in PR #38 is NOT enforced CI.
7. Mark a domain **VERIFIED** only after exact build/version receipt, all its CRUD/verb tests, old→new and new→old native serializer tests, server/RLS readback and iOS↔Android↔Portal signed-device convergence. Promote by domain with durable evidence; block release while mandatory domain coverage is incomplete.
8. Re-run the full Trip/Spray/Tank action matrix after **any** changes to a shared dependency, including schema, chemical catalogue fields, sync queue, UI action, RLS, Server RPC or Portal forms.

## 7. Next evidence required (not yet available)

- Actual **3.1.8 signed source/serializer and local-store fixtures** for iOS and Android (not 3.1.9 reconstructive tests); verified signing/source receipt mapping.
- Complete authored/current **iOS/Android golden payloads for all 26 domains** and full Portal TypeScript field/RPC mappings. This first audit traced the critical operations, not every field of every screen.
- Controlled backend versioned compatibility/readback test runs, including security and applied migration state (no writes in this audit).
- **Instrumented original-device** and authenticated Portal end-to-end checks, including missing-account and cross-vineyard journal recovery.
- Owner-reviewed corrections and shared domain-level sign-off before lifting production release hold.

**Release conclusion:** current contract registry 26/26 unverified. P0-F01 is a real validator/codec representation mismatch; P0-F02/03/04 are confirmed source/schema hazards requiring actual writer-path reproduction; iOS historical queue and Android legacy hold remain unresolved. The correct response is a bounded, auditable domain-by-domain certification programme, **not** another assertion that one patched sync route is safe.
