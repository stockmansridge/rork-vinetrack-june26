# VineTrack Integration Platform — Stage 3C Completion Report

Remaining operational read API: Work Tasks, Pruning, Irrigation, Growth
Stages, Yield, Pins. Built on the live Stage 3A/3B gateway, SQL 172–174 and
the verified explicit-grant security chain. Read-only; no write API, no
webhook delivery, no Lovable UI, no iOS/Android UI changes.

Supabase project: `tbafuqwruefgkbyxrxyb`.

---

## 1. Files changed

| File | Change |
| --- | --- |
| `supabase/functions/vinetrack-api/index.ts` | 12 new routes (6 resources × collection + detail), mappers, batch loaders, filters; Stage 3A/3B code untouched in behaviour |
| `sql/175_integration_api_stage3c_indexes.sql` | NEW — additive support indexes (see §17) |
| `sql/tests/175_integration_api_stage3c_indexes_tests.sql` | NEW — read-only index verification |
| `scripts/test-vinetrack-api.sh` | Stage 3C sections (~55 new checks) + new fixture env vars |
| `docs/vinetrack-api-v1.md` | All 6 new resources: shapes, scopes, sensitive matrix, filters, lifecycle, units, examples |
| `docs/vinetrack-api-openapi.yaml` | All 12 new routes + schemas (now covers 27 routes) |
| `docs/integration-platform-stage3c-report.md` | This report |

No SQL 172–174 object was modified. No mobile code was touched.

## 2. SQL migration added

`sql/175_integration_api_stage3c_indexes.sql` — strictly additive,
idempotent (`create index if not exists`), production-safe, tested by
`sql/tests/175`. Apply via the Supabase SQL editor, then run the test file.

## 3. Canonical source audit

Audited directly from the migrations before any code was written:

| Resource | Canonical tables | Children / related | Vineyard link | Block link | User link | Lifecycle | Units / dates |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Work Tasks | `work_tasks` (sql/014 + 050: start/end_date, area_ha, description, status) | `work_task_paddocks` (051), `work_task_labour_lines` (050, generated total_hours/total_cost), `work_task_machine_lines` (103), `trips.work_task_id` (102), `work_task_types` (052, catalogue only) | `vineyard_id` NOT NULL | multi via join table; legacy `paddock_id`+`paddock_name` snapshot | `created_by`; machine lines `operator_user_id` | soft-delete `deleted_at`; `is_archived`, `is_finalized` flags | `date`/`start_date`/`end_date` timestamptz; `duration_hours`; `area_ha` |
| Pruning | `pruning_activities` (166, parent) | `pruning_entries` (109/166, per-block allocations), `pruning_row_segments` (109, quarter grid), season assignment (161) | `vineyard_id` NOT NULL | per allocation `paddock_id` | `worker_or_crew` text snapshot; `created_by` | REVERSAL: `deleted_at` on activity + quarters unclaimed via RPC only | `entry_date` date; `labour_hours` numeric; `hourly_rate`; server-attributed vines/row-equivalents |
| Irrigation | `irrigation_sessions` (125 + 130 times + 142 import values) | `irrigation_session_blocks` (frozen per-block metrics), `irrigation_valves`/`irrigation_systems` (names) | `vineyard_id` NOT NULL | per session-block `block_id` | `created_by` only — no operator identity | `deleted_at`; `status` ∈ 8 values incl. `reversed` + `reversed_by_session_id` | canonical litres / L/h / mm / whole minutes; `session_date` date; `vintage_year` frozen |
| Growth Stages | `growth_stage_records` (055, canonical; legacy pins mirrored in) | `v_growth_stage_observations` view (transition), storage bucket `growth-stage-photos` | `vineyard_id` NOT NULL | `paddock_id` nullable | `created_by` + `recorded_by_name` snapshot | soft-delete `deleted_at` | `observed_at` timestamptz; `stage_code` stable E-L code |
| Yield | `historical_yield_records` (014) | `block_results` jsonb (camelCase iOS Codable); `yield_estimation_sessions` (working sampling data — NOT exposed) | `vineyard_id` NOT NULL | inside jsonb `paddockId` | `created_by` | soft-delete `deleted_at` | `year` int, `season` text, `archived_at`; tonnes / hectares / grams |
| Pins | `pins` (004 + 013 photo_path + 035 + 041 snapping + 169 composer + 170 custom types) | `pin_row_segments` (169), `pin_placements` view (171, canonical resolver), `vineyard_custom_pin_types` (170) | `vineyard_id` NOT NULL | `paddock_id` + placement resolution | `created_by`, `assigned_user_id`, `completed_by`(+`_user_id`) | soft-delete `deleted_at`; status/is_completed | `driving_row_number` numeric (path e.g. 19.5), `pin_side`, `along_row_distance_m` |

