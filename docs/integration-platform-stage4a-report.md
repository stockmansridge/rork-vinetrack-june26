# VineTrack Integration Platform — Stage 4A Backend Patch Report

Safe API request-log read RPC so the Lovable portal's "API Logs" tab can
go live. Backend-only: one migration + one rollback-only test file. No
Lovable, iOS, or Android changes; no gateway behaviour change.

Supabase project: `tbafuqwruefgkbyxrxyb`.

---

## 1. SQL migration file

`sql/177_integration_api_request_logs_rpc.sql` — strictly additive,
idempotent, production-safe. Does not touch SQL 172–176 objects. Adds:

1. `idx_integration_api_requests_client_keyset` on
   `(integration_client_id, created_at desc, id desc)` — supports the
   keyset pagination exactly (the existing
   `(integration_client_id, created_at desc)` index remains).
2. `public.integration_list_api_requests(...)` — SECURITY DEFINER
   management RPC, `search_path = public`, revoked from `public`/`anon`,
   granted to `authenticated` (authority enforced inside, matching every
   Stage 2 management RPC).

Apply via the Supabase SQL editor, then run
`sql/tests/177_integration_api_request_logs_tests.sql`.

## 2. Exact RPC signature

```sql
public.integration_list_api_requests(
  p_client_id          uuid,                        -- required
  p_from               timestamptz default null,
  p_to                 timestamptz default null,
  p_status_code        integer     default null,
  p_vineyard_id        uuid        default null,
  p_api_key_id         uuid        default null,
  p_error_only         boolean     default false,
  p_limit              integer     default 100,     -- clamped 1..1000
  p_before_created_at  timestamptz default null,    -- keyset cursor (pair)
  p_before_id          uuid        default null     -- keyset cursor (pair)
) returns jsonb
```

## 3. Returned JSON shape

```json
{
  "data": [
    {
      "id": "…",                              // log row uuid
      "request_id": "req_<32 hex>",           // matches X-VineTrack-Request-ID
      "created_at": "2026-08-10T02:41:30Z",
      "integration_client_id": "…",
      "api_key_id": "…",
      "api_key_prefix": "vt_live_ab12cd34",   // safe display prefix
      "api_key_name": "Production key",       // owner-chosen label (nullable)
      "api_key_revoked_at": null,             // set for revoked keys (history stays readable)
      "vineyard_id": "…",                     // nullable (e.g. /v1/me)
      "vineyard_name": "Stockmans Ridge",     // resolved server-side (nullable)
      "method": "GET",
      "path": "/v1/spray-jobs/{spray_job_id}",// canonical template from SQL 173+
      "status_code": 403,
      "duration_ms": 20,
      "error_code": "vineyard_access_denied"  // nullable
    }
  ],
  "pagination": {
    "has_more": true,
    "next_before_created_at": "2026-08-10T02:41:30Z",
    "next_before_id": "…"
  }
}
```

NOT returned (and mostly not even stored): key hash, API secret,
Authorization header, request body, response body, service-role
credentials, raw provider payloads, stack traces. The RPC selects only
`key_prefix`, `name`, `revoked_at` from `integration_api_keys` — the
`key_hash` column is never touched. Paths are the canonical low-cardinality
templates logged by the gateway (never raw URLs or query strings — the
gateway never logs them).

## 4. Authority rules

Reuses the EXISTING Stage 2 authority helper
`public._integration_can_view(actor, client)` — the same authority already
used by `integration_audit_history`. No new role model:

| Caller | Access |
| --- | --- |
| Account owner of the integration | ✅ full log read |
| Platform admin (`is_system_admin()`) | ✅ (existing system-admin rule) |
| Manager — Owner/Manager member of a vineyard with an ACTIVE grant to the integration | ✅ (exactly the Stage 2 Manager view rule) |
| Supervisor / Operator | ❌ `integration_not_found` |
| Anyone else / other account | ❌ `integration_not_found` |
| Unauthenticated | ❌ `not_authenticated` |

**Cross-account isolation / non-disclosure**: an inaccessible client id
raises the SAME `integration_not_found` error as a nonexistent uuid — the
identical convention used by `_integration_require_manage` and every
Stage 2 RPC, so integration ids cannot be probed (test T8 asserts error
equivalence).

## 5. Pagination behaviour

