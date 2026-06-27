# revenuecat-webhook — manual test helper (DRAFT)

> ⚠️ **DRAFT ONLY.** Part of the VineTrack July 2026 pricing/billing foundation.
> These payloads and commands exist to manually exercise the draft
> `revenuecat-webhook` Edge Function against the **draft** `public.vinetrack_*`
> tables (created by `supabase/migrations-draft-billing/01_vinetrack_pricing_entitlements.sql`).
>
> **Do NOT point a real RevenueCat project at this function** until the real
> Apple product IDs and RevenueCat entitlement IDs are confirmed and wired into
> `PRODUCT_TO_PLAN` / `ENTITLEMENT_TO_PLAN` in `index.ts`. Until then the sample
> `product_id` / `entitlement_id` values below match the **placeholder** keys in
> the function, so the function can map them to plans for testing.
>
> This does **not** change app access — `NewBackendRootView` still gates on the
> live RevenueCat SDK check. These tables are inert until the app/portal adopt
> `public.get_my_vinetrack_access()`.

---

## 1. Environment setup

The function reads three environment variables:

| Variable | Purpose | Notes |
| --- | --- | --- |
| `REVENUECAT_WEBHOOK_SECRET` | Shared secret. The function compares the request's `Authorization` header **verbatim** against this value. | Set the **same** value in the RevenueCat dashboard webhook "Authorization header" field (only once you go live). For local testing pick any string, e.g. `test-secret-123`. |
| `SUPABASE_URL` | Project URL. Used to create the service-role client. | Auto-provided in the deployed runtime. |
| `SUPABASE_SERVICE_ROLE_KEY` | Service-role key (bypasses RLS to write billing rows). | Auto-provided in the deployed runtime. **Never** expose this to clients. |

> ⚠️ **The `Authorization` header must equal the secret exactly** — the function
> does **not** expect a `Bearer ` prefix. If you set the secret to
> `test-secret-123`, the header must be `Authorization: test-secret-123`.

### Function URL format

- **Deployed:** `https://<PROJECT_REF>.supabase.co/functions/v1/revenuecat-webhook`
- **Local (supabase CLI):** `http://localhost:54321/functions/v1/revenuecat-webhook`

To serve and set the secret locally:

```bash
# Serve just this function with env vars from a file
supabase functions serve revenuecat-webhook --no-verify-jwt --env-file ./supabase/functions/.env.local

# .env.local (DO NOT COMMIT)
#   REVENUECAT_WEBHOOK_SECRET=test-secret-123
#   SUPABASE_URL=http://localhost:54321
#   SUPABASE_SERVICE_ROLE_KEY=<local service role key>
```

> `--no-verify-jwt` is required because RevenueCat does not send a Supabase JWT;
> the function does its own secret check instead.

---

## 2. Sample curl command

Set these shell variables first, then reuse them for every test below:

```bash
export FN_URL="https://<PROJECT_REF>.supabase.co/functions/v1/revenuecat-webhook"
export WEBHOOK_SECRET="test-secret-123"   # must match REVENUECAT_WEBHOOK_SECRET

curl -i -X POST "$FN_URL" \
  -H "Authorization: $WEBHOOK_SECRET" \
  -H "Content-Type: application/json" \
  -d @- <<'JSON'
{ "api_version": "1.0", "event": { ... } }
JSON
```

Each scenario below is a complete `-d` body you can paste in place of `{ ... }`.

---

## 3. Sample payloads

### Placeholder values — change these before/while testing

| Field | Placeholder used below | Replace with |
| --- | --- | --- |
| `app_user_id` | `00000000-0000-0000-0000-000000000000` | a **real** `auth.users.id` UUID (the test user). If it isn't a valid UUID the event is logged only (`logged_no_user`). |
| `product_id` | `com.vinetrack.solo.yearly` | the **real** Apple product ID once created in App Store Connect. The placeholder maps to `solo` in `PRODUCT_TO_PLAN`. |
| `entitlement_ids` | `["solo"]` | the **real** RevenueCat entitlement ID once created. The placeholder maps to `solo` in `ENTITLEMENT_TO_PLAN`. |
| `event.id` | `evt_solo_initial_001` | **Change between runs** unless you are deliberately testing idempotency (see §6). The function dedups on `(provider, event.id)`. |

> Timestamps are RevenueCat-style epoch **milliseconds** (`purchased_at_ms`,
> `expiration_at_ms`). Adjust them so `expiration_at_ms` is in the future for
> "still active" scenarios and in the past for expirations.

---

### 3.1 INITIAL_PURCHASE — Solo (no trial)

