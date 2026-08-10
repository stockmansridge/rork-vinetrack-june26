# VineTrack API — v1 (Stage 3A + Stage 3B + Stage 3C + Stage 3D)

The canonical engineering contract for the VineTrack public read-only API.
This document seeds the future developer portal; it is not end-user marketing
copy. Later Lovable documentation must match this contract.

Base URL:

```text
https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api
```

All routes below are relative to that base, e.g.
`GET {base}/v1/vineyards`.

## Authentication

Every request must carry a VineTrack API key:

```text
Authorization: Bearer vt_live_xxxxxxxx...
```

- Keys are created by a vineyard **Owner** in the integration management
  surface (SQL 172 `integration_create_api_key`). The plaintext is shown
  exactly once at creation and can never be retrieved again — by anyone.
- `vt_live_` keys are production credentials; `vt_test_` keys are test
  credentials. Both authenticate identically in Stage 3A.
- Supabase JWTs are **not** accepted. Query-string credentials are **not**
  accepted (`?api_key=...` is rejected with `invalid_request`).
- An API key only reaches data that its integration has been **explicitly
  granted**: every vineyard grant and every scope grant is explicit. Nothing
  is inherited from the person who created the key.

## API version

The route version is authoritative: all routes live under `/v1/`.
Responses also include the informational header:

```text
X-VineTrack-API-Version: v1
```

## Request IDs

Every response carries:

```text
X-VineTrack-Request-ID: req_<32 hex>
```

Error payloads repeat the same id as `error.request_id`. Quote it in support
enquiries — it correlates directly with VineTrack's API request log.

## Response envelopes

Single resource:

```json
{ "data": { "id": "..." } }
```

Collection:

```json
{ "data": [], "pagination": { "next_cursor": null } }
```

Error:

```json
{
  "error": {
    "code": "vineyard_access_denied",
    "message": "This integration is not authorised for the requested vineyard.",
    "request_id": "req_..."
  }
}
```

All responses are UTF-8 `application/json`. There are no HTML error pages.

## Error codes

| Code | HTTP | Meaning |
| --- | --- | --- |
| `missing_api_key` | 401 | No `Authorization` header. |
| `invalid_api_key` | 401 | Credential unknown or malformed. |
| `expired_api_key` | 401 | Credential past its expiry. |
| `revoked_api_key` | 401 | Credential revoked. |
| `integration_not_active` | 403 | Integration paused or revoked. |
| `insufficient_scope` | 403 | Required scope not granted. |
| `vineyard_access_denied` | 403 | Integration not authorised for the requested vineyard context. |
| `resource_not_found` | 404 | Resource does not exist **or is not accessible** (existence is never disclosed). |
| `invalid_request` | 400 | Malformed parameter, unsupported query parameter, missing required parameter, or credential in the query string. |
| `invalid_cursor` | 400 | Unreadable pagination cursor. |
| `rate_limit_exceeded` | 429 | Per-key request limit exceeded. |
| `method_not_allowed` | 405 | The API is read-only; only GET (and OPTIONS) are supported. |
| `internal_error` | 500 | Unexpected failure; quote `request_id` to support. |
| `disease_risk_unavailable` | 503 | Disease risk could not be computed AND no recent cached assessment exists (see `/v1/disease-risk`). |

Unknown query parameters are **rejected** with `invalid_request` (never
silently ignored) so integration mistakes surface immediately.

**Stale data is not an error.** When an environmental endpoint serves
cached data as a fallback it still returns HTTP `200` with the staleness
marked explicitly in the payload (`is_stale: true` /
`source_status: "stale_fallback"`). Errors are reserved for the case
where nothing can be served at all.

## Scopes

| Route | Required scope |
| --- | --- |
| `GET /v1/me` | authentication only |
| `GET /v1/vineyards` | `vineyards:read` |
| `GET /v1/vineyards/{id}` | `vineyards:read` |
| `GET /v1/blocks` | `blocks:read` |
| `GET /v1/blocks/{id}` | `blocks:read` |
| `GET /v1/trips` | `trips:read` |
| `GET /v1/trips/{id}` | `trips:read` |
| `GET /v1/spray-jobs` | `sprays:read` |
| `GET /v1/spray-jobs/{id}` | `sprays:read` |
| `GET /v1/fuel-records` | `fuel:read` |
| `GET /v1/fuel-records/{id}` | `fuel:read` |
| `GET /v1/fuel-purchases` | `fuel:read` |
| `GET /v1/fuel-purchases/{id}` | `fuel:read` |
| `GET /v1/equipment` | `equipment:read` |
| `GET /v1/equipment/{id}` | `equipment:read` |
| `GET /v1/work-tasks` | `work_tasks:read` |
| `GET /v1/work-tasks/{id}` | `work_tasks:read` |
| `GET /v1/pruning` | `pruning:read` |
| `GET /v1/pruning/{id}` | `pruning:read` |
| `GET /v1/irrigation-records` | `irrigation:read` |
| `GET /v1/irrigation-records/{id}` | `irrigation:read` |
| `GET /v1/growth-stages` | `growth_stages:read` |
| `GET /v1/growth-stages/{id}` | `growth_stages:read` |
| `GET /v1/yield-records` | `yield:read` |
| `GET /v1/yield-records/{id}` | `yield:read` |
| `GET /v1/pins` | `pins:read` |
| `GET /v1/pins/{id}` | `pins:read` |
| `GET /v1/weather` | `weather:read` |
| `GET /v1/rainfall` | `rainfall:read` |
| `GET /v1/disease-risk` | `disease_risk:read` |

Scopes never imply each other: `blocks:read` does not include
`vineyards:read`. Sensitive scopes (`labour:read`, `costs:read`,
`team:read`) are never implied by any resource scope.

### Sensitive-field gating

Operational resources gate cost and labour fields behind ADDITIONAL scopes.
The base resource scope is always required — a sensitive scope alone never
grants access to any route (`costs:read` alone cannot call
`/v1/fuel-purchases`). Sensitive fields are **omitted** from the response
(not returned as `null`) when the extra scope is absent:

