# VineTrack Developer Platform — v1

The canonical guide for external developers integrating with VineTrack.
It consolidates the API contract, scopes, vineyard grants, pagination,
errors, rate limits, webhooks, signing, retries, replay semantics,
onboarding and versioning into one source of truth.

Companion documents (all must agree with this guide):

- `docs/vinetrack-api-v1.md` — deep field-level API reference (every
  response field, unit and derivation documented).
- `docs/vinetrack-webhooks.md` — deep webhook reference (delivery states,
  management RPCs, deployment).
- `docs/openapi/vinetrack-v1.yaml` — machine-readable OpenAPI 3.1 spec.
- `docs/webhooks/vinetrack-events-v1.json` — machine-readable event catalogue.
- `docs/postman/VineTrack-v1.postman_collection.json` — Postman collection.
- `docs/vinetrack-api-changelog.md` — the developer-facing change history.

The API is **read-only** in v1. There are no public write endpoints.

---

## 1. Getting started — first API request in 10 minutes

Base URL (production):

```text
https://<vinetrack-api-host>/v1
```

For VineTrack's hosted platform the API host is the
`vinetrack-api` function endpoint, e.g.
`https://<project-ref>.supabase.co/functions/v1/vinetrack-api`. Your
VineTrack account owner can copy the exact base URL from the integrations
page. All examples below write `{base}` for it.

1. **Create an integration.** In VineTrack, the account owner opens the
   integration management surface and creates an integration client
   (e.g. "Packhouse Sync").
2. **Grant vineyard access.** Explicitly grant the integration each
   vineyard it may read. Nothing is inherited.
3. **Grant scopes.** Grant the read scopes the integration needs
   (e.g. `vineyards:read`, `trips:read`). See the scope table below.
4. **Create an API key.** Choose the environment (`live` or `test`) and,
   optionally, an expiry.
5. **Copy the key once.** The plaintext key (`vt_live_…` / `vt_test_…`)
   is shown exactly once. Store it in a secret manager immediately —
   it can never be retrieved again, by anyone.
6. **Call `/v1/me`** to confirm authentication and see your grants:

   ```bash
   curl \
     -H "Authorization: Bearer vt_live_REPLACE_ME" \
     "{base}/v1/me"
   ```

7. **List your vineyards** (requires `vineyards:read`):

   ```bash
   curl \
     -H "Authorization: Bearer vt_live_REPLACE_ME" \
     "{base}/v1/vineyards"
   ```

8. **Fetch an operational resource** (requires the resource scope, and
   `vineyard_id` is required on every operational collection):

   ```bash
   curl \
     -H "Authorization: Bearer vt_live_REPLACE_ME" \
     "{base}/v1/trips?vineyard_id=00000000-0000-4000-8000-000000000001&limit=10"
   ```

9. **Optional — configure a webhook endpoint.** In the integration
   management surface, add an HTTPS endpoint URL and copy its signing
   secret (`whsec_…`, also shown exactly once). Subscribe it to events.
10. **Send a test webhook.** Use *Send test webhook* and verify the
    signature on your receiver (section 12) before going live.

---

## 2. Authentication

Every request must carry a VineTrack API key as a bearer token:

```text
Authorization: Bearer vt_live_xxxxxxxx...
```

- **Key format**: `vt_live_` or `vt_test_` followed by 48 hex characters.
  The `environment` field (`live` | `test`) is recorded on the key.
- **Shown once**: the plaintext is returned exactly once at creation.
  Only a SHA-256 hash is stored server-side — the plaintext is
  unrecoverable afterwards, including by VineTrack administrators.
- **Key prefix**: the first characters (e.g. `vt_live_a1b2c3d4`) are kept
  for display so you can identify keys without exposing them.
- **Expiry**: keys may carry an optional `expires_at`; expired keys are
  rejected with `expired_api_key`.
- **Revocation**: keys can be revoked at any time; revoked keys are
  rejected with `revoked_api_key`. Revocation is immediate.
- **Last used**: a `last_used_at` timestamp is maintained (updated at
  most once per minute) so unused keys can be identified and removed.
- **Not accepted**: Supabase JWTs, and credentials in the query string
  (`?api_key=…` and similar are rejected with `invalid_request`).

**Storage practice.** Treat API keys like passwords: keep them in a
server-side secret manager, scope one key per system, rotate by creating
a new key and revoking the old, and never commit them to source control.

> **Never embed API keys in public or mobile client applications.**
> Keys grant vineyard-level data access and cannot be restricted to a
> device. Always call the VineTrack API from your own backend.

---

## 3. The vineyard access model

Access to any vineyard-scoped data requires **both**:

1. an explicit **vineyard grant** — the integration has been granted that
   specific vineyard; and
2. an explicit **scope grant** — the integration holds the scope the
   route (or webhook event) requires.

Neither alone is sufficient. Grants belong to the **integration**, not to
the person who created it — nothing is inherited from the creator's
personal access, and removing a person does not silently change what an
integration can read. Revoking a vineyard grant or scope takes effect
immediately (and also cancels queued webhook deliveries for it).

Requesting an ungranted vineyard returns `vineyard_access_denied` on
collections; direct `/{id}` lookups in ungranted vineyards return
`resource_not_found` — the existence of ungranted data is never disclosed.

---

