# Phase 2B — Verified store-purchase synchronisation

Status: implemented, migrations NOT yet executed, Edge Function NOT yet
deployed, catalogue mappings NOT yet activated (pending live RevenueCat
audit). Feature flag stays `use_shared_supabase_entitlement` / cohort
`internal`.

## Authoritative architecture

Apple / Google purchase
→ RevenueCat verifies the store transaction
→ RevenueCat webhook (Authorization secret, constant-time check)
→ `supabase/functions/revenuecat-webhook` validates + normalises
→ `billing_provider_events` (idempotent inbox, SQL 133)
→ `billing_product_catalog` maps product → plan (SQL 134)
→ `vinetrack_subscriptions` verified row (provider apple/google)
→ `get_my_vinetrack_access()` (SQL 135) resolves access
→ iOS, Android and portal receive the SAME entitlement.

Clients can never write subscription state: all billing tables have no
client INSERT/UPDATE/DELETE policies; only the service-role webhook and
backfill write.

## Resolver precedence (unchanged order, new sources validated)

1. Internal Unlimited grant
2. Enterprise
3. Team / assigned licence
4. Legacy / Solo — including VERIFIED app-store subscriptions
   (`reason_code = app_store_subscription`, cross-platform access)
5. No Supabase access → client RevenueCat `pro` fallback → legacy 3-month
   trial fallback → paywall

New validity rules (SQL 135): sandbox rows never grant; billing-issue
grace (`grace_period_end`) keeps `past_due`/elapsed-period rows valid until
grace end; everything checked against database `now()`.

## Response contract (additive)

SQL 135 appends to the SQL 132 row (first 30 columns unchanged):

- `purchase_platform` — 'ios' | 'android' | 'web' | null (where purchased,
  NOT where usable — an Apple purchase returns `can_use_android_app = true`)
- `cancel_at_period_end` — boolean
- `grace_period_end` — timestamptz

## Entitlement identifier findings (pro vs premium)

- iOS `SubscriptionService.entitlementIdentifier = "pro"` — correct production use.
- Android `RevenueCatManager` entitlement `pro` — correct production use.
- Draft webhook `ENTITLEMENT_TO_PLAN["premium"]` — broken mismatch, REMOVED.
  The rewritten webhook requires `pro`; events carrying `premium` without
  `pro` are classified `needs_review` (`entitlement_mismatch`) with a
  `store_subscription_sync_mismatch` audit row, and never grant access.
- Draft placeholders `legacy`/`solo` entitlement ids — legacy/test-only, removed;
  mapping now lives ONLY in `billing_product_catalog`.

## RevenueCat dashboard audit (user actions — no API access from Rork)

The sandbox has no RevenueCat secret key, so the live dashboard items must
be confirmed in the dashboard (or provide a secret API key and Rork can run
them via the REST API):

1. Entitlement identifier is exactly `pro`; note any `premium` remnants.
2. Every active Apple + Google product is attached to `pro`; record the real
   product ids, packages and plan each represents.
3. Current/default offering, its packages, and per-platform product mapping.
4. Webhook configuration: URL → the deployed `revenuecat-webhook` function,
   Authorization header = `REVENUECAT_WEBHOOK_SECRET`, production events
   enabled, delivery history.
5. App Store shared secret / Play service-account credentials present.
6. Jonathan's customer record looked up by his Supabase user id (aliases,
   `pro` state, platform, linked transaction).
7. Targeting rules / Experiments / offering overrides / promotional
   entitlements for any relevant cohort.

Then activate the catalogue: update `billing_product_catalog` rows with the
REAL product ids and set `is_active = true` (SQL editor, service role).

## Deployment order (each step reviewable / reversible)

1. Apply sql/133 → sql/134 → sql/135 (SQL editor).
2. Run `sql/tests/135_store_entitlement_tests.sql` (transaction-rolled-back).
3. Set the `REVENUECAT_WEBHOOK_SECRET` function secret; deploy
   `revenuecat-webhook` (see docs/deploy-edge-functions.md).
4. Configure the RevenueCat webhook (URL + Authorization header) for
   production events.
5. Activate real product mappings in `billing_product_catalog`.
6. Exercise the fixtures in `supabase/functions/revenuecat-webhook/README-test.md`
   with a controlled test user.
7. Backfill dry-run: `scripts/revenuecat-backfill-dryrun.ts` (needs
   REVENUECAT_SECRET_API_KEY + REVENUECAT_PROJECT_ID); review the report;
   only then `--execute`.

## Rollback

- Webhook: disable the webhook in the RevenueCat dashboard (events stop; the
  client RevenueCat fallback keeps every store customer unlocked).
- Resolver: re-run section E of sql/132 (drop + recreate) — appended columns
  disappear, clients ignore their absence. Or flip the feature flag off for
  the iOS gate.
- Backfill: rows carry `last_provider_event = 'BACKFILL'` — set `deleted_at`
  on those rows to fully revert; RevenueCat fallback protects users.
- Catalogue: set `is_active = false` to stop NEW access from a product
  without touching history.

## Client behaviour (fallback preserved)

- Supabase grants → access (paywall suppressed).
- Supabase denies / webhook not yet processed → RevenueCat `pro` grants
  fallback access, records a throttled mismatch diagnostic, no paywall.
- Post-purchase / Restore: bounded webhook sync — immediate → 2s → 5s → 10s
  (`StorePurchaseSyncPlan` on iOS, `scheduleStoreEntitlementSync()` on
  Android), then the RevenueCat fallback stands and regular refreshes retry.
- Offline: unchanged Phase 2A cache (per-user, 30-day grace, capped at the
  later of period end and grace end).

## Trials

- Store introductory trials arrive via the webhook as `status = 'trialing'`
  with `trial_end` — a verified store subscription, distinct from the
  client-computed 3-month account window (unchanged this phase).
- Server-side migration of the account trial is Phase 2C scope.

## Open items for Phase 2C

- Run the live RevenueCat dashboard audit + activate real product mappings.
- Deploy webhook + execute backfill after dry-run review.
- Stripe/portal billing webhook, licence quantity purchasing.
- System Admin Access & Entitlements page (admin RPC
  `admin_store_subscription_diagnostics()` already provides the data).
- Server-side account-trial migration; eventual removal of client fallback.