No operational table was restructured for the API.

## 4. Routes

All under the existing `vinetrack-api` function; GET only:

- `GET /v1/work-tasks?vineyard_id=` · `GET /v1/work-tasks/{work_task_id}`
- `GET /v1/pruning?vineyard_id=` · `GET /v1/pruning/{pruning_activity_id}`
- `GET /v1/irrigation-records?vineyard_id=` · `GET /v1/irrigation-records/{irrigation_record_id}`
- `GET /v1/growth-stages?vineyard_id=` · `GET /v1/growth-stages/{growth_stage_id}`
- `GET /v1/yield-records?vineyard_id=` · `GET /v1/yield-records/{yield_record_id}`
- `GET /v1/pins?vineyard_id=` · `GET /v1/pins/{pin_id}`

Every route runs the full chain: valid key → active integration →
active/unexpired key → resource scope → explicit active vineyard grant.
Collections require `vineyard_id` (no cross-vineyard collections). Detail
routes resolve the record's actual vineyard server-side before validating —
the caller never establishes ownership. Cross-vineyard ids return
`resource_not_found` (non-disclosing).

## 5. Scope mapping

| Route family | Scope |
| --- | --- |
| work-tasks | `work_tasks:read` |
| pruning | `pruning:read` |
| irrigation-records | `irrigation:read` |
| growth-stages | `growth_stages:read` |
| yield-records | `yield:read` |
| pins | `pins:read` |

All six already existed in the SQL 172 scope catalogue — no scope migration
was needed. `costs:read` / `labour:read` remain field-gating only and never
grant resource access alone (harness-tested).

## 6. Work Tasks schema/mapping

External field → canonical source → transformation → sensitivity:

| External | Source | Transform | Sensitivity |
| --- | --- | --- | --- |
| `task_type` | `work_tasks.task_type` | trimmed, '' → null (no canonical title column exists — task_type IS the label; no fake `title` invented) | — |
| `status` | `work_tasks.status` | as stored (free text, nullable) | — |
| `date`, `start_date`, `end_date` | same columns | none | — |
| `duration_hours`, `area_ha`, `description`, `notes` | same columns | notes '' → null | — |
| `blocks[] {id,name}` | `work_task_paddocks` (live rows) → names via `paddocks`; fallback legacy `paddock_id` (+`paddock_name` snapshot) | batch-loaded (no N+1) | — |
| `is_archived`, `is_finalized` | flags | none | — |
| detail `labour_lines[]` | `work_task_labour_lines` | worker_type is a CATEGORY, not identity → ungated; line row ids NOT exposed | `hourly_rate`, `total_cost` → costs:read |
| detail `total_labour_hours` | sum of generated `total_hours` | derived, documented | — |
| detail `machine_lines[]` | `work_task_machine_lines` | `equipment_id` resolved to canonical `vineyard_machines.id` via equipment_source (`vineyard_machine` direct, `tractor` via legacy backfill map); name = snapshot else resolved | `fuel_cost`/`hourly_rate`/`total_cost` → costs:read; `operator` → labour:read |
| detail `trip_ids[]` | `trips.work_task_id` | ids only (trips are a separate scoped resource) | — |

No worker contact data exists on any work-task table; none is exposed.

## 7. Pruning schema/mapping

Served from `pruning_activities` — actual pruning activity (one crew/day
across ≥1 blocks), NOT season configuration:

| External | Source | Transform | Sensitivity |
| --- | --- | --- | --- |
| `date` | `entry_date` | none | — |
| `pruning_method`, `season_year`, `vintage_year`, `started_at`, `ended_at` | activity columns | none | — |
| `labour_hours` | activity column (stored ONCE, never apportioned) | none | — |
| `vines_pruned` | `total_estimated_vines` (server-attributed rollup) | none | — |
| `row_equivalents` | `total_row_equivalents` (quarters ÷ 4) | round 3dp | — |
| `quarters_completed` | `total_quarters` | none | — |
| `vines_per_labour_hour` | derived | `vines_pruned ÷ labour_hours`, 1dp; null when hours absent | — |
| `blocks[] {block_id, block_name, row_equivalents, vines_pruned}` | live `pruning_entries` allocations + `paddocks` names | batch-loaded | — |
| `block_summary`, `work_task_id`, `notes` | activity columns | '' → null | — |
| `crew` | `worker_or_crew` | trimmed | labour:read |
| `hourly_rate` | activity column | none | costs:read |
| `labour_cost` | derived | `labour_hours × hourly_rate`, 3dp | costs:read |

