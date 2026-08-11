# VineTrack — Detailed Picking Log & Actual Yield Contract (sql/180)

Canonical shared contract for the **Record Actual Yield → `Basic | Detailed`**
workflow. Defined and implemented first in this repository (iOS + Android +
Supabase); the Lovable Portal consumes this contract as-is and must NOT create
portal-specific data structures or modify the schema independently.

- Migration: `sql/180_picking_records.sql`
- Tests: `sql/tests/180_picking_records_tests.sql` (rollback-only)
- iOS: `PickingRecord` / `BackendPickingRecord` / `PickingRecordSyncService`
- Android: `PickingRecord` / `PickingRecordRepository` / `PickingRecordCreateSync` / `PickingRecordUpdateSync` / `PickingRecordDeleteSync`

---

## 1. Modes

| Mode | Storage | Semantics |
| --- | --- | --- |
| **Basic** | `historical_yield_records` (unchanged) | The original single actual-yield entry. Contract, RLS, RPCs and `block_results` JSON are untouched. |
| **Detailed** | `public.picking_records` (new) | A picking log: one row per individual pick. A Block + Variety + Vintage may have MANY picks in one vintage. |

Only one mode is used for an individual save action.

## 2. Table `public.picking_records`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` PK, default `gen_random_uuid()` | Clients mint the id up front (idempotency key for offline replay). |
| `vineyard_id` | `uuid` NOT NULL → `vineyards(id)` on delete cascade | Vineyard scoping. |
| `picked_at` | `date` NOT NULL | Plain `yyyy-MM-dd`. Mandatory user field. |
| `vintage` | `integer` NOT NULL | **Server-derived — never send.** A BEFORE trigger sets it from `picked_at` via `resolve_vineyard_vintage_year` (sql/119, season-end-year rule using `vineyards.season_start_month/day`). Client-supplied values are overwritten. |
| `paddock_id` | `uuid` NOT NULL | Block id. No FK (matches `block_results` contract); `paddock_name` is the snapshot. Mandatory user field. |
| `paddock_name` | `text` NOT NULL default `''` | Point-in-time block name snapshot. |
| `variety_id` | `uuid` NULL | From the block's `variety_allocations` when resolvable. |
| `variety_key` | `text` NULL | Stable catalog key from the allocation (trusted across id drift). |
| `variety_name` | `text` NOT NULL default `''` | Display-name snapshot. Populated from block config; user selects when a block has multiple varieties. |
| `clone` | `text` NULL | Display string from the allocation (`PaddockVarietyAllocation.clone`). Since sql/182 clones ARE catalogue entities (`grape_clone_catalog` / `vineyard_grape_clones`) and allocations also carry a stable `cloneKey`; the picking log deliberately keeps storing the display SNAPSHOT so historical records never change when catalogues evolve. See `docs/vinetrack-clone-rootstock-catalogue.md`. |
| `weight_kg` | `double precision` NOT NULL, CHECK `> 0` | Mandatory user field. |
| `sugar_value` | `double precision` NULL | CHECK: requires `sugar_unit` when set. |
| `sugar_unit` | `text` NULL, CHECK in (`'brix'`,`'baume'`) | **Unit used AT ENTRY TIME** — stored with the value so a later vineyard-preference change never reinterprets history. Normalised lower/trim by trigger; cleared when `sugar_value` is null. |
| `ph` | `double precision` NULL, CHECK `0 < ph < 14` | |
| `ta_g_l` | `double precision` NULL, CHECK `>= 0` | Titratable acidity, g/L. |
| `purpose` | `text` NOT NULL default `''` | Free text. |
| `sold` | `boolean` NOT NULL default `false` | |
| `sold_to` | `text` NULL | Trigger nulls it when `sold = false`. Free text — no buyer catalogue exists in VineTrack. |
| `price_per_tonne` | `double precision` NULL, CHECK `>= 0` | Trigger nulls it when `sold = false`. |
| `grape_value` | `double precision` **GENERATED** | `(weight_kg / 1000) * price_per_tonne` when `sold` and price set, else NULL. **Never include in INSERT/UPSERT — the write will fail.** Read-only; no contradictory manual value is possible. |
| `notes` | `text` NOT NULL default `''` | |
| `created_by`, `updated_by` | `uuid` → `auth.users(id)` | |
| `created_at`, `updated_at` | `timestamptz` NOT NULL default `now()` | `updated_at` via `set_updated_at` trigger. |
| `deleted_at` | `timestamptz` NULL | Soft delete. Always filter `deleted_at is null`. |
| `client_updated_at` | `timestamptz` NULL | Last-write-wins sync stamp. |
| `sync_version` | `integer` NOT NULL default `1` | |