Maps to status `active`, creates/updates an Apple subscription + active licence.

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_solo_initial_001",
    "type": "INITIAL_PURCHASE",
    "app_user_id": "00000000-0000-0000-0000-000000000000",
    "product_id": "com.vinetrack.solo.yearly",
    "entitlement_ids": ["solo"],
    "period_type": "NORMAL",
    "environment": "SANDBOX",
    "purchased_at_ms": 1751328000000,
    "expiration_at_ms": 1782864000000
  }
}
```

Expected response: `{"status":"processed","planCode":"solo","subscriptionStatus":"active","revokedLicence":false}`.

---

### 3.2 Trial start — Solo (3-month free trial)

RevenueCat does **not** send a separate `TRIAL_STARTED`; a trial arrives as an
`INITIAL_PURCHASE` with `period_type: "TRIAL"` (or `"INTRO"`). The function maps
either to status `trialing` and records `trial_start` / `trial_end`.

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_solo_trial_001",
    "type": "INITIAL_PURCHASE",
    "app_user_id": "00000000-0000-0000-0000-000000000000",
    "product_id": "com.vinetrack.solo.yearly",
    "entitlement_ids": ["solo"],
    "period_type": "TRIAL",
    "environment": "SANDBOX",
    "purchased_at_ms": 1751328000000,
    "expiration_at_ms": 1759104000000
  }
}
```

Expected response: `subscriptionStatus":"trialing"`, active licence created.

---

### 3.3 RENEWAL — Solo

Maps to `active` (or `trialing` if `period_type` is `TRIAL`/`INTRO`). Updates the
existing subscription's period window; licence stays active.

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_solo_renewal_001",
    "type": "RENEWAL",
    "app_user_id": "00000000-0000-0000-0000-000000000000",
    "product_id": "com.vinetrack.solo.yearly",
    "entitlement_ids": ["solo"],
    "period_type": "NORMAL",
    "environment": "SANDBOX",
    "purchased_at_ms": 1782864000000,
    "expiration_at_ms": 1814400000000
  }
}
```

---

### 3.4 CANCELLATION — auto-renew off, access until period end

In RevenueCat, `CANCELLATION` means auto-renew was turned **off**; the user keeps
access until `expiration_at_ms`. The function keeps status `active`/`trialing`,
sets `cancel_at_period_end = true`, and **does not** revoke the licence.

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_solo_cancel_001",
    "type": "CANCELLATION",
    "app_user_id": "00000000-0000-0000-0000-000000000000",
    "product_id": "com.vinetrack.solo.yearly",
    "entitlement_ids": ["solo"],
    "period_type": "NORMAL",
    "environment": "SANDBOX",
    "purchased_at_ms": 1751328000000,
    "expiration_at_ms": 1814400000000
  }
}
```

Expected: subscription `active`, `cancel_at_period_end = true`, licence still `active`.

---

### 3.5 BILLING_ISSUE — past_due

Maps to status `past_due`. Licence is **not** revoked (grace period); access
decisions during dunning are made by the access RPC, not this webhook.

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_solo_billing_issue_001",
    "type": "BILLING_ISSUE",
    "app_user_id": "00000000-0000-0000-0000-000000000000",
    "product_id": "com.vinetrack.solo.yearly",
    "entitlement_ids": ["solo"],
    "period_type": "NORMAL",
    "environment": "SANDBOX",
    "purchased_at_ms": 1751328000000,
    "expiration_at_ms": 1782864000000
  }
}
```

Expected: subscription `past_due`, licence still `active`.

---

### 3.6 EXPIRATION — expired, licence revoked

Terminal "access ended" event. Maps to status `expired` and **revokes** the
user's active licence (`status = 'revoked'`, `revoked_at` set).

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_solo_expiration_001",
    "type": "EXPIRATION",
    "app_user_id": "00000000-0000-0000-0000-000000000000",
    "product_id": "com.vinetrack.solo.yearly",
    "entitlement_ids": ["solo"],
    "period_type": "NORMAL",
    "environment": "SANDBOX",
    "purchased_at_ms": 1751328000000,
    "expiration_at_ms": 1751328000000
  }
}
```

Expected: subscription `expired`, licence `revoked`.

---

### 3.7 TEST / unknown event — logged only

RevenueCat's "Send test event" button sends `type: "TEST"`. Any unrecognised
event type is logged to `vinetrack_billing_events` but causes **no** subscription
or licence change.

```json
{
  "api_version": "1.0",
  "event": {
    "id": "evt_test_001",
    "type": "TEST",
    "app_user_id": "00000000-0000-0000-0000-000000000000",
    "environment": "SANDBOX"
  }
}
```

Expected response: `{"status":"logged_informational",...}`.

> Other "logged only" outcomes you may see, by design:
> - `logged_no_user` — `app_user_id` isn't a valid Supabase UUID (e.g. `$RCAnonymousID:...`).
> - `logged_no_plan` — product/entitlement didn't match any mapping.
> - `logged_non_apple_plan` — mapping resolved to a non-Apple plan (Team/Enterprise are Stripe).

---

## 4. Verification SQL

Run in the Supabase SQL editor. Replace `:test_user` with the test
`auth.users.id` you used as `app_user_id`.

