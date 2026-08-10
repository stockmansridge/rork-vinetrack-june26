# VineTrack API — v1 (Stage 3A)

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

The route version is authoritative: all Stage 3A routes live under `/v1/`.
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
| `method_not_allowed` | 405 | Stage 3A is read-only; only GET (and OPTIONS) are supported. |
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

Scopes never imply each other: `blocks:read` does not include
`vineyards:read`. Sensitive scopes (`labour:read`, `costs:read`,
`team:read`) are never implied by any resource scope.

## Pagination

Collection endpoints use opaque cursor pagination:

```text
GET /v1/blocks?vineyard_id=<uuid>&limit=100
GET /v1/blocks?vineyard_id=<uuid>&limit=100&cursor=<next_cursor>
```

- `limit` — default 100, maximum 1000 (`invalid_request` above that).
- `cursor` — the `pagination.next_cursor` from the previous page. Opaque;
  do not construct or parse it. `next_cursor: null` means the last page.
- Ordering is deterministic (`created_at`, then `id`, ascending); iterating
  a stable collection yields no duplicates and no gaps.

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

Never embed real production keys in source code, docs, or client-side apps.

## Creating test credentials

Use the existing Stage 2 management RPCs (as a vineyard Owner) — there is no
second key mechanism:

```sql
select integration_create_client('My Test Integration', 'custom_api', null);
select integration_grant_vineyard('<integration_id>', '<vineyard_id>');
select integration_grant_scope('<integration_id>', 'vineyards:read');
select integration_grant_scope('<integration_id>', 'blocks:read');
select integration_create_api_key('<integration_id>', 'dev key', 'test', null);
-- The 'secret' field of the last result is shown ONCE. Store it now.
```

## Deployment (engineering)

- Function: `supabase/functions/vinetrack-api` on project
  `tbafuqwruefgkbyxrxyb`.
- Deploy via `scripts/deploy-edge-functions.ps1` / `.sh` (the scripts pass
  `--no-verify-jwt` for this function — callers present VineTrack keys, not
  Supabase JWTs).
- Requires SQL 172 + SQL 173 applied first.
- Secrets: only the standard Supabase-injected `SUPABASE_URL` and
  `SUPABASE_SERVICE_ROLE_KEY`. Optional: `VINETRACK_API_RATE_LIMIT_PER_MINUTE`
  (default 300), `VINETRACK_API_CORS_ORIGINS` (comma-separated exact origins;
  default: no browser origins allowed — this is a server-to-server API).
- HTTP test harness: `scripts/test-vinetrack-api.sh`.
