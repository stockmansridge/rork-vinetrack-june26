# Integration Platform Administration — Stage 7A

Platform-admin observability and governance for the VineTrack external
integration platform, across **all** customers. This surface is for VineTrack
staff (support / operations), not for customers — customer-facing integration
management remains the `integration_*` RPC family (SQL 172/177/178).

- Migration: `sql/179_integration_platform_admin.sql`
- Tests: `sql/tests/179_integration_platform_admin_tests.sql` (rollback-only)
- Related contracts: `docs/vinetrack-api-v1.md`, `docs/vinetrack-webhooks.md`,
  `docs/vinetrack-developer-platform.md`

---

## 1. Authority model

There is **one** platform-admin authority: `public.is_system_admin()`
(table `public.system_admins`, SQL 062) — the same check used by the Access &
Entitlements admin centre (SQL 140/146). Stage 7A does **not** introduce a
second admin permission system.

Every `admin_*` RPC in SQL 179:

- is `security definer` with `set search_path = public`;
- checks `is_system_admin()` first and raises
  `System Admin only` (SQLSTATE `42501`) otherwise;
- has execute granted to `authenticated` only — `anon` and `service_role`
  have **no** execute privilege. The admin surface is reached exclusively with
  a real staff user JWT; the service role must use the customer/dispatcher RPC
  surface instead.
- Internal helpers (`_admin_integration_health`, `_admin_mask_url`) have no
  client execute at all.

Vineyard Owners, Managers, Supervisors, Operators and anonymous callers are
all denied (verified by tests T2–T4).

## 2. Safe-field contract

No admin RPC ever returns:

- plaintext API keys or `key_hash`
- webhook `signing_secret_hash`, `signing_secret_prefix`, or `secret_ref`
  (Vault id)
- Authorization headers, bearer tokens, request bodies or response bodies
  (the request log never stored them — SQL 172 §H design)
- receiver response bodies for webhook deliveries

Webhook URLs are shown with the **query string redacted**
(`https://host/path?[redacted]`) because receiver URLs may embed credentials.
Key identity is shown as `key_prefix` + `name` only.

## 3. RPC contract

All list RPCs return `{ "data": [...], "pagination": { "has_more",
"next_before_created_at", "next_before_id" } }` with keyset pagination
(`created_at desc, id desc`; pass both cursor fields together or receive
`invalid_cursor`). Offset pagination is not used on log-scale tables.

### Directory & inspection

| RPC | Purpose |
| --- | --- |
| `admin_list_integrations(p_status, p_environment, p_owner_user_id, p_owner_query, p_vineyard_id, p_activity, p_health, p_errors_only, p_rate_limited_only, p_created_from, p_created_to, p_last_used_from, p_last_used_to, p_limit, p_before_created_at, p_before_id)` | Global integration directory: identity, owner (email/full name), counts (vineyard grants, scopes, keys, active keys, endpoints, active endpoints), last API request / last webhook delivery, 24h activity, health classification. Limit 1–200 (default 50). |
| `admin_get_integration(p_client_id)` | Configuration inspection: integration record, owner, health, vineyard grants (with revoked history), scopes (with sensitivity flag), API keys (safe metadata + derived status `active`/`expired`/`revoked`), webhook endpoints (masked URL, failure counters, subscription count). |
| `admin_get_integration_diagnostics(p_client_id)` | One-call support snapshot: everything from `admin_get_integration` **plus** last API request, 24h/7d request/error/rate-limit counts, webhook queue state (pending, retrying, next retry, failed 7d, failed attempts 24h) and the last 20 audit entries. |

Filters on `admin_list_integrations`:

- `p_status`: `active` / `paused` / `revoked`
- `p_environment`: `live` / `test` — integration has a non-revoked key in
  that environment
- `p_owner_query`: case-insensitive match on integration name, owner email,
  owner full name; `p_owner_user_id` for exact owner
- `p_vineyard_id`: has an active grant for that vineyard
- `p_activity`: `active_24h` / `active_7d` / `no_activity_30d`
  (API request **or** webhook delivery)
- `p_health`: health classification (below)
- `p_errors_only`: API errors or failed webhook attempts in the last 24h
- `p_rate_limited_only`: any 429 in the last 24h
- created / last-used date ranges

### API observability

