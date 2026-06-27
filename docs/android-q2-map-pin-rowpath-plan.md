# Android Stage Q-2 — Map / Pin / Row-Path Parity Audit + Implementation Plan

Audit/design artifact for **Stage Q-2** of the Android (`android-vinetrack`) → iOS
(`ios/VineTrackV2`) parity roadmap. Sources of truth: `docs/android-ios-parity-roadmap-status.md`
(Stage Q-0), `docs/android-map-pins-parity-status.md` (earlier map/pins slices),
`docs/android-q1-ui-polish-plan.md` (Q-1 closure).

> **STATUS: Q-2a DESIGN-COMPLETE.** This pass is **audit/design only** — no Android
> code, no iOS code, no schema/RLS/RPC, no build. It is the planning artifact for the
> Q-2b…Q-2f implementation sub-stages.

> **Constraints (hard):** No iOS changes. No Supabase schema/RLS/RPC changes. No changes
> to offline write queues, read-cache implementation, photo queues, trip detail streams,
> damage feature, or reports/export logic. iOS remains the benchmark; Android-ahead
> behaviour (3D toggle, itemised sync) must not regress.

---

## Sub-stage closure state

| Sub-stage | Scope | Status |
|---|---|---|
| Q-2a | Map / pin / row-path parity audit + this plan | **DESIGN-COMPLETE** (this pass) |
| Q-2b | Pin popup/detail row-path + offline label polish (display-only) | **CLOSED** (implemented + QA + build-passed) |
| Q-2c | Row/path snapping display + data-contract parity verification | **CLOSED** (verified + comment/wording polish + build-passed) |
| Q-2d | Duplicate-warning along-row-distance parity confirmation/polish | **CLOSED** (verified + side-context wording polish + build-passed) |
| Q-2e | Pin-photo display parity audit (audit-only; tiny label fix max) | **CLOSED** (audit + one calm offline-photo label + build-passed) |
| Q-2f | Quick-pin button workflow parity (quick create, duplicate sheet, auto-photo, success card) | **CLOSED** (implemented + QA + build-passed) |

---

## 1. Files inspected

**Android (audit, read-only):**
- `ui/screens/VineyardMapScreen.kt` — full map surface (Google Maps, polygons, row lines, pins, labels, 3D toggle, overlay controls).
- `ui/screens/PinsScreen.kt` — pin list/detail/create-edit, duplicate-warning UI, photo flow.
- `data/RowAttachment.kt` — row snapping geometry (explicit + synthetic rows, projection, along-row distance).
- `data/PinDuplicateChecker.kt` — along-row + raw-distance duplicate detection.
- `data/model/Models.kt` (Pin model + `rowAttachmentLabel`/`rowAttachmentDetail`).
- `data/PinRepository.kt`, `PinEditSync.kt`, `PinCompletionSync.kt`, `PinDeleteSync.kt`, `PinPhotoSync.kt`, `PinPhotoRepository.kt`, `PendingPhotoRepository.kt` (field/contract grounding only).
- `ui/AppViewModel.kt` `pinSyncState(...)` / `PinSyncState` (sync-state derivation).

**iOS (benchmark, read-only):**
- `LegacyImported/Models/VinePin.swift` (pin model + row/side/along-row fields).
- `LegacyImported/Views/Pins/PinsView.swift` (pin list/detail row-path wording).
- `LegacyImported/Services/TripTrackingService.swift` + `PinDuplicateChecker` (along-row-first, raw fallback).
- `LegacyImported/Views/Paddocks/EditPaddockSheet.swift` (row-attached pin field references).

---

## 2. Android map inventory (`VineyardMapScreen.kt`)

