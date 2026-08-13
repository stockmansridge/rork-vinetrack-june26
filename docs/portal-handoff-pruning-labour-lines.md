# Portal handoff — Pruning Activity labour lines (SQL 190)

**Status:** shared contract final and UNCHANGED. Migration applied, tests green,
iOS + Android shipped, `vinetrack-api` **deployed to production (version 11,
ACTIVE, 2026-08-13)**. Ready for the portal to adopt.
**Source of truth:** Rork/VineTrack mobile. Lovable CONSUMES this contract and
must not create or modify any of the objects below.

> Nothing in sections 1–11 changed while mobile was built. The contract you
> reviewed is the contract that shipped — same table, same columns, same RPC
> signature, same precedence, same fixtures.

---

## 1. What changed and why

Work Tasks have supported N labour lines since SQL 050. Pruning did not: its
labour was denormalised onto the parent activity as three scalar columns
(`worker_or_crew`, `labour_hours`, `hourly_rate`), so a pruning day worked by
two contractors on different rates could not be recorded at all.

SQL 190 adds `public.pruning_activity_labour_lines`, which **mirrors
`work_task_labour_lines` column for column**. It is not a second labour system —
same field names, same semantics, same generated arithmetic, same soft-delete
rule — so the portal can reuse its existing Work Task labour-line editor and
validation almost verbatim.

## 2. Ownership model — read this before writing any code

**Labour is PRUNING-OWNED. A linked Work Task never gets a copy; it resolves
through to the same rows.**

The pruning activity and its linked Work Task are the same piece of work, so the
labour exists in exactly ONE place and both objects report the SAME number.
Never add a task's labour to an activity's.

Pruning activity effective cost — strict precedence, never addition:

1. linked **piece-rate** task → the task's `piece_rate_total_cost`
2. the activity's **own rated labour lines** ← new
3. the linked hourly task's rated labour lines (SQL 189)
4. the activity's legacy `labour_hours × hourly_rate` (SQL 166)

Work task effective cost:

1. `piece_rate` → `piece_rate_total_cost`
2. its own rated labour lines
3. the rated labour lines of the pruning activity linked to it ← new

Rung 3 on the task side only ever turns a NULL into a value, so no pre-190
record changes value.

## 3. Table

`public.pruning_activity_labour_lines`

| Column | Notes |
| --- | --- |
| `id` | uuid PK, **client-generated** — the offline idempotency key |
| `pruning_activity_id` | FK → `pruning_activities`, cascade |
| `vineyard_id` | FK → `vineyards`, cascade. Always the ACTIVITY's vineyard |
| `work_date` | date |
| `worker_type_id` | uuid, optional link to the worker-type catalogue |
| `worker_type` | text — a CATEGORY ("Contractor"), never a person |
| `worker_count` | integer |
| `hours_per_worker` | double precision |
| `hourly_rate` | double precision, nullable |
| `total_hours` | **generated** `worker_count × hours_per_worker` |
| `total_cost` | **generated** `worker_count × hours_per_worker × coalesce(hourly_rate,0)` |
| `notes` | text |
| `line_index` | integer, stable display order |
| `deleted_at`, `client_updated_at`, `sync_version`, `created_by`, `updated_by`, `created_at`, `updated_at` | standard sync identity |

RLS is identical to `work_task_labour_lines`: members read, owner/manager/
supervisor/operator write, **nobody hard-deletes**. Soft delete via
`soft_delete_pruning_activity_labour_line(uuid)` (owner/manager/supervisor).

## 4. Hours vs cost — two deliberately different rules

- **Hours** sum EVERY active line, including unrated ones. An unpriced line is
  still work that was done and still drives vines-per-hour.
- **Cost** sums only lines with a non-null `hourly_rate`. `total_cost` is
  generated with `coalesce(hourly_rate, 0)`, so summing blindly would turn
  "nobody entered a rate" into `$0.00`. Unknown is **NULL**, never `0`.