- Deterministic newest-first keyset: `created_at DESC, id DESC` (the
  external API's pagination philosophy).
- Cursor = the `(created_at, id)` pair of the last row of the previous
  page, passed back as `p_before_created_at` + `p_before_id`. Supplying
  only one half raises `invalid_cursor`.
- Default limit 100; hard maximum 1000; values below 1 clamp to 1,
  values above 1000 clamp to 1000 (never an error).
- `pagination.has_more` tells Lovable whether another page exists;
  `next_before_*` are returned whenever a full page was served. Initial
  load = call with no cursor; next page = pass the cursor back; filters
  compose freely with the cursor. The full history is never loaded at
  once.

## 6. Filters

All filters are fixed, allowlisted parameters (no arbitrary filtering):

| Parameter | Behaviour |
| --- | --- |
| `p_from` / `p_to` | inclusive `created_at` range; `from > to` → `invalid_range` |
| `p_status_code` | exact status match; outside 100–599 → `invalid_status` |
| `p_vineyard_id` | rows logged against that vineyard |
| `p_api_key_id` | rows for one key (incl. revoked keys) |
| `p_error_only` | `true` → only rows with a non-null `error_code` |

## 7. Test file and results

`sql/tests/177_integration_api_request_logs_tests.sql` — rollback-only
(single transaction, `rollback` at the end; zero production rows touched),
mirroring the SQL 172 test conventions (fixture users in `auth.users`,
`request.jwt.claims` + role switching). Twelve tests:

- T1 RPC signature + keyset index exist
- T2 direct table access remains blocked for `authenticated`
- T3 Owner reads own logs — 7 fixture rows, newest-first, all safe fields
  present, hash fields absent, AND the actual SHA-256 of both fixture key
  secrets is asserted absent from the entire response text
- T4 key prefix/name resolved; revoked key still resolvable for
  historical rows (with `api_key_revoked_at` set)
- T5 vineyard name resolved
- T6 Manager (member of actively granted vineyard) can read
- T7 Supervisor and Operator denied
- T8 Owner B gets `integration_not_found` for A's integration AND for a
  random uuid (non-disclosing equivalence)
- T9 vineyard / status / error-only / api-key / from / from+to filters
  all return exact expected row counts
- T10 `invalid_status`, `invalid_range`, `invalid_cursor` (lone half)
- T11 pagination: limit 2 iterates 4 pages, 7 unique rows, no
  duplicates/gaps, `has_more` + cursor contract honoured; limit floor
  (−5 → 1 row) and oversized limit (5000 → clamped, no error)
- T12 existing write path unchanged: `integration_log_api_request`
  appends an 8th row through the canonical writer and it appears first
  in the RPC output

Sandbox validation: both files parse-checked (dollar-quoting balanced);
no DB connection exists in this environment, so run the test file in the
SQL editor after applying the migration — expected final output:
`NOTICE: SQL 177 request-log RPC tests: ALL PASSED`.

## 8. Confirmation — direct table access remains blocked

SQL 177 grants **no** table privilege. `integration_api_requests` keeps
its SQL 172 lockdown (RLS enabled, no policies, all privileges revoked
from `anon`/`authenticated`); the only read path is the new SECURITY
DEFINER RPC and the only write path remains the service-role-only
`integration_log_api_request`. Test T2 re-asserts the direct SELECT is
`insufficient_privilege`.

## 9. Confirmation — no secrets/hashes/bodies exposed

The log table stores no bodies, headers, or credentials by design
(SQL 172), and the RPC's select list is a fixed set of safe columns plus
`key_prefix`/`name`/`revoked_at` and `vineyards.name`. `key_hash` is
never selected; T3 asserts the computed hashes and plaintext secrets of
both fixture keys appear nowhere in the response.

## 10. Confirmation — no Lovable/iOS/Android changes

Zero changes to Lovable, iOS, or Android code. Zero changes to
`vinetrack-api` gateway behaviour: authentication, request-logging
semantics, key validation, vineyard isolation, and rate limiting are all
untouched (T12 proves the write path still behaves identically). This
patch is purely the read-management RPC + its index.

---

## Go-live checklist

1. Apply `sql/177_integration_api_request_logs_rpc.sql` in the SQL editor.
2. Run `sql/tests/177_integration_api_request_logs_tests.sql` — expect
   `ALL PASSED` (it rolls back automatically).
3. Lovable can then call
   `supabase.rpc('integration_list_api_requests', { p_client_id, ... })`
   with the signed-in user's session — no gateway redeploy needed.

Stopping here for review.
