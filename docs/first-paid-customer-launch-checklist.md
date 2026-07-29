# VineTrack — First Paid Customer Launch Checklist (Phase 2D)

Operational reference for accepting, validating and supporting the first
genuine paid VineTrack subscriber. Covers the expected purchase lifecycle,
the launch checklist, the first-customer check procedure, failure/support
procedures and the emergency access procedure.

Feature-flag posture during this phase (unchanged):

- `use_shared_supabase_entitlement` cohort = **internal**
- RevenueCat client fallback = **enabled**

---

## 1. Production configuration (audited 2026-07-29)

| Item | Expected value | Source of truth |
| --- | --- | --- |
| iOS yearly product | `yearly_9999` ("Yearly Premium", ONE_YEAR, APPROVED) | ASC app 6761143377, group "VineTrack Pro"; SQL 137/138 |
| iOS monthly product | `monthly_999` — registered but **INACTIVE** (not launching monthly) | SQL 137/138 |
| Android yearly product | `vinetrack_solo_yearly` | Play Console; SQL 138 |
| Android monthly product | none offered | — |
| RevenueCat entitlement | `pro` (exactly; `premium`-only events go to review) | webhook + catalogue |
| Active catalogue rows | exactly 2 (ios `yearly_9999`, android `vinetrack_solo_yearly`, both plan `solo`, qty 1, production) | `billing_product_catalog` |
| Webhook destination | Supabase Edge Function `revenuecat-webhook` | RevenueCat dashboard |
| Webhook auth | `REVENUECAT_WEBHOOK_SECRET` function secret == RevenueCat Authorization header (fails closed when unset) | function secrets |
| iOS bundle id | `app.rork.nt0v48tayl7v8noxcfe74` | `project.pbxproj` |
| Android package | `com.rork.vinetrack` | `app/build.gradle.kts` |
| App User ID strategy | Supabase `auth.users.id` UUID on both platforms | `SubscriptionService.swift` / `RevenueCatManager.kt` |

Sandbox handling: sandbox events are stored (`ignored`) and **never** grant
production access; the resolver also excludes `environment = 'sandbox'`.

Identity safeguards already enforced in code:

- Purchase/restore is **blocked while RevenueCat is anonymous** on both
  platforms (`ensureIdentifiedForTransaction()` / `ensureRevenueCatIdentified()`).
- Logout calls `Purchases.logOut()`; switching users re-identifies and clears
  the previous user's cached verification snapshot.
- Webhook resolves users only via a Supabase UUID in
  `app_user_id` / `original_app_user_id` / aliases — never by email; no match
  → `needs_review`. Ownership conflicts → `needs_review` (never silently
  reassociated); only a RevenueCat `TRANSFER` event moves ownership.
- Duplicate deliveries hit the `(provider, provider_event_id)` unique guard;
  out-of-order events older than `last_provider_event_at` are ignored.

---

## 2. Expected purchase lifecycle

### Apple

1. User signs into VineTrack (Supabase auth).
2. App identifies RevenueCat: `Purchases.logIn(<auth user UUID>)`.
3. User purchases `yearly_9999` through Apple.
4. RevenueCat records the transaction against the Supabase UUID.
5. RevenueCat webhook → Supabase Edge Function `revenuecat-webhook`.
6. Event validated (secret, entitlement `pro`, catalogue, environment) and
   recorded in `billing_provider_events`.
7. `vinetrack_subscriptions` + `vinetrack_user_licences` upserted.
8. `get_my_vinetrack_access()` grants (`app_store_subscription`).
9. iOS unlocks instantly via the RevenueCat fallback, then confirms the
   server within ~17 s (bounded 0/2/5/10 s post-purchase poll).
10. Portal and Android recognise the same access on next resolver call.

### Google Play

Same flow with `vinetrack_solo_yearly`, `PLAY_STORE` → provider `google`,
platform `android`.

### Where each stage can fail and what detects it

| Stage | Failure | Detected by |
| --- | --- | --- |
| 2 | anonymous RevenueCat ID | purchase blocked in-app; webhook `unresolved_app_user_id` → review + alert |
| 5 | webhook not delivered | RevenueCat delivery log; `admin_store_billing_monitor()` stuck deliveries |
| 6 | unknown/inactive product | `needs_review` (`unknown_product`) + alert |
| 6 | entitlement mismatch (`premium` w/o `pro`) | `needs_review` + alert |
| 6 | sandbox event | `ignored` (by design; no access) |
| 7 | ownership conflict | `needs_review` (`ownership_conflict`) + critical alert |
| 8 | resolver denies despite valid row | `admin_validate_user_store_entitlement()` → `failed` |
| 9–10 | client cache stale | pull-to-refresh / relaunch; bounded post-purchase poll |

---

## 3. Before accepting purchases

- [ ] Store products approved and available: ASC `yearly_9999` APPROVED;
      Play `vinetrack_solo_yearly` active.
- [ ] RevenueCat offering: current offering exposes exactly the launch
      products; both attached to entitlement `pro` (dashboard check).
- [ ] Webhook live: RevenueCat dashboard → send TEST event → function logs
      show `-> ignored (test_event)`.
- [ ] Webhook secret set: `REVENUECAT_WEBHOOK_SECRET` function secret matches
      the dashboard Authorization header.
- [ ] Catalogue mappings correct: exactly 2 active rows
      (`select * from billing_product_catalog where is_active` → SQL 138
      verification query).
- [ ] SQL 150 applied; `sql/tests/150_first_customer_diagnostics_tests.sql`
      passes (ALL PASSED, rolled back).