| RPC | Purpose |
| --- | --- |
| `admin_integration_api_metrics(p_window, p_client_id, p_group_by)` | Aggregates over `integration_api_requests`. Windows: `24h` / `7d` / `30d`. Totals: requests, 2xx, 4xx, 5xx, rate-limited (429), unauthenticated (failed-auth rows), avg duration, p95 duration, unique integrations, unique API keys. `p_group_by`: `none`, `integration`, `path` (canonical route template), `status_class`, `vineyard`, `api_key` (labelled by prefix/name), `day` (daily buckets for charting). Breakdown capped at 100 groups. |
| `admin_list_integration_api_requests(...)` | Cross-client request diagnostics, **including unauthenticated failures** (`integration_client_id is null`) that the customer-facing SQL 177 RPC cannot see. Fields: request id, timestamp, integration, key prefix/name, vineyard, method, canonical path, status code, duration, safe error code. Filters: client, key, vineyard, method, exact path, status code, status class, errors-only, rate-limited-only, unauthenticated-only, time range. Limit 1–1000. |

### Rate-limit observability

The fixed-window limiter (SQL 173, 300 req/min/key — **unchanged** in this
stage) keeps only ephemeral counters (self-pruned after 10 minutes). The
**durable** rate-limit record is the request log: every rejected request is
logged with `status_code = 429`, `error_code = 'rate_limit_exceeded'`,
integration, key and timestamp. Diagnostics therefore come from:

- `admin_integration_api_metrics(...)` → `rate_limited` totals/breakdowns
- `admin_list_integration_api_requests(p_rate_limited_only => true)` →
  per-request rows (integration, key prefix, route, timestamp)
- health signal `api_rate_limited_24h`