## 4. Scopes

Scopes never imply each other. Sensitive scopes are additive — they gate
extra fields on top of a base resource scope and never grant route access
on their own.

### Resource scopes

| Scope | Label | Exposes | Sensitive | Routes / events |
|---|---|---|---|---|
| `vineyards:read` | Vineyards | Vineyard names, country, timezone | No | `/v1/vineyards`, `/v1/vineyards/{id}` |
| `blocks:read` | Blocks | Block structure: names, rows, varieties, planting (no geometry) | No | `/v1/blocks`, `/v1/blocks/{id}`; `block.*` events |
| `trips:read` | Trips | Machine trip records: timing, distance, blocks, equipment (no GPS paths) | No | `/v1/trips`, `/v1/trips/{id}`; `trip.*` events |
| `sprays:read` | Sprays | Completed spray applications: products, rates, conditions, water/area | No | `/v1/spray-jobs`, `/v1/spray-jobs/{id}`; `spray_job.*` events |
| `fuel:read` | Fuel | Fuel usage fills and bulk purchases: dates, volumes, equipment | No | `/v1/fuel-records`, `/v1/fuel-purchases` (+`/{id}`); `fuel_log.*`, `fuel_purchase.created` events |
| `equipment:read` | Equipment | Machinery catalogue: machines, sprayers, items | No | `/v1/equipment`, `/v1/equipment/{id}` |
| `work_tasks:read` | Work tasks | General vineyard work tasks with labour/machine lines (identities and costs gated separately) | No | `/v1/work-tasks`, `/v1/work-tasks/{id}`; `work_task.*` events |
| `pruning:read` | Pruning | Pruning activity records: dates, vines pruned, per-block progress | No | `/v1/pruning`, `/v1/pruning/{id}`; `pruning_activity.*` events |
| `irrigation:read` | Irrigation | Irrigation sessions with per-block water allocation | No | `/v1/irrigation-records`, `/v1/irrigation-records/{id}`; `irrigation_record.*` events |
| `growth_stages:read` | Growth stages | E-L growth-stage observations | No | `/v1/growth-stages`, `/v1/growth-stages/{id}`; `growth_stage.recorded` event |
| `yield:read` | Yield | Archived season yield results with per-block breakdown | No | `/v1/yield-records`, `/v1/yield-records/{id}`; `yield_record.*` events |
| `pins:read` | Pins | Operational map pins: repairs, growth observations, issues | No | `/v1/pins`, `/v1/pins/{id}`; `pin.*` events |
| `weather:read` | Weather | Current station observation + forecast for granted vineyards | No | `/v1/weather` |
| `rainfall:read` | Rainfall | Daily observed rainfall history | No | `/v1/rainfall` |
| `disease_risk:read` | Disease risk | Current disease-pressure assessment | No | `/v1/disease-risk` |

### Sensitive scopes (additive field gates)

| Scope | Label | Exposes | Sensitive |
|---|---|---|---|
| `costs:read` | Costs | Monetary values on operational resources (fuel prices, chemical costs, labour rates/costs, trip cost summaries) | **Yes** |
| `labour:read` | Labour | The limited worker/operator identity fields the API permits: operator/recorder/assignee references (`user_id` + display name) and pruning crew snapshots | **Yes** |
| `team:read` | Team | Catalogued for future team-directory exposure; **no route or event uses it in v1** | **Yes** |

`labour:read` never exposes contact details, payroll data, authentication
records or any personal information beyond the identity references listed
above. `costs:read` never exposes bank, invoice or supplier data (none is
stored canonically).

### Write scopes (Stage 8)

Five write scopes are **active**. Write permission always requires ALL of:
active integration + valid (non-expired, non-revoked) API key + explicit
vineyard grant + the write scope. Read scopes never permit writes.

| Scope | Enables | Routes |
|---|---|---|
| `work_tasks:write` | Create/update work tasks — operational fields only (labour & machine cost lines are not writable externally) | `POST /v1/work-tasks`, `PATCH /v1/work-tasks/{id}` |
| `fuel:write` | Create/update operational fuel log entries — no cost, purchasing or operator identity fields | `POST /v1/fuel-records`, `PATCH /v1/fuel-records/{id}` |
| `irrigation:write` | Record irrigation sessions — create-only; VineTrack's calculation core derives volume, allocations, efficiency and vintage | `POST /v1/irrigation-records` |
| `growth_stages:write` | Record E-L growth-stage observations — create-only, catalogue codes only | `POST /v1/growth-stages` |
| `yield:write` | Create/update archived season yield records (canonical per-block shape) | `POST /v1/yield-records`, `PATCH /v1/yield-records/{id}` |

The remaining write scopes (`trips:write`, `sprays:write`,
`pruning:write`, `equipment:write`, `pins:write`) stay **reserved** — no
public write endpoint exists for them and granting them has no effect.
`pins:write` is deliberately deferred: pin placement (row/side/snapping)
is resolved on-device at capture time and no server-side placement
resolver exists, so external coordinates cannot pass through VineTrack's
canonical placement resolution — pins remain read-only. There is **no
public DELETE endpoint** of any kind, and no write surface for users,
team, billing, vineyard structure, chemicals or spray records.

### Sensitive-field gating summary

Sensitive fields are **omitted** (never `null`-ed) when the extra scope is
absent. The base scope is always required first.

