# VineTrack API — v1 (Stage 3A + Stage 3B)

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

Unknown query parameters are **rejected** with `invalid_request` (never
silently ignored) so integration mistakes surface immediately.

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
    `fuel-records`, `fuel-purchases`): `created_at` then `id`,
    **descending** — newest records first. `created_at` (not the business
    date) is the sort key because it is NOT NULL on every operational
    table, which keeps the keyset cursor deterministic; business-date
    filtering is provided separately via `from`/`to`.

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

## Units

Field names carry their unit explicitly: `distance_km`, `volume_l`,
`water_volume_l`, `treated_area_ha`, `duration_minutes`, `row_width_m`,
`tank_capacity_l`, `fuel_usage_l_per_hour`, `price_per_litre`,
`temperature_c`, `wind_speed_kmh`, `humidity_percent`. Spray product
rates/quantities keep the product's recorded unit (`Litres`, `mL`, `Kg`,
`g`) in a `unit` field and are never converted.

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

## Collection vs detail representation

Collections return an efficient summary; single-record endpoints return
full detail. Specifically: `/v1/spray-jobs` collections include tank/
product COUNTS and names but not the full tank mix — `GET
/v1/spray-jobs/{id}` returns full `tanks`, `blocks` and the linked plan
header. `/v1/trips` collections omit the `rows` work summary and `costs`
object — both are detail-only.

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
- Requires SQL 172 + SQL 173 + SQL 174 applied first.
- OpenAPI 3.1 document: `docs/vinetrack-api-openapi.yaml` (descriptive —
  the implementation remains canonical).
- Secrets: only the standard Supabase-injected `SUPABASE_URL` and
  `SUPABASE_SERVICE_ROLE_KEY`. Optional: `VINETRACK_API_RATE_LIMIT_PER_MINUTE`
  (default 300), `VINETRACK_API_CORS_ORIGINS` (comma-separated exact origins;
  default: no browser origins allowed — this is a server-to-server API).
- HTTP test harness: `scripts/test-vinetrack-api.sh`.