| Resource | Field(s) | Base scope | Additional scope |
| --- | --- | --- | --- |
| Trip | `operator` (user id + name) | `trips:read` | `labour:read` |
| Trip detail | `costs.fuel_cost`, `costs.chemical_cost`, `costs.input_cost`, `costs.total_cost` | `trips:read` | `costs:read` |
| Trip detail | `costs.labour_cost` | `trips:read` | `costs:read` **and** `labour:read` |
| Spray detail | `tanks[].products[].cost_per_unit`, `chemical_cost_total` | `sprays:read` | `costs:read` |
| Fuel record | `operator` (user id + name) | `fuel:read` | `labour:read` |
| Fuel record | `cost_per_litre`, `total_cost` | `fuel:read` | `costs:read` |
| Fuel purchase | `price_per_litre`, `total_price` | `fuel:read` | `costs:read` |
| Fuel purchase | `volume_l`, `date` | `fuel:read` | none |
| Equipment | (no cost-bearing fields exist canonically) | `equipment:read` | — |
| Work task detail | `labour_lines[].hourly_rate`, `labour_lines[].total_cost`, `machine_lines[].fuel_cost`, `machine_lines[].hourly_rate`, `machine_lines[].total_cost` | `work_tasks:read` | `costs:read` |
| Work task detail | `machine_lines[].operator` | `work_tasks:read` | `labour:read` |
| Pruning | `crew` (worker/crew identity snapshot) | `pruning:read` | `labour:read` |
| Pruning | `hourly_rate`, `labour_cost` | `pruning:read` | `costs:read` |
| Irrigation record | (no cost or labour fields exist canonically) | `irrigation:read` | — |
| Growth stage | `recorded_by` (user id + name) | `growth_stages:read` | `labour:read` |
| Yield record | (no pricing/revenue fields exist canonically — `costs:read` gates nothing today; any future financial grape-sale data will be `costs:read`-gated) | `yield:read` | — |
| Pin | `assigned_to`, `completed_by` (user id + name) | `pins:read` | `labour:read` |
| Weather / Rainfall / Disease risk | (no cost or labour fields exist — `costs:read` and `labour:read` are irrelevant to environmental resources and never affect access to them) | resource scope | — |

Monetary values are returned in the vineyard's local currency as recorded;
no currency column exists canonically, so no currency code is asserted.

## Pagination

Collection endpoints use opaque cursor pagination:

```text
GET /v1/blocks?vineyard_id=<uuid>&limit=100
GET /v1/blocks?vineyard_id=<uuid>&limit=100&cursor=<next_cursor>
```

- `limit` — default 100, maximum 1000 (`invalid_request` above that).
- `cursor` — the `pagination.next_cursor` from the previous page. Opaque;
  do not construct or parse it. `next_cursor: null` means the last page.
- Ordering is deterministic keyset iteration with no duplicates and no gaps:
  - Structural resources (`vineyards`, `blocks`, `equipment`):
    `created_at` then `id`, **ascending** (Stage 3A behaviour, unchanged).
  - Operational/chronological resources (`trips`, `spray-jobs`,
    `fuel-records`, `fuel-purchases`, `work-tasks`, `pruning`,
    `irrigation-records`, `growth-stages`, `yield-records`, `pins`):
    `created_at` then `id`, **descending** — newest records first.
    `created_at` (not the business date) is the sort key because it is
    NOT NULL on every operational table, which keeps the keyset cursor
    deterministic; business-date filtering is provided separately via
    `from`/`to`.
  - `/v1/rainfall` is a daily series with no per-row uuid after source
    resolution, so its cursor is keyed on the **date** itself,
    descending (newest day first). It is equally opaque — treat it like
    any other cursor.

`/v1/weather` and `/v1/disease-risk` are **singleton** responses (one
document per vineyard) and are not paginated — they return `data` plus a
`meta` freshness object instead of a `pagination` object.

## Date filters

Operational collections accept optional `from` and `to` parameters as ISO
dates (`YYYY-MM-DD`). Invalid or impossible dates (e.g. `2026-02-31`) and
`from > to` are rejected with `invalid_request`. The range is inclusive of
both days and is evaluated against UTC timestamps (a day means
`00:00:00Z`–`23:59:59Z`). The filtered column per resource:

| Resource | Date column semantics |
| --- | --- |
| trips | trip start time (`started_at`) — trips without a start time are excluded by a date filter |
| spray-jobs | spray date (`date`) — records without a date are excluded by a date filter |
| fuel-records | fill date/time (`date`) |
| fuel-purchases | purchase date (`date`) |
| work-tasks | task business date (`date`) |
| pruning | activity date (`date`) |
| irrigation-records | session date (`date`) |
| growth-stages | observation time (`observed_at`) |
| yield-records | season archive time (`archived_at`) |
| pins | — (no date filter; pins filter by block/status/category/type) |
| rainfall | observation date (`date`) — vineyard-local calendar day |

## Units

Field names carry their unit explicitly: `distance_km`, `volume_l`,
`water_volume_l`, `treated_area_ha`, `duration_minutes`, `row_width_m`,
`tank_capacity_l`, `fuel_usage_l_per_hour`, `price_per_litre`,
`temperature_c`, `wind_speed_kmh`, `humidity_percent`, `labour_hours`,
`duration_hours`, `vines_pruned`, `vines_per_labour_hour`,
`flow_l_per_hour`, `depth_mm`, `water_l_per_vine`, `water_l_per_ha`,
`total_yield_tonnes`, `total_area_ha`, `yield_tonnes_per_ha`,
`average_bunch_weight_g`, `along_row_distance_m`, `rainfall_mm`,
`rainfall_today_mm`, `rainfall_rate_mm_per_hour`, `wind_gust_kmh`,
`wind_speed_max_kmh`, `temp_min_c`, `temp_max_c`, `et0_mm`. Spray product
rates/quantities keep the product's recorded unit (`Litres`, `mL`, `Kg`,
`g`) in a `unit` field and are never converted. All environmental data is
metric — provider-native imperial values (e.g. Davis °F / mph / inches)
are converted deterministically by the canonical ingestion proxies before
storage; the API performs no unit conversion of its own.

## Rate limits

- 300 requests per minute per API key (server-configurable).
- Responses include `X-RateLimit-Limit` and `X-RateLimit-Remaining`.
- On breach: HTTP 429 with `rate_limit_exceeded` and a `Retry-After`
  header (seconds).

## Endpoints

### GET /v1/me

Confirms authentication and describes the integration's granted
capabilities. Requires a valid active key but no resource scope.

```json
{
  "data": {
    "integration_id": "9c6d...",
    "name": "Packhouse Sync",
    "environment": "live",
    "status": "active",
    "scopes": ["blocks:read", "vineyards:read"],
    "vineyards": [
      { "id": "1f0a...", "name": "Stockman's Ridge" }
    ]
  }
}
```

Only **active** grants and scopes appear. The `vineyards` list here is
integration metadata (id + name only); full vineyard resources still require
`vineyards:read`.

### GET /v1/vineyards

Requires `vineyards:read`. Returns only vineyards with an active explicit
grant to the authenticated integration. Query parameters: `limit`, `cursor`.

Vineyard resource shape:

```json
{
  "id": "1f0a...",
  "name": "Stockman's Ridge",
  "country_code": "AU",
  "country": "Australia",
  "timezone": "Australia/Sydney",
  "created_at": "2025-03-01T02:11:09Z",
  "updated_at": "2026-07-30T22:41:53Z"
}
```

