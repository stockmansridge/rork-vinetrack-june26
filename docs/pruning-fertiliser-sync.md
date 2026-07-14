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

## Calculation contract (identical on ALL platforms — iOS, Android, portal)

Source of truth = stored entries/segments; dashboards derive deterministically.
`get_pruning_vineyard_summary` (sql/115) is the **authoritative reference implementation** — the
portal must call it (or replicate it exactly); the mobile calculators mirror it for offline use.

**Blocks included:** ALL non-deleted paddocks of the selected vineyard — including blocks named
"Test", blocks with no season row, and blocks with zero vines. No platform may include a block the
others exclude.

**Season selection:** `season_year` = requested year, else the year of the as-of date in the
vineyard's IANA timezone (`vineyards.timezone`, UTC fallback) — never the device calendar year
independently. Entry grouping uses the stored `entry_date` (date-only, no UTC conversion).

- Row equivalents: full row = 1.0; quarter = 0.25. Completed = union of completed quarters (set
  semantics — duplicates impossible by construction). Segments carrying a `paddock_row_id` match
  only that row; segments without one match the FIRST configured row (stored order) with that
  number; unmatched quarters are excluded — never re-attached to a different row.
- **Block vine total (single precedence, all platforms):** `vine_count_override`, else
  `trunc((row_length_override ?? Σ row lengths) ÷ vine_spacing)` (spacing default 1.0; 0 vines when
  spacing ≤ 0). Row lengths use equirectangular distance with the polygon-centroid latitude (row
  start latitude when no polygon). No platform may use `paddock vines ÷ row count` while another
  uses `length ÷ spacing`.
- **Row vines:** block vines distributed by row-length weights — a row without geometry gets the
  average mapped length (or an equal share when nothing is mapped) — so per-row vines always
  reconcile with the block total and rows may have different lengths.
- **Rounding point (critical):** a quarter contributes `exactRowVines ÷ 4` at FULL precision.
  Vines pruned = `round(Σ exact quarter vines)` — rounded ONCE at the level being displayed
  (block card: block sum; vineyard dashboard: vineyard sum). NEVER `Σ round(…)` per quarter, per
  entry, or per block. (This was the 1,124 vs 1,126 drift.)
- **Overall completion % (the ONE formula):** `completed row equivalents ÷ total row equivalents`
  — row-equivalent based, NOT vine-weighted, NOT blocks-complete based. Display
  `round(fraction × 100)` half-up — never truncate. (Android truncation caused 3% vs iOS 4%;
  the portal's vine-weighted formula caused 5%.)
- **Vines/day (label: whole period):** group entries by `entry_date`, sum EXACT vines per day,
  divide by the number of days-with-entries over the whole period; round only for display.
- **Vines/labour hour:** `Σ exact vines of entries with labour_hours > 0 ÷ Σ labour hours`
  (person-hours, after Work Task labour-line totals are applied). Deleted entries and zero-hour
  entries are excluded from the denominator; their vines are excluded from the numerator.
- Daily rate (projection input) = mean row equivalents per day-with-entries over the 3 most recent
  days-with-entries, whole period when fewer. **Days without entries (rain days) never reduce the
  rate.**
- **Projection:** remaining working days = ceil(remaining row equivalents ÷ rate); walk calendar
  days starting AT the as-of date (today counts when it is a working day — the portal starting
  tomorrow caused 15 vs 14 July). Date-only arithmetic in the vineyard timezone — no UTC shifts.
  Vineyard projected completion = the LATEST block projection.
- Status thresholds: Ahead > 3 days early · On track ≤ 3 days late/early · At risk 1–3 days late ·
  Behind > 3 days late · Complete at 100% · Not started at 0%. "Blocks at risk" counts At risk +
  Behind.
- Time-elapsed marker = (today − start) ÷ (due − start), clamped 0–1; start falls back to the first
  entry date.
- Edge cases: no work recorded → Not started, no projection; one day recorded → that day is the
  average; zero labour hours → per-hour rates omitted (no divide-by-zero); due date passed with work
  remaining → Behind; zero completion rate → no projected finish; missing geometry →
  `manual_row_count` fallback rows (equal vine share, number identity); missing spacing and vine
  count → vine metrics show 0 while row-equivalent progress still works.

Fertiliser: per-hectare total = ha × rate; per-vine total = vines × g(mL)/vine ÷ 1000; packs =
total ÷ pack size; product cost = total ÷ pack size × price per pack; total job cost = product +
labour/machinery. Multi-block allocations are weighted by area (per-hectare) or vine count (per-vine).

### One aggregation function per platform

The vineyard dashboard is a single shared function on each platform — views NEVER aggregate inline:

- iOS: `PruningCalculator.vineyardSummary(…)` → `PruningVineyardSummary`
  (`LegacyImported/Models/PruningModels.swift`), used by `PruningTrackerView` and the parity check.
- Android: `PruningCalculator.vineyardSummary(…)` → `PruningVineyardSummary`
  (`data/model/PruningModels.kt`), used by `PruningTrackerScreen` and the parity check.
- Portal / server: the `get_pruning_vineyard_summary` RPC (sql/115) — the authoritative reference.

Block detail screens use the same primitives (`exactVinesPerDay`, `vinesPerLabourHour`,
`exactVines`) — no per-entry rounding, no `rate × vinesPerRow` approximations.

### Online SQL 115 reconciliation (offline-first preserved)

Mobile keeps the full local calculation path — a server-only dashboard would break field use.
When online, after every successful pruning sync/refresh each app calls
`get_pruning_vineyard_summary` and compares the server's rounded values (progress %, vines
pruned/total/remaining, vines/day, vines/labour-hour, blocks complete/at risk, projected date)
against the local `vineyardSummary`:

