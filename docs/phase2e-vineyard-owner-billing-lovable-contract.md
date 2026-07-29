# Phase 2E — Vineyard Owner Billing: Lovable hand-off contract

Backend contract for the portal-only Billing page at `/account/billing`.
Apply `sql/152_vineyard_owner_billing_access.sql` and
`sql/153_stripe_invoice_history.sql`, deploy the three Edge Functions, and run
`sql/tests/153_vineyard_owner_billing_tests.sql` BEFORE building the portal page.

## 1. Owner role and ownership validation

- Exact stored role value: `vineyard_members.role = 'owner'` (lowercase).
- A user is billing-eligible for a vineyard only when: authenticated AND a
  `vineyard_members` row exists with `role = 'owner'` AND the vineyard is not
  soft-deleted. Membership revocation deletes the row, so access ends
  immediately.
- Membership role ≠ Stripe billing ownership. The money is anchored by
  `vinetrack_subscriptions.owner_user_id` (the "billing owner"). A vineyard can
  have several Owner-role members but only the billing owner can see invoices
  or open the Stripe Customer Portal. Everyone else with the Owner role gets
  the safe summary plus `billing_authority_code = "billing_managed_by_another_owner"`.
- Every RPC and Edge Function re-verifies ownership server-side per request.
  Never trust the vineyard id in the URL — the backend rejects vineyards the
  user does not own with `owner_required`.
- System Admins do NOT get customer Billing access unless they also hold an
  Owner membership. Admin billing stays in `/admin/access-entitlements`.

## 2. Multiple-vineyard behaviour

- `get_my_billing_vineyards()` returns ALL billing-eligible vineyards.
- 0 rows → hide the Billing nav item and block/redirect the route.
- 1 row → auto-select it.
- 2+ rows → show a vineyard selector; changing it must refetch summary,
  history, and licences and must not show stale data from the previous
  vineyard.

## 3. RPC signatures and return types

All RPCs use the authenticated user (no user-id parameters, ever).

### `get_my_billing_vineyards()` → rows

| column | type |
|---|---|
| vineyard_id | uuid |
| vineyard_name | text |
| role | text (`owner`) |
| has_stripe_customer | boolean |
| has_active_subscription | boolean |
| plan_code | text \| null |
| subscription_status | text \| null |
| can_manage_billing | boolean |

Zero rows for non-Owners (not an error).

### `get_my_vineyard_billing_summary(p_vineyard_id uuid)` → jsonb

Keys: `vineyard_id`, `vineyard_name`, `user_role`, `is_vineyard_owner`,
`can_manage_billing`, `can_view_invoices`, `billing_authority_code`
(`null | "billing_managed_by_another_owner" | "no_billing_relationship"`),
`billing_owner_user_id`, `billing_owner_display_name`, `effective_plan`,
`access_source` (`subscription | trial | manual_grant | <grant type> | none`),
`purchase_platform` (`web | ios | android | null`), `receipt_managed_by`
(`stripe | apple | google | null`), `subscription_id`, `subscription_status`,
`provider` (`stripe | apple | google | manual | null`), `product_id`
(safe plan code), `plan_code`, `current_period_start`, `current_period_end`,
`cancel_at_period_end`, `cancelled_at`, `expires_at`, `licence_limit`
(null when unlimited), `assigned_licences`, `available_licences`,
`is_unlimited`, `portal_access`, `can_use_ios_app`, `can_use_android_app`,
`has_stripe_customer`, `has_invoice_history`, `money_unit` (`"minor_units"`).

No Stripe customer IDs are ever returned.

### `get_my_vineyard_billing_history(p_vineyard_id uuid, p_limit int = 50, p_offset int = 0)` → rows

`record_id, record_type ('invoice'), provider, purchase_platform, product_id,
plan_code, description, invoice_id (Stripe id — needed for link requests),
invoice_number, invoice_status (draft|open|paid|void|uncollectible|refunded),
currency, subtotal, tax, total, amount_paid, amount_due, period_start,
period_end, created_at, paid_at, voided_at, refunded_at, subscription_status,
can_view_invoice, can_download_invoice, redacted_reference, total_count`

- **All money values are INTEGER MINOR UNITS (cents) in the row's `currency`.**
  Do not assume AUD; format from `currency`.
- Server-side pagination; `total_count` repeats on every row.
- Historical invoices remain after cancellation.
- Only callable by the billing owner; other Owners get
  `billing_managed_by_another_owner`.

### `get_my_vineyard_billing_licences(p_vineyard_id uuid)` → rows

`licence_id, user_display_name, user_email, vineyard_id, vineyard_name,
assigned_at, status ('active' | 'pending')`

Billing owner only. Use server counts from the summary for "3 of 5 licences
assigned"; never compute seats from browser-side user lists.

## 4. Edge Function contracts

Both require the user's Supabase JWT in `Authorization: Bearer <token>`
(invoke via `supabase.functions.invoke`).

### `create-stripe-customer-portal-session`

