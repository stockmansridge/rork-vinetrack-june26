# Android Offline Field Reliability / Offline Write Queue — Status Note

Internal status tracker for the Android (`android-vinetrack`) Field Reliability /
Offline Write Queue work. No Supabase schema/RLS changes were made by any stage
below. iOS / Lovable remain the source of truth for parity, and all changes are
additive and compatible with existing server-generated records.

---

## Closure state

| Stage | Scope | Status |
|---|---|---|
| 4A-i | Connectivity observer, offline banner, placeholder Sync Status screen. | **CLOSED** |
| 4A-ii | Inert pending-write outbox skeleton. | **CLOSED** |
| 4A-iii | Client-generated UUIDs for pin creation, online-only. | **CLOSED** |
| 4A-iv | Queued non-destructive pin creation only. | **CLOSED** |
| 5 | Offline domain cache audit (read-only, no code change). | **CLOSED** |
| 6A | Offline read cache foundation, write-through only. | **CLOSED** |
| 6B | Cached offline launch — vineyard list, selected-vineyard paddocks/blocks, and selected-vineyard pins. | **CLOSED** |
| 7A | Pin photo upload/retry audit (read-only, no code change). | **CLOSED** |
| 7B | Persist pending pin photo attachment locally, no upload retry. | **CLOSED** |
| 7C | Upload pending pin photos after pin sync, pin-photo-only retry. | **CLOSED** |
| 8 | Sign-out cleanup hygiene for offline reliability data. | **CLOSED** |
| 9 | Offline pin update / complete / delete audit (read-only, no code change). | **CLOSED / AUDIT ONLY** |
| 9A-prereq | Narrow pin completion write shape (completion-only PATCH). | **CLOSED** |
| 9A | Offline pin completion toggle queue (completion-only queue + replay). | **CLOSED** |
| 9B-1 | Decode/preserve pin conflict metadata (model + cache, no write change). | **CLOSED** |
| 9B-2 | Send `client_updated_at` on normal online pin edits (online edit-path only). | **CLOSED** |
| 9B-3 (design) | Offline pin text/category/mode edit queue design audit (no implementation). | **CLOSED / DESIGN ONLY** |
| 9B-3 | Offline descriptive pin edit queue (title/notes/category/mode queue + replay). | **CLOSED** |
| Tier-A audit | Trip / GPS / row / tank replay audit (read-only, no code change). | **CLOSED / AUDIT ONLY** |
| Tier-A Stage A | Local active-trip persistence only (durable on-device snapshot, no replay). | **CLOSED** |
| Tier-A Stage B (design) | Trip start/end/metadata queue audit/design (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage B-1 | Trip metadata/pause/start-engine-hours queue for existing active server trips (queue + replay). | **CLOSED** |
| Tier-A Stage C (design) | GPS breadcrumb event log/replay audit/design (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage C-1 | Coalesced TRIP_GPS marker + GPS/path replay for existing active server trips (queue + replay). | **CLOSED** |
| Tier-A Stage D (design) | Row coverage replay (done/skip/undo) audit/design (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage D-1 | Coalesced TRIP_ROW marker + row coverage replay for existing active server trips (queue + replay). | **CLOSED** |
| Tier-A Stage E (design) | Tank/fill/engine-hour replay audit/design (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage E-1 | Coalesced TRIP_TANK marker + tank/fill replay for existing active server trips (queue + replay). | **CLOSED** |
| Tier-A Stage B-2 (design) | Trip-end summary queue audit/design (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage B-2-1 | Lightweight TRIP_END marker + dependency-gated trip-end replay for existing active server trips (queue + replay). | **CLOSED** |
| Tier-A Stage B-3 (design) | Offline trip start / provisional-trip reconciliation audit/design (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage B-3-1 | Offline trip start with client-generated final trip id, local provisional active trip, and dependency-ordered TRIP_START replay. | **CLOSED** |
| Tier-A Stage F (design) | Sync Status / blocked recovery UX audit/design (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage F-1 | Sync Status display/state clarity only (derived display states, dependency-aware labels, friendly error text — display only, no actions). | **CLOSED** |
| Tier-A Stage F-2 | Sync Status global Retry all action for retryable/deferred pending rows, routed through the existing ordered replay pipeline (no destructive actions). | **CLOSED** |
| Tier-A Stage F-3 | Sync Status blocked-item details and copy diagnostics — tappable read-only details sheet + clipboard diagnostics (no retry/dismiss/destructive actions). | **CLOSED** |
| Tier-A Stage F-2b | Sync Status per-item retry for eligible failed pending-write rows, routed through the existing ordered replay pipeline (no destructive actions). | **CLOSED** |
| Tier-A Stage G-0 (design) | Delete / soft-delete queueing audit/design — offline delete strategy, marker shapes, dependency gates, idempotency, and staged plan (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage G-1 | Pin soft-delete queue — offline/transient pin delete via `PIN` / `DELETE` marker and `PinDeleteSync`, local-only create cancellation, dependency-gated replay, safe pending-photo handling (no trip/hard delete, no destructive recovery). | **CLOSED** |
| Tier-A Stage G-2 | Trip delete queue for ended trips — offline/transient trip soft-delete for ended/inactive trips with no unresolved same-trip markers via `TRIP` / `DELETE` marker and `TripDeleteSync`, dependency-gated replay (no active-trip offline delete, no hard delete, no destructive recovery). | **CLOSED** |
| Tier-A Stage H-0 (design) | Fuel logs offline queue / retry audit/design — current online-only create/update/delete flows mapped, server write shape, data model, offline risks, marker design (`FUEL_LOG` + `CREATE`/`UPDATE`/`DELETE`), per-op strategies, Sync Status/retry UX, and staged plan (no implementation). | **CLOSED / DESIGN ONLY** |
| Tier-A Stage H-1 | Fuel-log create queue — offline/transient fuel-log create via `FUEL_LOG` / `CREATE` marker and `FuelLogCreateSync`, client-generated ids for idempotent replay, optimistic insert into `AppUiState.fuelLogs` (update/delete remain online-only). | **CLOSED** |
| Tier-A Stage H-2 | Fuel-log update queue — offline/transient fuel-log edit via `FUEL_LOG` / `UPDATE` marker and `FuelLogUpdateSync`, edit-before-create folding into the pending create payload, latest-wins coalescing per fuel-log id, optimistic edit of `AppUiState.fuelLogs` (delete remains online-only). | **CLOSED** |
| Tier-A Stage H-3 | Fuel-log delete queue — offline/transient fuel-log soft-delete via `FUEL_LOG` / `DELETE` marker and `FuelLogDeleteSync`, local-only pending-create cancellation, dependency-gated replay behind same-log create/update, coalesced one-marker-per-id, optimistic remove from `AppUiState.fuelLogs`. | **CLOSED** |
| Tier-A Stage H-4 | Fuel-log QA/UX/Sync Status polish audit — read-only audit of the fuel-log create/update/delete offline queue triad (coordinators, ViewModel write paths, Sync Status labels/details, replay ordering, coordinator isolation, cache/refresh, role/permission UX, wording); no correctness bugs found, no app code changed. | **CLOSED / AUDIT ONLY** |
| Tier-A Stage H-5 | iOS/Android parity checkpoint — read-only cross-platform audit of offline queue behaviour, Sync Status/pending-outbox UX, pins, pin photos, trips, trip/pin delete, fuel logs, maps, and role/permission UX after Android fuel-log offline queue completion; parity matrix + gap report + recommended next slices produced, no app code changed. | **CLOSED / AUDIT ONLY** |
| Stage I-0 | Spray-record offline queue audit/design — current online-only spray create/update/delete flows mapped against the iOS dirty-tracking benchmark, server contract (client-generated id + `client_updated_at`), single-atomic-record-with-embedded-tanks model, marker design (`SPRAY_RECORD` + `CREATE`/`UPDATE`/`DELETE`), and staged plan (no implementation). | **CLOSED / DESIGN ONLY** |
| Stage I-1 | Spray-record CREATE offline queue — offline/transient plain spray create via `SPRAY_RECORD` / `CREATE` marker and `SprayRecordCreateSync`, id + `clientUpdatedAt` minted before network, optimistic insert into `AppUiState.sprayRecords`, idempotent replay (trip-coupled variants remain online-only). | **CLOSED** |
| Stage I-2 | Spray-record UPDATE offline queue — offline/transient spray edit via `SPRAY_RECORD` / `UPDATE` marker and `SprayRecordUpdateSync`, edit-before-create folding into the pending create payload, latest-wins coalescing per spray-record id, dependency-gated replay behind same-id create. | **CLOSED** |
| Stage I-3 | Spray-record DELETE offline queue — offline/transient spray soft-delete via `SPRAY_RECORD` / `DELETE` marker and `SprayRecordDeleteSync`, local-only pending-create/update cancellation, dependency-gated replay behind same-id create/update, coalesced one-marker-per-id, optimistic remove from `AppUiState.sprayRecords`. | **CLOSED** |
| Stage I-4 | Spray-record QA/UX/Sync Status polish + trip-coupled create decision — read-only audit of the spray create/update/delete offline queue triad (lifecycle, replay ordering, Sync Status labels/details/diagnostics, failure/permission handling, export/cost/calculator tolerance, cache/read posture) plus trip-coupled create decision; no correctness bugs found, no app code changed. | **CLOSED / QA ONLY** |
| Stage I (overall) | Spray-record plain create/update/delete offline queue. | **CLOSED** |
| Stage J-0 | Work-task offline queue audit/design — dependent header + labour/machine line model mapped, marker shapes, parent dependency gates, and staged plan. | **CLOSED / DESIGN ONLY** |
| Stage J-1 | Work-task header CREATE offline queue (`WORK_TASK` / `CREATE` + `WorkTaskCreateSync`, client id + `client_updated_at` minted before network, optimistic insert, idempotent replay). | **CLOSED** |
| Stage J-2 | Work-task header UPDATE / finalize-reopen offline queue (`WORK_TASK` / `UPDATE` + `WorkTaskUpdateSync`, edit-before-create folding, latest-wins coalescing, same-id create deferral). | **CLOSED** |
| Stage J-3 | Work-task header DELETE offline queue (`WORK_TASK` / `DELETE` + `WorkTaskDeleteSync`, local-only create/update cancellation, dependency-gated replay, coalesced one-marker-per-task). | **CLOSED** |
| Stage J-4 | Work-task labour line CREATE/UPDATE/DELETE offline queue (`WORK_TASK_LABOUR` + `WorkTaskLabourSync`, parent dependency gate, edit-before-create folding, delete-before-create cancellation, header-delete child cleanup). | **CLOSED** |
| Stage J-5 | Work-task machine line CREATE/UPDATE/DELETE offline queue (`WORK_TASK_MACHINE` + `WorkTaskMachineSync`, parent dependency gate, folding/coalescing/cancellation, header-delete child cleanup). | **CLOSED** |
| Stage J-6 | Work-task offline queue QA/UX polish + synced-delete child-marker sweep (lifecycle matrix, replay ordering, dependency gates, Sync Status labels/diagnostics, synced work-task delete now sweeps unresolved same-task labour/machine markers). | **CLOSED** |
| Stage J-7 | Work-task offline queue documentation closure + parity checkpoint (this note). | **CLOSED / DOC ONLY** |
| Stage J (overall) | Work-task header + labour line + machine line create/update/delete offline queue. | **CLOSED** |
| Stage K-0 | Maintenance offline queue audit/design — current online-only maintenance create/update/delete flows mapped against the iOS dirty-tracking benchmark, server contract (client-generated id + `client_updated_at` + soft delete), single-record-no-child-table model, marker design (`MAINTENANCE_LOG` + `CREATE`/`UPDATE`/`DELETE`), and staged plan (no implementation). | **CLOSED / DESIGN ONLY** |
| Stage K-1 | Maintenance log CREATE offline queue — offline/transient maintenance create via `MAINTENANCE_LOG` / `CREATE` marker and `MaintenanceLogCreateSync`, id + `clientUpdatedAt` minted before network, optimistic insert into `AppUiState.maintenanceLogs`, idempotent replay (update/delete remain online-only). | **CLOSED** |
| Stage K-2 | Maintenance log UPDATE offline queue — offline/transient maintenance edit via `MAINTENANCE_LOG` / `UPDATE` marker and `MaintenanceLogUpdateSync`, edit-before-create folding into the pending create payload, latest-wins coalescing per log id, dependency-gated replay behind same-id create. | **CLOSED** |
| Stage K-3 | Maintenance log DELETE offline queue — offline/transient maintenance soft-delete via `MAINTENANCE_LOG` / `DELETE` marker and `MaintenanceLogDeleteSync`, local-only pending-create/update cancellation, dependency-gated replay behind same-id create/update, coalesced one-marker-per-id, role-aware blocking for operators who cannot soft-delete. | **CLOSED** |
| Stage K-4 | Maintenance offline queue QA/UX polish — read-only audit of the maintenance create/update/delete offline queue triad (lifecycle matrix, replay ordering, folding/coalescing/cancellation, payload/security, role/permission/failure handling, Sync Status labels/details/diagnostics, UI/cost/equipment display); no correctness bugs found, no app code changed. | **CLOSED / QA ONLY** |
| Stage K-5 | Maintenance offline queue documentation closure + parity checkpoint (this note). | **CLOSED / DOC ONLY** |
| Stage K (overall) | Maintenance log create/update/delete offline queue. | **CLOSED** |
| Stage L-0 | Yield offline queue audit/design — current online-only yield create/update/delete flows mapped against the iOS dirty-tracking benchmark, server contract (client-generated id + `client_updated_at` + soft delete), single-record-with-embedded-block-results model, marker design (`YIELD_RECORD` + `CREATE`/`UPDATE`/`DELETE`), and staged plan (no implementation). | **CLOSED / DESIGN ONLY** |
| Stage L-1 | Yield record CREATE offline queue — offline/transient yield create via `YIELD_RECORD` / `CREATE` marker and `YieldRecordCreateSync`, id + `clientUpdatedAt` + block-result ids minted before network, optimistic insert into yield list, idempotent replay across both actual and estimate create paths (update/delete remain online-only). | **CLOSED** |
| Stage L-2 | Yield record UPDATE offline queue — offline/transient yield edit via `YIELD_RECORD` / `UPDATE` marker and `YieldRecordUpdateSync`, edit-before-create folding into the pending create payload, latest-wins coalescing per yield-record id, dependency-gated replay behind same-id create, covering both actual and estimate update paths. | **CLOSED** |
| Stage L-3 | Yield record DELETE offline queue — offline/transient yield soft-delete via `YIELD_RECORD` / `DELETE` marker and `YieldRecordDeleteSync`, local-only pending-create/update cancellation, dependency-gated replay behind same-id create/update, coalesced one-marker-per-id, role-aware blocking for operators who cannot soft-delete. | **CLOSED** |
| Stage L-4 | Yield offline queue QA/UX polish — read-only audit of the yield create/update/delete offline queue triad (lifecycle matrix, replay ordering, folding/coalescing/cancellation, payload/security, role/permission/failure handling, Sync Status labels/details/diagnostics, UI/cost-per-tonne/report tolerance); no correctness bugs found, no app code changed. | **CLOSED / QA ONLY** |
| Stage L-5 | Yield offline queue documentation closure + parity checkpoint (this note). | **CLOSED / DOC ONLY** |
| Stage L (overall) | Yield record create/update/delete offline queue. | **CLOSED** |
| Stage M-0 | Damage records offline queue audit/design — found Android has **no damage record feature at all** (no model, repository, read path, screen, AppViewModel state, or online create/update/delete path); the only `damage` reference is the unrelated yield-estimation `damageFactor`. Damage records exist on iOS + Supabase only. An offline queue would require building the full Android damage feature first, which is outside the offline-parity cadence. | **PARKED / DESIGN ONLY** |
| Stage N-0 | Growth-stage records offline queue audit/design — current online-only growth create/update/delete + photo flows mapped against the iOS dirty-tracking benchmark, server contract (client-generated id + `client_updated_at` + `soft_delete_growth_stage_record` RPC), single-record-with-photo-paths model, marker design (`GROWTH_RECORD` + `CREATE`/`UPDATE`/`DELETE`, photo upload parked), and staged plan (no implementation). | **CLOSED / DESIGN ONLY** |
| Stage N-1 | Growth-stage record CREATE offline queue — offline/transient growth create via `GROWTH_RECORD` / `CREATE` marker and `GrowthRecordCreateSync`, id + `clientUpdatedAt` minted before network, optimistic insert into the growth list, idempotent replay, direct Android records remain `pin_id = null` (update/delete/photos remain online-only). | **CLOSED** |
| Stage N-2 | Growth-stage record UPDATE offline queue — offline/transient growth edit via `GROWTH_RECORD` / `UPDATE` marker and `GrowthRecordUpdateSync`, edit-before-create folding into the pending create payload, latest-wins coalescing per record id, dependency-gated replay behind same-id create, optimistic snapshot preserves `pinId`/`photoPaths` locally without sending them. | **CLOSED** |
| Stage N-3 | Growth-stage record DELETE offline queue — offline/transient growth soft-delete via `GROWTH_RECORD` / `DELETE` marker and `GrowthRecordDeleteSync`, local-only pending-create/update cancellation, dependency-gated replay behind same-id create/update, coalesced one-marker-per-id, role-aware blocking for operators who cannot soft-delete. | **CLOSED** |
| Stage N-4 | Growth-stage offline queue QA/UX polish — read-only audit of the growth create/update/delete offline queue triad (lifecycle matrix, replay ordering, folding/coalescing/cancellation, payload/security, role/permission/failure handling, Sync Status labels/details/diagnostics, photo boundary, UI/block-detail tolerance); no correctness bugs found, no app code changed. | **CLOSED / QA ONLY** |
| Stage N-5 | Growth-stage offline queue documentation closure + parity checkpoint (this note). | **CLOSED / DOC ONLY** |
| Stage N (overall) | Growth-stage record create/update/delete offline queue (direct Android records; photos remain online-only). | **CLOSED** |
| Stage O-0 | Offline read-cache / app-restart browsing audit/design — current Android read-cache map, app-start hydration behaviour, pending-write reconstruction feasibility, recommended local-first merge design, and staged plan (no implementation). | **CLOSED / DESIGN ONLY** |
| Stage O-1 | Pending-write restart hydration — stateless `PendingWriteOverlay` rebuilds optimistic maintenance/yield/growth rows from the existing persistent outbox after offline restart (CREATE reconstruct, UPDATE overlay-if-baseline, DELETE hide), vineyard-scoped, no second outbox, no network, no marker mutation. | **CLOSED** |
| Stage O-2 | Server snapshot cache (first family) — vineyard-scoped JSON snapshot cache for maintenance/yield/growth via extended `DomainCacheStore`/`DomainCacheRepository`, write-through only on successful server reads, offline fallback baseline for the O-1 overlay, owner-gated, cleared on sign-out. | **CLOSED** |
| Stage O-3 | Cached/offline screen integration + pending/cached UX audit — read-only audit of Maintenance/Yield/Growth screens + Block Detail growth summary rendering the cache-baseline + overlay state lists; inline banners/per-row badges parked, Sync Status remains source of truth; no code changed. | **CLOSED / QA ONLY** |
| Stage O-4 | Offline read-cache QA/UX polish — full lifecycle/cache-purity/overlay-correctness/owner-scoping/failure-edge/performance audit of the O-1/O-2 read-cache slice; no correctness bugs found, no app code changed, `runChecks` passed. | **CLOSED / QA ONLY** |
| Stage O-5 | Offline read-cache documentation closure + parity checkpoint (this note). | **CLOSED / DOC ONLY** |
| Stage O (overall) | Offline restart browsing for maintenance/yield/growth — cached server snapshots + pending-write overlays (first completed slice). | **CLOSED** |
| Stage P-0 | Remaining read-cache expansion audit/design — current read-cache state for trips/spray/fuel/work-tasks + child rows after Stage O, complexity classification, recommended next slice (fuel logs), per-family cache design, overlay feasibility, risks, and the P-stage roadmap (no implementation). | **CLOSED / DESIGN ONLY** |
| Stage P-1 | Fuel-log read-cache + pending-write overlay — vineyard-scoped server snapshot cache (`fuel_<vid>`) via extended `DomainCacheStore`/`DomainCacheRepository`, write-through only on successful server reads, in-memory→cache→empty fallback, `PendingWriteOverlay.overlayFuel` CREATE/UPDATE/DELETE overlay with id-only UPDATE/DELETE safety, no fuel-purchase/reference cache, no permission/replay mutation. | **CLOSED** |
| Stage P-2 | Spray-record read-cache + pending-write overlay — vineyard-scoped server snapshot cache (`spray_<vid>`) with nested `SprayTank` preservation, `PendingWriteOverlay.overlaySpray` CREATE/UPDATE/DELETE overlay (UPDATE replaces nested tanks from payload), no trip-coupled row invention, no template/import cache, no cost/export/report logic change, no permission/replay mutation. | **CLOSED** |
| Stage P-3 | Work-task header + labour/machine read-cache + parent-gated overlay — vineyard-scoped header cache (`worktask_<vid>`) and task-scoped labour/machine line caches (`worktask_labour_<taskId>` / `worktask_machine_<taskId>`, matching `loadTaskLines(taskId)` read granularity), header + child CREATE/UPDATE/DELETE overlays, parent gate against the final visible header set, deleted/hidden parent hides all child lines, no orphan rows, DB-generated labour totals not invented. | **CLOSED** |
| Stage P-4 | Historical-trip snapshot cache only — vineyard-scoped trip snapshot cache (`trips_<vid>`), snapshot-only with **no** pending-write overlay, no historical row reconstruction from scalar trip markers, cache written from raw server list before any restored/provisional active-trip merge, `ActiveTripStore` stays authoritative for active-trip restoration, documented TRIP_DELETE limitation. | **CLOSED** |
| Stage P-5 | Read-cache expansion QA/UX polish — audit-first lifecycle/cache-purity/overlay-correctness/parent-gate/active-historical-separation/owner-vineyard-safety/UX/performance/security audit across fuel, spray, work-task header+lines, and historical trips (plus O-stage maintenance/yield/growth regression check); no correctness bugs found, no app code changed, `runChecks` passed. | **CLOSED / QA ONLY** |
| Stage P-6 | Read-cache expansion documentation closure + parity checkpoint (this note). | **CLOSED / DOC ONLY** |
| Stage P (overall) | Offline restart browsing for fuel logs, spray records, work-task headers + labour/machine lines (overlays), and historical trips (snapshot only) — cached server snapshots + pending-write overlays where designed. | **CLOSED** |
| Stage M (overall) | Damage records offline queue. **PARKED** — Android has no damage feature yet (no model/repository/read path/screen/state/online write path); a feature build (future M-1) must precede any offline queue. | **PARKED** |

`runChecks` passed for `android-vinetrack` on each implementation slice and each
QA/closure pass.

**Milestone:** the Android offline reliability package covering Stages 4A, 5, 6,
7, and 8 can now be considered **closed**.

---

## What Android now supports

- **Live connectivity state** — online/offline tracked via Android network
  callbacks, defaulting safely to online.
- **Offline banner** — slim banner shown only when offline; copy does not promise
  queued writes beyond what is actually implemented.
- **Sync Status screen** — reachable from More → Account → Sync Status; shows
  connection status, live pending count, and explanatory copy.
- **Local pending-write outbox** — JSON-backed local store behind a repository.
- **Client-generated pin IDs** — every new pin gets a stable client UUID.
- **Offline queueing of new pin creation only** — pin creates made while offline
  (or that fail with a clear network/unavailable error) are enqueued.
- **Optimistic local pin display** — queued pins appear in the local pins
  list/map immediately so the user sees what they created.
- **Automatic pin-create replay** — triggered when connectivity flips back online
  and after a successful vineyard load when already online (post-session).
- **Idempotent replay by client UUID** — the same UUID is used for the optimistic
  pin, the pending write, the serialized payload, and the replay insert.
- **Pending item status/error display** — Sync Status reflects pending count and
  surfaces last error/status text for queued items.

### Read reliability (Stages 5 / 6A / 6B)

- **Write-through read cache** — successful online reads of the vineyard list,
  selected-vineyard paddocks/blocks, and selected-vineyard pins are saved locally.
- **Per-user cache owner separation** — cached data is scoped to the signing-in
  user id; another user cannot read the previous user's cached data.
- **Saved field data status in Sync Status** — shows whether saved field data
  exists, last saved/synced time, and saved block/pin counts for the selected
  vineyard.
- **Cached offline launch** — when live vineyard loading fails and an
  owner-matched cache exists, the app hydrates from cache and routes to a useful
  read-oriented field view instead of the hard failure screen.
- **Cached paddock/pin fallback** — when live reads of the selected vineyard's
  paddocks/pins fail and no in-memory data exists, they hydrate from cache.
- **Stale/saved-data UX** — Sync Status shows "Showing saved field data" with
  copy that saved data may be out of date until connection returns; it does not
  claim full offline mode.
- **Pin reconciliation** — cached pins merge with pending offline-created pins by
  client UUID so queued local pins stay visible and no duplicates appear.

### Pin photo retry (Stages 7A / 7B / 7C)

- **One-photo-per-pin retry flow** — a single photo per pin can now be retained
  and uploaded after the associated pin exists server-side.
- **Compress + persist on enqueue** — when a pin photo cannot be uploaded
  immediately, the photo is compressed and the JPEG saved to app-private storage,
  with pending metadata recorded in JSON-backed SharedPreferences.
- **Offline-created pins keep their photo** — a pin created offline with a photo
  persists the compressed JPEG and a pending attachment keyed to the pin's client
  UUID instead of discarding it.
- **Online-failure retention** — when online pin creation succeeds but the
  immediate photo upload fails, the compressed photo is retained as a pending
  attachment keyed by the created pin id.
- **Eventual upload** — pending photos upload once the associated pin exists
  server-side, using the deterministic Supabase Storage path
  `{vineyardId}/pins/{clientPinId}/photo.jpg`.
- **Idempotent retry** — upload uses upsert against the deterministic path, so
  repeated retries do not create orphaned/duplicate storage objects.
- **photo_path update + cleanup** — after a successful upload the pin's
  `photo_path` is updated; the local file is cleaned up and the attachment marked
  uploaded only after both the upload and `photo_path` update succeed.
- **App-state reconciliation** — the matching pin in `AppUiState.pins` is updated
  by id with the new photo path; no duplicate pin is inserted and the pending
  photo count decreases.
- **Sync Status photo counts** — pending photo count and a blocked/needs-attention
  line appear in Sync Status when relevant.

### Sign-out cleanup (Stage 8)

- **Local offline data cleared on explicit sign-out** — signing out now wipes the
  device's local offline reliability state for the signed-out account as a
  defence-in-depth measure on top of the existing owner-gating.
- **Stores cleared** — the pending write outbox, pending photo metadata, the
  app-private pending photo JPEGs under `filesDir/pending_pin_photos/`, and the
  domain read cache are all cleared.
- **In-memory state reset** — sync/cache state is reset via a fresh `AppUiState`,
  so no stale offline/cached indicators remain visible on the Login screen
  (`pendingSyncCount = 0`, `pendingSyncItems = emptyList()`,
  `pendingPhotoCount = 0`, `pendingPhotoBlockedCount = 0`, empty cache status,
  `isUsingCachedFieldData = false`, `cachedFieldDataLastSyncedAt = null`).

---

## Scope boundary

**Only these operations are queue-enabled (offline write):**

- pin create
- pin photo attachment retention + upload retry (one photo per pin, tied to the
  pin create above)

**Only these read entities are cached / hydrated for offline launch:**

- vineyard list
- selected-vineyard paddocks/blocks
- selected-vineyard pins

**These read entities are NOT cached / hydrated yet:**

- trips
- spray records
- work tasks
- fuel logs
- growth records
- maintenance records
- yield records
- operators
- members/roles
- equipment
- spray presets
- chemicals
- GPS paths
- row coverage
- tank/fill state

**These remain online-only (no offline queue / replay):**

- pin update/edit
- pin complete/toggle
- pin delete/soft-delete
- trip create/update/end
- GPS path autosave
- row Done/Skip/Undo
- tank/fill actions
- spray records
- work tasks
- fuel logs
- growth/maintenance/yield records
- JSONB array replay

---

## Architecture notes

- **`ConnectivityObserver`** — wraps `ConnectivityManager.NetworkCallback`,
  exposed as a connectivity flow; defaults to online when network state is
  unknown, unregisters cleanly, and is independent of auth/session state.
- **`PendingWrite`** — local pending-write model: `id`, `entityType`, `opType`,
  `payloadJson`, `clientId`, `createdAt`, `updatedAt`, `attemptCount`,
  `lastError`, `status` (`pending`/`in_progress`/`failed`/`blocked`/`synced`),
  with stable string constants for entity/op/status values.
- **`PendingWriteStore`** — JSON-backed SharedPreferences persistence; local-only,
  safe on empty/corrupt JSON, whole-list replacement.
- **`PendingWriteRepository`** — sole access point for pending writes: enqueue,
  list/current count, observable count, update status/error, increment attempt,
  mark synced, remove, prune synced. Unresolved count excludes `synced`.
- **`PinCreateSync`** — deliberately pin-create-only replay coordinator; filters
  strictly on `entityType == pin && opType == create`. Marks items in-progress,
  replays via `PinRepository.createPin` with the queued client id, prunes/marks
  synced on success, increments attempts on transient failure, and
  blocks/fails on auth/validation/corrupt-payload errors without looping.
- **`AppViewModel` wiring** — collects connectivity into `AppUiState.isOnline`
  and the repository count into `AppUiState.pendingSyncCount`; routes
  `createPin` through the online path or the offline enqueue path; triggers
  `PinCreateSync` replay on reconnect and after successful vineyard load.
- **`SyncStatusScreen`** — read-only surface showing online/offline status, live
  pending count, pending item summaries, and empty-state copy. No broad/manual
  retry control.

Pin photo retry architecture (Stages 7B / 7C):

- **`PendingPhotoAttachment`** — local pending pin-photo model: `id`,
  `clientPinId`, `vineyardId`, `localPath`, `createdAt`, `updatedAt`, `status`
  (`pending`/`in_progress`/`failed`/`blocked`/`uploaded`), `attemptCount`,
  `lastError`. Keyed to the client-generated pin UUID; one attachment per pin.
- **`PendingPhotoStore`** — JSON-backed SharedPreferences persistence, separate
  from `PendingWriteStore` and `DomainCacheStore`; safe on empty/corrupt JSON,
  whole-list replacement, no network access.
- **`PendingPhotoRepository`** — sole access point: enqueue, list/observe,
  update status/error, increment attempt, mark uploaded, remove, prune uploaded,
  write compressed JPEG bytes to app-private storage, and delete local files on
  remove/cleanup. Compressed photos are written to
  `filesDir/pending_pin_photos/{clientPinId}.jpg`; the original content Uri is
  never persisted.
- **`PinPhotoSync`** — deliberately pin-photo-only upload coordinator (not a
  general SyncManager). Lists retryable attachments, skips any whose pin create
  is still queued, marks in-progress under a mutex guard, reads the local JPEG,
  uploads via `PinPhotoRepository`, calls `PinRepository.updatePhotoPath`, then
  cleans up and reconciles app state.
- **`AppViewModel` trigger points** — runs `PinPhotoSync` after
  `PinCreateSync.replayAll` completes, when connectivity flips online, after a
  successful vineyard load while online, and after an online pin create whose
  photo upload failed and was retained. All paths require online + valid session
  and guard against overlapping runs.
- **`SyncStatusScreen` photo display** — surfaces the live pending photo count
  and a blocked/needs-attention line when relevant; no broad manual retry button.

Sign-out cleanup architecture (Stage 8):

- **`PendingWriteRepository.clearAll()`** — clears the pending write store and
  resets the in-memory list/count to empty/0.
- **`PendingPhotoRepository.clearAll()`** — deletes every local file under
  `filesDir/pending_pin_photos/`, clears the pending photo store, and resets the
  in-memory list/count.
- **`DomainCacheRepository.clearAll()`** — clears the entire domain read cache.
- **`AppViewModel.signOut()` wiring** — invokes all three local cleanup paths
  alongside auth/session sign-out, wrapped safely so cleanup failure cannot block
  sign-out, then routes to Login with a fresh `AppUiState`.

Read-cache architecture (Stages 6A / 6B):

- **`DomainCacheStore`** — JSON-backed SharedPreferences persistence for the
  read cache; owner user id, vineyard list snapshot + timestamp, and per-vineyard
  paddocks/pins each with their own synced timestamp. Safe on empty/corrupt JSON.
- **`DomainCacheRepository`** — sole access point for the read cache:
  save/load vineyards, save/load paddocks, save/load pins, last-synced/status
  helpers, and owner-gated reads. Kept separate from `PendingWriteRepository`.
- **`DomainCacheStatus`** — display-only model surfacing cached-data presence,
  last saved time, and saved block/pin counts to Sync Status.
- **`AppUiState.isUsingCachedFieldData`** — true only while vineyard list and/or
  selected-vineyard blocks/pins are served from cache; clears on successful
  online loads.
- **`AppUiState.cachedFieldDataLastSyncedAt`** — display-only timestamp of the
  cached data being shown.
- **`loadVineyards()` cache fallback** — live fetch remains primary; on failure
  with no in-memory vineyards, hydrates owner-matched cached vineyards, picks the
  selected/default vineyard using existing priority, and routes to Main instead
  of VineyardLoadFailed. With no cache, the existing failure screen is preserved.
- **`loadVineyardData()` paddock/pin fallback** — live reads remain primary; on
  failure with no in-memory data, hydrates paddocks/pins from cache and
  reconciles cached pins with pending offline-created pins by client UUID.
- **Sync Status cached-data display** — "Showing saved field data" appears only
  when cached data is actively in use, with last-saved time and stale-data copy.

Additional notes:

- Pending writes are currently **JSON-backed SharedPreferences, not Room**.
- The domain read cache is also **JSON-backed SharedPreferences, not Room**.
- Cache **writes happen only after successful online reads**; fallback data is
  **not re-cached** and fallback does not update cache timestamps.
- Cache reads are **owner-gated** by current user id.
- **Cached roles are not used for permissions** — server RLS stays authoritative.
- `PinCreateSync` is **deliberately pin-create-only and not a general
  SyncManager**.
- `PinPhotoSync` is **deliberately pin-photo-only and not a general
  SyncManager**.
- Pending photo files live under **app-private storage**
  (`filesDir/pending_pin_photos/{clientPinId}.jpg`); the **original content Uri is
  never persisted**.
- **No Supabase schema/RLS changes** were made.

Pin photo trigger / ordering (Stage 7C):

- Pending photo upload runs **after pending pin-create replay**, **when
  connectivity returns**, **after a successful vineyard load while online**, and
  **after an online pin create whose photo upload failed and was retained**.
- **Photos are skipped while their pin create is still queued** — upload only
  happens after the pin row exists server-side.
- Upload runs **only when online with a valid session**, and is **safe to retry**
  because the path is deterministic and upserted.

Pin photo failure handling (Stage 7C):

- **Missing/unreadable local file → blocked** with a clear last error.
- **Network/5xx/transient failure → failed/retryable**, incrementing attempt.
- **401/403/RLS/validation → blocked.**
- **Upload succeeds but `updatePhotoPath` fails → local file retained and
  attachment kept retryable.**
- An **attempt cap blocks repeated failures** without aggressive looping.

---

## Safety / conflict notes

- Pin creation is **additive and low conflict** — it inserts a new row rather
  than mutating shared state.
- The **client-generated UUID gives idempotency**: replaying the same queued
  create cannot create a second row.
- A **duplicate/409 during replay is treated as already synced** where safe,
  since the client owns the id.
- **Tier-A JSONB replay remains parked** because full-array patches could clobber
  iOS / shared edits (trip end, GPS path autosave, row Done/Skip/Undo, tank/fill,
  and JSONB array replay).

Read-cache safety (Stages 6A / 6B):

- The **cache never bypasses auth** — a valid restored session/user is required
  before any cached field data can be used; unauthenticated users still go to
  Login.
- **Owner-gating prevents cross-user data access** — owner mismatch clears or
  safely ignores old cache.
- **Stale-data copy is shown** whenever saved field data is active.
- **Server RLS remains authoritative for writes** once online.

---

## Sign-out cleanup safety (Stage 8)

- Cleanup is **local-only**: **no Supabase rows are deleted**, **no Supabase
  Storage objects are deleted**.
- **No queue flush/replay** and **no background sync** occur during sign-out.
- **Sign-out still completes even if cleanup fails** — cleanup is wrapped safely.
- **Normal replay/cache behaviour while signed in is unchanged** — Stage 8 only
  clears local offline/cache state when the user explicitly signs out.

---

## Offline pin update / complete / delete audit (Stage 9, audit only)

Read-only audit. **No code changed, no queueing implemented, no schema/RLS
changes, no offline edit/complete/delete support added.**

### Current online behaviour

- **Pin edits are online-only** — title/notes/category/mode changes PATCH the
  server directly; there is no offline queue for edits.
- **Completion toggle is online-only** — open/complete changes write directly.
- **Delete is online-only** — and uses the `soft_delete_pin` RPC (sets
  `deleted_at`), **not a hard delete**.
- **Photo add/remove on existing pins is online-only** — separate from the
  Stage 7 pin-create photo retry flow.
- **All these flows roll back the optimistic UI change on failure** and surface
  an error message rather than leaving the local state mutated.

### Important audit finding — completion write shape

- **`togglePinCompleted` currently PATCHes the full editable pin field set**
  (title, notes, category, mode, row metadata, completion), **not just
  `is_completed`**.
- This is acceptable for current online behaviour, but it is **unsafe as an
  offline replay shape**: a replayed completion toggle could **overwrite
  title/notes/category/mode/row fields that were changed elsewhere**
  (iOS/web/another device) between enqueue and replay.
- **Conclusion:** offline completion queueing must **not** be implemented until
  completion writes are **narrowed to completion-only fields**.

### Backend / data metadata

- The **server pins table already has useful sync/conflict metadata**:
  `updated_at`, `client_updated_at`, `sync_version`, `deleted_at`, and the
  completion fields.
- The **Android `Pin` model currently does not decode** `updated_at`,
  `client_updated_at`, or `sync_version`.
- **Android pin write paths currently do not send `client_updated_at`.**
- So although the server has enough metadata for conflict detection, **the
  Android client is not yet wired to read or send it**.

### Conflict risks

- A **stale offline edit could clobber newer iOS/web edits** to the same pin.
- **Completion replay using the current full-field patch could clobber remote
  text/category/mode/row edits.**
- A **queued delete is destructive** even though it is a soft-delete.
- **Photo upload/remove conflicts** need separate handling.
- **Duplicate queued updates to the same pin** would need coalescing.

### Recommended staged plan

- **Stage A — completion toggle only**, but **only after narrowing completion
  writes** to `is_completed`/completion fields rather than the full editable
  field set.
- **Stage B — non-destructive text/category/mode edits**, only after Android
  **decodes and sends conflict metadata** such as `client_updated_at` /
  `sync_version`.
- **Stage C — offline delete deferred** until server-side conflict semantics
  and user-facing needs-attention handling exist.
- **Current recommendation: no offline delete yet.**

### Sync Status / pin indicators

- The existing **`PinSyncState` / Sync Status indicator layer can absorb future
  pin update/delete pending states** (pending/blocked/needs-attention).
- However, **replay/write logic is not implemented yet** — the indicator layer
  is ready to surface states that do not exist until a future queueing slice.

### Scope / safety

- **Audit only** — no code changed, no queueing implemented, no schema/RLS
  changes, and no offline delete/edit/complete support added.

---

## Stage 9A prerequisite — narrow pin completion write shape (closed)

Safety prerequisite for any future offline completion queueing. **Display/write
shape narrowing only — no offline queueing, pending writes, replay, or
update/delete queueing added; no schema/RLS/iOS changes.**

### What changed

- **`PinRepository.updatePinCompletion(id, isCompleted)` was added.**
- It **PATCHes only `is_completed`**.
- It **no longer sends** `title`, `notes`, `category`, `mode`, `paddock`,
  row/path fields, or `photo_path`.
- It requests **`return=representation`** and returns the **reconciled server
  row**.

### ViewModel behaviour

- **`AppViewModel.togglePinCompleted(...)` now uses the narrow completion
  method** instead of the full-field `updatePin(...)` path.
- The **existing optimistic UI toggle remains**.
- **Rollback on failure remains.**
- **Unauthorized still signs out.**
- **Successful server row reconciliation is now applied safely by id.**

### Safety / scope

- **No offline completion queueing added yet.**
- **No pending write op added.**
- **No replay logic added.**
- **No update/delete queueing added.**
- **Edit/delete/photo/offline-create flows unchanged.**
- **No schema/RLS/iOS changes.**

### Why this matters

- This **closes the audit risk** where a future replayed completion toggle could
  clobber title/notes/category/mode/row fields changed elsewhere.
- **Stage 9A proper — the offline completion queue — is now unblocked** by the
  narrow write shape.
- **Text/category/mode offline edits still require conflict metadata support**
  (Android decoding/sending `client_updated_at` / `sync_version`).
- **Offline delete remains deferred.**

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

---

## Stage 9A — offline pin completion toggle queue (closed)

Offline queueing and replay for **pin completion toggles only**. **No
text/category/mode edit queueing, no delete queueing, no photo queueing beyond
the existing pending photo flow, no pin-create queue changes, no schema/RLS
changes, no iOS changes.**

### What Android now supports

- **Users can toggle an existing pin Done/Open while offline.**
- **Android optimistically updates the local pin state** so the change is
  visible immediately.
- **A completion-only pending write is queued.**
- **Replay occurs when connection and a valid session are available.**
- **The returned server row is reconciled into local state** by id.
- **Pending/blocked states surface through the existing Sync Status and
  pin-level indicators** — no new UI surfaces added.

### Payload shape

The queued pending write is:

- `entityType = PIN`
- `opType = UPDATE`
- `clientId = pinId`
- payload:
  - `pinId`
  - `isCompleted`

It **does not include** `title`, `notes`, `category`, `mode`, `paddock`,
row/path fields, or `photo_path`.

- **`clientUpdatedAt` / `sync_version` are intentionally parked for Stage 9B**
  because Android does not yet decode/send that metadata for pins.

### Offline / transient behaviour

- **Known offline** — no network call; optimistic state kept; pending write
  enqueued; friendly saved-offline message.
- **Online transient/network/5xx** — optimistic state kept; pending write
  enqueued; friendly retry/saved-locally message.
- **Unauthorized** — existing sign-out behaviour preserved.
- **Validation/permission/non-5xx server errors** — optimistic state rolled
  back; **not** queued.

### Coalescing

- **Completion writes are coalesced by `clientId = pinId`** — multiple
  unresolved completion writes for the same pin do not pile up.
- **Latest toggle wins.**
- **Unrelated pin creates / photos / other pins are not removed.**

### Replay

- **`PinCompletionSync` is a completion-only coordinator** (separate from the
  pin-create and pin-photo coordinators).
- It **processes only pending/failed PIN / UPDATE completion writes**.
- It is **guarded by valid session + online state**.
- It is **triggered on reconnect and after a successful vineyard load**.
- It uses a **mutex overlap guard** against concurrent runs.
- It calls **`PinRepository.updatePinCompletion(pinId, isCompleted)`**.
- It **removes the write on success** and reconciles the returned server row.
- It **retries transient/server/session-expired failures**.
- It **blocks corrupt/permission/validation failures** without looping.
- It uses an **attempt cap consistent with existing replay paths**.

### Scope / safety

- **No text/category/mode edit queueing.**
- **No delete queueing.**
- **No photo queueing beyond the existing pending photo flow.**
- **No changes to the pin create queue.**
- **No schema/RLS changes.**
- **No iOS changes.**

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

---

## Stage 9B-1 — decode and preserve pin conflict metadata (closed)

Model/cache preservation only. **No write body changes, no offline edit
queueing, no delete queueing, no Sync Status/UI changes, no schema/RLS/iOS
changes.**

### What changed

The Android `Pin` model now decodes and preserves the following nullable
fields (all default to `null`, using the existing `@SerialName` style):

- `updated_at` → `updatedAt`
- `client_updated_at` → `clientUpdatedAt`
- `sync_version` → `syncVersion`
- `completed_at` → `completedAt`
- `completed_by` → `completedBy`

### Backwards compatibility

- **Old cached pin JSON remains compatible** — missing fields decode to `null`
  via per-field defaults.
- **Server responses missing these fields still decode.**
- **Unknown extra fields remain ignored** (`ignoreUnknownKeys = true`).
- **No cache migration required.**

### Cache preservation

- **`DomainCacheStore` serializes pins via `Pin.serializer()`**, so the newly
  decoded metadata is **automatically saved/restored** in cached pins.
- **No cache code change was required.**

### Scope / safety

- **Decode/preserve only.**
- **No write body changes** (`createPin`, `updatePin`, `updatePinCompletion`,
  `updatePhotoPath`, `softDeletePin` unchanged).
- **No offline edit queueing.**
- **No delete queueing.**
- **No Sync Status / UI changes** (no `PinSyncState`, map/list/detail indicator
  changes).
- **No schema/RLS/iOS changes.**

### Why this matters

- This **unblocks future Stage 9B-2 work** to send `client_updated_at` on
  normal online pin edits.
- **Future offline text/category/mode edit queueing still requires a staged
  conflict strategy.**
- **Offline delete remains deferred.**

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

---

## Stage 9B-2 — send client_updated_at on normal online pin edits (closed)

Online edit-path only. **No offline text/category/mode edit queueing, no delete
queueing, no completion queue changes, no photo queue changes, no Sync Status/UI
changes, no schema/RLS/iOS changes.**

### What changed

- **`PinRepository.updatePin(...)` now stamps `client_updated_at`** at normal
  edit save time.
- The timestamp uses the **existing project convention** — `Instant.now().toString()`,
  producing a **UTC ISO-8601** value.
- This **aligns Android's normal online pin edit path with the iOS
  last-write-wins contract** before any offline edit queueing.

### PATCH payload shape

Normal `updatePin(...)` now sends:

- `paddock_id`
- `title`
- `category`
- `mode`
- `notes`
- `side`
- `row_number`
- `is_completed`
- `client_updated_at`

### Narrow paths unchanged

`client_updated_at` was **not** added to:

- `updatePinCompletion(...)`
- `updatePhotoPath(...)`
- `softDeletePin(...)`
- pin completion queue payload
- pin create queue payload
- pending photo retry
- replay payloads

### Behaviour / cache

- **Optimistic edit/rollback behaviour unchanged.**
- **Friendly error handling unchanged.**
- **Unauthorized sign-out unchanged.**
- **`return=representation` retained.**
- **The returned server row now decodes `clientUpdatedAt`** (added in Stage 9B-1).
- **Cached pins preserve it via `Pin.serializer()`** — no cache migration
  required.

### Scope / safety

- **Online edit-path only.**
- **No offline text/category/mode queueing.**
- **No delete queueing.**
- **No completion queue changes.**
- **No photo queue changes.**
- **No Sync Status / UI changes.**
- **No schema/RLS/iOS changes.**

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

---

## Stage 9B-3 — offline pin text/category/mode edit queue design audit (closed / design only)

Design/audit only. **No code changed, no offline edit queueing implemented, no
schema/RLS/RPC changes, no iOS changes, delete still deferred.**

### Current editable fields

The current Android `updatePin(...)` edit path includes:

- `paddock_id`
- `title`
- `category`
- `mode`
- `notes`
- `side`
- `row_number`
- `is_completed`
- `client_updated_at`

Classification:

- **Safe first offline-edit candidates** — `title`, `notes`, `category`, `mode`.
- **Online-only for the first slice** — `paddock_id`, `side`, `row_number`, and
  row/path snap fields (positional/reassignment fields are higher conflict risk).
- **Already covered by Stage 9A** — `is_completed` (completion-only queue).
- **Separate photo flow** — `photo_path` (Stage 7 pending photo retry).

### Critical design finding

- **Stage 9A's completion queue already uses `entityType = PIN` and
  `opType = UPDATE`.**
- **`PinCompletionSync` replay/coalescing currently treats all PIN / UPDATE
  pending writes as completion writes.**
- **Therefore offline edit queueing must NOT reuse PIN / UPDATE directly** — it
  would collide with the completion queue's filtering and coalescing.
- **Recommended discriminator:** add a distinct pending entity type such as
  **`PIN_EDIT`** for future edit queueing, so edit and completion writes never
  cross-contaminate.

### Proposed first payload

Proposed future edit payload (not yet implemented):

- `entityType = PIN_EDIT`
- `opType = UPDATE`
- `clientId = pinId`
- payload:
  - `pinId`
  - `title`
  - `notes`
  - `category`
  - `mode`
  - `clientUpdatedAt`
  - `baseClientUpdatedAt`

Excluded from the first payload:

- completion (`is_completed`)
- delete / soft-delete
- `photo_path`
- paddock reassignment (`paddock_id`)
- `side` / `row_number` / snap fields

### Conflict strategy

- **Recommended: stale-guard + block.**
- On replay, compare the **current server pin `client_updated_at`** with the
  queued **`baseClientUpdatedAt`**.
- **If the server value is newer**, do **not** overwrite — mark the pending edit
  **BLOCKED / Needs attention**.
- **Otherwise** PATCH the descriptive fields with a fresh `client_updated_at`.
- **Pure last-write-wins is a fallback only**, not the preferred first
  implementation (it risks silent stale overwrite of iOS/web edits).

### Coalescing strategy

- **Coalesce by `clientId = pinId`.**
- **Latest edit wins** — replace earlier unresolved `PIN_EDIT` writes for the
  same pin.
- **Preserve the original `baseClientUpdatedAt`** where possible so the
  stale-guard still compares against the first known base, not a moving target.
- **Never touch** pending creates, completion toggles, photo work, or other
  pins' pending writes.

### Replay / UI design

Proposed future **`PinEditSync`**:

- **Separate edit-only coordinator** (like `PinCreateSync` / `PinCompletionSync`
  / `PinPhotoSync`), not a general SyncManager.
- **Session + online guard.**
- **Reconnect and vineyard-load triggers.**
- **Mutex overlap guard** against concurrent runs.
- **Success reconciles the returned server row** into local state by id.
- **Transient/network/5xx/session-expired failures retry.**
- **Corrupt/permission/validation/stale-conflict failures block** (Needs
  attention) without looping.
- **Attempt cap consistent with existing replay paths.**

Proposed UI:

- **Reuse `PinSyncState`** — add future `pendingEdit` / `blockedEdit` states.
- **Map/list/detail** show **Pending sync** / **Needs attention**.
- **Sync Status labels the item as "Pin edit".**
- **No new UI screens required.**

### Scope / safety

- **Design audit only** — no code changed.
- **No offline edit queueing implemented.**
- **No schema/RLS/RPC changes.**
- **No iOS changes.**
- **Offline delete still deferred.**

---

## Stage 9B-3 — offline descriptive pin edit queue (closed)

Offline queueing and replay for **descriptive pin edits only** (`title`,
`notes`, `category`, `mode`). **No offline delete queueing, no completion queue
changes, no pin-create queue changes, no pending photo retry changes, no photo
add/remove changes, no duplicate-checker/map-visual changes, no schema/RLS/iOS
changes.**

### What Android now supports

- **Users can edit an existing pin's descriptive fields while offline** —
  `title`, `notes`, `category`, `mode`.
- **Android queues the edit and replays it when online.**
- **Replay uses a stale-guard conflict check** before overwriting the server
  row.
- **Pending/blocked states surface through the existing Sync Status and
  pin-level indicators** — no new screens added.

### Supported / excluded fields

Offline edit queueing is limited to:

- `title`
- `notes`
- `category`
- `mode`

Explicitly excluded (remain online-only / unchanged):

- completion (`is_completed`)
- delete / soft-delete
- `photo_path`
- paddock reassignment (`paddock_id`)
- `side`
- `row_number`
- row/path snap fields

### Pending write discriminator and payload

- **`PendingEntityType.PIN_EDIT` was added.**
- **Descriptive edits use `PIN_EDIT` / `UPDATE`.**
- **The completion queue continues to own `PIN` / `UPDATE`.**
- This **prevents replay/coalescing collisions** between edit and completion
  writes.

Queued payload:

- `pinId`
- `title`
- `notes`
- `category`
- `mode`
- `clientUpdatedAt`
- `baseClientUpdatedAt`

### Repository / replay

- **`updatePinFields(...)` PATCHes only** `title`, `notes`, `category`, `mode`,
  `client_updated_at` (with `return=representation`, returning the reconciled
  `Pin`).
- **`fetchPin(...)` reads the live non-deleted row** for conflict checking.
- **`PinEditSync` is a separate edit-only coordinator** (alongside
  `PinCreateSync` / `PinCompletionSync` / `PinPhotoSync`), processing only
  unresolved `PIN_EDIT` / `UPDATE` writes.
- **Replay requires a valid session + online state.**
- **Triggered on reconnect and after a successful vineyard load.**
- **Mutex overlap guard** against concurrent runs.
- **Success reconciles the returned server row** into `AppUiState.pins` by id.
- **Transient/network/5xx/session-expired failures retry.**
- **Corrupt payloads, permission/validation failures, deleted pins, and stale
  conflicts block** (Needs attention) without looping.
- **Attempt cap consistent with existing replay paths.**

### Coalescing

- **Unresolved `PIN_EDIT` writes are coalesced by `clientId = pinId`.**
- **Latest edit wins** — replaces the previous payload.
- **The earliest useful `baseClientUpdatedAt` is preserved** so the stale-guard
  compares against the first known base, not a moving target.
- **Pending creates, completions, photos, and other pins are untouched.**

### Conflict guard

- On replay, **the current server pin `client_updated_at` is compared with the
  queued `baseClientUpdatedAt`**.
- **If the server is newer**, Android **blocks the pending edit instead of
  overwriting** it.
- **If the conflict cannot be proven**, replay proceeds using the queued
  `clientUpdatedAt`.
- **Blocked conflicts surface as Needs attention.**

### UI / indicators

- **`PinSyncState` includes `pendingEdit` / `blockedEdit`.**
- **Pending edit shows Pending sync** on map/list/detail.
- **Blocked edit shows Needs attention.**
- **Sync Status labels the item as "Pin edit".**
- **No new UI screens were added.**

### Scope / safety

- **No offline delete queueing.**
- **No completion queue changes.**
- **No pin create queue changes.**
- **No pending photo retry changes.**
- **No photo add/remove changes.**
- **No duplicate checker / map visual changes.**
- **No schema/RLS/iOS changes.**

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

---

## Tier-A trip / GPS / row / tank replay audit (closed / audit only)

Read-only audit of what would be required to make active field trips resilient
offline (trip start/end, GPS breadcrumb/path logging, row completion/skip/done
state, tank/session/fill events, and engine-hour/fuel/labour summary fields
linked to trips). **No code changed, no replay implemented, no schema/RLS/RPC
changes, no broad SyncManager, no UI rewrite, no iOS changes.**

### Current trip lifecycle

- **Trip start is online-required** via `TripRepository.createTrip(...)`.
- **Trip end PATCHes final state** — path/distance/notes/engine hours are
  written when the trip ends.
- **Metadata and activation are online PATCH flows.**
- **Row-plan seeding and row coverage are server writes.**
- **In-progress trip state is mostly held in `AppUiState`** plus the live
  `LocationTracker`.
- **Failures use the existing friendly error / rollback patterns.**

### Highest data-loss risk — GPS / path logging

- **GPS/path points accumulate in memory** through `LocationTracker`.
- **Autosave is throttled.**
- **Autosave failures are silently swallowed.**
- **Going offline can lose unsaved tail points** if the process dies.
- **Process death / backgrounding can lose in-memory points.**
- **Current path persistence is whole-array replace, not append.**
- **There is no durable local active-track store yet.**

### Row coverage risk

- **Row done/skip/undo state is server-first with optimistic local update.**
- **Failure rolls back to the previous state.**
- **Offline row actions are therefore lost / reverted.**
- **End-trip review correctly refuses to finish if coverage save fails.**

### Tank / fill / engine-hour risk

- **Tank/fill state is stored in trip JSON / live columns.**
- **Writes are online-first with rollback on failure.**
- **No local durable event persistence exists before the server write.**
- **Fuel fill logs are a separate online-first table** and are out of Tier-A
  trip scope for now.

### Existing offline infrastructure fit

- **The existing `PendingWriteRepository` and replay-coordinator patterns can
  help for discrete summary writes** (e.g. trip start/end/metadata).
- **But high-frequency / ordered streams** like GPS breadcrumbs, row actions,
  and tank events **likely need a trip-specific local store or append-style
  event log** rather than the generic pending-write outbox.
- **The current domain cache covers vineyards/paddocks/pins only, not trips.**

### Ordering / idempotency risks

- **The trip must exist before GPS/row/tank events replay.**
- **The end-trip summary must replay last.**
- **Path/coverage/tank fields are currently full-array / blob PATCHes**, so
  blind replay risks clobbering newer server state.
- **Row done/skip/undo actions are order-sensitive.**
- **Tank sessions should merge by session UUID.**
- **Breadcrumbs need idempotency / deduping.**

### Recommended staged plan

- **Stage A** — local persistence for active trip state only, **no replay**.
- **Stage B** — queue trip start/end/metadata summary writes.
- **Stage C** — queue GPS breadcrumbs through an append / idempotent event log.
- **Stage D** — queue row done/skip/undo coverage events.
- **Stage E** — queue tank/fill/engine-hour events.
- **Stage F** — Sync Status / blocked recovery for trips.

### Safest first implementation slice

- **Stage A — local active-trip persistence only, no replay — is the
  recommended first slice.**
- It should **reduce process-death / offline data loss** without changing
  server write contracts or adding replay complexity.
- **Trip read-cache parity with pins is a natural companion.**

### Scope / safety

- **Audit only** — no code changed.
- **No replay implemented.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No UI rewrite.**
- **No iOS changes.**

---

## Tier-A Stage A — local active-trip persistence only (closed)

Durable on-device persistence of in-progress active-trip state to reduce data
loss from process death, offline autosave failures, or app interruption.
**Local restore only — not sync replay. No replay logic, no
`PendingWriteRepository` changes, no trip start/end queueing, no GPS breadcrumb
replay, no row event replay, no tank event replay, no schema/RLS/RPC changes,
no broad SyncManager, no new UI screens, no iOS changes.**

### What Android now supports

- **Android now durably saves in-progress active trip state locally.**
- This **reduces data loss from process death, offline autosave failures, or
  app interruption.**
- This is **local restore only, not sync replay.**

### Local store design

- **`ActiveTripStore` was added.**
- Uses a **dedicated SharedPreferences file** — `vinetrack_active_trip`.
- Stores a **single JSON snapshot**.
- Uses the **existing lightweight JSON/SharedPreferences style** (mirroring
  `DomainCacheStore` / `PendingWriteStore`).
- **No Room/KSP introduced.**
- Snapshot scoped by:
  - `ownerUserId`
  - `vineyardId`
  - the embedded `Trip` id
  - `savedAt`
- **Corrupt/unreadable JSON is safely ignored** and treated as no snapshot — it
  does not crash the app.

### Persisted fields

The snapshot stores the **full serializable `Trip`**, including:

- trip id
- path points
- total distance
- row sequence
- sequence index
- current/next row
- completed paths
- skipped paths
- tracking pattern
- tank sessions
- active tank number
- filling state
- filling tank number
- start/end engine hours
- pause state
- trip metadata

### Save triggers

Local persistence is triggered on:

- trip start
- metadata update
- pause/resume
- GPS path/distance updates
- row done/skip/undo
- tank/fill changes
- engine-hour changes
- trip end/delete clearing

Notes:

- **Local GPS persistence is throttled more tightly than server autosave.**
- **Discrete state changes persist immediately.**

### Restore behaviour

- **Restore runs during trip/vineyard load.**
- **Requires matching user and vineyard.**
- **Restores only a real server-created trip id.**
- **Does not fake a trip** if start failed before a server id existed.
- **Overlays local progress only when the server trip is still active.**
- **Does not truncate a longer server path with a shorter local path.**
- **Server-ended/deleted trips clear the local snapshot.**
- **Stale/offline trip lists can accept the snapshot** so the active-trip view
  survives.

### Clear behaviour

The local active-trip snapshot clears on:

- successful trip end
- trip delete
- explicit sign-out cleanup
- invalid/mismatched restore
- non-active restored trip

### Scope / safety

- **No replay logic.**
- **No `PendingWriteRepository` changes.**
- **No trip start/end queueing.**
- **No GPS breadcrumb replay.**
- **No row event replay.**
- **No tank event replay.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No new UI screens.**
- **No iOS changes.**

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack` — a missing
  `ActiveTripStore` import was fixed during implementation before the successful
  build.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

### Parked next steps (remaining Tier-A stages)

- **Stage B** — trip start/end/metadata queue.
- **Stage C** — GPS breadcrumb replay / event log.
- **Stage D** — row coverage replay.
- **Stage E** — tank/fill/engine-hour replay.
- **Stage F** — Sync Status / blocked recovery.
- **Start-before-server-id handling is parked for Stage B.**

---

## Tier-A Stage B — trip start/end/metadata queue audit/design (closed / design only)

Audit/design of the safest first trip replay layer for discrete trip lifecycle
writes, ahead of GPS/row/tank event replay. **No code changed, no queueing
implemented, no GPS/row/tank replay, no delete queueing, no schema/RLS/RPC
changes, no broad SyncManager, no UI rewrites, no iOS changes.**

### Current discrete trip write paths

- **Trip start** via `TripRepository.createTrip(...)`.
- **Activate trip.**
- **Metadata update.**
- **Pause/resume.**
- **Start engine hours.**
- **End trip.**
- **End trip with row review.**
- **Trip delete / soft delete.**

Key finding:

- **Trip start is currently online-required** — the trip is only inserted into
  state after the server returns.
- **Stage A active-trip persistence protects existing active trips** but does
  **not invent server trips.**

### Start-before-server-id decision

- **`createTrip(...)` already generates a client UUID before the network call.**
- **But safe offline start still requires a local provisional trip and
  reconciliation through GPS/row/tank child state.**
- **Therefore offline trip start is deferred.**
- **Stage B should not queue trip start yet.**

### Safe Stage B candidates

Safe first candidates for queueing on an **existing active server trip**:

- **metadata updates**
- **pause/resume**
- **start engine hours**

These are **small scalar fields with low ordering risk.**

### Deferred fields / flows

These remain parked:

- trip start
- trip end
- delete
- final `path_points`
- row coverage arrays
- tank sessions
- GPS breadcrumbs

Reasons:

- **End summary must replay last.**
- **Path/coverage/tank are whole-array / blob replacements.**
- **Blind replay risks clobbering newer server state.**
- **GPS/row/tank require later event-log or merge design.**

### Recommended staged plan

- **Stage B-1** — queue metadata + pause/resume + start-engine-hours for
  **existing active server trips only.**
- **Stage B-2** — queue trip-end summary later, after GPS/row/tank event-log
  design.
- **Stage B-3** — offline trip start later, after client-id / provisional-trip
  reconciliation design.

### Pending write discriminator recommendation

- **`PendingEntityType.TRIP` exists but should not be used broadly** for all
  trip work.
- **Recommended future discriminator for B-1: `TRIP_METADATA`.**
- **Keep GPS/row/tank on their own future event-log types/stores.**
- This **avoids collisions**, similar to the `PIN` vs `PIN_EDIT` split.

### Proposed B-1 replay design

Proposed future **`TripMetadataSync`** coordinator:

- **Coalesce by `clientId = tripId`.**
- **Latest update wins.**
- **Preserve the earliest `baseClientUpdatedAt`.**
- **Stale-guard using the live trip `client_updated_at`.**
- **Transient/5xx/session-expired failures retry.**
- **Validation/permission/corrupt/stale failures block.**
- **Attempt cap consistent with existing replay paths.**
- **Sync Status label: "Trip details".**
- **Offline updates should update `AppUiState.trips` and `ActiveTripStore`** so
  the Stage A snapshot and the pending write agree.

### Scope / safety

- **Design only** — no code changed.
- **No queueing implemented.**
- **No GPS/row/tank replay.**
- **No delete queueing.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No UI rewrites.**
- **No iOS changes.**

### Parked future work (remaining Tier-A stages)

- **Stage B-1 implementation.**
- **Stage B-2** — trip-end summary.
- **Stage B-3** — offline trip start.
- **Stage C** — GPS breadcrumb event log / replay.
- **Stage D** — row coverage replay.
- **Stage E** — tank/fill/engine-hour replay.
- **Stage F** — Sync Status / blocked recovery.

---

## Tier-A Stage B-1 — trip metadata/pause/start-engine-hours queue (closed)

Offline queueing and replay for **safe scalar trip updates on existing active
server trips only** — trip metadata, pause/resume, and start engine hours. This
is the **first trip pending-write/replay slice**. **No trip start, no trip end,
no delete, no GPS/path replay, no row coverage, no tank sessions, no fuel logs,
no final summaries, no schema/RLS/RPC changes, no broad SyncManager, no iOS
changes.**

### What Android now supports

- **Android can now save selected trip detail changes offline** for an existing
  active server trip.
- **The changes are queued and replayed later.**
- This is the **first trip pending-write/replay slice.**
- It **does not cover** trip start, trip end, GPS, row coverage, tank sessions,
  delete, or final summaries.

### Pending write discriminator

- **`PendingEntityType.TRIP_METADATA` was added.**
- It is **distinct from broad `TRIP`.**
- **B-1 filters strictly on `TRIP_METADATA` + `UPDATE`.**
- **Future GPS/row/tank/trip-end work remains separate.**

### Payload shape

Queued write:

- `entityType = TRIP_METADATA`
- `opType = UPDATE`
- `clientId = tripId`

Payload fields:

- `tripId`
- `paddockId`
- `paddockName`
- `personName`
- `tripFunction`
- `tripTitle`
- `machineId`
- `workTaskId`
- `operatorUserId`
- `operatorCategoryId`
- `isPaused`
- `startEngineHours`
- `clientUpdatedAt`
- `baseClientUpdatedAt`

Explicitly excluded:

- trip start
- trip end
- delete
- path points
- total distance
- row coverage
- row plan
- tank sessions
- fuel logs
- final summaries

### Trip model / metadata

- **The Android `Trip` model now decodes `client_updated_at` as a read-only
  `clientUpdatedAt`.**
- This was **needed for the stale/conflict guard.**
- **No schema/RLS/RPC change was made.**

### Repository and replay

- **`TripRepository.fetchTrip(id)`** reads the **live non-deleted trip row.**
- **`TripRepository.updateTripMetadataFields(...)`** PATCHes **only safe B-1
  scalar fields**:
  - metadata fields
  - `is_paused`
  - `start_engine_hours`
  - `client_updated_at`
- It uses **`return=representation`** and returns the **reconciled `Trip`.**
- It does **not** PATCH path/coverage/tank/end/delete/start fields.
- **`TripMetadataSync`** is a new replay coordinator that:
  - requires **session + online**,
  - uses a **mutex/overlap guard**,
  - triggers **on reconnect and after a successful vineyard/trip load**,
  - **reconciles the returned trip into `AppUiState.trips`**,
  - **refreshes the `ActiveTripStore` snapshot when relevant.**

### Offline behaviour

For **existing active server trips** while known offline:

- metadata / pause / start-engine-hour changes **update local state
  optimistically**,
- the **Stage A active-trip snapshot is persisted**,
- a **`TRIP_METADATA` write is enqueued/coalesced**,
- a **friendly saved-offline message** is shown,
- **no network call is made** while known offline,
- **no trip is invented** if no server id exists.

### Coalescing and conflict guard

- **Unresolved `TRIP_METADATA` writes coalesce by `clientId = tripId`.**
- **Latest wins.**
- **The earliest useful `baseClientUpdatedAt` is preserved.**
- **Other trips and non-trip-metadata pending work are untouched.**
- On replay, the coordinator **fetches the live trip first**, and:
  - **blocks missing / deleted / no-longer-active trips**,
  - **blocks stale conflicts** where the server `client_updated_at` is newer
    than the queued base,
  - **falls back to last-write-wins only when a conflict cannot be proven**,
  - **timestamp parsing handles both `Z` and offset shapes.**

### Failure handling / Sync Status

- **Success removes the pending write.**
- **Transient/network/5xx/session-expired failures retry.**
- **Corrupt payloads, permission/validation failures, missing/deleted/ended
  trips, and stale conflicts block.**
- **Attempt cap matches existing replay paths.**
- **Sync Status labels the item as "Trip details".**
- **No new trip UI screens were added.**

### Scope / safety

- **No changes to** trip start, trip end, delete / soft delete, GPS/path
  autosave, GPS breadcrumb replay, row coverage, row plan, tank sessions, fuel
  logs, or pin queues.
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No iOS changes.**

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

### Parked next steps

- **Stage B-2** — trip-end summary queue, after GPS/row/tank event-log design.
- **Stage B-3** — offline trip start with client-id / provisional-trip
  reconciliation.
- **Stage C** — GPS breadcrumb event log / replay.
- **Stage D** — row coverage replay.
- **Stage E** — tank/fill/engine-hour replay.
- **Stage F** — Sync Status / blocked recovery.

---

## Tier-A Stage C — GPS breadcrumb event log/replay audit/design (closed / design only)

Audit/design of the safest offline replay path for trip GPS/path progress
without clobbering server data. **No code changed, no queueing/replay
implemented, no trip start queueing, no trip end queueing, no row coverage
replay, no tank/fill replay, no fuel logs, no schema/RLS/RPC changes, no broad
SyncManager, no iOS changes.**

### Current GPS/path flow

- **`LocationTracker` captures high-accuracy GPS fixes.**
- It **filters poor accuracy and jitter.**
- **GPS points and running distance are held in memory while tracking.**
- **`CoordinatePoint` currently has lat/lng plus optional bearing/speed/accuracy,
  but no point id/timestamp.**
- **`AppViewModel.beginTracking` updates trip path/distance in UI state, row-lock
  logic, server autosave, and the Stage A local snapshot.**
- **Server autosave currently runs via `maybeAutosave`.**
- **Stage A local snapshot runs via `maybeAutosaveLocal`.**
- **Server autosave failures are swallowed, while Stage A protects the local
  active-trip state.**

### Current server write shape

- **`TripRepository.saveProgress(...)` PATCHes:**
  - `path_points`
  - `total_distance`
  - `is_paused`
  - `client_updated_at`
- **End-trip PATCH also sends final:**
  - `path_points`
  - `total_distance`
- **`path_points` and `total_distance` are whole-array/blob style replacements**
  and can clobber newer server state if replayed blindly.

### Key risks

- **Stale full-path replay can overwrite a longer server path.**
- **Duplicate points.**
- **Out-of-order points.**
- **Lack of per-point id/timestamp.**
- **Restored/interrupted trips.**
- **Reconnect after long offline sessions.**
- **Multiple devices editing the same trip.**
- **Interaction with the Stage A active-trip snapshot.**
- **Interaction with Stage B-1 `TRIP_METADATA`.**

### Options considered

- **guarded whole-array PATCH**
- **local append-only breadcrumb event log**
- **periodic path segments**
- **trip-specific GPS store**
- **generic pending write with `TRIP_GPS`**
- **server-side merge/RPC**
- **client-side fetch/merge/PATCH**

Decision:

- **No schema/RPC change for this slice.**
- **Avoid one pending row per GPS fix.**
- **Avoid broad `TRIP`.**
- **Use a coalesced trip-scoped marker.**

### Recommended Stage C approach

- **Add future `PendingEntityType.TRIP_GPS`.**
- **Coalesce to one row per trip using `clientId = tripId`.**
- **Treat the outbox row as a lightweight marker** that the trip has unsynced GPS
  progress.
- **Use the Stage A active-trip snapshot as the local source of captured path.**
- **Replay fetches the live trip.**
- **Merge server path with local snapshot path.**
- **Dedupe near-identical consecutive coordinates.**
- **Never produce or PATCH a path shorter than the server path.**
- **Recompute `total_distance` from the merged path.**
- **Use the existing `saveProgress` contract or a progress-only variant.**
- **Reconcile the returned trip into state.**
- **Refresh `ActiveTripStore` when relevant.**

### Store / discriminator decision

- **Recommended future discriminator: `TRIP_GPS`.**
- **Coalesced one row per trip.**
- **No per-fix pending-write rows.**
- **High-frequency GPS stays grouped in Sync Status.**
- **A future GPS event-log/store can be introduced later if needed**, but Stage
  C-1 can reuse the existing outbox as a marker.
- **Cleanup after successful sync/end/delete/sign-out.**

### Replay algorithm design

Proposed future **`TripGpsSync`**:

- **Mutex/overlap guard.**
- **Session + online required.**
- **Reads unresolved `TRIP_GPS` markers.**
- **Loads the local path from the Stage A snapshot.**
- **Fetches the live trip.**
- **Blocks missing/deleted/no-longer-active trips.**
- **Merges server/local path.**
- **Dedupes near-identical consecutive points.**
- **Recomputes distance.**
- **Skips PATCH if nothing new.**
- **PATCHes only when the merged path is at least as complete as the server
  path.**
- **Success removes the marker.**
- **Transient failures retry.**
- **Corrupt/permission/conflict/cap failures block.**
- **Triggers on reconnect and after a successful vineyard/trip load.**

### Sync Status / UI design

- **Grouped Sync Status label should be "Trip GPS".**
- **Pending count should include it.**
- **No new trip screen required for Stage C-1.**

### Scope / safety

- **Design only** — no code changed.
- **No queueing/replay implemented.**
- **No trip start queueing.**
- **No trip end queueing.**
- **No row coverage replay.**
- **No tank/fill replay.**
- **No fuel logs.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No iOS changes.**

### Recommended next implementation slice

- **Stage C-1 should implement the coalesced `TRIP_GPS` marker +
  `TripGpsSync` coordinator.**
- **Trip end replay remains deferred** until GPS replay is proven.
- **Trip start remains deferred** until provisional-trip reconciliation is
  designed.
- **Row and tank replay remain deferred to Stages D and E.**

---

## Tier-A Stage C-1 — coalesced TRIP_GPS marker + TripGpsSync coordinator (closed)

Offline queueing and replay for **GPS/path progress on existing active server
trips only**, using a coalesced `TRIP_GPS` marker and the Stage A active-trip
snapshot as the local path source. **No trip start, no trip end, no row
coverage, no tank sessions, no delete, no fuel logs, no final summaries, no
schema/RLS/RPC changes, no broad SyncManager, no iOS changes.**

### What Android now supports

- **Android can now queue GPS/path progress** for an existing active server
  trip.
- It uses a **coalesced pending marker, not one row per GPS fix.**
- It **replays by fetching the live server trip, merging with the Stage A local
  active-trip snapshot, deduping, recomputing distance, and PATCHing guarded
  progress.**
- It **does not cover** trip start, trip end, row coverage, tank sessions,
  delete, fuel logs, or final summaries.

### Pending write discriminator

- **`PendingEntityType.TRIP_GPS` was added.**
- It is **distinct from broad `TRIP` and from `TRIP_METADATA`.**
- It is used **strictly for GPS/path progress replay.**
- It processes **`TRIP_GPS` + `UPDATE` only.**

### Marker payload

Queued marker:

- `entityType = TRIP_GPS`
- `opType = UPDATE`
- `clientId = tripId`

Payload fields:

- `tripId`
- `baseServerPointCount`
- `baseClientUpdatedAt`
- `clientUpdatedAt`
- `savedAt`

Notes:

- **No GPS point arrays are stored in the outbox row.**
- **Path data remains in the Stage A `ActiveTripStore` snapshot.**

### Enqueue / coalescing behaviour

Markers are enqueued:

- **when known offline during active tracking**,
- **when server GPS autosave fails while believed online.**

Behaviour:

- **One marker per trip.**
- **No per-fix pending rows.**
- **Latest marker wins.**
- **The earliest useful baseline is preserved.**
- **No network call when known offline.**

### Local snapshot source

- **Replay uses the Stage A `ActiveTripStore` as the local path source.**
- **The snapshot trip id must match.**
- **No matching snapshot means no invented path data.**
- **The marker is removed safely when there is no local work to replay.**

### Repository / PATCH body

- **Replay uses the existing `TripRepository.fetchTrip(id)`.**
- **Replay uses the existing `saveProgress(...)`.**
- PATCH sends **only**:
  - `path_points`
  - `total_distance`
  - safe live `is_paused`
  - `client_updated_at`

Explicitly excluded PATCH fields:

- metadata
- row coverage
- row plan
- tank sessions
- trip start
- trip end
- delete
- fuel logs
- final summaries

### Merge / dedupe / distance

- **Replay fetches the live server trip first.**
- **Takes the local path only when it is strictly longer than the server path.**
- **Never produces or PATCHes a path shorter than the server path.**
- **Dedupes consecutive points closer than 1m.**
- **Skips PATCH and removes the marker if nothing new remains.**
- **Recomputes `total_distance` from scratch using haversine.**
- **Avoids additive distance drift.**
- **Reconciliation keeps the longer of in-memory vs returned path** so
  live-growing tracks are not truncated.

### Replay coordinator

**`TripGpsSync`:**

- **Processes unresolved `TRIP_GPS` / `UPDATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Triggers on reconnect and after a successful vineyard/trip load.**
- **Blocks missing / deleted / no-longer-active trips.**
- **Retries transient/network/5xx/session-expired failures.**
- **Blocks corrupt payloads, permission/validation failures, ended trips, and
  unrecoverable merge conflicts.**
- **Attempt cap consistent with existing replay paths.**
- **Removes the marker on success.**
- **Refreshes the `ActiveTripStore` snapshot when relevant.**

### Sync Status / UI

- **Sync Status labels the item as "Trip GPS".**
- **Pending count includes these markers.**
- **No new trip UI screens were added.**

### Stage interactions / scope

- **Stage A remains the local active-trip path source.**
- **Stage B-1 `TRIP_METADATA` remains isolated.**
- **C-1 does not touch metadata/pause/start-engine-hours replay.**
- **Trip end replay remains deferred.**
- **Offline trip start remains deferred.**

Confirmed no changes to:

- trip start
- trip end
- delete / soft delete
- row coverage
- row plan
- tank sessions
- fuel logs
- final summaries
- pin queues
- schema/RLS/RPC
- broad SyncManager
- iOS code

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

### Parked next steps

- **Stage B-2** — trip-end summary queue, after GPS replay is proven.
- **Stage B-3** — offline trip start with client-id / provisional-trip
  reconciliation.
- **Stage D-1** — row coverage replay (TRIP_ROW marker + TripRowSync). **Now
  closed.**
- **Stage E** — tank/fill/engine-hour replay.
- **Stage F** — Sync Status / blocked recovery.

---

## Tier-A Stage D — row coverage replay audit/design (closed / design only)

Read-only audit and design of the safest offline replay path for trip row
coverage (Done / Skip / Undo) without corrupting row sequence, completed/skipped
paths, or end-trip review. **No code changed, no row replay implemented, no
trip start queueing, no trip end queueing, no tank/fill replay, no fuel logs, no
schema/RLS/RPC changes, no broad SyncManager, no iOS changes.**

### Current row coverage flow

- **Row coverage state lives on `Trip`**, with the key fields:
  - `completedPaths`
  - `skippedPaths`
  - `rowSequence`
  - `sequenceIndex`
  - `currentRowNumber`
  - `nextRowNumber`
  - `trackingPattern`
- **State is held in `AppUiState.trips` and the Stage A `ActiveTripStore`.**
- **Mark done** adds the current path to `completedPaths` and removes it from
  `skippedPaths`.
- **Skip** adds the current path to `skippedPaths` and removes it from
  `completedPaths`.
- **Undo** steps `sequenceIndex` back and clears that restored path from both
  `completedPaths` and `skippedPaths`.
- **End-trip review is additive and must save coverage before ending the
  trip.**
- **Row done/skip/undo are optimistic** — they persist the Stage A snapshot,
  then call the server.
- **On failure the UI rolls back**, while the Stage A snapshot may still
  preserve the optimistic local state as the freshest local work.

### Current server write shape

`TripRepository.updateTripCoverage(...)` / `TripCoveragePatch` PATCHes:

- `completed_paths`
- `skipped_paths`
- `sequence_index`
- `current_row_number`
- `next_row_number`
- `client_updated_at`

Notes:

- **`completed_paths` and `skipped_paths` are whole-array replacements.**
- **`sequence_index` can regress** if stale data is replayed.
- **Row sequence / tracking pattern are row-plan setup fields** and are **not**
  part of the coverage PATCH.

### Ordering / clobber risks

- **Done/skip/undo are order-sensitive.**
- **Undo semantics are especially sharp** because the current implementation
  does not store the original action type.
- **Stale snapshot replay could reduce server progress.**
- **Stale replay could move `sequence_index` backwards.**
- **Completing and skipping the same row must be deterministic.**
- **Multi-device editing can diverge.**
- **End-trip replay must remain deferred** until row coverage replay is proven.
- **GPS replay and row replay touch different columns** and must stay on
  separate discriminators.

### Options considered

Options compared:

- whole-coverage snapshot replay with guard,
- append-only row-action event log,
- coalesced coverage marker using the Stage A snapshot,
- separate `TRIP_ROW` pending type,
- broad `TRIP` update,
- server-side merge/RPC,
- client-side fetch/merge/PATCH.

Decision:

- **No schema/RPC change for this slice.**
- **Do not use broad `TRIP`.**
- **Do not implement a full row-action event log yet.**
- **Prefer a coalesced marker + Stage A snapshot, mirroring C-1.**

### Recommended Stage D approach

- Add a future **`PendingEntityType.TRIP_ROW`**.
- **One coalesced marker per trip** using `clientId = tripId`.
- **The Stage A snapshot is the local coverage source.**
- **Replay fetches the live server trip first.**
- **Union-merge `completedPaths` / `skippedPaths`.**
- **Deterministic tie-break:** completed wins over skipped for the same path.
- **Never reduce server completed/skipped progress.**
- **Never move `sequence_index` backwards in D-1.**
- **Block rather than overwrite on stale/conflicting state.**
- **Trip-end replay remains deferred.**

### Marker / discriminator design

Future marker:

- `entityType = TRIP_ROW`
- `opType = UPDATE`
- `clientId = tripId`

Suggested payload:

- `tripId`
- `baseCompletedCount`
- `baseSkippedCount`
- `baseSequenceIndex`
- `baseClientUpdatedAt`
- `clientUpdatedAt`
- `savedAt`

Notes:

- **One marker per trip.**
- **No per-row pending rows in D-1.**
- **Local coverage comes from the Stage A snapshot.**
- **Separate from `TRIP_GPS` and `TRIP_METADATA`.**
- **Sync Status label should be "Trip rows".**

### Conflict / merge strategy

- **Compare server coverage fields against the local Stage A snapshot and
  marker baseline.**
- **PATCH merged coverage only when local adds safe progress.**
- **Skip / remove the marker when already synced.**
- **Block as Needs attention** when a regression/divergence would shrink server
  progress.
- **Retry transient/network/5xx/session-expired failures.**
- **Re-derive current/next row from the merged covered set and chosen index.**

### Replay algorithm design

Future **`TripRowSync`:**

- **Processes unresolved `TRIP_ROW` / `UPDATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Loads the Stage A snapshot for the same trip.**
- **Fetches the live server trip.**
- **Blocks missing / deleted / no-longer-active trips.**
- **Union-merges `completedPaths` / `skippedPaths`.**
- **Re-derives sequence index / current / next safely.**
- **PATCHes via the existing `updateTripCoverage(...)`.**
- **Reconciles the returned trip into `AppUiState.trips`.**
- **Refreshes the `ActiveTripStore` when relevant.**
- **Removes the marker on success.**
- **Retries / blocks with the existing attempt-cap pattern.**
- **Triggers on reconnect and after a successful vineyard/trip load.**

### Boundaries

- **Design only** — no code changed.
- **No row replay implemented.**
- **No trip start queueing.**
- **No trip end queueing.**
- **No tank/fill replay.**
- **No fuel logs.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No iOS changes.**

### Recommended next implementation slice

- **Stage D-1 should implement the `TRIP_ROW` marker + `TripRowSync`.**
- It should use **conservative union-merge and never shrink server progress.**
- **True undo-event semantics can remain parked** for a later event-log slice if
  required.
- **Stage B-2 trip-end summary should stay parked** until GPS and row replay are
  proven.

---

## Tier-A Stage D-1 — coalesced TRIP_ROW marker + TripRowSync coordinator (closed)

Offline queueing and replay for **row coverage progress only** (Done / Skip /
Undo) on existing active server trips, using a coalesced `TRIP_ROW` marker and
the Stage A active-trip snapshot as the local coverage source. **No trip start
queueing, no trip end queueing, no tank/fill replay, no fuel logs, no delete, no
final summaries, no server schema/RLS/RPC changes, no broad SyncManager, no iOS
changes.**

### What Android now supports

- **Android can now queue row done/skip/undo coverage progress** for existing
  active server trips.
- It uses a **coalesced pending marker, not one row per row action.**
- It replays by **fetching the live server trip, union-merging the local Stage A
  snapshot coverage with server coverage, re-deriving row position, and PATCHing
  guarded coverage.**
- This **does not cover** trip start, trip end, tank/fill replay, fuel logs,
  delete, or final summaries.

### Pending write discriminator

- **`PendingEntityType.TRIP_ROW` was added.**
- It is **distinct from broad `TRIP`, `TRIP_METADATA`, and `TRIP_GPS`.**
- It is used **strictly for row coverage replay.**
- It processes **`TRIP_ROW` / `UPDATE` only.**

### Marker payload

The queued marker is:

- `entityType = TRIP_ROW`
- `opType = UPDATE`
- `clientId = tripId`

Payload fields:

- `tripId`
- `baseCompletedCount`
- `baseSkippedCount`
- `baseSequenceIndex`
- `baseClientUpdatedAt`
- `clientUpdatedAt`
- `savedAt`

Notes:

- **No completed/skipped arrays are stored in the outbox row.**
- **Row coverage data remains in the Stage A `ActiveTripStore` snapshot.**

### Enqueue / rollback behaviour

- **`persistCoverage` still applies the optimistic row coverage locally.**
- **The Stage A snapshot is persisted.**
- **Known-offline** row done/skip/undo makes **no network call.**
- **Known-offline** row done/skip/undo **keeps the optimistic local coverage
  change.**
- **A coalesced `TRIP_ROW` marker is enqueued.**
- **A friendly saved-offline message is shown.**
- **Transient online coverage-save failures now keep optimistic local coverage
  and enqueue `TRIP_ROW`.**
- **Unauthorized still rolls back and signs out.**
- **No per-row pending rows are created.**

### Local snapshot source

- **Replay uses the Stage A `ActiveTripStore` as the local coverage source.**
- **The snapshot trip id must match.**
- **No matching snapshot means no invented coverage data.**
- **The marker is removed safely** when there is no local work to replay.

### Repository / PATCH body

- **Replay uses the existing `TripRepository.fetchTrip(id)`.**
- **Replay uses the existing `TripRepository.updateTripCoverage(...)`.**
- PATCH sends only:
  - `completed_paths`
  - `skipped_paths`
  - `sequence_index`
  - `current_row_number`
  - `next_row_number`
  - `client_updated_at`

Excluded PATCH fields:

- `row_sequence`
- `tracking_pattern`
- GPS/path
- `total_distance`
- tank sessions
- metadata
- trip start
- trip end
- delete
- fuel logs

### Merge / derive strategy

- **Replay fetches the live server trip first.**
- **Completed paths are unioned.**
- **Skipped paths are unioned.**
- **Completed wins over skipped** for the same path.
- **Server completed paths are never removed.**
- **Server skipped paths are only removed if now completed.**
- **`sequenceIndex` never moves backwards versus server in D-1.**
- **Current/next row are re-derived** from the server row sequence and chosen
  index.
- **PATCH is skipped and the marker removed** when nothing new is added.
- **A defensive non-destructive guard blocks unsafe shrink/regression** instead
  of overwriting.

### Replay coordinator

**`TripRowSync`:**

- **Processes unresolved `TRIP_ROW` / `UPDATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Triggers on reconnect and after a successful vineyard/trip load.**
- **Blocks missing / deleted / no-longer-active trips.**
- **Retries transient/network/5xx/session-expired failures.**
- **Blocks corrupt payloads, permission/validation failures, ended trips, and
  stale/unsafe merge conflicts.**
- **Uses an attempt cap consistent with existing replay paths.**
- **Reconciles the returned trip into `AppUiState.trips`.**
- **Preserves the longer live in-memory path during reconciliation.**
- **Refreshes the `ActiveTripStore` snapshot when relevant.**
- **Removes the marker on success.**

### Sync Status / UI

- **Sync Status label: "Trip rows".**
- **The pending count includes these markers.**
- **No new trip UI screens were added.**

### Stage interactions / scope

- **Stage A remains the local row coverage source.**
- **Stage B-1 `TRIP_METADATA` remains isolated.**
- **Stage C-1 `TRIP_GPS` remains isolated.**
- **D-1 does not touch GPS/path or metadata replay.**
- **Trip end replay remains deferred.**
- **Offline trip start remains deferred.**

No changes to:

- trip start
- trip end
- delete / soft delete
- GPS/path replay
- tank sessions
- fuel logs
- final summaries
- schema/RLS/RPC
- broad SyncManager
- iOS code

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

### Parked next steps

- **Stage E-1** — tank/fill replay (TRIP_TANK marker + TripTankSync). **Now
  audited/designed.**
- **Stage B-2** — trip-end summary queue, after GPS + row replay are proven.
- **Stage B-3** — offline trip start with client-id / provisional-trip
  reconciliation.
- **Stage F** — Sync Status / blocked recovery UX.

---

## Tier-A Stage E — tank/fill/engine-hour replay audit/design (closed / design only)

Read-only audit and design of the safest offline replay path for tank sessions,
fill timer state, and engine-hour fields without clobbering server trip state.
**No code changed, no tank replay implemented, no trip start queueing, no trip
end queueing, no GPS/path replay changes, no row coverage replay changes, no
fuel logs, no end-engine-hours replay, no schema/RLS/RPC changes, no broad
SyncManager, no iOS changes.**

### Current tank/fill/engine-hour flow

- **Tank/fill state lives on `Trip`**, with the key fields:
  - `tankSessions`
  - `activeTankNumber`
  - `isFillingTank`
  - `fillingTankNumber`
  - `startEngineHours`
  - `endEngineHours`
- **Stage A `ActiveTripStore` captures this automatically** because it persists
  the full serializable `Trip`.
- **`startTankSession`, `endTankSession`, `startFillTimer`, and `stopFillTimer`
  route through `persistTankSessions`.**
- **`startEngineHours` is already covered by Stage B-1.**
- **`endEngineHours` belongs with future trip-end summary work.**
- **Current tank/fill actions are optimistic** — they persist the Stage A
  snapshot, then PATCH.
- **Currently, non-Unauthorized failures roll back** and show a tank update
  error; **there is no offline queue yet.**

### Current server write shape

`TripRepository.updateTripTankSessions(...)` PATCHes:

- `tank_sessions`
- `active_tank_number`
- `is_filling_tank`
- `filling_tank_number`
- `client_updated_at`

Notes:

- **`tank_sessions` is a whole-array/blob replacement.**
- **Live tank fields are scalars.**
- **`start_engine_hours` is handled by B-1.**
- **`end_engine_hours` is deferred to trip-end summary.**
- **GPS/path, row coverage, row plan, metadata, trip start/end/delete, and fuel
  logs remain excluded.**

### Clobber / ordering risks

- **Whole-array tank session replacement can clobber server state.**
- **Stale replay could lose tank-end or fill-end events.**
- **Stale replay could reopen an ended tank.**
- **Duplicate sessions are possible** if not merged by stable id.
- **Stable `TankSession.id` allows union-by-id merge.**
- **Live scalar fields can become stale.**
- **Trip-end summary depends on tank replay being proven first.**
- **Stage E must stay isolated from `TRIP_METADATA`, `TRIP_GPS`, and
  `TRIP_ROW`.**

### Options considered

Options compared:

- whole tank snapshot replay with guard,
- append/merge by tank session id,
- coalesced `TRIP_TANK` marker using the Stage A snapshot,
- per-event tank log,
- broad `TRIP` update,
- server-side merge/RPC,
- client-side fetch/merge/PATCH.

Decision:

- **No schema/RPC change for this slice.**
- **Do not use broad `TRIP`.**
- **Do not implement a full per-event tank log yet.**
- **Prefer a coalesced marker + Stage A snapshot + client union-by-id
  merge/PATCH, mirroring C-1 and D-1.**

### Recommended Stage E approach

- Add a future **`PendingEntityType.TRIP_TANK`**.
- **One coalesced marker per trip** using `clientId = tripId`.
- **The Stage A snapshot is the local tank/fill source.**
- **Replay fetches the live server trip first.**
- **Merge tank sessions by stable id.**
- **Never drop a server tank session.**
- **For sessions with the same id, prefer the more-complete session:**
  - completed `endTime` over open,
  - completed `fillEndTime` over open fill,
  - otherwise local wins as the freshest local edit where safe.
- **Live scalar fields should be conservative:**
  - only assert local active/filling state when matching open sessions still
    exist in the merged set,
  - otherwise keep the server scalar or block.
- **Engine hours stay out of `TRIP_TANK`.**

### Marker / discriminator design

Future marker:

- `entityType = TRIP_TANK`
- `opType = UPDATE`
- `clientId = tripId`

Suggested payload:

- `tripId`
- `baseSessionCount`
- `baseActiveTankNumber`
- `baseClientUpdatedAt`
- `clientUpdatedAt`
- `savedAt`

Notes:

- **One marker per trip.**
- **No per-event rows in E-1.**
- **No session arrays in the outbox row.**
- **Local tank/fill data comes from the Stage A snapshot.**
- **Separate from `TRIP_METADATA`, `TRIP_GPS`, and `TRIP_ROW`.**
- **Sync Status label should be "Trip tanks".**

### Conflict / merge strategy

- **Compare** server tank sessions, local Stage A snapshot tank sessions, live
  tank scalars, and the marker baseline.
- **PATCH merged tank state** when local adds/advances safe tank session data.
- **Skip / remove the marker** when already synced.
- **Block as Needs attention** when a merge would drop/regress server sessions
  or reopen an ended tank.
- **Retry** transient/network/5xx/session-expired failures.

### Replay algorithm design

Future **`TripTankSync`**:

- **Processes unresolved `TRIP_TANK` / `UPDATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Loads the Stage A snapshot for the same trip.**
- **Fetches the live server trip.**
- **Blocks missing/deleted/no-longer-active trips.**
- **Union-merges sessions by id.**
- **Reconciles live tank scalars conservatively.**
- **PATCHes via existing `updateTripTankSessions(...)`.**
- **Reconciles the returned trip into `AppUiState.trips`.**
- **Preserves the longer live in-memory path during reconciliation.**
- **Refreshes `ActiveTripStore` when relevant.**
- **Removes the marker on success.**
- **Retries / blocks with the existing attempt-cap pattern.**
- **Triggers on reconnect and successful vineyard/trip load.**

### Recommended next implementation slice

- **Stage E-1 should implement the `TRIP_TANK` marker + `TripTankSync`.**
- **`persistTankSessions` should keep optimistic local changes and enqueue** on
  known-offline or transient failure.
- **Unauthorized should still roll back and sign out.**
- **Replay should use union-by-id tank-session merge and conservative
  live-scalar reconciliation.**
- **A per-event tank log remains parked** unless union-by-id proves
  insufficient.
- **Stage B-2 trip-end summary should stay parked** until tank replay is proven.

### Scope / safety

- **Design only** — no code changed.
- **No tank replay implemented.**
- **No trip start queueing.**
- **No trip end queueing.**
- **No GPS/path replay changes.**
- **No row coverage replay changes.**
- **No fuel logs.**
- **No end-engine-hours replay.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No iOS changes.**

---

## Tier-A Stage E-1 — coalesced TRIP_TANK marker + TripTankSync coordinator (closed)

Offline queueing and replay for **tank/fill changes on existing active server
trips**, using a coalesced `TRIP_TANK` marker and the Stage A active-trip
snapshot as the local tank/fill source. **No trip start queueing, no trip end
queueing, no GPS/path changes, no row coverage changes, no fuel logs, no
end-engine-hours replay, no server schema/RLS/RPC changes, no broad SyncManager,
no iOS changes.**

### What Android now supports

- **Android can now queue tank/fill changes** for existing active server trips.
- It uses a **coalesced pending marker, not one row per tank/fill event.**
- It replays by **fetching the live server trip, union-merging tank sessions by
  stable `TankSession.id`, reconciling live tank/fill scalars conservatively, and
  PATCHing guarded tank state.**
- This **does not cover** trip start, trip end, end-engine-hours, fuel logs,
  delete, or final summaries.

### Pending write discriminator

- **`PendingEntityType.TRIP_TANK` was added.**
- It is **distinct from broad `TRIP`, `TRIP_METADATA`, `TRIP_GPS`, `TRIP_ROW`,
  and the legacy unused `TANK_SESSION` placeholder.**
- It is used **strictly for tank/fill replay.**
- It processes **`TRIP_TANK` / `UPDATE` only.**

### Marker payload

The queued marker is:

- `entityType = TRIP_TANK`
- `opType = UPDATE`
- `clientId = tripId`

Payload fields:

- `tripId`
- `baseSessionCount`
- `baseActiveTankNumber`
- `baseClientUpdatedAt`
- `clientUpdatedAt`
- `savedAt`

Notes:

- **No `tankSessions` arrays are stored in the outbox row.**
- **Tank/fill data remains in the Stage A `ActiveTripStore` snapshot.**

### Enqueue / rollback behaviour

- **`persistTankSessions` still applies the optimistic tank/fill changes
  locally.**
- **The Stage A snapshot is persisted.**
- **Known-offline** tank/fill changes make **no network call.**
- **Known-offline** tank/fill changes **keep the optimistic local state.**
- **A coalesced `TRIP_TANK` marker is enqueued.**
- **A friendly saved-offline message is shown.**
- **Transient online tank/fill save failures now keep optimistic local state and
  enqueue `TRIP_TANK`.**
- **Unauthorized still rolls back and signs out.**
- **No per-event pending rows are created.**

### Local snapshot source

- **Replay uses the Stage A `ActiveTripStore` as the local tank/fill source.**
- **The snapshot trip id must match.**
- **No matching snapshot means no invented tank/fill data.**
- **The marker is removed safely** when there is no local work to replay.

### Repository / PATCH body

- **Replay uses the existing `TripRepository.fetchTrip(id)`.**
- **Replay uses the existing `TripRepository.updateTripTankSessions(...)`.**
- PATCH sends only:
  - `tank_sessions`
  - `active_tank_number`
  - `is_filling_tank`
  - `filling_tank_number`
  - `client_updated_at`

Excluded PATCH fields:

- `start_engine_hours`
- `end_engine_hours`
- GPS/path
- `total_distance`
- row coverage
- row plan
- metadata
- trip start
- trip end
- delete
- fuel logs

### Tank-session merge strategy

- **Replay fetches the live server trip first.**
- **Tank sessions are unioned by stable `TankSession.id`.**
- **Server sessions are never dropped.**
- **Local-only sessions are appended.**
- **Shared ids resolve to the more-complete session:**
  - closed `endTime` beats open,
  - closed `fillEndTime` beats open fill.
- **Server-closed sessions/fills are never reopened.**
- **Duplicates are avoided.**
- **PATCH is skipped and the marker removed** when nothing is added or advanced.
- **A defensive guard blocks unsafe shrink/regression/conflict** instead of
  overwriting.

### Live scalar reconcile

- **`activeTankNumber` is asserted from local only when a matching session is
  still open in the merged set.**
- **`isFillingTank` and `fillingTankNumber` are asserted from local only when a
  matching session still has an open fill.**
- **Ended tanks are not reopened.**
- **Stale local scalars do not clear or overwrite newer safe server scalars**
  unless the merge proves it is safe.
- **Otherwise the server scalar is preserved or the marker blocks.**

### Replay coordinator

**`TripTankSync`:**

- **Processes unresolved `TRIP_TANK` / `UPDATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Triggers on reconnect and after a successful vineyard/trip load.**
- **Blocks missing / deleted / no-longer-active trips.**
- **Retries transient/network/5xx/session-expired failures.**
- **Blocks corrupt payloads, permission/validation failures, ended trips, and
  stale/unsafe merge conflicts.**
- **Uses an attempt cap consistent with existing replay paths.**
- **Reconciles the returned trip into `AppUiState.trips`.**
- **Preserves the longer live in-memory path during reconciliation.**
- **Refreshes the `ActiveTripStore` snapshot when relevant.**
- **Removes the marker on success.**

### Sync Status / UI

- **Sync Status label: "Trip tanks".**
- **The pending count includes these markers.**
- **No new trip UI screens were added.**

### Stage interactions / scope

- **Stage A remains the local tank/fill source.**
- **Stage B-1 `TRIP_METADATA` remains isolated and still owns start-engine-hours.**
- **Stage C-1 `TRIP_GPS` remains isolated.**
- **Stage D-1 `TRIP_ROW` remains isolated.**
- **E-1 does not touch GPS/path, row coverage, metadata, trip-end, or
  engine-hour replay.**
- **Trip end replay remains deferred.**
- **Offline trip start remains deferred.**

No changes to:

- trip start
- trip end
- delete / soft delete
- GPS/path replay
- row coverage replay
- fuel logs
- final summaries
- schema/RLS/RPC
- broad SyncManager
- iOS code

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

### Parked next steps

- **Stage B-2** — trip-end summary queue, after GPS + row + tank replay are
  proven.
- **Stage B-3** — offline trip start with client-id / provisional-trip
  reconciliation.
- **Stage F** — Sync Status / blocked recovery UX.
- **A per-event tank log remains parked** unless union-by-id proves
  insufficient.
- **End-engine-hours stays with future trip-end work.**

---

## Tier-A Stage B-2 — trip-end summary queue audit/design (closed / design only)

Read-only audit and design of the safest offline replay path for **ending an
existing active server trip** without finalising stale GPS, row, tank, or
engine-hour state. **No code changed, no trip-end queue implemented, no offline
trip start, no delete queueing, no fuel logs, no schema/RLS/RPC changes, no broad
SyncManager, no iOS changes.**

### Current trip-end flow

- **`endTrip(...)`** currently captures tracker points/distance, **stops and
  nulls the tracker**, clears tracking/row-lock state, then calls
  `TripRepository.endTrip(...)`.
- **On success**, the returned trip is reconciled and the **Stage A snapshot
  clears** because the trip is no longer active.
- **On failure**, there is **no offline queue** — the server trip remains active
  while local capture has already been torn down.
- **`endTripWithRowReview(...)`** saves row review coverage first, then calls
  `endTrip(...)`.
- **If row review coverage save fails, the trip is not ended.** This
  review-before-end invariant must be preserved.

### Current server write shape

`TripEndPatch` fields:

- `is_active = false`
- `is_paused = false`
- `end_time`
- `total_distance`
- `path_points`
- `completion_notes`
- `end_engine_hours`
- `client_updated_at`

Notes:

- **`is_active`, `is_paused`, and `end_time` are finalisers.**
- **`path_points` and `total_distance` duplicate GPS-owned data** and can clobber
  if stale.
- **Row coverage and tank sessions are not included** in the end patch.
- **Safe marker fields are** completion notes, end engine hours, and requested
  end time.

### Ordering dependencies

A queued trip end must replay **only after unresolved same-trip dependencies
clear**:

- `TRIP_GPS`
- `TRIP_ROW`
- `TRIP_TANK`
- relevant `TRIP_METADATA`

Specifically:

- **Trip end must not freeze stale GPS/path data.**
- **Trip end must not run before row review choices are persisted.**
- **Trip end must not run before tank/fill replay is persisted.**
- **Trip end should not run while relevant metadata/pause/start-engine work
  remains pending.**

### Options considered

Options compared:

- queue full end-trip payload,
- queue a lightweight end marker and derive final state at replay,
- block end while other trip markers are pending,
- force immediate GPS/row/tank replay then end,
- broad `TRIP` / blob update,
- server-side finalise RPC,
- client-side fetch/merge/final PATCH.

Decision:

- **No schema/RPC change for this slice.**
- **No broad `TRIP`.**
- **Do not store path/row/tank arrays in the end marker.**
- **Prefer a lightweight `TRIP_END` marker + dependency-gated replay.**

### Recommended Stage B-2 approach

- Add a future **`PendingEntityType.TRIP_END`**.
- **One marker per trip** using `clientId = tripId`.
- **The Stage A snapshot is the local source** for completion notes, end engine
  hours, and requested end time.
- **The marker stores no path, row, or tank arrays.**
- **Replay dependency-gates** on same-trip `TRIP_GPS`, `TRIP_ROW`, `TRIP_TANK`,
  and relevant `TRIP_METADATA`.
- **After dependencies clear, replay fetches the live server trip.**
- **The final PATCH derives `path_points` and `total_distance` from the live
  server trip after GPS replay**, not from stale local arrays.
- **Block rather than end with stale/unsafe state.**

### Marker / discriminator design

Future marker:

- `entityType = TRIP_END`
- `opType = UPDATE`
- `clientId = tripId`

Suggested payload:

- `tripId`
- `completionNotes`
- `endEngineHours`
- `requestedEndTime`
- `baseClientUpdatedAt`
- `clientUpdatedAt`
- `savedAt`

Notes:

- **One marker per trip.**
- **No full path/tank/row arrays in the marker.**
- **Sync Status label should be "Trip end".**

### Conflict / dependency strategy

- **Unresolved dependency markers for the same trip** should defer/retry end,
  **not finalise**.
- **Missing/deleted live trip** should block.
- **Already-ended live trip** should skip/remove the marker safely.
- **Stale server/client conflict** should block as Needs attention.
- **Transient/network/5xx/session-expired failures** should retry.
- **Permanent validation/permission/corrupt-payload failures** should block.

### Offline end behaviour design

Intended behaviour when the user ends a trip offline:

- **Apply an optimistic local ended state.**
- **Tracking stops locally.**
- **Further GPS/row/tank actions are gated after local end.**
- **The Stage A snapshot must be preserved until the end marker successfully
  syncs** — do not clear the active-trip snapshot too early.
- **The end-trip summary may display as completed locally with pending sync.**
- **`is_active = false` must not be written until replay.**
- **Offline end-with-review must keep/enqueue row coverage work** so the
  dependency gate lands row coverage before trip end.

### Replay algorithm design

Future **`TripEndSync`**:

- **Processes unresolved `TRIP_END` / `UPDATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Triggers on reconnect and after a successful vineyard/trip load.**
- **Dependency-gates** on same-trip `TRIP_GPS`, `TRIP_ROW`, `TRIP_TANK`, and
  relevant `TRIP_METADATA`.
- **Loads the Stage A snapshot for the same trip.**
- **Fetches the live server trip.**
- **Blocks missing/deleted trips.**
- **Skips/removes if already ended.**
- **Derives the final PATCH from live path/distance** plus marker/snapshot notes
  and end engine hours.
- **Calls the existing `TripRepository.endTrip(...)`.**
- **Reconciles the returned trip into `AppUiState.trips`.**
- **Clears the Stage A snapshot only after a successful server end.**
- **Removes the marker on success.**
- **Retries / blocks with the existing attempt-cap pattern.**
- **Sync Status label "Trip end".**

### Recommended next implementation slice

- **Stage B-2-1 should implement the `TRIP_END` marker + `TripEndSync`.**
- **`endTrip(...)` / `endTripWithRowReview(...)` should enqueue and preserve
  local ended state** on known-offline / transient failure.
- **Unauthorized should still sign out.**
- **The dependency gate is mandatory.**
- **Existing early tracker teardown / snapshot clearing must be reworked** so a
  deferred/offline end does not lose local trip state.

### Scope / safety

- **Design only** — no code changed.
- **No trip-end queue implemented.**
- **No offline trip start.**
- **No delete queueing.**
- **No fuel logs.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No iOS changes.**

### Parked future work

- **Stage B-2-1** — trip-end summary queue implementation.
- **Stage B-3** — offline trip start with client-id / provisional-trip
  reconciliation.
- **Stage F** — Sync Status / blocked recovery UX.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage B-2-1 — TRIP_END marker + TripEndSync coordinator (closed)

Offline queueing and replay for **trip-end summaries on existing active server
trips**, using a lightweight `TRIP_END` marker and dependency-gated replay so the
server trip is never finalised over stale GPS, row, tank, or metadata state. **No
offline trip start, no delete queueing, no fuel logs, no schema/RLS/RPC changes,
no broad SyncManager, no iOS changes.**

### What Android now supports

- **Android can now queue trip-end summaries** for existing active server trips.
- Trip end uses a **lightweight marker, not a full trip snapshot.**
- **Server finalisation is dependency-gated** behind same-trip GPS, row, tank,
  and relevant metadata replay.
- **Final path/distance are derived from the live server trip** after
  dependencies clear.
- This **does not cover** offline trip start, delete queueing, fuel logs,
  schema/RPC changes, or iOS.

### Pending write discriminator

- **`PendingEntityType.TRIP_END` was added.**
- It is **distinct from broad `TRIP`, `TRIP_METADATA`, `TRIP_GPS`, `TRIP_ROW`,
  and `TRIP_TANK`.**
- It is used **strictly for trip-end replay.**

### Marker payload

The queued marker is:

- `entityType = TRIP_END`
- `opType = UPDATE`
- `clientId = tripId`

Payload fields:

- `tripId`
- `completionNotes`
- `endEngineHours`
- `requestedEndTime`
- `baseClientUpdatedAt`
- `clientUpdatedAt`
- `savedAt`

Excluded marker data:

- path points
- row coverage arrays
- tank sessions
- metadata payloads
- fuel logs
- trip start/delete fields

### Dependency gate

- **`TripEndSync` checks unresolved same-trip dependencies before finalising:**
  - `TRIP_GPS`
  - `TRIP_ROW`
  - `TRIP_TANK`
  - relevant `TRIP_METADATA`
- **If dependencies exist:**
  - **server end is not written,**
  - **the Stage A snapshot is not cleared,**
  - **the marker is deferred without consuming retry attempts,**
  - **blocked dependencies also prevent finalisation.**
- **Replay triggers run `TRIP_END` after GPS/row/tank/metadata replay attempts.**

### Offline / transient end behaviour

- **`endTrip(...)` folds the final tracker path/distance into the local trip and
  Stage A snapshot before local end.**
- **Tracking is stopped locally.**
- **Row-lock/tracking state is cleared locally.**
- **Known-offline end enqueues `TRIP_GPS` then `TRIP_END`.**
- **Transient online failure follows the same queued local-ended path.**
- **The user sees a friendly saved-offline message.**
- **Local ended state is tracked via `locallyEndedTripIds`.**
- **`activeTrip` excludes locally-ended ids.**
- **Row/tank actions are gated after local end.**
- **The Stage A snapshot is preserved until server end succeeds.**
- **Unauthorized still signs out.**

### Review-before-end behaviour

- **`endTripWithRowReview(...)` applies review coverage locally first.**
- **It persists the Stage A snapshot.**
- **It enqueues/keeps `TRIP_ROW` when offline/transient.**
- **It then enqueues `TRIP_END`.**
- **The dependency gate guarantees row coverage lands before server
  finalisation.**
- **Review choices are not lost.**

### Final state derivation

- **After dependencies clear, replay fetches the live server trip.**
- **Missing/deleted trips block.**
- **Already-ended live trips remove the marker safely.**
- **The final PATCH uses live server `pathPoints` and `totalDistance`.**
- **The final PATCH uses marker/snapshot `completionNotes`, `endEngineHours`, and
  `requestedEndTime`.**
- **Stale local path arrays are not used for finalisation.**
- **Row/tank arrays are not included in the end PATCH.**

### Repository / PATCH body

- **`TripRepository.endTrip(...)` now accepts an optional `endTime`.**
- **The default live end still uses the current time.**
- **Replay passes the requested end time.**
- `TripEndPatch` sends only:
  - `is_active = false`
  - `is_paused = false`
  - `end_time`
  - `total_distance`
  - `path_points`
  - `completion_notes`
  - `end_engine_hours`
  - `client_updated_at`

Excluded PATCH fields:

- row coverage
- tank sessions
- metadata
- fuel logs
- delete fields
- start fields

### Replay coordinator

**`TripEndSync`:**

- **Processes unresolved `TRIP_END` / `UPDATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Dependency-gates before fetch/finalisation.**
- **Fetches the live trip.**
- **Blocks missing/deleted trips.**
- **Skips/removes already-ended trips.**
- **Calls `endTrip(...)` with the final derived state.**
- **Reconciles the returned trip into `AppUiState.trips`.**
- **Clears the locally-ended flag on success.**
- **Clears the Stage A snapshot only after a successful server end.**
- **Removes the marker on success.**
- **Retries transient/network/5xx/session-expired failures.**
- **Blocks corrupt payloads, permission/validation failures, stale conflicts,
  and unsafe states.**
- **Uses an attempt cap consistent with existing replay paths.**

### Sync Status / UI

- **Sync Status label: "Trip end".**
- **The pending count includes these markers.**
- **No new screens were added.**

### Stage interactions / scope

- **`TRIP_GPS` must clear before `TRIP_END` finalises.**
- **`TRIP_ROW` must clear before `TRIP_END` finalises.**
- **`TRIP_TANK` must clear before `TRIP_END` finalises.**
- **Relevant `TRIP_METADATA` must clear before `TRIP_END` finalises.**
- **The Stage A snapshot is preserved until a successful server end.**
- **B-2-1 reuses existing enqueue/replay hooks** without modifying GPS/row/tank
  implementation internals.

No changes to:

- offline trip start
- delete / soft delete queueing
- fuel logs
- schema/RLS/RPC
- broad SyncManager
- iOS code

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`; a **missing
  `TripEndSync` import was fixed during implementation.**
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

### Parked next steps

- **Stage B-3** — offline trip start with client-id / provisional-trip
  reconciliation.
- **Stage F** — Sync Status / blocked recovery UX.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage B-3 — offline trip start / provisional-trip reconciliation audit/design (closed / design only)

Read-only audit and design of the safest way to **start a trip offline**, create
a local provisional trip, capture GPS/row/tank work against it, then replay the
trip start and reconcile all dependent markers without corrupting data. **No code
changed, no offline start implemented, no delete queueing, no fuel logs, no
schema/RLS/RPC changes, no broad SyncManager, no iOS changes.**

### Current trip-start flow

- **`startTrip(...)` is currently online-only and server-return-first.**
- It calls **`TripRepository.createTrip(...)`**.
- **`createTrip(...)` currently generates a UUID inside the repository** during
  the network call.
- **The trip only enters `AppUiState.trips` after the server returns.**
- **`beginTracking(...)` only starts after the returned row exists.**
- **If create fails before server return, no trip, tracker, or Stage A snapshot
  is created.**
- This is the **remaining major Tier-A functional gap.**

### Current server insert shape

`TripInsert` fields:

- `id`
- vineyard id
- paddock id/name
- person / function / title
- machine / work task / operator fields
- start time
- active / paused fields
- total distance / path defaults
- start engine hours
- created by
- client updated timestamp

Notes:

- **Scalar identity/job fields are safe for a queued start marker.**
- **`path_points` / `total_distance` should remain default/empty at insert** and
  be owned by `TRIP_GPS`.
- **Row-plan fields should remain separate.**
- **Tank sessions should remain owned by `TRIP_TANK`.**
- **End fields remain owned by `TRIP_END`.**

### Provisional trip decision

Chosen approach:

- **Generate the final UUID on the client before attempting network create.**
- **Use that same UUID as the final server trip id.**
- **Create a local active trip immediately when offline or on transient
  failure.**
- **Insert it into `AppUiState.trips`.**
- **Start tracking locally.**
- **Persist the Stage A snapshot immediately.**
- **Enqueue `TRIP_START`.**

Why:

- **No id remapping is required.**
- **GPS/row/tank/metadata/end markers can all attach to the same final trip id.**
- **The trip id is also the idempotency key.**
- **UUID collision risk is negligible.**

Rejected options:

- separate provisional id with later remap,
- keeping offline start blocked,
- requiring connectivity for start.

### Dependency / reconciliation design

- **Dependent markers can use the same client-generated final trip id.**
- **No id remapping is needed.**
- **If `TRIP_START` is unresolved, same-trip dependent markers must
  defer/block:**
  - `TRIP_METADATA`
  - `TRIP_GPS`
  - `TRIP_ROW`
  - `TRIP_TANK`
  - `TRIP_END`
- **If `TRIP_START` blocks permanently, dependents must not write to a
  non-existent server trip.**
- **If the app restarts before start syncs, the Stage A snapshot plus the
  pending `TRIP_START` marker should restore the local trip.**

### Replay ordering

Required replay order:

- **`TRIP_START` first,**
- **then `TRIP_METADATA` / `TRIP_GPS` / `TRIP_ROW` / `TRIP_TANK`,**
- **then `TRIP_END` last.**

Notes:

- **`replayPendingTripStart()` should run first on reconnect and post-load.**
- **Dependent coordinators should gate on unresolved same-trip `TRIP_START`.**
- **`TripEndSync` should also include `TRIP_START` in its dependency gate.**

### Marker / discriminator design

Future marker:

- `PendingEntityType.TRIP_START`
- `opType = CREATE`
- `clientId = tripId`

Suggested payload:

- `tripId`
- `vineyardId`
- `paddockId`
- `paddockName`
- `personName`
- `tripFunction`
- `tripTitle`
- `machineId`
- `workTaskId`
- `operatorUserId`
- `operatorCategoryId`
- `startTime`
- `startEngineHours`
- `clientUpdatedAt`
- `savedAt`

Excluded marker data:

- path points
- total distance
- tank sessions
- row-plan arrays
- completion/end fields
- delete fields

**Sync Status label should be "Trip start".**

### Local offline-start behaviour design

Intended behaviour:

- **Generate the final trip UUID client-side.**
- **Build a local active `Trip`.**
- **Prepend it to `AppUiState.trips`.**
- **Call `beginTracking(...)`.**
- **Persist the Stage A snapshot.**
- **Enqueue one `TRIP_START` marker.**
- **Allow GPS/row/tank/metadata/end markers to attach to the same id.**
- **Show a friendly message** — "Trip started offline — it'll sync when
  connection returns."
- **Local end can enqueue `TRIP_END`, now gated behind `TRIP_START`.**

### Replay algorithm design

Future **`TripStartSync`**:

- **Processes unresolved `TRIP_START` / `CREATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Probes `fetchTrip(tripId)` first for idempotency.**
- **If the server row already exists, treat as success and reconcile.**
- **If absent, creates the server trip row using the queued id.**
- **Reconciles the returned trip into `AppUiState.trips`.**
- **Preserves the live local path during reconciliation.**
- **Refreshes the Stage A snapshot.**
- **Removes the marker on success.**
- **Retries transient/network/5xx/session-expired failures.**
- **Blocks corrupt payloads and permission/validation failures.**
- **Uses an attempt cap consistent with existing replay paths.**

### Conflict / idempotency strategy

- **Server already has the same id** means the insert likely succeeded but the
  response was lost.
- **`fetchTrip(id)` is the idempotency probe.**
- **Duplicate trips are prevented** because the primary key equals the client
  UUID.
- **Duplicate UUID collision is negligible.**
- **If the same id somehow exists, the client adopts/reconciles the existing row**
  rather than creating another.

### Mandatory restore rule change

- **`restoreActiveTrip(...)` currently clears a snapshot absent from a fresh
  server list.**
- **With offline start, a provisional trip is legitimately absent from the server
  until `TRIP_START` lands.**
- **Stage B-3-1 must not clear an active-trip snapshot that has an unresolved
  `TRIP_START` marker for the same trip.**

### Recommended next implementation slice

- **Stage B-3-1 should implement:**
  - the `TRIP_START` marker,
  - `TripStartSync`,
  - explicit id support in `TripRepository.createTrip(...)`,
  - the offline/transient `startTrip(...)` local provisional-trip path,
  - replay ordering with start first,
  - dependent gates on unresolved `TRIP_START`,
  - the restore-rule fix for unresolved `TRIP_START`.
- **The online path should remain behaviourally unchanged** except the id is
  generated before the repository create.

### Scope / safety

- **Design only** — no code changed.
- **No offline start implemented.**
- **No delete queueing.**
- **No fuel logs.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No iOS changes.**

### Parked future work

- **Stage B-3-1** — offline trip start implementation.
- **Stage F** — Sync Status / blocked recovery UX.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage B-3-1 — TRIP_START marker + TripStartSync coordinator (closed)

Offline trip start for new trips using a **client-generated final trip id**, a
**local provisional active trip**, and a **lightweight `TRIP_START` create
marker** with dependency-ordered replay. **No delete queueing, no fuel logs, no
schema/RLS/RPC changes, no broad SyncManager, no iOS changes.**

### What Android now supports

- **Android can now start a trip offline.**
- **The app generates the final trip UUID client-side before attempting network
  create.**
- **Offline/transient start creates a local active trip immediately.**
- **Tracking starts locally.**
- **The Stage A active-trip snapshot is persisted.**
- **A `TRIP_START` marker is queued.**
- **Dependent GPS/row/tank/metadata/end markers attach to the same final trip
  id.**
- **No id remapping is required.**

### Pending write discriminator

- **`PendingEntityType.TRIP_START` was added.**
- It is **distinct from broad `TRIP`, `TRIP_METADATA`, `TRIP_GPS`, `TRIP_ROW`,
  `TRIP_TANK`, and `TRIP_END`.**
- It uses **`opType = CREATE`.**
- It is **used strictly for trip-start replay.**

### Marker payload

Queued marker shape:

- `entityType = TRIP_START`
- `opType = CREATE`
- `clientId = tripId`

Payload fields:

- `tripId`
- `vineyardId`
- `paddockId`
- `paddockName`
- `personName`
- `tripFunction`
- `tripTitle`
- `machineId`
- `workTaskId`
- `operatorUserId`
- `operatorCategoryId`
- `startTime`
- `startEngineHours`
- `clientUpdatedAt`
- `savedAt`

Excluded marker data:

- path points
- total distance
- row coverage arrays
- row-plan arrays
- tank sessions
- completion/end fields
- delete fields
- fuel logs

### Repository explicit-id support

- **`TripRepository.createTrip(...)` now accepts an optional explicit id.**
- **The provided id is used verbatim in `TripInsert.id`.**
- **When id is null, it falls back to a new UUID as before.**
- **Optional `startTime` and `clientUpdatedAt` are supported** for
  replay/idempotency.
- **The online happy path remains behaviourally unchanged** except id generation
  can happen before the call.

### Offline / transient start behaviour

- **`startTrip(...)` generates the final UUID and start instant up front.**
- **Known-offline start builds a local active trip.**
- **The local trip is prepended to `AppUiState.trips`.**
- **`beginTracking(...)` starts local GPS tracking.**
- **The Stage A snapshot is persisted.**
- **One coalesced `TRIP_START` marker is enqueued.**
- **A friendly message is shown** — "Trip started offline — it'll sync when
  connection returns."
- **The caller receives success.**
- **Transient online create failure falls back to the same local-start path with
  the same id.**
- **Unauthorized signs out and does not enqueue.**

### Local trip construction

- **The provisional local trip uses the client-generated final id.**
- `isActive = true`
- `isPaused = false`
- `totalDistance = 0.0`
- `pathPoints = []`
- **Includes vineyard/paddock/job/operator scalars.**
- **Includes start time.**
- **Includes optional start engine hours.**
- **Includes the client updated timestamp.**
- **Contains no row/tank/end data in the start marker.**

### TripStartSync replay / idempotency

**`TripStartSync`**:

- **Processes unresolved `TRIP_START` / `CREATE` only.**
- **Requires session + online.**
- **Uses a mutex/overlap guard.**
- **Runs before all dependent replay coordinators.**
- **Decodes the payload.**
- **Probes `fetchTrip(tripId)` before insert.**
- **Treats an existing server row as success.**
- **Creates the server trip using the queued id when absent.**
- **Reconciles the returned/existing trip into `AppUiState.trips`.**
- **Preserves the longer live local path when reconciling.**
- **Refreshes the Stage A snapshot when relevant.**
- **Removes the marker on success.**
- **Retries transient/network/5xx/session-expired failures.**
- **Blocks corrupt payloads and permission/validation failures.**
- **Uses an attempt cap consistent with existing replay paths.**

### Replay ordering

Replay order on reconnect and post-load:

- `TRIP_START`
- `TRIP_METADATA`
- `TRIP_GPS`
- `TRIP_ROW`
- `TRIP_TANK`
- `TRIP_END`

### Dependent gates

- **`TRIP_METADATA`, `TRIP_GPS`, `TRIP_ROW`, and `TRIP_TANK` defer while an
  unresolved same-trip `TRIP_START` exists.**
- **Waiting on `TRIP_START` does not consume retry attempts.**
- **A blocked `TRIP_START` also holds dependents.**
- **`TripEndSync` includes `TRIP_START` in its dependency gate.**
- **Dependents never write to the server before the trip exists.**

### Restore rule fix

- **`restoreActiveTrip(...)` no longer clears a Stage A snapshot that is absent
  from a fresh server list when an unresolved `TRIP_START` exists for the same
  id.**
- **The provisional trip is re-injected/restored.**
- **Genuinely stale snapshots still clear when no unresolved `TRIP_START`
  exists.**

### Sync Status / UI

- **Sync Status label: "Trip start".**
- **The pending count includes these markers.**
- **No new screens were added.**

### Stage interactions / completed chain

- **Dependent markers attach to the same client-generated final trip id.**
- **No id remapping is needed.**
- **The Stage A snapshot remains the local source for active trip state.**
- **`TRIP_START` success unblocks dependents.**
- **`TRIP_END` remains last.**
- **The Tier-A active-trip offline chain now includes:**
  - `TRIP_START`
  - `TRIP_METADATA`
  - `TRIP_GPS`
  - `TRIP_ROW`
  - `TRIP_TANK`
  - `TRIP_END`

### Scope / safety

- **No delete / soft-delete queueing.**
- **No fuel logs.**
- **No schema/RLS/RPC changes.**
- **No broad SyncManager.**
- **No iOS changes.**

### Build / check reference

- **Implementation `runChecks` passed** for `android-vinetrack`; an initial
  companion-object conflict was fixed during implementation.
- **QA `runChecks` passed** for `android-vinetrack`; **no code changed during
  QA.**

### Parked future work

- **Stage F** — Sync Status / blocked recovery UX.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage F — Sync Status / blocked recovery UX (closed / design only)

**Status: CLOSED / DESIGN ONLY.** Tier-A Stage F audit/design — Sync Status /
blocked recovery UX. This was an audit/design-only pass: **no app code changed**
and no correctness bug was found that warranted a fix.

### Current Sync Status surface

- `SyncStatusScreen` is currently **read-only**.
- It shows connection state, pending sync count, pending photo counts, saved
  field-data / cache status, and a per-item pending list.
- Per-item rows show a title, a status label, and an optional raw `lastError`.
- **No retry, dismiss, recovery, or item-level actions exist yet.**
- The pending count comes from unresolved pending writes.
- Current status labels include: **Waiting to sync**, **Syncing**, **Will retry**,
  and **Needs attention**.
- `BLOCKED` maps to **Needs attention**.
- `FAILED` maps to **Will retry**, even when the item is actually waiting on a
  dependency.

### Current pending write model

Available recovery fields on each pending write:

- `id`, `entityType`, `opType`, `payloadJson`, `clientId`, `createdAt`,
  `updatedAt`, `attemptCount`, `lastError`, `status`.

Status lifecycle: `PENDING`, `IN_PROGRESS`, `SYNCED`, `FAILED`, `BLOCKED`.

- **Unresolved** includes `PENDING`, `IN_PROGRESS`, `FAILED`, and `BLOCKED`.
- `FAILED` is retry-eligible.
- `BLOCKED` usually means terminal until the underlying issue is resolved.
- Attempt count is incremented only for real transient failures.
- Dependency-deferred items use `FAILED` **without** consuming attempts.
- Trip markers coalesce by trip id.
- Pin writes coalesce / key by pin id where applicable.
- Pin photos use separate pending-photo storage.

### Current replay failure semantics

The common coordinator pattern:

- Retryable network / 5xx / expired-session / transient failures become `FAILED`.
- Retryable failures eventually become `BLOCKED` after the attempt cap.
- Corrupt payloads, permission/validation rejections, missing/deleted rows,
  unsafe conflicts, and missing snapshots/photos become `BLOCKED`.
- Dependency-deferred items become `FAILED` without incrementing attempt count.
- Dependencies can clear automatically on later replay.
- Blocked items do not automatically recover unless the underlying issue is
  resolved.

**Central UX finding:** `FAILED` is overloaded. It can mean both a transient
error that will retry **and** a dependency wait that should show as waiting. The
current label **Will retry** is misleading for dependency-waiting items.

### Entity types covered

The current Sync Status / pending-write ecosystem includes: pin create, pin
completion, pin edit, pin photo counts (via pending-photo storage), `TRIP_START`,
`TRIP_METADATA`, `TRIP_GPS`, `TRIP_ROW`, `TRIP_TANK`, and `TRIP_END`.

### Recovery action safety classification

**Safe for early slices:**

- view clearer details,
- show derived display states,
- show attempt count,
- show friendly error text,
- retry all retryable/deferred items,
- retry item where safe,
- copy diagnostics.

**Safe but later / needs navigation:**

- open related pin/trip.

**Parked / unsafe for now:**

- dismiss/remove blocked item,
- archive blocked item,
- rebuild from local snapshot,
- force server overwrite,
- clear all local pending data,
- manual conflict editor,
- deleting pending photos,
- clearing active-trip snapshots from the UI.

### Recommended Stage F-1 scope

Stage F-1 should be **display/state clarity only**: no writes, no destructive
actions, no retry buttons yet, no schema/storage enum change. Derive display
state from existing fields rather than adding a new stored status enum.

Suggested derived labels:

- `PENDING` → **Waiting to sync**
- `IN_PROGRESS` → **Syncing…**
- `FAILED` + unresolved same-trip `TRIP_START` → **Waiting for trip start**
- `FAILED` + `TRIP_END` waiting on same-trip GPS/row/tank/metadata →
  **Waiting for trip changes**
- other `FAILED` → **Retrying**
- `BLOCKED` → **Needs attention**

Also: show item type / short label, show attempt count (e.g. **Attempt 3 of 8**),
and show friendly error text instead of raw server/code strings where possible.

### Dependency-waiting UX

- Dependency waiting should **not** look like a generic failure.
- `TRIP_METADATA`, `TRIP_GPS`, `TRIP_ROW`, `TRIP_TANK`, and `TRIP_END` may wait
  on `TRIP_START`.
- `TRIP_END` may wait on GPS/row/tank/metadata.
- A blocked `TRIP_START` holds dependents.
- Derived UI state can safely show **Waiting for trip start** or
  **Waiting for trip changes**.
- **No new persisted enum is required for F-1** — the UI can derive the state
  from current pending rows.

### Blocked item UX

- `BLOCKED` should display a clear, plain-language reason.
- Examples: permission/validation failure, corrupt payload, missing/deleted
  server row, unsafe conflict, missing local snapshot/photo, or attempt-cap
  exhaustion.
- Retry should be **disabled** for clearly non-retryable blocked items.
- Retry for blocked attempt-cap cases can be designed later.
- Dismissal / destructive cleanup remains parked.

### Safe retry design (later slices)

- Manual retry should reuse the existing **ordered** replay functions.
- Do **not** bypass dependency gates.
- Global retry should run the same order: trip start, metadata, GPS, row, tank,
  trip end, plus pin replay / photo replay in their existing safe order.
- Retry should reset eligible `FAILED`/deferred rows to `PENDING`.
- Retry should **not** reset attempt counts by default.
- Non-retryable blocked rows should be excluded.
- Recommend global **Retry all** first, then per-item retry later.

### Recovery boundaries (out of scope)

- force overwrite,
- manual conflict editor,
- destructive pending-row deletion,
- clearing active-trip snapshots,
- deleting local pending photos,
- schema/RLS/RPC changes,
- iOS changes.

### Recommended implementation slices

- **Stage F-1** — Sync Status display/state clarity only.
- **Stage F-2** — Retry all / retry item for retryable or deferred items using
  existing ordered replay.
- **Stage F-3** — Blocked-item details panel, copy diagnostics, optional open
  related pin/trip.
- **Stage F-4** — Carefully designed dismiss/archive flow, parked until needed.

### Build / check reference

- **Audit/design only — no code changed, no build required.**

### Parked future work

- **Stage F-1** — Sync Status display/state clarity.
- **Stage F-2** — retry actions (retry all / retry item).
- **Stage F-3** — blocked-item details / diagnostics.
- **Stage F-4** — dismiss/archive recovery design.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage F-1 — Sync Status display/state clarity (closed)

**Status: CLOSED.** Tier-A Stage F-1 — Sync Status display/state clarity only.
This slice improves how pending/replay items are presented; it is **display-only**
and changes no app behaviour.

### What Android now supports

- Sync Status now shows clearer user-facing states for **pending**, **syncing**,
  **retrying**, **dependency-waiting**, and **blocked** items.
- This is **display-only**.
- **No retry buttons, destructive actions, replay triggers, or pending-row
  mutations were added.**

### Files changed

- `ui/AppViewModel.kt`
  - added a UI-only `PendingSyncDisplayState`,
  - extended `PendingSyncItem`,
  - added dependency-aware display-state derivation,
  - added friendly error mapping.
- `ui/screens/SyncStatusScreen.kt`
  - renders the improved status label, friendly detail, attempt label, and
    de-emphasised raw diagnostic detail.

### Derived display states

- **No new persisted pending-write status enum was added.**
- Display state is derived from existing pending rows and same-trip dependency
  context.

Labels:

- `PENDING` → **Waiting to sync**,
- `IN_PROGRESS` → **Syncing…**,
- `FAILED` + unresolved same-trip `TRIP_START` → **Waiting for trip start**,
- `FAILED` + `TRIP_END` waiting on same-trip GPS/row/tank/metadata → **Waiting for
  trip changes**,
- other `FAILED` → **Retrying**,
- `BLOCKED` → **Needs attention**.

### Dependency-waiting logic

- Dependency state is computed **read-only** from the unresolved pending list.
- Unresolved `TRIP_START` trip ids are derived from `TRIP_START` / `CREATE`
  markers.
- Unresolved trip-change ids are derived from `TRIP_GPS`, `TRIP_ROW`, `TRIP_TANK`,
  and `TRIP_METADATA`.
- `TRIP_METADATA`, `TRIP_GPS`, `TRIP_ROW`, `TRIP_TANK`, and `TRIP_END` waiting on
  an unresolved start show **Waiting for trip start**.
- `TRIP_END` waiting on unresolved trip changes shows **Waiting for trip changes**.
- A blocked `TRIP_START` still holds dependents because `BLOCKED` is unresolved.
- **No pending row is mutated to show these labels.**

### PendingSyncItem / UI model

- `PendingSyncItem` now carries:
  - `displayStatusLabel`,
  - `friendlyDetail`,
  - `attemptLabel`,
  - `rawDetail`.
- This is **UI-layer only**.

### Attempt count display

- Attempt label shows as **Attempt N of 8**.
- Shown only for `FAILED` / `BLOCKED` items with `attemptCount > 0`.
- Pure dependency-waiting rows do not show an attempt count when no retry attempt
  has been consumed.

### Friendly error mapping

Friendly mappings cover:

- dependency wait,
- network / connection problem,
- server / 5xx problem,
- permission / forbidden,
- validation / bad request,
- missing / deleted row,
- corrupt payload,
- missing local snapshot / photo,
- attempt cap reached.

- The primary detail text is now user-friendly where possible.
- The raw detail is retained separately as de-emphasised diagnostic information
  when useful.

### SyncStatusScreen display

- The screen now shows the improved label, friendly detail, an attempt line when
  present, and de-emphasised raw diagnostic detail.
- Existing connection / cache / photo cards are unchanged.
- The existing pending count is unchanged.
- **No buttons were added.**

### Behaviour boundaries

- **No pending rows are mutated by opening Sync Status.**
- No replay is triggered from the screen.
- No retry action was added.
- No destructive action was added.
- No storage enum / status migration.
- No coordinator retry/block logic changed.
- No iOS changes.

### Build / check reference

- Implementation `runChecks` passed for `android-vinetrack`.

### Parked future work

- **Stage F-2** — Retry all / retry item for retryable or deferred items using
  existing ordered replay.
- **Stage F-3** — blocked-item details, copy diagnostics, optional open related
  pin/trip.
- **Stage F-4** — dismiss/archive recovery design.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage F-2 — Sync Status retry actions (closed)

**Status: CLOSED.** Tier-A Stage F-2 — global Retry all action for
retryable/deferred pending sync rows.

### What Android now supports

- Sync Status now exposes a safe global **Retry all** action.
- Retry uses the existing ordered replay pipeline.
- Retry does **not** perform direct server writes from the screen.
- Retry does **not** bypass dependency gates.
- Retry does **not** add destructive recovery actions.

### Files changed

- `data/PendingWriteRepository.kt`
  - added `retryEligibleCount()`,
  - added `resetFailedForRetry()`.
- `ui/AppViewModel.kt`
  - added `canRetrySync`,
  - added `isRetryingSync`,
  - added `retryPendingSync()`,
  - derives retry availability from pending writes.
- `ui/screens/SyncStatusScreen.kt`
  - added **Retry all** button,
  - added explanatory retry-safety text.
- `ui/main/MainScaffold.kt`
  - wired `onRetryAll = vm::retryPendingSync`.

### Eligible-row logic

- Only `FAILED` pending rows are retry-eligible.
- This includes real transient failures **and** dependency-deferred rows (which
  are represented as `FAILED`).
- `BLOCKED` rows are excluded.
- `PENDING`, `IN_PROGRESS`, and `SYNCED` rows are untouched.
- Blocked-cause classification is intentionally **not** attempted in F-2.

### Status reset behaviour

- `resetFailedForRetry()` changes eligible `FAILED` rows back to `PENDING`.
- Stale `lastError` is cleared.
- `updatedAt` is refreshed.
- Attempt count is **preserved**.
- No rows are removed.
- No server write occurs during reset.

### Replay trigger / order

`retryPendingSync()` runs the existing replay functions in this order:

1. pin creates,
2. pin completions,
3. pin edits,
4. trip start,
5. trip metadata,
6. trip GPS,
7. trip row,
8. trip tank,
9. trip end,
10. pin photos.

- No new per-entity write path was added.
- All existing mutex guards / coordinators remain in control.
- Attempt caps are preserved.

### Dependency safety

- Retry only resets status, then routes through existing coordinators.
- `TRIP_START` gates remain in force.
- `TRIP_END` dependency gate remains in force.
- Pin-photo pin-exists ordering remains in force.
- Dependency waiting remains safe.

### UI behaviour

- **Retry all** appears only when eligible failed rows exist and the device is
  online.
- Retry is disabled while `isRetryingSync`.
- Label changes to **Retrying…** while active.
- Explanatory text: *Retries use the normal sync order so trip changes stay
  safe.*
- Opening Sync Status still does **not** mutate rows.
- Retry is an explicit user action only.

### Pending photo handling

- Global retry calls the existing pending-photo replay **last**.
- No pending photo files are deleted.
- Pending photo block semantics are unchanged.

### Behaviour boundaries

No changes to:

- per-item retry,
- dismiss / remove / archive,
- force overwrite,
- snapshot clearing,
- pending-photo deletion,
- storage enum / status migration,
- schema / RLS / RPC,
- broad `SyncManager`,
- iOS code.

### Build / check reference

- Implementation `runChecks` passed for `android-vinetrack`.
- QA `runChecks` passed; no code changed during QA.

### Parked future work

- **Stage F-2b** — per-item retry routed safely through the ordered pipeline.
- **Stage F-3** — blocked-item details, copy diagnostics, optional open related
  pin/trip.
- **Stage F-4** — dismiss/archive recovery design.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage F-3 — blocked-item details and diagnostics (closed)

**Status: CLOSED.** Tier-A Stage F-3 — Sync Status blocked-item details and copy
diagnostics.

### What Android now supports

- Sync Status pending rows can now be opened for **read-only details**.
- Details are shown in a modal bottom sheet (read-only surface).
- Users can **copy sync diagnostics** for support/debugging.
- No retry, dismiss, remove, archive, overwrite, or destructive recovery actions
  were added.

### Files changed

- `ui/AppViewModel.kt`
  - extended `PendingSyncItem`,
  - added diagnostic text construction.
- `ui/screens/SyncStatusScreen.kt`
  - made pending rows tappable,
  - added details bottom sheet,
  - added **Copy diagnostics** action.

### PendingSyncItem / diagnostics fields

`PendingSyncItem` now carries UI-only fields for:

- display status label,
- friendly detail,
- attempt label,
- raw detail / last error,
- entity type,
- operation type,
- client id / related id,
- raw status,
- attempt count,
- created timestamp,
- updated timestamp,
- diagnostic text.

- Pending write storage is **unchanged**.
- No pending row is mutated to create diagnostics.

### Details UI

- Pending rows are tappable.
- Tap opens a read-only details surface (modal bottom sheet).
- The details surface can be dismissed.
- Opening/closing details does **not** mutate outbox rows.
- Details are available for **all** pending sync items, not only blocked items.

### Details content

Details show:

- item title,
- display status label,
- friendly detail,
- attempt label when present,
- readable entity type,
- operation type,
- related / client id,
- raw status,
- created / updated timestamps,
- de-emphasised raw diagnostic detail when useful.

- Payload JSON is **not** shown as primary UI.
- Secrets, tokens, session data, auth data, API keys, and Supabase keys are
  **not** exposed.

### Copy diagnostics

- **Copy diagnostics** copies a multi-line diagnostic block.
- Diagnostic text includes title, display state, entity type, operation, related
  id, status, attempts, created/updated timestamps, friendly detail, and raw
  diagnostic/error when present.
- Payload JSON is **excluded**.
- Secrets / tokens / auth / session / key material are **excluded**.
- Copy action uses the Android clipboard.
- Snackbar confirms: *Sync diagnostics copied.*
- Copy action does **not** mutate pending rows.

### Blocked-item wording

- Details reuse the Stage F-1 friendly detail mapping.
- Blocked cases covered include:
  - permission / validation,
  - missing / deleted row,
  - corrupt payload,
  - missing local data,
  - repeated transient failures / attempt cap.

### Related navigation

- Related pin/trip navigation was **not** added in F-3.
- Reason: no straightforward existing safe entry point from this screen.
- Parked as **Stage F-3b**.

### Behaviour boundaries

- Details are read-only.
- Only actions are **Copy diagnostics** and dismiss.
- No retry action was added.
- No dismiss / remove / archive.
- No force overwrite.
- No snapshot clearing.
- No pending-photo deletion.
- No pending write storage / schema change.
- No replay / coordinator logic change.
- No iOS changes.

### Build / check reference

- Implementation `runChecks` passed for `android-vinetrack`.
- QA `runChecks` passed; no code changed during QA.

### Parked future work

- **Stage F-2b** — per-item retry routed safely through the ordered pipeline.
- **Stage F-3b** — related pin/trip navigation from details if a safe entry point
  is added.
- **Stage F-4** — dismiss/archive recovery design.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage F-2b — per-item retry routed through ordered replay (closed)

**Status: CLOSED.** Tier-A Stage F-2b — per-item retry for eligible failed
pending-write rows.

### What Android now supports

- Sync Status item details can now show **Retry this item** for eligible rows.
- Per-item retry resets **only** the selected eligible row.
- It then runs the **full existing ordered replay pipeline**.
- It does **not** call a single coordinator in isolation.
- It preserves dependency gates and attempt-count semantics.

### Files changed

- `data/PendingWriteRepository.kt`
  - added `resetFailedRowForRetry(id)`.
- `ui/AppViewModel.kt`
  - extended `PendingSyncItem` with `canRetry`,
  - added `retryPendingSyncItem(id)`.
- `ui/screens/SyncStatusScreen.kt`
  - added **Retry this item** action in the details sheet.
- `ui/main/MainScaffold.kt`
  - wired `onRetryItem = vm::retryPendingSyncItem`.

### Eligibility logic

- `canRetry` is true **only** when pending-write status is `FAILED`.
- Eligible rows include transient failures and dependency-deferred rows
  represented as `FAILED`.
- `BLOCKED`, `PENDING`, `IN_PROGRESS`, and `SYNCED` rows are excluded.
- Pending-photo blocked items are not pending-write rows and do not expose item
  retry.
- The retry decision uses status only and does **not** inspect payload JSON.

### PendingSyncItem model

- `canRetry` is UI-layer only.
- The existing `id` is the pending-write id.
- Pending write storage is **unchanged**.

### Repository helper behaviour

`resetFailedRowForRetry(id)`:

- acts only if the row exists and is currently `FAILED`,
- changes that row to `PENDING`,
- clears stale `lastError`,
- refreshes `updatedAt`,
- preserves `attemptCount`,
- removes nothing,
- no-ops safely if the row is no longer eligible,
- returns `Boolean`.

### AppViewModel method behaviour

`retryPendingSyncItem(id)`:

- no-ops if offline,
- no-ops if no session,
- no-ops if retry already in flight,
- no-ops if the selected row is no longer eligible,
- resets only the selected failed row,
- runs the full ordered replay pipeline,
- returns `Boolean` so the UI can show success/failure feedback.

### Replay order

Per-item retry uses the same order as **Retry all**:

- pin creates,
- pin completions,
- pin edits,
- trip start,
- trip metadata,
- trip GPS,
- trip row,
- trip tank,
- trip end,
- pin photos.

- No coordinator is called in isolation.
- Dependency gates remain in force.
- Attempt counts / caps are preserved.

### UI behaviour

- **Retry this item** appears only in the details sheet.
- Shown only when the selected item is retryable.
- Shown only when online.
- Hidden / disabled while retrying.
- On tap the sheet closes and shows:
  - *Retry started.*
  - or *This item can no longer be retried.*
- **Copy diagnostics** and dismiss remain intact.

### Behaviour boundaries

- Opening details does **not** mutate rows.
- Copy diagnostics does **not** mutate rows.
- Retry is an explicit user action only.
- No blocked-row retry.
- No dismiss / remove / archive.
- No force overwrite.
- No snapshot clearing.
- No pending-photo deletion.
- No new persisted status enum.
- No schema / RLS / RPC.
- No iOS changes.

### Build / check reference

- Implementation `runChecks` passed for `android-vinetrack`.
- QA `runChecks` passed; no code changed during QA.

### Parked future work

- **Stage F-3b** — related pin/trip navigation from details if a safe entry point
  is added.
- **Stage F-4** — dismiss/archive recovery design.
- **Delete queueing.**
- **Fuel logs.**

---

## Tier-A Stage G-0 — delete / soft-delete queueing audit/design (closed / design only)

**Status: CLOSED / DESIGN ONLY.** Tier-A Stage G-0 — delete / soft-delete
queueing audit and design. No app behaviour was changed; this slice only maps
the current delete flows and recommends a safe offline queue/replay strategy.

### Current delete flows

- Current Android delete paths are **online-only**.
- **No** delete operation currently queues to the pending-write outbox.
- Delete operations optimistically remove local state, call a soft-delete RPC,
  and roll back the local removal on failure.
- There is **no offline guard** on delete.
- There is **no unresolved-marker dependency check** before delete.

Key flows:

- Pin delete: `deletePin(id)` → `PinRepository.softDeletePin(...)` →
  `soft_delete_pin` RPC.
- Trip delete: `deleteTrip(id)` → `TripRepository.softDeleteTrip(...)` →
  `soft_delete_trip` RPC.
- Other soft-delete flows follow the same general shape.

### Server write shape

- Delete operations use **security-definer soft-delete RPCs**.
- RPCs return `void`.
- RPCs generally set `deleted_at = now()` and `updated_by = auth.uid()`.
- Trip delete does **not** set `is_active`.
- Permission is generally owner / manager / supervisor.
- Permission failure is a **non-retryable** class.
- Re-deleting an already soft-deleted row is effectively **idempotent**.
- Hard-missing / never-created rows can return **not found**.

### Dependency risks

- Deleting a trip with pending `TRIP_START` can **resurrect** the trip later if
  start replays.
- Deleting a trip with pending metadata/GPS/row/tank/end markers can race or
  orphan pending work.
- Deleting a pin with pending create can **resurrect** the pin later.
- Deleting a pin with pending edit/completion/photo can race or orphan pending
  work.
- Deleting a local-only row should be resolved **locally**, not sent to server.
- Already-deleted rows should not loop forever as blocked.
- Active-trip snapshot cleanup must be handled carefully.
- Pending photo cleanup must not run before parent delete is proven safe.

### Options considered

- queue delete marker only,
- queue full tombstone,
- optimistic local remove and replay soft delete later,
- local pending-delete state,
- block delete while dependent markers exist,
- dependency-gated delete replay,
- RPC idempotency,
- hard delete.

Decision:

- Hard delete is **out of scope**.
- A full tombstone is **unnecessary** for soft delete.
- **Delete marker + dependency-aware replay** is the preferred direction.
- **Pin delete should be implemented before trip delete.**

### Recommended delete marker design

- Reuse the existing entity type with `PendingOpType.DELETE` where safe.
- Do **not** invent broad blob delete markers.

Recommended marker shapes:

- Pin delete:
  - `entityType = PIN`,
  - `opType = DELETE`,
  - `clientId = pinId`,
  - `payload { pinId }`,
  - Sync Status label **Pin delete**.
- Trip delete:
  - `entityType = TRIP`,
  - `opType = DELETE`,
  - `clientId = tripId`,
  - `payload { tripId }`,
  - Sync Status label **Trip delete**.

- Delete coordinators should own delete ops **only**.
- Delete replay must **not** be picked up by create/edit/update coordinators.

### Pin delete design

- Local-only pending pin create should **cancel** the unresolved create and
  remove the optimistic pin locally.
- Local-only pin delete should **not** queue a server delete.
- Synced pin delete should queue a **soft-delete marker**.
- Same-pin edit/completion/photo work must **not** race delete.
- Pending photo attachment should be removed only **after** parent delete is
  confirmed, except local-only create cancellation can remove the photo
  immediately.
- The server soft-delete RPC remains **unchanged**.
- Local UI may optimistically hide the pin.
- A future pending-delete visual state can be added later.

Ordering: pin create/edit/completion/photo should resolve before server pin
delete, unless a later implementation safely supersedes/cancels moot work.

### Trip delete design

- Trip delete is **higher risk** than pin delete.
- A locally-started unsynced trip with `TRIP_START` should **not** send a server
  delete.
- Same-trip metadata/GPS/row/tank/end markers must **not** race trip delete.
- Active trip delete touches tracking and the Stage A snapshot.
- **Ended trips with no unresolved markers** are the safest first trip-delete
  case.
- Active-trip offline delete should be **parked** or handled in a later slice
  after gates prove reliable.

### Idempotency / already-deleted behaviour

- An already soft-deleted row can be treated as **success**.
- Server **not found** for a local-only or purged row should be treated as
  success/no-op where safe.
- Permission failure should **block**.
- Validation / corrupt payload should **block**.
- Transient / network / 5xx should **retry**.

### Sync Status / UX implications

- Labels: **Pin delete**, **Trip delete**.
- Stage F retry actions should apply to delete markers when they are `FAILED`.
- Blocked delete should display **Needs attention**.
- Destructive dismiss / archive remains **parked**.
- An optional pending-delete visual state remains future UX work.

### Recovery boundaries (out of scope)

- Permanent hard delete.
- Destructive local pending cleanup from UI.
- Force-delete over conflicts.
- Deleting active-trip snapshots without dependency review.
- Deleting pending photos before parent delete is proven safe.
- Schema / RLS / RPC changes.
- iOS changes.

### Recommended implementation slices

- **Stage G-1** — pin soft-delete queue first.
- **Stage G-2** — trip delete queue for ended trips with no unresolved markers.
- **Stage G-3** — active-trip offline delete only if G-2 proves dependency gates
  reliable.
- **Stage G-4** — cleanup/UX, pending-delete visual state, labels / diagnostics /
  retry eligibility.
- **Stage G-5** — parity review.

### Parity checkpoint recommendation

- A **light** iOS/Android parity checkpoint can happen after Android Tier-A
  offline chain closure.
- A **deeper** parity audit should wait until delete and fuel-log decisions are
  closed.
- A **full release** parity audit should happen before TestFlight / Play testing
  release.

### Build / check reference

- Audit / design only — **no code changed**, so no build was required.

### Parked future work

- **Stage G-1** — pin soft-delete queue.
- **Stage G-2** — trip delete queue (ended trips, no unresolved markers).
- **Stage G-3** — active-trip offline delete (gated on G-2).
- **Stage G-4** — delete cleanup/UX, pending-delete visual state.
- **Stage G-5** — parity review.
- **Stage F-3b** — related pin/trip navigation from details.
- **Stage F-4** — dismiss/archive recovery design.
- **Fuel logs.**

---

## Tier-A Stage G-1 — pin soft-delete queue (closed)

**Status: CLOSED.** Tier-A Stage G-1 — offline/retryable pin soft-delete queue
using the existing `PIN` / `DELETE` pending-write marker and a dedicated
`PinDeleteSync` coordinator. This is the first delete-queueing implementation
slice off the Stage G-0 design.

### What Android now supports

- Android can now **queue pin soft-delete while offline or after a transient
  failure**.
- Pin delete uses the **existing pending-write outbox** (no new storage).
- Local-only offline-created pins can be **cancelled safely** without sending a
  server delete.
- Synced pins can be **optimistically hidden** and soft-deleted later.
- Pin delete now appears in **Sync Status** and participates in **Retry all /
  per-item retry**.

### Files changed

- `data/PinDeleteSync.kt`
  - new soft-delete-only replay coordinator.
- `ui/AppViewModel.kt`
  - constructed `PinDeleteSync`,
  - rewrote `deletePin(...)`,
  - added `replayPendingPinDeletes()`,
  - added the **Pin delete** Sync Status label,
  - wired delete replay into the ordered replay pipelines.

### Marker payload

Queued marker shape:

- `entityType = PIN`,
- `opType = DELETE`,
- `clientId = pinId`,
- payload `{ pinId }`.

- One unresolved delete marker per pin (coalesced).
- No broad blob marker.
- No trip-delete marker was added.

### Local-only pending-create cancellation

When a pin still has an unresolved `PIN` / `CREATE` marker, delete is treated as
local cancellation:

- the pending create marker is removed,
- the optimistic pin is removed from local state,
- the retained pending photo attachment is removed,
- `soft_delete_pin` is **not** called,
- no `PIN` / `DELETE` marker is queued.

This prevents `PinCreateSync` from later resurrecting the pin.

### Synced pin delete — offline / transient behaviour

- The optimistic hide is preserved.
- The known-offline path skips the network and enqueues one coalesced
  `PIN` / `DELETE` marker.
- A friendly saved-offline message is shown.
- A transient online failure keeps the hide and enqueues the delete.
- A successful online delete behaves as before.
- `Unauthorized` still signs out.
- Permission / validation server errors roll back and are **not** silently
  queued as retryable transient work.

### Dependency handling

`PinDeleteSync` defers while same-pin dependencies are unresolved:

- `PIN` / `CREATE`,
- `PIN` / `UPDATE` completion,
- `PIN_EDIT`,
- pending photo attachment.

- Dependency waiting does **not** consume retry attempts.
- Synced edits / completions / photos are **not** silently discarded.
- Delete does not race same-pin writes.

### Pending photo handling

- Local-only pending-create cancellation removes the retained photo immediately.
- Synced pin delete does **not** clean the retained photo until the soft-delete
  is confirmed or safely idempotent.
- Delete replay only cleans the photo once the dependency gate proves no photo
  upload remains unresolved.
- No local photo file is deleted prematurely.

### PinDeleteSync replay / failure handling

`PinDeleteSync`:

- processes only unresolved `PIN` / `DELETE`,
- requires session + online,
- uses a mutex / overlap guard,
- calls the existing `PinRepository.softDeletePin(pinId)`,
- treats already-deleted / not-found where safe as **idempotent success**,
- removes the marker on success,
- keeps the pin hidden on success,
- cleans the retained photo after a confirmed / safe delete,
- retries transient / network / 5xx / session-expired failures,
- blocks corrupt payloads and permission / validation failures,
- uses an attempt cap consistent with the other coordinators.

### Replay ordering

Ordered replay sequence:

- pin creates,
- pin completions,
- pin edits,
- **pin deletes**,
- trip start,
- trip metadata,
- trip GPS,
- trip row,
- trip tank,
- trip end,
- pin photos.

- Delete-before-photos is safe because delete defers while a same-pin photo is
  unresolved.
- Pin-photo replay remains unchanged.

### Sync Status / retry integration

- The `PIN` / `DELETE` label is **Pin delete**.
- The pending count includes delete markers.
- **Retry all** and **per-item retry** apply to `FAILED` delete markers.
- Details / copy diagnostics show the correct entity / op / status.

### Coordinator isolation

- `PinCreateSync` processes only `PIN` / `CREATE`.
- `PinCompletionSync` processes only `PIN` / `UPDATE`.
- `PinEditSync` processes only `PIN_EDIT`.
- `PinPhotoSync` works from pending photo attachments only.
- `PinDeleteSync` processes only `PIN` / `DELETE`.
- No coordinator cross-processes delete markers.

### App state / cache behaviour

- The optimistic hide filters the pin from `AppUiState.pins`.
- Successful replay keeps the pin hidden.
- The server-error path restores the previous pins where intended.
- A deleted pin stays hidden after confirmed replay.
- Cached state does not intentionally resurrect a pending-deleted pin.

### Behaviour boundaries

- No trip delete queueing.
- No active-trip delete.
- No hard delete.
- No dismiss / archive recovery.
- No force overwrite.
- No schema / RLS / RPC changes.
- No iOS changes.

### Build / check reference

- Implementation `runChecks` passed for `android-vinetrack`.
- QA `runChecks` passed; no code changed during QA.

### Parked next steps

- **Stage G-2** — trip delete queue for ended trips with no unresolved markers.
- **Stage G-3** — active-trip offline delete, only if G-2 gates prove reliable.
- **Stage G-4** — cleanup/UX, pending-delete visual state, diagnostics polish.
- **Stage G-5** — iOS/Android parity review.
- **Stage F-3b** — related pin/trip navigation from details.
- **Stage F-4** — dismiss/archive recovery design.
- **Fuel logs.**

---

## Tier-A Stage G-2 — trip delete queue for ended trips (closed)

**Status: CLOSED.** Tier-A Stage G-2 — queued trip soft-delete for ended/inactive
trips with no unresolved same-trip markers, using the existing `TRIP` / `DELETE`
pending-write marker and a dedicated `TripDeleteSync` coordinator. This extends
the Stage G-1 delete-queueing approach to trips while keeping active/in-flight
trip delete parked.

### What Android now supports

- Android can now **queue trip soft-delete while offline or after a transient
  failure** for eligible ended/inactive trips.
- Trip delete uses the **existing pending-write outbox** (no new storage).
- Eligible ended trips can be **optimistically hidden** and soft-deleted later.
- Trip delete now appears in **Sync Status** and participates in **Retry all /
  per-item retry**.
- Active / in-flight trip offline delete remains **intentionally parked**.

### Files changed

- `data/TripDeleteSync.kt`
  - new soft-delete-only replay coordinator for trip deletes.
- `ui/AppViewModel.kt`
  - constructed `TripDeleteSync`,
  - rewrote `deleteTrip(...)`,
  - added `replayPendingTripDeletes()`,
  - added the **Trip delete** Sync Status label,
  - wired trip delete replay into the ordered replay pipelines.

### Marker payload

Queued marker shape:

- `entityType = TRIP`,
- `opType = DELETE`,
- `clientId = tripId`,
- payload `{ tripId }`.

- One unresolved delete marker per trip (coalesced).
- No broad blob marker.
- Pin-delete behaviour unchanged.

### Eligibility / guard behaviour

G-2 supports only **ended/inactive** trips. Delete is **not** queued for:

- the current active trip,
- any trip with `isActive == true`,
- a locally-started unsynced trip waiting on `TRIP_START`,
- a locally-ended trip waiting on `TRIP_END`,
- any trip with unresolved same-trip markers.

Same-trip unresolved markers checked:

- `TRIP_START`,
- `TRIP_METADATA`,
- `TRIP_GPS`,
- `TRIP_ROW`,
- `TRIP_TANK`,
- `TRIP_END`.

When any unresolved same-trip marker exists:

- `softDeleteTrip` is **not** called,
- no `TRIP` / `DELETE` marker is queued,
- the trip remains visible,
- the user sees: **Finish syncing this trip before deleting it.**

### Ended-trip offline / transient behaviour

- The optimistic hide/remove is preserved.
- The known-offline path skips the network and enqueues one coalesced
  `TRIP` / `DELETE` marker.
- A friendly saved-offline message is shown: **Trip deleted offline — will sync
  when connection is available.**
- The pending count / Sync Status reflect the delete marker.
- A transient online failure keeps the optimistic hide and enqueues the delete.
- A successful online delete behaves as before.
- `Unauthorized` signs out.
- Permission / validation server errors roll back and are **not** queued as
  retryable transient work.

### TripDeleteSync replay / failure handling

`TripDeleteSync`:

- processes only unresolved `TRIP` / `DELETE`,
- requires session + online,
- uses a mutex / overlap guard,
- re-checks same-trip unresolved markers before replay,
- defers while unresolved trip markers exist,
- dependency waiting does **not** consume retry attempts,
- calls the existing `TripRepository.softDeleteTrip(tripId)`,
- treats already-deleted / not-found where safe as **idempotent success**,
- removes the marker on success,
- keeps the trip hidden on success,
- retries transient / network / 5xx / session-expired failures,
- blocks corrupt payloads and permission / validation failures,
- uses an attempt cap consistent with the other coordinators.

### Replay ordering

Ordered replay sequence:

- pin creates,
- pin completions,
- pin edits,
- pin deletes,
- trip start,
- trip metadata,
- trip GPS,
- trip row,
- trip tank,
- trip end,
- **trip deletes**,
- pin photos.

- Trip delete runs **after** trip end.
- This order is applied to **Retry all**, **per-item retry**, **reconnect
  replay**, and **post-load replay**.
- Reconnect / post-load pin-photo behaviour was left unchanged where it already
  differed.

### Sync Status / retry integration

- The `TRIP` / `DELETE` label is **Trip delete**.
- The pending count includes trip delete markers.
- **Retry all** and **per-item retry** apply to `FAILED` trip delete markers.
- Details / copy diagnostics show the correct entity / op / status.

### Coordinator isolation

- Trip start sync does not process delete markers.
- Trip metadata sync does not process delete markers.
- Trip GPS sync does not process delete markers.
- Trip row sync does not process delete markers.
- Trip tank sync does not process delete markers.
- Trip end sync does not process delete markers.
- `TripDeleteSync` processes only `TRIP` / `DELETE`.

### App state / cache behaviour

- The optimistic hide removes the eligible ended trip from `AppUiState.trips`.
- Successful replay keeps the trip hidden.
- A permission / validation failure restores the previous trip list.
- There is no deliberate cache resurrection path.

### Active-trip boundary

- No offline delete for the current active trip.
- No locally-started unsynced trip cancel.
- No active-trip chain cancellation.
- No Stage A active-trip snapshot clearing as part of G-2.
- No row-lock clearing beyond existing online behaviour.
- Active-trip offline delete remains **parked for G-3** and should only proceed
  if G-2 gates prove reliable in field use.

### Behaviour boundaries

- No pin delete queueing changes.
- No hard delete.
- No dismiss / archive recovery.
- No force overwrite.
- No schema / RLS / RPC changes.
- No iOS changes.

### Build / check reference

- Implementation `runChecks` passed for `android-vinetrack`.
- QA `runChecks` passed; no code changed during QA.

### Parked next steps

- **Stage H-0 (design)** — fuel logs offline queue / retry audit/design (see
  section below).
- **Stage G-3** — active-trip offline delete, only if G-2 gates prove reliable in
  field use.
- **Stage G-4** — cleanup/UX, pending-delete visual state, diagnostics polish.
- **Stage G-5** — iOS/Android parity review.
- **Stage F-3b** — related pin/trip navigation from details.
- **Stage F-4** — dismiss/archive recovery design.

---

## Tier-A Stage H-0 — fuel logs offline queue / retry audit/design (closed / design only)

**Status: CLOSED / DESIGN ONLY.** Tier-A Stage H-0 — audit of the current Android
fuel-log create/update/delete behaviour and design of the safest offline
queue/replay strategy. This slice is **design only**: no fuel-log queueing was
implemented and no app behaviour changed.

### Files inspected

- `data/FuelLogRepository.kt`
- `data/model/Models.kt`
- `data/model/PendingWrite.kt`
- `ui/AppViewModel.kt`
- `ui/screens/FuelLogScreen.kt`
- `sql/092_tractor_fuel_logs.sql`
- `sql/097_vineyard_machines.sql`
- `data/PinDeleteSync.kt`
- `data/TripDeleteSync.kt`

### Current fuel-log flows

All current fuel-log flows are **online-only** and **do not queue** to the
pending-write outbox.

**List / view**
- Entry via `FuelLogScreen`.
- Loaded into `AppUiState.fuelLogs`.
- `fuelPurchases` is a separate collection used for owner/manager trip-cost
  basis (not the same as `fuelLogs`).

**Create**
- `createFuelLog(input, onResult)`.
- Repository call `FuelLogRepository.createFuelLog(vineyardId, input)`.
- REST `POST` to `tractor_fuel_logs` with `Prefer: return=representation`.
- No optimistic insert today; no offline guard; failure sets `fuelError`; no
  Sync Status marker.
- **Design enabler:** the client already sends `UUID.randomUUID()` as the `id`
  and sends `client_updated_at`.

**Update**
- `updateFuelLog(id, input, onResult)`.
- REST `PATCH` to `tractor_fuel_logs?id=eq.{id}` sending editable fields plus a
  fresh `client_updated_at`.
- No offline guard; no queue; no Sync Status marker.

**Delete**
- `deleteFuelLog(id, onResult)`.
- Optimistic local remove, then repository call `softDeleteFuelLog(id)`.
- RPC `soft_delete_tractor_fuel_log`.
- No offline guard; no queue; no Sync Status marker.

### Server write shape

- Table `public.tractor_fuel_logs`.
- Create uses REST `POST`; update uses REST `PATCH` by `id`; delete uses the
  security-definer RPC `soft_delete_tractor_fuel_log(p_id uuid)`.
- Delete returns `void`; create/update return the row representation.
- Insert sends a **client-generated `id`**; the server also has a
  `gen_random_uuid()` default, but Android supplies the `id`.
- Soft delete sets `deleted_at`, `updated_at`, `updated_by`, and increments
  `sync_version`.
- `client_updated_at` column exists and is already populated.
- Permission / RLS expectations:
  - non-member insert blocked,
  - non-owner/manager/non-creator update blocked,
  - soft delete owner/manager only,
  - missing row RPC raises **not found**.

### Current data model

`TractorFuelLog` includes:

- `id`, `vineyardId`, `operatorUserId`, `machineId`, `tractorId`,
  `fillDatetime`, `litresAdded`, `engineHours`, `operatorName`, `costPerLitre`,
  `totalCost`, `filledToFull`, `notes`, `deletedAt`.

Notes:
- `machineId` is preferred; `tractorId` is the **legacy fallback**.
- Fuel logs are **independent records**, not directly tied to a trip/job.
- Derived fuel-rate display is **not persisted**.

### Offline risks

- Duplicate creates are **low risk** because Android already supplies a stable
  client `id`.
- Edit-before-create must **not** `PATCH` a row that does not exist yet.
- Delete-before-create should cancel the local create and **not** call the RPC.
- Delete-after-edit requires dependency ordering.
- Stale edits are possible because there is **no conflict guard** yet.
- Fuel logs can affect displayed litres/hour and cost/usage estimates.
- Operator delete may be **permission-blocked**.
- Refresh/cache can resurrect optimistically removed rows unless local pending
  state is respected.

### Options compared

- `FUEL_LOG` + `CREATE`/`UPDATE`/`DELETE` markers.
- One generic payload-inferred fuel marker.
- Separate entity types per op.
- Full editable payload vs partial patch.
- Client-generated id vs server-generated id.

**Decision:**
- Use the existing `PendingEntityType.FUEL_LOG`.
- Use normal `PendingOpType.CREATE`, `UPDATE`, `DELETE`.
- Use the **full editable payload** for create/update.
- Keep **client-generated ids**.
- **Separate coordinators per op** are preferred.

### Recommended marker design

`clientId = fuelLogId` for all fuel-log markers.

**Create**
- `entityType = FUEL_LOG`, `opType = CREATE`, label **Fuel log**.
- Payload: full insert set.
- Stable idempotency by client id; conflict/already-exists can be treated as
  success where safe.

**Update**
- `entityType = FUEL_LOG`, `opType = UPDATE`, label **Fuel log edit**.
- Payload: full editable set plus `clientUpdatedAt`.
- One unresolved update per log; defer while same-log create is unresolved.

**Delete**
- `entityType = FUEL_LOG`, `opType = DELETE`, label **Fuel log delete**.
- Payload `{ fuelLogId }`.
- Local-only create cancellation; defer while same-log create/update unresolved.
- Already-deleted/not-found can be treated as success where safe.

### Create strategy

- H-1 should generate the fuel-log `id` in the ViewModel.
- Optimistic insert should prepend the row immediately.
- Offline path should skip network and enqueue `FUEL_LOG` / `CREATE`.
- Transient online failure should keep the optimistic row and enqueue.
- Replay success should reconcile the server row.
- Permission/validation should block and surface **Needs attention**.

### Update strategy

- Updates should queue offline/transient.
- One unresolved update per log should coalesce **latest-wins**.
- Edit-before-create should **fold into the pending create payload**.
- Edit-after-delete should be rejected/no-op because the row is being removed.
- Phase 1 can remain **last-writer-wins** using `client_updated_at`; deeper
  conflict detection is deferred.

### Delete strategy

- Soft-delete only.
- Local-only pending create cancellation should remove the create marker and the
  optimistic row **without** a server RPC.
- Synced delete should optimistic-remove and enqueue delete.
- Delete should defer behind same-log create/update.
- Already-deleted/not-found should be success/no-op where safe.
- Permission-blocked delete should become **Needs attention**.
- Role-gated delete affordance can be considered in a later UX slice.

### Sync Status / retry UX

Labels:
- `FUEL_LOG` / `CREATE` → **Fuel log**,
- `FUEL_LOG` / `UPDATE` → **Fuel log edit**,
- `FUEL_LOG` / `DELETE` → **Fuel log delete**.

- Pending count should include fuel markers.
- **Retry all** and **per-item retry** should apply to FAILED fuel markers.
- Blocked permission/validation should show **Needs attention**.
- Details/copy diagnostics should show entity/op/status/client id.

### Recommended implementation slices

- **Stage H-1** — fuel-log create queue.
- **Stage H-2** — fuel-log update queue.
- **Stage H-3** — fuel-log delete queue.
- **Stage H-4** — QA/UX/Sync Status polish.
- **Stage H-5** — parity checkpoint.

Recommended internal fuel replay order:
- fuel creates,
- fuel updates,
- fuel deletes.

Suggested broader replay placement: **after trip deletes and before pin photos**,
unless implementation finds a safer placement.

### Parity checkpoint recommendation

- Do **not** run full iOS/Android parity until fuel-log queue decisions are
  closed.
- After fuel design/implementation, run a deeper iOS/Android parity audit across
  offline queues, delete queues, Sync Status, and maps/pins/trips/fuel.
- Full release parity remains later.

### Code / build reference

- Audit/design only — **no code changed**, **no build required**.

### Parked next steps

- **Stage H-1** — fuel-log create queue (see section below).
- **Stage H-2** — fuel-log update queue.
- **Stage H-3** — fuel-log delete queue.
- **Stage H-4** — QA/UX/Sync Status polish.
- **Stage H-5** — parity checkpoint.
- **Stage G-3** — active-trip offline delete, still parked pending G-2 field
  confidence.
- **Stage F-3b** — related-record navigation.
- **Stage F-4** — dismiss/archive recovery design.

---

## Tier-A Stage H-1 — fuel-log create queue (closed)

**Status: CLOSED.** Tier-A Stage H-1 — queued fuel-log create using a
`FUEL_LOG` / `CREATE` marker and the `FuelLogCreateSync` coordinator. Fuel-log
update and delete remain online-only in this slice.

### What Android now supports

- Android can now **queue fuel-log create** while offline or after a transient
  failure.
- Fuel-log create uses the existing **pending-write outbox**.
- Fuel logs use **caller-supplied / client-generated ids** for offline-safe
  idempotency.
- New fuel logs are **optimistically inserted** into `AppUiState.fuelLogs`.
- Fuel-log create appears in **Sync Status** and participates in **Retry all /
  per-item retry**.

### Files changed

- `data/FuelLogCreateSync.kt`
  - new create-only replay coordinator.
- `data/FuelLogRepository.kt`
  - `createFuelLog(...)` now accepts a caller-supplied `id` and
    `clientUpdatedAt`,
  - added `newId()`,
  - replay can reuse the payload `id`.
- `ui/AppViewModel.kt`
  - constructed `FuelLogCreateSync`,
  - rewrote `createFuelLog(...)`,
  - added `replayPendingFuelCreates()`,
  - added **Fuel log** Sync Status label,
  - wired fuel-create replay into the ordered replay pipelines.

### Marker payload

Queued marker shape:
- `entityType = FUEL_LOG`,
- `opType = CREATE`,
- `clientId = fuelLogId`,
- payload includes: `id`, `vineyardId`, `machineId`, `tractorId`,
  `fillDatetime`, `litresAdded`, `engineHours`, `operatorName`, `costPerLitre`,
  `totalCost`, `filledToFull`, `notes`, `clientUpdatedAt`.

Notes:
- **One unresolved create marker per fuel-log id** (coalesced).
- **No auth/session/secrets** are stored in the payload.
- `operator_user_id` / `created_by` are resolved from the session at insert time.

### Client-generated id handling

- The `id` is generated **before** optimistic insert.
- The **same id** is used for: the optimistic row, the marker `clientId`, the
  payload, and the server insert.
- Replay **reuses the payload id** and does not mint a new id.

### Optimistic create behaviour

- `createFuelLog(...)` **prepends** a local `TractorFuelLog` immediately.
- The optimistic row appears **before** server success when offline/transient.
- The form `onResult` callback behaviour is **preserved**.
- `fuelError` is **cleared** on optimistic create.
- **No marker** is created on clean online success.

### Online success behaviour

- The repository receives the caller-supplied `id` and `clientUpdatedAt`.
- The returned server row **reconciles** the local optimistic row by id.
- **No duplicate row** is produced.
- **No pending marker** is created.

### Offline / transient behaviour

- The known-offline path **skips the network**.
- One **coalesced** `FUEL_LOG` / `CREATE` marker is enqueued.
- The optimistic row **remains visible**.
- Friendly message shown: _Fuel log saved offline — will sync when connection is
  available._
- Pending count / Sync Status reflect the marker.
- A **transient online failure** keeps the optimistic row and enqueues the
  marker; the transient path **does not roll back** the optimistic row.

### Permanent failure behaviour

- `BackendError.Server` validation/permission **rolls back** the optimistic row.
- A permanent failure is **not queued** as retryable transient work.
- A friendly error is surfaced.
- **Unauthorized still signs out.**

### FuelLogCreateSync replay / failure handling

- Processes only unresolved `FUEL_LOG` / `CREATE`.
- Requires **session + online**.
- Uses a **mutex/overlap guard**.
- Decodes the full create payload.
- Calls the repository create using the **payload id** (does not mint a new id).
- Treats **duplicate/already-created** conflict as idempotent success where safe.
- **Removes the marker** on success.
- **Reconciles** local `fuelLogs` by id.
- Retries transient/network/5xx/session-expired failures.
- **Blocks** corrupt payload and permission/validation failures.
- Uses an **attempt cap** consistent with other coordinators.

### Replay ordering

- Fuel creates run **after trip deletes and before pin photos**.
- Wired into: **Retry all**, **per-item retry**, **reconnect replay**, and
  **post-load replay**.
- **No fuel update replay** added; **no fuel delete replay** added.
- Pre-existing pin-photo replay differences for reconnect/post-load were left
  **unchanged**.

### Sync Status / retry integration

- `FUEL_LOG` / `CREATE` label is **Fuel log**.
- Pending count includes fuel-log create markers.
- **Retry all** and **per-item retry** apply to FAILED fuel-create markers.
- Details/copy diagnostics show correct entity/op/status/client id.

### Update / delete boundaries

- Fuel-log **update remains online-only** in H-1.
- Fuel-log **delete remains online-only** in H-1.
- **No update/delete markers** are produced.
- **No edit-before-create folding** was added.

### App state / cache behaviour

- The optimistic fuel log appears in `AppUiState.fuelLogs`.
- Successful replay **keeps/reconciles it by id**.
- Permanent failure **rolls back** where intended.
- **No path intentionally drops** a pending-created log before replay.
- **No duplicate row** appears after replay.

### Boundaries

No changes to:
- fuel-log update queue,
- fuel-log delete queue,
- pin/trip delete queueing,
- active-trip delete,
- hard delete,
- dismiss/archive recovery,
- force overwrite/conflict UI,
- schema/RLS/RPC,
- iOS code.

### Code / build reference

- Implementation `runChecks` passed.
- QA `runChecks` passed.
- No code changed during QA.

### Parked next steps

- **Stage H-2** — fuel-log update queue (see section below).
- **Stage H-3** — fuel-log delete queue.
- **Stage H-4** — QA/UX/Sync Status polish.
- **Stage H-5** — parity checkpoint.
- **Stage G-3** — active-trip offline delete, still parked pending G-2 field
  confidence.
- **Stage F-3b** — related-record navigation.
- **Stage F-4** — dismiss/archive recovery design.

---

## Tier-A Stage H-2 — fuel-log update queue (closed)

**Status: CLOSED.** Tier-A Stage H-2 — queued fuel-log update using a
`FUEL_LOG` / `UPDATE` marker and the `FuelLogUpdateSync` coordinator, with
edit-before-create folding into the pending create payload. Fuel-log delete
remains online-only in this slice.

### What Android now supports

- Android can now **queue fuel-log edits** while offline or after a transient
  failure.
- Fuel-log update uses the existing **pending-write outbox**.
- Fuel-log edits are **optimistically applied** to `AppUiState.fuelLogs`.
- Edits to fuel logs with an unresolved pending create are **folded into the
  create payload**.
- Fuel-log update appears in **Sync Status** and participates in **Retry all /
  per-item retry**.

### Files changed

- `data/FuelLogUpdateSync.kt`
  - new update-only replay coordinator.
- `data/FuelLogCreateSync.kt`
  - added `foldEdit(...)` to rewrite pending create payloads with the latest
    editable values.
- `data/FuelLogRepository.kt`
  - `updateFuelLog(...)` now accepts a replay-safe `clientUpdatedAt`.
- `ui/AppViewModel.kt`
  - constructed `FuelLogUpdateSync`,
  - rewrote `updateFuelLog(...)`,
  - added `replayPendingFuelUpdates()`,
  - added **Fuel log edit** Sync Status label,
  - wired fuel-update replay after fuel-create in the ordered replay pipelines.

### Marker payload

Queued marker shape:
- `entityType = FUEL_LOG`,
- `opType = UPDATE`,
- `clientId = fuelLogId`,
- payload includes: `id`, `machineId`, `tractorId`, `fillDatetime`,
  `litresAdded`, `engineHours`, `operatorName`, `costPerLitre`, `totalCost`,
  `filledToFull`, `notes`, `clientUpdatedAt`.

Notes:
- **No auth/session/secrets** are stored in the payload.
- `operator_user_id` and `created_by` are **not overwritten**.

### Optimistic update behaviour

- `updateFuelLog(...)` updates the matching row in `AppUiState.fuelLogs`
  **immediately**.
- The update is **by id**; **no duplicate row** is created.
- The form `onResult` callback behaviour remains **intact**.
- The previous fuel-log list is **captured** for permanent-failure rollback.

### Online success behaviour

- The live PATCH uses the caller-supplied `clientUpdatedAt`.
- The returned server row **reconciles by id**.
- **No pending marker** is created on clean success.
- **No duplicate row** is produced.

### Offline / transient behaviour

- The known-offline path **skips the network**.
- The optimistic edit **remains visible**.
- If a same-log `FUEL_LOG` / `CREATE` is unresolved, the edit **folds into the
  pending create marker** and **no UPDATE marker** is queued.
- Otherwise one **coalesced** `FUEL_LOG` / `UPDATE` marker is enqueued.
- Friendly message shown: _Fuel log edit saved offline — will sync when
  connection is available._
- A **transient/network failure** keeps the optimistic edit; the transient path
  folds into the pending create where applicable or queues/coalesces the UPDATE,
  and **does not roll back** the optimistic edit.

### Permanent failure behaviour

- `BackendError.Server` validation/permission **rolls back** to the previous
  fuel-log list.
- A permanent failure is **not queued** as retryable transient work.
- A friendly error is surfaced.
- **Unauthorized still signs out.**

### Edit-before-create folding

- If an unresolved same-log `FUEL_LOG` / `CREATE` exists, **no UPDATE marker** is
  queued.
- The existing CREATE payload is **rewritten** with the latest editable values.
- The `id` is **preserved**; the vineyard scope is **preserved**.
- A fresh `clientUpdatedAt` is stored.
- The optimistic local row remains **edited**.
- Sync Status remains **Fuel log**, not **Fuel log edit**.
- Replay of the create inserts the **edited/latest values**.

### Update coalescing

- When no pending create exists, only **one unresolved UPDATE** exists per
  fuel-log id.
- A newer edit **replaces** the older unresolved update payload (latest edit
  wins).
- Attempt semantics remain **safe**.

### FuelLogUpdateSync replay / failure handling

- Processes only unresolved `FUEL_LOG` / `UPDATE`.
- Requires **session + online**.
- Uses a **mutex/overlap guard**.
- Decodes the full update payload.
- **Defers** while a same-log `FUEL_LOG` / `CREATE` is unresolved; dependency
  waiting **does not consume retry attempts**.
- Calls the repository update using the **payload id** and **payload
  `clientUpdatedAt`**.
- **Removes the marker** on success.
- **Reconciles** local `fuelLogs` with the returned server row by id.
- Retries transient/network/5xx/session-expired failures.
- **Blocks** corrupt payload and permission/validation failures.
- Uses an **attempt cap** consistent with other coordinators.

### Replay ordering

- Fuel updates run **after fuel creates and before pin photos**.
- Wired into: **Retry all**, **per-item retry**, **reconnect replay**, and
  **post-load replay**.
- **No fuel delete replay** added; **H-1 fuel create replay remains intact**.

### Sync Status / retry integration

- `FUEL_LOG` / `UPDATE` label is **Fuel log edit**.
- `FUEL_LOG` / `CREATE` remains **Fuel log**.
- Pending count includes fuel-log update markers.
- **Retry all** and **per-item retry** apply to FAILED fuel-update markers.
- Details/copy diagnostics show correct entity/op/status/client id.
- Folded edits into create continue to display as **Fuel log**.

### Update / delete boundaries

- Fuel-log **delete remains online-only** in H-2.
- **No delete marker** is produced.
- **Edit-after-delete** was not expanded.
- **H-1 create behaviour remains intact.**

### App state / cache behaviour

- The optimistic edit updates the row **in place by id**.
- Successful replay **keeps/reconciles it by id**.
- Permanent failure **rolls back** where intended.
- **No path intentionally overwrites** a pending-edited fuel log before replay.
- **No duplicate row** appears after replay.

### Boundaries

No changes to:
- fuel-log delete queue,
- pin/trip delete queueing,
- active-trip delete,
- hard delete,
- dismiss/archive recovery,
- force overwrite/conflict UI,
- schema/RLS/RPC,
- iOS code.

### Code / build reference

- Implementation `runChecks` passed.
- QA `runChecks` passed.
- No code changed during QA.

### Parked next steps

- **Stage H-3** — fuel-log delete queue (see section below).
- **Stage H-4** — QA/UX/Sync Status polish.
- **Stage H-5** — parity checkpoint.
- **Stage G-3** — active-trip offline delete, still parked pending G-2 field
  confidence.
- **Stage F-3b** — related-record navigation.
- **Stage F-4** — dismiss/archive recovery design.

---

## Tier-A Stage H-3 — fuel-log delete queue (closed)

**Status: CLOSED.** Tier-A Stage H-3 — queued fuel-log soft-delete using a
`FUEL_LOG` / `DELETE` marker and the `FuelLogDeleteSync` coordinator, with
local-only pending-create cancellation and dependency-gated replay behind
same-log create/update. This closes the fuel-log create/update/delete offline
triad.

### What Android now supports

- Android can now **queue fuel-log soft-delete** while offline or after a
  transient failure.
- Fuel-log delete uses the existing **pending-write outbox**.
- Fuel logs that only exist as **pending offline creates** can be **cancelled
  locally** (no server delete ever issued).
- Synced fuel logs can be **optimistically removed** and soft-deleted later.
- Fuel-log delete appears in **Sync Status** and participates in **Retry all /
  per-item retry**.

### Files changed

- `data/FuelLogDeleteSync.kt`
  - new delete-only replay coordinator.
- `ui/AppViewModel.kt`
  - constructed `FuelLogDeleteSync`,
  - rewrote `deleteFuelLog(...)`,
  - added `replayPendingFuelDeletes()`,
  - added **Fuel log delete** Sync Status label,
  - wired fuel-delete replay after fuel-update in the ordered replay pipelines.

### Marker payload

Queued marker shape:
- `entityType = FUEL_LOG`,
- `opType = DELETE`,
- `clientId = fuelLogId`,
- payload `{ fuelLogId }`.

Notes:
- **No auth/session/secrets** are stored in the payload.
- **One unresolved delete marker** per fuel-log id.

### Local-only pending-create cancellation

When a same-log unresolved `FUEL_LOG` / `CREATE` exists:
- the pending create marker is **removed**,
- any unresolved same-log `FUEL_LOG` / `UPDATE` marker is **removed**,
- the optimistic fuel log is **removed** from `AppUiState.fuelLogs`,
- **no DELETE marker** is queued,
- `softDeleteFuelLog` is **not called**,
- `FuelLogCreateSync` **cannot later resurrect** the row.

### Synced fuel-log delete — offline / transient behaviour

- The optimistic local remove is **preserved**.
- The known-offline path **skips the network**.
- One **coalesced** `FUEL_LOG` / `DELETE` marker is enqueued.
- Friendly message shown: _Fuel log deleted offline — will sync when connection
  is available._
- Pending count / Sync Status reflect the marker.
- A **transient online failure** keeps the local remove and enqueues the delete.
- **Clean online success** behaves as before and creates **no marker**.
- **Unauthorized still signs out.**
- **Permission/validation** server errors **restore** the previous fuel-log list
  and are **not queued** as retryable transient work.

### Dependency handling

`FuelLogDeleteSync` **defers** while same-log unresolved markers exist:
- `FUEL_LOG` / `CREATE`,
- `FUEL_LOG` / `UPDATE`.

Notes:
- Dependency waiting leaves the marker **retryable/deferred**.
- Dependency waiting **does not consume retry attempts**.
- Queued work is only discarded in the **explicit local-only pending-create
  cancellation** path.

### Delete coalescing

- Enqueue **removes/replaces** any earlier unresolved same-log DELETE marker.
- Repeated delete attempts **do not grow** the pending count.
- The latest delete state remains **safe**.

### FuelLogDeleteSync replay / failure handling

- Processes only unresolved `FUEL_LOG` / `DELETE`.
- Requires **session + online**.
- Uses a **mutex/overlap guard**.
- Decodes the payload; **blocks corrupt payload**.
- **Re-checks** same-log create/update dependencies before replay.
- Calls `FuelLogRepository.softDeleteFuelLog(fuelLogId)`.
- Treats **already-deleted / not-found** where safe as **idempotent success**.
- **Removes the marker** on success.
- Keeps the local row **hidden** on success.
- Retries transient/network/5xx/session-expired failures.
- **Blocks** permission/validation failures.
- Uses an **attempt cap** consistent with the fuel create/update coordinators.

### Replay ordering

Fuel deletes run **after fuel updates and before pin photos**. Broader order:
- pin creates,
- pin completions,
- pin edits,
- pin deletes,
- trip start,
- trip metadata,
- trip GPS,
- trip row,
- trip tank,
- trip end,
- trip deletes,
- fuel-log creates,
- fuel-log updates,
- fuel-log deletes,
- pin photos.

Wired into: **Retry all**, **per-item retry**, **reconnect replay**, and
**post-load replay**. Reconnect/post-load pin-photo behaviour remains whatever it
was before H-3; **H-3 did not change that behaviour**.

### Sync Status / retry integration

- `FUEL_LOG` / `DELETE` label is **Fuel log delete**.
- Pending count includes fuel-log delete markers.
- **Retry all** and **per-item retry** apply to FAILED fuel-delete markers.
- Details/copy diagnostics show correct entity/op/status/client id.

### Create / update coordinator isolation

- `FuelLogCreateSync` processes only `FUEL_LOG` / `CREATE`.
- `FuelLogUpdateSync` processes only `FUEL_LOG` / `UPDATE`.
- `FuelLogDeleteSync` processes only `FUEL_LOG` / `DELETE`.
- **No coordinator cross-processes** another fuel op.

### App state / cache behaviour

- The optimistic delete **removes** the fuel log from `AppUiState.fuelLogs`.
- Successful replay **keeps it hidden**.
- Permission/validation failure **restores** the previous fuel-log list.
- **No path intentionally re-adds** a pending-deleted row.

### Boundaries

No changes to:
- pin/trip delete queueing,
- active-trip delete,
- hard delete,
- dismiss/archive recovery,
- force overwrite/conflict UI,
- schema/RLS/RPC,
- iOS code.

### Code / build reference

- Implementation `runChecks` passed.
- QA `runChecks` passed.
- No code changed during QA.

### Parked next steps

- **Stage H-4** — QA/UX/Sync Status polish for fuel-log create/update/delete (see
  section below).
- **Stage H-5** — parity checkpoint.
- **Stage G-3** — active-trip offline delete, still parked pending G-2 field
  confidence.
- **Stage F-3b** — related-record navigation.
- **Stage F-4** — dismiss/archive recovery design.

---

## Tier-A Stage H-4 — fuel-log QA/UX/Sync Status polish audit (closed / audit only)

**Status: CLOSED / AUDIT ONLY.** Tier-A Stage H-4 was a read-only QA/UX/Sync
Status polish audit of the fuel-log create/update/delete offline queue triad
(Stages H-1, H-2, H-3). The audit found **no correctness bugs**, made **no app
code changes**, and confirmed the triad is field-ready. A short list of optional
polish items is parked below.

### Files inspected

- `data/FuelLogCreateSync.kt`,
- `data/FuelLogUpdateSync.kt`,
- `data/FuelLogDeleteSync.kt`,
- `ui/AppViewModel.kt`,
- `ui/screens/SyncStatusScreen.kt`.

### Create UX findings

- Offline create shows the **optimistic fuel log immediately**.
- One `FUEL_LOG` / `CREATE` marker is queued.
- Online success **reconciles by id** without a duplicate.
- Permanent failure **rolls back cleanly**.
- Sync Status label is **Fuel log**.

### Update UX findings

- Offline edit **updates the row immediately**.
- Edit-before-create folding is **invisible and intuitive**.
- A folded edit remains under the **Fuel log** Sync Status label.
- A standalone queued edit shows **Fuel log edit**.
- Permanent failure **restores the previous row/list cleanly**.

### Delete UX findings

- Offline delete **removes the row immediately**.
- Local-only pending-create cancellation removes the create/update markers and the
  row with **no RPC / no delete marker**.
- A synced queued delete shows **Fuel log delete**.
- Permanent failure **restores the previous list**.
- Repeated delete **does not create duplicate pending rows**.

### Sync Status labels / details

- `FUEL_LOG` / `CREATE` → **Fuel log**,
- `FUEL_LOG` / `UPDATE` → **Fuel log edit**,
- `FUEL_LOG` / `DELETE` → **Fuel log delete**.

Notes:
- Pending count includes **all fuel markers**.
- **Retry all** works for failed fuel markers.
- **Per-item retry** works for failed fuel markers.
- The details sheet shows correct **Type / Operation / Related id / Status**.
- Copy diagnostics **excludes payload JSON, secrets, tokens, and auth/session
  data**.

### Replay ordering

Verified order:
- pin creates,
- pin completions,
- pin edits,
- pin deletes,
- trip start,
- trip metadata,
- trip GPS,
- trip row,
- trip tank,
- trip end,
- trip deletes,
- fuel-log creates,
- fuel-log updates,
- fuel-log deletes,
- pin photos.

Notes:
- The fuel create/update/delete **internal order is preserved** everywhere.
- Reconnect/post-load **pin-photo behaviour was not changed** by H-4.

### Coordinator isolation

- `FuelLogCreateSync` processes only `FUEL_LOG` / `CREATE`,
- `FuelLogUpdateSync` processes only `FUEL_LOG` / `UPDATE`,
- `FuelLogDeleteSync` processes only `FUEL_LOG` / `DELETE`,
- **No fuel coordinator** processes pin/trip markers,
- **No pin/trip coordinator** processes fuel markers.

### Cache / refresh findings

- `loadVineyardData` **overwrites `fuelLogs`** with the server list.
- Post-load replay **re-applies pending fuel work** after load when online and a
  session exists.
- A pending-deleted synced row could **theoretically reappear briefly** between
  load and replay.
- This is **shared cross-entity behaviour**, not a fuel-specific bug.
- **No fuel-only fix** was made.
- Parked as **cross-entity reconcile-after-load** design if needed.

### Role / permission UX findings

- Permission rejections flow through the **permanent failure / blocked** paths.
- The delete affordance is **not currently role-hidden** in this audit.
- Role-gated delete affordance and clearer permission messaging are **parked UX
  work**.
- **No broad role-gating** was added in H-4.

### Messages / wording findings

The fuel offline messages are short and field-friendly:
- _fuel log saved offline_,
- _fuel log edit saved offline_,
- _fuel log deleted offline_,
- dependency-waiting wording,
- permanent-error friendly mapping.

### Minor parked polish

- A fuel `UPDATE`/`DELETE` waiting behind an unresolved `CREATE` currently renders
  as **retry/deferred** rather than a dedicated **Waiting…** display state.
- This **consumes no attempts**.
- The practical path is **rare** because edits fold into creates and deletes
  become local cancellation.
- Parked as **optional display-state polish**.

### Build / check reference

- The H-4 audit found **no correctness bugs**.
- **No app code changed.**
- `runChecks` passed.

### Verdict

- H-4 is **closed as audit-only**.
- **No implementation polish slice** is required before H-5.

### Parked next steps

- **Stage H-5** — iOS/Android parity checkpoint for fuel offline behaviour and
  broader offline queue parity (see the H-5 section below).
- **Optional fuel polish** — dedicated **Waiting…** display state for rare fuel
  dependency deferrals.
- **Optional UX polish** — role-gated fuel delete affordance and clearer
  permission messaging.
- **Cross-entity reconcile-after-load** design.
- **Stage G-3** — active-trip offline delete, still parked pending G-2 field
  confidence.
- **Stage F-3b** — related-record navigation.
- **Stage F-4** — dismiss/archive recovery design.

---

## Tier-A Stage H-5 — iOS/Android parity checkpoint (closed / audit only)

**Status: CLOSED / AUDIT ONLY.** Tier-A Stage H-5 was a read-only iOS/Android
parity checkpoint run after the Android fuel-log offline queue work (Stages H-1
through H-4). It compared the two platforms at a practical workflow level,
produced a parity matrix and gap report, and recommended next slices. **No app
code changed** on either platform; **no schema/RLS/RPC** changed; **no build was
required**.

### Files inspected

**iOS:**
- `Backend/Sync/SyncStatusCenter.swift`,
- `Backend/Sync/PinSyncService.swift`,
- `Backend/Sync/TripSyncService.swift`,
- `Backend/Sync/OperationsSyncServices.swift`,
- `Backend/Sync/ManagementSyncServices.swift` (incl. `FuelPurchaseSyncService`,
  `TractorFuelLogSyncService`),
- `VineTrackV2App.swift`,
- `NewMainTabView.swift`,
- `BackendSettingsView.swift`,
- `FuelLogView.swift`.

**Android:**
- pin sync coordinators,
- trip sync coordinators,
- fuel-log sync coordinators,
- pending-write model/repository,
- `ui/AppViewModel.kt`,
- `ui/screens/SyncStatusScreen.kt`,
- `docs/android-offline-field-reliability-status.md`.

### Architectural framing

The core difference between the two platforms:

**iOS** — a **generic local-first dirty-tracking** model:
- each sync service holds pending upserts/deletes,
- persisted metadata such as `pendingUpserts`, `pendingDeletes`, failed records,
- debounced eager push plus a push/pull sweep,
- last-write-wins via `client_updated_at`,
- broad entity coverage.

**Android** — an **explicit pending-write outbox**:
- per-op coordinators,
- ordered replay pipeline,
- dependency gates,
- coalescing,
- edit-before-create folding where needed,
- attempt caps,
- rich Sync Status.

Summary: **iOS is broader but coarser**; **Android is narrower historically but
deeper**, and now covers the core offline/delete/fuel workflows with richer
recovery UX.

### Android current state

Android now supports:
- offline pin create/edit/completion/photo,
- offline trip start/metadata/GPS/row/tank/end,
- pin delete queue,
- ended-trip delete queue,
- fuel-log create/update/delete queues,
- Sync Status labels/details/copy diagnostics,
- Retry all,
- per-item retry,
- ordered replay with dependency gates.

Parked Android items:
- active-trip offline delete,
- dismiss/archive recovery,
- related-record navigation.

### iOS current state

- iOS has **broad offline upsert/delete coverage** through dirty-tracking sync
  services.
- This includes pins, trips, fuel purchases, tractor fuel logs, and many
  operational/management entities.
- Pending work is represented mostly as **aggregate sync counts/status**.
- Retry is **implicit** through sweep / manual sync.
- iOS **lacks** the Android-style per-item pending-work list, op labels, details
  sheet, copy diagnostics, and per-item retry.

### Parity matrix

| Workflow | Status |
|---|---|
| Offline pin create | ✅ Parity / close enough |
| Offline pin edit/completion | ✅ Parity / close enough |
| Offline pin photos | ✅ Parity / close enough |
| Pin delete offline queue | ✅ Parity / close enough |
| Trip start offline | ✅ Parity / close enough |
| Trip progress offline | ✅ Parity / close enough |
| Trip end offline | ✅ Parity / close enough |
| Ended-trip delete offline queue | ✅ Parity / close enough |
| Active-trip offline delete | ⚠️ Partial — product decision needed |
| Fuel-log create offline | ✅ Parity / close enough |
| Fuel-log edit offline | ✅ Parity / close enough |
| Fuel-log delete offline | ✅ Parity / close enough |
| Sync Status visibility | ⚠️ Partial — Android richer |
| Retry all | ⚠️ Partial — Android explicit, iOS implicit/manual sweep |
| Per-item retry | ❌ Gap — Android only |
| Details / copy diagnostics | ❌ Gap — Android only |
| Map / pin display | ✅ Parity / close enough |
| Role / permission UX | ⏸️ Parked — product decision |

### Key gaps

- iOS **Sync Status UX depth** is behind Android.
- iOS **lacks explicit per-item retry**.
- **Active-trip offline delete** semantics differ between platforms.
- Android has **explicit dependency-gated replay** while iOS relies on dirty
  tracking / sweep / last-write-wins.
- **User-facing wording differs**.
- **Role/permission destructive affordances** are parked on both platforms.

### Risk classification

- **iOS Sync Status depth gap** — should fix before broad beta; iOS should follow
  Android.
- **iOS per-item retry gap** — should fix before broad beta; iOS should follow
  Android.
- **Active-trip offline delete** — product decision needed; not a blocker.
- **iOS formal dependency gating** — acceptable parked item.
- **Wording divergence** — acceptable parked item; shared wording pass.
- **Role/permission destructive affordances** — acceptable parked item, product
  decision.
- **Core CRUD offline parity** — no blocker.

### Recommended next slices

- **No Android polish required** from H-5.
- **iOS Sync Status parity audit/design first.**
- **iOS pending-work list/details/copy diagnostics** as read-only first.
- **iOS Retry all / per-item retry** later.
- **Shared wording/UX alignment.**
- **Active-trip offline delete** product decision.
- **Deeper release parity audit** before TestFlight / Play testing.
- Keep **dismiss/archive recovery** and **related-record navigation** parked.

### Verdict

- H-5 **closes as an audit-only parity checkpoint**.
- Core **offline CRUD has effectively reached parity** for pins, trips, and fuel
  logs.
- Remaining gaps are mainly **iOS catching up to Android Sync Status/retry UX**
  plus the **active-trip delete product decision**.
- **No code changed.**
- **No build required.**

### Parked next steps

- **iOS Sync Status parity audit/design.**
- **iOS pending-work list/details/copy diagnostics.**
- **iOS Retry all / per-item retry.**
- **Shared wording/UX alignment.**
- **Active-trip offline delete** product decision.
- **Deeper release parity audit.**
- **Stage G-3** — active-trip offline delete, still parked.
- **Stage F-3b** — related-record navigation.
- **Stage F-4** — dismiss/archive recovery design.

---

## Stage I — Spray-record plain offline queue (closed)

Offline queueing and replay for the **plain spray-record create/update/delete
paths** (the spray calculator / standard spray form), bringing Android to
offline parity with the existing iOS app for plain spray records. **No iOS
changes, no schema/RLS/RPC changes, no read-cache changes, no export/cost logic
changes, no trip-coupled spray-create offline support.**

### Files changed across implementation

- `data/SprayRecordRepository.kt` — explicit replay `id` / `clientUpdatedAt`
  support on create/update; existing online behaviour preserved by default.
- `data/SprayRecordCreateSync.kt` — `SPRAY_RECORD` / `CREATE` coordinator plus
  edit-before-create `foldEdit(...)`.
- `data/SprayRecordUpdateSync.kt` — `SPRAY_RECORD` / `UPDATE` coordinator with
  same-id create deferral.
- `data/SprayRecordDeleteSync.kt` — `SPRAY_RECORD` / `DELETE` coordinator with
  same-id create/update deferral and idempotent already-deleted handling.
- `ui/AppViewModel.kt` — create/update/delete write paths, marker
  enqueue/fold/cancel, replay wiring, and Sync Status labels.
- `ui/screens/SyncStatusScreen.kt` — spray-record Sync Status labels/details.

### Stage I-0 — design summary

- Android spray records were **online-only** before Stage I.
- The **iOS benchmark queues spray records through dirty-tracking**.
- Android **already had `PendingEntityType.SPRAY_RECORD`** available.
- A spray record is a **single atomic record with embedded tanks**, so **no
  child-row queue was required**.
- The existing **server contract already supported client-generated `id` and
  `client_updated_at`**.
- **No schema/RLS/RPC changes were needed.**

### Stage I-1 — CREATE summary

- The plain `createSprayRecord` path now **mints `id` + `clientUpdatedAt` before
  the network call**.
- **Offline/transient create prepends an optimistic row** to
  `AppUiState.sprayRecords`.
- **One `SPRAY_RECORD` / `CREATE` marker is queued** (clientId = sprayRecordId).
- **Replay uses the payload `id` + `clientUpdatedAt`**.
- **Duplicate / 409 is treated as idempotent success** where safe.
- **Clean online success reconciles by id** and leaves no marker.
- **Permanent validation/permission failure rolls back** the optimistic row.
- **Trip-coupled create variants remain online-only.**

Create payload includes: stable `id`, `vineyardId`, date/start time, weather
fields, spray reference, notes, fan/jet count, average speed, equipment type,
tractor/gear, machine id, spray equipment id, operation type, `tripId` (only if
already present in the plain form path), `isTemplate`, `tanks`, and
`clientUpdatedAt`. It **excludes** auth/session data, tokens, Supabase keys,
secrets, and `created_by` (resolved from the live session at replay).

### Stage I-2 — UPDATE summary

- `updateSprayRecord(...)` now supports an **optional replay `clientUpdatedAt`**.
- **Offline/transient edit updates the row optimistically.**
- **Edit-before-create folds the latest editable values into the pending CREATE
  marker** (no UPDATE marker queued; `clientUpdatedAt` refreshed; Sync Status
  stays "Spray record").
- **Standalone updates coalesce to one `SPRAY_RECORD` / `UPDATE` marker per
  record** (latest edit wins).
- **Replay defers behind a same-id unresolved CREATE without consuming
  attempts.**
- **Clean success reconciles by id; permanent failures roll back** to the
  previous list.
- **`created_by` is never mutated.**

### Stage I-3 — DELETE summary

- Delete uses a `SPRAY_RECORD` / `DELETE` payload of **`{ sprayRecordId }`**
  only.
- **Delete-before-create cancels the pending CREATE and any same-id UPDATE
  locally** and removes the optimistic row — **no server RPC is called** for a
  never-synced record (prevents resurrection).
- **Synced deletes optimistically hide the row** and queue DELETE when
  offline/transient.
- **One unresolved DELETE marker per record** (coalesced).
- **Replay defers behind a same-id unresolved CREATE/UPDATE without consuming
  attempts**, and calls the existing `softDeleteSprayRecord(...)`.
- **Already-deleted / 404 / missing-row is treated as success** where safe.
- **Permission/validation failures BLOCK instead of infinite retry.**

### Stage I-4 — QA/UX summary

- **Full create/update/delete lifecycle QA passed** (create+edit fold,
  delete-before-create cancel, create-then-edit, update-then-delete, edit/delete
  coalescing, dependency deferrals not consuming attempts).
- **Final replay order:** fuel-log deletes → spray creates → spray updates →
  spray deletes → pin photos. This order is present in **Retry all, per-item
  retry, reconnect, and post-load**.
- **Sync Status titles:** `CREATE` → "Spray record", `UPDATE` → "Spray record
  edit", `DELETE` → "Spray record delete". The **details sheet shows entity
  "Spray record" plus the operation**.
- **Copy diagnostics excludes** payload JSON, tanks JSON, and
  auth/session/tokens/keys/secrets.
- **`runChecks` passed.**

### UX / safety behaviour

- **Create offline** shows an optimistic row and a friendly offline message.
- **Update offline** keeps the optimistic edit.
- **Delete offline** hides the row.
- **Transient failures** keep the queued local state.
- **Immediate permanent failures roll back local UI** where appropriate.
- **Queued permission/validation failures become BLOCKED / Needs attention** and
  remain visible in Sync Status.

### Boundaries / parked decisions

- **Only the plain spray-record create/update/delete paths are queued.**
- **`createSprayJobForLater`, `startSprayJob`, `startSprayJobNow`, trip-first
  create variants, and import remain online-only.**
- **Trip-coupled spray-create offline support is parked** because it requires
  trip-create dependency gates and live-GPS considerations.
- **Spray-record read-cache / offline app-restart viewing remains parked.**
- **No iOS changes. No schema/RLS/RPC changes.**

### Parity checkpoint

- **Android now has offline parity with the existing iOS app for plain
  spray-record create/update/delete.**
- **Android is ahead of iOS on Sync Status / retry / details.**
- **Remaining Android parity gaps are broader entity coverage:** work tasks +
  lines, maintenance logs, yield / historical yield, damage records,
  growth-stage records, management/reference entities, per-record sync badges,
  and broader read-cache.

### Build / check reference

- **Stage I-0 — design only**, no build required.
- **Stage I-1 implementation `runChecks` passed**; **I-1 QA `runChecks` passed**.
- **Stage I-2 implementation `runChecks` passed**; **I-2 QA `runChecks` passed**.
- **Stage I-3 implementation `runChecks` passed**; **I-3 QA `runChecks` passed**.
- **Stage I-4 QA `runChecks` passed** (no code changed).

### Recommended next Android-only module

- The next major parity module should be the **Work Tasks offline queue**.
- **Start with a design/audit slice** because work tasks have **dependent
  labour/machine/paddock line records**, unlike the single-atomic spray record.

---

## Stage J — Work-task offline queue (closed)

Offline queueing and replay for the **work-task header plus its dependent labour
and machine line records** (create / update / finalize-reopen / delete), bringing
Android to offline coverage for the work-task workflow. Unlike the single-atomic
spray record, work tasks have **dependent child line records**, so this stage
adds **explicit parent dependency gates**. **No iOS changes, no schema/RLS/RPC
changes, no read-cache changes, no trip-side work-task link changes, and no
export/cost logic changes beyond compile tolerance.**

### Stage status

The Work Task offline queue is **CLOSED**. Closed substages:

- **J-0** — audit/design (dependent-record model, marker shapes, dependency
  gates, staged plan).
- **J-1** — work-task header CREATE.
- **J-2** — work-task header UPDATE / finalize-reopen.
- **J-3** — work-task header DELETE.
- **J-4** — labour line CREATE/UPDATE/DELETE.
- **J-5** — machine line CREATE/UPDATE/DELETE.
- **J-6** — QA/UX polish + synced-delete child-marker sweep.

### Files changed across implementation

- `data/model/PendingWrite.kt` — added `WORK_TASK`, `WORK_TASK_LABOUR`, and
  `WORK_TASK_MACHINE` pending entity types.
- `data/WorkTaskRepository.kt` — header create/metadata-update/finalize support
  with explicit replay `id` / `clientUpdatedAt`, folded finalize-on-insert, and
  a combined header-update patch; existing online behaviour preserved by
  default.
- `data/WorkTaskCreateSync.kt` — `WORK_TASK` / `CREATE` coordinator plus
  edit/finalize-before-create folding.
- `data/WorkTaskUpdateSync.kt` — `WORK_TASK` / `UPDATE` coordinator with same-id
  create deferral.
- `data/WorkTaskDeleteSync.kt` — `WORK_TASK` / `DELETE` coordinator with same-id
  create/update deferral and idempotent already-deleted handling.
- `data/WorkTaskLineRepository.kt` — labour/machine line upsert/delete with
  explicit replay `id` / `clientUpdatedAt`; online behaviour preserved by
  default.
- `data/WorkTaskLabourSync.kt` — `WORK_TASK_LABOUR` create/update/delete
  coordinator with parent dependency gate.
- `data/WorkTaskMachineSync.kt` — `WORK_TASK_MACHINE` create/update/delete
  coordinator with parent dependency gate.
- `ui/AppViewModel.kt` — header + labour + machine write paths, marker
  enqueue/fold/cancel, header-delete child-marker cleanup + synced-delete
  sweep, replay wiring/ordering, and Sync Status labels/diagnostics.
- `ui/screens/SyncStatusScreen.kt` — friendly work-task entity labels in the
  details sheet.

### Final replay ordering

The final work-task replay order is:

1. work-task creates (`replayPendingWorkTaskCreates()`),
2. work-task updates (`replayPendingWorkTaskUpdates()`),
3. labour create/update/delete (`replayPendingWorkTaskLabour()`),
4. machine create/update/delete (`replayPendingWorkTaskMachine()`),
5. work-task deletes (`replayPendingWorkTaskDeletes()`),
6. pin photos.

The whole work-task group sits **after spray deletes and before pin photos** in
**all four replay pipelines** — Retry all, per-item retry, reconnect, and
post-load.

### Dependency gates

- **Header UPDATE** defers while the same task has an unresolved `WORK_TASK` /
  `CREATE`.
- **Header DELETE** defers while the same task has an unresolved `WORK_TASK` /
  `CREATE` or `WORK_TASK` / `UPDATE`.
- **Labour and machine** create/update/delete replays defer while the same
  `workTaskId` has an unresolved header `WORK_TASK` / `CREATE`.
- **Dependency deferrals do not consume attempts** — a deferred marker is
  retried later without counting toward its attempt cap.
- **Child line writes are never replayed before the parent task exists
  server-side.**

### Folding / coalescing / cancellation

- **Edit-before-create** folds the latest editable header fields into the
  pending header CREATE (no UPDATE marker queued; `clientUpdatedAt` refreshed).
- **Finalize/reopen-before-create** folds the finalized state into the pending
  header CREATE where safe.
- **Delete-before-create** (never-synced task) cancels the local header CREATE
  and any same-id header UPDATE marker, and also cancels any same-task labour
  and machine markers — no server call is made.
- **Labour/machine edit-before-create** folds the latest editable values into
  the child CREATE marker (no child UPDATE marker queued).
- **Labour/machine delete-before-create** cancels the child CREATE and any
  same-line child UPDATE marker locally — no server delete RPC is called.
- **Repeated updates and deletes coalesce** to one unresolved marker per
  entity (header per task; labour/machine per line); latest edit wins.

### Delete cleanup

- **Never-synced work-task delete** cancels the header markers and all
  same-task child labour/machine markers, removes the optimistic rows locally,
  and makes **no server call**.
- **Synced work-task delete** now **sweeps unresolved same-task labour/machine
  markers** where the delete is committed, so child markers do not linger after
  the parent is removed.
- The synced-delete sweep **only removes unresolved pending markers** — it does
  **not** remove already-synced child history on the server.

### Sync Status coverage

Friendly labels:

- `WORK_TASK` / `CREATE` → **Work task**,
- `WORK_TASK` / `UPDATE` → **Work task edit**,
- `WORK_TASK` / `DELETE` → **Work task delete**,
- `WORK_TASK_LABOUR` / `CREATE` → **Work task labour**,
- `WORK_TASK_LABOUR` / `UPDATE` → **Work task labour edit**,
- `WORK_TASK_LABOUR` / `DELETE` → **Work task labour delete**,
- `WORK_TASK_MACHINE` / `CREATE` → **Work task machine**,
- `WORK_TASK_MACHINE` / `UPDATE` → **Work task machine edit**,
- `WORK_TASK_MACHINE` / `DELETE` → **Work task machine delete**.

Also:

- **Details-sheet entity labels are friendly** (header/labour/machine map to
  readable names rather than raw entity strings).
- **Retry all and per-item retry** work for every work-task marker type through
  the existing generic Sync Status surface.
- **Copy diagnostics excludes** payload JSON, line payloads, and
  auth/session/tokens/Supabase keys/secrets (emits metadata only).

### Payload exclusions

- Header and child payloads **exclude** auth/session data, tokens, Supabase
  keys, secrets, and `created_by` (resolved from the live session at replay).
- Child payloads **exclude** parent work-task copies and DB-generated totals
  (e.g. labour `total_hours` / `total_cost`).

### Boundaries / parked items

These remain **online-only / out of scope** for Stage J:

- **trip-side work-task links** (work tasks created/linked from the trip flow),
- **read-cache / offline app-restart browsing** for work tasks and their lines,
- **other operation modules** — maintenance, yield / historical yield, damage,
  and growth-stage records (not part of Stage J),
- **iOS changes** of any kind.

### Parity checkpoint

- **Android work-task offline coverage is now substantially aligned with the
  existing iOS dirty-tracking model** for the work-task header plus labour and
  machine lines (create / update / finalize-reopen / delete).
- **Android remains intentionally Android-only** — no iOS app changes were made
  in Stage J.
- **Android Sync Status / retry UX remains stronger than iOS** (per-item op
  labels, details sheet, copy diagnostics, Retry all, and per-item retry).
- **Remaining broad offline parity gaps are outside Stage J:** trip-side
  work-task links, work-task read-cache, and the maintenance / yield / damage /
  growth-stage modules.

### Build / check reference

- **Stage J-0 — design only**, no build required.
- **J-1 through J-5 implementation `runChecks` passed**; each J-1 through J-5 QA
  pass `runChecks` passed.
- **J-6 `runChecks` passed** after the synced-delete child-marker sweep.
- **J-7 is documentation only** — no app code changed, so no build was required
  for this update.

### Parked next steps

- **Trip-side work-task link offline support** (needs trip-create dependency
  gates).
- **Work-task read-cache / offline app-restart viewing.**
- **Maintenance / yield / damage / growth-stage offline queues.**
- **iOS Sync Status / retry UX parity** (iOS catching up to Android).

---

## Stage K — Maintenance offline queue (closed)

Offline queueing and replay for **maintenance logs** (create / update / delete),
bringing Android to offline coverage for the maintenance workflow. Unlike work
tasks, a maintenance log is a **single record with no dependent child table**,
so the queue mirrors the spray-record triad pattern with a single
`MAINTENANCE_LOG` entity carrying `CREATE` / `UPDATE` / `DELETE`. **No iOS
changes, no schema/RLS/RPC changes, no read-cache changes, no invoice/photo
upload changes, and no export/cost logic changes beyond compile tolerance.**

### Stage status

The Maintenance offline queue is **CLOSED**. Closed substages:

- **K-0** — audit/design (single-record model, marker shapes, dependency gates,
  staged plan).
- **K-1** — maintenance log CREATE.
- **K-2** — maintenance log UPDATE.
- **K-3** — maintenance log DELETE.
- **K-4** — QA/UX polish + lifecycle audit.
- **K-5** — documentation closure (this note).

### Files changed across implementation

- `data/MaintenanceLogRepository.kt` — create/update support with explicit
  replay `id` / `clientUpdatedAt`, plus `softDeleteMaintenanceLog(...)`;
  existing online behaviour preserved by default (UUID minted when no id given,
  `clientUpdatedAt` defaults to `nowIso()`, `created_by` resolved from the live
  session).
- `data/MaintenanceLogCreateSync.kt` — `MAINTENANCE_LOG` / `CREATE` coordinator
  plus the `foldEdit` helper for edit-before-create folding.
- `data/MaintenanceLogUpdateSync.kt` — `MAINTENANCE_LOG` / `UPDATE` coordinator
  with same-id create deferral.
- `data/MaintenanceLogDeleteSync.kt` — `MAINTENANCE_LOG` / `DELETE` coordinator
  with same-id create/update deferral and idempotent already-deleted handling.
- `data/model/Models.kt` — `applyMaintenanceInput(...)` optimistic-edit helper
  (touches only editable fields; preserves id/vineyardId/createdBy/photoPath).
- `ui/AppViewModel.kt` — maintenance create/update/delete write paths, marker
  enqueue/fold/cancel, replay wiring/ordering, and Sync Status labels.
- `ui/screens/SyncStatusScreen.kt` — friendly maintenance entity label in the
  details sheet.

### Final replay ordering

The final maintenance replay order is:

1. maintenance creates (`replayPendingMaintenanceCreates()`),
2. maintenance updates (`replayPendingMaintenanceUpdates()`),
3. maintenance deletes (`replayPendingMaintenanceDeletes()`),
4. pin photos.

The whole maintenance group sits **after work-task deletes and before pin
photos** in **all four replay pipelines** — Retry all, per-item retry,
reconnect, and post-load.

### Folding / coalescing / cancellation

- **Edit-before-create** folds the latest editable fields into the pending
  `MAINTENANCE_LOG` / `CREATE` payload (no UPDATE marker queued;
  `clientUpdatedAt` refreshed).
- **Delete-before-create** (never-synced log) cancels the local CREATE marker
  and any same-id UPDATE marker, removes the optimistic row, and makes **no
  server call**.
- **Standalone updates coalesce** to one unresolved `MAINTENANCE_LOG` / `UPDATE`
  marker per log; latest edit wins; stale failed payloads are replaced safely.
- **Standalone deletes coalesce** to one unresolved `MAINTENANCE_LOG` / `DELETE`
  marker per log; repeated deletes do not duplicate markers.
- **UPDATE defers** while the same log has an unresolved `MAINTENANCE_LOG` /
  `CREATE`.
- **DELETE defers** while the same log has an unresolved `MAINTENANCE_LOG` /
  `CREATE` or `MAINTENANCE_LOG` / `UPDATE`.
- **Dependency deferrals do not consume attempts** — a deferred marker is
  retried later without counting toward its attempt cap.

### Payload / security

- **CREATE / UPDATE payload** carries the editable maintenance fields only: `id`,
  `vineyardId`, `itemName`, `equipmentSource`, `equipmentRefId`, `hours`,
  `machineHours`, `workCompleted`, `partsUsed`, `partsCost`, `labourCost`,
  `date`, `isArchived`, `isFinalized`, and `clientUpdatedAt`.
- **DELETE payload** carries only `{ maintenanceLogId }`.
- Payloads **exclude** auth/session data, tokens, Supabase keys, secrets,
  `created_by`, `photo_path`, archived/finalized audit columns, and
  server-managed audit/sync columns.
- **`created_by` is resolved from the live session** during create replay — it
  is never carried in the payload.
- **Copy diagnostics excludes** payload JSON and auth/session/tokens/Supabase
  keys/secrets (emits metadata only).

### Sync Status coverage

Friendly labels:

- `MAINTENANCE_LOG` / `CREATE` → **Maintenance**,
- `MAINTENANCE_LOG` / `UPDATE` → **Maintenance edit**,
- `MAINTENANCE_LOG` / `DELETE` → **Maintenance delete**.

Also:

- **Details-sheet type label** maps `maintenance_log` to **Maintenance**.
- **Operation row** shows `CREATE` / `UPDATE` / `DELETE` correctly.
- **Retry all and per-item retry** work for every maintenance marker type
  through the existing generic Sync Status surface.
- **Diagnostics are payload-free and secret-free.**

### Role / permission handling

- **Operators may create/edit maintenance logs but may not soft-delete them.**
- **Immediate online delete permission failure** rolls back the optimistic hide
  and does **not** queue a marker.
- **Queued delete permission failure** becomes **BLOCKED / needs attention** in
  Sync Status.
- **Role-restricted delete does not infinite retry** — permission/validation
  failures block rather than loop.

### Boundaries / parked items

These remain **online-only / out of scope** for Stage K:

- **maintenance invoice/photo upload** (Android does not currently write
  maintenance photos),
- **maintenance read-cache / offline app-restart browsing**,
- **child records** (none exist for maintenance),
- **iOS changes** of any kind,
- **schema / RLS / RPC changes.**

### Parity checkpoint

- **Android maintenance offline coverage is now substantially aligned with the
  existing iOS dirty-tracking model** for maintenance metadata create / update /
  delete.
- **Android does not yet mirror iOS maintenance photo upload** because Android
  does not currently write maintenance photos.
- **Android remains intentionally Android-only** — no iOS app changes were made
  in Stage K.
- **Android Sync Status / retry UX remains stronger than iOS** (per-item op
  labels, details sheet, copy diagnostics, Retry all, and per-item retry).
- **Remaining broad offline parity gaps are outside Stage K:** maintenance
  photo upload, maintenance read-cache, and the yield / damage / growth-stage
  modules.

### Build / check reference

- **Stage K-0 — design only**, no build required.
- **K-1 through K-3 implementation `runChecks` passed**; each K-1 through K-3 QA
  pass `runChecks` passed.
- **K-4 `runChecks` passed** (QA-only, no code changed).
- **K-5 is documentation only** — no app code changed, so no build was required
  for this update.

### Parked next steps

- **Maintenance invoice/photo upload offline retry** (needs an Android
  maintenance photo write path first).
- **Maintenance read-cache / offline app-restart viewing.**
- **Yield / damage / growth-stage offline queues.**
- **iOS Sync Status / retry UX parity** (iOS catching up to Android).

---

## Stage L — Yield offline queue (closed)

Offline queueing and replay for **historical yield records** (create / update /
delete), bringing Android to offline coverage for the yield workflow. A yield
record is a **single record with embedded `blockResults`** (no separate child
table), so the queue mirrors the maintenance/spray triad pattern with a single
`YIELD_RECORD` entity carrying `CREATE` / `UPDATE` / `DELETE`. **No iOS changes,
no schema/RLS/RPC changes, no read-cache changes, no yield-estimation-session
changes, and no export/cost logic changes beyond compile tolerance.**

### Stage status

The Yield offline queue is **CLOSED**. Closed substages:

- **L-0** — audit/design (single-record-with-embedded-block-results model,
  marker shapes, dependency gates, staged plan).
- **L-1** — yield record CREATE.
- **L-2** — yield record UPDATE.
- **L-3** — yield record DELETE.
- **L-4** — QA/UX polish + lifecycle audit.
- **L-5** — documentation closure (this note).

### Files changed across implementation

- `data/YieldRepository.kt` — create/update support with explicit replay `id`,
  block-result ids, and `clientUpdatedAt`, plus `softDeleteYieldRecord(...)`;
  existing online behaviour preserved by default (record + block-result UUIDs
  minted when none given, `clientUpdatedAt` defaults to `nowIso()`, `created_by`
  resolved from the live session).
- `data/YieldRecordCreateSync.kt` — `YIELD_RECORD` / `CREATE` coordinator plus
  the `foldEdit` helper and the pure `buildActualRecord(...)` /
  `buildEstimateRecord(...)` optimistic-record builders.
- `data/YieldRecordUpdateSync.kt` — `YIELD_RECORD` / `UPDATE` coordinator with
  same-id create deferral and the pure `buildUpdatedEstimateRecord(...)` builder.
- `data/YieldRecordDeleteSync.kt` — `YIELD_RECORD` / `DELETE` coordinator with
  same-id create/update deferral and idempotent already-deleted handling.
- `data/model/Models.kt` — `HistoricalYieldRecord` / `HistoricalBlockResult`
  serializable shapes used across optimistic UI, marker payloads, and replay
  (no new server-managed fields introduced).
- `ui/AppViewModel.kt` — yield create/update/delete write paths (actual and
  estimate), marker enqueue/fold/cancel, replay wiring/ordering, and Sync Status
  labels.
- `ui/screens/SyncStatusScreen.kt` — friendly yield entity label in the details
  sheet.

### Final replay ordering

The final yield replay order is:

1. yield creates (`replayPendingYieldCreates()`),
2. yield updates (`replayPendingYieldUpdates()`),
3. yield deletes (`replayPendingYieldDeletes()`),
4. pin photos (where pin-photo replay exists).

The whole yield group sits **after maintenance deletes and before pin photos**
(where applicable) in **all four replay pipelines** — Retry all, per-item retry,
reconnect, and post-load. **Reconnect intentionally omits pin-photo replay**,
matching the existing app pattern from all prior stages.

### Folding / coalescing / cancellation

- **Edit-before-create** folds the latest editable fields and `blockResults`
  into the pending `YIELD_RECORD` / `CREATE` payload (no UPDATE marker queued;
  `clientUpdatedAt` refreshed).
- **Delete-before-create** (never-synced record) cancels the local CREATE marker
  and any same-id UPDATE marker, removes the optimistic row, and makes **no
  server call**.
- **Standalone updates coalesce** to one unresolved `YIELD_RECORD` / `UPDATE`
  marker per record; latest edit wins; stale failed payloads are replaced safely.
- **Standalone deletes coalesce** to one unresolved `YIELD_RECORD` / `DELETE`
  marker per record; repeated deletes do not duplicate markers.
- **UPDATE defers** while the same record has an unresolved `YIELD_RECORD` /
  `CREATE`.
- **DELETE defers** while the same record has an unresolved `YIELD_RECORD` /
  `CREATE` or `YIELD_RECORD` / `UPDATE`.
- **Dependency deferrals do not consume attempts** — a deferred marker is
  retried later without counting toward its attempt cap.

### Payload / security

- **CREATE / UPDATE payload** carries the editable yield fields only: `id`,
  `vineyardId`, `season`, `year`, `archivedAt`, `totalYieldTonnes`,
  `totalAreaHectares`, `notes`, `blockResults`, and `clientUpdatedAt`.
- **DELETE payload** carries only `{ yieldRecordId }`.
- **`blockResults` preserve the `HistoricalBlockResult` serializable shape**
  (camelCase) exactly across optimistic UI, payload, and replay.
- Payloads **exclude** auth/session data, tokens, Supabase keys, secrets,
  `created_by`, `updated_by`, and server-managed audit/sync columns
  (`created_at`, `updated_at`, `deleted_at`, `sync_version`).
- **`created_by` is resolved from the live session** during create replay — it
  is never carried in the payload.
- **Copy diagnostics excludes** payload JSON and auth/session/tokens/Supabase
  keys/secrets (emits metadata only).

### Sync Status coverage

Friendly labels:

- `YIELD_RECORD` / `CREATE` → **Yield**,
- `YIELD_RECORD` / `UPDATE` → **Yield edit**,
- `YIELD_RECORD` / `DELETE` → **Yield delete**.

Also:

- **Details-sheet type label** maps `yield_record` to **Yield**.
- **Operation row** shows `CREATE` / `UPDATE` / `DELETE` correctly.
- **Retry all and per-item retry** work for every yield marker type through the
  existing generic Sync Status surface.
- **Diagnostics are payload-free and secret-free.**

### Role / permission handling

- **Operators may create/edit yield records but may not soft-delete them.**
- **Immediate online delete permission failure** rolls back the optimistic hide
  and does **not** queue a marker.
- **Queued delete permission failure** becomes **BLOCKED / needs attention** in
  Sync Status.
- **Role-restricted delete does not infinite retry** — permission/validation
  failures block rather than loop.

### UI / report behaviour

- **Optimistic yield creates / edits / deletes are supported**, covering both
  the **actual** and **estimate** create paths and both the actual and estimate
  update paths.
- **Totals (`totalYieldTonnes` / `totalAreaHectares`) and `blockResults` are
  built before the network call** and shared identically across the optimistic
  UI row, the marker payload, and the replay insert/update.
- **Cost-per-tonne / cost-report surfaces tolerate pending optimistic yield
  rows, edits, and deletes** without regressing maintenance, work-task, fuel,
  spray, pin, or trip flows.

### Boundaries / parked items

These remain **online-only / out of scope** for Stage L:

- **yield estimation sessions** (Android does not currently write that entity),
- **yield read-cache / offline app-restart browsing**,
- **child records** (none exist — block results are embedded),
- **iOS changes** of any kind,
- **schema / RLS / RPC changes.**

### Parity checkpoint

- **Android yield offline coverage is now substantially aligned with the
  existing iOS dirty-tracking model** for historical yield records (create /
  update / delete).
- **Android does not yet mirror iOS yield estimation sessions** because Android
  does not currently write that entity.
- **Android remains intentionally Android-only** — no iOS app changes were made
  in Stage L.
- **Android Sync Status / retry UX remains stronger than iOS** (per-item op
  labels, details sheet, copy diagnostics, Retry all, and per-item retry).
- **Remaining broad offline parity gaps are outside Stage L:** yield estimation
  sessions, yield read-cache, and the damage / growth-stage modules.

### Build / check reference

- **Stage L-0 — design only**, no build required.
- **L-1 through L-3 implementation `runChecks` passed**; each L-1 through L-3 QA
  pass `runChecks` passed.
- **L-4 `runChecks` passed** (QA-only, no code changed).
- **L-5 is documentation only** — no app code changed, so no build was required
  for this update.

### Parked next steps

- **Yield estimation session offline queueing** (needs an Android estimation
  session write path first).
- **Yield read-cache / offline app-restart viewing.**
- **Damage / growth-stage offline queues.**
- **iOS Sync Status / retry UX parity** (iOS catching up to Android).

---

## Stage N — Growth-stage offline queue (closed)

Offline queueing and replay for **growth-stage records** (create / update /
delete), bringing Android to offline coverage for the growth-stage workflow. A
growth-stage record is a **single record with `photoPaths`** (no separate child
table), so the queue mirrors the maintenance/yield triad pattern with a single
`GROWTH_RECORD` entity carrying `CREATE` / `UPDATE` / `DELETE`. Android
direct-authored growth records remain **direct records with `pin_id = null`**;
the queue intentionally does **not** replicate iOS growth-pin mirroring. **No
iOS changes, no schema/RLS/RPC changes, no read-cache changes, and growth photo
upload/remove stays online-only.**

### Stage status

The Growth-stage offline queue is **CLOSED**. Closed substages:

- **N-0** — audit/design (single-record-with-photo-paths model, server contract
  with client-generated id + `client_updated_at` + `soft_delete_growth_stage_record`
  RPC, marker shapes, dependency gates, staged plan; photo upload parked).
- **N-1** — growth record CREATE.
- **N-2** — growth record UPDATE.
- **N-3** — growth record DELETE.
- **N-4** — QA/UX polish + lifecycle audit.
- **N-5** — documentation closure (this note).

**Stage M (damage records) remains PARKED** because Android has no damage
feature yet — no model, repository, read path, screen, AppViewModel state, or
online create/update/delete path (the only `damage` reference is the unrelated
yield-estimation `damageFactor`). A damage feature build (future M-1) must
precede any damage offline queue.

### Files changed across implementation

- `data/GrowthStageRecordRepository.kt` — create/update support with explicit
  replay `id` and `clientUpdatedAt`, plus `softDeleteGrowthStageRecord(...)`;
  existing online behaviour preserved by default (record UUID minted when none
  given, `clientUpdatedAt` defaults to `nowIso()`, `created_by` resolved from
  the live session).
- `data/GrowthRecordCreateSync.kt` — `GROWTH_RECORD` / `CREATE` coordinator plus
  the `foldEdit` helper used by the UPDATE flow.
- `data/GrowthRecordUpdateSync.kt` — `GROWTH_RECORD` / `UPDATE` coordinator with
  same-id create deferral.
- `data/GrowthRecordDeleteSync.kt` — `GROWTH_RECORD` / `DELETE` coordinator with
  same-id create/update deferral and idempotent already-deleted handling.
- `data/model/Models.kt` — the `GrowthStageRecord` serializable shape and the
  `applyGrowthInput(...)` optimistic-snapshot helper used identically across
  optimistic UI, marker payloads, and replay (no new server-managed fields
  introduced).
- `ui/AppViewModel.kt` — growth create/update/delete write paths, marker
  enqueue/fold/cancel, replay wiring/ordering, and Sync Status labels.
- `ui/screens/SyncStatusScreen.kt` — friendly growth entity label in the details
  sheet.

### Final replay ordering

The final growth replay order is:

1. growth creates (`replayPendingGrowthCreates()`),
2. growth updates (`replayPendingGrowthUpdates()`),
3. growth deletes (`replayPendingGrowthDeletes()`),
4. pin photos (where pin-photo replay exists).

The whole growth group sits **after yield deletes and before pin photos** (where
applicable) in **all four replay pipelines** — Retry all, per-item retry,
reconnect, and post-load. **Reconnect and post-load intentionally omit
pin-photo replay**, matching the existing app pattern from all prior stages.

### Folding / coalescing / cancellation

- **Edit-before-create** folds the latest editable fields into the pending
  `GROWTH_RECORD` / `CREATE` payload (no UPDATE marker queued; `clientUpdatedAt`
  refreshed).
- **Delete-before-create** (never-synced record) cancels the local CREATE marker
  and any same-id UPDATE marker, removes the optimistic row, and makes **no
  server call** (the soft-delete RPC is not invoked).
- **Standalone updates coalesce** to one unresolved `GROWTH_RECORD` / `UPDATE`
  marker per record; latest edit wins; stale failed payloads are replaced safely.
- **Standalone deletes coalesce** to one unresolved `GROWTH_RECORD` / `DELETE`
  marker per record; repeated deletes do not duplicate markers.
- **UPDATE defers** while the same record has an unresolved `GROWTH_RECORD` /
  `CREATE`.
- **DELETE defers** while the same record has an unresolved `GROWTH_RECORD` /
  `CREATE` or `GROWTH_RECORD` / `UPDATE`.
- **Dependency deferrals do not consume attempts** — a deferred marker is
  retried later without counting toward its attempt cap.

### Payload / security

- **CREATE / UPDATE payload** carries the direct form-owned fields only: `id`,
  `vineyardId`, `paddockId`, `stageCode`, `stageLabel`, `variety`, `observedAt`,
  `rowNumber`, `notes`, and `clientUpdatedAt`.
- **DELETE payload** carries only `{ growthRecordId }`.
- Payloads **exclude** auth/session data, tokens, Supabase keys, secrets,
  `created_by`, `updated_by`, and server-managed audit/sync columns
  (`created_at`, `updated_at`, `deleted_at`, `sync_version`).
- Payloads **exclude the iOS pin-mirroring fields** (`pin_id`, `latitude`,
  `longitude`, `side`) and **`photo_paths`** — Android direct edits never mutate
  mirrored pin/photo state.
- **`created_by` is resolved from the live session** during create replay — it
  is never carried in the payload.
- **Copy diagnostics excludes** payload JSON and auth/session/tokens/Supabase
  keys/secrets (emits metadata only).

### Sync Status coverage

Friendly labels:

- `GROWTH_RECORD` / `CREATE` → **Growth**,
- `GROWTH_RECORD` / `UPDATE` → **Growth edit**,
- `GROWTH_RECORD` / `DELETE` → **Growth delete**.

Also:

- **Details-sheet type label** maps `growth_record` to **Growth**.
- **Operation row** shows `CREATE` / `UPDATE` / `DELETE` correctly.
- **Retry all and per-item retry** work for every growth marker type through the
  existing generic Sync Status surface.
- **Diagnostics are payload-free and secret-free.**

### Role / permission handling

- **Operators may create/edit growth records but may not soft-delete them.**
- **Immediate online delete permission failure** rolls back the optimistic hide
  and does **not** queue a marker.
- **Queued delete permission failure** becomes **BLOCKED / needs attention** in
  Sync Status.
- **Role-restricted delete does not infinite retry** — permission/validation
  failures block rather than loop.

### UI behaviour

- **Optimistic growth creates / edits / deletes are supported** and display
  correctly in the Growth screen.
- The **`applyGrowthInput(...)` snapshot is built before the network call** and
  shared identically across the optimistic UI row, the marker payload, and the
  replay insert/update; it **preserves record id, existing `pinId`,
  `photoPaths`, `createdAt`, and geo/side/non-form fields** while updating only
  the form-owned fields and the client timestamp.
- **Direct Android-authored growth rows remain `pin_id = null`.**
- **Existing pinned/mirrored records preserve their local pin/photo fields**
  during optimistic edits; the direct-edit payload does not mutate iOS
  pin-mirroring fields or `photo_paths`.
- **Block Detail growth summary tolerates pending optimistic creates / edits /
  deletes** without regressing pin, trip, yield, or maintenance flows.

### Photo boundary

Growth photo upload/remove remains **online-only** for the whole of Stage N:

- **no `photo_paths` writes are queued**,
- **no storage uploads are queued**,
- **no storage deletes are queued**,
- optimistic update **preserves existing photo paths locally for display only**,
- optimistic delete **does not attempt storage cleanup**.

### Boundaries / parked items

These remain **online-only / out of scope** for Stage N:

- **growth photo upload/remove offline queue**,
- **growth read-cache / offline app-restart browsing**,
- **iOS pin-mirroring logic** and **iOS changes** of any kind,
- **schema / RLS / RPC changes**,
- **the damage feature build and damage offline queue** (Stage M parked).

### Parity checkpoint

- **Android growth-stage offline coverage is now substantially aligned with the
  iOS dirty-tracking model** for direct growth-stage records (create / update /
  delete).
- **Android intentionally does not replicate iOS growth-pin mirroring** —
  Android direct-authored records remain `pin_id = null`.
- **Android Sync Status / retry UX remains stronger than iOS** (per-item op
  labels, details sheet, copy diagnostics, Retry all, and per-item retry).
- **Damage remains parked** because Android lacks the feature surface entirely.
- **Remaining broad offline parity gaps are now mostly photo / read-cache /
  damage-feature related.**

### Build / check reference

- **Stage N-0 — design only**, no build required.
- **N-1 through N-3 implementation `runChecks` passed**; each N-1 through N-3 QA
  pass `runChecks` passed.
- **N-4 `runChecks` passed** (QA-only, no code changed).
- **N-5 is documentation only** — no app code changed, so no build was required
  for this update.

### Parked next steps

- **Growth photo upload/remove offline queueing** (needs an offline photo write /
  storage retry path).
- **Growth read-cache / offline app-restart viewing.**
- **Damage feature build (M-1) then damage offline queue (M-2+).**
- **iOS Sync Status / retry UX parity** (iOS catching up to Android).

---

## Stage O — Offline read-cache / restart browsing (closed, first slice)

Offline restart browsing for **maintenance logs, yield records, and growth-stage
records**, built from two complementary layers: a **pending-write overlay**
(O-1) that rebuilds optimistic rows from the existing persistent outbox, and a
**server snapshot cache** (O-2) that supplies a last-known-good baseline for
those overlays after an offline restart. **No iOS changes, no schema/RLS/RPC
changes, no broad cache expansion to trips/spray/fuel/work-tasks, no photo
offline handling, and no change to existing pending-write replay semantics.**

### Stage status

The Offline read-cache / restart-browsing stage is **CLOSED for the first
completed slice** (maintenance / yield / growth). Closed substages:

- **O-0** — audit/design (read-cache map, app-start hydration behaviour,
  pending-write reconstruction feasibility, recommended local-first merge
  design, staged plan).
- **O-1** — pending-write restart hydration.
- **O-2** — server snapshot cache (maintenance / yield / growth).
- **O-3** — screen integration / cached-pending UX audit.
- **O-4** — full QA/UX polish.
- **O-5** — documentation closure (this note).

### Files changed across implementation

- `data/PendingWriteOverlay.kt` — new stateless overlay object that rebuilds
  maintenance/yield/growth display rows from unresolved outbox markers.
- `data/DomainCacheStore.kt` — added vineyard-scoped JSON storage + per-entity
  synced timestamps for maintenance/yield/growth, reusing the existing
  SharedPreferences file and owner-gating.
- `data/DomainCacheRepository.kt` — save/load wrappers for the three new cached
  entity families, kept consistent with the existing paddock/pin cache API.
- `ui/AppViewModel.kt` — `loadVineyardData()` cache write-through on server
  success, cache fallback on failure, and a single pending-write overlay pass
  after baseline selection.
- `docs/android-offline-field-reliability-status.md` — this status note.

### O-1 pending-write overlay

- **Uses the existing persistent pending-write outbox** (`PendingWriteRepository`
  snapshot passed in) — **introduces no second outbox**.
- **Performs no network calls**; **does not mutate, replay, clear, or re-status
  markers**; **does not alter attempt counts**.
- **Overlays unresolved markers only** (`QUEUED` / `FAILED` / `BLOCKED` where
  they represent user-visible local state); **`SYNCED` markers are ignored**.
- **Supports maintenance, yield, and growth** entity families.
- **CREATE** reconstructs a display row from the CREATE payload and inserts /
  dedupes by id (a same-id baseline row wins).
- **UPDATE** overlays form-owned fields **only when a same-id baseline / created
  row already exists** — it never invents a row; latest unresolved UPDATE wins.
- **DELETE** hides the same-id row.
- **UPDATE / DELETE without a baseline are harmless no-ops** (no invented row, no
  cross-vineyard hide, no crash); a CREATE+DELETE pair for the same id resolves
  to no visible row.
- **Vineyard scoping**: CREATE/UPDATE overlays are filtered by payload
  `vineyardId`; DELETE markers carry only an id and are applied **only** to rows
  already present in the selected vineyard's baseline/created overlay, so they
  **cannot hide rows from another vineyard**; markers lacking required scoping
  are skipped.
- **Corrupt / undecodable payloads are ignored safely.**
- Growth specifics: Android-authored pending CREATE rows keep **`pinId = null`**,
  **no `photoPaths` are invented**, and UPDATE overlays preserve existing
  `pinId` / photo / geo fields while changing only form-owned fields.

### O-2 server snapshot cache

- **Extends the existing `DomainCacheStore` / `DomainCacheRepository`** (same
  JSON-backed SharedPreferences file, same owner-gating, same whole-group
  replace style as the paddock/pin caches) — **no second cache architecture, no
  Room, no schema/RLS/RPC changes**.
- **JSON-backed local storage**, **owner/user gated**, **vineyard scoped**
  (`maintenance_<vid>`, `yield_<vid>`, `growth_<vid>`).
- **Caches maintenance / yield / growth server snapshots only.**
- **Writes cache only after successful online list reads** — never caches failed
  reads, offline fallback data, in-memory fallback lists, O-1 overlaid /
  optimistic rows, pending payload JSON, or auth/session/tokens/keys/secrets.
- **Corrupt cache fails soft** — decode failures return an empty fallback rather
  than crashing or blocking app startup.
- **Sign-out / account change clears the cache** via the existing
  `domainCache.clearAll()` path used at sign-out; owner mismatch isolates cached
  rows so vineyard A cannot show vineyard B's cached records.

### Hydration / merge flow

`loadVineyardData()` for each of the three entities:

1. **Choose a baseline** — server success result, else current in-memory list,
   else cached server snapshot, else empty list.
2. **Write cache only from the server-success branch**, before overlay (so the
   cache always represents the last known-good server snapshot, never overlaid
   rows).
3. **Take one pending-write snapshot** (`pendingWrites.list()` once per load).
4. **Apply the overlay exactly once** after baselines are chosen.
5. **Update UI state** with the overlaid lists.

Merge rules: baseline wins a duplicate CREATE id; CREATE dedupes by id; the
latest UPDATE wins where a baseline / created row exists; DELETE hides the row;
`SYNCED` markers are ignored; `BLOCKED` markers remain visible when they
represent user-visible local state; DELETE-only markers never hide cross-vineyard
rows. The overlay does not mutate cache contents, and cache contents stay
independent of the pending outbox.

### UX behaviour

- **Maintenance / Yield / Growth screens render the shared overlaid state
  lists** (`state.maintenanceLogs` / `yieldRecords` / `growthRecords`), so cached
  rows, pending CREATE rows, and UPDATE overlays appear after an offline restart,
  and pending DELETE hides cached rows.
- **Block Detail growth summary uses the same overlaid growth list** and
  tolerates pending optimistic creates / edits / deletes.
- The **existing saved/cached field-data indication is reused** via the cached
  field-data state / Sync Status; **no heavy new UI was added**.
- **Inline cached banners on these screens and per-row pending badges remain
  parked.**
- **Sync Status remains the source of truth** for pending / blocked marker
  details; **copy diagnostics stay payload-free and secret-free**.

### Safety / security

- **No cached data is used for permission decisions** — **server RLS remains
  authoritative on replay**.
- **No markers are cleared or marked synced by hydration**, and **no attempt
  counts are incremented**.
- **No signed photo URLs are cached**; **no storage upload/delete behaviour is
  changed**.
- **Existing replay ordering is unchanged** — the overlay is display-only and
  runs after baseline selection without touching the replay pipelines.

### Boundaries / parked items

Explicitly **out of scope** for Stage O (unchanged):

- **trips cache, spray cache, fuel cache, work-task child-line cache**,
- **photo offline queues** and **growth / maintenance photo offline handling**,
- **the damage feature build and damage offline queue**,
- **iOS changes**, **schema / RLS / RPC changes**, and **broad cache UX
  changes**.

Parked future enhancements:

- **per-entity cached timestamps** (O-2 reuses the shared field-data timestamp),
- **inline cached-data banner on Maintenance / Yield / Growth screens**,
- **per-row pending sync badges**,
- **broader snapshot cache expansion** to the remaining entity families.

### Parity checkpoint

- **Android now supports offline restart browsing for maintenance / yield /
  growth** using cached server snapshots plus pending-write overlays.
- This **materially closes the read-side parity gap** against iOS's local-first
  model for these entities.
- **Android still does not have broad iOS-style local-first persistence for every
  entity.**
- **Remaining read-side gaps are trips / spray / fuel / work-task child rows /
  photos / damage.**

### Build / check reference

- **O-0 — design only**, no build required.
- **O-1 and O-2 implementation `runChecks` passed**; the O-1 and O-2 QA passes
  `runChecks` passed.
- **O-4 `runChecks` passed** (QA-only, no code changed).
- **O-3 and O-5 are documentation / QA only** — no app code changed, so no build
  was required for those passes.

### Parked next steps

- **Server snapshot cache + overlay for the remaining entity families** (trips,
  spray, fuel, work-task child rows).
- **Inline cached-data banner and per-row pending badges** on the cached screens.
- **Per-entity cached timestamps.**
- **Photo / read-cache parity** for photo-bearing entities and **the damage
  feature build** before any damage offline work.

---

## Stage P-0 — Remaining read-cache expansion audit/design (design-complete)

Audit/design-only checkpoint for extending the Stage O offline-restart read-cache
(server snapshot cache + pending-write overlay) to the remaining existing Android
entity families. **No product code changed; no iOS, schema/RLS/RPC, write
queue/replay, cache implementation, photo offline queue, or damage-feature
changes.**

### Stage status

**P-0 is CLOSED (design only).** No implementation; this was the design
checkpoint before P-1. P-1 through P-6 are now complete — see the
"Stage P — Read-cache expansion (closure)" section below.

### Current remaining read-cache state (after Stage O)

- **Maintenance / yield / growth** now have a **server snapshot cache + pending-write
  overlay** (Stage O) and survive a cold offline restart.
- **Active trip** already has its **own dedicated snapshot** store and is handled
  separately from historical trips.
- **Historical trips, spray records, fuel logs, work tasks, work-task labour
  lines, work-task machine lines, and reference lists** remain **blank after a
  cold offline restart** unless still held in memory — they are live-server-read
  only on the read side.

### Complexity classification

- **Fuel logs — lowest-risk next slice.** Single entity, self-contained
  CREATE/UPDATE payloads, id-only DELETE, no child rows, no photo/storage
  dependency, complete C/U/D queue already in place, no reference-list dependency
  for basic rendering.
- **Spray records — safe but heavier.** Nested tanks plus spray/equipment display
  names raise reconstruction and denormalisation complexity.
- **Work-task header — safe**, but child rows add complexity.
- **Work-task labour / machine lines — medium-risk** due to parent/child
  dependencies and DB-generated totals.
- **Historical trips — snapshot-only candidate**; **no pending-write overlay**,
  because trip markers are scalar deltas and the active trip is handled
  separately.
- **Photos and damage remain parked.**

### Recommended next slice

**P-1 should be the Fuel logs cache + pending-write overlay**, because fuel is:

- a single entity,
- backed by fully self-contained CREATE/UPDATE payloads,
- id-only on DELETE,
- free of child rows,
- free of photo/storage dependencies,
- already covered by a complete C/U/D offline queue, and
- not dependent on a reference list for basic rendering.

This mirrors the Stage O maintenance/yield/growth pattern exactly, so it carries
the least new risk.

### Proposed P-stage roadmap

- **P-1** — Fuel logs cache + overlay.
- **P-2** — Spray records cache + overlay.
- **P-3** — Work-task header + labour + machine caches/overlays with a parent
  gate.
- **P-4** — Historical-trip snapshot cache for finished-trip browsing (snapshot
  only, no outbox overlay).
- **P-5** — QA/UX polish.
- **P-6** — Documentation closure + parity checkpoint.

### Risks / parked items

- **child-line orphaning** risk (work-task labour/machine lines without their
  parent),
- **work-task total fields generated by the DB** (must not be invented locally),
- **trip active-snapshot vs historical-snapshot separation** must be preserved,
- **spray nested-tank reconstruction and export/report side effects**,
- **stale reference names** (denormalised display names drifting),
- **cache size** growth as more families are cached,
- **role / permission drift** while offline,
- **signed / photo URL risks** (never cache signed URLs),
- **damage feature absent** on Android — out of scope until a feature build.

### Boundaries

Explicitly out of scope for the P stages: **the damage feature, photo offline
queues, iOS changes, schema/RLS/RPC changes, new business features, and broad UI
redesign.**

### Build / check reference

- **P-0 — design only**, no build required; no code changed.

---

## Stage P — Read-cache expansion (closure + parity checkpoint)

Extends the Stage O offline-restart read-cache (server snapshot cache +
pending-write overlay) to the remaining major existing Android field-data
surfaces. **No iOS, schema/RLS/RPC, write queue/replay, photo offline queue, or
damage-feature changes.**

### Stage status

The remaining read-cache expansion stage is **CLOSED** for fuel logs, spray
records, work-task headers, work-task labour lines, work-task machine lines, and
historical trips. Closed substages:

- **P-0** — remaining read-cache expansion audit/design (design only).
- **P-1** — fuel logs cache + pending-write overlay.
- **P-2** — spray records cache + pending-write overlay.
- **P-3** — work-task header + labour/machine cache + parent-gated overlay.
- **P-4** — historical trip snapshot cache only.
- **P-5** — QA/UX polish.
- **P-6** — documentation closure (this note).

### Files changed

- `data/DomainCacheStore.kt` — vineyard-scoped fuel/spray/trip snapshot keys and
  timestamps; vineyard-scoped work-task header key; task-scoped labour/machine
  line keys; JSON-backed SharedPreferences, owner-gated, safe on corrupt JSON.
- `data/DomainCacheRepository.kt` — save/load/last-synced wrappers for each new
  cached family, owner-gated, kept in the existing `clearAll()` path.
- `data/PendingWriteOverlay.kt` — `overlayFuel`, `overlaySpray`, and the
  work-task header/labour/machine overlay functions (P-4 trips have no overlay).
- `ui/AppViewModel.kt` — write-through, fallback baseline selection, single
  overlay application per family, cached-field metadata wiring, task-scoped line
  cache in `loadTaskLines(taskId)`, and snapshot-only trip cache.
- `docs/android-offline-field-reliability-status.md` — this closure note.

### P-1 — fuel logs

- **Vineyard-scoped server snapshot cache**, owner/user gated.
- **Write-through only after a successful online fuel-log list read.**
- **Fallback chain:** server success → current in-memory → cached snapshot → empty.
- **`PendingWriteOverlay.overlayFuel`** applies unresolved CREATE/UPDATE/DELETE:
  CREATE reconstructs a `TractorFuelLog` and dedupes by id (baseline wins),
  UPDATE overlays form-owned fields only onto an existing same-id row,
  UPDATE-only with no baseline does not invent a row, DELETE hides the same-id
  row, CREATE+DELETE nets to no row, latest UPDATE wins.
- **id-only UPDATE/DELETE markers** apply only to rows already in the
  selected-vineyard baseline/created set; CREATE overlays filter by payload
  vineyard id. No cross-vineyard surfacing or hiding.
- **No fuel-purchase / reference-list cache.** No permission/replay mutation.

### P-2 — spray records

- **Vineyard-scoped server snapshot cache**, owner/user gated, write-through only
  on successful reads, same fallback chain as P-1.
- **Nested `SprayTank` preserved** on CREATE; **UPDATE replaces/overlays nested
  tanks from the payload** onto an existing same-id row.
- **`PendingWriteOverlay.overlaySpray`** follows the same merge rules as fuel
  (dedupe by id, baseline wins, no row invention on UPDATE/DELETE-only,
  CREATE+DELETE nets to no row, latest UPDATE wins).
- **No trip-coupled spray row invention**, **no spray template/import-specific
  cache**, **no cost/export/report logic change**. No permission/replay mutation.

### P-3 — work tasks

- **Vineyard-scoped work-task header cache.**
- **Task-scoped labour/machine line caches** because lines are read per task via
  `loadTaskLines(taskId)` — a vineyard-wide line cache would be misleading/
  incomplete; task-scoped keys never mix lines across tasks.
- **Header CREATE/UPDATE/DELETE overlay** plus **labour/machine
  CREATE/UPDATE/DELETE overlays.**
- **Parent gate:** child lines are computed against the **final visible header
  set** (after header overlay/delete); a child shows only if its `workTaskId`
  is in that set. **A deleted/hidden parent hides all of its child lines.**
  **No orphan child rows.**
- **DB-generated labour totals are not invented** as server-confirmed values;
  pending child rows use safe defaults / model-derived display values, and
  UPDATE preserves baseline server/audit/generated fields. **Machine cost
  handling follows existing app semantics.** No permission/replay mutation.

### P-4 — historical trips

- **Vineyard-scoped historical trip snapshot cache.**
- **Snapshot-only** — **no pending-write overlay** for trip markers.
- **No historical trip row reconstruction** from scalar trip markers
  (TRIP_START/METADATA/GPS/ROW/TANK/END/DELETE).
- **`ActiveTripStore` remains authoritative** for active-trip restoration; the
  trip cache is written from the **raw server trip list before** any
  restored/provisional active-trip row can be merged in.
- **TRIP_DELETE limitation (documented):** a cached historical trip with a
  pending delete may remain visible offline until reconnect/replay refreshes the
  server snapshot.

### Hydration / merge flow

For overlay families (fuel, spray, work-task header + lines):

1. Choose the **baseline**: server success, else current in-memory fallback,
   else cached server snapshot, else empty list.
2. **Write cache only from server success, before overlay.**
3. Take a **pending-write snapshot**.
4. **Apply the overlay once** where designed.
5. **Update UI state** with the overlaid lists.

For trips: same server / in-memory / cache / empty baseline, **no overlay**,
and active-trip restoration remains separate.

### UX behaviour

- **Existing saved/cached field-data banner is reused** — no heavy new UI.
- **Cached-field state** (`isUsingCachedFieldData`,
  `cachedFieldDataLastSyncedAt`) now includes fuel, spray, work-task header,
  labour/machine line, and trip cache fallbacks in its chain.
- **Sync Status remains the source of truth** for unresolved pending markers.
- **Inline cached banners and per-row pending badges remain parked.**

### Safety / security

- **No cached data is used for permission decisions** — server RLS remains
  authoritative on replay.
- **No pending markers are cleared or marked synced by hydration**, **no attempt
  counts increment**, and **no replay/network is triggered** by fallback/overlay.
- **No signed photo URLs** and **no auth/session/tokens/keys/secrets** are cached.
- **Replay ordering is unchanged.**

### Boundaries / parked items

Still explicitly out of scope:

- photo offline queues; signed/photo URL caching; growth/maintenance photo
  offline handling,
- damage feature build and damage offline queue (Android has no damage feature
  yet),
- GPS / row / tank detail-stream caching for trips,
- per-entity cached timestamp UI; inline cached banners; per-row pending badges,
- iOS changes; schema/RLS/RPC changes.

### Parity checkpoint

- Android now supports **offline restart browsing for the major existing
  field-data surfaces**: maintenance, yield, growth, fuel, spray, work tasks
  (including labour/machine lines), and historical trips.
- **Active trip already persists separately** through `ActiveTripStore`.
- This **materially closes the read-side local-first parity gap** for existing
  Android surfaces.
- **Remaining major gaps are photos and damage**, with damage still parked
  because Android has no damage feature yet.
- Android still **does not claim full broad iOS-style local-first persistence**
  for every possible dataset/reference list.

### Build / check reference

- **`runChecks` passed** for `android-vinetrack` on P-1, P-2, P-3, P-4, and P-5.
- **P-0 and P-6 are documentation/design-only**; no build required for P-6
  (no code changed).

---

## Parked future work

- offline pin delete replay (Stage 9C — deferred)
- paddock reassignment offline edits
- row/side/snap offline edits
- field-scoped merge conflict resolution
- pin delete offline replay (Stage 9C — deferred)
- multiple photos per pin
- growth-record photo retry
- trip create/end replay
- tank/fill replay
- trip-coupled spray-create offline queueing (parked — needs trip-create
  dependency gates + live GPS handling)
- spray-record read-cache / offline app-restart viewing (parked)
- trip-side work-task link offline queueing (parked — needs trip-create
  dependency gates)
- work-task read-cache / offline app-restart viewing (parked)
- maintenance invoice/photo upload offline retry (parked — needs an Android
  maintenance photo write path)
- maintenance read-cache / offline app-restart viewing (parked)
- yield estimation session offline queueing (parked — needs an Android
  estimation session write path)
- yield read-cache / offline app-restart viewing (parked)
- growth/damage queueing
- caching/hydration of trips, sprays, tasks, fuel, growth/maintenance/yield,
  operators, members/roles, equipment, presets, chemicals, GPS paths, row
  coverage, tank/fill
- general multi-entity SyncManager
- retry/backoff scheduling
- conflict reconciliation
- JSONB merge semantics

---

## Build / check reference

`runChecks` passed for `android-vinetrack` on each closed implementation and
QA/closure slice (4A-i through 4A-iv, plus Stage 6A implementation/QA, Stage 6B
implementation/QA, Stage 7B implementation/QA, and Stage 7C implementation/QA).
Stages 5 and 7A were audit-only passes with no code change. `runChecks` passed
for `android-vinetrack` on Stage 8 implementation and QA. This note is
**documentation only** — no app code changed, so no build was necessary for
this update.
