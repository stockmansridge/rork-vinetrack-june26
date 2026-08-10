# VineTrack Integration Platform — Stage 5A Backend Report
# Outbound Webhook Platform

Stage 5A turns the dormant Stage 2 webhook schema (SQL 172) into a complete,
running webhook system: canonical domain events, subscription fan-out, a
signed HTTP dispatcher with retries/backoff, endpoint health + auto-disable,
test sends, replays, full management RPCs and audit coverage.

No iOS, Android or Lovable code was changed. Everything is additive on the
SQL 172–177 foundation.

## 1. Deliverables

| File | Purpose |
|---|---|
| `sql/178_integration_webhook_platform.sql` | The migration (schema + helpers + triggers + management RPCs + dispatcher RPCs) |
| `sql/tests/178_integration_webhook_platform_tests.sql` | Rollback-only verification, T1–T18 |
| `supabase/functions/vinetrack-webhook-dispatch/index.ts` | Dispatcher Edge Function |
| `supabase/functions/vinetrack-webhook-dispatch/lib.ts` | Pure helpers (signing, SSRF, classification) |
| `supabase/functions/vinetrack-webhook-dispatch/lib_test.ts` | Deno unit tests (9 tests, all passing) |
| `docs/vinetrack-webhooks.md` | Developer contract (envelope, signature, retries, policy, RPC surface) |
| `docs/vinetrack-api-v1.md` | New "Webhooks" section pointing at the contract |

## 2. Schema (additive)

New tables (RLS on, zero client privileges — RPC/service-role only):

- **`integration_events`** — immutable outbox. `public_id` (`evt_<32hex>`,
  the envelope `id`), `event_type` (FK to the Stage 2 catalogue),
  `vineyard_id` (null only for `webhook.test`), `resource_type` / `resource_id`,
  compact `payload` (never a raw row), `dedup_key` (unique where not null),
  `source`. UPDATE/DELETE blocked by trigger.
- **`webhook_deliveries`** — queue + history. `public_id` (`dlv_<32hex>`,
  the `X-VineTrack-Delivery` header), status machine
  `pending → delivering → delivered | failed | cancelled`, lease fields
  (`claim_token`, `claimed_at`), `next_attempt_at`, `attempt_count`,
  `is_test`, `replay_of`, `cancel_reason`, last status/error. Unique
  original delivery per (event, endpoint); replays/tests exempt. Partial
  index on the due queue; keyset index per client.
- **`webhook_delivery_attempts`** — one row per HTTP attempt: status,
  duration, sanitised `error_category` + `error_detail` (≤500 chars).
  **No request/response bodies are ever stored.**

`webhook_endpoints` extensions: `name`, `secret_ref` (Vault id),
`last_success_at`, `last_failure_at`, `consecutive_failures`, `paused_at`,
`disabled_at`, `disabled_reason`, `deleted_at`; status check widened to
`active | paused | disabled` (constraint swap widens only).

Catalogue extensions: `integration_webhook_event_catalog.is_system` +
`webhook.test` row. `integration_audit_log` action check widened with the
11 webhook actions (original 12 values preserved verbatim).

## 3. Event generation — mechanism and rationale

**Triggers on the 11 canonical primary tables** (`trips`, `spray_records`,
`fuel_purchases`, `tractor_fuel_logs`, `work_tasks`, `pruning_activities`,
`irrigation_sessions`, `growth_stage_records`, `historical_yield_records`,
`pins`, `paddocks`). Rationale: mutation paths are fragmented — iOS sync,
Android sync and portal RPCs all write these tables directly — so the table
is the only reliable choke point. RPC-level emission would miss the app sync
paths entirely.

Guarantees:

- **Outbox atomicity**: the event insert shares the operational
  transaction. Rolled-back write ⇒ no event (tested, T11).
- **Never break the app**: emission runs through `_integration_emit_safe`,
  which converts any emission error into a Postgres WARNING instead of
  failing the sync write. Deliberate trade-off, documented and tested.
- **Fast exit**: nothing is stored for vineyards with **no active
  integration grant** (single indexed EXISTS per row — hot sync tables stay
  cheap, and event storage cannot grow for non-integrated accounts).
- **Dedup at source**: `created/completed/recorded` keys are once-ever per
  resource (offline sync replays safe — notably `pruning_activities`'
  client-generated-id replays); `updated` keys carry `txid_current()`
  (one event per transaction burst).

