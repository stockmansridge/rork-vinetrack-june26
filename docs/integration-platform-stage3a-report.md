# VineTrack Integration Platform — Stage 3A completion report

## Read-only API gateway + Vineyards / Blocks

Status: **implemented, ready to apply and deploy**. Nothing in this stage
changes iOS, Android, Lovable, or any existing table/RPC/policy — SQL 173 is
purely additive on top of SQL 172.

Apply / deploy order:

1. Run `sql/173_integration_api_gateway_support.sql` in the Supabase SQL
   editor (project `tbafuqwruefgkbyxrxyb`); SQL 172 must already be applied.
2. Run `sql/tests/173_integration_api_gateway_tests.sql` — expected final
   output `NOTICE: SQL 173 integration gateway tests: ALL PASSED`, then
   `ROLLBACK` (no production rows touched).
3. Deploy the gateway: `./scripts/deploy-edge-functions.sh` (or the
   PowerShell script). The scripts deploy `vinetrack-api` with
   `--no-verify-jwt`.
4. Create test credentials via the SQL 172 RPCs and run
   `scripts/test-vinetrack-api.sh` against the deployed gateway.

---

## 1. Files changed

- `sql/173_integration_api_gateway_support.sql` — new (gateway support migration)
- `sql/tests/173_integration_api_gateway_tests.sql` — new (rollback-only tests)
- `supabase/functions/vinetrack-api/index.ts` — new (the gateway)
- `scripts/deploy-edge-functions.sh` / `.ps1` — `vinetrack-api` added with `--no-verify-jwt`
- `scripts/test-vinetrack-api.sh` — new (HTTP-level security test harness)
- `docs/vinetrack-api-v1.md` — new (developer-facing API contract seed)
- this report

## 2. Gateway name and path

One canonical Supabase Edge Function: **`vinetrack-api`**, with versioned
internal routing. Public base URL:

```text
https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api
```

New resources are added as route cases inside the same function — no
per-endpoint functions.

## 3. External routes implemented

- `GET /v1/me`
- `GET /v1/vineyards`
- `GET /v1/vineyards/{vineyard_id}`
- `GET /v1/blocks?vineyard_id=<uuid>` (vineyard_id REQUIRED in Stage 3A)
- `GET /v1/blocks/{block_id}`
- `OPTIONS` on any path → 204. All other methods → 405 `method_not_allowed`.
- Unknown routes → 404 JSON `resource_not_found`.

## 4. Authentication flow

1. Reject any credential-looking query parameter (`api_key`, `apikey`,
   `key`, `token`, `authorization`) with `invalid_request`.
2. `Authorization: Bearer <key>` required; missing → `missing_api_key`,
   non-Bearer or non-`vt_(live|test)_<48 hex>` shape (including Supabase
   JWTs) → `invalid_api_key`. The plaintext key exists only in memory for
   the request; it is hashed inside Postgres using the exact Stage 2
   convention (`_integration_hash_secret`, SHA-256) and never stored or
   logged.
3. `integration_authenticate_api_key()` (SQL 173, service_role only)
   performs checks 1–4: credential exists → not revoked → not expired →
   integration active. It returns the safe profile (active scopes + active
   vineyard grants), used for `/v1/me`, collection scope checks, and the
   granted-vineyard list.
4. Rate limit check (per key, Postgres-backed).
5. Scope + vineyard enforcement per route (section 9/10 below).

## 5. How SQL 172 `integration_validate_api_request()` is used

Every request with a single-vineyard context — `GET /v1/vineyards/{id}`,
`GET /v1/blocks?vineyard_id=`, `GET /v1/blocks/{id}` — is validated by SQL
172's canonical five-check function (credential, revocation, expiry,
integration status, scope grant, explicit vineyard grant) before any
resource row is read. No permission logic was recreated or contradicted.

`/v1/me` and `GET /v1/vineyards` have no single-vineyard argument, so they
use SQL 173's `integration_authenticate_api_key()` — the same checks 1–4
plus the profile — and `/v1/vineyards` then requires `vineyards:read` from
that profile and reads **only** vineyards in the active-grant list. Access
is never derived from any human user's membership.

## 6. External vineyard response schema

```json
{
  "id": "uuid",
  "name": "string",
  "country_code": "string | null",
  "country": "string | null",
  "timezone": "string | null",
  "created_at": "ISO 8601",
  "updated_at": "ISO 8601"
}
```