Do not re-implement either rule — call the helpers.

## 5. Read path

`public.pruning_activity_json(activity_id, include_segments)` — unchanged
signature, every pre-190 key preserved. Added:

- `activity.labour_lines` — array (see `pruning_activity_labour_lines_json`);
  `total_cost` is NULL, not `0.00`, on an unrated line
- `activity.labour_line_count`
- `activity.total_labour_hours`, `activity.labour_hours_source`
- `totals.labour_hours` — now the SUM of the activity's lines when it owns any,
  and byte-for-byte the previous value otherwise
- `totals.total_labour_hours`, `totals.labour_hours_source`,
  `totals.labour_line_count`, `totals.vines_per_labour_hour`
- `labour_cost_source` gains a `pruning_labour_lines` value

`activity.labour_hours` and `activity.hourly_rate` are still reported **as
recorded** so a legacy single-crew activity round-trips unchanged.

Helper functions (all `authenticated` + `service_role`):

- `pruning_activity_labour_lines_json(uuid)`
- `pruning_activity_labour_line_hours(uuid)` / `_cost(uuid)` / `_count(uuid)`
- `pruning_activity_effective_labour_hours(uuid)` / `pruning_activity_labour_hours_source(uuid)`
- `pruning_activity_effective_labour_cost(uuid)` / `pruning_activity_labour_cost_source(uuid)`
- `work_task_pruning_labour_line_cost(uuid)`

## 6. Write path

```sql
select public.save_pruning_activity_labour_lines(
  '<activity_id>'::uuid,
  '[{"id":"<client uuid>","work_date":"2026-08-03","worker_type":"Pruner",
     "worker_count":2,"hours_per_worker":8,"hourly_rate":30,"line_index":0}]'::jsonb,
  now()
);
```

**Desired-state**, single transaction, same contract shape as
`update_pruning_activity`:

- lines present are upserted on their **client id**
- lines absent are **soft-deleted**
- a re-sent soft-deleted line is **restored**
- replaying the same payload is idempotent (this is what makes offline replay
  deterministic)
- a client id already owned by another activity is never re-parented

Returns the canonical set plus `total_labour_hours`, `labour_cost` and
`labour_cost_source`, so the caller can replace its local set wholesale.

Plain REST insert/update against the table also works (same RLS shape as work
task labour lines) — but the RPC is the recommended path because only it gives
you desired-state deletion in one transaction.

## 7. Reporting rules

- Activity totals = SUM of the activity's labour lines. Never per block.
- `pruning_activity_allocation_export`: `activity_labour_hours`,
  `activity_labour_cost`, `activity_labour_cost_source` and the new
  `activity_labour_line_count` appear on the **PRIMARY allocation row only**, so
  summing a CSV counts the activity once no matter how many blocks it covers.
- `allocation_share_labour_cost` still splits that ONE figure by row-equivalent
  share with the rounding residual on the primary row, so it reconciles exactly.
- Skipped and reversed allocations carry no labour.
- Cost/ha and cost/vine must use the aggregate ACTIVITY cost, never a per-block
  or per-line figure.

## 8. Legacy activities

Not backfilled. `worker_or_crew`, `labour_hours` and `hourly_rate` are untouched,
and an activity with no lines resolves exactly as it does today. Converting a
legacy activity to lines is a USER action in the editor — never an automatic
rewrite — because `worker_or_crew` is free text ("Dave + 2 casuals") and the
database cannot honestly split it into a worker type and a crew size.

When rendering: if `labour_line_count = 0`, show the legacy crew/hours/rate
exactly as now. Offer "convert to labour lines" as an explicit action.

## 9. Do NOT

- create a parallel pruning labour table
- copy pruning labour into `work_task_labour_lines`
- add a task's labour cost to an activity's
- create a synthetic labour line, worker type or hours for a piece-rate job
- sum `total_cost` directly (use the cost helper — it skips unrated lines)
- apportion labour across blocks

## 10. Sequence

