# Lovable Hand-off — Billing Review Resolution Actions (SQL 148)

Backend contract for clearing Billing Health review items from the Access &
Entitlements page. Apply `sql/148_billing_review_resolution_actions.sql`
first; validate with `sql/tests/148_billing_review_resolution_tests.sql`
(single transaction, always rolled back).

Nothing is ever deleted: resolve/dismiss/acknowledge stamp state onto the
existing rows; raw provider events, payload history, alerts, subscriptions
and audit rows all remain queryable forever.

The entitlement cohort stays at `internal`. Do not change it.

---

## 1. Item types

Every review item is addressed by `(item_type, item_id)`:

| item_type            | item_id is…                     | Open definition (live)                                                    |
| -------------------- | ------------------------------- | ------------------------------------------------------------------------- |
| `event`              | `billing_provider_events.id`    | `processing_status` in `needs_review` / `failed`, not resolved/dismissed  |
| `unresolved_user`    | `billing_provider_events.id`    | `processing_error_code` in `unresolved_app_user_id` / `user_not_found`    |
| `ownership_conflict` | `billing_provider_events.id`    | `processing_error_code = 'ownership_conflict'`                            |
| `stuck_delivery`     | `billing_provider_events.id`    | `processing_status = 'received'` (monitor shows those older than 15 min)  |
| `alert`              | `billing_admin_alerts.id`       | `acknowledged_at is null`                                                 |

The monitor (`admin_store_billing_monitor()`) now returns `id` inside each
`recent` entry for events/stuck deliveries, so rows are directly actionable.

## 2. List RPC

```sql
admin_billing_review_items(
  p_item_type text,                 -- one of the five item types (required)
  p_status    text default 'open',  -- 'open' | 'resolved' | 'dismissed' | 'all'
  p_limit     integer default 100,  -- clamped 1..500
  p_offset    integer default 0
)
```

Returns one row per item (System Admin only; raises `42501` otherwise):

| column          | type        | notes                                                        |
| --------------- | ----------- | ------------------------------------------------------------ |
| item_id         | uuid        |                                                              |
| item_type       | text        | echoes the requested type                                    |
| severity        | text        | `critical` (failed / ownership conflict) or `warning`; alerts use their stored severity |
| status          | text        | `open` \| `resolved` \| `dismissed` (acknowledged alerts report `resolved`) |
| user_id         | uuid?       | linked Supabase user                                          |
| user_email      | text?       |                                                              |
| provider        | text?       | `revenuecat` etc.                                            |
| platform        | text?       | `ios` / `android` / `unknown`; null for alerts               |
| product         | text?       | store product id                                             |
| reason          | text?       | error code + short message (never payloads/receipts/tokens)  |
| created_at      | timestamptz | event `received_at` / alert `created_at`                     |
| last_attempt_at | timestamptz?| last retry or processing attempt                             |
| retry_count     | integer     | 0 for alerts                                                 |
| is_retryable    | boolean     | drive the Retry button from this — never compute client-side |
| resolved_at     | timestamptz?| alerts: `acknowledged_at`                                    |
| resolved_by     | uuid?       | alerts: `acknowledged_by`                                    |
| dismissed_at    | timestamptz?| always null for alerts                                       |
| dismissed_by    | uuid?       |                                                              |
| total_count     | bigint      | full filtered count for pagination                           |

## 3. Mutation RPC (unified)

```sql
admin_update_billing_review_item(
  p_item_type      text,
  p_item_id        uuid,
  p_action         text,               -- 'acknowledge' | 'resolve' | 'dismiss' | 'retry' | 'link_user'
  p_reason         text default null,  -- REQUIRED (non-empty) for EVERY action
  p_target_user_id uuid default null   -- required for 'link_user'
) returns jsonb
```

Action rules (unsupported combinations are rejected with SQLSTATE `22023`):