## 4. Catalogue mapping decisions (canonical model vs event names)

- `trip.completed` = `end_time` transition; rows synced already-finished
  emit ONLY `trip.completed` (one logical event per operation).
  `trip.updated` is suppressed while `is_active` (live-tracking sync noise,
  many writes/minute).
- `spray_job.completed` = spray record INSERT (a record IS a completed
  application). **`spray_job.created` is not emitted in v1** — reserved for
  future planning-header exposure; documented in the contract.
- `work_task.completed` = finalisation (`is_finalized` false→true), the
  only canonical completion concept work tasks have.
- `irrigation_record.completed` = `planned/running → completed` status
  transition; inserts (typically recorded post-hoc as completed) emit
  `irrigation_record.created`.
- `pin.resolved` = `is_completed` false→true (re-resolvable → txid dedup).
- Deletions/reversals emit nothing (no `*.deleted` names in the catalogue;
  reversed pruning/irrigation rows are omitted by the read API).
- `fuel_purchase` and `growth_stage` are insert-only families, matching the
  catalogue (no `updated` names exist for them).

## 5. Envelope + signature contract

Body: `{id, type, api_version, occurred_at, vineyard_id, data}` — compact,
identifiers + at most a small lifecycle field; never sensitive fields.

Headers: `X-VineTrack-Signature: v1=<hex>`, `X-VineTrack-Timestamp`,
`X-VineTrack-Event`, `X-VineTrack-Delivery`, `X-VineTrack-API-Version`.

Signature: `HMAC_SHA256(secret, "<timestamp>.<raw body>")` — timestamped to
kill replay of captured requests; verification guide with constant-time
comparison and 5-minute tolerance is in `docs/vinetrack-webhooks.md`.
Determinism covered by deno tests (same inputs ⇒ same signature; secret /
timestamp / body each change it; independent WebCrypto verify round-trip).

## 6. Secret handling

- `whsec_<48hex>` generated server-side; **returned exactly once** by
  create/rotate RPCs.
- Tables store SHA-256 hash + 14-char display prefix only. The usable
  secret lives in **Supabase Vault**; `webhook_endpoints.secret_ref` holds
  the Vault id. The only reader is `integration_webhook_get_endpoint_secret`
  (service_role only).
- Rotation is an immediate cutover (hash + Vault updated atomically);
  endpoint deletion destroys the Vault row. Tested: plaintext appears in no
  table column and no audit row (T4); Vault row gone after delete (T18).

## 7. Dispatcher (`vinetrack-webhook-dispatch`)

- Claim loop: `integration_webhook_claim_deliveries(batch, lease)` uses
  `FOR UPDATE SKIP LOCKED` + a claim-token lease ⇒ **parallel/overlapping
  runs are safe**; an expired lease is reclaimable ⇒ **at-least-once**.
- Claim-time re-validation (the lazy revocation point): endpoint deleted /
  disabled and revoked integrations **cancel** queued deliveries
  (`endpoint_deleted`, `endpoint_disabled`, `integration_revoked`,
  `vineyard_grant_revoked`, `scope_revoked`); paused endpoint/integration
  **defers** (+5 min, nothing lost, resumes on reactivation).
- Send: HTTPS POST, 10s timeout, redirects never followed, SSRF re-check
  (hostname policy + DNS resolution against private/reserved IPv4+IPv6
  ranges) before every attempt.
- Classification: 2xx success; timeout/network/TLS/5xx/408/429 retryable;
  other 4xx and all 3xx permanent. `Retry-After` honoured (widens only,
  clamped to 1h).
- Bookkeeping via `integration_webhook_record_attempt`: backoff schedule
  **1m, 5m, 30m, 2h, 12h, 24h**, max 7 attempts; success resets endpoint
  health; **10 consecutive failures auto-disable the endpoint** (audited).
- Run budget ~45s, batches of 20, per-endpoint secret memoisation.
- Auth: service-role Bearer or `x-dispatch-secret` = `WEBHOOK_DISPATCH_SECRET`.

## 8. Authority + audit

Identical to Stage 2: mutations require account owner / platform admin
(`_integration_require_manage`); reads additionally allow Owner/Manager
members of actively granted vineyards (`_integration_can_view`).
Non-disclosing errors throughout (`webhook_endpoint_not_found` /
`delivery_not_found` for missing AND not-yours — no id probing).

