# VineTrack Integration Platform — Stage 3B completion report

## Operational Read API: Trips, Spray Jobs, Fuel, Equipment

Status: **implemented, ready to apply and deploy**. Read-only extension of
the live Stage 3A gateway. Nothing in this stage changes iOS, Android,
Lovable, any existing table/column/RLS policy/RPC, or Stage 3A behaviour.

Apply / deploy order:

1. Run `sql/174_integration_api_operational_indexes.sql` in the Supabase SQL
   editor (project `tbafuqwruefgkbyxrxyb`); SQL 172 + 173 must already be
   applied. Then run `sql/tests/174_integration_api_operational_indexes_tests.sql`
   → `SQL 174 operational index tests: ALL PASSED`.
2. Redeploy the gateway: `./scripts/deploy-edge-functions.sh` (or the
   PowerShell script) — same `vinetrack-api` function, `--no-verify-jwt`.
3. Extend the test integration with the operational scopes (SQL in
   `docs/vinetrack-api-v1.md` "Creating test credentials") and run
   `scripts/test-vinetrack-api.sh` (now covers 3A regression + all 3B).

---

## 1. Files changed

- `supabase/functions/vinetrack-api/index.ts` — extended (10 new routes,
  sensitive-field gating, descending keyset pagination, machine resolution,
  merged equipment listing; Stage 3A handlers behaviourally unchanged)
- `sql/174_integration_api_operational_indexes.sql` — new (5 justified indexes)
- `sql/tests/174_integration_api_operational_indexes_tests.sql` — new
- `scripts/test-vinetrack-api.sh` — extended (Stage 3B matrix + §17 regression)
- `docs/vinetrack-api-v1.md` — extended (all 5 resources, filters, units,
  sensitive-scope matrix, PowerShell note)
- `docs/vinetrack-api-openapi.yaml` — new (OpenAPI 3.1, descriptive)
- this report

No deploy-script change needed (`vinetrack-api` already deployed with
`--no-verify-jwt`). No mobile app files touched.

## 2. Additive SQL migration

**SQL 174** — indexes only, strictly additive, idempotent:

- `idx_trips_vineyard_created_id_active`,
  `idx_spray_records_vineyard_created_id_active`,
  `idx_tractor_fuel_logs_vineyard_created_id_active`,
  `idx_fuel_purchases_vineyard_created_id_active` — composite partial
  `(vineyard_id, created_at, id) where deleted_at is null`, backing every
  collection endpoint's keyset pagination without a per-page sort
  (backward scan serves DESC).
- `idx_fuel_purchases_vineyard_date_active` — `fuel_purchases.date` is the
  API date-filter column and previously had **no index** (unlike
  trips.start_time / spray_records.date / tractor_fuel_logs.fill_datetime).

No new tables, columns, functions or scopes were needed: all seven Stage 3B
scopes (`trips:read`, `sprays:read`, `fuel:read`, `equipment:read`,
`costs:read`, `labour:read`, `team:read`) already exist in the SQL 172
scope catalogue with correct sensitivity flags.

## 3. Canonical source tables audited

| Resource | Canonical tables (migration) | Notes |
| --- | --- | --- |
| Trips | `trips` (006) + additive cols: `trip_function`/`trip_title` (023), `seeding_details` (038), `manual_correction_events` (039), `completion_notes` (040), `tractor_id`/`operator_user_id`/`operator_category_id` (057), `start/end_engine_hours` (093), `machine_id` (098), `work_task_id` (102); costs in `trip_cost_allocations` (059) | soft delete `deleted_at` via `soft_delete_trip` |
| Spray | `spray_records` (007, ACTUAL applied records; `tanks` jsonb holds full mix) + `spray_job_id` (033), `machine_id`/`tractor_id`/`spray_equipment_id` (101); plan header `spray_jobs` + `spray_job_paddocks` (032/034); `is_template` on both | soft delete via `soft_delete_spray_record`; jobs archive via `archive_spray_job`, drafts hard-deleted via `hard_delete_draft_spray_job` (085) |
| Fuel usage | `tractor_fuel_logs` (092) + `machine_id` (097) | litres, engine hours, operator snapshot, optional cost per litre / total cost; soft delete |
| Fuel purchases | `fuel_purchases` (011) | ONLY `volume_litres`, `total_cost`, `date` + envelope. No supplier/notes/tax/price-per-litre columns |
| Equipment | `vineyard_machines` (097, canonical machine catalogue; legacy `tractors` (011) backfilled via `legacy_tractor_id`), `spray_equipment` (011), `equipment_items` (053); serial/VIN on all four (105) | all soft-deleted via `deleted_at` |