No additional telemetry table was needed; per-window counter snapshots are
not persisted by design (documented limitation: the "requests used in the
current window" figure is derivable from log rows per minute, not stored).

### Webhook observability

| RPC | Purpose |
| --- | --- |
| `admin_webhook_metrics(p_window, p_client_id)` | Delivery counts by status (`pending`, `delivering`, `delivered`, `failed`, `cancelled`), retry-scheduled count, test count, delivered/failed rates (over terminal deliveries), average attempts; attempt totals/failures/avg duration; endpoint state (active/paused/disabled, auto-disabled, endpoints with ≥3 consecutive failures); oldest pending delivery; up to 50 integrations with current webhook problems. |
| `admin_list_webhook_endpoints(p_client_id, p_status, p_failing_only, p_include_deleted, ...)` | Global endpoint list: integration + owner email, name, **masked URL**, status, consecutive failures, last success/failure, paused/disabled timestamps, `disabled_reason`, subscription counts. `p_failing_only` = consecutive failures > 0 or disabled. |
| `admin_list_webhook_deliveries(p_client_id, p_endpoint_id, p_event_type, p_status, p_vineyard_id, p_is_test, p_from, p_to, ...)` | Cross-client delivery list: delivery public id, event type/public id, integration, endpoint, vineyard, status, attempts, last HTTP status, last error category, next retry, created/terminal timestamps, replay linkage, test flag. |

Per-delivery **detail** (attempt history and the canonical safe event
envelope) is intentionally served by the existing
`integration_get_webhook_delivery` — platform admins pass its view authority
via `is_system_admin()` inside `_integration_can_view` (SQL 178). Receiver
response bodies are never stored or returned.

### Control actions (narrow, reversible, audited)

| RPC | Effect | Audit action |
| --- | --- | --- |
| `admin_suspend_integration(p_client_id, p_reason)` | `status -> 'paused'` | `integration.paused` |
| `admin_reactivate_integration(p_client_id)` | `'paused' -> 'active'` | `integration.reactivated` |
| `admin_revoke_integration_api_key(p_api_key_id, p_reason)` | sets `revoked_at` | `api_key.revoked` |
| `admin_set_webhook_endpoint_status(p_endpoint_id, 'active'\|'paused', p_reason)` | pause, or reactivate (also clears disable state + failure streak) | `webhook_endpoint.paused` / `.reactivated` |

All controls require explicit target ids, write an `integration_audit_log`
record with `metadata.platform_admin = true` (+ optional reason, truncated to
200 chars), and return safe confirmation metadata only. There are **no**
delete actions; suspension/revocation are state changes and customer
configuration always remains intact. Revoked integrations are terminal
(matching the SQL 172 state machine) and cannot be suspended/reactivated.

### Audit history

`admin_list_integration_audit(p_client_id, p_action, p_actor_user_id,
p_vineyard_id, p_from, p_to, ...)` — global or per-integration audit trail:
timestamp, actor (id + email), `actor_type` (`platform_admin` / `user` /
`system` for actorless automation such as auto-disable), integration, action,
vineyard, safe metadata. Covers the full SQL 172/178 action catalogue
(integration lifecycle, grants, scopes, keys, webhook endpoint lifecycle,
secret rotation, replay, test sends) plus the Stage 7A admin actions above.
Audit metadata never contains credentials (existing 172/178 invariant).

## 4. Health classification

Computed **in the backend** by `_admin_integration_health` and returned by the
list/get/diagnostics RPCs as
`{ classification, reasons[], signals{} }`. The frontend must not re-derive
these rules. Evaluation order: inactive(revoked) → critical → warning →
inactive(dormant) → healthy.

| Class | Conditions (any) |
| --- | --- |
| `inactive` | integration `revoked` (terminal, expected-quiet); **or** created > 30 days ago with no API request and no webhook delivery in the last 30 days |
| `critical` | integration `paused` (suspended); any non-deleted webhook endpoint `disabled` (including the SQL 178 auto-disable at 10 consecutive failures); has keys but zero usable keys (all revoked/expired) |
| `warning` | ≥ 20 requests in 24h with > 10% 4xx/5xx error rate; ≥ 10 rate-limited (429) requests in 24h; any endpoint with ≥ 3 consecutive delivery failures; any usable key expiring within 7 days |
| `healthy` | none of the above |

Thresholds were chosen conservatively; they are backend constants and can be
tuned in one place. **Open product decisions** (surfaced, not invented):

- whether persistent 5xx delivery failures short of auto-disable should be
  `critical` rather than `warning` (currently the streak reaches auto-disable
  at 10 and flips to critical then);
- the dormancy window (30 days) for `inactive`;
- whether a paused **endpoint** (customer-initiated) should affect health
  (currently it does not — pausing is a legitimate customer action).

## 5. Metrics definitions

- `client_error_4xx` **includes** 429s; `rate_limited` is also reported
  separately.
- `unauthenticated` = request-log rows with no resolved integration
  (failed key auth); they count toward totals but not toward
  `unique_integrations` / `unique_api_keys` (SQL `count(distinct)` ignores
  nulls).
- `p95_duration_ms` uses `percentile_cont(0.95)` over `duration_ms`.
- Delivery `delivered_rate` / `failed_rate` are computed over **terminal**
  deliveries (`delivered` + `failed`) in the window; `retry_scheduled` =
  `pending` with ≥ 1 prior attempt.
- Failed webhook attempt = attempt row with a non-null `error_category`.

## 6. Suspension semantics

Stage 7A reuses the canonical `integration_clients.status` machine — no new
mechanism:

- **Suspend** (`admin_suspend_integration`) sets `status = 'paused'`:
  - API authentication fails safely: `integration_authenticate_api_key`
    (SQL 173) returns `integration_not_active`; the gateway maps this to
    HTTP 403 `integration_not_active`.
  - Webhook fan-out stops: `_integration_emit_event` only fans out to
    `active` clients (SQL 178).
  - Queued deliveries are **deferred** (+5 minutes per dispatcher claim pass,
    SQL 178 `integration_webhook_claim_deliveries`) — not cancelled — so
    reactivation resumes delivery.
  - Customer configuration (grants, scopes, keys, endpoints, subscriptions)
    remains intact.
- **Reactivate** restores `status = 'active'`, clears `paused_at`.
- **Revoked** remains terminal: queued deliveries are cancelled with
  `cancel_reason = 'integration_revoked'`; admin RPCs refuse to suspend or
  reactivate a revoked integration.

## 7. Indexes (performance review)

Existing coverage (SQL 172–178) is client-scoped: `integration_api_requests
(integration_client_id, created_at desc[, id desc])`, `(api_key_id,
created_at desc)`, `(request_id)`; `webhook_deliveries` due-queue partial,
client keyset, endpoint, event indexes; audit `(integration_client_id,
created_at desc)`; `next_attempt_at` partial for the dispatcher.

Stage 7A adds exactly three, all justified by platform-wide (no client
filter) keyset listing and windowed metrics:

- `idx_integration_api_requests_created_keyset (created_at desc, id desc)`
- `idx_webhook_deliveries_created_keyset (created_at desc, id desc)`
- `idx_integration_audit_created_keyset (created_at desc, id desc)`

Deliberately **not** added (avoid write overhead without demonstrated need):
partial error-only index on `integration_api_requests (created_at) where
status_code >= 400` — errors-only listing rides the new keyset index; revisit
if error scans become slow at volume. `status_code`, `event_type` and
`vineyard_id` access paths are already served by existing indexes or are
small-table scans (`webhook_endpoints` is capped at 10 per client).

The list health computation runs a handful of small indexed lookups per row;
page size is capped at 200 and the surface is staff-only, so this is
acceptable. If the directory grows to thousands of integrations, materialise
health signals into a summary table on a schedule.

## 8. Data retention (review — no data deleted in this stage)

| Table | Current retention | Growth driver | Concern |
| --- | --- | --- | --- |
| `integration_api_requests` | none (indefinite) | 1 row per API request; at the 300/min limit a single busy key could write ~432k rows/day | **highest** — first table to need a policy |
| `webhook_deliveries` | none | 1 row per event × matching endpoint | medium |
| `webhook_delivery_attempts` | none | ≤ 7 rows per delivery | medium |
| `integration_events` | none (immutable outbox) | 1 row per emitted domain event | medium |
| `integration_audit_log` | none (append-only by trigger) | low volume (config changes) | low — keep indefinitely |
| `integration_rate_limit_counters` | self-pruned > 10 min (SQL 173) | ephemeral | none |

Recommended future policy (**product decision — carried from Stage 6, still
open; do not implement silently**): request log 90 days, delivery attempts
30–90 days, deliveries 90 days, events 180 days (or archive), audit log
indefinite. Precedent for a retention migration exists
(`sql/031_rainfall_retention_policy.sql`). Aggregated metrics older than the
raw-log horizon would need a rollup table if long-range charting is wanted.

## 9. Operational runbook

- **"Customer says their integration stopped working"** →
  `admin_get_integration_diagnostics(client_id)`: check `health.reasons`,
  `api_activity.last_request.error_code`, key statuses (expired/revoked?),
  endpoint `disabled_reason`, `recent_audit` for who changed what.
- **"Who is hammering the API?"** →
  `admin_integration_api_metrics('24h', null, 'integration')`, then
  `('24h', client_id, 'path')` and `('24h', client_id, 'api_key')`.
- **"Which keys are being rate-limited?"** →
  `admin_list_integration_api_requests(p_rate_limited_only => true)`.
- **"Are webhooks healthy platform-wide?"** → `admin_webhook_metrics('24h')`;
  drill in with `admin_list_webhook_endpoints(p_failing_only => true)` and
  `admin_list_webhook_deliveries(p_status => 'failed')`; per-delivery detail
  via `integration_get_webhook_delivery(delivery_id)`.
- **"Emergency: abusive/compromised integration"** →
  `admin_suspend_integration(client_id, reason)` (reversible) or
  `admin_revoke_integration_api_key(key_id, reason)` for a single credential.
  Everything is audited with `platform_admin: true`.
- **"Receiver fixed after auto-disable"** →
  `admin_set_webhook_endpoint_status(endpoint_id, 'active', reason)` —
  clears `disabled_reason` and resets the failure streak.
- Failed-auth spikes (`p_unauthenticated_only => true`) indicate key scanning
  or a customer with a broken credential — correlate timestamps with
  `admin_integration_api_metrics('24h', null, 'day')`.

## 10. Security boundaries (tested)

`sql/tests/179_integration_platform_admin_tests.sql` (rollback-only) covers:
platform admin allowed; vineyard Owner/Manager/Supervisor/Operator denied;
anon denied; service_role denied (no grant); internal helper not callable by
authenticated; secret/hash/URL-credential non-exposure across list, request
log, endpoint, delivery and diagnostics outputs; suspended-integration
authentication failure (`integration_not_active`); audit writes for every
control action; keyset pagination and cursor validation; health
classification fixtures (healthy / critical via auto-disabled endpoint /
inactive-dormant).

Stage 7A changes **no** customer-facing `/v1/*` semantics, scope meanings,
rate limits, webhook signature contract or retry schedule, and introduces
**no** public write API.