`country_code`, `country` and `timezone` are `null` when the vineyard has
not configured them.

### GET /v1/vineyards/{vineyard_id}

Requires `vineyards:read` and an active explicit grant to that vineyard.
Returns the same shape as the collection. A vineyard that exists but is not
granted returns `resource_not_found` — existence is never disclosed.

### GET /v1/blocks?vineyard_id={uuid}

Requires `blocks:read`. `vineyard_id` is **required** in Stage 3A — vineyard
isolation is explicit. Requesting an ungranted vineyard returns
`vineyard_access_denied` (which does not reveal whether the vineyard
exists). Query parameters: `vineyard_id`, `limit`, `cursor`.

Block resource shape:

```json
{
  "id": "77b3...",
  "vineyard_id": "1f0a...",
  "name": "Block 12 — Shiraz",
  "planting_year": 2014,
  "row_count": 42,
  "row_width_m": 3.0,
  "vine_spacing_m": 1.8,
  "varieties": [
    { "name": "Shiraz", "percent": 100 }
  ],
  "created_at": "2025-03-02T00:15:40Z",
  "updated_at": "2026-06-11T05:02:17Z"
}
```

Boundary geometry and per-row geometry are deliberately **not** exposed in
Stage 3A; exposing geometry is a future explicit API decision.

### GET /v1/blocks/{block_id}

Requires `blocks:read` and an active grant to the block's vineyard. Returns
the same block shape. A block in an ungranted vineyard returns
`resource_not_found` — cross-vineyard ids are not discoverable.

### GET /v1/trips?vineyard_id={uuid}

Requires `trips:read`. `vineyard_id` is **required**. Optional filters:
`from`, `to` (trip start date), `equipment_id` (canonical machine id — an
id from another vineyard simply matches nothing), `limit`, `cursor`.
Newest first.

Trip resource shape (collection summary):

```json
{
  "id": "3d2c...",
  "vineyard_id": "1f0a...",
  "title": "Trim rows 40-60",
  "function": "mowing",
  "status": "completed",
  "started_at": "2026-08-01T21:04:11Z",
  "ended_at": "2026-08-01T23:40:52Z",
  "duration_minutes": 149,
  "distance_km": 12.482,
  "block_ids": ["77b3..."],
  "block_name": "Block 12",
  "equipment_id": "a9b1...",
  "equipment_name": "John Deere 5075E",
  "work_task_id": null,
  "tank_count": 2,
  "engine_hours_start": 1204.5,
  "engine_hours_end": 1207.1,
  "notes": "Completed both passes",
  "created_at": "2026-08-01T21:04:12Z",
  "updated_at": "2026-08-01T23:40:53Z"
}
```

- `status` is `active`, `paused` or `completed` (derived from the live
  tracking flags).