- [ ] Billing monitor clear: `admin_store_billing_monitor()` shows 0 open
      alerts / review items (or all known + acknowledged).
- [ ] Support-access workflow tested (see §7; T9/T10 in the SQL 150 suite).
- [ ] Restore-purchase flow tested on a second device.
- [ ] Privacy policy + subscription terms links working in both apps.
- [ ] Account deletion and cancellation guidance reachable in-app.

## 4. At first purchase

1. Confirm store purchase (ASC / Play order).
2. Confirm RevenueCat customer: App User ID is the Supabase UUID,
   entitlement `pro` active.
3. Confirm webhook event: `billing_provider_events` row `processed`.
4. Confirm Supabase subscription: `vinetrack_subscriptions` row active with
   the correct product/provider/period.
5. Confirm resolver: run
   `select public.admin_validate_user_store_entitlement('<user uuid>');`
   → `overall_status = healthy`.
6. Confirm portal display: Access & Entitlements shows Apple App Store /
   Google Play, correct product, status, expiry; Available Platforms =
   Portal, iOS, Android.
7. Confirm second-platform login (Apple buyer signs into Android, or vice
   versa) — no second purchase demanded.
8. Confirm Billing Health is clear (no new alerts/review items).

## 5. Within 24 hours

- [ ] No delayed or duplicate webhook issues (`open_review_count = 0`;
      duplicates return `already_processed`).
- [ ] Subscription still `active`; `current_period_end` correct.
- [ ] Customer has not reported access loss on any platform.
- [ ] Re-run the diagnostic RPC — still `healthy`.
- [ ] Capture anonymised validation notes (timings, any anomalies).

## 6. Before first renewal

- [ ] RENEWAL webhook handling verified (sandbox accelerated renewal or the
      real first renewal).
- [ ] `current_period_end` advanced on the SAME subscription row.
- [ ] No duplicate subscription row
      (`select count(*) from vinetrack_subscriptions where owner_user_id = …
      and billing_provider in ('apple','google') and deleted_at is null` = 1).
- [ ] Access remained active throughout.

---

## 7. Failure and support procedures

### Purchase succeeds but access is denied

Run `admin_validate_user_store_entitlement(<user>)` first — it walks the
whole chain. Then check in order:

1. RevenueCat customer identity (App User ID = Supabase UUID, not `$RCAnonymousID:…`).
2. Entitlement `pro` active in the RevenueCat dashboard.
3. Webhook delivery (RevenueCat delivery log; retry from dashboard if needed).
4. `billing_provider_events` processing status; re-drive retryable rows via
   `admin_retry_billing_delivery` (idempotent).
5. Catalogue mapping active for the exact product id.
6. User resolution (`unresolved_users` in Billing Review → `link_user`).
7. Ownership conflict (Billing Review → resolve with reason; never delete).
8. Resolver output (`admin_user_access_detail`).
9. Mobile cache: relaunch / pull-to-refresh; the post-purchase poll retries
   on next foreground.

### Purchase not found after reinstall

Check: signed-in Supabase user → RevenueCat login identity → tap Restore
Purchases (blocked until identified — by design) → correct store account on
the device → subscription environment (sandbox never grants) → ownership
linkage in `vinetrack_subscriptions`.

### Wrong account receives access

Immediately: preserve all billing evidence (never delete the provider
event); use the ownership-conflict review item; resolve through Billing
Review with actor + mandatory reason; ownership moves only via a validated
TRANSFER or an audited admin action.

### Store cancellation

Access normally remains active until the paid period ends — cancellation is
**not** immediate expiry. The portal must display
"Active — cancels at period end" (`cancel_at_period_end = true`,
status stays `active`). EXPIRATION is the terminal event that removes access.

### Refund or revocation

RevenueCat sends CANCELLATION with a Play `cancel_reason` or an EXPIRATION;
access ends when the resolver sees the terminal state. Confirm the specific
event in `billing_provider_events` and the resulting subscription status —
do not manually expire the row unless the provider event confirms revocation.

---

## 8. Emergency access procedure (automation failed, payment confirmed)

Use the existing `support_access` grant — never a permanent Internal
Unlimited grant.

1. Verify payment in ASC / Play Console / RevenueCat.
2. Create the grant (expiry is MANDATORY for `support_access`; recommended
   default **72 hours**, not hard-coded):

   ```sql
   select public.admin_create_billing_grant(
     '<user uuid>', 'support_access',
     'Payment confirmed (ASC order …) — webhook automation failed; billing review item <id> open',
     null, now() + interval '72 hours', null);
   ```

3. The resolver recalculates immediately; the customer regains access on all
   platforms.
4. Fix the underlying billing issue through Billing Review.
5. Once the store subscription row grants correctly, revoke the grant:

   ```sql
   select public.admin_revoke_billing_grant('<grant id>',
     'Billing issue resolved — store subscription now granting');
   ```

Both actions require a non-empty reason and are audit-logged. Verified by
tests T9/T10 in `sql/tests/150_first_customer_diagnostics_tests.sql`.

---

## 9. Manual store-console verifications (cannot be automated from Rork)

These must be performed in the consoles (no dashboard API access from this
environment):

- RevenueCat dashboard: current offering contents, both products attached to
  entitlement `pro`, webhook URL + Authorization header value.
- ASC: sandbox/TestFlight purchase, accelerated renewal, cancel-at-period-end,
  billing grace, refund; restore on a second Apple device.
- Play Console: licence-tester purchase in an internal/closed track, renewal,
  grace/account-hold, refund; resync on a second Android device. If Play
  production access is not yet granted, complete everything possible with
  licence testers and record the gap here.