### RLS (identical shape to `historical_yield_records`)
- SELECT: any vineyard member (`is_vineyard_member`).
- INSERT/UPDATE: `owner | manager | supervisor | operator`.
- Client hard DELETE: blocked for everyone.
- Soft delete: RPC `soft_delete_picking_record(p_id uuid)` — `owner | manager | supervisor`.

### Portal access pattern
- List: `GET /rest/v1/picking_records?select=*&vineyard_id=eq.{id}&deleted_at=is.null&order=picked_at.desc`
- Create: `POST /rest/v1/picking_records` with the columns above **minus `vintage`, `grape_value` and server audit columns**; send `client_updated_at`.
- Edit: `PATCH .../picking_records?id=eq.{id}&deleted_at=is.null` (same exclusions; see §5a for the full edit workflow).
- Delete: `POST /rest/v1/rpc/soft_delete_picking_record` `{ "p_id": "<uuid>" }`.

## 3. Vintage derivation

`vintage` is the **season-end year**: with the default 1 July season start,
10 Feb 2026 → Vintage 2026; 15 Aug 2026 → Vintage 2027. The server trigger is
authoritative; clients mirror it (`VintageResolver` on iOS/Android) only for
offline display. The Portal should display the stored `vintage` and never
compute its own for stored rows.

## 4. Sugar measurement preference (regional settings)

- New column `public.vineyards.sugar_measurement_unit` (`'brix' | 'baume' | NULL`).
- `get_vineyard_region_settings(p_vineyard_id)` now returns `sugar_measurement_unit` (last column).
- `set_vineyard_region_settings` gained a **12-parameter overload** with
  `p_sugar_measurement_unit` appended. The legacy 11-parameter overload remains
  for older clients and never touches the sugar column. The Portal must call
  the 12-parameter form (send all `p_*` named params, `null` allowed).
- Resolution rule (all clients): explicit value when set; otherwise the
  regional default — **AU/NZ → `baume`, everywhere else → `brix`**.
- UI label: **"Grape sugar measurement"** with options **Brix (°Bx)** /
  **Baumé (°Bé)** — exposed in Region & Units settings on both apps (owner/
  manager write, mirrored server-side).
- The preference only sets the DEFAULT unit for NEW picking entries. Reading
  historical records must always use the row's own `sugar_unit`.

## 5. Actual yield aggregation & precedence

For a Block + Variety + Vintage:

```
actual_yield_tonnes = SUM(weight_kg) / 1000
```

**Precedence (canonical, all clients):** when picking records exist for a
Block + Variety + Vintage, their summed weight IS the actual yield for that
combination. A Basic manually entered actual (`historical_yield_records`
`block_results[].actualYieldTonnes` with `year` = vintage) for the same
combination is **superseded — never added on top**. Basic records without a
matching detailed combination remain authoritative. Estimates are unaffected.

Server-side aggregation view (RLS-respecting, `security_invoker`):

```
public.picking_yield_totals
  (vineyard_id, vintage, paddock_id, variety_name, paddock_name,
   pick_count, total_weight_kg, actual_yield_tonnes,
   first_picked_at, last_picked_at, total_grape_value)
```

`GET /rest/v1/picking_yield_totals?vineyard_id=eq.{id}&vintage=eq.2026` gives
the Portal ready-made totals. Variety identity for matching is the
case/whitespace-insensitive `variety_name` (clients pick names from block
config, so names are consistent).

## 5a. Edit / update workflow (canonical, all clients)

Editing an existing picking record is a first-class operation on iOS,
Android and the Portal. Both apps expose it by tapping a record in the
Picking Log, which opens the SAME Detailed entry form prefilled from the
record and saves an update-in-place. The Portal must match these semantics.

### Editable fields

Date (`picked_at`), Block (`paddock_id` + `paddock_name` snapshot), Variety
(`variety_id` / `variety_key` / `variety_name` snapshot), Clone (`clone`
snapshot), `weight_kg`, `sugar_value` + `sugar_unit`, `ph`, `ta_g_l`,
`purpose`, `sold`, `sold_to`, `price_per_tonne`, `notes`.

### Server-authoritative fields — NEVER write on update

- `vintage` — the `BEFORE INSERT OR UPDATE` trigger re-derives it from the
  (possibly new) `picked_at` via `resolve_vineyard_vintage_year`. Changing
  the date across a season boundary moves the record to the correct vintage
  automatically; a client-supplied vintage is overwritten.
- `grape_value` — generated column; including it FAILS the write.
- `created_by`, `created_at`, `updated_at`, `updated_by`, `sync_version` —
  server audit columns.

### Write shape

- `PATCH /rest/v1/picking_records?id=eq.{id}&deleted_at=is.null` with
  `Prefer: return=representation`, sending the editable columns plus
  `client_updated_at` (fresh timestamp — last-write-wins).