```sql
-- 4a. Every event landed in the append-only log (newest first).
select created_at, event_type, external_event_id, provider,
       payload->'event'->>'environment' as environment, subscription_id
from public.vinetrack_billing_events
where provider = 'revenuecat'
order by created_at desc
limit 25;

-- 4b. The subscription reflects the latest event.
select s.id, s.status, s.cancel_at_period_end, s.billing_provider,
       s.trial_start, s.trial_end, s.current_period_start, s.current_period_end,
       s.revenuecat_app_user_id, p.code as plan_code
from public.vinetrack_subscriptions s
join public.vinetrack_plans p on p.id = s.plan_id
where s.revenuecat_app_user_id = ':test_user'::text
order by s.created_at desc;

-- 4c. The user's licence state (active vs revoked).
select l.id, l.status, l.assigned_at, l.revoked_at, l.subscription_id
from public.vinetrack_user_licences l
join public.vinetrack_subscriptions s on s.id = l.subscription_id
where s.revenuecat_app_user_id = ':test_user'::text
order by l.created_at desc;

-- 4d. CONFIRM no invoice records were created for Apple/RevenueCat events.
--     Solo/legacy receipts stay with Apple — this MUST return 0 rows.
select count(*) as apple_invoice_rows
from public.vinetrack_invoice_records r
join public.vinetrack_subscriptions s on s.id = r.subscription_id
where s.billing_provider = 'apple';
```

You can also confirm the end-to-end result on device via the **VineTrack Access
Resolution** section in the Backend Diagnostic view (tap Refresh after running a
webhook test).

---

## 5. Idempotency test

The function logs the raw event first; the unique index on
`(provider, external_event_id)` is the idempotency guard.

```bash
# Run the SAME payload twice (note: identical event.id).
curl -s -X POST "$FN_URL" -H "Authorization: $WEBHOOK_SECRET" \
  -H "Content-Type: application/json" -d @solo_initial.json
# -> {"status":"processed",...}

curl -s -X POST "$FN_URL" -H "Authorization: $WEBHOOK_SECRET" \
  -H "Content-Type: application/json" -d @solo_initial.json
# -> {"status":"already_processed","eventId":"evt_solo_initial_001"}
```

Then confirm **no duplicate rows** were created:

```sql
-- Exactly one event row for that id.
select external_event_id, count(*)
from public.vinetrack_billing_events
where provider = 'revenuecat' and external_event_id = 'evt_solo_initial_001'
group by external_event_id;

-- Exactly one subscription + one active licence for the test user.
select
  (select count(*) from public.vinetrack_subscriptions
     where revenuecat_app_user_id = ':test_user'::text) as subs,
  (select count(*) from public.vinetrack_user_licences l
     join public.vinetrack_subscriptions s on s.id = l.subscription_id
     where s.revenuecat_app_user_id = ':test_user'::text and l.status = 'active') as active_licences;
```

Expected: second call returns `already_processed`; counts stay at 1.

---

## 6. Cleanup SQL

Removes **only** test rows for the supplied test user. Replace `:test_user`.
Run inside a transaction so you can review counts before committing.

```sql
begin;

-- Show what will be removed first.
select 'events' as kind, count(*) from public.vinetrack_billing_events
  where provider = 'revenuecat' and owner_user_id = ':test_user'::uuid
union all
select 'licences', count(*) from public.vinetrack_user_licences l
  join public.vinetrack_subscriptions s on s.id = l.subscription_id
  where s.revenuecat_app_user_id = ':test_user'::text
union all
select 'subscriptions', count(*) from public.vinetrack_subscriptions
  where revenuecat_app_user_id = ':test_user'::text;

-- Delete licences first (FK), then subscriptions, then the event log.
delete from public.vinetrack_user_licences l
using public.vinetrack_subscriptions s
where l.subscription_id = s.id
  and s.revenuecat_app_user_id = ':test_user'::text;

delete from public.vinetrack_subscriptions
where revenuecat_app_user_id = ':test_user'::text;

delete from public.vinetrack_billing_events
where provider = 'revenuecat'
  and owner_user_id = ':test_user'::uuid;

-- ⚠️ Review the row counts above. If correct:
-- commit;
-- Otherwise:
-- rollback;
```

> Only deletes rows tied to the test user's `revenuecat_app_user_id` /
> `owner_user_id`. It will **not** touch real billing rows for other users.
> Plans (`vinetrack_plans`) are catalogue data and are intentionally left intact.

---

## Notes / safety recap

- Draft-only; not in the numbered `sql/` stream, not enforced by the app.
- No invoice rows are ever created from RevenueCat events (Apple owns receipts).
- Keep `SUPABASE_SERVICE_ROLE_KEY` and `REVENUECAT_WEBHOOK_SECRET` out of source
  control and out of client builds.
- Do not connect a live RevenueCat project until real product/entitlement IDs
  replace the placeholders in `index.ts`.
