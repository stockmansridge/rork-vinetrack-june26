# VineTrack Webhooks — v1 (Stage 5A)

Outbound webhooks notify external systems when operational data changes in
VineTrack. They complement the read-only VineTrack API
(`docs/vinetrack-api-v1.md`): a webhook tells you *that* something changed;
the API remains the authoritative place to fetch *what* it now looks like.

Built on the Stage 2 integration foundation (SQL 172): the same integration
clients, vineyard grants, scopes and audit log govern webhooks.

> **Developer-facing guide:** external developers should start with
> `docs/vinetrack-developer-platform.md` — the consolidated onboarding,
> API and webhook guide. Both documents must agree; this file remains the
> deep webhook reference. Machine-readable event catalogue:
> `docs/webhooks/vinetrack-events-v1.json`.

## Delivery model — read this first

- **At-least-once.** A delivery may occasionally arrive more than once
  (for example when a timeout hid a success, or a dispatcher lease expired
  mid-flight). Consumers MUST deduplicate on the event `id` (stable across
  retries and replays) or the `X-VineTrack-Delivery` id (unique per
  delivery attempt series).
- **No ordering guarantee.** Events for the same vineyard, and even for the
  same resource, can arrive out of order. Use `occurred_at` and your own
  reads from the API to reconcile.
- **Compact payloads.** The `data` object carries identifiers plus at most a
  small lifecycle field (for example `status`). It never contains labour,
  cost, team or other sensitive fields. Fetch full state from the read API
  with your API key.
- **Transactional events.** Events are recorded in the same database
  transaction as the operational write (outbox pattern), so a rolled-back
  write never emits and a committed write is never silently skipped at the
  recording stage.

## Prerequisites

An endpoint only ever receives an event when ALL of these hold at delivery
time (checked when the event is emitted AND re-checked when it is sent):

1. The integration client is `active` (not paused, not revoked).
2. The endpoint is `active` (not paused, disabled or deleted).
3. The event's vineyard is **actively granted** to the integration.
4. The integration holds the **active read scope** for the event family
   (`trips:read` for `trip.*`, `sprays:read` for `spray_job.*`, etc. —
   same scope families as the read API).
5. A matching active subscription exists (event name, optionally restricted
   to one vineyard).

Revoking a grant or scope stops future deliveries **and** cancels queued,
not-yet-sent deliveries (cancel reason `vineyard_grant_revoked` /
`scope_revoked`). It also blocks replays of old deliveries.

## Event catalogue

| Event | Emitted when |
|---|---|
| `trip.created` | A trip row is created (still in progress) |
| `trip.updated` | A non-tracking edit to a trip (see notes) |
| `trip.completed` | A trip gains its end time — including trips synced already-finished (those emit ONLY `trip.completed`, not `created`) |
| `spray_job.created` | **Not emitted in v1** — reserved (see notes) |
| `spray_job.updated` | A spray record is edited |
| `spray_job.completed` | A spray record is created (a record IS a completed application) |
| `fuel_purchase.created` | A bulk fuel purchase is recorded |
| `fuel_log.created` / `fuel_log.updated` | A tractor fuel fill is recorded / edited |
| `growth_stage.recorded` | A growth stage observation is recorded (insert-only) |
| `yield_record.created` / `yield_record.updated` | A yield record is created / edited |
| `work_task.created` / `work_task.updated` | A work task is created / edited |
| `work_task.completed` | A work task is **finalised** (the canonical completion concept) |
| `pruning_activity.created` / `pruning_activity.updated` | A pruning activity is created / edited |
| `irrigation_record.created` / `irrigation_record.updated` | An irrigation session is recorded / corrected |
| `irrigation_record.completed` | A planned/running session transitions to completed |
| `pin.created` / `pin.updated` | An observation pin is created / edited |
| `pin.resolved` | A pin transitions to completed/resolved |
| `block.created` / `block.updated` | A block (paddock) is created / edited |
| `webhook.test` | You pressed *Send test webhook* (system event; not subscribable) |

Lifecycle notes (deliberate decisions, matched to the canonical data model):

- **One logical event per operation.** A row inserted already-completed emits
  only the `*.completed` event, never `created` + `completed`.
- **`spray_job.created` is not emitted in v1.** Spray records represent
  finished applications, so creation IS completion. The name stays reserved
  in the catalogue for a future planning-header exposure.
- **Live trip tracking is silent.** While a trip is actively tracking
  (`is_active`), its frequent sync updates do NOT emit `trip.updated` —
  you get `trip.created` at start and `trip.completed` at the end.
- **Deletions/reversals are silent in v1.** There are no `*.deleted` event
  names, and reversed pruning activities / irrigation sessions (which the
  read API omits) emit nothing.
- **Deduplication at source.** `created`/`completed`/`recorded` transitions
  emit at most once per resource, ever (safe against offline sync replays).
  `updated` transitions emit at most once per database transaction, so a
  burst of field edits saved together arrives as one event.
- **Child-record edits don't emit.** Events fire on the canonical primary
  tables. Editing only an allocation/child row (for example a pruning block
  allocation) without touching the parent does not emit in v1.

