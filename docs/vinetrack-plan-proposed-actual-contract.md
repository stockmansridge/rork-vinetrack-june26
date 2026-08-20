# VineTrack Plan → Proposed → Actual contract (Stage 5B)

**Owner:** Rork/VineTrack mobile owns this contract end-to-end (schema, guards,
mobile writers). **Lovable (web portal) CONSUMES it** and must not invent a
competing representation, add columns, or bypass the rules below.

Applied by `sql/201_spray_job_plan_provenance.sql`.
Verified by `sql/tests/201_spray_job_plan_provenance_tests.sql` (rollback-only),
`ios/VineTrackTests/SprayJobPlanProvenanceTests.swift` and
`android-vinetrack/app/src/test/java/com/rork/vinetrack/data/PlanSprayJobProvenanceTest.kt`.

---

## 1. The chain

```text
resistance_plans                    PLANNED SEASON (sql/196, document)
  └─ positions[] (JSONB)            position id = positions[].id (stable text)
        │  0..N
        ▼
spray_jobs                          PROPOSED work (sql/032 + sql/201 provenance)
        │  0..N (sql/033)
        ▼
spray_records                       ACTUAL completed applications
```

* One plan position → **0..N spray jobs** (multi-block / staged execution).
  There is deliberately **no uniqueness constraint** on
  `(resistance_plan_id, resistance_position_id)`.
* One spray job → **at most one** plan position (single columns).
* One spray job → 0..N spray records via `spray_records.spray_job_id`
  (sql/033; the record's vineyard must match the job's — existing trigger).
* Identifiers: `resistance_plans.id` (uuid), `resistance_plans.positions[].id`
  (stable **text**, client-generated, unique within the plan),
  `spray_jobs.id` (uuid, client-minted), `spray_records.id` (uuid).

## 2. Columns added to `spray_jobs` (sql/201, additive)

| Column | Type | Nullable | Meaning |
|---|---|---|---|
| `resistance_plan_id` | `uuid` | yes | The `resistance_plans.id` this job was created from. **No FK by design** (see §4). |
| `resistance_position_id` | `text` | yes | The `positions[].id` inside the plan document this job executes. |
| `resistance_position_snapshot` | `jsonb` | yes | The sql/196 position object **frozen verbatim at creation** — original planned intent. |
| `resistance_plan_source_revision` | `bigint` | yes | The plan's sql/198 `server_revision` the creating client had synced when it froze the snapshot. `NULL` when the plan had never synced (offline draft) — legitimate, never faked. |

**Shape constraint** `spray_jobs_resistance_link_shape` (all-or-nothing):

* Unlinked job → **all four columns NULL**. Every pre-5B job remains valid.
* Linked job → `resistance_plan_id` set **and** non-empty
  `resistance_position_id` **and** `resistance_position_snapshot` is a JSON
  **object whose own `id` equals `resistance_position_id`**.
  `resistance_plan_source_revision` is optional either way (only meaningful
  when linked).

Index: `idx_spray_jobs_resistance_plan` on
`(resistance_plan_id, resistance_position_id) where resistance_plan_id is not null`.

## 3. The snapshot freezes ORIGINAL INTENT — never verdicts

`resistance_position_snapshot` is the sql/196 position document, byte-shape
identical to what both mobile clients serialise:

```json
{
  "id": "pos-1",
  "products": [
    {
      "id": "prod-1",
      "group_codes": ["3"],
      "source": "group" | "saved_chemical",
      "saved_chemical_id": "…optional…",
      "product_name": "…optional…",
      "chemical_availability": "…optional…",
      "registered_for_planned_disease": true | false | null
    }
  ],
  "target_date_epoch_ms": 0,
  "growth_stage": "…optional…",
  "note": "…optional…"
}
```

Rules:

* **Never derive historical job intent from the current plan position.** A
  manager editing position P3 from FRAC 3 to FRAC 11 must not change what an
  existing job created from P3 displays — that job still shows FRAC 3.
* **Never snapshot resistance verdicts** ("Good fit", warnings, counters).
  Same rule as sql/196: a verdict is a function of plan + actual history +
  ruleset, two of which keep changing.
* When re-linking a not-yet-completed job to a different position, freeze the
  NEW position's current document — never patch fields piecemeal.

## 4. Why `resistance_plan_id` has no foreign key

1. sql/196 T22 pins that **nothing holds an FK into `resistance_plans`** —
   planning data never grows a cascade path into operational data.
2. **Offline ordering:** a plan can be authored offline, a job created from
   one of its positions offline, and the JOB may reach the server BEFORE the
   plan. An FK would reject the job and lose the linkage.

The guards instead:

* **Write-time trigger** (`spray_jobs_validate_plan_provenance_trg`,
  SECURITY DEFINER): if the plan row exists, its vineyard must equal the
  job's vineyard, else the write is rejected. If the plan row does not exist
  yet, the write is accepted as a *pending* link.
* **Resolution always joins on vineyard equality**, so a pending link whose
  plan later lands in a different vineyard is permanently inert — it never
  resolves and never counts toward progress.

Link state is queryable:

