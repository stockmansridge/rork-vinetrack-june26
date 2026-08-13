# Piece Rate pruning costing — shared contract (sql/188 + sql/189)

Status: **live on iOS + Android**, and **resolved database-side and API-side by
sql/189** · Portal (Lovable) **CONSUMES ONLY**.

Rork/VineTrack mobile is the source of truth for this contract. The portal must
not create or modify any of these columns, tables, constraints or RPCs.

## Why

Pruning is commonly contracted at an agreed price **per vine**, not per hour.
Before this, the only labour costing VineTrack could express was
`work_task_labour_lines` (sql/050): `worker_count × hours_per_worker ×
hourly_rate`. A grower who agreed "$1.27 a vine" had to reverse-engineer an
hourly rate, which is neither what was agreed nor what gets invoiced.

Piece Rate is an **alternate costing method on the existing work task**. It is
strictly additive: no column or table is dropped or renamed, no existing RLS
policy changes, and every existing record keeps behaving exactly as an hourly
job.

## THE reading rule

```
costing_method = 'hourly'      → labour cost = Σ work_task_labour_lines.total_cost
costing_method = 'piece_rate'  → labour cost = work_tasks.piece_rate_total_cost
```

Three rules every consumer (mobile, portal, API, reports) must honour:

1. **Never sum the two.** A task has exactly ONE labour cost at any time.
2. **Never infer piece rate from the presence of a rate.** `costing_method` is
   the only switch.
3. **Never treat an absent agreement as `$0.00`.** A missing rate or quantity is
   "not specified".

## Effective work task labour cost — the one number to read

There is exactly **one** labour cost for a work task, and one rule that produces
it. Every client, report, database object and endpoint uses this rule.

```
effectiveLabourCost(task):

  costing_method = 'piece_rate'   →  work_tasks.piece_rate_total_cost
  anything else, including NULL   →  Σ ACTIVE, RATED work_task_labour_lines.total_cost
```

- **Never add them.** A piece-rate job's cost is its agreement; its labour lines
  are hours, not money. `piece_rate_total_cost + Σ line.total_cost` is always
  wrong.
- **An unrecognised or missing `costing_method` reads as hourly**, so every
  legacy record keeps its exact pre-existing value.
- **Soft-deleted lines never contribute** (`deleted_at is null`).
- **Unrated lines are skipped, not counted as zero.** `total_cost` is generated
  with `coalesce(hourly_rate, 0)`, so summing an unrated line silently turns "no
  rate entered" into `$0.00`. A task whose lines carry no rate resolves to
  **null — "not specified"**.

### Fallback for a pruning activity with no linked Work Task

A pruning activity may pre-date work tasks, or simply not be linked to one.
Those records keep their own activity-level figure, untouched:

```
effectiveLabourCost(activity):

  linked task, piece rate   →  the task's piece_rate_total_cost
                               (no fallback — an unpriced piece-rate job is
                               "not specified", and falling back to hours × rate
                               would report an HOURLY figure for a piece-rate job)
  linked task, otherwise    →  the task's rated labour lines,
                               else the activity's own labour_hours × hourly_rate
  no linked task            →  labour_hours × hourly_rate   (legacy, unchanged)
```

This is **precedence, never addition**. The middle branch's fallback exists so
nothing that had a value before sql/189 loses it: an activity linked to a task
with no costed line still reports its own hours × rate, exactly as it always
did.

### Where the rule lives

| surface | implementation |
| --- | --- |
| iOS | `PieceRateCosting.effectiveLabourCost(task:labourLines:)` |
| Android | `PieceRateCosting.effectiveLabourCost(task, labourLines)` |
| database, task | `public.work_task_effective_labour_cost(uuid)` (sql/189) |
| database, activity | `public.pruning_activity_effective_labour_cost(uuid)` (sql/189) |
| database, joins | `public.v_work_task_effective_labour_cost` (sql/189) |
| shared API | `effective_labour_cost` on the work task payload |

The hourly side is also exposed on its own —
`public.work_task_labour_line_cost(uuid)` and the view's `labour_line_cost` — so
an audit screen can show "the hourly lines would have been $480" **beside** the
real cost. It is never added to it.

Each surface also reports **which branch produced the number** — `piece_rate` |
`labour_lines` | `activity_hours` | `null` — so a report can label the figure
without re-deriving the branch and eventually disagreeing with the cost it is
labelling.

### Where it is exposed

- `public.pruning_activity_json` → `activity.labour_cost` and
  `totals.labour_cost`, plus `labour_cost_source`, `costing_method`,
  `piece_rate_per_vine`, `piece_vine_count`, `piece_rate_total_cost` and
  `totals.cost_per_vine`.
- `public.pruning_activity_allocation_export` → `activity_labour_cost` (primary
  allocation row only), `activity_labour_cost_source`,
  `activity_costing_method`, `activity_piece_rate_per_vine`,
  `activity_piece_vine_count` and `allocation_share_labour_cost`.
- `vinetrack-api` work tasks → `costing_method` and `piece_vine_count` always;
  `piece_rate_per_vine`, `piece_rate_total_cost`, `effective_labour_cost` and
  `labour_cost_source` with `costs:read`.