| Resource | With `labour:read` | With `costs:read` |
|---|---|---|
| Trip | `operator` | detail `costs.*` (`labour_cost` needs **both** scopes) |
| Spray detail | — | `tanks[].products[].cost_per_unit`, `chemical_cost_total` |
| Fuel record | `operator` | `cost_per_litre`, `total_cost` |
| Fuel purchase | — | `total_price`, `price_per_litre` |
| Work task detail | `machine_lines[].operator` | labour/machine line `hourly_rate`, `total_cost`, `fuel_cost` |
| Pruning | `crew` | `hourly_rate`, `labour_cost` |
| Growth stage | `recorded_by` | — |
| Pin | `assigned_to`, `completed_by` | — |
| Yield record | — | — (no pricing fields exist in v1) |
| Weather / rainfall / disease risk | — | — |

---

## 5–6. REST API catalogue

All resources are readable with `GET`; five resources additionally accept
writes (`POST`/`PATCH` — see §6b). Unsupported methods on a known route
return 405 `method_not_allowed`; there are no DELETE routes.
`vineyard_id` is **required** on every collection except `/v1/vineyards`
and `/v1/me`. Unknown query parameters are rejected with
`invalid_request`. Every route additionally requires an active vineyard
grant for the vineyard context it touches (section 3).

Common errors on all routes: `missing_api_key`, `invalid_api_key`,
`expired_api_key`, `revoked_api_key`, `integration_not_active`,
`insufficient_scope`, `rate_limit_exceeded`, `invalid_request`,
`internal_error` — plus `vineyard_access_denied` (collections),
`resource_not_found` (`/{id}` routes and unknown paths), `invalid_cursor`
(paginated routes).

### 6b. Write API (Stage 8)