- iOS: `PruningSyncService.verifyServerParity` → `lastParityReport` + `[PruningParity]` log line.
- Android: `AppViewModel.verifyPruningServerParity` → `PruningParity` logcat tag
  (`Log.w` on mismatch, `Log.d` on match).

The check NEVER blocks or alters the workflow: RPC unavailable (offline, older schema) ⇒ silent
skip. Note the check compares the server's season (as-of year in the vineyard timezone) against
the device's newest local season per block — identical except across a New-Year boundary.

### Shared fixture tests

The same deterministic fixture runs in both native test suites and encodes the SQL 115 contract:

- iOS: `ios/VineTrackV2Tests/PruningCalculatorFixtureTests.swift` (swift-testing).
- Android: `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/PruningCalculatorFixtureTest.kt` (JUnit).

Fixture: block "Cab Franc" with 7 REAL non-sequential rows (42–47 + 50, six 200 m + one 100 m,
vine override 1300) with rows 42–45 full + row 46 Q1/Q2 completed over two entries
(13 Jul: 8 quarters/4 h; 14 Jul: 10 quarters/8 h), plus a manual-fallback block (4 rows,
400 vines), as of 2026-07-14. Expected identical on every platform:

- Block: 4.5 / 7 row eq · 64 % · 900 / 1300 vines · rate 2.25 · projected 2026-07-15 · Ahead.
- Vineyard: 4.5 / 11 row eq · 41 % · 900 / 1700 vines · 800 remaining · 450 vines/day ·
  75 vines/labour-hour · projected 2026-07-15 · 0 complete · 0 at risk.
- Plus: duplicate quarters never double-count, legacy number-matched segments, reversal reopens
  quarters, gap days never reduce rates, zero-hour entries excluded from both rate sides.

Run Android: `./gradlew testReleaseUnitTest --tests '*PruningCalculatorFixtureTest'`.
Run iOS: the `VineTrackV2Tests` target in Xcode (⌘U).

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

## Record Pruning + Work Task link (sql/113, corrected by sql/114)

Wording contract (all platforms): the action is **"Record Pruning"** — never "Complete Today" —
because the date field determines when the work occurred. Dialog title: `Record Pruning — <Block>`.
Submit button: `Record N quarters` (disabled when nothing is selected).

- `pruning_entries.work_task_id` — nullable uuid, **one Work Task per entry at most**. Logical
  reference (no FK), matching the pruning tables' `paddock_id` convention: the task is created
  client-side with a client-generated UUID and pushed through the existing work-task queue, so the
  pruning RPC may replay before the `work_tasks` row exists remotely. Stable ids keep the link
  consistent regardless of replay order.
- **sql/114 (corrective, 113 untouched):** partial unique index
  `pruning_entries_work_task_unique` on `(work_task_id) where work_task_id is not null and
  deleted_at is null` — one task may be linked to at most ONE live pruning entry (existing
  duplicates resolved earliest-entry-wins before the index is created). `record_pruning_entry`
  now DROPS the link (entry still records) when another live entry already owns the task id, so
  replay can never fail or steal a link; `set_pruning_entry_work_task` RAISES on the same
  condition because it's an explicit user action. Both functions deliberately accept a
  `work_task_id` with no `work_tasks` row yet — required because the pruning queue may replay
  before the work-task queue; vineyard isolation still rejects an existing task from another
  vineyard. This allowance is documented on both functions.
- `record_pruning_entry` gained `p_work_task_id uuid default null` (old 15-arg signature dropped —
  PostgREST ambiguity). On replay the link only back-fills an EMPTY `work_task_id`; it can never
  overwrite an existing different link, so retries create at most one linked task.