**Reversal decision (documented per brief §5): reversed activities are
OMITTED from the collection and return 404 by id.** VineTrack's reversal
RPC un-claims the activity's quarters, so its work no longer exists in live
progress — returning it would contradict every in-app total. Reversed
activity can never inflate totals. The internal quarter grid is not
exposed; per-block `row_equivalents` is the stable external measure.

## 8. Irrigation schema/mapping

Served from `irrigation_sessions` + frozen `irrigation_session_blocks`:

| External | Source | Transform | Sensitivity |
| --- | --- | --- | --- |
| `date` | `session_date` | none | — |
| `vintage_year`, `status`, `started_at`→`ended_at` (`finished_at`), `duration_minutes`, `calculation_method`, `source_type` | session columns | none | — |
| `flow_l_per_hour`, `volume_l`, `effective_volume_l`, `efficiency_percent` | `flow_litres_per_hour`, `total_volume_litres`, `effective_volume_litres`, `irrigation_efficiency_percent` | renamed for explicit units; values never recomputed | — |
| `irrigation_system_id`, `valve_id` | session columns | references only — config is not dumped into the record | — |
| `blocks[]` (list) | session_blocks | `allocation_percent`, `volume_l` + names | — |
| `blocks[]` (detail) | session_blocks | adds `effective_volume_l`, `area_ha` (m² ÷ 10000, exact), `vine_count`, `water_l_per_vine`, `water_l_per_ha`, `depth_mm`, `effective_depth_mm` | — |
| detail `system`/`valve` | `irrigation_systems` / `irrigation_valves` | `{id, name(, valve_number)}` display refs | — |

Missing metrics are `null` — never zero (VineTrack's missing-data rule
preserved). No cost or labour fields exist. Note: the in-app feature is
currently gated to system administrators via RLS; the API path is governed
by the integration grant + `irrigation:read` scope instead (service-role
reads with explicit validation), which is the platform's intended
integration access model.

## 9. Growth Stages schema/mapping

Served from `growth_stage_records` (canonical store; the apps mirror
legacy growth pins into it — a not-yet-mirrored legacy pin is a transient
sync state, documented):

| External | Source | Transform | Sensitivity |
| --- | --- | --- | --- |
| `block_id`/`block_name` | `paddock_id` + `paddocks.name` | batch names | — |
| `observed_at`, `stage_code`, `stage_label`, `variety`, `variety_id`, `row_number` | columns | none — `stage_code` is the stable canonical code | — |
| `side` | column | lowercased `left`/`right` (documented normalisation) | — |
| `latitude`/`longitude`, `notes` | columns | notes '' → null | — |
| `recorded_by {user_id, name}` | `created_by` + `recorded_by_name` | minimal identity contract | labour:read |
| `photo_paths` | — | **NOT exposed** (private storage paths); imagery API is a future explicit design | — |

`pin_id` (internal mirror linkage) is not exposed.

## 10. Yield schema/mapping

Served from `historical_yield_records` — recorded season yield history.
In-progress `yield_estimation_sessions` are working sampling data and are
NOT exposed (documented decision):

| External | Source | Transform | Sensitivity |
| --- | --- | --- | --- |
| `season` | `season` | '' → null | — |
| `vintage_year` | `year` | 0 (unset default) → null | — |
| `archived_at`, `total_yield_tonnes`, `total_area_ha`, `notes` | columns | rename hectares → `_ha` | — |
| `yield_tonnes_per_ha` (top level) | derived | `total_yield_tonnes ÷ total_area_ha`, 3dp; null when area = 0 (never invented from unreliable area) | — |
| `blocks[]` | `block_results` jsonb (camelCase) | `paddockId`→`block_id` (lowercased uuid), `areaHectares`→`area_ha`, `yieldTonnes`→`estimated_yield_tonnes`, `yieldPerHectare`→`yield_tonnes_per_ha` (STORED, not derived), `averageBunchWeightGrams`→`average_bunch_weight_g`, `totalVines`→`vine_count`, plus samples/damage/actual fields; non-numeric values → null | — |

