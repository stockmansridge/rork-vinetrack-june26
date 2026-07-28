# Phase 2B Closeout — First-Customer Launch Runbook

Status: Phase 2B closeout (2026-07-28). Controlled Apple and Google purchase
flows are treated as **provisionally successful**. No paying customers exist;
no historical backfill is required or planned.

## 1. Verified production catalogue

Only two products are (post SQL 138) active in `billing_product_catalog`:

| Platform | Product ID              | Plan | Entitlement | Env        | Qty |
|----------|-------------------------|------|-------------|------------|-----|
| iOS      | `yearly_9999`           | solo | pro         | production | 1   |
| Android  | `vinetrack_solo_yearly` | solo | pro         | production | 1   |

Kept **inactive** (fail-closed → webhook records `needs_review`, grants nothing):

- `monthly_999` — real ASC product; activate only if VineTrack intentionally
  launches a monthly plan (verify plan mapping first — `legacy_monthly` is
  currently the only monthly plan code).
- `REAL_ID_FROM_RC` — accidental row from a mis-run SQL-editor rename (the
  literal example placeholder was pasted). Not a real product; audit reference only.
- `com.vinetrack.solo.yearly`, `com.vinetrack.legacy.monthly`,
  `com.vinetrack.legacy.yearly` — SQL 134 placeholders.

## 2. First-customer flow (production)

1. User creates or signs into VineTrack (iOS or Android).
2. Supabase Auth establishes the user UUID.
3. The app calls `Purchases.logIn(<auth.users.id>)` — RevenueCat App User ID
   **is** the Supabase UUID. Purchase and Restore Purchases are blocked while
   RevenueCat is anonymous.
4. User purchases yearly Solo (`yearly_9999` on iOS / `vinetrack_solo_yearly`
   on Android).
5. RevenueCat grants entitlement `pro` immediately → the client fallback gate
   unlocks the app with no waiting.
6. RevenueCat delivers the webhook → the edge function authenticates
   (shared secret, constant-time), records the event idempotently
   (`billing_provider_events`, UNIQUE on provider+event id), maps the product
   via the catalogue, and upserts ONE verified row in
   `vinetrack_subscriptions` + an active user licence.
7. `get_my_vinetrack_access()` returns `has_access = true`,
   `reason_code = 'app_store_subscription'`, correct `purchase_platform`.
8. The same account now works on **iOS, Android and the portal** — no second
   purchase, Restore Purchases resolves the same canonical user, and duplicate
   rows are structurally impossible (UNIQUE on provider + external
   subscription id).

Fail-safes: sandbox events never grant production access; unknown/inactive
products, unresolved users, entitlement mismatches and ownership conflicts all
finalise as `needs_review` with **no access granted**; a different account
cannot silently claim the same store transaction (only a provider `TRANSFER`
event moves ownership, revoking the old licence).

## 3. Rollout controls (unchanged)

- `use_shared_supabase_entitlement` cohort = **internal** (do not move to
  beta/all until real-purchase monitoring is clean).
- RevenueCat client fallback = **enabled** (first customers get instant access
  while Supabase synchronises).

## 4. Monitoring & alerts (SQL 139)

- `admin_store_subscription_diagnostics(limit)` — per-subscription view with
  product ID, purchase platform, provider, plan, status, period/grace end,
  cancel-at-period-end, last provider event, last webhook received, last
  verified, review/mismatch status. External ids redacted.
- `admin_store_billing_monitor()` — one-call JSON health report: events
  needing review, failed events, unknown products, unresolved users, ownership
  conflicts, RevenueCat-active-but-Supabase-missing, stuck deliveries,
  subscriptions expiring within 7 days, recent status changes, open alerts.
- `admin_billing_alerts()` / `admin_acknowledge_billing_alert(id)` — alert
  inbox. A trigger fires alerts ONLY on `needs_review` / `failed` /
  unknown-product / ownership-conflict events (never on successful renewals);
  the listing call lazily adds `sync_window_exceeded` alerts (grant processed
  15+ min ago with no active Supabase subscription; deliveries stuck in
  `received`). All System-Admin-gated; no receipts, tokens or secrets.

## 5. Launch checklist

- [ ] Apple `yearly_9999` active in catalogue, attached to `pro` (SQL 138)
- [ ] Google `vinetrack_solo_yearly` active in catalogue, attached to `pro` (SQL 138)
- [ ] RevenueCat current offering contains exactly these products, entitlement `pro` (dashboard check)
- [ ] Webhook deployed at `/functions/v1/revenuecat-webhook`, shared-secret auth verified (401 on bad secret)
- [ ] Duplicate delivery idempotent (`already_processed`, UNIQUE guard)
- [ ] Catalogue production-only: exactly 2 active rows, ambiguity check returns zero rows
- [ ] Anonymous purchase blocked in both apps (purchase/restore disabled until `Purchases.logIn(UUID)`)
- [ ] Shared resolver live (`get_my_vinetrack_access()` returns `app_store_subscription` for store rows)
- [ ] Client RevenueCat fallback enabled (instant access after purchase)
- [ ] Portal recognises store purchases (same resolver, `portal_access = true`)
- [ ] Audit logging enabled (`store_subscription_*` events in `vinetrack_entitlement_audit`)
- [ ] Admin diagnostics + monitor + alerts live (SQL 139)
- [ ] No backfill required (no existing paying customers)
- [ ] Rollback documented (below)

## 6. Rollback

- **Catalogue**: run the rollback block at the end of SQL 138 — sets both
  verified rows `is_active = false`. New purchases then finalise as
  `needs_review` (no new access); existing verified subscription rows keep
  granting until their own lifecycle ends; the client fallback still covers
  paying users.
- **Monitoring/alerts**: rollback block in the SQL 139 header (drop trigger,
  functions, table; re-run section B of SQL 135 for the previous diagnostics).
- **Behavioural**: disable `use_shared_supabase_entitlement` — clients revert
  to the RevenueCat-only gate.

## 7. Remaining manual dashboard checks (before first real sale)

1. RevenueCat → Product catalog: `yearly_9999` and `vinetrack_solo_yearly`
   both attached to entitlement **`pro`** (exact string) and present in the
   **current** offering's packages.
2. RevenueCat → Webhooks: single webhook, URL correct, Authorization value
   set, environment Both, All apps, All events.
3. App Store Connect: `yearly_9999` state stays APPROVED / Ready for Sale in
   the "VineTrack Pro" group; paid-apps agreement + banking active.
4. Google Play Console: `vinetrack_solo_yearly` base plan active; licence
   testers configured.
