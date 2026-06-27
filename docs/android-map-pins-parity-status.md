# Android Map + Pins Parity — Status Note

Internal status tracker for the Android (`android-vinetrack`) Map + Pins parity
stream, started after the Android offline reliability package (Stages 4A, 5, 6,
7, 8) closed. No Supabase schema/RLS changes were made by any slice below.
iOS / Lovable remain the source of truth for parity, and all changes are
display-only and compatible with existing server-generated records.

---

## Closure state

| Slice | Scope | Status |
|---|---|---|
| Audit | Map + Pins parity audit (read-only, no code change). | **CLOSED** |
| Slice 1 | Row/path metadata wording polish (display-only). | **CLOSED** |
| Slice 2 | Pending/offline pin visual indicators (display-only). | **CLOSED** |
| Audit 2 | Map style parity audit (read-only, no code change). | **CLOSED** |
| Slice 3 | Block-label readability polish (display-only). | **CLOSED** |

`runChecks` passed for `android-vinetrack` on the row/path wording slice
(implementation + QA), the pending/offline pin indicators slice
(implementation + QA), and the block-label readability slice (implementation +
QA). The Map + Pins parity audit and the Map style parity audit were both
read-only passes with no code change.

---

## Audit findings summary

- **Map surface works** both online and with cached offline launch data — the
  map screen loads, the selected vineyard renders, and core controls remain
  usable in both modes.
- **Block polygons, row lines, and pins render** for the selected vineyard.
- **Offline banner does not obscure map controls** — the slim cached/offline
  indicator leaves the core map controls accessible.
- **Duplicate warnings already use along-row distance** for row-attached pins,
  and raw GPS distance only for legacy (non-row-attached) pins. This behaviour
  was confirmed correct and left unchanged.
- **Map / pin core behaviour is generally sound** — the audit found no
  correctness bug requiring an immediate fix; the recommended work was polish.

---

## Row/path wording slice (Slice 1)

- **Prefers `drivingRowNumber` for display** when present, so the customer-facing
  path/driving row (e.g. `19.5`) is the primary row shown.
- **Falls back to `pinRowNumber`** when `drivingRowNumber` is absent; returns no
  label when neither exists.
- **Preserves fractional row numbers** such as `19.5` without rounding, and trims
  whole numbers cleanly (`15.0` → `15`).
- **Appends side only when present** (`left`/`right`); omits side cleanly when
  absent with no trailing separator.
- **Optional secondary detail** — shows a subtle `Block row …` line only when both
  `drivingRowNumber` and `pinRowNumber` exist and differ; hidden when they match
  or only one value exists.
- **Surfaces updated:**
  - pin list / card,
  - pin detail / edit sheet.
- **Display-only** — no database, write-path, offline/replay, or duplicate-checker
  changes. Stored pin fields were left untouched.

Example rendering:

- `drivingRowNumber = 19.5`, `pinRowNumber = 15`, side left →
  `Attached to row 19.5 · left`, secondary `Block row 15`.
- only `pinRowNumber = 15`, side right → `Attached to row 15 · right`, no
  secondary line.
- `drivingRowNumber = 19.5`, no side → `Attached to row 19.5`.

---

## Pending/offline pin indicators slice (Slice 2)

- **`PinSyncState` is display-only** and derived entirely from existing pending
  stores; no new fields were added to the `Pin` model.
- **Pending/blocked create ids come from `PendingWriteRepository`** — derived from
  `entityType = PIN`, `opType = CREATE`, and the unresolved/blocked statuses
  already defined.
- **Pending/blocked photo ids come from `PendingPhotoRepository`** — derived from
  pending photo attachments with unresolved/blocked status.
- **Map markers now distinguish** pending create, pending photo, and
  blocked/needs-attention state without making pins hard to see, and with a
  concise callout status line only when relevant.
- **Pin list / card shows status chips** such as Pending sync, Photo waiting, and
  Needs attention, alongside the existing mode/open/done/photo badges.
- **Pin detail / edit sheet shows a conservative status banner** that does not
  imply unsupported offline edit/delete support.
- **Wording aligns with Sync Status** (pending pin create, pending photo upload,
  blocked/needs attention) without duplicating or replacing the Sync Status
  screen.
- **No replay/write/database logic changed** — derived from existing repositories
  only; no retry buttons or new sync actions added.

---

## Map style parity audit summary (Audit 2)

- **Android default map style is already Hybrid** — no change needed to make
  Hybrid the default.
- **Android supports Hybrid / Satellite / Standard / Terrain** selectable through
  Settings (`MapDefaults` / `MapPrefsStore`).
- **3D Overview / Top-down toggle exists** on Android and is ahead of iOS here.
- **Biggest gap found was block-label readability** — iOS shows always-visible
  orange block-name chips, while Android used generic azure marker pins that only
  surfaced name/area/rows on tap.
- **Offline tile-free map fallback remains parked** as larger work (iOS has an
  offline vector map view; Android relies on cached Google Maps tiles).

---

## Block-label readability slice (Slice 3)

- **Generic azure block label markers replaced** with compact always-visible chip
  labels.
- **Implemented using `MarkerComposable`** (maps-compose 6.12.0), guarded with
  `@OptIn(MapsComposeExperimentalApi::class)`.
- **Labels anchored at the block polygon centroid** (`anchor = Offset(0.5f, 0.5f)`).
- **Primary text is the block name**; blank/missing names are handled cleanly.
- **Optional row count suffix** appears only when `rowCount > 0`, formatted
  compactly (e.g. `· 12r`).
- **Tapping a label still shows** the block name + area/rows callout.
- **Labels toggle still controls visibility** — `MapDefaults.showBlockLabels`
  governs whether chips render.
- **Zoom-gated** at `LABEL_MIN_ZOOM = 13.5f`; labels disappear below that zoom.
- **No clustering or heavy map rewrite added.**

### Polygon styling

- **Block polygons shifted toward iOS-style amber/orange** stroke/fill for better
  contrast over satellite imagery.
- **Satellite imagery remains visible** through the transparent fill.
- **Row lines and pin markers remain readable** over the new polygon colour.
- **Geometry unchanged** — only styling adjusted.

### Safety / scope notes

- Display-only.
- No database / Supabase writes.
- No geometry data changes.
- No offline cache changes.
- No pin sync / replay changes.
- No pending photo retry changes.
- No iOS changes.

---

## Current parked parity items

- offline tile-free / vector map fallback (larger work)
- hybrid/satellite visual depth polish
- compass / facing-direction wording
- fuller pin-detail field parity
- multiple photos per pin
- offline pin update/complete/delete audit
- growth-record photo retry
- broader offline write queues
- Tier-A trip / GPS / row / tank replay

---

## Build / check reference

- `runChecks` passed for `android-vinetrack` on the row/path wording slice
  implementation and QA.
- `runChecks` passed for `android-vinetrack` on the pending/offline pin indicator
  slice implementation and QA.
- `runChecks` passed for `android-vinetrack` on the block-label readability slice
  implementation and QA; no code changed during QA.
- The Map + Pins parity audit and the Map style parity audit were read-only — no
  code changed and no build was required.
- This note is **documentation only** — no app code changed, so no build was
  necessary for this update.