No pricing/revenue/destination/variety fields exist canonically — none
invented; `costs:read` gates nothing here today, and any future
grape-sale financials will be costs:read-gated commercial data (documented
in the sensitive matrix).

## 11. Pins schema/mapping

Served from `pins` + the SQL 171 canonical `pin_placements` view (the
server-authoritative resolver — the API never re-derives placement):

| External | Source | Transform | Sensitivity |
| --- | --- | --- | --- |
| `type` | `mode` | `Repairs`→`repairs`, `Growth`→`growth`, `ManualIssue`→`manual_issue` | — |
| `custom_type {id,name}` | `custom_type_id` + `vineyard_custom_pin_types` | batch lookup (includes inactive types for historical pins) | — |
| `category`, `priority`, `title`, `notes`, `growth_stage_code` | columns | '' → null | — |
| `status` | `status` / `is_completed` | canonical stored status wins; legacy pins derive completed/open from is_completed (documented) | — |
| `block_id`/`block_name` | placement `paddock_id`/`paddock_name` (fallback stored `paddock_id`) | — | — |
| `latitude`/`longitude` | columns | raw pin coordinates | — |
| `row.*` | `snapped_to_row`, `driving_row_number`→`path_number` (**exact, e.g. 19.5**), `pin_row_number`→`row_number` (fallback legacy `row_number`), `pin_side`→`side` lowercase (fallback legacy `side`), `along_row_distance_m`, `snapped_latitude/longitude` | snapped identity preserved exactly — never reduced to raw GPS | — |
| `location.*` | placement view: `location_scope`, `location_assignment_basis`, `row_summary`, `location_warning_code` | canonical values passed through | — |
| `due_date`, `work_task_id` (`linked_work_task_id`), `resolved_at` (`completed_at`) | columns | rename | — |
| detail `row_segments[] {row, segment}` | placement `segments` jsonb | validated numeric pairs | — |
| `assigned_to`, `completed_by` | `assigned_user_id`; `completed_by_user_id`+`completed_by` | minimal `{user_id, name}` | labour:read |
| `photo_path` | — | **NOT exposed** (private storage path) | — |

Duplicate-detection diagnostics (sql/036/044 audit machinery) are internal
and not exposed.

## 12. Sensitive-field matrix (Stage 3C additions)

| Resource | costs:read unlocks | labour:read unlocks |
| --- | --- | --- |
| Work task detail | labour line `hourly_rate`/`total_cost`; machine line `fuel_cost`/`hourly_rate`/`total_cost` | machine line `operator` |
| Pruning | `hourly_rate`, `labour_cost` | `crew` |
| Irrigation | — (no such fields exist) | — |
| Growth stages | — | `recorded_by` |
| Yield | — (no financial fields exist today; future ones will be gated) | — |
| Pins | — | `assigned_to`, `completed_by` |

Rules unchanged from 3B: base scope always required; sensitive scopes never
grant resource access alone; gated fields are OMITTED, not nulled. Identity
objects stay minimal (`user_id` + `name`) — no email/phone/address/payroll.

## 13. Lifecycle / deleted / reversed / resolved rules

| Resource | Default collection | By id |
| --- | --- | --- |
| Work tasks | deleted excluded; archived INCLUDED (history, `is_archived` flag) | deleted → 404 |
| Pruning | reversed (deleted_at) EXCLUDED — matches live progress; never inflates totals | reversed → 404 |
| Irrigation | deleted excluded; `status=reversed` excluded from default, retrievable via `?status=reversed` | deleted → 404; reversed OK (explicit status) |
| Growth stages | deleted excluded; observations are permanent history | deleted → 404 |
| Yield | deleted excluded; records are permanent history | deleted → 404 |
| Pins | deleted excluded; resolved (completed) INCLUDED as history, filterable | deleted → 404 |

## 14. Filters

All collections: `vineyard_id` (required), `limit`, `cursor`. Unknown
parameters → `invalid_request` (unchanged policy).