- Cleared fields must be sent as **explicit JSON nulls** (e.g. un-selling a
  pick sends `"sold": false, "sold_to": null, "price_per_tonne": null`) so
  stale values are cleared server-side. The trigger also re-nulls the
  commercial fields whenever `sold = false`.
- An empty result set means the row was soft-deleted elsewhere — treat the
  edit as moot and drop the local copy; never re-insert.
- The record `id` NEVER changes — an edit updates in place, it never
  duplicates. RLS: any `owner | manager | supervisor | operator` member may
  update (same policy as insert).

### Form dependency rules (identical on iOS + Android)

- **Date changed** → the displayed vintage recomputes locally (mirror only);
  the server re-derives the authoritative value on save.
- **Block changed** → Variety and Clone reset (they belonged to the old
  block) and re-resolve from the new block's `variety_allocations`.
- **Variety changed** → Clone resets (clones belong to a variety).
- **Block and Variety unchanged** → the record's original variety/clone stay
  selectable even if Block Setup no longer lists them, so an edit never
  silently loses historical snapshots.
- **Sugar unit is preserved**: the form prefills the record's own
  `sugar_unit` (never today's vineyard preference). The preference is only
  the default for records without sugar data.

### After a successful edit

Nothing is stored twice — every downstream surface derives from the picking
records, so Picking Log rows and totals, Yield Overview, Actual Yield
(supersede rule, §5) and Yield Reports all recompute automatically from the
updated row (`picking_yield_totals` for the Portal). Soft delete is
unchanged (§2 RPC).

### Offline behaviour (apps; for Portal awareness)

- iOS: the edit dirty-marks the record and replays through the same
  last-write-wins upsert used for creates.
- Android: a coalesced `PICKING_RECORD / UPDATE` outbox marker replays the
  PATCH (latest edit wins); it is dependency-gated behind the same record's
  unresolved CREATE, and an edit of a record whose insert hasn't synced yet
  is folded into the queued insert payload instead.
- Parity tests: `ios/VineTrackTests/PickingRecordEditTests.swift` ↔
  `android-vinetrack/.../PickingRecordEditParityTest.kt`.

## 6. Cost / value

`grape_value = (weight_kg / 1000) × price_per_tonne` — generated server-side
for sold picks only. There is no pre-existing "Cost of Grapes" contract in
VineTrack (verified); Cost Reports continue to compute cost-per-tonne from
actual yield exactly as before. `total_grape_value` in the totals view is the
revenue-side aggregate for future commercial reporting.

## 7. Sold behaviour

- `sold = false` → `sold_to` and `price_per_tonne` are neither required nor
  stored (the trigger clears them).
- `sold = true` → UI shows Sold To (free text) and Price per tonne; both
  remain optional (no accounting contract requires them), `grape_value`
  appears once a price is set.

## 8. Client implementations (reference)

### iOS
- Model `PickingRecord` + `PickingYieldAggregator` (`LegacyImported/Models/PickingRecord.swift`)
- DTOs `BackendPickingRecord[Upsert]` (`Backend/Models/BackendPickingRecord.swift`) — `picked_at` encoded as local-calendar `yyyy-MM-dd`
- Sync `PickingRecordSyncService` (push→pull, last-write-wins, offline queue) wired into the full sweep and manual sync screen — creates AND edits ride the same dirty-mark → upsert path
- UI: `RecordActualYieldSheet` (`Basic | Detailed` segmented control; Detailed keeps the sheet open for fast harvest entry; `init(editing:)` reuses the same form for edit-in-place), `PickingLogListView` (vintage-grouped log + totals; tap a record to edit, swipe to delete), sugar preference in `RegionUnitsSettingsView`

### Android
- Model `PickingRecord` (`data/model/Models.kt`), repository `PickingRecordRepository`
- Offline outbox: `PICKING_RECORD` entity type, `PickingRecordCreateSync` / `PickingRecordUpdateSync` / `PickingRecordDeleteSync` (idempotent by client-minted id, coalesced per record, replayed in every replay pipeline)
- UI: `RecordYieldSheet` mode toggle + detailed form (an `editing` record locks it to Detailed and saves update-in-place), `PickingLogView` (hub → Picking Log; tap a record to edit), sugar preference in `RegionUnitsSettingsScreen`
- Aggregation: `computeVarietyYieldSummaries(records, paddocks, pickingRecords)` applies the supersede rule per (paddock, variety, vintage)

## 9. What the Portal must NOT do

- Do not send `vintage`, `grape_value`, `created_at`, `updated_at`,
  `updated_by`, `sync_version` on writes.
- Do not store sugar values without the unit used.
- Do not add Basic and Detailed actuals together for the same
  Block + Variety + Vintage.
- Do not create new tables/columns for picking data — schema changes originate
  in this repository via numbered migrations.