## The envelope

Every delivery is an HTTP `POST` with this JSON body:

```json
{
  "id": "evt_9f8e7d6c5b4a39281706f5e4d3c2b1a0",
  "type": "trip.completed",
  "api_version": "v1",
  "occurred_at": "2026-08-10T01:02:03.456Z",
  "vineyard_id": "3a1c2f1e-0000-4000-8000-000000000001",
  "data": {
    "id": "5b2d3e4f-0000-4000-8000-000000000002",
    "end_time": "2026-08-10T01:00:00+00:00"
  }
}
```

- `id` — stable event id. The same event keeps the same id across retries
  AND replays. Deduplicate on it.
- `vineyard_id` — `null` only for `webhook.test`.
- `data.id` — the resource id, usable directly against the read API
  (for example `GET /v1/trips/{id}`).

### Headers

| Header | Meaning |
|---|---|
| `X-VineTrack-Signature` | `v1=<hex HMAC-SHA256>` — see below |
| `X-VineTrack-Timestamp` | Unix seconds used in the signed message |
| `X-VineTrack-Event` | Event type, e.g. `trip.completed` |
| `X-VineTrack-Delivery` | Delivery id `dlv_…` — unique per delivery row; a replay gets a NEW id |
| `X-VineTrack-API-Version` | `v1` |
| `User-Agent` | `VineTrack-Webhooks/1.0` |

## Verifying signatures

Each endpoint has its own signing secret (`whsec_…`, shown exactly once at
creation/rotation). The signature is:

```
signed_message = "<X-VineTrack-Timestamp>" + "." + <raw request body bytes>
signature      = "v1=" + hex( HMAC_SHA256( secret, signed_message ) )
```

Verification rules:

1. Read the RAW request body (before any JSON parsing/re-serialisation).
2. Compute the HMAC with your stored secret and compare to
   `X-VineTrack-Signature` using a constant-time comparison.
3. Reject if `X-VineTrack-Timestamp` is older than your tolerance
   (5 minutes is recommended) to prevent replay of captured requests.

Node example:

```js
const crypto = require("crypto");

function verify(rawBody, headers, secret) {
  const ts = headers["x-vinetrack-timestamp"];
  const expected = "v1=" + crypto
    .createHmac("sha256", secret)
    .update(`${ts}.${rawBody}`)
    .digest("hex");
  const given = headers["x-vinetrack-signature"] ?? "";
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  return given.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected));
}
```

**Secret rotation is an immediate cutover** — the old secret stops being
used the moment rotation returns. Rotate during a quiet window, update your
receiver, then use *Send test webhook* to confirm.

## Responding, retries and failure handling

- Respond with any **2xx** within **10 seconds**. Do heavy work async.
- Redirects are **not** followed (3xx is a permanent failure).
- **Retryable**: timeouts, network/TLS errors, HTTP 5xx, 408 and 429.
- **Permanent** (no retry): other 4xx, 3xx, delivery-policy blocks.
- Backoff after failed attempt N: **1m, 5m, 30m, 2h, 12h, 24h**
  (maximum 7 attempts, then the delivery is `failed`).
- A `Retry-After` header on 429/503 is honoured (it can widen a scheduled
  gap, up to 1 hour; it never shortens one).

### Endpoint health

- Any successful delivery resets the endpoint's consecutive-failure count.
- After **10 consecutive failures** the endpoint is automatically
  **disabled** (audited). Queued deliveries to a disabled endpoint are
  cancelled. Fix the receiver, reactivate the endpoint, then replay what
  you missed.
- **Paused** endpoints (manual pause, or a paused integration) are gentler:
  queued deliveries are deferred, nothing is lost, and delivery resumes
  automatically on reactivation.

### Delivery states

`pending → delivering → delivered | failed | cancelled`

Cancel reasons you may see in the delivery log: `endpoint_deleted`,
`endpoint_disabled`, `integration_revoked`, `vineyard_grant_revoked`,
`scope_revoked`.

## Endpoint URL policy (SSRF protection)

Accepted URLs must be `https://` with a real public hostname:

- optional explicit port limited to `443`/`8443`;
- hostname required — IPv4/IPv6/decimal/hex IP literals are refused;
- at least one dot and an alphabetic TLD (no single-label intranet names);
- `localhost`, `*.localhost`, `*.local`, `*.internal`, `*.home.arpa` and
  cloud metadata hosts are refused;
- no userinfo (`user@host`).

At send time the dispatcher re-resolves the hostname and refuses any
private/reserved address, and never follows redirects.

## Test webhooks and replays

- **Send test webhook** emits a `webhook.test` event to one endpoint,
  signed and delivered exactly like a real event (it proves transport +
  signature, not entitlements). `vineyard_id` is `null`.
- **Replay** creates a brand-new delivery (new `X-VineTrack-Delivery` id,
  fresh attempt counter) of the SAME event (`id` unchanged). Replays are
  refused when the endpoint is not active or the grant/scope chain has been
  revoked. Both actions are audited.

## Management surface (Lovable portal RPCs)