| Aspect | Android today | Notes |
|---|---|---|
| Map engine | Google Maps Compose (`GoogleMap`) | Cached Google tiles offline; no offline vector fallback. |
| Visual mode | Hybrid default; Satellite/Standard/Terrain via Settings (`MapDefaults`/`MapPrefsStore`) | Matches/exceeds iOS default. |
| 3D toggle | Top-down / 3D Overview (`OVERVIEW_TILT = 50f`) | **Android-ahead** — iOS has no equivalent. Must not regress. |
| Block polygons | Amber (`0xFFFF9500`) stroke + 16% fill, drawn for `hasGeometry` blocks | iOS-style amber already adopted (Slice 3). |
| Block labels | Always-visible centroid chips via `MarkerComposable`, zoom-gated `≥13.5f`, optional `· Nr` row count | iOS parity already shipped. |
| Row lines | White 55%-alpha polylines from `row.startPoint`→`endPoint`, toggleable | Present. |
| Pins | Hue-coded markers (yellow=needs attention, orange=pending create/photo, green=completed, red=open), faded when local-only, callout = title + notes + sync label | Sync-state coloring is **Android-ahead**. |
| Overlay controls | Pins / Rows / Labels session toggles (no writes) | Present. |
| Empty state | "Nothing to map yet" when no geometry/pins/vineyard centre | Present, calm wording. |
| Missing-key note | Surfaces when `BuildConfig.MAPS_API_KEY` blank | Present. |
| Pin selection popup | Google **default marker callout** (title + snippet) only | **Gap** — no rich row/path/side/photo popup card (see §7). |
| Block-detail entry from map | None (map markers don't deep-link to block detail) | Minor gap; parked (not in Q-2 scope per roadmap). |
| Offline/cached map behaviour | Renders cached launch data; relies on Google tile cache | Offline vector map parked (larger work). |

---

## 3. Android pin workflow inventory (`PinsScreen.kt` + `data/*`)

| Aspect | Android today |
|---|---|
| Create/edit/delete | Create via launcher (Repairs/Growth); edit text/category/mode + side/row/snap via `PinEditSync`; complete via `PinCompletionSync`; delete via `PinDeleteSync` (soft-delete, idempotent). |
| Category handling | `category` / `buttonName` / `mode` with `displayTitle` fallback chain. |
| Photo flow | One photo per pin; offline capture queued via `PendingPhotoRepository` + `PinPhotoSync`; retry surfaced in Sync Status. |
| Snapping | `RowAttachment.resolve(...)` — explicit mapped rows first, synthetic row grid fallback (from `rowDirection`/`rowWidth`); projects fix onto row centreline; records `pinRowNumber`, `pinSide`, `alongRowDistanceM`. Does **not** speculate `drivingRowNumber` for launcher pins (parity with iOS `PinAttachmentResolver.manual`). |
| Duplicate warning | `PinDuplicateChecker.nearbyAlongRow` (preferred) then `nearbyRawDistance` (legacy fallback). |
| Row/path/side fields | `rowNumber` (manual), `drivingRowNumber`, `pinRowNumber`, `pinSide` (+ legacy `side`), `alongRowDistanceM`. |
| Popup/detail display | List card + detail/edit sheet show `rowAttachmentLabel` ("Attached to row 19.5 · left") + optional `rowAttachmentDetail` ("Block row 15"); status chips (Pending sync / Photo waiting / Needs attention). |
| Pending/offline state | `PinSyncState` derived from `PendingWriteRepository` (PIN/CREATE) + `PendingPhotoRepository`; display-only, no new model fields. |
| Pin-photo retry display | Status chip + conservative detail banner; retry actions live only in Sync Status. |

---

## 4. iOS benchmark findings

- **Pin model (`VinePin.swift`):** `drivingRowNumber: Double?`, **`pinRowNumber: Int?`**, `pinSide: PinSide?`, `alongRowDistanceM: Double?`, plus legacy `rowNumber`/`side`. New code prefers `drivingRowNumber`/`pinRowNumber`.
- **Pin wording (`PinsView.swift`):** shows driving path row when present, side from `pinSide ?? side`, and block `pinRowNumber` as a secondary detail — **the exact pattern Android already mirrors** in `rowAttachmentLabel`/`rowAttachmentDetail`.
- **Duplicate detection (`TripTrackingService` + `PinDuplicateChecker`):** along-row check first (`nearbyPinAlongRow`, `alongRowDuplicateMetres`), raw-distance fallback (`nearbyPin`) second. iOS re-snaps each existing pin at check time; iOS raw fallback scopes by vineyard + radius only.
- **In-trip duplicate UX:** iOS surfaces "View existing / Create anyway" with distance + radius diagnostics (`diagDuplicateCheckResult`, `diagDuplicateRadiusMeters`).
- **Map:** iOS has an offline vector map (`OfflineVineyardMapView`) and pins PDF export; no 3D toggle.

---

## 5. Data-contract findings (Android vs iOS vs server)

| Field | Server (`pins`) | Android `Pin` | iOS `VinePin` | Verdict |
|---|---|---|---|---|
| id | `id` | `id: String` | `id` (UUID) | Match |
| client id | client-minted UUID | `id` minted client-side on create | same | Match |
| vineyard id | `vineyard_id` | `vineyardId` | yes | Match |
| block/paddock id | `paddock_id` | `paddockId: String?` | yes | Match |
| latitude/longitude | `latitude`/`longitude` | `Double?` | yes | Match |
| driving/path row | `driving_row_number` | `drivingRowNumber: Double?` | `Double?` | Match |
| snapped block row | `pin_row_number` | **`pinRowNumber: Double?`** | **`pinRowNumber: Int?`** | **Type nuance** — Android decodes Double (more tolerant), iOS Int. Snapped rows are integral, so equality + display agree; **no contract break**. Flag, don't change. |
| manual row | `row_number` | `rowNumber: Int?` | `rowNumber` | Match |
| side | `pin_side` (+ legacy `side`) | `pinSide` (+ `side`) | `pinSide`/`side` | Match |
| along-row distance | `along_row_distance_m` | `alongRowDistanceM: Double?` | `Double?` | Match |
| category/mode/title | `category`/`mode`/`title`/`button_name` | all present | yes | Match |
| completion | `is_completed`/`completed_at`/`completed_by` | present | yes | Match |
| notes | `notes` | present | yes | Match |
| photo path | `photo_path` | `photoPath` (single) | multi-photo on iOS | **Gap** — Android single, iOS multi (parked Q-4). |
| timestamps | `created_at`/`updated_at`/`client_updated_at`/`sync_version` | all decoded | yes | Match (Android preserves but does not yet send all on writes — noted, not in Q-2). |
| soft delete | `deleted_at` | `deletedAt` | yes | Match |

**Net:** no missing field and no contract break for row/path/side/duplicate. The single
contrast worth a one-line code comment is the `pinRowNumber` Int-vs-Double decode nuance.

---

## 6. Row/path snapping findings

- Android **does snap** pins to rows (`RowAttachment.resolve`), explicit rows first, synthetic grid fallback — geometry mirrors iOS `RowGuidance`.
- It **records** `pinRowNumber`, `pinSide`, `alongRowDistanceM`; it intentionally does **not** invent `drivingRowNumber` for launcher pins (matches iOS manual-attachment behaviour).
- Snapping is **deterministic** (pure projection math), so the stored `alongRowDistanceM` is a stable key for duplicate detection.
- Snapping survives offline create/replay: the resolved attachment is persisted on the pin record and queued like any other field — replay does not re-snap, so offline and online produce the same stored attachment.
- **Display wording matches iOS** ("Attached to row …", side, secondary block row) — already shipped in Slice 1 / Q-1.
- **Gap (minor):** the pin **drop confirmation popup** does not yet echo the row/path it attached to (requirement in the prompt). The data exists; this is a display-only addition.

---

## 7. Duplicate-warning findings

- **Android already uses along-row distance** as the primary signal (`nearbyAlongRow`, `ALONG_ROW_DUPLICATE_METRES = 2.5`), scoped to same block + same snapped row + same side (when known) + same mode (when known) + open pins only.
- Raw GPS distance is used **only** for legacy pins lacking row attachment (`nearbyRawDistance`), with a row-spacing-derived radius (`duplicateRadius`: half row width, clamped 2.5–6.0 m, else 3.0 m) — mirrors iOS `PinDuplicateChecker.duplicateRadius`.
- Android's raw fallback is **stricter** than iOS (adds block/mode/side/manual-row scoping) to avoid cross-row false positives — a safe, intentional Android-ahead difference; **keep**.
- **Conclusion:** the prompt's requirement ("duplicate warnings based on distance along the snapped row line, not raw GPS distance across rows") is **already satisfied**. Q-2d is therefore a **confirmation + small wording polish** stage, not an algorithm rewrite.

---

## 8. Pin popup / detail findings

| Element | List card | Detail/edit sheet | Map marker callout |
|---|---|---|---|
| Category / title | yes | yes | yes (title) |
| Notes / status | yes | yes | yes (snippet) |
| Block / paddock | resolved name | yes | no |
| Attached row/path | `rowAttachmentLabel` | yes | **no** |
| Exact row/path number | yes (fractional preserved) | yes | **no** |
| Side | yes | yes | **no** |
| Photo presence | badge | thumbnail | no |
| Offline/pending status | chips | banner | hue + label |

**Gaps:** (1) the **map marker callout** is the Google default (title + notes + sync label)
and omits the attached row/path/side that the list/detail already show; (2) the **pin drop
confirmation popup** does not echo the attached row/path. Both are display-only using
existing fields.

---

## 9. Photo parity findings (audit-only — keep parked to Q-4)

| Aspect | Android | iOS | Verdict |
|---|---|---|---|
| Photos per pin | 1 | multiple | **Gap** (parked Q-4). |
| Upload/retry state | `PendingPhotoRepository` + Sync Status retry | dirty-tracking | Android-ahead (itemised). |
| Offline display | placeholder/label only; no signed-URL caching | similar | By-design limitation. |
| Signed URL / local path | local path until uploaded; deterministic `{vineyardId}/pins/{clientPinId}/photo.jpg` | signed URLs | Match for single photo. |
| Delete | manager-gated server delete | gated | Match. |

**Recommendation:** keep multi-photo parked to **Q-4**. The only candidate inside Q-2 is a
**tiny display-only label** if a blank/ambiguous photo state is found in Q-2e — not a queue
or multi-photo change.

---

## 10. Risk classification

**Low-risk (UI label/display, existing fields):**
- Pin drop popup echoes attached row/path/side (data already resolved).
- Map marker callout adds row/path/side line (reuse `rowAttachmentLabel`).
- Offline pin-label resilience polish (blank → calm fallback), consistent with Q-1d.
- Duplicate-warning wording confirmation/polish.

**Medium-risk (display/data-contract verification):**
- `pinRowNumber` Int-vs-Double decode nuance — add a clarifying comment + verify equality/format paths; no behaviour change.
- Snapping display verification across explicit vs synthetic rows.

**High-risk (park / do not touch in Q-2):**
- Duplicate-detection **algorithm** changes (already at parity — confirmation only).
- Snapping **geometry** changes / row-row snapping rewrites.
- Pin write/replay payload changes (sending `sync_version`/`client_updated_at`).

**Parked to Q-4 (photos):** multi-photo per pin, offline photo viewing/signed-URL caching.

**Parked to schema/server:** none required — every Q-2 item reuses existing fields/RPCs. If
any proposed fix appears to need schema, **park it**.

---

## 11. Recommended Q-2 sub-stage breakdown + acceptance criteria

### Q-2b — Pin popup/detail row-path + offline label polish (display-only) — **CLOSED**
- **Files likely touched:** `ui/screens/PinsScreen.kt` (pin drop confirmation + detail), `ui/screens/VineyardMapScreen.kt` (marker callout snippet).
- **Change:** pin drop confirmation echoes "Attached to row … · side"; map marker callout appends the same `rowAttachmentLabel` line; calm offline fallback where a label could be blank.
- **Must not change:** snapping geometry, duplicate logic, write/replay, photo queue, 3D toggle, polygon/label rendering, schema.
- **QA:** dropping a pin on a mapped row shows the attached-row line; tapping a row-attached map marker shows row/path/side; non-attached pins show no broken label; offline shows calm fallback, never blank/raw id.
- **Build:** `runChecks` Android.
- **Risk:** **Low.**

#### Q-2b closure note (implemented + QA + build-passed)
**Files changed (2):**
- `ui/screens/VineyardMapScreen.kt` — pin marker callout now prepends `pin.rowAttachmentLabel` ("Attached to row 19.5 · left") on its own line above the existing notes + sync-state line. Reuses the existing model field; no new state, no geometry, no marker-mutation. Non-attached pins (`rowAttachmentLabel == null`) show no row line.
- `ui/screens/PinsScreen.kt` — `PinEditSheetHost` now surfaces a post-drop confirmation snackbar echoing the attached row/side ("Pin saved — attached to row 19.5 · left side") for newly-dropped launcher pins that snapped to a mapped row. The row attachment is resolved once up front (moved above `doCreate`) and reused by both the existing duplicate check and the confirmation, so there is **no extra snap call and no duplicate-logic change**. A `SnackbarHost` was added to both the Observations (`PinsScreen`) and launcher (`PinCategoryLauncherScreen`) Scaffolds; confirmation fires only on `ok == true` and only when an attachment exists — un-snapped pins show no misleading row line.

**Intentionally unchanged (verified):**
- `RowAttachment` snapping geometry — untouched.
- `PinDuplicateChecker` along-row + raw-distance algorithm, thresholds, radii, scoping — untouched.
- Pin write/replay payloads, marker mutation, attempt counts, photo queue — untouched.
- Offline/pending wording (`Pending sync`, `Photo waiting to upload`, `Needs attention`) — **deliberately kept** consistent with the Sync Status screen rather than diverging to alternate copy; `PinSyncState.primaryLabel` already calm/clear.
- Pin list card + detail/edit sheet already render `rowAttachmentLabel`/`rowAttachmentDetail` — verified consistent; no wording change needed.
- iOS, schema/RLS/RPC — untouched.

**Safety:** confirmation/callout are display-only; rendering the map or showing the snackbar triggers no sync/replay, no network call, no marker mutation, and exposes no payload JSON/secrets.

**Build:** `runChecks` Android — **passed.**

**Parked Q-2 follow-ups:** Q-2c (pinRowNumber Int/Double decode comment + snapping display verification), Q-2d (duplicate-warning wording confirmation), Q-2e (single-photo display audit), Q-2f (QA/regression + docs closure). Multi-photo per pin and offline vector map remain parked (Q-4 / larger work).

### Q-2c — Row/path snapping display + data-contract parity verification — **CLOSED**
- **Files likely touched:** `data/model/Models.kt` (clarifying comment only), possibly `PinsScreen.kt` display.
- **Change:** document the `pinRowNumber` Int(iOS)/Double(Android) decode nuance; verify explicit-vs-synthetic snapping renders identically; no behaviour change.
- **Must not change:** geometry math, stored values, write payloads, schema.
- **QA:** explicit-row and synthetic-row pins both display correct row/side/along-row; fractional driving rows preserved; whole rows trimmed.
- **Build:** `runChecks` Android (only if code touched; comment-only still build-checked).
- **Risk:** **Low–medium** (verification-led).

#### Q-2c closure note (verified + comment/wording polish + build-passed)
**Files changed (1):**
- `data/model/Models.kt` — two small, display-only edits:
  1. **Protective comment** rewritten near the row-attachment fields. It now states explicitly that `drivingRowNumber` is the fractional path (iOS also Double?), and that `pinRowNumber` is modelled as **`Int?` on iOS (`VinePin.pinRowNumber`)** but **intentionally `Double?` on Android** so exact decimal path/row values (e.g. 19.5) are never truncated — with a “do NOT narrow this to Int” directive. (The previous comment conflated driving/pin row and did not name the iOS Int? contrast.)
  2. **Wording consistency fix** in `rowAttachmentLabel`: side now renders as the friendlier “· left side” / “· right side”, matching the Q-2b post-drop confirmation snackbar (which already appended “ side”). Previously the shared label said “· left” while the snackbar said “· left side” — now list card, detail/edit sheet, map callout, and snackbar are all consistent.

**Data-contract verification (no change):**
- Android pin field `@SerialName`s match the server `pins` contract exactly: `pin_row_number`, `pin_side`, `along_row_distance_m`, `driving_row_number`, `row_number`, plus ids/timestamps/soft-delete. Confirmed in both `Pin` (`Models.kt`) and `PinRepository.PinInput`.
- `pinRowNumber: Double?` is intentional/tolerant; `pinSide` maps cleanly to `left`/`right` (lowercased, validated); `alongRowDistanceM: Double?` preserved.
- Client id minted on create (`PinRepository.createPin`); `client_updated_at`/`sync_version` decoded and preserved (narrow EditPatch never clobbers row/snap columns).

**Explicit vs synthetic attachment display (verified):** both `RowAttachment.explicitRowAttachment` and `syntheticRowAttachment` populate the same `Attachment(pinRowNumber, pinSide, alongRowDistanceM, snappedLat/Lng)` shape, persisted to the same `Pin` columns. All surfaces — snackbar, map callout, list card, detail sheet — render via the single `rowAttachmentLabel`/`rowAttachmentDetail` helpers, so explicit and synthetic snaps display identically. No internal terms (geometry/polyline/projection/alongRowDistanceM) surface in UI.

**Payload safety (verified):** `PinInput` carries `pin_row_number`/`pin_side`/`along_row_distance_m` on create; the descriptive `EditPatch`, `CompletionPatch`, `PhotoPatch`, and soft-delete RPC are all deliberately narrow and never touch row/snap columns, so edits/completion/photo/delete and offline replay all preserve the attachment.

**Row/path formatting (verified):** `formatRowNumber` trims whole rows (`19`) and preserves fractional rows (`19.5`) with no trailing `.0`; side renders as friendly `left side`/`right side`; no raw enum/internal value appears.

**Duplicate-warning compatibility (verified, unchanged):** `PinDuplicateChecker.nearbyAlongRow` still consumes `alongRowDistanceM` as the primary signal (scoped block + snapped row + side + mode, open pins only); `nearbyRawDistance` remains the legacy fallback for pins lacking row attachment. Thresholds/radii/scoping untouched. The friendlier `· left side` label still reads correctly inside the warning surfaces.

**Intentionally unchanged:** `RowAttachment` geometry, `PinDuplicateChecker` algorithm, pin write/replay payloads, photo queue, marker mutation, 3D toggle, iOS, schema/RLS/RPC.

**Build:** `runChecks` Android — **passed.**

### Q-2d — Duplicate-warning along-row parity confirmation/polish — **CLOSED**
- **Files likely touched:** `ui/screens/PinsScreen.kt` (warning wording only), possibly a comment in `PinDuplicateChecker.kt`.
- **Change:** confirm along-row-first / raw-fallback behaviour; polish the warning copy to make clear it is "another open pin ~Xm along this row" vs legacy "nearby pin in this block". **No algorithm change.**
- **Must not change:** thresholds, radii, scoping, match selection, replay.
- **QA:** two same-row pins within 2.5 m → along-row warning with along-row wording; legacy pin within radius → raw-distance wording; cross-row pins do not warn.
- **Build:** `runChecks` Android.
- **Risk:** **Low** (wording) / confirmation.

#### Q-2d closure note (verified + side-context wording polish + build-passed)
**Algorithm verification (no change):** `PinDuplicateChecker` confirmed untouched and at iOS parity — `nearbyAlongRow` (along-row distance primary, `ALONG_ROW_DUPLICATE_METRES = 2.5`, scoped to block + snapped row + side + mode, open pins only) runs first; `nearbyRawDistance` (row-spacing-derived radius, clamped 2.5–6.0 m, else 3.0 m) is the legacy fallback only for pins lacking row attachment. Thresholds, radii, block/mode/side/manual-row scoping, match selection, and replay are all unchanged. No algorithm bug found.

**Files changed (1):**
- `ui/screens/PinsScreen.kt` — duplicate-warning dialog wording polish only:
  1. The along-row warning now reads “is already **on row 19.5 · left side**, about X.X m away”, adding **side context** when the snapped attachment has a known side. Side is derived from the already-resolved `attachment.pinSide` (no new persisted field, no second snap, no extra resolve). It uses the same friendly “row 19.5 · left side” style as the Q-2b snackbar and the shared `rowAttachmentLabel` (list/detail/map callout), so all duplicate/attachment surfaces now read consistently. “attached to” → “on” also aligns with the iOS sheet’s “On {row}” phrasing.
  2. `PendingPinDuplicate` gained a display-only `side: String?` field (populated only for along-row matches; null for the legacy raw-distance fallback).
- The legacy raw-distance fallback copy is unchanged: “is already nearby in this block, about X.X m away” — correct for pins without row/path data; no false row implication.

**Benchmark (iOS `PinDuplicateWarningSheet.swift`):** headline “Possible duplicate pin nearby on Row X” + “On {attachmentLabel}” (row + side) + “There’s already a pin within X.X m of this location…”. Android keeps its compact AlertDialog form but now matches iOS in surfacing **row + side + distance** for along-row duplicates and distance-only for legacy pins. No internal terms (alongRowDistanceM / projection / snapped geometry / polyline / raw GPS) appear in any warning copy.

**Offline/pending behaviour (verified):** the warning fires the same for synced, locally-pending, and offline-created pins (it matches against `state.pins`, which includes optimistic local rows); row-attached pins use the along-row wording, legacy/no-attachment pins use the raw-distance wording. Rendering the dialog triggers no sync/replay, no network call, no marker mutation, no attempt increment, and exposes no payload JSON/secrets.

**Intentionally unchanged:** `PinDuplicateChecker` algorithm/thresholds/radii/scoping, `RowAttachment` geometry, pin write/replay payloads, photo queue, 3D toggle, map engine, iOS, schema/RLS/RPC.

**Build:** `runChecks` Android — **passed.**

**Recommended next slice:** Q-2e (single-photo display parity audit; tiny calm label only if a blank/ambiguous photo state is found).

### Q-2e — Pin-photo display parity audit (audit-only; tiny label fix max) — **CLOSED**
- **Files likely touched:** none expected; at most a one-line label in `PinsScreen.kt`.
- **Change:** audit single-photo states (pending/blocked/offline) for blank/ambiguous wording; tiny calm label only if found. Multi-photo stays parked to Q-4.
- **Must not change:** photo queue, retry, storage paths, signed URLs.
- **QA:** photo states read clearly online/offline; no false "multiple photos" implication.
- **Build:** `runChecks` Android only if code touched.
- **Risk:** **Low** (audit-led).

#### Q-2e closure note (audit + one calm offline-photo label + build-passed)
**Android pin-photo support (confirmed):** one photo per pin, stored at the shared
`vineyard-pin-photos/{vineyardId}/pins/{clientPinId}/photo.jpg` path (matches iOS + web portal).
Offline capture is queued via `PendingPhotoRepository` + `PinPhotoSync`; retry/cap actions live
only in Sync Status. Display surfaces and their states:
- **List card** (`PinsScreen.kt`) — a small photo glyph when `pin.hasPhoto`, plus a calm `Photo waiting` chip when `sync.pendingPhoto`. Clear, no false multi-photo implication.
- **Detail/edit sheet** — `PinPhotoSection` shows the synced image (signed URL) or the locally-picked image, Add/Replace/Remove, and an upload-progress overlay; `PinSyncBanner` carries calm `Photo waiting to upload` / `Needs attention` copy mirroring Sync Status.
- **Map callout** — sync hue (orange for `pendingCreate || pendingPhoto`) + the existing sync label; never implies a photo is present/viewable. Unchanged.
- **`PinSyncState`** — `pendingPhoto` / `blockedPhoto` derive purely from the existing pending-photo store; `primaryLabel` calm. Unchanged.

**iOS benchmark:** iOS pins support **multiple** photos with dirty-tracking sync. This is a real
feature gap, **kept parked to Q-4** — Q-2e did not pull it forward (no multi-photo, no queue,
no signed-URL cache, no storage/schema change).

**Files changed (1):**
- `ui/screens/PinsScreen.kt` — `PinPhotoSection` now distinguishes "still loading" from "could not load". Previously, for an existing pin with a `photoPath` while **offline** (or on a transient sign failure), `requestPinPhotoUrl` returned `null`, leaving `hasImage == true` with a `null` model → an **endless spinner with no explanation**. A display-only `photoUnavailable` flag (set when the signed-URL callback resolves with a blank/null URL) now shows a calm **"Photo unavailable offline"** note instead. No change to upload/retry, storage paths, signed-URL minting, or the photo queue.

**Map/list/detail consistency (verified):** list shows photo presence + pending chip; detail shows the photo state clearly (image / calm unavailable note / progress); map callout never falsely implies photo availability; pending wording matches Sync Status.

**Safety:** display-only. Rendering these surfaces triggers no photo upload/delete, no signed-URL
handling change, no photo-queue mutation, no attempt increment, and no replay/network beyond the
pre-existing on-demand signed-URL fetch. No secrets or raw storage paths exposed in UI.

**Build:** `runChecks` Android — **passed.**

**Recommended next slice:** Q-2f (full map/pin QA-regression + Q-2 docs closure).

### Q-2f — QA / regression + docs closure
- **Files likely touched:** this doc + `docs/android-map-pins-parity-status.md` + roadmap status.
- **Change:** record QA, mark Q-2 sub-stages closed, list parked items.
- **QA:** full map/pin regression — render, snapping, duplicate, popup, offline, 3D toggle, sync coloring; cache-purity + role-gating sanity.
- **Build:** `runChecks` Android (final).
- **Risk:** **Low.**

---

## 12. Boundaries held for Q-2a (and Q-2 overall)

Out of scope / parked: damage, broad photo offline queues + multi-photo (Q-4), trip detail
streams (Q-3), map/pin **snapping algorithm** rewrites, offline vector map, pins PDF export,
schema/RLS/RPC, iOS changes, reports/export, large map redesign, block-detail deep-link from
map markers.

---

## 13. Final recommendation

- **Recommended first implementation slice: Q-2b** (pin popup/detail row-path + offline label
  polish). Highest day-to-day clarity, reuses fields and the proven `rowAttachmentLabel`
  display contract, touches no geometry/duplicate/write/photo logic, zero schema risk —
  directly satisfies the prompt's "pin drop popup should display the row/path the pin was
  attached to" and "customer-facing wording should say a pin is on/attached to a row".
- **Then:** Q-2c → Q-2d → Q-2e → Q-2f, each its own build-checked slice.
- **Key audit conclusion:** the two behaviourally-sensitive requirements — **along-row (not
  raw-GPS) duplicate detection** and **recording exact path row + side** — are **already
  implemented and at iOS parity**. Q-2 is therefore predominantly **display/wording polish +
  verification**, not risky algorithm or contract work. The only true functional gaps
  (multi-photo per pin, offline vector map) stay parked (Q-4 / larger work).
- **Q-2a can be marked design-complete** — this note is the artifact; no code changed, no
  build required.

### After Q-2
Proceed to **Q-3 (trip detail-stream read parity)** per the Q-0 roadmap — it reuses the proven
P-4 `DomainCacheStore` snapshot-cache pattern and closes the most-noticed remaining offline
gap before the larger Damage build (Q-5/Q-6).

---

## Q-2f — Quick-pin button workflow parity (CLOSED)

**Goal:** bring the Android pin-button workflow up to the iOS quick-pin flow. Previously a
button tap on Android opened the full **New pin** form; iOS drops the pin immediately from the
button grid with a duplicate sheet (when needed), an optional auto-photo prompt, and a success
toast. Android now mirrors that flow while preserving its existing offline-safe create,
duplicate checking, row/path snapping, and photo-upload queue.

### iOS benchmark inspected
- `App/RepairsGrowthView.swift` — quick button grid, `handleRepairButton`/`createRepairPin`,
  duplicate check, success toast, auto-photo trigger (`store.settings.autoPhotoPrompt`).
- `App/AutoPhotoConfirmSheet.swift` — "Add a photo?" sheet with a 3 → 0s auto-skip countdown.
- `App/PinDropConfirmationSheet.swift` — full manual form (kept available as fallback).
- `LegacyImported/Models/AppSettings.swift`, `App/PreferencesHubView.swift` — `autoPhotoPrompt`.

### Files changed
- `android-vinetrack/.../ui/AppViewModel.kt`
  - `createPin(...)` gained an optional `onCreatedPin: (Pin) -> Unit` callback (fires with the
    created or queued optimistic pin) so the launcher's success card / auto-photo prompt have a
    concrete pin. `enqueuePinCreate(...)` now returns the optimistic `Pin`. **No change** to the
    pin payload, insert path, or offline outbox semantics.
  - Added `attachQuickPinPhoto(pin, uri, ...)` — reuses the **existing** pin-photo upload and
    pending-photo queue (`pendingPhotos.enqueue` / `replayPendingPinPhotos`). Offline (or on a
    failed upload) it retains the photo against the pin id; online it uploads immediately. No
    new photo queue, no signed-URL/storage changes.
- `android-vinetrack/.../ui/screens/PinsScreen.kt`
  - `PinCategoryLauncherScreen` now **quick-creates** on a button tap instead of opening the
    form: capture a one-shot GPS fix → infer block via `RowAttachment.containsPoint` → resolve
    attachment via `RowAttachment.resolve` → run `PinDuplicateChecker` (along-row first, raw
    fallback) → create via `createPin(attachToRow = true)`.
  - New `QuickPinDuplicateSheet` (ModalBottomSheet): title "Duplicate?", "Possible duplicate pin
    nearby", existing pin title/category/status/block, "On row X · side" + "N m away", with
    Cancel / Create anyway.
  - New `AutoPhotoPromptSheet` (ModalBottomSheet): "Add a photo?" with "Auto-skipping in Ns"
    3 → 0 countdown; Skip / Take Photo; auto-skips at zero. Take Photo launches the existing
    photo picker → `attachQuickPinPhoto`.
  - New `QuickPinSuccessToast` floating card: "{category} pin dropped" + friendly side/row
    subtitle, plus a calm "Saved offline — will sync when connected" line when offline.
    Auto-dismisses (~2.8s).
  - Full **New pin** form kept available: a top-bar action opens a blank form, and the no-GPS
    path falls back to the form (pre-filled mode/category/side) with calm wording.

### Algorithms intentionally unchanged
Row/path snapping (`RowAttachment`), duplicate detection + thresholds (`PinDuplicateChecker`,
along-row 2.5 m / raw-distance radii), the pin payload/data contract, the offline pin
outbox/replay, and the pin-photo pending queue/signed-URL behaviour are all reused as-is. Q-2f
is UI/workflow only.

### Auto-photo behaviour
Uses the **existing** device-local `AppPreferences.autoPhotoPrompt` (Preferences hub /
`AppPreferencesStore`) — no new setting, no backend schema. When off, no prompt appears and the
success card shows immediately. When on, the prompt shows after a successful quick create.

### Offline behaviour
Quick create offline queues a pending pin (existing outbox) and shows the offline success card.
A photo taken from the prompt while offline is retained via the existing pending-photo queue and
uploads on reconnect; Sync Status reflects the pending pin/photo. Showing the popups triggers no
network calls and no marker mutation/replay.

### QA performed
Quick-tap Irrigation Left/Right creates a pin (correct side) with row attachment and no form;
nearby duplicate shows the bottom sheet (Cancel stops, Create anyway proceeds); auto-photo on
shows the 3s prompt (Skip leaves the pin saved, countdown auto-skips, Take Photo opens the
picker and queues/uploads); offline quick pin saves pending; offline photo shows pending state;
full form remains reachable; friendly row/side wording verified; build green.

### Parked follow-ups (Q-4)
- In-prompt camera capture (the prompt uses the system photo picker; a direct camera capture
  path is deferred with the rest of the pin-photo parity items).