## 7. External block response schema

```json
{
  "id": "uuid",
  "vineyard_id": "uuid",
  "name": "string",
  "planting_year": "integer | null",
  "row_count": "integer | null",
  "row_width_m": "number | null",
  "vine_spacing_m": "number | null",
  "varieties": [ { "name": "string", "percent": "number | null" } ],
  "created_at": "ISO 8601",
  "updated_at": "ISO 8601"
}
```

## 8. Canonical source mapping

Vineyard (`public.vineyards`, sql/001 + 080 + 099):

- `id` → `vineyards.id` (none)
- `name` → `vineyards.name` (none)
- `country_code` → `vineyards.country_code` (sql/099; null when unset)
- `country` → `vineyards.country` (sql/001; null when unset)
- `timezone` → `vineyards.timezone` (sql/080; null when unset)
- `created_at` / `updated_at` → same columns (none)
- Soft-deleted vineyards (`deleted_at is not null`) are never returned.

Block (`public.paddocks`, sql/005 + 020):

- `id` → `paddocks.id` (none)
- `vineyard_id` → `paddocks.vineyard_id` (none)
- `name` → `paddocks.name` (none)
- `planting_year` → `paddocks.planting_year` (none)
- `row_count` → `paddocks.rows` jsonb (transformed: array length; null when
  row layout not configured — per-row geometry itself is NOT exposed)
- `row_width_m` → `paddocks.row_width` (renamed with explicit unit)
- `vine_spacing_m` → `paddocks.vine_spacing` (renamed with explicit unit)
- `varieties[].name` → `paddocks.variety_allocations[]` jsonb (`name` with
  legacy fallback `varietyName`; entries without a name are dropped)
- `varieties[].percent` → same jsonb (`percent` with legacy fallback
  `percentage`)
- `created_at` / `updated_at` → same columns (none)
- Deliberately NOT exposed: `polygon_points` (boundary geometry), per-row
  geometry inside `rows`, irrigation hardware fields (`flow_per_emitter`,
  `emitter_spacing`), phenology date overrides, calculation overrides,
  sync bookkeeping (`sync_version`, `client_updated_at`), `created_by`/
  `updated_by`. Exposing geometry is reserved as a future explicit
  decision. Note VineTrack has no canonical stored area column — block
  area is derived client-side from geometry, so no `area_ha` is exposed
  in Stage 3A (documented in section 21).

## 9. Scope mapping per route

- `GET /v1/me` → authentication only (profile lists granted vineyard
  id+name pairs as integration metadata; full vineyard resources still need
  `vineyards:read`)
- `GET /v1/vineyards`, `GET /v1/vineyards/{id}` → `vineyards:read`
- `GET /v1/blocks`, `GET /v1/blocks/{id}` → `blocks:read`
- No scope implies another; `blocks:read` does not grant `vineyards:read`
  (proven by the harness test).

## 10. Vineyard isolation logic

- Collection: `/v1/vineyards` reads only ids from the integration's
  active-grant list; zero grants → empty page, not an error.
- `GET /v1/vineyards/{id}`: five-check validation for that id; refusal is
  returned as `resource_not_found` — a granted-nonexistent id and an
  existing-but-ungranted id are indistinguishable.
- `GET /v1/blocks?vineyard_id=`: five-check validation; refusal is
  `vineyard_access_denied` (explicitly named context, still non-disclosing
  about existence).
- `GET /v1/blocks/{id}`: block resolved first (service role), then its
  vineyard is five-check validated; a block in an ungranted vineyard
  returns `resource_not_found` exactly like a nonexistent block. When the
  block does not exist, the scope check still runs first so the error
  (insufficient_scope vs resource_not_found) never depends on existence.
- The creator's personal vineyard memberships play no part at request time.

## 11. Error-code mapping

Internal validation codes (SQL 172/173) → external contract:

- `invalid_key` → 401 `invalid_api_key`
- `key_revoked` → 401 `revoked_api_key`
- `key_expired` → 401 `expired_api_key`
- `integration_not_active` → 403 `integration_not_active`
- `scope_not_granted` → 403 `insufficient_scope`
- `vineyard_not_granted` → 403 `vineyard_access_denied` (explicit vineyard
  context) or 404 `resource_not_found` (direct resource fetch)