Key relationships: every table carries `vineyard_id → vineyards` (cascade);
trips/sprays/fuel link machines via preferred `machine_id` **or** legacy
`tractor_id`; DB triggers enforce same-vineyard integrity on spray job
refs. Dates/times are `timestamptz` (UTC); units: distance **metres**
(GPS), fuel **litres**, engine **hours**, spray water **litres**, rates in
recorded chemical units; worker fields are `operator_user_id` +
free-text name snapshots (`person_name`/`operator_name`); sync fields
(`sync_version`, `client_updated_at`, `created_by`, `updated_by`) exist
everywhere and are **not** exposed.

## 4. Routes implemented

- `GET /v1/trips?vineyard_id=` · `GET /v1/trips/{trip_id}`
- `GET /v1/spray-jobs?vineyard_id=` · `GET /v1/spray-jobs/{spray_job_id}`
- `GET /v1/fuel-records?vineyard_id=` · `GET /v1/fuel-records/{fuel_record_id}`
- `GET /v1/fuel-purchases?vineyard_id=` · `GET /v1/fuel-purchases/{fuel_purchase_id}`
- `GET /v1/equipment?vineyard_id=` · `GET /v1/equipment/{equipment_id}`

`vineyard_id` is REQUIRED on every collection (explicit isolation; no
cross-vineyard collections). All other methods → 405. No other modules
exposed.

## 5. Scope mapping

| Route | Base scope | Extra field scopes honoured |
| --- | --- | --- |
| /v1/trips[…] | `trips:read` | `costs:read`, `labour:read` |
| /v1/spray-jobs[…] | `sprays:read` | `costs:read` |
| /v1/fuel-records[…] | `fuel:read` | `costs:read`, `labour:read` |
| /v1/fuel-purchases[…] | `fuel:read` | `costs:read` |
| /v1/equipment[…] | `equipment:read` | (none exist) |

Every request still runs the full SQL 172/173 chain: valid key → active
integration → unexpired/unrevoked key → required scope → **explicit
vineyard grant** (`integration_validate_api_request`, the canonical
five-check validator). Human memberships (creator/owner/manager/…) are
never consulted. Sensitive scopes never grant a resource alone —
`costs:read` without `fuel:read` cannot call `/v1/fuel-purchases`
(harness-tested).

## 6. Trips — external schema + mapping