| Resource | Filters | Notes |
| --- | --- | --- |
| work-tasks | `from`/`to` (date), `status`, `task_type`, `block_id` | block matches join-table links OR the legacy single block |
| pruning | `from`/`to` (entry_date), `block_id` | block resolves activity ids via live allocations; no worker filter (privacy — worker is a labour-gated field) |
| irrigation-records | `from`/`to` (session_date), `status` (validated enum), `block_id` | block via session-blocks |
| growth-stages | `from`/`to` (observed_at), `block_id`, `stage_code` | — |
| yield-records | `from`/`to` (archived_at), `vintage` (4-digit) | no `variety`/`block_id` filter — variety not stored; blocks live in jsonb (not an indexed path); documented deferral |
| pins | `block_id`, `status` (validated; derivation-aware or-expression), `category`, `type` (repairs/growth/manual_issue) | no date filter by design |

Sub-filters resolved through child tables cap at 5,000 linked ids
(documented; far beyond realistic per-block volumes).

## 15. Pagination

All six resources reuse the Stage 3B opaque keyset cursor over
(`created_at`, `id`), **descending** (newest first), default 100 / max
1000, no offsets. `created_at` is the sort key (NOT NULL everywhere ⇒
deterministic cursor); business dates are filterable via `from`/`to`.
Cursor fields per resource are identical and documented in the API doc.

## 16. Derived values

All deterministic, from canonical data, documented in code + docs:

- Work tasks: `total_labour_hours` (sum of generated line hours).
- Pruning: `row_equivalents` = quarters ÷ 4 (server rollup);
  `vines_per_labour_hour` = vines ÷ hours (1dp); `labour_cost` =
  hours × rate (costs:read).
- Irrigation: `area_ha` = stored m² ÷ 10000 (exact unit conversion only —
  all water metrics are the server-computed stored values, never
  recomputed).
- Yield: top-level `yield_tonnes_per_ha` = total tonnes ÷ total ha (null
  when area 0); per-block value is the STORED canonical number.
- Pins: `status` derivation (stored status else completion flag).

Nothing was derived where source quality is uncertain (e.g. no per-block
treated area for sprays, no vine counts from area).

## 17. Indexes / performance

`sql/175` adds 9 additive partial indexes:

- Keyset `(vineyard_id, created_at, id) where deleted_at is null` on:
  `work_tasks`, `pruning_activities`, `irrigation_sessions`,
  `growth_stage_records`, `historical_yield_records`, `pins`.
- Filter support: `work_tasks (vineyard_id, date)`,
  `pruning_entries (vineyard_id, paddock_id)`,
  `historical_yield_records (vineyard_id, year)` — all partial on live rows.

Existing indexes already cover the other filter paths (audited in the
migration header): `work_task_paddocks.paddock_id`,
`pruning_activities (vineyard_id, entry_date desc)`,
`irrigation_sessions (vineyard_id, session_date desc)`,
`irrigation_session_blocks (vineyard_id, block_id)`,
`growth_stage_records (vineyard_id, observed_at desc)` + `paddock_id`,
`pins.paddock_id`.

N+1 avoidance: every per-row relationship (task blocks, pruning
allocations, irrigation session blocks, block names, pin placements, custom
pin types) is batch-loaded with one `IN (...)` query per page — a
collection page costs a fixed 2–4 queries regardless of page size.

## 18. API logging

Unchanged Stage 3A/3B system (`integration_log_api_request`). New canonical
templates (never raw ids): `/v1/work-tasks`,
`/v1/work-tasks/{work_task_id}`, `/v1/pruning`,
`/v1/pruning/{pruning_activity_id}`, `/v1/irrigation-records`,
`/v1/irrigation-records/{irrigation_record_id}`, `/v1/growth-stages`,
`/v1/growth-stages/{growth_stage_id}`, `/v1/yield-records`,
`/v1/yield-records/{yield_record_id}`, `/v1/pins`, `/v1/pins/{pin_id}`.

## 19. Test results

- `deno check supabase/functions/vinetrack-api/index.ts` — **passes, no
  type errors**.
- `bash -n scripts/test-vinetrack-api.sh` — **passes**.
- `sql/tests/175` — read-only verification written; run in the SQL editor
  after applying sql/175.
- HTTP harness now ≈125 checks: full Stage 3A/3B regression (auth catalogue
  — invalid/expired/revoked keys, paused/revoked integrations, missing
  scope, wrong vineyard, rate-limit headers, envelopes, 405s, 403 body
  regression) PLUS Stage 3C: per-resource 200 + envelope, missing
  vineyard_id, scope isolation (blocks-only key cannot read any 3C
  resource), ungranted-vineyard 403, all filters (valid + invalid values),
  sensitive-field negative checks with the base key and positive checks
  with the sensitive key, random-uuid 404s for all six, cross-vineyard
  fixture 404s, snapped path/row shape check, no-photo-path leak check,
  and cursor iteration.