| action        | allowed item types                          | behaviour                                                                 |
| ------------- | ------------------------------------------- | ------------------------------------------------------------------------- |
| `acknowledge` | `alert` only                                | stamps `acknowledged_at/by`; alert leaves the open count, stays in history |
| `resolve`     | event family (all four)                     | stamps `resolved_at/by`, `resolution_reason`, `resolution_action='resolve'`; auto-acknowledges the event's open alerts |
| `dismiss`     | event family                                | stamps `dismissed_at/by`, `dismissal_reason`; auto-acknowledges its alerts |
| `retry`       | event family where `is_retryable` is true   | idempotent server-side reprocess (mirrors the webhook pipeline). Success (`processed`/`ignored`) auto-marks the item resolved with `resolution_action='retry'` and clears its alerts; failure leaves it open with the new code |
| `link_user`   | `unresolved_user`, `ownership_conflict`     | requires an explicit `auth.users.id` (`P0002` if it does not exist — never resolve by email alone); sets the event's `resolved_user_id`; then call `retry` |

Returns `{ item_type, item_id, action, status: 'ok', … }`; `retry` also returns
`result: { outcome, code, message, subscription_id, resolved_user_id }` where
`outcome` is `processed` / `ignored` / `needs_review` / `failed`.

Error codes: `42501` not a System Admin · `22023` validation
(`reason_required`, `invalid_item_type`, `invalid_action`,
`invalid_action_for_item_type`, `item_type_mismatch`, `already_closed`,
`not_retryable`, `target_user_required`) · `P0002` `item_not_found` /
`user_not_found`.

Convenience wrappers (same semantics):

```sql
admin_resolve_billing_review_item(p_item_type text, p_item_id uuid, p_reason text)
admin_dismiss_billing_review_item(p_item_type text, p_item_id uuid, p_reason text)
admin_retry_billing_delivery(p_item_id uuid, p_reason text default 'Retry requested')
admin_acknowledge_billing_alert(p_alert_id uuid)   -- unchanged (SQL 139)
```

## 4. Retry semantics

- Idempotent: the reprocess locks and UPDATEs the same event row; the
  subscription upsert is keyed on `(billing_provider, external_subscription_id)`
  — retrying twice can never create a second subscription, licence or billing
  event. A second retry of an already-processed item is rejected.
- `TEST`, `TRANSFER` and `SUBSCRIBER_ALIAS` events are never retryable.
- Unresolved-user events become retryable only after `link_user`.
- A retry that still fails validation lands back in the appropriate queue with
  a fresh error code (e.g. an ownership conflict re-flags itself) — it is never
  silently forced through.

## 5. Monitor changes

`admin_store_billing_monitor()` (same call, same shape, additive):

- `events_needing_review`, `failed_events`, `unknown_products`,
  `unresolved_users`, `ownership_conflicts`, `stuck_deliveries` now EXCLUDE
  resolved/dismissed items — acting on an item immediately reduces the count.
- `rc_active_supabase_missing` entries disappear once their
  `sync_window_exceeded` alert is acknowledged (or the event is resolved).
- `recent` entries now include `id` (+ `retry_count`) so they are actionable.
- New `recent_review_actions` array: last 10 admin review actions
  (`event_type`, `item_type`, `item_id`, `reason`, `outcome`, `actor`,
  `created_at`).
- `open_alerts` unchanged (already excluded acknowledged alerts).

## 6. Audit

Every mutation writes an append-only row to `vinetrack_billing_events`
(`provider = 'system'`) with actor, reason and timestamp:
`billing_review_resolved`, `billing_review_dismissed`,
`billing_review_retried`, `billing_review_user_linked`,
`billing_review_alert_acknowledged`. There is no delete API of any kind.

## 7. Suggested UI flow per category

- **Open alerts** — Acknowledge (existing behaviour, or the unified RPC).
- **Events needing review** — Resolve / Dismiss (reason dialog is mandatory);
  show Retry when `is_retryable` is true.
- **Unresolved users** — "Link account" picker (must select a real user, then
  confirm) → `link_user`, then offer Retry; Dismiss only for confirmed
  synthetic/invalid events.
- **Stuck deliveries** — Retry first; Resolve after out-of-band correction;
  Dismiss with reason.
- **Ownership conflicts** — "Choose correct owner" → `link_user`, then Retry
  (safe: it re-flags if still conflicting); Resolve/Dismiss for known
  test/duplicate records.
- Render resolved/dismissed history via `p_status = 'resolved' | 'dismissed'`.