- `duration_minutes` is pause-aware (paused intervals excluded, matching
  the apps' canonical calculation) and `null` while a trip is active.
- `distance_km` is converted from the stored GPS metres (documented
  transformation).
- `equipment_id` is always a canonical machine id (see Equipment).
- `operator` (`{ user_id, name }`) is included **only** with `labour:read`.
- GPS path points and start/end coordinates are **not** exposed — no
  location telemetry leaves the platform in Stage 3B.

### GET /v1/trips/{trip_id}

Same shape plus:

- `rows`: `{ "planned": 20, "completed": 18, "skipped": 2 }` — row-plan
  work summary.
- `costs` (**only** with `costs:read`): summed from the trip's saved cost
  allocation — `fuel_cost`, `chemical_cost`, `input_cost`, `total_cost`;
  `labour_cost` appears only with `costs:read` **and** `labour:read`.
  `costs` is `null` when no costing has been calculated for the trip.

### GET /v1/spray-jobs?vineyard_id={uuid}

Requires `sprays:read`. `vineyard_id` is **required**. Optional filters:
`from`, `to` (spray date), `limit`, `cursor`. Newest first.

The canonical source is VineTrack's completed spray application records —
what was actually applied in the field (compliance-grade), not the planning
header. Template records are excluded. When a record fulfilled a planned
spray job, the detail endpoint includes the linked plan header.

Collection summary shape:

```json
{
  "id": "5e1b...",
  "vineyard_id": "1f0a...",
  "status": "completed",
  "date": "2026-08-02T20:30:00Z",
  "started_at": "2026-08-02T20:30:00Z",
  "ended_at": "2026-08-02T23:10:00Z",
  "reference": "SR-2026-014",
  "operation_type": "Fungicide",
  "equipment_id": "a9b1...",
  "equipment_name": "John Deere 5075E",
  "equipment_type": "Airblast",
  "spray_equipment_id": "c4d2...",
  "conditions": {
    "temperature_c": 18.5,
    "wind_speed_kmh": 7.2,
    "wind_direction": "NW",
    "humidity_percent": 64
  },
  "water_volume_l": 1200,
  "treated_area_ha": 3.4,
  "tank_count": 2,
  "product_names": ["Luna Sensation", "Wetter 600"],
  "average_speed_kmh": 6.5,
  "fans_jets": "14 jets",
  "trip_id": "3d2c...",
  "spray_job_id": "8a90...",
  "notes": null,
  "created_at": "2026-08-02T23:12:40Z",
  "updated_at": "2026-08-02T23:12:40Z"
}
```

- `conditions` values are as recorded by the apps (°C, km/h 10-minute
  average, % relative humidity) — never converted.
- `water_volume_l` and `treated_area_ha` are derived from the canonical
  tank mix (`area = water × concentration factor ÷ rate per ha`, summed
  per tank), matching the apps' calculation exactly.

### GET /v1/spray-jobs/{spray_job_id}

Same summary shape plus full detail:

```json
{
  "blocks": [ { "block_id": "77b3...", "name": "Block 12" } ],
  "tanks": [
    {
      "tank_number": 1,
      "water_volume_l": 600,
      "spray_rate_l_per_ha": 350,
      "concentration_factor": 1,
      "area_ha": 1.714,
      "products": [
        {
          "product_id": "b2c3...",
          "name": "Luna Sensation",
          "quantity_per_tank": 0.24,
          "rate_per_ha": 0.14,
          "rate_per_100l": 0,
          "unit": "Litres"
        }
      ]
    }
  ],
  "spray_job": {
    "id": "8a90...",
    "name": "Pre-flower fungicide",
    "status": "completed",
    "target": "Powdery mildew",
    "operation_type": "Fungicide",
    "planned_date": "2026-08-02"
  }
}
```

- Blocks treated resolve through the linked trip's block set, else the
  linked plan's block links. Per-block treated area is not canonically
  stored and is therefore not invented.
- With `costs:read`, each product gains `cost_per_unit` and the record
  gains `chemical_cost_total`.
- Product rates/quantities are in the product's recorded `unit` — never
  converted.

### GET /v1/fuel-records?vineyard_id={uuid}

Requires `fuel:read`. Operational fuel USAGE (machine fill) records.
`vineyard_id` is **required**. Optional filters: `from`, `to` (fill date),
`equipment_id` (canonical machine id), `limit`, `cursor`. Newest first.

```json
{
  "id": "9f4e...",
  "vineyard_id": "1f0a...",
  "date": "2026-08-03T04:20:00Z",
  "equipment_id": "a9b1...",
  "equipment_name": "John Deere 5075E",
  "volume_l": 62.5,
  "engine_hours": 1207.1,
  "filled_to_full": true,
  "notes": null,
  "created_at": "2026-08-03T04:21:10Z",
  "updated_at": "2026-08-03T04:21:10Z"
}
```

- `operator` (`{ user_id, name }`) only with `labour:read`.
- `cost_per_litre` / `total_cost` only with `costs:read`.
- Fuel records do not canonically link to a trip; fuel-to-trip allocation
  is a derived costing concern, not a stored relationship.

### GET /v1/fuel-records/{fuel_record_id}

Same shape; same gating.

### GET /v1/fuel-purchases?vineyard_id={uuid}

Requires `fuel:read`. Bulk fuel PURCHASING records — separate from usage.
`vineyard_id` is **required**. Optional filters: `from`, `to` (purchase
date), `limit`, `cursor`. Newest first.

```json
{
  "id": "6c7d...",
  "vineyard_id": "1f0a...",
  "date": "2026-07-28T00:00:00Z",
  "volume_l": 900,
  "total_price": 1683.0,
  "price_per_litre": 1.87,
  "created_at": "2026-07-28T02:10:00Z",
  "updated_at": "2026-07-28T02:10:00Z"
}
```

- `total_price` and `price_per_litre` appear **only** with `costs:read`
  (omitted otherwise — one consistent policy).
- Canonical storage is volume + total price; `price_per_litre` is derived
  (`total_price ÷ volume_l`) exactly like the apps' weighted fuel-cost
  convention. No supplier, reference, notes or tax fields exist
  canonically, so none are exposed.

### GET /v1/fuel-purchases/{fuel_purchase_id}

Same shape; same gating.

### GET /v1/equipment?vineyard_id={uuid}

Requires `equipment:read`. One unified, deliberately typed resource over
VineTrack's machinery catalogues. `vineyard_id` is **required**. Optional
filters: `type`, `limit`, `cursor`.

`type` accepts an external kind — `machine` (self-propelled vineyard
machines incl. tractors), `sprayer` (spray rigs/tanks), `item` (general
equipment: trailers, pumps, tools) — or a canonical machine subtype:
`tractor`, `atv`, `side_by_side`, `harvester`, `utility_vehicle`,
`other_vineyard_machine`.

```json
{
  "id": "a9b1...",
  "vineyard_id": "1f0a...",
  "kind": "machine",
  "name": "John Deere 5075E",
  "equipment_type": "tractor",
  "make": "John Deere",
  "model": "5075E",
  "year": 2019,
  "serial_number": "1LV5075E...",
  "vin_number": null,
  "fuel_usage_l_per_hour": 8.5,
  "tank_capacity_l": null,
  "created_at": "2025-04-10T01:00:00Z",
  "updated_at": "2026-06-01T22:15:00Z"
}
```

- `kind` = `machine` | `sprayer` | `item`. Sprayers carry
  `tank_capacity_l`; machines carry `fuel_usage_l_per_hour` (`null` when
  not configured); items carry `make`/`model`.
- There is **no** `active` filter: VineTrack has no canonical active flag
  on equipment — deleted equipment is simply never returned.
- No purchase cost, depreciation or service-cost fields exist on the
  canonical equipment records, so none are exposed.
- The id returned here is the same id used by `equipment_id` on trips and
  fuel records.

### GET /v1/equipment/{equipment_id}

Same shape. Ids are looked up across all three catalogues; an id in an
ungranted vineyard returns `resource_not_found`.

### GET /v1/work-tasks?vineyard_id={uuid}

Requires `work_tasks:read`. General vineyard work tasks (the canonical
source is VineTrack's Work Tasks module). `vineyard_id` is **required**.
Optional filters: `from`, `to` (task date), `status` (stored status value),
`task_type`, `block_id`, `limit`, `cursor`. Newest first.

```json
{
  "id": "e1f2...",
  "vineyard_id": "1f0a...",
  "task_type": "Mowing",
  "status": "completed",
  "date": "2026-08-01T00:00:00Z",
  "start_date": "2026-08-01T00:00:00Z",
  "end_date": "2026-08-02T00:00:00Z",
  "duration_hours": 6.5,
  "area_ha": 4.2,
  "blocks": [ { "id": "77b3...", "name": "Block 12" } ],
  "description": "Mid-rows both directions",
  "notes": null,
  "is_archived": false,
  "is_finalized": true,
  "created_at": "2026-08-01T05:12:40Z",
  "updated_at": "2026-08-02T03:01:11Z"
}
```

- There is **no** canonical title column — `task_type` is the task's label.
- `status` is the stored client value (free text, nullable); `is_archived`
  and `is_finalized` are returned as explicit flags. Archived tasks remain
  in the collection as history; deleted tasks never appear.
- `blocks` come from the task's multi-block links, falling back to the
  legacy single-block reference for older tasks.
- The `block_id` filter matches tasks linked to that block through either
  path.

### GET /v1/work-tasks/{work_task_id}

Same shape plus:

- `labour_lines`: per-day, per-worker-TYPE entries — `work_date`,
  `worker_type`, `worker_count`, `hours_per_worker`, `total_hours`,
  `notes`. Worker type is a category (e.g. "Contractor"), never an
  identity, so it is not labour-gated. With `costs:read` each line gains
  `hourly_rate` and `total_cost`.
- `total_labour_hours`: sum of line total hours (derived, documented).
- `machine_lines`: manual machine work — `work_date`, `equipment_id`
  (canonical machine id when resolvable), `equipment_name`,
  `duration_hours`, `started_at`, `ended_at`, `engine_hours_start/-end/
  -used`, `fuel_volume_l`, `entry_source`, `notes`. With `costs:read`:
  `fuel_cost`, `hourly_rate`, `total_cost`. With `labour:read`:
  `operator` (`{ user_id, name }`; name is `null` — machine lines store
  no name snapshot).
- `trip_ids`: linked GPS trip ids (full trips are a separate
  `trips:read`-scoped resource).
- Internal labour/machine line row ids are **not** exposed — they are not
  stable external references.

### GET /v1/pruning?vineyard_id={uuid}

Requires `pruning:read`. Actual pruning ACTIVITY records (one activity =
one crew/day of work across one or more blocks) — not season
configuration. `vineyard_id` is **required**. Optional filters: `from`,
`to` (activity date), `block_id`, `limit`, `cursor`. Newest first.

```json
{
  "id": "ab12...",
  "vineyard_id": "1f0a...",
  "date": "2026-07-15",
  "pruning_method": "spur",
  "season_year": 2026,
  "vintage_year": 2027,
  "started_at": "2026-07-15T20:00:00Z",
  "ended_at": "2026-07-16T01:30:00Z",
  "labour_hours": 22,
  "vines_pruned": 1840,
  "row_equivalents": 11.5,
  "quarters_completed": 46,
  "vines_per_labour_hour": 83.6,
  "block_summary": "Cabernet Franc · Sauvignon Blanc",
  "blocks": [
    { "block_id": "77b3...", "block_name": "Cabernet Franc", "row_equivalents": 7.25, "vines_pruned": 1160 },
    { "block_id": "88c4...", "block_name": "Sauvignon Blanc", "row_equivalents": 4.25, "vines_pruned": 680 }
  ],
  "work_task_id": null,
  "notes": null,
  "created_at": "2026-07-16T01:31:00Z",
  "updated_at": "2026-07-16T01:31:00Z"
}
```

- **Reversed activities are omitted from the collection entirely.**
  Reversal is VineTrack's only way to revert completed pruning quarters;
  a reversed activity's work no longer exists in live progress, so the
  API mirrors that exactly — reversed activity can never inflate totals.
- `vines_pruned` / `row_equivalents` / `quarters_completed` are the
  server-attributed values from VineTrack's idempotent quarter model —
  never double-counted across devices.
- `vines_per_labour_hour` is derived (`vines_pruned ÷ labour_hours`,
  1 decimal) and `null` when labour hours are absent.
- `crew` (free-text worker/crew identity snapshot) appears **only** with
  `labour:read`.
- `hourly_rate` and the derived `labour_cost`
  (`labour_hours × hourly_rate`) appear **only** with `costs:read`.
- Labour is stored ONCE per activity (never apportioned across blocks).
- The internal row/quarter grid is not exposed; per-block
  `row_equivalents` (quarters ÷ 4) is the stable external measure.

### GET /v1/pruning/{pruning_activity_id}

Same shape (blocks included). A reversed activity returns
`resource_not_found`.

### GET /v1/irrigation-records?vineyard_id={uuid}

Requires `irrigation:read`. Actual irrigation session records with their
server-computed per-block water allocation. `vineyard_id` is **required**.
Optional filters: `from`, `to` (session date), `status`, `block_id`,
`limit`, `cursor`. Newest first.

```json
{
  "id": "cd34...",
  "vineyard_id": "1f0a...",
  "date": "2026-08-05",
  "vintage_year": 2027,
  "status": "completed",
  "started_at": "2026-08-05T18:00:00Z",
  "ended_at": "2026-08-05T22:00:00Z",
  "duration_minutes": 240,
  "calculation_method": "configured_flow",
  "source_type": "manual_ios",
  "flow_l_per_hour": 1200,
  "volume_l": 4800,
  "effective_volume_l": 4320,
  "efficiency_percent": 90,
  "irrigation_system_id": "ef56...",
  "valve_id": "0a1b...",
  "blocks": [
    { "block_id": "77b3...", "block_name": "Block 12", "allocation_percent": 100, "volume_l": 4800 }
  ],
  "notes": null,
  "created_at": "2026-08-05T22:05:00Z",
  "updated_at": "2026-08-05T22:05:00Z"
}
```

- Canonical units: litres, litres/hour, mm, whole minutes (1 L over 1 m²
  = 1 mm depth). Values are the server-computed canonical results — the
  API never recomputes them.
- `status` ∈ `completed`, `corrected`, `reversed`, `planned`, `running`,
  `cancelled`, `imported`, `estimated`. Sessions with `status=reversed`
  are **excluded from the default collection** (they are corrections);
  request them explicitly with `?status=reversed`. Deleted sessions never
  appear.
- Metrics that could not be calculated are `null` — never zero
  (VineTrack's missing-data rule).
- No cost or labour fields exist on irrigation sessions.
- Irrigation system/valve configuration is NOT dumped into the record;
  the record carries only its frozen per-session results plus
  `irrigation_system_id` / `valve_id` references.

### GET /v1/irrigation-records/{irrigation_record_id}

Same shape plus per-block detail metrics — each block gains
`effective_volume_l`, `area_ha` (exact m² ÷ 10000 conversion),
`vine_count`, `water_l_per_vine`, `water_l_per_ha`, `depth_mm`,
`effective_depth_mm` — and display references `system`
(`{ id, name }`) and `valve` (`{ id, name, valve_number }`).
Reversed sessions ARE retrievable by id (explicit status).

### GET /v1/growth-stages?vineyard_id={uuid}

Requires `growth_stages:read`. Recorded E-L growth-stage observations
(canonical store: growth-stage records; legacy pin observations are
mirrored into it by the apps). `vineyard_id` is **required**. Optional
filters: `from`, `to` (observation time), `block_id`, `stage_code`,
`limit`, `cursor`. Newest first.

```json
{
  "id": "f6a7...",
  "vineyard_id": "1f0a...",
  "block_id": "77b3...",
  "block_name": "Block 12",
  "observed_at": "2026-08-04T21:15:00Z",
  "stage_code": "EL-12",
  "stage_label": "5 leaves separated",
  "variety": "Sauvignon Blanc",
  "variety_id": "9d0e...",
  "row_number": 14,
  "side": "left",
  "latitude": -41.2743,
  "longitude": 173.2801,
  "notes": null,
  "created_at": "2026-08-04T21:16:02Z",
  "updated_at": "2026-08-04T21:16:02Z"
}
```

- `stage_code` is the canonical stable E-L code as recorded;
  `stage_label` is its display label.
- `side` is normalised to lowercase `left`/`right` (documented).
- `recorded_by` (`{ user_id, name }`) appears **only** with
  `labour:read`.
- Photo storage paths / attachment URLs are **not** exposed — imagery
  access is a future explicit API design.

### GET /v1/growth-stages/{growth_stage_id}

Same shape; same gating.

### GET /v1/yield-records?vineyard_id={uuid}

Requires `yield:read`. Archived season yield results with per-block
breakdown — VineTrack's recorded yield history. `vineyard_id` is
**required**. Optional filters: `from`, `to` (archive time), `vintage`
(4-digit year), `limit`, `cursor`. Newest first.

```json
{
  "id": "1b2c...",
  "vineyard_id": "1f0a...",
  "season": "2025/26",
  "vintage_year": 2026,
  "archived_at": "2026-04-20T03:00:00Z",
  "total_yield_tonnes": 182.4,
  "total_area_ha": 24.6,
  "yield_tonnes_per_ha": 7.415,
  "blocks": [
    {
      "block_id": "77b3...",
      "block_name": "Block 12",
      "area_ha": 4.2,
      "estimated_yield_tonnes": 31.5,
      "yield_tonnes_per_ha": 7.5,
      "average_bunches_per_vine": 38.2,
      "average_bunch_weight_g": 152,
      "vine_count": 5400,
      "samples_recorded": 20,
      "damage_factor": 1,
      "actual_yield_tonnes": 30.9,
      "actual_recorded_at": "2026-04-19T00:00:00Z"
    }
  ],
  "notes": null,
  "created_at": "2026-04-20T03:00:05Z",
  "updated_at": "2026-04-20T03:00:05Z"
}
```

- Per-block `yield_tonnes_per_ha` is the canonically STORED value; the
  top-level `yield_tonnes_per_ha` is derived
  (`total_yield_tonnes ÷ total_area_ha`, documented) and `null` when the
  area is zero.
- `estimated_yield_tonnes` vs `actual_yield_tonnes` are both preserved
  (estimates from sampling; actuals when recorded at harvest).
- No pricing/revenue fields exist canonically — there is nothing for
  `costs:read` to gate today. If financial grape-sale data is added
  later it will be `costs:read`-gated commercial information.
- In-progress sampling sessions are working data and are **not** exposed.
- Variety is not stored on yield records canonically, so no `variety`
  field (or filter) is invented.

### GET /v1/yield-records/{yield_record_id}

Same shape.

### GET /v1/pins?vineyard_id={uuid}

Requires `pins:read`. Vineyard operational pins — repairs, growth
observations and manual issues — with VineTrack's canonical placement
resolution. `vineyard_id` is **required**. Optional filters: `block_id`,
`status` (`open`, `in_progress`, `completed`, `cancelled`), `category`,
`type` (`repairs`, `growth`, `manual_issue`), `limit`, `cursor`.
Newest first.

```json
{
  "id": "2d3e...",
  "vineyard_id": "1f0a...",
  "type": "repairs",
  "custom_type": null,
  "category": "infrastructure",
  "priority": "high",
  "status": "open",
  "title": "Broken dripper line",
  "notes": "Second span from the end post",
  "growth_stage_code": null,
  "block_id": "77b3...",
  "block_name": "Block 12",
  "latitude": -41.2745,
  "longitude": 173.2803,
  "row": {
    "snapped_to_row": true,
    "path_number": 19.5,
    "row_number": 19,
    "side": "left",
    "along_row_distance_m": 42.7,
    "snapped_latitude": -41.27451,
    "snapped_longitude": 173.28032
  },
  "location": {
    "scope": "point",
    "assignment_basis": "snapped_point",
    "row_summary": null,
    "warning": null
  },
  "due_date": null,
  "work_task_id": null,
  "resolved_at": null,
  "created_at": "2026-08-06T02:10:00Z",
  "updated_at": "2026-08-06T02:10:00Z"
}
```

- **Snapped path/row identity is preserved exactly**: `row.path_number`
  is the driving path (e.g. `19.5`), `row.row_number` the pinned vine
  row, `row.side` `left`/`right` (normalised lowercase). Pins are never
  reduced to raw GPS.
- `location` is VineTrack's server-authoritative placement resolution
  (scope `point`/`row`/`block`; assignment basis e.g. `snapped_point`,
  `row_segments`, `block`, `legacy_block`, `unassigned`;
  `row_summary` like `"Rows 2–4 · Row 5 (sections 1–2)"` for row-scope
  pins).
- `status` derivation (documented): the canonical stored status wins;
  legacy pins without one derive `completed`/`open` from their
  completion flag. `resolved_at` is the completion time. Resolved pins
  remain in the collection as history — filter with `status`.
- `type` is the pin mode (`repairs`, `growth`, `manual_issue`);
  `custom_type` (`{ id, name }`) identifies a vineyard-defined custom
  pin type when used.
- `assigned_to` and `completed_by` (`{ user_id, name }`) appear **only**
  with `labour:read`.
- Photo storage paths are **not** exposed. Duplicate-detection
  diagnostics are internal and not exposed.
- The `block_id` filter matches the pin's stored block link.

### GET /v1/pins/{pin_id}

Same shape plus `row_segments`: the exact row/section selection of a
row-scope pin as `[{ "row": 5, "segment": 1 }, ...]` (sections are
quarters 1–4).

### GET /v1/weather

Singleton environmental document for one granted vineyard. Requires
`weather:read` plus an explicit vineyard grant.

```text
GET /v1/weather?vineyard_id=<uuid>
```

```json
{
  "data": {
    "vineyard_id": "...",
    "current": {
      "temperature_c": 14.2,
      "humidity_percent": 78,
      "wind_speed_kmh": 9.7,
      "wind_gust_kmh": 18.4,
      "wind_direction_degrees": 315,
      "wind_direction": "NW",
      "rainfall_today_mm": 4.2,
      "rainfall_rate_mm_per_hour": 0,
      "leaf_wetness": 3.5,
      "observed_at": "2026-08-10T02:40:00Z",
      "fetched_at": "2026-08-10T02:41:12Z",
      "is_stale": false,
      "source": {
        "provider": "davis_weatherlink",
        "station_id": "123456",
        "station_name": "Home Block Station"
      }
    },
    "current_status": "ok",
    "forecast": [
      {
        "date": "2026-08-10",
        "rain_mm": 2.5,
        "rain_probability_percent": 70,
        "temp_min_c": 6.1,
        "temp_max_c": 15.4,
        "wind_speed_max_kmh": 32,
        "et0_mm": 1.8
      }
    ],
    "forecast_status": "ok",
    "forecast_source": {
      "provider": "willyweather",
      "location": { "latitude": -33.28, "longitude": 149.1, "label": "Orange", "basis": "forecast_location" },
      "horizon_days": 7,
      "fetched_at": "2026-08-10T01:15:03Z",
      "is_stale": false
    }
  },
  "meta": { "generated_at": "2026-08-10T02:41:30Z" }
}
```

**Observed vs forecast — never mixed.** `current` is the vineyard's own
weather-station observation (Davis WeatherLink, the only canonical stored
observation source). `forecast` is provider forecast data. They carry
separate provenance and separate status fields and are never merged into
one ambiguous list.

**Current observation.**

- Served **cache-only** from VineTrack's canonical observation store — a
  public API call can never trigger an upstream station fetch (the same
  rule the apps' RPC enforces).
- `current_status`: `ok` (observation present), `no_data` (station
  configured but nothing cached yet), `not_configured` (no active
  station for this vineyard). `current` is `null` except for `ok`.
- Freshness: `is_stale: true` when the reading is older than **20
  minutes** (VineTrack's canonical staleness threshold). `observed_at`
  is the station's reading time; `fetched_at` is when VineTrack cached it.
- Wind semantics (canonical Davis mapping): `wind_speed_kmh` is the
  station's current wind speed; `wind_gust_kmh` is the recent gust (high
  over the last 10 minutes). `wind_direction_degrees` is the raw bearing;
  `wind_direction` is the derived 16-point compass name.
- `leaf_wetness` is the station's measured leaf-wetness sensor value
  (unitless Davis scale); `null` when the station has no such sensor.
  Missing readings are `null` — never zero.

**Forecast.**

- Provider-abstracted: field names are VineTrack-normalised and survive a
  provider change. The provider chain is the vineyard's canonical
  preference (`auto` | `open_meteo` | `willyweather`); `auto` uses
  WillyWeather when the vineyard has a saved WillyWeather location,
  otherwise Open-Meteo.
- Horizon: up to **7 days** (`horizon_days`), each item with an explicit
  ISO `date`.
- `rain_probability_percent` is available from WillyWeather only
  (Open-Meteo forecast items carry `null`). `et0_mm` provenance differs
  by provider: Open-Meteo supplies FAO ET0 directly; for WillyWeather it
  is VineTrack's deterministic Hargreaves estimate from tmin/tmax (the
  same calculation the apps use).
- Freshness: forecasts are served from a server-side cache with a
  **3-hour TTL** — API traffic can trigger at most one upstream provider
  request per vineyard per window. `forecast_status`: `ok` (fresh),
  `stale` (upstream failed; last good bundle served with
  `is_stale: true`), `unavailable` (upstream failed, no cache),
  `not_configured` (no forecast location/coordinates known).
- `forecast_source.location` explains WHICH place the forecast
  represents: the saved WillyWeather town (`basis:
  "forecast_location"`) or the vineyard's server-resolved coordinates
  (`basis: "station" | "blocks" | "pins"`), rounded to 2 decimal places
  (~1 km) — coarse weather location, never precise private geometry.
- No provider credentials, provider-internal identifiers beyond the safe
  station/location metadata above, signed URLs, or raw provider payloads
  are ever exposed.
- Arbitrary-coordinate lookups are **not supported** — `lat`/`lon`
  parameters are rejected. Environmental data is vineyard-based only.

### GET /v1/rainfall

Daily observed rainfall history for one granted vineyard. Requires
`rainfall:read` plus an explicit vineyard grant.

```text
GET /v1/rainfall?vineyard_id=<uuid>[&from=YYYY-MM-DD&to=YYYY-MM-DD&limit=&cursor=]
```

```json
{
  "data": [
    {
      "date": "2026-08-09",
      "rainfall_mm": 4.2,
      "source": "davis_weatherlink",
      "station": { "id": "123456", "name": "Home Block Station" },
      "notes": null,
      "updated_at": "2026-08-10T00:05:12Z"
    },
    {
      "date": "2026-08-08",
      "rainfall_mm": 0,
      "source": "manual",
      "station": null,
      "notes": "Gauge emptied late",
      "updated_at": "2026-08-09T08:11:00Z"
    }
  ],
  "pagination": { "next_cursor": "eyJkIjoi..." }
}
```

- **Observed rainfall only** — forecast rainfall is never returned here
  (it lives in `/v1/weather` `forecast[].rain_mm`, clearly labelled as
  forecast).
- One record per vineyard-local calendar day that has data; days without
  any recorded rainfall are omitted (this is an observation list, not a
  calendar grid). Aggregation is the consumer's job — records are always
  **daily** (no silent aggregation switching).
- `source` is the canonical provenance of the winning record for that
  day: `manual` (manager-entered, always wins) > `davis_weatherlink`
  (on-vineyard station) > `wunderground_pws` (nearby personal station) >
  `open_meteo` (broad-model gap-fill). Exactly the resolution the apps
  and portal use — the API never shows a different number than VineTrack.
- `station` identifies the recording station where applicable; `notes`
  carries the manual-entry note when present.
- Ordered newest day first; standard `limit` (default 100, max 1000) with
  an opaque date-keyed cursor. `from`/`to` are inclusive ISO dates.
- Retention is indefinite (no expiry) — full history is queryable.

### GET /v1/disease-risk

Current disease-pressure assessment for one granted vineyard. Requires
`disease_risk:read` plus an explicit vineyard grant.

```text
GET /v1/disease-risk?vineyard_id=<uuid>
```

```json
{
  "data": {
    "vineyard_id": "...",
    "calculated_at": "2026-08-10T02:41:30Z",
    "model_version": "mvp-1",
    "wetness_source": "estimated_proxy",
    "weather_source": {
      "provider": "open_meteo",
      "location": { "latitude": -33.28, "longitude": 149.1, "basis": "blocks" },
      "fetched_at": "2026-08-10T02:41:30Z",
      "observed_through": "2026-08-10T02:00:00Z",
      "hours_used": 96,
      "source_status": "ok"
    },
    "risks": [
      {
        "disease": "downy_mildew",
        "risk_level": "medium",
        "summary": "Past 48h: 12.4 mm rain, min 11.0°C, 14 estimated wet hours.",
        "window_hours": 48,
        "inputs": { "rainfall_mm": 12.4, "min_temperature_c": 11, "wet_hours": 14 }
      },
      {
        "disease": "powdery_mildew",
        "risk_level": "low",
        "summary": "1 of last 3 days had 6+ favourable hours (21–30°C, RH ≥ 60%).",
        "window_hours": 72,
        "inputs": { "favourable_days_of_last_3": 1, "latest_temperature_c": 14.2 }
      },
      {
        "disease": "botrytis",
        "risk_level": "low",
        "summary": "6 estimated wet hours in 15–25°C window over past 36h.",
        "window_hours": 36,
        "inputs": { "wet_hours_15_to_25_c": 6 }
      }
    ]
  },
  "meta": {
    "generated_at": "2026-08-10T02:41:30Z",
    "source_updated_at": "2026-08-10T02:41:30Z",
    "is_stale": false
  }
}
```

- **Exactly three disease models exist in VineTrack today** and only
  those are returned: `downy_mildew` (simplified 10:10:24 rule),
  `powdery_mildew` (simplified Gubler-Thomas), `botrytis` (simplified
  Broome/Bulit). The API runs the SAME models the iOS and Android apps
  run — same thresholds, same inputs, same wording.
- `risk_level` is `low` | `medium` | `high`. **No numeric score is
  exposed**: the apps' internal 10/60/90 values are a chart index derived
  from the level, not a canonical score — exposing one would manufacture
  pseudo-precision.
- `wetness_source: "estimated_proxy"` is the canonical caveat: leaf
  wetness is estimated (rain > 0 mm OR RH ≥ 90% OR temperature−dew-point
  ≤ 2°C), not measured.
- `inputs` are the observed model inputs (the "why"), not tunable
  internals. `window_hours` is each model's assessment window.
- Provenance answers all four freshness questions: `calculated_at` (when
  computed), `weather_source.observed_through` (the weather-data window's
  end), `weather_source.source_status` (`ok` | `stale_fallback`), and
  `model_version` (`mvp-1` — bumped whenever the shared models change so
  consumers can interpret shifts safely; no algorithm was changed for
  this API).
- **Current risk only.** VineTrack does not store historical disease-risk
  results, so no history endpoint is pretended — there is no date filter.
- Freshness: computed at most once per vineyard per **30 minutes**
  (cached server-side). If the weather source is unreachable, the last
  assessment (up to 24 h old) is served with
  `weather_source.source_status: "stale_fallback"` and `meta.is_stale:
  true`. With no coordinates or no usable cache the endpoint returns
  `503 disease_risk_unavailable` — upstream provider errors are never
  leaked.
- This endpoint returns calculated risk output — measured environmental
  data lives in `/v1/weather` and `/v1/rainfall`, and no free-form
  agronomy advice is generated.

## Collection vs detail representation

Collections return an efficient summary; single-record endpoints return
full detail. Specifically: `/v1/spray-jobs` collections include tank/
product COUNTS and names but not the full tank mix — `GET
/v1/spray-jobs/{id}` returns full `tanks`, `blocks` and the linked plan
header. `/v1/trips` collections omit the `rows` work summary and `costs`
object — both are detail-only. `/v1/work-tasks` collections omit
`labour_lines` / `machine_lines` / `trip_ids` (detail-only).
`/v1/irrigation-records` collections carry per-block allocation percent
and volume only; full per-block metrics are detail-only. `/v1/pins`
collections omit `row_segments` (detail-only).

## curl examples

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/me"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/vineyards"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/vineyards/<VINEYARD_UUID>"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/blocks?vineyard_id=<VINEYARD_UUID>&limit=100"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/blocks/<BLOCK_UUID>"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/trips?vineyard_id=<VINEYARD_UUID>&from=2026-07-01&to=2026-07-31"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/spray-jobs/<SPRAY_RECORD_UUID>"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/fuel-purchases?vineyard_id=<VINEYARD_UUID>"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/equipment?vineyard_id=<VINEYARD_UUID>&type=tractor"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/work-tasks?vineyard_id=<VINEYARD_UUID>&from=2026-07-01&to=2026-07-31"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/pruning?vineyard_id=<VINEYARD_UUID>&block_id=<BLOCK_UUID>"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/irrigation-records?vineyard_id=<VINEYARD_UUID>&status=completed"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/pins?vineyard_id=<VINEYARD_UUID>&status=open&type=repairs"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/weather?vineyard_id=<VINEYARD_UUID>"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/rainfall?vineyard_id=<VINEYARD_UUID>&from=2026-01-01&to=2026-08-10"
```

```bash
curl \
  -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/disease-risk?vineyard_id=<VINEYARD_UUID>"
```

Never embed real production keys in source code, docs, or client-side apps.

### PowerShell note

`Invoke-RestMethod` / `Invoke-WebRequest` throw on 4xx/5xx and hide the
response body by default — the JSON error envelope IS returned by the API.
To see it:

```powershell
try { Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $key" } }
catch { $_.ErrorDetails.Message }
```

Or use `curl.exe` (not the PowerShell alias) which prints the body as-is.

## Creating test credentials

Use the existing Stage 2 management RPCs (as a vineyard Owner) — there is no
second key mechanism:

```sql
select integration_create_client('My Test Integration', 'custom_api', null);
select integration_grant_vineyard('<integration_id>', '<vineyard_id>');
select integration_grant_scope('<integration_id>', 'vineyards:read');
select integration_grant_scope('<integration_id>', 'blocks:read');
select integration_grant_scope('<integration_id>', 'trips:read');
select integration_grant_scope('<integration_id>', 'sprays:read');
select integration_grant_scope('<integration_id>', 'fuel:read');
select integration_grant_scope('<integration_id>', 'equipment:read');
select integration_grant_scope('<integration_id>', 'work_tasks:read');
select integration_grant_scope('<integration_id>', 'pruning:read');
select integration_grant_scope('<integration_id>', 'irrigation:read');
select integration_grant_scope('<integration_id>', 'growth_stages:read');
select integration_grant_scope('<integration_id>', 'yield:read');
select integration_grant_scope('<integration_id>', 'pins:read');
select integration_grant_scope('<integration_id>', 'weather:read');
select integration_grant_scope('<integration_id>', 'rainfall:read');
select integration_grant_scope('<integration_id>', 'disease_risk:read');
-- Sensitive scopes only when the integration truly needs them:
-- select integration_grant_scope('<integration_id>', 'costs:read');
-- select integration_grant_scope('<integration_id>', 'labour:read');
select integration_create_api_key('<integration_id>', 'test', 'dev key', null);
-- The 'secret' field of the last result is shown ONCE. Store it now.
```

## Deployment (engineering)

- Function: `supabase/functions/vinetrack-api` on project
  `tbafuqwruefgkbyxrxyb`.
- Deploy via `scripts/deploy-edge-functions.ps1` / `.sh` (the scripts pass
  `--no-verify-jwt` for this function — callers present VineTrack keys, not
  Supabase JWTs).
- Requires SQL 172 + SQL 173 + SQL 174 + SQL 175 + SQL 176 applied first.
- OpenAPI 3.1 document: `docs/vinetrack-api-openapi.yaml` (descriptive —
  the implementation remains canonical).
- Secrets: the standard Supabase-injected `SUPABASE_URL` and
  `SUPABASE_SERVICE_ROLE_KEY`. Optional: `VINETRACK_API_RATE_LIMIT_PER_MINUTE`
  (default 300), `VINETRACK_API_CORS_ORIGINS` (comma-separated exact origins;
  default: no browser origins allowed — this is a server-to-server API),
  and `WILLYWEATHER_API_KEY` (the existing global project secret — used only
  to refresh the per-vineyard forecast cache; without it WillyWeather-backed
  forecasts report `not_configured` and everything else still works).
- HTTP test harness: `scripts/test-vinetrack-api.sh`.