All management goes through SECURITY DEFINER RPCs — the underlying tables
are not directly readable. Authority model is identical to Stage 2:
account owner (and platform admin) manage; Owner/Manager members of granted
vineyards may view.

| RPC | Authority |
|---|---|
| `integration_list_webhook_endpoints(client_id)` | view |
| `integration_get_webhook_endpoint(endpoint_id)` | view |
| `integration_create_webhook_endpoint(client_id, url, name)` → returns `signing_secret` ONCE | manage |
| `integration_update_webhook_endpoint(endpoint_id, url, name)` | manage |
| `integration_set_webhook_endpoint_status(endpoint_id, 'paused'\|'active')` | manage |
| `integration_delete_webhook_endpoint(endpoint_id)` (soft delete; cancels queue; destroys Vault secret) | manage |
| `integration_rotate_webhook_secret(endpoint_id)` → returns new secret ONCE | manage |
| `integration_list_webhook_subscriptions(endpoint_id)` | view |
| `integration_create_webhook_subscription(endpoint_id, event_type, vineyard_id?)` | manage |
| `integration_delete_webhook_subscription(subscription_id)` | manage |
| `integration_send_test_webhook(endpoint_id)` | manage |
| `integration_replay_webhook_delivery(delivery_id)` | manage |
| `integration_list_webhook_deliveries(client_id, …filters, keyset cursor)` | view |
| `integration_get_webhook_delivery(delivery_id)` (includes attempt history) | view |

Error codes raised: `not_authenticated`, `integration_not_found`,
`webhook_endpoint_not_found`, `invalid_webhook_url`,
`webhook_url_not_allowed`, `endpoint_limit_reached` (10 per integration),
`integration_not_active`, `endpoint_not_active`, `event_not_found`,
`event_not_subscribable`, `scope_not_granted`, `vineyard_not_granted`,
`subscription_exists`, `subscription_not_found`, `delivery_not_found`,
`replay_not_allowed`, `invalid_status`, `invalid_cursor`, `invalid_range`,
`invalid_request`.

Delivery listing filters: endpoint, event type, status, vineyard, time
range; newest first; keyset pagination via
(`next_before_created_at`, `next_before_id`); limit 1–1000 (default 100).

Every management action is written to `integration_audit_log`
(`webhook_endpoint.created/updated/paused/reactivated/disabled/deleted`,
`webhook_secret.rotated`, `webhook_subscription.created/deleted`,
`webhook.test_sent`, `webhook.replayed`). Audit rows never contain secrets.

## Security properties

- Signing secrets live in **Supabase Vault**; tables store only a SHA-256
  hash + display prefix. The plaintext is shown once and is unrecoverable
  afterwards — including by platform admins. The only reader of the usable
  secret is the service-role dispatcher RPC.
- Delivery/attempt logs store status codes, durations and sanitised error
  categories — **never** request/response bodies or receiver headers.
- Event payloads never include sensitive fields (labour, costs, team).

## Retention and limitations (v1, documented)

- Events, deliveries and attempts are retained **indefinitely** — no
  cleanup job exists yet. Add retention before volume becomes a concern.
- Emission is skipped entirely for vineyards with no active integration
  grant (nothing is stored — this keeps app sync writes cheap).
- If event recording itself errors, the operational write still succeeds
  and a WARNING lands in the Postgres logs (deliberate trade-off: a webhook
  bug must never break iOS/Android sync). Covered by tests.
- DNS-rebinding between the dispatcher's resolution check and the actual
  request remains a theoretical TOCTOU window (documented; full mitigation
  needs a custom connection layer).

## Deployment (engineering)

- Migration: `sql/178_integration_webhook_platform.sql`
  (requires SQL 172–177 applied; requires Supabase Vault, present on all
  hosted projects). Tests: `sql/tests/178_integration_webhook_platform_tests.sql`
  (single transaction, rollback-only).
- Dispatcher: `supabase/functions/vinetrack-webhook-dispatch`
  (deploy like the other functions; see `scripts/deploy-edge-functions.*`).
  Auth: `Authorization: Bearer <service-role key>` or an
  `x-dispatch-secret` header matching the `WEBHOOK_DISPATCH_SECRET`
  function secret.
- Scheduling: invoke the function every minute. Supabase cron example
  (Dashboard → Integrations → Cron, or `pg_cron` + `pg_net`):

  ```sql
  select cron.schedule(
    'vinetrack-webhook-dispatch', '* * * * *',
    $$ select net.http_post(
         url     := 'https://<project-ref>.supabase.co/functions/v1/vinetrack-webhook-dispatch',
         headers := jsonb_build_object(
           'Content-Type', 'application/json',
           'Authorization', 'Bearer ' || '<service-role-key>'),
         body    := '{}'::jsonb) $$);
  ```

  Parallel/overlapping runs are safe: claiming uses
  `FOR UPDATE SKIP LOCKED` with a lease, so no delivery is double-sent
  inside a lease window.
- Unit tests for the signing/SSRF/classification helpers:
  `deno test supabase/functions/vinetrack-webhook-dispatch/lib_test.ts`.
