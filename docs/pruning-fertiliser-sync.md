# Pruning Tracker + Fertiliser Calculator — shared sync & calculation contract (Phase 2)

Both tools are System Admin-only while in development. iOS and Android implement the SAME
contract below; the Lovable portal can consume the same tables later.

## Tables (sql/109, sql/110)

| Table | Writes | Notes |
| --- | --- | --- |
| `pruning_seasons` | client upsert on `id` + `soft_delete_pruning_season` RPC | One row per vineyard + paddock + season year (unique partial index on live rows). Season ids are **deterministic**: `UUIDv3(md5, "vinetrack-pruning-season|<vineyardId>|<paddockId>|<year>")` — Kotlin `UUID.nameUUIDFromBytes`, replicated byte-for-byte on iOS (`PruningSeasonId.make`). Two devices configuring the same block converge on the same row. |
| `pruning_entries` | `record_pruning_entry` / `delete_pruning_entry` RPCs only (no direct client writes) | One row per "Record Pruning" submission. Carries crew, labour hours, times, method, notes, the server-attributed `row_equivalents_completed` / `estimated_vines_completed`, and the optional `work_task_id` link (sql/113). |
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

## Record Pruning + Work Task link (sql/113)

Wording contract (all platforms): the action is **"Record Pruning"** — never "Complete Today" —
because the date field determines when the work occurred. Dialog title: `Record Pruning — <Block>`.
Submit button: `Record N quarters` (disabled when nothing is selected).

- `pruning_entries.work_task_id` — nullable uuid, **one Work Task per entry at most**. Logical
  reference (no FK), matching the pruning tables' `paddock_id` convention: the task is created
  client-side with a client-generated UUID and pushed through the existing work-task queue, so the
  pruning RPC may replay before the `work_tasks` row exists remotely. Stable ids keep the link
  consistent regardless of replay order.
- `record_pruning_entry` gained `p_work_task_id uuid default null` (old 15-arg signature dropped —
  PostgREST ambiguity). On replay the link only back-fills an EMPTY `work_task_id`; it can never
  overwrite an existing different link, so retries create at most one linked task.
- `set_pruning_entry_work_task(p_entry_id, p_work_task_id)` — the explicit link / unlink / replace
  action (clients cannot write `pruning_entries` directly). Validates the task belongs to the same
  vineyard.
- **Create Work Task flow (mobile, mirrored on both platforms):** "Create a Work Task for this
  pruning work" toggle, default OFF. When ON, only the work type is asked (default `Pruning`,
  existing task-type catalog); everything else is reused from the pruning form — date, block,
  crew, labour hours, times, notes. Task is created as **Completed** (`isFinalized`,
  `status = "Completed"`), with notes
  `Source: Pruning Tracker — Rows 44–46 · 6 quarters · 1.5 row equivalents · ~375 vines · <method>`
  plus the user's notes, a `work_task_paddocks` join row, and `area_ha` from the block (iOS).
  One task per submission — never per row or per quarter.
- **Atomicity:** both records are local-first writes; each syncs through its own idempotent queue
  with the SAME client ids, so offline replay preserves the relationship and can never duplicate.
- **Reversal:** deleting an entry with a linked task prompts — Keep Work Task / Delete Work Task
  (existing work-task delete permissions) / Cancel. `delete_pruning_entry` itself never touches the
  task. Editing a Work Task never rewrites the pruning entry — the pruning record stays the source
  of truth for row completion.

### Portal parity spec (implement in Lovable)

- Same wording contract as above; the recording dialog must contain exactly: Date, Worker or crew,
  Labour hours, optional Start/Finish time, Pruning method, Notes, selected rows + quarters,
  Create Work Task toggle (default off, conditional fields only).
- Quarter tiles ≥ 44×44 px, full cell width, whole tile clickable, states: grey = remaining,
  blue = selected, green = completed (locked); keep Q1–Q4 headings; hover/focus/keyboard states.
- Work Task creation must call the existing work-task insert with a client-generated UUID and pass
  it as `p_work_task_id` to `record_pruning_entry` (or use `set_pruning_entry_work_task` on retry).
  If the task insert fails after pruning succeeded: keep the pruning record, show
  "Pruning was recorded, but the Work Task could not be created", and retry with the SAME task id.
- **Range parser (reference behaviour, must match the pickers on mobile):** input like
  `1-10, 15, 20-22` selects every ACTUAL configured row whose row number falls inclusively in a
  range — never synthesised rows. Trim whitespace; accept descending input (`46-44` ≡ `44-46`);
  de-duplicate; ignore numbers not present in the configured rows; malformed tokens produce a
  validation message, never a silent single-row selection; apply to incomplete quarters only.
  Test cases: single row `44` → {44}; `44-46` over rows 42–46 → {44,45,46}; `46-44` → same;
  `2-5` over rows 1,2,3,5,6 → {2,3,5} (no invented 4); `1-10, 15, 20-22` multi-token;
  duplicates `44,44-45` → {44,45}; `44-abc` → validation error; `999` (absent) → empty + notice.

## Phase 2 remainder (deliberately sequenced after sync is verified)

1. Nutrient-target mode (elemental vs P₂O₅/K₂O conversion: P = P₂O₅ × 0.4364, K = K₂O × 0.8301,
   displayed alongside the label basis — never silently mixed).
2. Fertigation mode (prefilled from irrigation settings, all defaults visible and editable).
