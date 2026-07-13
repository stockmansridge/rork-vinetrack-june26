# Pruning Tracker + Fertiliser Calculator — shared sync & calculation contract (Phase 2)

Both tools are System Admin-only while in development. iOS and Android implement the SAME
contract below; the Lovable portal can consume the same tables later.

## Tables (sql/109, sql/110)

| Table | Writes | Notes |
| --- | --- | --- |
| `pruning_seasons` | client upsert on `id` + `soft_delete_pruning_season` RPC | One row per vineyard + paddock + season year (unique partial index on live rows). Season ids are **deterministic**: `UUIDv3(md5, "vinetrack-pruning-season|<vineyardId>|<paddockId>|<year>")` — Kotlin `UUID.nameUUIDFromBytes`, replicated byte-for-byte on iOS (`PruningSeasonId.make`). Two devices configuring the same block converge on the same row. |
| `pruning_entries` | `record_pruning_entry` / `delete_pruning_entry` RPCs only (no direct client writes) | One row per "Complete Today". Carries crew, labour hours, times, method, notes and the server-attributed `row_equivalents_completed` / `estimated_vines_completed`. |
| `pruning_row_segments` | RPCs only | Four fixed quarters per row; `UNIQUE(pruning_season_id, row_number, segment_number)`. **Single source of truth for completed work.** |
| `fertiliser_products` | client upsert on `id` + `soft_delete_fertiliser_product` RPC | `analysis_basis` = `elemental` \| `oxide` stored explicitly. |
| `fertiliser_records` | client upsert on `id` + `soft_delete_fertiliser_record` RPC | `record_status` = draft / planned / completed / cancelled; `calculation_mode` = perHectare / perVine / nutrientTarget / fertigation. |
| `fertiliser_record_allocations` | client upsert on `id` with the record | Per-block share (area, vines, rate, product, cost) so multi-block records stay reportable per block. |

All tables: RLS via `is_vineyard_member` (select) and `has_vineyard_role(owner/manager/supervisor/operator)`
(writes), client hard-deletes blocked, `set_updated_at` triggers, `client_updated_at` for LWW.

## Conflict rules (pruning)

- `record_pruning_entry` is **idempotent**: entry insert is `on conflict (id) do nothing`; each quarter
  is claimed with `on conflict … do update … where completed = false`. A quarter completed first by
  another device stays attributed to that device's entry; the losing entry's row-equivalents/vines are
  recomputed from the quarters it actually won — nothing is ever double-counted.
- A completed quarter never reverts through sync. The only reversal path is the explicit
  `delete_pruning_entry` RPC (owner/manager/supervisor/operator), which soft-deletes the entry and
  frees its quarters.
- Clients re-apply the server's segment attribution after every pull; entries still queued locally keep
  their optimistic quarters until their push lands.

## Calculation contract (identical on both platforms)

Source of truth = stored entries/segments; dashboards derive deterministically.

- Row equivalents: full row = 1.0; quarter = 0.25. Completed = union of completed quarters (set
  semantics — duplicates impossible by construction).
- Vines in row = row length ÷ vine spacing; stored vine counts win when present
  (`paddock.effectiveVineCount`). Vines for N quarters = N × vinesPerRow ÷ 4, rounded.
- Daily rate = total row equivalents on days WITH entries ÷ number of days with entries, over the last
  3 working days, last 7, or the whole period. **Days without entries (rain days) never reduce the
  rate.** Preferred rate = 3-day rolling average, falling back to whole-period.
- Remaining working days = ceil(remaining row equivalents ÷ preferred rate); projected finish walks
  forward through the season's configured working days (ISO weekdays, default Mon–Fri).
- Status thresholds: Ahead > 3 days early · On track ≤ 3 days late/early · At risk 1–3 days late ·
  Behind > 3 days late · Complete at 100% · Not started at 0%.
- Time-elapsed marker = (today − start) ÷ (due − start), clamped 0–1; start falls back to the first
  entry date.
- Edge cases: no work recorded → Not started, no projection; one day recorded → that day is the
  average; zero labour hours → per-hour rates omitted (no divide-by-zero); due date passed with work
  remaining → Behind; zero completion rate → no projected finish; differing row lengths → vinesPerRow
  uses the block average (total length ÷ rows); missing geometry → `manual_row_count` from season
  setup; missing spacing and vine count → vine metrics show 0 while row-equivalent progress still works.

Fertiliser: per-hectare total = ha × rate; per-vine total = vines × g(mL)/vine ÷ 1000; packs =
total ÷ pack size; product cost = total ÷ pack size × price per pack; total job cost = product +
labour/machinery. Multi-block allocations are weighted by area (per-hectare) or vine count (per-vine).

## Offline behaviour

- iOS: `PruningSyncService` / `FertiliserSyncService` (management-sync template) — dirty-id metadata
  persisted in `PersistenceStore`, debounced eager push, full sweep on vineyard change / foreground /
  reconnect / manual sync / 180 s timer, pull-to-refresh on both tool screens, pending counts feed the
  global sync status bar.
- Android: `PruningSyncCoordinator` / `FertiliserSyncCoordinator` — local-first writes into the
  SharedPreferences stores, queued in the shared `PendingWriteRepository` outbox (coalesced per record
  id), replayed on reconnect/foreground via `replayAllPendingWrites()`, reconciled on screen open and
  vineyard change; pending rows count toward `AppUiState.pendingSyncCount`.
- Both: client-generated UUIDs; local caches survive offline restarts; server state survives logout /
  reinstall / device changes.

## Phase 2 remainder (deliberately sequenced after sync is verified)

1. Nutrient-target mode (elemental vs P₂O₅/K₂O conversion: P = P₂O₅ × 0.4364, K = K₂O × 0.8301,
   displayed alongside the label basis — never silently mixed).
2. Fertigation mode (prefilled from irrigation settings, all defaults visible and editable).