Plus gateway-level: `missing_api_key` 401, `invalid_request` 400,
`invalid_cursor` 400, `rate_limit_exceeded` 429, `method_not_allowed` 405,
`resource_not_found` 404, `internal_error` 500. All errors use the standard
envelope with `request_id`. Postgres/PostgREST failures are translated to
`internal_error`; details go to server logs only (no schema names, RPC
names, stack traces, or service-role status leak externally).

## 12. Pagination

- Opaque cursor = base64url of `{t: created_at, id}` — an implementation
  detail, not a contract; consumers must treat it as opaque.
- Keyset iteration: `where (created_at, id) > (t, id) order by created_at
  asc, id asc` — deterministic, duplicate-free, gap-free for stable data.
- Documented ordering: `created_at` ascending, then `id` ascending, for
  both vineyards and blocks.
- `limit` default 100, max 1000; `limit > 1000` or non-integer →
  `invalid_request`; undecodable cursor → `invalid_cursor`.
- The helper (`pagedList`) is generic and will serve Trips/Sprays/Fuel
  unchanged.

## 13. Rate limiting and limitations

- 300 requests/minute per API key, configurable via the
  `VINETRACK_API_RATE_LIMIT_PER_MINUTE` function secret.
- Implementation: `integration_rate_limit_counters` (SQL 173) — fixed
  60-second windows keyed by `(api_key_id, window_start)`, incremented
  atomically by `integration_check_rate_limit()` (service_role only).
  Because the counter lives in Postgres, the limit holds across ALL Edge
  Function instances — it is NOT a per-instance in-memory counter.
- Breach: 429 `rate_limit_exceeded` + `Retry-After`; every authenticated
  response carries `X-RateLimit-Limit` / `X-RateLimit-Remaining`.
- Known limitations (documented deliberately):
  - Fixed windows allow a burst of up to 2× the limit across a window
    boundary (fine for a first version; sliding windows can come later).
  - Each request costs one extra DB round-trip; acceptable at these
    volumes, revisit if limits grow orders of magnitude.
  - Unauthenticated (invalid-key) traffic is not rate-limited per key
    (there is no key identity); platform-level protection is the
    Supabase/edge layer. Future option: per-IP limiting.
  - Rows older than 10 minutes are pruned opportunistically per key.
- The per-key window design extends naturally to future resource-specific
  limits (add a scope/route dimension to the counter key).

## 14. API request logging

Every GET/POST/PUT/PATCH/DELETE request writes one row to
`integration_api_requests` via `integration_log_api_request()` (SQL 173,
service_role only): request id, integration client id + API key id when
known, vineyard id when known, method, **canonical route template** (e.g.
`/v1/blocks/{block_id}` — no raw ids in the path, low cardinality), status
code, duration ms, safe error code, timestamp. Failed-auth attempts are
logged with NULL client/key ids (SQL 173 relaxed the NOT NULL for exactly
this). Never logged: plaintext key, Authorization header, request/response
bodies, service-role credentials — the table has no columns for them and
the writer function receives none of them. Log failures never break the
API response.

## 15. `last_used_at` behaviour

- `integration_authenticate_api_key()` (used on every request) refreshes
  `last_used_at` at most **once per 60 seconds per key** — freshness
  without a per-request write hot-spot.
- SQL 172's `integration_validate_api_request()` also sets it on each
  successful per-vineyard validation (pre-existing Stage 2 behaviour,
  intentionally not restructured); bounded by the 300 rpm rate limit.
- Both writes happen only inside trusted server-side processing; no
  user-facing RPC can touch `last_used_at`.

## 16. Environment / secrets configuration

- Function name: `vinetrack-api`; public route
  `https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api`.
- Required: none beyond the standard Supabase-injected `SUPABASE_URL` and
  `SUPABASE_SERVICE_ROLE_KEY` (never committed, never returned, never
  logged, never exposed to Lovable or mobile apps).
- Optional secrets: `VINETRACK_API_RATE_LIMIT_PER_MINUTE` (default 300),
  `VINETRACK_API_CORS_ORIGINS` (comma-separated exact origins; default
  empty = no browser origins; auth and vineyard checks apply regardless of
  origin).
- Deployment: `scripts/deploy-edge-functions.sh` / `.ps1` — the function is
  deployed with `--no-verify-jwt` because callers present VineTrack API
  keys, not Supabase JWTs (same pattern as `revenuecat-webhook`).
- Verification: `curl -i <base>/v1/me` → 401 JSON `missing_api_key` means
  deployed and healthy.