- `vinetrack-api` pruning activities → `labour_cost` now resolves through the
  same rule, plus `labour_cost_source`, `costing_method`, `piece_rate_per_vine`
  and `piece_vine_count`.

### Multi-block allocation

`allocation_share_labour_cost` splits the **one** effective cost across the
live, non-skipped allocations by each block's share of row equivalents, rounded
to cents, with the rounding residual assigned to the primary allocation. The
allocations therefore reconcile **exactly**:

```
$1,000 piece-rate job, 60 / 40 by row equivalents
    Block A    $600.00
    Block B    $400.00
    total    $1,000.00      ← exactly, never $999.99
```

Skipped allocations never carry labour (sql/168), and the piece-rate figure is
always the **saved snapshot** — allocation never re-reads today's row vine
counts.

### Why `work_task_labour_lines` was left alone

`work_task_labour_lines.total_cost` is a **stored generated column**
(`worker_count × hours_per_worker × hourly_rate`). It is structurally incapable
of expressing a piece-rate cost, and it cannot be redefined without dropping it
— which would break the Integration Read API, the External Write API (sql/186),
the portal and both mobile clients, all of which read it today.

So the table is untouched. On a piece-rate job its lines still record hours and
its generated `total_cost` still reports the hourly arithmetic. That value is
simply **not** the job's labour cost. The commercial agreement lives on the
parent `work_tasks` row, where "one job, one agreement" belongs.

## Hours on a piece-rate job

Hours stay recordable and are **preserved as operational history** — who worked,
how many, for how long. They never drive the cost. Both clients surface them
under "Hours worked (optional)" with an explicit note, and both expose
`hoursAreOperationalOnly` (true when a piece-rate job has hours > 0) so no
report can mistake them for a cost basis.

An hourly *rate* is dropped from labour lines saved against a piece-rate job —
carrying one would create a second, contradictory cost.

## The arithmetic

```
labour cost = piece_vine_count × piece_rate_per_vine
    2,238 vines × $1.27 = $2,842.26
```

Rounded to whole cents, **half away from zero** — the same rule as the
database's `round(numeric, 2)`. `piece_rate_per_vine` is `numeric(12,4)` and
`piece_rate_total_cost` is `numeric(14,2)`, so money never drifts through binary
floating point.

Cost per hectare is `cost ÷ hectares`, and is **null** whenever no positive area
is known — an unknown denominator must never render as a number.

Negative inputs are clamped to zero rather than producing a negative bill, and
the database rejects them outright via check constraints.

## Historical protection

A piece-rate job must keep the commercial calculation it was created with. If
someone edits a row's vine count six months later, a completed job must **not**
silently re-cost.

- The vine **quantity** is snapshotted onto the task (`piece_vine_count`) at
  create/update time.
- The **per-row detail** behind that quantity is snapshotted into
  `work_task_piece_rate_rows`.
- `piece_rate_total_cost` is generated from the snapshot columns **only**. It
  never reads `paddocks.rows`, so no vineyard-setup edit can change a historical
  job's value.

`work_task_piece_rate_rows` is **not** a second row-selection system. Row
selection for pruning stays exactly where it is (`pruning_row_segments`,
sql/112). Clients derive the snapshot **from** that existing selection — the
operator never selects rows twice and never types a total the app already knows.

## Where the vine count comes from

Every row calculates its own vine count automatically from data the app already
holds — the row's mapped `startPoint`/`endPoint` and the BLOCK's vine spacing.
Nobody types a quantity to get a piece-rate cost (see
`docs/paddock-geometry-spec.md` §2 and §5.3):

```
rowLengthMetres       = distance(row.startPoint, row.endPoint)   per row, never the block average
rowCalculatedVines    = round(rowLengthMetres / vineSpacing)     half away from zero
rowEffectiveVineCount = rows[].vineCountOverride ?? rowCalculatedVines
piece_vine_count      = Σ rowEffectiveVineCount over the selected rows
```

A 250 m row at 1.5 m spacing is `166.67` → **167 vines**.

- The manual override is OPTIONAL and only ever means "the calculated number is
  wrong for this row". `0` or negative is not an override and falls back to the
  calculated value.
- No vine spacing, or no usable row geometry → the count is **unavailable**
  (`—`), never `0`.
- Independent of the block-level `paddocks.vine_count_override`, which remains
  the block total used for water/spray/fertiliser/yield estimates.

So the operator's whole job is: select the rows, choose Piece Rate, enter the
agreed rate per vine.

## Schema

### `work_tasks` (added columns)

| column | type | notes |
| --- | --- | --- |
| `costing_method` | text, not null, default `'hourly'` | `'hourly'` \| `'piece_rate'`. Check-constrained. Every legacy row defaults to `'hourly'`. |
| `piece_rate_per_vine` | numeric(12,4) null | Agreed price per vine, e.g. `1.2700`. Historical — never rewritten by later vineyard edits. `>= 0`. |
| `piece_vine_count` | integer null | HISTORICAL SNAPSHOT of the quantity the job was costed on. `>= 0`. |
| `piece_rate_total_cost` | numeric(14,2), **generated** | `round(piece_vine_count × piece_rate_per_vine, 2)` when `costing_method = 'piece_rate'`, else `NULL`. |