| External field | Source | Transformation | Sensitivity |
| --- | --- | --- | --- |
| id / vineyard_id | trips.id / vineyard_id | none | trips:read |
| title / function | trip_title / trip_function | none | trips:read |
| status | is_active + is_paused | derived: active / paused / completed | trips:read |
| started_at / ended_at | start_time / end_time | none (UTC ISO) | trips:read |
| duration_minutes | start/end + pause/resume_timestamps | pause-aware (mirrors apps' activeDuration); null while active | trips:read |
| distance_km | total_distance | **metres ÷ 1000** (GPS stores metres) | trips:read |
| block_ids / block_name | paddock_ids ∪ paddock_id / paddock_name | multi-block set w/ legacy fallback; name is snapshot | trips:read |
| equipment_id / equipment_name | machine_id, tractor_id → vineyard_machines | legacy tractor link resolved to canonical machine id | trips:read |
| work_task_id | work_task_id | none | trips:read |
| tank_count | total_tanks | none | trips:read |
| engine_hours_start/_end | start/end_engine_hours | none | trips:read |
| notes | completion_notes | none | trips:read |
| operator { user_id, name } | operator_user_id / person_name | omitted entirely w/o scope | + labour:read |
| rows { planned, completed, skipped } (detail) | row_sequence / completed_paths / skipped_paths | array lengths only | trips:read |
| costs { fuel, chemical, input, total } (detail) | Σ active trip_cost_allocations | summed; null if never costed | + costs:read |
| costs.labour_cost (detail) | Σ trip_cost_allocations.labour_cost | | + costs:read **and** labour:read |
| created_at / updated_at | same | none | trips:read |

NOT exposed: `path_points` / GPS coordinates (no start/end location is
canonically stored separately — only the raw GPS path, which is location
telemetry and stays private), `seeding_details`, `tank_sessions`,
`manual_correction_events`, live row-progress fields, `operator_category_id`
(links to hourly labour rates), `created_by`/`updated_by`, sync fields.

## 7. Spray — external schema + mapping

Resource decision (documented): `/v1/spray-jobs` serves
**`spray_records`** — the actual completed application/compliance records —
because external consumers (SWNZ/GFA/Vinsight-style) need what was applied,
not the planning header. `is_template=true` rows excluded. The linked
`spray_jobs` plan header is embedded in the detail response.

| External field | Source | Transformation | Sensitivity |
| --- | --- | --- | --- |
| id / vineyard_id | spray_records | none | sprays:read |
| status | (constant) | "completed" — records are completed applications | sprays:read |
| date / started_at / ended_at | date / start_time / end_time | none | sprays:read |
| reference / operation_type / notes / fans_jets | spray_reference / operation_type / notes / number_of_fans_jets | none | sprays:read |
| equipment_id / equipment_name | machine_id, tractor_id, `tractor` text | canonical machine id; name prefers the `tractor` snapshot (matches apps) | sprays:read |
| equipment_type / spray_equipment_id | equipment_type / spray_equipment_id | none | sprays:read |
| conditions { temperature_c, wind_speed_kmh, wind_direction, humidity_percent } | temperature / wind_speed / wind_direction / humidity | renamed w/ explicit units (as recorded: °C, km/h 10-min avg, %) | sprays:read |
| average_speed_kmh | average_speed | unit-named | sprays:read |
| water_volume_l | Σ tanks[].waterVolume | derived | sprays:read |
| treated_area_ha | Σ waterVolume×cf÷sprayRatePerHa per tank | apps' canonical areaPerTank derivation; null when unknowable | sprays:read |
| tank_count / product_names | tanks jsonb | count / distinct names | sprays:read |
| trip_id / spray_job_id | same | none | sprays:read |
| blocks [{block_id, name}] (detail) | trip.paddock_ids else spray_job_paddocks → paddocks | structured; per-block treated area NOT stored canonically, not invented | sprays:read |
| tanks[] (detail) | tanks jsonb | tank_number, water_volume_l, spray_rate_l_per_ha, concentration_factor, area_ha, products[] | sprays:read |
| tanks[].products[] | tanks[].chemicals[] | product_id (savedChemicalId), name, quantity_per_tank, rate_per_ha, rate_per_100l, `unit` (recorded 'Litres'/'mL'/'Kg'/'g' — never converted) | sprays:read |
| products[].cost_per_unit + chemical_cost_total (detail) | chemicals[].costPerUnit | Σ cost×qty | + costs:read |
| spray_job {id, name, status, target, operation_type, planned_date} (detail) | spray_jobs | plan header only | sprays:read |

No raw join-table rows exposed. No operator field exists on spray_records
(only `created_by`, which is private user metadata — not exposed).
Rainfall is not part of the spray record canonically.

## 8. Fuel Records — external schema + mapping

| External field | Source | Transformation | Sensitivity |
| --- | --- | --- | --- |
| id / vineyard_id | tractor_fuel_logs | none | fuel:read |
| date | fill_datetime | none | fuel:read |
| equipment_id / equipment_name | machine_id, tractor_id → vineyard_machines | canonical machine resolution | fuel:read |
| volume_l | litres_added | unit-named | fuel:read |
| engine_hours / filled_to_full / notes | same | none | fuel:read |
| operator { user_id, name } | operator_user_id / operator_name | omitted w/o scope | + labour:read |
| cost_per_litre / total_cost | same | omitted w/o scope | + costs:read |
| created_at / updated_at | same | none | fuel:read |

No canonical trip link exists on fuel logs (fuel-to-trip allocation is a
derived costing concern) — documented, not invented.

## 9. Fuel Purchases — external schema + mapping

| External field | Source | Transformation | Sensitivity |
| --- | --- | --- | --- |
| id / vineyard_id / date | fuel_purchases | none | fuel:read |
| volume_l | volume_litres | unit-named | fuel:read |
| total_price | total_cost | omitted w/o scope | + costs:read |
| price_per_litre | total_cost ÷ volume_litres | **derived** (matches the apps' weighted-cost convention); null when volume 0; omitted w/o scope | + costs:read |
| created_at / updated_at | same | none | fuel:read |

Recommendation adopted: quantities → `fuel:read`; monetary amounts →
additionally `costs:read`, with **omission** (never null-with-key) as the
single documented policy. Supplier / reference / notes / GST are NOT
canonically stored, so they are not exposed (see §23).

## 10. Equipment — external schema + mapping

Decision (documented): tractors and general equipment are internally
fragmented across FOUR tables. The API presents ONE deliberately typed
resource with `kind` = `machine` | `sprayer` | `item`:

- `machine` ← `vineyard_machines` (canonical; every active legacy tractor
  is already backfilled here by sql/097). The legacy `tractors` table is
  NOT listed separately — it would duplicate every tractor — but enriches
  backfilled machines with make/model/year via `legacy_tractor_id`.
- `sprayer` ← `spray_equipment`.
- `item` ← `equipment_items`.

| External field | Source | Transformation | Sensitivity |
| --- | --- | --- | --- |
| id / vineyard_id | table row | none (uuids are globally unique across tables; same id used by trips/fuel `equipment_id`) | equipment:read |
| kind | source table | machine / sprayer / item | equipment:read |
| name | name | blank → null | equipment:read |
| equipment_type | machine_type / "sprayer" / category | typed per kind | equipment:read |
| make / model / year | tractors.brand/model/model_year (machines, via legacy link); equipment_items.make/model | null where not stored | equipment:read |
| serial_number / vin_number | same (sql/105) | none | equipment:read |
| fuel_usage_l_per_hour | vineyard_machines | 0 = "not set" → null (apps' convention) | equipment:read |
| tank_capacity_l | spray_equipment.tank_capacity_litres | sprayers only | equipment:read |
| created_at / updated_at | same | none | equipment:read |

No purchase cost / depreciation / service-cost fields exist on the
canonical equipment records — nothing to gate. NOT exposed:
`available_for_job_costing`, `fuel_tracking_enabled`, `legacy_tractor_id`,
notes, sync fields.

## 11. Sensitive cost/labour field matrix

| Resource | Field | Base scope | Additional scope |
| --- | --- | --- | --- |
| Trip | operator (user id + name) | trips:read | labour:read |
| Trip detail | costs.fuel_cost / chemical_cost / input_cost / total_cost | trips:read | costs:read |
| Trip detail | costs.labour_cost | trips:read | costs:read + labour:read |
| Spray detail | products[].cost_per_unit, chemical_cost_total | sprays:read | costs:read |
| Fuel record | operator (user id + name) | fuel:read | labour:read |
| Fuel record | cost_per_litre, total_cost | fuel:read | costs:read |
| Fuel purchase | volume_l, date | fuel:read | none |
| Fuel purchase | price_per_litre, total_price | fuel:read | costs:read |
| Trip | distance_km, duration, engine hours | trips:read | none |
| Equipment | (no cost-bearing fields exist) | equipment:read | — |

Never exposed regardless of scope: worker contact details (email/phone —
not even queried), `operator_category_id` and `operator_categories.cost_per_hour`
(hourly labour rates), payroll-adjacent data, auth metadata,
`created_by`/`updated_by`.

## 12. Deleted / reversed record behaviour

Audited lifecycle per module: all five sources use `deleted_at` soft delete
via owner/manager-gated RPCs; there are no reversal/credit rows in these
modules. The API filters `deleted_at is null` on **every** query — list
AND single-record — so soft-deleted data is never exposed and a deleted
record's id returns `resource_not_found`. Additionally:

- Spray templates (`spray_records.is_template = true`) are excluded — not
  operational history.
- Archived spray *jobs* (status archived + deleted_at) never surface: the
  resource is spray_records; a linked archived plan header would only
  appear as metadata on a still-active record.
- Draft spray jobs can be HARD-deleted (sql/085) — irrelevant to the API
  (never exposed as a resource).
- Deleted equipment stays resolvable as a **name** on historical trips /
  fuel records (correct: history keeps its label) but is never listed in
  `/v1/equipment` and its direct fetch returns 404.

## 13. Filters implemented (explicit allowlist only)

- Common: `vineyard_id` (required), `limit`, `cursor`; `from`/`to`
  (ISO `YYYY-MM-DD`, validated as real calendar dates, `from>to` rejected,
  UTC-day semantics) on trips / spray-jobs / fuel-records / fuel-purchases.
- Trips: `equipment_id` (canonical machine id; matches both the preferred
  machine link and the legacy tractor link; an unknown or cross-vineyard
  id matches nothing — non-disclosing empty page).
- Fuel records: `equipment_id` (same semantics).
- Equipment: `type` = kind (`machine`/`sprayer`/`item`) or canonical
  machine subtype (`tractor`, `atv`, …). `active` is NOT implemented —
  no canonical active flag exists; deleted rows are already excluded.
- Deliberately deferred (documented): trips `operator_id` (operator-based
  filtering is labour-adjacent; revisit with a labour-scoped design),
  spray `status` (records are all completed — status lives on the plan),
  spray `block_id` (block linkage is indirect via trip/plan joins; needs a
  proper indexed path first).
- Unknown parameters still return `invalid_request` on every route.

## 14. Pagination / ordering

Same opaque keyset cursor model as Stage 3A (base64url `{t, id}`, default
100 / max 1000, no offsets). The utility was extended cleanly with a
direction flag:

- Structural resources (vineyards, blocks, equipment): `created_at, id`
  ASC — Stage 3A behaviour byte-for-byte unchanged.
- Operational resources (trips, spray-jobs, fuel-records, fuel-purchases):
  `created_at DESC, id DESC` — newest first, as preferred for
  chronological data. **`created_at` (not the business date) is the sort
  key** because the business date columns are nullable on trips/sprays —
  a keyset over a nullable column is not deterministic. `created_at` is
  NOT NULL everywhere, closely tracks the business date in practice, and
  `from`/`to` provide date-range access independently. Documented in the
  API docs.
- `/v1/equipment` merges three tables: each is queried with the same
  cursor predicate (limit+1), merge-sorted on (created_at, id); the global
  first page is always contained in the per-table prefixes, so iteration
  is deterministic with no duplicates or gaps.

## 15. Indexes added and why

See §2 — five indexes, each tied to a concrete query path (keyset
pagination per vineyard; fuel-purchase date filter that previously had no
index). Nothing speculative: equipment catalogues and existing
single-column date indexes (trips.start_time, spray_records.date,
tractor_fuel_logs.fill_datetime) were audited and judged sufficient.
N+1 avoidance: machine names resolve via ONE catalogue query per request
(`loadMachineIndex`), not per row; tractor enrichment is one query;
spray-detail block names are one `in (...)` query.

## 16. API logging behaviour

Unchanged SQL 173 path (`integration_log_api_request`) for all Stage 3B
traffic. Canonical low-cardinality templates only: `/v1/trips`,
`/v1/trips/{trip_id}`, `/v1/spray-jobs`, `/v1/spray-jobs/{spray_job_id}`,
`/v1/fuel-records/…`, `/v1/fuel-purchases/…`, `/v1/equipment/…` — raw ids
never appear in the logged path; the vineyard id is stored in its own
column. Bodies, headers and credentials are never logged; log failures
never break responses.

## 17. Stage 3A empty-403-body — investigation + fix status

Inspected the full error path: every gateway error, including 403
`vineyard_access_denied`, is emitted by the single `errorResponse()`
helper, which always writes the documented JSON envelope with
`Content-Type: application/json; charset=utf-8` — there is no code path
that can return an empty 403 body. Root cause of the observation is
PowerShell: `Invoke-RestMethod`/`Invoke-WebRequest` throw on 4xx/5xx and
hide the response body by default (it is available via
`$_.ErrorDetails.Message`). Security outcome untouched. Actions taken:

- Regression test added to the harness: the ungranted-vineyard 403 must
  carry `error.code == "vineyard_access_denied"`, a non-empty message and
  a `req_`-prefixed request id in the body.
- A PowerShell note (with the working pattern and the `curl.exe`
  alternative) added to `docs/vinetrack-api-v1.md`.

## 18. Automated test results

- `deno check supabase/functions/vinetrack-api/index.ts` — **passes** (no
  type errors).
- `bash -n scripts/test-vinetrack-api.sh` — **passes**.
- SQL 174 + test file — ready to run in the SQL editor (this sandbox has
  no connection to the shared project; same manual-apply flow as SQL
  143–173). Expected: `ALL PASSED`.
- HTTP harness — extended to ~70 checks covering the §26–§30 matrices:
  - Stage 3A regression: auth chain (missing/malformed/unknown/expired/
    revoked keys, paused/revoked integrations), scope non-implication,
    vineyard isolation, envelopes, 405/404/400 paths, rate-limit headers
    implicitly on every call, query-string credential rejection.
  - Trips/Spray/Fuel/Equipment: correct scope + vineyard 200s; missing
    scope 403 (`blocks:read` implies none of the four); ungranted
    vineyard 403 with JSON body; cross-vineyard ids → non-disclosing 404
    per resource; date filtering (valid, malformed, impossible date,
    from>to); equipment filter non-disclosure; equipment type filter
    (kind, subtype, invalid); no cost/labour leakage with the base key
    (structural jq assertions on `has(...)`); positive sensitive-field
    checks with the costs+labour key; product/block/units mapping
    assertions on spray detail; cursor iteration without duplicates.
  Fixtures are env-vars only; second-account cases skip cleanly when not
  provided. Run after deploy per the header comment.

## 19. Manual API test examples

See `docs/vinetrack-api-v1.md` (placeholders only). Quick smoke:

```bash
BASE=https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api
curl -H "Authorization: Bearer <KEY>" "$BASE/v1/trips?vineyard_id=<VY>&from=2026-07-01&to=2026-07-31&limit=5"
curl -H "Authorization: Bearer <KEY>" "$BASE/v1/spray-jobs/<SPRAY_ID>"
curl -H "Authorization: Bearer <KEY>" "$BASE/v1/fuel-purchases?vineyard_id=<VY>"   # no costs:read -> no prices
curl -H "Authorization: Bearer <KEY>" "$BASE/v1/equipment?vineyard_id=<VY>&type=tractor"
```

## 20. Documentation / OpenAPI

- `docs/vinetrack-api-v1.md` — full Stage 3B contract: scopes + sensitive
  matrix, all fields with units, filters, pagination/order semantics, date
  semantics, examples, error examples, PowerShell note.
- `docs/vinetrack-api-openapi.yaml` — OpenAPI 3.1 covering all 15 routes
  (3A + 3B), bearer auth description, envelopes, error catalogue, scope
  descriptions, full schemas. Explicitly descriptive — the implementation
  remains canonical.

## 21. Write access remains impossible

Confirmed. The gateway rejects every non-GET method with 405 before
authentication (harness-tested with POST /v1/trips); no handler issues an
insert/update/delete/RPC-with-side-effects other than the Stage 3A
logging/rate-limit/last-used writers, which are internal telemetry. The
service role is never exposed; no write scope has any behaviour.

## 22. No webhooks / UI changes

Confirmed. No webhook dispatch/signing/retry code exists; no Lovable UI,
no iOS/Android files touched, no SWNZ/GFA/Vinsight connector logic. None
of §33's deferred items were started.

## 23. Canonical data-model issues found (resolve before future integrations)

1. **Fuel purchases are threadbare**: no supplier, invoice/reference,
   notes, or GST fields, and price-per-litre is derived. A future
   procurement-grade API (or Xero-style integration) needs canonical
   supplier/reference/tax columns.
2. **Per-block treated area is not stored** for sprays; the block set is
   only reachable via the trip OR plan join, and spray_records has no
   direct paddock link. Compliance connectors (SWNZ) will want a stored
   per-block application row — recommend a `spray_record_paddocks` child
   table with area at write time.
3. **Spray weather units are convention, not constraint** — °C / km/h / %
   are app conventions with no DB validation. Fine for read-out; a write
   API must pin units.
4. **Chemical mix lives in loosely-typed jsonb** (`tanks`) with camelCase
   iOS Codable keys and no DB validation; `spray_jobs.chemical_lines` uses
   a DIFFERENT per-line shape. A write API must canonicalise one shape.
5. **Trips have no stored date column** — only nullable `start_time`;
   autosaved drafts can exist with neither. This forced created_at-based
   ordering (§14) and means date filters skip undated trips.
6. **Dual machine linkage** (`machine_id` + legacy `tractor_id`) works via
   resolution but every consumer must know both. A backfill making
   `machine_id` NOT NULL-in-practice would let the legacy path retire.
7. **Operator identity is a text snapshot** (`person_name`,
   `operator_name`) alongside an optional user id — names can drift from
   accounts. A future `team:read` contract needs a canonical worker
   registry decision.
8. **No currency column anywhere** — monetary fields are unit-less
   numbers (NZD by convention). Multi-currency integrations need a
   vineyard-level currency setting.
9. **Provenance columns still absent** on operational tables (Stage 2
   report §9) — still required before any external WRITE endpoint.

---

**Stopping here per the brief — Stage 3C is not started.**