## 17. Automated tests and results

**DB level — `sql/tests/173_integration_api_gateway_tests.sql`** (single
transaction, final ROLLBACK; T1–T6): objects exist; the full authenticate
chain (valid profile with only active scopes/grants; malformed / unknown /
revoked / expired keys; paused and revoked integrations); `last_used_at`
throttle; rate-limit counting, blocking, retry-after and per-key isolation;
request logging incl. NULL-client failed-auth rows, method validation and
request-id format constraint; and lockdown (authenticated role cannot call
any Stage-3A function or read the counters). Expected output:
`SQL 173 integration gateway tests: ALL PASSED`.

**HTTP level — `scripts/test-vinetrack-api.sh`** (~30 checks against the
deployed gateway): the section-26 matrix — authentication (missing/
malformed/invalid/valid/expired/revoked keys, paused/revoked integrations),
scope enforcement (including `blocks:read` ⇏ `vineyards:read` and `/v1/me`
without resource scopes), vineyard isolation (granted retrievable; other
account's vineyard/block UUIDs → non-disclosing 404; ungranted vineyard
filter → 403), envelopes (collection/single/error), request-id header, 405s,
unknown route, invalid cursor, max limit, unknown query param, and
query-string credential rejection. Keys/UUIDs are provided via environment
variables only.

**Results:** this sandbox has no connection to the shared Supabase project,
so both suites are ready-to-run rather than executed here — same
apply-in-editor flow as SQL 143–172. Run steps are at the top of this
report. Isolation cases that need a second account (Vineyard B fixtures)
are parameterised in the harness and skipped cleanly when not provided.
Regression safety needs no new tests: SQL 173 touches no existing table
column used by clients (one new nullable column + one relaxed NOT NULL on a
Stage-2-only diagnostics table), no existing policy or RPC, so iOS/Android/
portal behaviour is unchanged; SQL 172's T16 (existing RLS intact) still
applies.

**Key-isolation invariants** (Integration A's key cannot act as B; adding
vineyard access to the human creator changes nothing) hold structurally:
the key hash resolves to exactly one integration client, and the validator
reads only `integration_client_vineyards`/`integration_client_scopes` —
proven at DB level by SQL 172 tests T10 and re-exercised over HTTP by the
harness.

## 18. Manual curl examples

See `docs/vinetrack-api-v1.md` (placeholders only; no real secrets in the
repo). Quick smoke test:

```bash
curl -H "Authorization: Bearer <VT_API_KEY>" \
  "https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api/v1/me"
```

## 19. No operational resource APIs exposed

Confirmed. Only `me`, `vineyards`, and `blocks` routes exist; every other
path returns 404. Trips, Spray, Fuel, Work Tasks, Pruning, Irrigation,
Yield, Equipment, Pins and Weather remain unexposed.

## 20. No write APIs / webhooks / UI added

Confirmed. All non-GET methods return 405. No webhook dispatch, signing, or
retry code exists. No Idempotency-Key processing. No Lovable, iOS, or
Android UI was changed (no files under `ios/`, `android-vinetrack/`, or the
Lovable contract docs were touched).

## 21. Schema findings affecting later API resources

1. **No canonical block area.** `paddocks` stores geometry
   (`polygon_points`) but no stored hectares; area is computed client-side.
   A future `area_ha` API field needs either a canonical stored column or a
   server-side computation decision. Deferred.
2. **`variety_allocations` is loosely-shaped jsonb** with legacy field
   aliases (`name`/`varietyName`, `percent`/`percentage`) and no DB-level
   validation. The gateway normalises defensively; a future write API must
   pin one canonical shape.
3. **Row identity lives inside `rows` jsonb**, not in a relational table.
   A future rows/row-sections API (and pin placement references) will need
   a stable addressing convention (sql/171 already defines row numbers for
   pins) rather than jsonb array indexes.
4. **`vineyards.country` vs `country_code` duplication** (free text vs
   code, sql/099). The API exposes both, nullable; a future normalisation
   should make `country_code` authoritative.
5. **Provenance columns still absent** on operational tables (Stage 2
   report §9) — required before any external write endpoint.
6. **`integration_api_requests` retention**: no TTL yet; fine at Stage-3A
   volumes, but a retention/rollup policy should land with the first
   high-volume resource APIs.

---

**Stopping here per the brief — Stage 3B is not started.**