1. ~~Apply `sql/190_pruning_activity_labour_lines.sql` (needs 166, 188, 189).~~ **Done.**
2. ~~Run `sql/tests/190_pruning_activity_labour_lines_tests.sql`.~~ **Done — all passed.**
3. ~~Redeploy `supabase/functions/vinetrack-api`.~~ **Done — production version 11.**
4. ~~Mobile ships the Labour lines editor on iOS and Android.~~ **Done.**
5. **Portal adopts this contract.** ← you are here

### What `vinetrack-api` now returns on a pruning activity

Added, additive only — every pre-190 key keeps its name, type and value:

- `total_labour_hours` — the EFFECTIVE hours (own lines when any, else the
  legacy scalar). Counts unrated lines.
- `labour_hours_source` — `labour_lines` | `activity_hours` | null
- `labour_line_count`
- `labour_lines[]` — requires `labour:read`. `worker_type` is a CATEGORY, never
  a person. `hourly_rate` and `total_cost` appear only with `costs:read`, and
  `total_cost` is **null, not 0.00**, on an unrated line.
- `labour_cost_source` gains `pruning_labour_lines` (the activity's OWN lines)
  alongside the existing `labour_lines` (a linked task's).
- `labour_hours` is still reported **as recorded**, so a legacy single-crew
  activity round-trips unchanged.
- `vines_per_labour_hour` is now derived from `total_labour_hours`, so an
  activity is measured on the same hours it is costed on.

Two behaviours worth coding against explicitly:

- **Scope-gated keys are ABSENT, not empty.** Without `labour:read` the
  `labour_lines` and `crew` keys do not appear at all — do not read a missing
  `labour_lines` as "this activity has no labour". Use `labour_line_count`,
  which is always present, to distinguish "none" from "not permitted". Likewise
  `hourly_rate` and `total_cost` are absent from each line without `costs:read`.
- **Unrated lines stop the chain — they never fall through.** An activity that
  owns labour lines but has priced none of them reports `labour_cost: null` and
  `labour_cost_source: null`. It does NOT fall back to a linked task's lines or
  the legacy scalar pair: those lines ARE its labour record, so falling through
  would report someone else's money. Render this as "not specified", never
  `$0.00`. Its `total_labour_hours` is still populated.

## 11. Shared regression fixtures

Both mobile suites and the SQL suite assert these exact numbers:

- one line: 2 × 8 h @ $30 → **16 h, $480**
- multiple lines: 16 h + 6 h → **22 h, $690**
- three-block activity with the same lines → still **22 h, $690** (never $2,070)
- linked hourly task reports the SAME **$480**, never $960
- linked piece-rate task 250 × $0.55 → **$137.50**, never $617.50
- unrated line: hours count, cost is **NULL**, never $0.00
- legacy activity 7.5 h × $32 → **$240**, unchanged

## 12. Mobile implementation notes (for reference, not obligations)

Both clients now treat labour as pruning-owned, which is what the portal should
do too:

- The Pruning Activity editor has ONE labour surface, writing
  `pruning_activity_labour_lines`. It is not a second editor next to the Work
  Task one — the Work Task card in that screen is now link management only.
- Piece rate stays a Work Task property (sql/188). Choosing it writes
  `work_tasks.costing_method` and the agreed rate; any hours captured alongside
  it are saved as an **unrated** pruning labour line. No synthetic "piece rate"
  labour line is ever created.
- A legacy activity renders its original crew/hours/rate exactly as recorded,
  with an explicit "Convert to labour lines" action. Never automatic.
- Saving goes through `save_pruning_activity_labour_lines` with the COMPLETE
  set every time — add, edit and remove all replay through the same idempotent
  call. An empty array is a real instruction ("no labour lines"), not a no-op.
- Both suites assert the section 11 fixtures:
  `ios/VineTrackTests/PruningActivityLabourLineTests.swift` and
  `android-vinetrack/.../data/PruningActivityLabourLineTest.kt`.