- `set_pruning_entry_work_task(p_entry_id, p_work_task_id)` — the explicit link / unlink / replace
  action (clients cannot write `pruning_entries` directly). Validates the task belongs to the same
  vineyard.
- **Create Work Task flow (mobile, mirrored on both platforms):** "Create a Work Task for this
  pruning work" toggle, default OFF. When ON, the work type is asked (default `Pruning`, existing
  task-type catalog) plus a **Labour lines** section; everything else is reused from the pruning
  form — date, block, crew, times, notes. Task is created as **Completed** (`isFinalized`,
  `status = "Completed"`), with notes
  `Source: Pruning Tracker — Rows 44–46 · 6 quarters · 1.5 row equivalents · ~375 vines · <method>`
  plus the user's notes, a `work_task_paddocks` join row, and `area_ha` from the block (iOS).
  One task per submission — never per row or per quarter.
- **Labour lines (canonical Work Task costing rows):** the flow creates real
  `work_task_labour_lines` rows (sql/050) — NOT a pruning-specific model — through each platform's
  existing labour path (iOS `MigratedDataStore.addWorkTaskLabourLine` →
  `WorkTaskLabourLineSyncService`; Android `AppViewModel.saveLabourLine` → `WorkTaskLabourSync`
  outbox with its parent-create gate). The first line is seeded from the pruning form's
  Worker/Crew + Labour hours; more workers can be added, each with its own worker type
  (`worker_type_id` link + `worker_type` snapshot, default rate seeded from the worker type),
  worker count, hours per worker and optional hourly rate. Line totals use the DB convention:
  `total_hours = worker_count × hours_per_worker`, `total_cost = total_hours × hourly_rate`;
  a blank rate displays as "Not specified", never $0.
- **Person-hours convention:** VineTrack Work Tasks treat labour-line hours as PERSON-hours and
  the canonical labour source when lines exist (see `AddEditWorkTaskView` /
  `WorkTaskLogView.effectiveHours`). Therefore when the toggle is ON,
  `pruning_entries.labour_hours = Σ line person-hours` (Worker A 8 h + Worker B 8 h → 16 h) so
  vines-per-labour-hour stays accurate; the task header's `durationHours` carries the same total
  as a fallback. With the toggle OFF, the manually entered labour hours apply unchanged.
- **Atomicity:** all three records (pruning entry, task header + join row, labour lines) are
  local-first writes; each syncs through its own idempotent queue with the SAME client-generated
  ids (labour ids minted when the row is added in the sheet), and Android's labour queue defers
  behind the task header's pending create, so offline replay preserves relationships and can
  never duplicate the task or a line. A failed step retries from its own queue without
  re-recording pruning.
- **Reversal:** deleting an entry with a linked task prompts — Keep Work Task / Delete Work Task
  (existing work-task delete permissions) / Cancel. `delete_pruning_entry` itself never touches the
  task. Editing a Work Task never rewrites the pruning entry — the pruning record stays the source
  of truth for row completion.

### Portal summary parity spec (implement in Lovable — sql/115)

The portal's pruning dashboard MUST NOT keep its own aggregation. Replace it with:

```ts
const { data } = await supabase.rpc("get_pruning_vineyard_summary", {
  p_vineyard_id: vineyardId,
  // optional: p_season_year, p_today (defaults: vineyard-timezone today)
});
```

Returned fields: `completion_fraction` + `display_percent` (row-equivalent based),
`total_vines`, `vines_pruned` (+ `_exact`), `vines_remaining`, `vines_per_day` (+ `_exact`),
`vines_per_labour_hour` (+ `_exact`), `labour_hours`, `projected_completion_date`,
`blocks_complete`, `blocks_at_risk`, and a per-block `blocks` array (name, row count, row
equivalents, vines, rate, projection, status) — use the `blocks` array for the block cards so the
same numbers drive both levels. Display the pre-rounded fields as-is; never re-derive progress
from vines or re-round the exact values differently. The three portal-side root causes to remove:
vine-weighted overall %, its own vine denominator (22,704 vs the contract's 22,598), and a
projection that skips the current day.

### Portal recording spec (implement in Lovable)

- Same wording contract as above; the recording dialog must contain exactly: Date, Worker or crew,
  Labour hours (read-only Σ person-hours while the task toggle is on), optional Start/Finish time,
  Pruning method, Notes, selected rows + quarters, Create Work Task toggle (default off,
  conditional fields only) with the same Labour lines section (seed first line from Worker/Crew +
  Labour hours; add/remove workers; worker type picker seeds the rate; per-line totals; blank
  rate = "Not specified").
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