```sql
select public.spray_job_resistance_link_state(<spray_job_id>);
-- 'none' | 'pending_plan' | 'linked' | 'cross_vineyard_invalid'
```

## 5. Completed provenance is immutable

* Before completion, a proposed job may be re-linked or unlinked
  (owner/manager RLS applies).
* The moment **any live `spray_records` row references the job**
  (`spray_job_id`, `deleted_at is null`), the four provenance columns are
  **frozen** — trigger `spray_jobs_freeze_completed_provenance_trg` rejects
  any change, including clearing them. Normal edits (name, notes, status,
  chemical_lines, equipment) remain allowed.

## 6. Progress is DERIVED — never written back into the plan

Creating or completing jobs **must not** modify `resistance_plans` and must
not bump its sql/198 `server_revision` (a manager edits the plan while
operators execute jobs, without manufactured revision conflicts).

Derive progress with (SECURITY INVOKER — RLS applies):

```sql
select * from public.resistance_position_spray_job_ids(<plan_id>, '<position_id>');
-- setof uuid: live, same-vineyard jobs linked to that position

select * from public.resistance_position_coverage(<plan_id>, '<position_id>');
-- spray_job_count integer
-- proposed_paddock_ids uuid[]   ← union of spray_job_paddocks of linked jobs
-- completed_block_ids uuid[]    ← union of spray_records.block_ids (sql/195,
--                                 derived from application_blocks) of live
--                                 records whose spray_job_id is a linked job
```

Multi-block partial execution falls out naturally: a position covering blocks
A+B with job 1 completed on A and job 2 still proposed reports
`proposed {A,B}` / `completed {A}`.

## 7. Deviation ≠ compliance

* **Plan deviation** — the job's/record's proposed or actual chemistry differs
  from the frozen `resistance_position_snapshot`. Display it; never block it.
* **Resistance compliance** — evaluated only by the Resistance Engine against
  CURRENT history. A job created from a compliant plan must still get the
  normal Live Resistance Check later; plan compliance at planning time
  guarantees nothing. A different FRAC group can be a deviation while being
  perfectly compliant.

## 8. What mobile writes (reference behaviour)

"Create Spray Job" on a Resistance Planner position (both platforms,
owner/manager only — matches `spray_jobs` INSERT RLS):

```json
{
  "id": "<client-minted uuid>",
  "vineyard_id": "<vineyard>",
  "name": "Powdery Mildew 2026/27 — Spray 4",
  "is_template": false,
  "status": "planned",
  "target": "Powdery Mildew",
  "notes": "<position note, if any>",
  "chemical_lines": [
    { "chemical_id": "<saved_chemicals.id if chosen>", "name": "Talendo",
      "notes": "Planned FRAC 3" }
  ],
  "resistance_plan_id": "<plan id>",
  "resistance_position_id": "pos-4",
  "resistance_position_snapshot": { …verbatim position… },
  "resistance_plan_source_revision": 7,
  "created_by": "<user>"
}
```

plus `spray_job_paddocks` rows for the plan's blocks (proposed coverage).

* Prefill carries **only what the plan genuinely knows**: blocks,
  disease/target, planned FRAC group/combination, optional selected product.
  **Never invented:** carrier volume, rates, water. The job stays fully
  editable.
* Offline: the entire insert (including provenance and paddock links) rides
  ONE queued create marker keyed by the client-minted job id, so a retried
  replay is idempotent (duplicate ⇒ already synced) and the link survives any
  sync ordering — including the job landing before its offline-created plan.
* Completion: a record created from a job carries
  `spray_records.spray_job_id = job.id` in the create/upsert itself. The job
  row must exist server-side first (sql/033 validates existence + vineyard);
  mobile replays job creates before record creates for that reason.

## 9. What Lovable MUST and MUST NOT do

**MUST**

* Populate all four provenance fields together when creating a job from a
  position; freeze the position verbatim (§3).
* Keep `spray_records.spray_job_id` set on completions it creates from a job.
* Read original intent from the snapshot, current standing from the engine,
  and progress from the two derived functions (§6).
* Show "From Resistance Plan" context (plan, position, original intended
  FRAC/combination) on linked jobs, and show deviation clearly when the
  proposed chemical differs — without blocking the change.
* Treat legacy jobs with NULL provenance as fully valid.

**MUST NOT**

* Add an FK to `resistance_plans`, a uniqueness constraint on
  plan+position, or any progress/status column on `resistance_plans`.
* Re-derive or "refresh" a job's snapshot after plan edits.
* Rewrite provenance on a job that has a live linked record (the trigger will
  reject it anyway).
* Bump the plan's `server_revision` (or touch the plan at all) from job or
  record activity.
* Resolve or display a `cross_vineyard_invalid` link as if it were linked.

## 10. Status vocabulary

`spray_jobs.status` stays sql/032:
`draft | planned | in_progress | completed | cancelled | archived`.
Mobile writes `planned` at creation and does not manage transitions; the
portal owns status flow. Archival stays `archive_spray_job` (soft delete);
archived jobs drop out of the resolution functions via `deleted_at`.