- Request: `POST { "vineyard_id": "<uuid>" }`
- Success: `200 { "url": "https://billing.stripe.com/..." }`
- Redirect immediately; never store the URL. Fresh session per click.
- Errors: `401 authentication_required`, `403 owner_required |
  billing_managed_by_another_owner`, `404 vineyard_not_found |
  no_billing_relationship | stripe_customer_not_found`.
- Return URL is server-side (`/account/billing`); client-supplied Stripe
  customer IDs are unsupported.

### `get-stripe-invoice-link`

- Request: `POST { "vineyard_id": "<uuid>", "invoice_id": "in_...", "action": "view" | "download" }`
- Success: `200 { "invoice_id": "in_...", "action": "view", "url": "https://..." }`
- Request links only on click; links are minted fresh and not persisted.
- Errors: `401 authentication_required`, `403 owner_required |
  billing_managed_by_another_owner | invoice_access_denied`,
  `404 vineyard_not_found | no_billing_relationship | invoice_not_found |
  invoice_link_unavailable`, `400 unsupported_action`.

## 5. Permission error codes → portal messages

| code | message |
|---|---|
| `authentication_required` | Please sign in to view billing. |
| `owner_required` | Only a Vineyard Owner can access billing for this vineyard. |
| `vineyard_not_found` | This vineyard could not be found. |
| `billing_access_denied` | You do not have permission to view this vineyard's billing information. |
| `billing_managed_by_another_owner` | Billing is managed by another authorised Vineyard Owner. |
| `no_billing_relationship` | No billing account is associated with this vineyard. |
| `stripe_customer_not_found` | No Stripe billing account is associated with this vineyard. |
| `invoice_not_found` | This invoice could not be found. |
| `invoice_access_denied` | You do not have permission to view this invoice. |

RPC errors arrive as the exception message (exact code string). Never show
raw SQL or Stripe errors.

## 6. Apple / Google / trial / grant states

- `receipt_managed_by = "apple"` → show the Apple App Store notice; no Stripe
  invoices, no Manage Billing. `purchase_platform = "ios"`.
- `receipt_managed_by = "google"` → Google Play notice. `purchase_platform = "android"`.
- `access_source = "trial"` → trial notice, no invoice actions.
- `access_source` = a grant type (provider `manual`) → grant notice, no
  invoice actions.
- `billing_authority_code = "no_billing_relationship"` → "No billing account
  is associated with this vineyard."

## 7. Seat usage

Use `licence_limit`, `assigned_licences`, `available_licences`,
`is_unlimited` from the summary. `is_unlimited = true` → "Unlimited licences"
(limit/available are null).

## 8. Query keys and invalidation

```
["account", "billing", "vineyards"]
["account", "billing", "summary", vineyardId]
["account", "billing", "history", vineyardId, limit, offset]
["account", "billing", "licences", vineyardId]
```

- Returning from the Stripe Customer Portal (page refocus on
  `/account/billing`): invalidate summary, history, licences, and the shared
  entitlement/access queries.
- Logout or account switch: clear ALL customer billing query data.

## 9. Security notes for the portal build

- Direct table reads of `vinetrack_invoice_records` are admin-only — customer
  data flows only through the RPCs above.
- The Stripe secret key exists only as a Supabase function secret; nothing
  Stripe-secret related belongs in frontend config.
- Hiding the nav item is NOT the security boundary — the backend rejects every
  unauthorized call; the route guard is UX only.

## 10. Backend deployment prerequisites (Rork/Jonathan side — for reference)

1. Apply `sql/152` then `sql/153` in the Supabase SQL editor; run
   `sql/tests/153_vineyard_owner_billing_tests.sql` (expects ALL PASSED, rolls back).
2. Set Supabase function secrets: `STRIPE_SECRET_KEY`,
   `STRIPE_WEBHOOK_SECRET`, `STRIPE_PORTAL_RETURN_URL`
   (e.g. `https://<portal-domain>/account/billing`).
3. Deploy: `supabase functions deploy stripe-webhook --no-verify-jwt`,
   `supabase functions deploy create-stripe-customer-portal-session`,
   `supabase functions deploy get-stripe-invoice-link`.
4. Stripe dashboard: enable the Customer Portal (Settings → Billing →
   Customer portal), add a webhook endpoint pointing at
   `https://<project-ref>.functions.supabase.co/stripe-webhook` subscribed to:
   `customer.created, customer.updated, customer.subscription.created,
   customer.subscription.updated, customer.subscription.deleted,
   invoice.created, invoice.finalized, invoice.paid, invoice.payment_failed,
   invoice.voided, invoice.marked_uncollectible, charge.refunded,
   credit_note.created` — and copy its signing secret into
   `STRIPE_WEBHOOK_SECRET`.

Populate `vinetrack_subscriptions.stripe_customer_id` /
`stripe_subscription_id` at checkout time (existing purchase flow) — the
webhook links invoices through those trusted records and never links by email.