Subscription creation enforces, independently: event exists, not
system-only, **active required scope** for the event family (derived from
the catalogue module → `trips:read` etc.), and an **active vineyard grant**
for vineyard-restricted subscriptions.

Audited actions: endpoint created/updated/paused/reactivated/disabled
(auto-disable included)/deleted, secret rotated, subscription
created/deleted, test sent, replayed. Audit log remains append-only.

## 9. Verification

`sql/tests/178_integration_webhook_platform_tests.sql` — one transaction,
rolled back; expected final output
`NOTICE: SQL 178 webhook platform tests: ALL PASSED`:

- T1 objects/triggers/functions exist (11 event triggers verified)
- T2 direct table access denied to authenticated
- T3 HTTPS/SSRF URL matrix (18 hostile URLs refused) + 10-endpoint cap
- T4 one-time secret, hash/prefix-only storage, Vault round-trip, rotation
- T5 authority matrix (Owner B non-disclosure; Manager view-only; Sup/Op none)
- T6 subscription gates (unknown event / system event / missing scope /
  non-granted vineyard / duplicate)
- T7 emission fast-exit (never-granted vineyard stores nothing)
- T8 trip lifecycle incl. live-tracking suppression + same-tx dedup
- T9 fan-out (overlapping subs ⇒ ONE delivery; no sub ⇒ no delivery;
  paused endpoint skips delivery but never the event)
- T10 every resource family emits exactly one correct event
- T11 outbox atomicity (rolled-back write ⇒ no event)
- T12 event immutability
- T13 claim envelope shape, double-claim protection, lease expiry reclaim,
  success bookkeeping
- T14 claim-token enforcement, 1-minute backoff, Retry-After, permanent
  4xx, 7-attempt cap
- T15 auto-disable at 10 failures + audit + claim-time cancellation +
  reactivation reset
- T16 pause defers; scope/grant revocation cancels queued deliveries and
  blocks replay
- T17 test webhook (null vineyard, is_test, claimable, audited); replay ids
  never reused
- T18 delivery list/detail RPCs (filters, keyset, attempt history, manager
  view, Owner B refusal), endpoint delete (queue cancelled, Vault cleared),
  audit coverage + append-only

Dispatcher unit tests (deno): 9/9 passing — signature determinism +
mutation sensitivity + WebCrypto round-trip, hostname SSRF matrix,
private IPv4/IPv6 detection, status classification, Retry-After parsing.
`deno check` clean for `index.ts`, `lib.ts`, `lib_test.ts`.

## 10. Confirmations

- Direct table access to all new tables is revoked; catalogues remain the
  only readable reference data (unchanged from Stage 2).
- No secret, hash, Vault id, or HTTP body is exposed by any RPC or log.
- The migration is strictly additive: no Stage 2–4 object is dropped or
  narrowed (the two constraint swaps only widen allowed value sets).
- No iOS, Android or Lovable files were touched.

## 11. Known limitations (documented in the contract)

- No retention/cleanup job yet — events/deliveries/attempts grow unbounded.
- Child/allocation-table edits do not emit (primary-table triggers only).
- Emission failure degrades to a Postgres WARNING (app writes always win).
- DNS-rebinding TOCTOU window between dispatcher resolution check and fetch.
- `spray_job.created` reserved, not emitted (see §4).

## Go-live checklist

1. Apply `sql/178_integration_webhook_platform.sql` in the Supabase SQL
   editor (requires SQL 172–177; Vault is present on hosted projects).
2. Run `sql/tests/178_integration_webhook_platform_tests.sql` → expect
   `ALL PASSED` (rollback-only, safe on production).
3. Deploy `supabase/functions/vinetrack-webhook-dispatch`
   (add `--no-verify-jwt` only if the scheduler cannot send a JWT; the
   function enforces service-role / `WEBHOOK_DISPATCH_SECRET` itself).
4. Optionally set the `WEBHOOK_DISPATCH_SECRET` function secret.
5. Schedule the function every minute (Supabase cron / `pg_cron` +
   `pg_net`; snippet in `docs/vinetrack-webhooks.md`). Overlapping runs
   are safe.
6. Create an endpoint + subscription for a test integration, press
   *Send test webhook*, verify the signature at the receiver, then watch
   `integration_list_webhook_deliveries`.
7. Lovable portal UI for endpoints/subscriptions/delivery logs is the
   natural Stage 5B follow-up (the RPC surface in
   `docs/vinetrack-webhooks.md` §Management is everything it needs).