| Route | Scope | Notes |
|---|---|---|
| `POST /v1/work-tasks` | `work_tasks:write` | `Idempotency-Key` required; `vineyard_id`, `task_type`, `date` required in the body; optional `description`, `status`, `notes`, `start_date`, `end_date`, `duration_hours`, `block_ids[]`, `external_id` |
| `PATCH /v1/work-tasks/{id}` | `work_tasks:write` | Partial update; `expected_updated_at` required; finalised/archived tasks refuse edits (409) |
| `POST /v1/fuel-records` | `fuel:write` | `Idempotency-Key` required; `vineyard_id`, `date`, `volume_l` required; optional `equipment_id`, `engine_hours`, `filled_to_full`, `notes`, `external_id`. Cost fields are never writable |
| `PATCH /v1/fuel-records/{id}` | `fuel:write` | Partial update; `expected_updated_at` required |
| `POST /v1/irrigation-records` | `irrigation:write` | `Idempotency-Key` required; `vineyard_id`, `system_id`, `valve_id`, `date`, `duration_minutes`, `calculation_method` (+ the method's raw inputs). Create-only — corrections use the in-app reverse/re-record workflow |
| `POST /v1/growth-stages` | `growth_stages:write` | `Idempotency-Key` required; `vineyard_id`, `stage_code` (catalogue E-L code); optional `observed_at`, `block_id`, `variety`, `notes`, `external_id`. Create-only |
| `POST /v1/yield-records` | `yield:write` | `Idempotency-Key` required; `vineyard_id`, `vintage_year`; optional `season`, totals, `notes`, `blocks[]`, `external_id`. Totals derive from blocks when omitted |
| `PATCH /v1/yield-records/{id}` | `yield:write` | Partial update; `expected_updated_at` required; `blocks` replaces the full set and re-derives totals |

**Idempotency (every POST).** Send an `Idempotency-Key` header (1–255
chars, your choice — a UUID per logical operation is ideal). Retrying with
the same key and the same payload returns the original result (same
record, `Idempotency-Replayed: true` header, no duplicate). The same key
with a **different** payload returns `409 idempotency_conflict`. Keys are
stored durably server-side — replay protection survives network retries
and server restarts. Missing key → `400 idempotency_required`.

**Concurrency (every PATCH).** Include `expected_updated_at` — the exact
`updated_at` from your latest GET. If the record changed since (in the
apps, the portal, or by another integration), you get `409 conflict` and
nothing is overwritten: re-GET, re-apply, retry. PATCH is a partial
update: omitted fields stay unchanged; `null` clears only nullable
fields. The record's vineyard, canonical id, provenance and finalisation
flags can never be changed.

**Provenance.** API-created records carry `origin: "integration"` in
every read response (VineTrack-created records show `origin:
"vinetrack"`). The creating integration is recorded server-side and the
record is never attributed to a human user.

**External IDs.** Optionally supply `external_id` (1–255 chars) — your
system's identifier for the record. It is scoped to your integration,
unique per resource type among live records (duplicate → `409 conflict`),
returned in all read/write responses and in webhook payloads, and never
replaces the VineTrack UUID. Only the integration that created a record
may set or change its `external_id` — mappings cannot be claimed on
VineTrack-created records or hijacked across integrations.

**Responses.** Creates return `201`, updates `200`, both with the full
canonical resource representation under `data` (including the VineTrack
`id`, your `external_id`, `origin` and timestamps) — no follow-up GET
needed. Validation problems return `422 validation_failed` with safe
field-level `details` (`[{field, issue}]`).

**Webhooks & loop prevention.** External writes flow through the exact
same canonical event pipeline as in-app writes — e.g. a successful
`POST /v1/work-tasks` emits `work_task.created` to your subscribed
endpoints. Event payloads now carry `origin` (and `external_id` when set,
additive and backwards-compatible), so a receiver can ignore events for
records it created itself: check `origin == "integration"` and match
`external_id` against your own mappings.

### Core

| Route | Scope | Query parameters |
|---|---|---|
| `GET /v1/me` | authentication only | — |
| `GET /v1/vineyards` | `vineyards:read` | `limit`, `cursor` |
| `GET /v1/vineyards/{vineyard_id}` | `vineyards:read` | — |
| `GET /v1/blocks` | `blocks:read` | `vineyard_id` (required), `limit`, `cursor` |
| `GET /v1/blocks/{block_id}` | `blocks:read` | — |

Example — `GET {base}/v1/vineyards`:

```json
{
  "data": [
    {
      "id": "00000000-0000-4000-8000-000000000001",
      "name": "Riverbend Estate",
      "country_code": "AU",
      "country": "Australia",
      "timezone": "Australia/Sydney",
      "created_at": "2025-03-01T02:11:09Z",
      "updated_at": "2026-07-30T22:41:53Z"
    }
  ],
  "pagination": { "next_cursor": null }
}
```

### Operations

| Route | Scope | Query parameters | Sensitive extras |
|---|---|---|---|
| `GET /v1/trips` | `trips:read` | `vineyard_id`*, `from`, `to`, `equipment_id`, `limit`, `cursor` | `operator` (labour) |
| `GET /v1/trips/{trip_id}` | `trips:read` | — | `operator` (labour); `costs` (costs; `labour_cost` needs both) |
| `GET /v1/spray-jobs` | `sprays:read` | `vineyard_id`*, `from`, `to`, `limit`, `cursor` | — |
| `GET /v1/spray-jobs/{spray_job_id}` | `sprays:read` | — | product costs (costs) |
| `GET /v1/fuel-records` | `fuel:read` | `vineyard_id`*, `from`, `to`, `equipment_id`, `limit`, `cursor` | `operator` (labour); prices (costs) |
| `GET /v1/fuel-records/{fuel_record_id}` | `fuel:read` | — | same |
| `GET /v1/fuel-purchases` | `fuel:read` | `vineyard_id`*, `from`, `to`, `limit`, `cursor` | prices (costs) |
| `GET /v1/fuel-purchases/{fuel_purchase_id}` | `fuel:read` | — | prices (costs) |
| `GET /v1/equipment` | `equipment:read` | `vineyard_id`*, `type`, `limit`, `cursor` | — |
| `GET /v1/equipment/{equipment_id}` | `equipment:read` | — | — |

`equipment` `type` accepts `machine`, `sprayer`, `item` or a machine
subtype (`tractor`, `atv`, `side_by_side`, `harvester`,
`utility_vehicle`, `other_vineyard_machine`).

Example — `GET {base}/v1/trips?vineyard_id=…&limit=1`:

```json
{
  "data": [
    {
      "id": "00000000-0000-4000-8000-00000000000a",
      "vineyard_id": "00000000-0000-4000-8000-000000000001",
      "title": "Trim rows 40-60",
      "function": "mowing",
      "status": "completed",
      "started_at": "2026-08-01T21:04:11Z",
      "ended_at": "2026-08-01T23:40:52Z",
      "duration_minutes": 149,
      "distance_km": 12.482,
      "block_ids": ["00000000-0000-4000-8000-00000000000b"],
      "block_name": "Block 12",
      "equipment_id": "00000000-0000-4000-8000-00000000000c",
      "equipment_name": "Example Tractor 5075",
      "work_task_id": null,
      "tank_count": 2,
      "engine_hours_start": 1204.5,
      "engine_hours_end": 1207.1,
      "notes": null,
      "created_at": "2026-08-01T21:04:12Z",
      "updated_at": "2026-08-01T23:40:53Z"
    }
  ],
  "pagination": { "next_cursor": null }
}
```

GPS paths and coordinates are never exposed on trips.

### Vineyard records

| Route | Scope | Query parameters | Sensitive extras |
|---|---|---|---|
| `GET /v1/work-tasks` | `work_tasks:read` | `vineyard_id`*, `from`, `to`, `status`, `task_type`, `block_id`, `limit`, `cursor` | — |
| `GET /v1/work-tasks/{work_task_id}` | `work_tasks:read` | — | line costs (costs); `machine_lines[].operator` (labour) |
| `GET /v1/pruning` | `pruning:read` | `vineyard_id`*, `from`, `to`, `block_id`, `limit`, `cursor` | `crew` (labour); rates (costs) |
| `GET /v1/pruning/{pruning_activity_id}` | `pruning:read` | — | same |
| `GET /v1/irrigation-records` | `irrigation:read` | `vineyard_id`*, `from`, `to`, `status`, `block_id`, `limit`, `cursor` | — |
| `GET /v1/irrigation-records/{irrigation_record_id}` | `irrigation:read` | — | — |
| `GET /v1/growth-stages` | `growth_stages:read` | `vineyard_id`*, `from`, `to`, `block_id`, `stage_code`, `limit`, `cursor` | `recorded_by` (labour) |
| `GET /v1/growth-stages/{growth_stage_id}` | `growth_stages:read` | — | same |
| `GET /v1/yield-records` | `yield:read` | `vineyard_id`*, `from`, `to`, `vintage`, `limit`, `cursor` | — |
| `GET /v1/yield-records/{yield_record_id}` | `yield:read` | — | — |
| `GET /v1/pins` | `pins:read` | `vineyard_id`*, `block_id`, `status`, `category`, `type`, `limit`, `cursor` | `assigned_to`, `completed_by` (labour) |
| `GET /v1/pins/{pin_id}` | `pins:read` | — | same |

Notes:

- `irrigation-records` `status` ∈ `completed`, `corrected`, `reversed`,
  `planned`, `running`, `cancelled`, `imported`, `estimated`; reversed
  sessions are excluded by default and retrievable via `?status=reversed`.
- `pins` `status` ∈ `open`, `in_progress`, `completed`, `cancelled`;
  `type` ∈ `repairs`, `growth`, `manual_issue`. Pins have no date filter.
- `yield-records` `vintage` is a 4-digit year.
- Reversed pruning activities are omitted entirely (they no longer count).

Example — `GET {base}/v1/pins?vineyard_id=…&status=open&limit=1`:

```json
{
  "data": [
    {
      "id": "00000000-0000-4000-8000-00000000000d",
      "vineyard_id": "00000000-0000-4000-8000-000000000001",
      "type": "repairs",
      "custom_type": null,
      "category": "infrastructure",
      "priority": "high",
      "status": "open",
      "title": "Broken dripper line",
      "notes": "Second span from the end post",
      "growth_stage_code": null,
      "block_id": "00000000-0000-4000-8000-00000000000b",
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
  ],
  "pagination": { "next_cursor": null }
}
```

### Environmental

| Route | Scope | Query parameters | Shape |
|---|---|---|---|
| `GET /v1/weather` | `weather:read` | `vineyard_id` (required) | singleton — `data` + `meta`, not paginated |
| `GET /v1/rainfall` | `rainfall:read` | `vineyard_id`*, `from`, `to`, `limit`, `cursor` | daily list, date-keyed cursor |
| `GET /v1/disease-risk` | `disease_risk:read` | `vineyard_id` (required) | singleton — `data` + `meta`; `disease_risk_unavailable` 503 when nothing can be served |

None of the environmental routes has a `/{id}` form. Arbitrary
coordinate lookups are not supported — environmental data is
vineyard-based only. Stale cached data is served with `is_stale: true`
markers and HTTP 200; errors are reserved for "nothing can be served".

Full field-level semantics for every route (units, derivations,
null-handling, provenance) are documented in `docs/vinetrack-api-v1.md`.

---

## 7. Response envelope

Exact envelopes (no others exist):

Single resource:

```json
{ "data": { "id": "..." } }
```

Collection:

```json
{ "data": [], "pagination": { "next_cursor": null } }
```

Environmental singletons (`/v1/weather`, `/v1/disease-risk`):

```json
{ "data": {}, "meta": { "generated_at": "2026-08-10T02:41:30Z" } }
```

Error:

```json
{
  "error": {
    "code": "vineyard_access_denied",
    "message": "This integration is not authorised for the requested vineyard.",
    "request_id": "req_0123456789abcdef0123456789abcdef"
  }
}
```

Every response carries the headers `X-VineTrack-Request-ID`
(`req_<32 hex>`) and `X-VineTrack-API-Version: v1`. **Log the request ID
with every call** — quoting it to VineTrack support correlates directly
with the server-side API request log.

---

## 8. Pagination

Collections use opaque **cursor** pagination (never offsets):

```text
GET /v1/blocks?vineyard_id=<uuid>&limit=100
GET /v1/blocks?vineyard_id=<uuid>&limit=100&cursor=<next_cursor>
```

- `limit`: default **100**, maximum **1000** (`invalid_request` above).
- `cursor`: the previous page's `pagination.next_cursor`. Opaque — do not
  construct or parse. Malformed cursors return `invalid_cursor`.
- `next_cursor: null` means the last page.
- Ordering is stable keyset iteration (no duplicates, no gaps):
  - structural resources (`vineyards`, `blocks`, `equipment`):
    `created_at` then `id`, ascending;
  - operational resources: `created_at` then `id`, **descending**
    (newest first);
  - `/v1/rainfall`: keyed on the calendar date, newest day first.

Fetch the next page by repeating the request with the returned cursor;
stop when `next_cursor` is `null`.

---

## 9. Rate limits

- **300 requests per minute per API key** (server-configurable), counted
  in a fixed 60-second window shared across all API servers.
- Every authenticated response includes `X-RateLimit-Limit` and
  `X-RateLimit-Remaining`.
- On breach: HTTP **429** with error code `rate_limit_exceeded` and a
  `Retry-After` header (seconds until the window resets).

Recommended client behaviour:

- On 429, wait the `Retry-After` seconds before retrying.
- Use exponential backoff with jitter for 5xx/network errors.
- **Do not** aggressively retry 401/403 responses — an invalid, expired
  or revoked key, or a missing scope/grant, will not fix itself; alert a
  human instead.
- Spread scheduled bulk pulls; use `from`/`to` filters rather than
  re-reading full history.

---

## 10. Error catalogue

| Code | HTTP | Meaning | Retry? |
|---|---|---|---|
| `missing_api_key` | 401 | No `Authorization` header | No — fix the request |
| `invalid_api_key` | 401 | Credential unknown or malformed | No |
| `expired_api_key` | 401 | Credential past its expiry | No — issue a new key |
| `revoked_api_key` | 401 | Credential revoked | No |
| `integration_not_active` | 403 | Integration paused or revoked | No — resolve with the vineyard owner |
| `insufficient_scope` | 403 | Required scope not granted | No |
| `vineyard_access_denied` | 403 | Integration not authorised for the requested vineyard | No |
| `resource_not_found` | 404 | Resource does not exist **or is not accessible** (existence never disclosed) | No |
| `invalid_request` | 400 | Malformed/unsupported/missing parameter, or credential in the query string | No — fix the request |
| `invalid_cursor` | 400 | Unreadable pagination cursor | No — restart iteration |
| `rate_limit_exceeded` | 429 | Per-key limit exceeded | Yes — after `Retry-After` |
| `method_not_allowed` | 405 | Method not supported on this endpoint (no DELETE anywhere) | No |
| `validation_failed` | 422 | Body failed validation — see field-level `details` | No — fix the payload |
| `idempotency_required` | 400 | POST without an `Idempotency-Key` header | No — add the header |
| `idempotency_conflict` | 409 | Same `Idempotency-Key` reused with a different payload | No — use a new key |
| `conflict` | 409 | Stale `expected_updated_at`, duplicate `external_id`, or an immutable/locked record | Re-GET, then retry |
| `internal_error` | 500 | Unexpected failure | Yes — with backoff; quote `request_id` to support |
| `disease_risk_unavailable` | 503 | Disease risk could not be computed and no recent cache exists | Yes — later |

---

## 11. Webhooks

Webhooks notify your system *that* something changed; the read API stays
the authoritative source for *what* it now looks like. Payloads are
compact (identifiers + at most a small lifecycle field) and **never**
contain cost, labour or team data.

An endpoint receives an event only when ALL hold at delivery time:
integration active, endpoint active, event's vineyard actively granted,
event's required scope actively granted, and a matching subscription
exists. Revoking a grant/scope stops future deliveries, cancels queued
ones and blocks replays.

Every delivery is an HTTP `POST` with headers:

| Header | Meaning |
|---|---|
| `X-VineTrack-Event` | Event type, e.g. `trip.completed` |
| `X-VineTrack-Delivery` | Delivery id `dlv_…` — unique per delivery; a replay gets a NEW id |
| `X-VineTrack-Timestamp` | Unix seconds used in the signed message |
| `X-VineTrack-Signature` | `v1=<hex HMAC-SHA256>` (see below) |
| `X-VineTrack-API-Version` | `v1` |

Envelope body (fixed key order):

```json
{
  "id": "evt_0123456789abcdef0123456789abcdef",
  "type": "trip.completed",
  "api_version": "v1",
  "occurred_at": "2026-08-10T01:02:03.456Z",
  "vineyard_id": "00000000-0000-4000-8000-000000000001",
  "data": {
    "id": "00000000-0000-4000-8000-00000000000a",
    "end_time": "2026-08-10T01:00:00+00:00"
  }
}
```

### Signature contract

```text
signed_message = "<X-VineTrack-Timestamp>" + "." + <raw request body>
X-VineTrack-Signature: v1=HEX( HMAC_SHA256( signing_secret, signed_message ) )
```

> **Verify the signature against the exact raw request body — before any
> JSON parsing or reformatting.** Re-serialised JSON will not match the
> signed bytes.

Each endpoint has its own signing secret (`whsec_…`), shown exactly once
at creation and at rotation. Rotation is an immediate cutover.

---

## 12. Signature verification examples

All examples: read the **raw** body, compute HMAC-SHA256, compare in
constant time, and reject stale timestamps (5 minutes recommended).
Secrets below are placeholders.

**Node.js**

```js
const crypto = require("crypto");

function verifyVineTrackWebhook(rawBody, headers, secret) {
  const ts = headers["x-vinetrack-timestamp"];
  const given = headers["x-vinetrack-signature"] ?? "";
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  const expected = "v1=" + crypto
    .createHmac("sha256", secret)          // secret: "whsec_..."
    .update(`${ts}.${rawBody}`)
    .digest("hex");
  return given.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected));
}
```

**Python**

```python
import hashlib, hmac, time

def verify_vinetrack_webhook(raw_body: bytes, headers: dict, secret: str) -> bool:
    ts = headers.get("X-VineTrack-Timestamp", "")
    given = headers.get("X-VineTrack-Signature", "")
    if abs(time.time() - float(ts)) > 300:
        return False
    signed = f"{ts}.".encode() + raw_body
    expected = "v1=" + hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()
    return hmac.compare_digest(given, expected)  # secret: "whsec_..."
```

**PHP**

```php
function verifyVineTrackWebhook(string $rawBody, array $headers, string $secret): bool {
    $ts = $headers['X-VineTrack-Timestamp'] ?? '';
    $given = $headers['X-VineTrack-Signature'] ?? '';
    if (abs(time() - (int)$ts) > 300) return false;
    $expected = 'v1=' . hash_hmac('sha256', $ts . '.' . $rawBody, $secret);
    return hash_equals($expected, $given); // $secret: "whsec_..."
}
```

**Go**

```go
func VerifyVineTrackWebhook(rawBody []byte, ts, given, secret string) bool {
	t, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || math.Abs(float64(time.Now().Unix()-t)) > 300 {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret)) // secret: "whsec_..."
	mac.Write([]byte(ts + "."))
	mac.Write(rawBody)
	expected := "v1=" + hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(given))
}
```

---

## 13. Webhook event catalogue

Required scope must be actively granted for the event to be delivered.
All events are vineyard-scoped except `webhook.test`. Machine-readable
version: `docs/webhooks/vinetrack-events-v1.json`.

| Event | Resource | Scope | Emitted when | Repeats? |
|---|---|---|---|---|
| `trip.created` | trip | `trips:read` | Trip started (still in progress) | Once |
| `trip.updated` | trip | `trips:read` | Non-tracking edit to a trip (live tracking is silent) | Per edit |
| `trip.completed` | trip | `trips:read` | Trip gains its end time (already-finished trips emit only this) | Once |
| `spray_job.created` | spray_job | `sprays:read` | **Not emitted in v1** — reserved | — |
| `spray_job.updated` | spray_job | `sprays:read` | Spray record edited | Per edit |
| `spray_job.completed` | spray_job | `sprays:read` | Spray record created (a record IS a completed application) | Once |
| `fuel_log.created` | fuel_log | `fuel:read` | Fuel fill recorded | Once |
| `fuel_log.updated` | fuel_log | `fuel:read` | Fuel fill edited | Per edit |
| `fuel_purchase.created` | fuel_purchase | `fuel:read` | Bulk fuel purchase recorded (insert-only; no updated event) | Once |
| `work_task.created` | work_task | `work_tasks:read` | Work task created | Once |
| `work_task.updated` | work_task | `work_tasks:read` | Work task edited | Per edit |
| `work_task.completed` | work_task | `work_tasks:read` | Work task finalised | Once |
| `pruning_activity.created` | pruning_activity | `pruning:read` | Pruning activity created | Once |
| `pruning_activity.updated` | pruning_activity | `pruning:read` | Pruning activity edited (reversal emits nothing) | Per edit |
| `irrigation_record.created` | irrigation_record | `irrigation:read` | Irrigation session recorded | Once |
| `irrigation_record.updated` | irrigation_record | `irrigation:read` | Irrigation session corrected (reversal emits nothing) | Per edit |
| `irrigation_record.completed` | irrigation_record | `irrigation:read` | Planned/running session transitions to completed | Once |
| `growth_stage.recorded` | growth_stage | `growth_stages:read` | Growth-stage observation recorded (insert-only) | Once |
| `yield_record.created` | yield_record | `yield:read` | Yield record created | Once |
| `yield_record.updated` | yield_record | `yield:read` | Yield record edited | Per edit |
| `pin.created` | pin | `pins:read` | Pin created | Once |
| `pin.updated` | pin | `pins:read` | Pin edited | Per edit |
| `pin.resolved` | pin | `pins:read` | Pin transitions to completed/resolved | Per resolution (a reopened pin can resolve again) |
| `block.created` | block | `blocks:read` | Block created | Once |
| `block.updated` | block | `blocks:read` | Block edited | Per edit |
| `webhook.test` | webhook_endpoint | — (system) | *Send test webhook* pressed; `vineyard_id` is `null`; not subscribable | On demand |

`*.updated` events emit at most once per database transaction (a burst of
field edits saved together arrives as one event). There are no
`*.deleted` events in v1 — deletions and reversals are silent.

---

## 14. Delivery semantics

- **At-least-once.** A delivery may occasionally arrive more than once
  (e.g. a timeout hid a success). **Receivers must be idempotent.**
- **No ordering guarantee** — even for the same resource. Reconcile with
  `occurred_at` and reads from the API.
- **Deduplication**: dedupe on the event `id` (`evt_…`) to process each
  logical event once — it is stable across retries AND replays. Use
  `X-VineTrack-Delivery` (`dlv_…`) if you want to track each physical
  delivery separately.
- **Replay** creates a brand-new delivery (new `X-VineTrack-Delivery`
  id, fresh attempt counter) of the **same original event** (`id` and
  payload unchanged) — so a receiver may legitimately receive the same
  event more than once.

---

## 15. Retry policy

Backoff after failed attempt N (fixed schedule):

| Attempt | Wait before next |
|---|---|
| 1 (initial) | +1 minute |
| 2 | +5 minutes |
| 3 | +30 minutes |
| 4 | +2 hours |
| 5 | +12 hours |
| 6 | +24 hours |
| 7 | — final; delivery becomes `failed` |

Maximum **7 attempts**.

- **Retryable**: timeouts (10 s limit), network/TLS errors, HTTP 5xx,
  408, 429.
- **Permanent** (no retry): other 4xx, all 3xx (**redirects are never
  followed**), delivery-policy blocks.
- A `Retry-After` header on a retryable response is honoured: it can
  widen the scheduled gap (clamped to 1 hour) but never shortens it.
- **HTTPS is required**; ports other than 443/8443 are refused.
- After **10 consecutive failures** an endpoint is automatically
  disabled and queued deliveries are cancelled; fix your receiver,
  reactivate, then replay what you missed.

---

## 16. Webhook security guidance

- **HTTPS only** — plain HTTP endpoints are refused at registration.
- **Store the signing secret securely.** It is displayed once; treat it
  like a password.
- **Rotate secrets** periodically or on suspicion of exposure. Rotation
  is an immediate cutover — update the receiver first, rotate in a quiet
  window, then use *Send test webhook* to confirm.
- **Validate the timestamp** (reject > 5 minutes old) to prevent replay
  of captured requests.
- **Handle duplicates** — dedupe on event `id` (section 14).
- **Respond fast with 2xx** (within 10 seconds). Queue heavy processing
  on your side and acknowledge immediately.
- Never log the signing secret or echo request headers back.

---

## 17. Webhook payload examples

All IDs and values below are synthetic. Payloads follow the envelope in
section 11; `data` carries identifiers plus at most a small lifecycle
field — fetch full state from the read API.

`webhook.test`:

```json
{
  "id": "evt_00000000000000000000000000000001",
  "type": "webhook.test",
  "api_version": "v1",
  "occurred_at": "2026-08-10T01:00:00.000Z",
  "vineyard_id": null,
  "data": { "endpoint_id": "00000000-0000-4000-8000-0000000000e1", "message": "VineTrack webhook test" }
}
```

`trip.completed`:

```json
{
  "id": "evt_00000000000000000000000000000002",
  "type": "trip.completed",
  "api_version": "v1",
  "occurred_at": "2026-08-10T01:02:03.456Z",
  "vineyard_id": "00000000-0000-4000-8000-000000000001",
  "data": { "id": "00000000-0000-4000-8000-00000000000a", "end_time": "2026-08-10T01:00:00+00:00" }
}
```

`spray_job.completed`:

```json
{
  "id": "evt_00000000000000000000000000000003",
  "type": "spray_job.completed",
  "api_version": "v1",
  "occurred_at": "2026-08-10T02:15:41.120Z",
  "vineyard_id": "00000000-0000-4000-8000-000000000001",
  "data": { "id": "00000000-0000-4000-8000-00000000000e" }
}
```

`work_task.completed`:

```json
{
  "id": "evt_00000000000000000000000000000004",
  "type": "work_task.completed",
  "api_version": "v1",
  "occurred_at": "2026-08-10T03:20:00.000Z",
  "vineyard_id": "00000000-0000-4000-8000-000000000001",
  "data": { "id": "00000000-0000-4000-8000-00000000000f", "status": "completed" }
}
```

`pin.resolved`:

```json
{
  "id": "evt_00000000000000000000000000000005",
  "type": "pin.resolved",
  "api_version": "v1",
  "occurred_at": "2026-08-10T04:05:12.000Z",
  "vineyard_id": "00000000-0000-4000-8000-000000000001",
  "data": { "id": "00000000-0000-4000-8000-00000000000d", "status": "completed" }
}
```

`irrigation_record.completed`:

```json
{
  "id": "evt_00000000000000000000000000000006",
  "type": "irrigation_record.completed",
  "api_version": "v1",
  "occurred_at": "2026-08-10T05:00:00.000Z",
  "vineyard_id": "00000000-0000-4000-8000-000000000001",
  "data": { "id": "00000000-0000-4000-8000-000000000010", "status": "completed" }
}
```

Follow up any event with the read API, e.g. `GET /v1/trips/{data.id}`.

---

## 18. Versioning policy

- All REST routes live under **`/v1/`**; responses carry
  `X-VineTrack-API-Version: v1`.
- All webhook envelopes carry **`api_version: "v1"`** and deliveries the
  matching `X-VineTrack-API-Version: v1` header.

**Backwards compatible** (may happen within v1 — build tolerant parsers):

- adding new optional response fields;
- adding new event types;
- adding new endpoints or new optional query parameters;
- adding new error codes for new failure modes.

**Breaking** (requires a new version, never silently within v1):

- removing or renaming existing fields, routes or events;
- changing a field's meaning or type;
- changing the signature contract or envelope structure;
- tightening what an existing scope grants.

No deprecation timeline is promised at this time; any future deprecation
will be announced in `docs/vinetrack-api-changelog.md` before it happens.

---

## 23. Developer onboarding checklist

- [ ] Integration created in VineTrack
- [ ] Vineyard(s) granted to the integration
- [ ] Scopes granted (only what you need; sensitive scopes justified)
- [ ] API key created and stored in a secret manager
- [ ] `GET /v1/me` returns your integration profile
- [ ] `GET /v1/vineyards` returns the granted vineyards
- [ ] First operational resource fetched (e.g. `/v1/trips`)
- [ ] Webhook endpoint created (HTTPS, port 443/8443)
- [ ] Signing secret stored securely
- [ ] Test webhook sent and signature verified against the raw body
- [ ] Receiver deduplicates on event `id` and responds 2xx fast
- [ ] Production monitoring configured (rate-limit headers, request IDs
      logged, webhook failure alerting)

---

## Support

Include the `X-VineTrack-Request-ID` (API) or `X-VineTrack-Delivery`
(webhooks) identifier in any support enquiry.