- Live execution requires the deployed function + fixtures (sandbox has no
  DB/network to the project). Run after deploying:
  `GATEWAY_URL=... VT_KEY_FULL=... VT_VINEYARD_GRANTED=... VT_BLOCK_GRANTED=... ./scripts/test-vinetrack-api.sh`
  (grant the six new scopes to the test integration first — snippet in the
  API doc).

## 20. OpenAPI / docs updates

- `docs/vinetrack-api-v1.md`: scope table (27 routes), sensitive matrix,
  pagination/date-filter tables, units list, full per-resource sections
  with JSON examples and lifecycle notes, new curl examples, credential
  snippet with the six new scopes. No real secrets anywhere.
- `docs/vinetrack-api-openapi.yaml`: 12 new paths, 6 new tags, 12 new
  schemas (summary/detail split where relevant), shared `block_id`
  parameter; YAML validated. Still explicitly descriptive — the
  implementation remains canonical.

## 21. Schema inconsistencies discovered

1. `work_tasks` has NO title column — `task_type` doubles as the label
   (API documents this; no fake field invented).
2. `work_tasks.status` is unconstrained free text (no CHECK, no enum);
   the API returns it as stored and filters by exact value.
3. Dual block linkage on work tasks (legacy `paddock_id`+`paddock_name`
   snapshot vs `work_task_paddocks`) — API merges with documented fallback.
4. Machine identity on `work_task_machine_lines` uses the generic
   `equipment_source`/`equipment_ref_id` pattern while trips use
   `machine_id`/`tractor_id` — a third linkage convention; the API resolves
   all of them to the canonical `vineyard_machines.id`.
5. Pruning labour is mirrored onto the primary allocation for legacy
   readers (SQL 166) — the API deliberately reads ONLY the activity parent,
   immune to the mirror.
6. `historical_yield_records.year` defaults to 0 (meaning "unset") — mapped
   to null.
7. Yield `block_results` stores bunch weight in GRAMS while sampling
   sessions use KG — field named `average_bunch_weight_g` to make the unit
   unambiguous.
8. Growth observations exist in two stores during mirror transition
   (`pins` + `growth_stage_records`); the API serves the canonical table
   only.
9. Legacy pins have NULL `status` (only `is_completed`), while composer
   pins have the sql/169 CHECK-constrained status — the API's documented
   derivation bridges both.
10. `pins.side`/`pin_side` store capitalised `Left`/`Right`; normalised to
    lowercase in the API (documented).
11. Irrigation feature access in-app is currently system-admin-gated
    (Phase 1 capability function) — an integration grant + scope is the
    access model for the API; worth confirming this is intended before
    granting `irrigation:read` to external partners.
12. Provenance columns (`created_source`, integration attribution) are
    still absent on all operational tables — required before any Stage
    write API.

## 22. Confirmation — no write API

The gateway accepts GET (and CORS OPTIONS) only; every other method returns
405 `method_allowed`-safe JSON. No INSERT/UPDATE/DELETE path exists in the
function; it holds only the service-role key inside the Edge runtime and
performs reads + the SQL 173 logging/rate-limit RPCs. Harness asserts POST
→ 405 on multiple routes.

## 23. Confirmation — no webhook / UI work

No webhook delivery, signing, or retries were built (SQL 172's webhook
tables remain dormant). No Lovable integration UI, no mobile
integration-management UI, and zero iOS/Android code changes. Weather,
rainfall and disease-risk remain untouched for Stage 3D.

---

## Go-live checklist

1. Apply `sql/175_integration_api_stage3c_indexes.sql` in the SQL editor;
   run `sql/tests/175_integration_api_stage3c_indexes_tests.sql`.
2. Redeploy: `./scripts/deploy-edge-functions.sh` (or `.ps1`) — no flag
   changes needed.
3. Grant the six new scopes to the test integration (snippet in
   `docs/vinetrack-api-v1.md`), export the new fixture env vars, run
   `scripts/test-vinetrack-api.sh`.

Stopping here for review — Stage 3D (environmental/live data) not started.
