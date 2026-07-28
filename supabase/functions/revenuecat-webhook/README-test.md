# revenuecat-webhook — test fixtures (Phase 2B)

## Deploying (IMPORTANT: `--no-verify-jwt`)

RevenueCat sends a shared-secret `Authorization` header, NOT a Supabase JWT.
The function MUST be deployed with gateway JWT verification off, otherwise
the gateway rejects every delivery with 401 before the function's own
constant-time secret check runs:

```bash
# 1. Set the secret ONCE (never commit it; also paste the same value into
#    RevenueCat dashboard -> Integrations -> Webhooks -> Authorization header):
supabase secrets set REVENUECAT_WEBHOOK_SECRET="<random long secret>" --project-ref tbafuqwruefgkbyxrxyb

# 2. Deploy (scripts/deploy-edge-functions.sh|.ps1 already do this):
supabase functions deploy revenuecat-webhook --project-ref tbafuqwruefgkbyxrxyb --no-verify-jwt
```

The function fails closed: until the secret is set, every request returns
500 "Webhook secret not configured" and nothing is stored.

## Local controlled tests (no database, no secrets)

The auth / idempotency / unknown-product / sanitisation behaviour is covered
by a local harness that runs this exact function against a mock Supabase:

```bash
deno run --allow-net --allow-env --allow-run scripts/revenuecat-webhook-localtest/run-tests.ts
```

## Live test fixtures

Representative payloads for exercising the webhook without real receipts or
customer data. Replace `<SECRET>` with the value of the
`REVENUECAT_WEBHOOK_SECRET` function secret, `<FN_URL>` with the deployed
function URL, and `<USER_UUID>` with a controlled test Supabase user id.

> Prerequisites: sql/133 + sql/134 applied, and an ACTIVE
> `billing_product_catalog` row for the product id used below (the seeded
> placeholders are inactive by design — activate a test mapping first, e.g.
> `update billing_product_catalog set is_active = true where external_product_id = 'com.vinetrack.solo.yearly';`).

Every request returns JSON with the processing result. Re-sending the same
`event.id` returns `{"status":"already_processed"}` — the idempotency guard.
Check `billing_provider_events.processing_status` after each call.

## 1. Auth rejection (expect 401)

```bash
curl -s -X POST <FN_URL> -H "Authorization: wrong" -H "Content-Type: application/json" -d '{"event":{"id":"evt-auth","type":"TEST"}}'
```

## 2. Initial purchase (expect processed; subscription + licence created)

```bash
curl -s -X POST <FN_URL> -H "Authorization: <SECRET>" -H "Content-Type: application/json" -d '{
  "api_version": "1.0",
  "event": {
    "id": "evt-t1-initial",
    "type": "INITIAL_PURCHASE",
    "environment": "PRODUCTION",
    "store": "APP_STORE",
    "app_user_id": "<USER_UUID>",
    "product_id": "com.vinetrack.solo.yearly",
    "entitlement_ids": ["pro"],
    "period_type": "TRIAL",
    "purchased_at_ms": 1785000000000,
    "expiration_at_ms": 1792900000000,
    "event_timestamp_ms": 1785000001000,
    "transaction_id": "test-txn-1",
    "original_transaction_id": "test-orig-txn-1"
  }
}'
```

## 3. Duplicate delivery (expect already_processed)

Re-send fixture 2 unchanged.

## 4. Renewal (expect processed; SAME row updated, period extended)

Same as 2 with `id:"evt-t2-renewal"`, `type:"RENEWAL"`, `period_type:"NORMAL"`,
later `purchased_at_ms`/`expiration_at_ms`/`event_timestamp_ms`.

## 5. Cancellation (expect processed; status stays active, cancel_at_period_end=true)

Same ids with `id:"evt-t3-cancel"`, `type:"CANCELLATION"`, later `event_timestamp_ms`.

## 6. Billing issue with grace (expect processed; past_due + grace_period_end)

`type:"BILLING_ISSUE"`, add `"grace_period_expiration_at_ms": 1794000000000`.

## 7. Expiration (expect processed; expired, licence revoked, resolver denies)

`type:"EXPIRATION"`, later `event_timestamp_ms`.

## 8. Out-of-order (expect ignored / stale_event)

Re-send fixture 4 (RENEWAL) with a NEW event id but an `event_timestamp_ms`
EARLIER than fixture 7's — must not resurrect the expired subscription.

## 9. premium-without-pro mismatch (expect needs_review, no access)

Fixture 2 with `id:"evt-t5-premium"`, `entitlement_ids:["premium"]`.

## 10. Unknown product (expect needs_review, no access)

Fixture 2 with `id:"evt-t6-unknown"`, `product_id:"com.vinetrack.mystery"`.

## 11. Anonymous app user id (expect needs_review, attaches to nobody)

Fixture 2 with `id:"evt-t7-anon"`, `app_user_id:"$RCAnonymousID:abc123"`, no aliases.

## 12. Sandbox (expect ignored; stored but never grants production access)

Fixture 2 with `id:"evt-t8-sandbox"`, `environment:"SANDBOX"`.

## 13. Google Play purchase (expect processed; provider=google, platform=android)

Fixture 2 with `id:"evt-t9-play"`, `store:"PLAY_STORE"`,
`product_id:"vinetrack_solo_yearly"` (activate its catalogue row first).
Then verify the SAME user's resolver output grants `can_use_ios_app = true`.

## 14. Transfer (expect processed when unambiguous; needs_review otherwise)

```json
{"event":{"id":"evt-t10-transfer","type":"TRANSFER","environment":"PRODUCTION","store":"APP_STORE",
  "transferred_from":["<OLD_USER_UUID>"],"transferred_to":["<NEW_USER_UUID>"],
  "event_timestamp_ms":1793000000000}}
```

## Verification queries

```sql
select provider_event_id, event_type, processing_status, processing_error_code
from billing_provider_events order by received_at desc limit 20;

select status, cancel_at_period_end, grace_period_end, external_subscription_id,
       last_provider_event, environment
from vinetrack_subscriptions where owner_user_id = '<USER_UUID>';

select * from admin_store_subscription_diagnostics(20);
```