Indexed on `costing_method`.

### `work_task_piece_rate_rows`

Mirrors `work_task_paddocks` (sql/051) exactly for RLS, soft delete and sync.

| column | type | notes |
| --- | --- | --- |
| `id` | uuid PK | |
| `work_task_id` | uuid FK → work_tasks | cascade delete |
| `vineyard_id` | uuid FK → vineyards | cascade delete |
| `paddock_id` | uuid FK → paddocks | cascade delete |
| `paddock_row_id` | uuid null | Logical reference into `paddocks.rows[].id` (no FK target exists — same pattern as `pruning_row_segments.paddock_row_id`). NULL for manual/fallback rows with no mapped geometry. |
| `row_number` | integer null | Display snapshot of the row number **at costing time**. |
| `vine_count` | integer not null, default 0 | THE snapshotted quantity this row was paid on. `>= 0`. Frozen history. |
| audit / sync | | `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`, `client_updated_at`, `sync_version` |

- One **active** row per `(work_task_id, paddock_id, paddock_row_id)`;
  soft-deleted rows are excluded, so a row can be removed and re-added while the
  job is still being edited. Manual rows (no `paddock_row_id`) are keyed on
  `(work_task_id, paddock_id, row_number)` instead.
- RLS: members read; owner/manager/supervisor/operator insert and update.
  **Client hard delete is blocked** (`using (false)`).
- Soft delete via `public.soft_delete_work_task_piece_rate_row(uuid)`
  (owner/manager/supervisor only).

### `paddocks.rows[].vineCountOverride`

Optional positive integer on the existing JSONB array — no schema change. See
`docs/paddock-geometry-spec.md` §2 for the canonical element shape and the
row-identity preservation rule.

## Validation (both clients, identical messages)

| condition | message |
| --- | --- |
| rate missing, non-finite, or ≤ 0 | `Enter the agreed rate per vine.` |
| rate > 1,000 | `That rate per vine looks too high — check the number.` |
| vine count missing or ≤ 0 | `Select the rows this job covers so the vine count can be calculated.` |
| vine count > 10,000,000 | `That vine count looks too high — check the selected rows.` |

Every problem is returned at once so the form can mark each field. The
boundaries themselves (1,000 / 10,000,000) are acceptable values.

## Formatting parity

| value | rendering |
| --- | --- |
| money total | `$2,842.26` — grouped, always 2 decimals |
| agreed rate | `$1.27` — always 2 decimals |
| vine quantity | `2,238` — grouped |

## Implementation

| | iOS | Android |
| --- | --- | --- |
| costing core | `ios/VineTrack/LegacyImported/Models/PieceRateCosting.swift` | `.../data/model/PieceRateCosting.kt` |
| per-row vine count | `.../Utilities/PaddockRowVineCount.swift` | `.../data/model/PaddockRowVineCount.kt` |
| row vine-count UI | Edit Block → "Vines Per Row" + `RowVineCountEditorSheet.swift` | Edit Block → "Vines Per Row" card + row dialog |
| row-count parity tests | `ios/VineTrackTests/RowVineCountTests.swift` | `.../data/RowVineCountTest.kt` |
| snapshot repository | `.../Repositories/WorkTaskPieceRateRowRepository.swift` | `.../data/` work task repository |
| tracker UI | Record Pruning sheet | `.../ui/screens/PruningTrackerScreen.kt` |
| parity tests | `ios/VineTrackTests/PieceRateCostingTests.swift` | `.../data/PieceRateCostingTest.kt` |
| effective-cost parity tests | `ios/VineTrackTests/EffectiveLabourCostTests.swift` | `.../data/EffectiveLabourCostTest.kt` |
| database tests | `sql/tests/188_piece_rate_pruning_costing_tests.sql` and `sql/tests/189_effective_work_task_labour_cost_tests.sql` | — |

Both unit suites assert the **same fixtures**, so a divergence between the
platforms fails a build. The database suite is rollback-only and safe to run
against the shared project.

## Portal / API consumers — checklist

- [ ] **Read the value the backend already resolved**: `effective_labour_cost`
      on a work task, `labour_cost` on a pruning activity, or
      `activity_labour_cost` in the export view. Deriving
      `labour_hours × hourly_rate` yourself is now wrong.
- [ ] Read `costing_method` and branch on it. Treat any unrecognised value as
      `'hourly'`.
- [ ] For `'piece_rate'`, read `piece_rate_total_cost`. Do not recompute it from
      `paddocks.rows`.
- [ ] Never add `Σ work_task_labour_lines.total_cost` to
      `piece_rate_total_cost`.
- [ ] Never fabricate a labour line to represent a piece-rate job. A piece-rate
      task with zero labour lines is valid and fully represented by the API.
- [ ] Render an absent cost as "not specified", not `$0.00`.
- [ ] Show hours on a piece-rate job as operational history only.
- [ ] Preserve `paddocks.rows[].id` and `vineCountOverride` on any write to
      `paddocks.rows`.
