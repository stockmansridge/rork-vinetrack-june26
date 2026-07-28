# VineTrack Access & Subscription System — Phase 1 Audit

Date: 2026-07-28 · Scope: discovery only. **No app code changed, no migrations written or executed, no production behaviour altered.**

Target rule for the future system: *one VineTrack account, one shared entitlement, access on iOS, Android and the Portal according to the plan, regardless of purchase channel (Apple / Google Play / Portal).*

---

## 1. Shared Supabase project — CONFIRMED

| Question | Answer |
|---|---|
| iOS Supabase URL | `https://tbafuqwruefgkbyxrxyb.supabase.co` — `ios/VineTrack/App/AppConfig.swift` (`supabaseURL`, env `SUPABASE_URL`/`EXPO_PUBLIC_SUPABASE_URL` with this hardcoded default) |
| Android Supabase URL | Same project — `android-vinetrack/.../data/AppConfig.kt` (`DEFAULT_SUPABASE_URL` and `FALLBACK_SUPABASE_URL` both `tbafuqwruefgkbyxrxyb`) |
| Dev/staging/fallback projects | None in either app. The only second project reference is the **one-off V1→V2 migration tooling** (`migration/`, env `V1_SUPABASE_URL`) — not used at runtime |
| Portal same `auth.users`? | Yes by design — the Portal targets the same project (see `docs/` runbooks referencing `tbafuqwruefgkbyxrxyb`; portal recovery routes were added to this project's auth redirect allowlist) |
| Same user can log into both apps? | Yes — both use the same GoTrue endpoint; iOS via supabase-swift SDK, Android via direct Ktor calls to `/auth/v1/*`. Sessions are independent per device |

## 2. Authentication — iOS and Android

The four concerns are **already separate objects** in the system (good foundation):
- **Authentication** = `auth.users` + `public.profiles`
- **Membership** = `public.vineyard_members`
- **Role** = `vineyard_members.role` (`owner|manager|supervisor|operator` — no `viewer` exists) + `system_admins`
- **Entitlement** = RevenueCat `pro` entitlement and/or `vinetrack_subscriptions` via `get_my_vinetrack_access()`

### iOS (`ios/VineTrack/`)
- Login: `App/NewBackendLoginView.swift` (email/password, Sign in with Apple via `AppleSignInHelper` + `signInWithIdToken`), service `App/NewBackendAuthService.swift` over `Backend/Auth/SupabaseAuthRepository.swift`.
- Sign-up: `auth.signUp` + best-effort profile upsert. Email confirmation: if no session returned, user is told "Check your email to confirm your account, then sign in." No in-app OTP for signup.
- Password reset: PIN-based (`verifyOTP(type: .recovery)` + `update(user:)`), then sign-out. No deep links.
- Session persistence: supabase-swift default storage (Keychain). Biometric lock stores only a flag + email (`BiometricKeychain`, service `com.vinetrack.biometric`), never a password.
- Token refresh/restore: `SupabaseAuthRepository.restoreSession()` — cached session kept on network errors (offline-first); signed out only on genuine 401/403 auth rejection.
- Startup gate order (`App/NewBackendRootView.swift`): splash → biometric → login → onboarding → vineyard load → **no-vineyard onboarding** (`WaitingForInviteView`) → disclaimer → **subscription gate** → main tabs.
- No vineyard membership → invite/create onboarding (never the paywall). No subscription → non-dismissable `SubscriptionPaywallView` (with sign-out), or `OfflineAccessUnavailableView` when offline.

### Android (`android-vinetrack/`)
- No Supabase SDK — direct Ktor (`data/SupabaseClient.kt`). Auth service `data/auth/AuthRepository.kt`; UI `ui/auth/LoginScreen.kt` (email/password + Google via Credential Manager id-token flow).
- Sign-up, PIN password reset and email-confirmation handling mirror iOS.
- Session persistence: **plaintext SharedPreferences** `vinetrack_session` (keys `access_token`, `refresh_token`, `user_id`, `user_email`, `user_created_at`, vineyard selection keys) — not encrypted.
- Token refresh: central HttpSend interceptor — proactive refresh 60 s before expiry, single-flight 401 retry, transient network failures keep the session; foreground revalidation with 300 s skew (`AppViewModel.onAppForegrounded()`).
- Route order (`AppRoute` in `ui/AppViewModel.kt`, rendered by `RootScreen.kt`): `Restoring → Login → BiometricLock → VineyardLoading → NoVineyards | Paywall → Main`.
- Key ordering fact (both platforms): **the paywall is only evaluated after vineyard membership** — a user with no vineyard never sees a paywall.

## 3. Where access decisions are made (the core finding)

| Platform | Location | Access source | Server verified | Portal aware | Manual grant aware |
|---|---|---|---|---|---|
| iOS | `Backend/Subscription/SubscriptionService.swift` `hasAccess` — **the enforced global gate** (`NewBackendRootView`) | RevenueCat `pro` entitlement + client-computed 3-month window from `auth.users.created_at` + 30-day offline grace snapshot | RevenueCat only | **No** | **No** |
| iOS | `Backend/Subscription/VineTrackAccessResolver.swift` → RPC `get_my_vinetrack_access()` | Supabase entitlement (Stripe/manual/Apple aware) | Yes (SECURITY DEFINER) | Yes | Yes — **but explicitly "ADDITIVE / NOT YET ENFORCED"; only called from `BackendDiagnosticView`** |
| Android | `ui/AppViewModel.kt` `resolveVineTrackAccess()` — the enforced gate | **A.** RPC `get_my_vinetrack_access()` → **B.** RevenueCat `pro` → **C.** 3-month window → **D.** 30-day offline grace | A is server-verified | **Yes** | **Yes** |

Consequences:
- **Android already honours portal (Stripe) subscriptions, manual Billing Grants, and Apple purchases recorded in Supabase.** iOS honours **only RevenueCat** — this is the single biggest cross-platform gap.
- Neither app writes purchases into Supabase. The only server-side sync path is the **draft** Edge Function `supabase/functions/revenuecat-webhook/` — not production-wired (placeholder product maps, entitlement guessed as `"premium"` while both apps use `"pro"`).
- Access is all-or-nothing at the root route on both platforms; no per-feature paywalls. The only in-app role gates are System Admin surfaces.

## 4. Apple purchase handling (iOS)

- All Apple billing goes through **RevenueCat**; StoreKit is never used directly. Entitlement id: **`pro`** (`SubscriptionService.entitlementIdentifier`). Products/offering live in the RevenueCat dashboard (legacy $9.99/mo, $99/yr, both 3-month intro trial; comment forbids adding Basic $5/$30 to the default offering). Package→plan mapping in `PaywallView` is a string heuristic (`contains("year"/"month")`).
- **Customer ID strategy: correct for the future system** — `Purchases.logIn(supabaseUserId.uuidString)`; the RevenueCat appUserID **is the Supabase `auth.users.id`** on both platforms; `logOut()` on sign-out. Purchases are therefore already permanently linked to the Supabase user, not to an anonymous RC id or an email.
- Renewal/cancel/expiry: delegated to RevenueCat (`customerInfoStream`, `willRenew`, `expirationDate`); no Apple grace-period-specific handling.
- Purchases are **not written to Supabase** from the app; no server receipt verification; webhook exists only as the draft above.

## 5. Google purchase handling (Android)

- Package `com.rork.vinetrack` (versionName 0.0.6). **No Google Play Billing library** — billing is exclusively RevenueCat (`com.revenuecat.purchases:purchases:10.13.0`); acknowledgement handled by the RC SDK.
- Entitlement id **`pro`** (shared); appUserID = Supabase user UUID (`data/subscription/RevenueCatManager.kt`); offerings fetched at runtime (comment: Play sells only `vinetrack_solo_yearly`; Team/Enterprise are portal-managed).
- Purchase/restore via RC awaitPurchase/awaitRestore; live unlock via `UpdatedCustomerInfoListener`. Not written to Supabase; server verification only via the Supabase RPC path (step A).

## 6. Trial access — three overlapping mechanisms

1. **Client-side 3-month free window** (both apps): `Date() < auth.users.created_at + 3 months`, computed locally from the server-provided `created_at` (iOS `isInInitialFreeAccessPeriod`; Android caches `user_created_at` in prefs). **User-scoped**, not stored anywhere, works offline and cross-device. Risks: a new email = a new 3-month trial; evaluated against the device clock.
2. **Store intro offers**: 3-month free trials on the RC products (Apple/Google enforced, `periodType == .trial`).
3. **Server-side trial** (draft billing layer): `vinetrack_plans.trial_days = 90` (solo) + `vinetrack_subscriptions.trial_start/trial_end` + `status='trialing'`, populated only by the draft RevenueCat webhook. `get_my_vinetrack_access()` treats `trialing` as entitled but **never checks `trial_end` against `now()`** — expiry relies entirely on an RC `EXPIRATION` webhook event arriving.

Trial users and the Portal: only via mechanism 3 (server-side), which is not yet fed by anything in production. Expired trials on mobile: paywall (iOS) / paywall route (Android). Changing devices does not reset a trial (created_at is server data); changing email (new account) does.

## 7. Database objects (authoritative inventory)

Identity/membership (all RLS-enabled, authoritative):
- `profiles` (sql/001) — user-scoped, self-only policies, **no billing columns**.
- `vineyards`, `vineyard_members` (roles `owner|manager|supervisor|operator`), `invitations` (case-insensitive email matching throughout), `worker_types` (106/107). Helper RPCs `is_vineyard_member` / `vineyard_role` / `has_vineyard_role` used across ~100 migrations' RLS.
- Ownership safety (sql/016): last-owner guard trigger, `transfer_vineyard_ownership`, account-deletion request pipeline.
- Team RPCs: `create_vineyard_with_owner`, `create_invitation` / `resend_invitation` / `cancel_invitation` (079, 122), `accept_invitation` / `decline_invitation` (001/003/079/081), `update_member_role`, `remove_member`, `get_vineyard_team_members`, `set_default_vineyard` (012).

System admin — **two coexisting mechanisms**:
- Legacy `is_admin()` (sql/017): hardcoded email allowlist containing exactly `jonathan@stockmansridge.com.au`; still gates ~14 `admin_list_*` RPCs and support-request RLS.
- Table-driven `system_admins` + `is_system_admin()` (sql/062/063): gates feature flags, billing grants, login-activity, email logs, irrigation admin. This is the pattern the new entitlement work should standardise on.

Billing (the `vinetrack_*` layer):
- Tables (defined in `supabase/migrations-draft-billing/01_vinetrack_pricing_entitlements.sql`): `vinetrack_plans` (seeded: `legacy_monthly`, `legacy_yearly`, `solo` [Apple, trial 90d], `team` [Stripe], `enterprise`; sql/096 adds `internal_unlimited`), `vinetrack_subscriptions` (owner_user_id-keyed; provider `apple|stripe|manual`; status `trialing|active|past_due|canceled|expired|paused|manual`), `vinetrack_user_licences` (per-seat; has an **unused** `invited_email` pre-signup placeholder), `vinetrack_invoice_records`, `vinetrack_billing_events` (append-only, idempotent on `(provider, external_event_id)`).
- All five: RLS enabled, **SELECT-only policies, zero client write policies** — clients cannot edit their own plan state. Writes are service-role/SECURITY-DEFINER only.
- Entitlement RPC: **`get_my_vinetrack_access()`** — authoritative version in `sql/096` (24 columns: `has_supabase_access`, `access_source`, `plan_*`, `status`, `trial_end`, `current_period_end`, `unlimited_licences`, `manual_grant_*`, `solo_check_required`, `can_use_ios_app`, `can_use_portal`, licence counts). Tier ranking enterprise > internal > team > legacy > solo; `solo` returns `solo_check_required = true` (defer to RC on device).
- ⚠️ **Draft-dependency inconsistency**: `sql/096` (numbered, applied stream) depends on the "draft" tables — so draft file 01 must in practice already be applied to any environment where 096 runs. The "draft" label is effectively historical for file 01; only `02_test_seed…` is genuinely manual-only.

Edge Functions: `revenuecat-webhook` (**draft**, fail-closed secret check, idempotent, resolves `app_user_id` only when it is a Supabase UUID, placeholder plan maps incl. `premium → legacy_yearly` TODO); `send-invitation-email`, `support-request`, email test functions, weather/agronomy proxies. **No Stripe webhook exists yet.**

## 8. Billing Grants ("Billing Grants / Internal Access")

- **No dedicated grants table.** A grant is a `vinetrack_subscriptions` row with `unlimited_licences = true`, plan `internal_unlimited`, plus columns `manual_grant_reason`, `manual_grant_expires_at`, `manual_grant_revoked_at/by` (all added in `sql/096`).
- RPCs (all `is_system_admin()`-gated; called by iOS `BillingGrantsView` and Android `BillingGrantsScreen` as admin tooling): `admin_list_manual_unlimited_grants`, `admin_grant_unlimited_access(p_owner_user_id, p_vineyard_id, p_reason, p_expires_at)`, `admin_revoke_unlimited_access(p_subscription_id, p_revoke_licences)`.
- Association: keyed on **`auth.users.id`** (raises `user_not_found` if the uuid doesn't exist). **Email is display-only** in the listing output. Vineyard link optional/contextual. Expiry (`manual_grant_expires_at`) **is** checked at read time by `get_my_vinetrack_access()`. Revocable. Does **not** create an auth user; does **not** work pre-signup.
- Platform detection: **Android detects grants** (gate step A). **iOS cannot** — the RPC result is diagnostics-only there. The grant "works only in the portal + Android" today.
- Email case-sensitivity: not applicable to grants (uuid-keyed); everywhere email *is* compared (invitations, `add_system_admin`) it is `lower()`-normalised.

### The Jonathan access problem — cause analysis

From code (conclusive):
1. **iOS ignores the grant entirely.** Even a perfectly valid grant for his `auth.users.id` cannot unlock iOS: the enforced gate is RevenueCat `pro` + the 3-month `created_at` window. Once his account is older than 3 months and he has no Apple subscription, iOS shows the paywall regardless of any grant. This alone explains "granted access does not arrive on iOS".
2. **A grant cannot exist without a pre-existing auth user.** If the grant was created in the Portal against an email before the matching auth account existed (or against a differently-spelled/aliased email resolved to a different uuid), it points at the wrong or no user. The uuid-keyed RPC prevents this, but a Portal-side email-based flow (implemented outside this repo) could bypass it.
3. Separate legacy coupling: `is_admin()` (sql/017) hardcodes this email for admin RPCs — it grants admin *reporting* access, never product entitlement, and must not be duplicated in the new system.

Requires live verification (not possible from this sandbox — service-role/Management-API credentials are not exposed to the agent shell; run in the Supabase SQL editor):

```sql
-- (a) does the auth account exist, is it confirmed, when did it last sign in?
select id, lower(email), created_at, email_confirmed_at, last_sign_in_at, banned_until
from auth.users where lower(email) = 'jonathan@stockmansridge.com.au';

-- (b) is the grant connected to that user id, and is it live?
select s.id, s.owner_user_id, s.status, s.unlimited_licences,
       s.manual_grant_reason, s.manual_grant_expires_at, s.manual_grant_revoked_at, s.deleted_at
from vinetrack_subscriptions s where s.unlimited_licences = true or s.manual_grant_reason is not null;

-- (c) Stockmans Ridge membership for that user
select vm.vineyard_id, v.name, vm.role from vineyard_members vm
join vineyards v on v.id = vm.vineyard_id
where vm.user_id = '<user id from (a)>';

-- (d) what the resolver would return for him (run as that user, or inspect the CTE in sql/096)
```

If (a) returns no row or `email_confirmed_at is null`, that is the login failure. If (a) is fine but (b)'s `owner_user_id` differs from (a)'s id, the grant is attached to the wrong identity. Even when both are correct, **iOS will still not honour it until Phase 2 wires the resolver into the gate.**

## 9. Roles vs paid licences — current conflations

- Membership, role and entitlement are already separate tables — good. No code path grants Owner from payment or payment from Owner.
- Conflations that do exist:
  - **Vineyard membership is a prerequisite for the paywall** on both platforms (no-vineyard users bypass entitlement checks entirely — they get the app shell's onboarding, effectively free access to nothing, acceptable but worth documenting).
  - **System Admins have no automatic mobile entitlement** — correct, but confusing during testing: an admin without an RC sub or grant hits the iOS paywall.
  - The 3-month window means **authentication alone currently implies 3 months of entitlement** — a deliberate but client-enforced conflation.
- Seat/licence consumption (`vinetrack_user_licences`) exists in schema but is **not enforced anywhere** (no seat-count checks in the resolver).

## 10. Offline access behaviour (both apps, deliberately preserved)

- Snapshot store: `EntitlementVerificationStore` — iOS UserDefaults key `vinetrack.entitlementVerification.v1`; Android SharedPreferences `vinetrack_entitlement`, same key. Contents: `{userId, lastVerifiedAt, wasEntitled, productStatus}` (+ reserved `vineyardAccessActive` on iOS, never written).
- Written only after a successful **online** verification; a verified "not entitled" never anchors grace; Android additionally records a negative only when *both* online checks completed (flaky networks never shrink the window).
- Grace: **30 days** from the last entitled verification, applied **only while offline**. Keyed by user id (no cross-account leakage). iOS marks a verification >24 h old as stale (refresh button); reconnect triggers automatic re-verification on both platforms.
- A user cannot continue indefinitely: after 30 days offline, iOS shows `OfflineAccessUnavailableView`, Android routes to `Paywall` on next cold start.
- Grant revoked while offline: undetected until reconnection (within the 30-day design envelope). The 3-month window bypasses all of this — no verification needed at all.

## 11. Security risks

| Risk | Severity | Detail |
|---|---|---|
| iOS entitlement gate is client-side only (RC SDK + local date math); Supabase-verified path exists but is unenforced | **High** | `SubscriptionService.hasAccess`; portal/manual/grant purchases invisible on iOS |
| 3-month free window: per-email, client-clock-evaluated, no server record | **High** | New email = new trial; device clock rollback extends it; no `trial` row is written |
| RC entitlement name mismatch: apps use `pro`, draft webhook maps `premium` | **High** (blocking for Phase 2) | `supabase/functions/revenuecat-webhook/index.ts` line ~82, placeholder product maps |
| Trial/period expiry in `get_my_vinetrack_access()` is event-driven only (no `now()` check on `trial_end`/`current_period_end`) | **Medium** | Missed RC webhook = indefinite `trialing/active` access |
| Android session tokens in plaintext SharedPreferences | **Medium** | `vinetrack_session`; move to EncryptedSharedPreferences/Keystore later |
| Entitlement snapshots in UserDefaults / plain prefs (editable on rooted/jailbroken devices) | **Low–Medium** | Bounded by 30-day grace + offline-only application |
| Legacy `is_admin()` hardcodes one email in SQL | **Medium** | Compromised mailbox on that account = full legacy admin surface; also violates the no-hardcoded-email rule going forward |
| No Stripe webhook; portal purchases have no ingestion path in this repo | **Medium** | `vinetrack_invoice_records` idle; Portal presumably writes via service role (unverifiable here) |
| Draft billing schema applied but labelled "draft"; no migration marker | **Medium** | `sql/096` depends on it; formalise in Phase 2 |
| Purchases never pushed to Supabase from either app; Supabase's view of Apple/Google state depends entirely on the unfinished webhook | **High** | Cross-platform rule impossible until fixed |
| RC anonymous-user collisions | **Low** | Both apps `logIn()` with the Supabase UUID before purchase; webhook ignores `$RCAnonymousID` |
| Client-writable subscription state | **None found** | All `vinetrack_*` tables are SELECT-only for clients; `profiles` carries no billing columns |
| Cross-vineyard licence leakage | **Low** | Grants are user-scoped; no seat enforcement yet to leak |

## 12. Recommended canonical identity keys

- **User identity:** `auth.users.id` (already the RC appUserID on both platforms — the hardest part is done).
- **Vineyard identity:** `vineyards.id` uuid.
- **Subscription identity:** `vinetrack_subscriptions.id` (internal uuid) + external refs already present (`revenuecat_app_user_id`, `stripe_customer_id`, `stripe_subscription_id`).
- **Billing account identity:** `vinetrack_subscriptions.owner_user_id` (extend to a billing-account table only if multi-owner billing is ever needed).
- **Licence assignment:** `vinetrack_user_licences (subscription_id, user_id, vineyard_id)` — already shaped correctly, incl. `invited_email` for pre-signup seats.
- **Email:** lookup/communication only — already true everywhere except the legacy `is_admin()` allowlist.

**Migration feasibility: yes, without breaking users.** Existing schema already uses these keys; no data remodelling required — the work is wiring, backfill and enforcement, not restructuring.

## 13. Current-state access flows

```text
iOS login (no purchase)
→ Supabase Auth (Keychain session)
→ vineyard membership (listMyVineyards; none → invite/create screen, paywall skipped)
→ disclaimer
→ SubscriptionService.hasAccess:
    RC "pro" active? → app
    created_at + 3mo in future? → app
    offline && verified-entitled <30d ago? → app
    offline otherwise → "can't verify" notice
    else → paywall (blocking)

iOS purchase           → RC purchase(package) → entitlement "pro" active → gate opens → snapshot written. Nothing written to Supabase.
iOS restore            → RC restorePurchases() → same.

Android login (no purchase)
→ Supabase Auth (Ktor; prefs session)
→ vineyard membership (none → NoVineyards, paywall skipped)
→ resolveVineTrackAccess():
    A get_my_vinetrack_access(): has_supabase_access && can_use_ios_app → app   ← portal/grant/Apple-in-Supabase aware
    B RC "pro" active → app
    C created_at + 3mo → app
    D offline grace <30d → app
    else → Paywall route

Android purchase/restore → RC (Play under the hood) → entitlement → unlock + snapshot. Nothing written to Supabase.

Portal login             → same auth.users; entitlement via vinetrack_* tables (implementation outside this repo).

Manual Billing Grant     → admin RPC (uuid-keyed) → vinetrack_subscriptions(unlimited_licences)
                          → visible to: Portal ✓, Android ✓ (step A), iOS ✗ (resolver unenforced).

Invitation               → create_invitation (email, lowercased) → invitee accepts (email match vs JWT) → vineyard_members row. No entitlement implication.

Trial                    → client-side 3-month window from auth created_at (both apps) + store intro offers.
                           Expiry → paywall. Server-side trialing rows exist in schema but nothing populates them in production.
```

Divergence points: (1) Android checks Supabase first, iOS never does; (2) purchases reach Supabase on neither platform; (3) trial is client-computed on mobile, schema-modelled for the portal.

## 14. Proposed Phase 2 migration plan (not executed)

Principle: **additive, feature-flagged, parallel-run, reversible.** The Android resolver order (Supabase → RC → free window → grace) is already the target architecture; Phase 2 mostly brings iOS and the server up to it.

1. **Formalise the billing schema** — new numbered migration (`sql/132_…`) that re-states the draft-01 objects idempotently (`create table if not exists` / `create or replace`) so the applied state is version-controlled; keep all existing data.
2. **Harden the resolver** (`get_my_vinetrack_access` v2): add `now()` checks on `trial_end`/`current_period_end` (with a small grace buffer for `past_due`), keep `solo_check_required` semantics, add `access_reason` for diagnostics.
3. **Finish and deploy the RevenueCat webhook**: fix entitlement map to `pro`, real product IDs (`vinetrack_solo_yearly` + legacy IDs from the RC dashboard), set `REVENUECAT_WEBHOOK_SECRET`. This is what finally writes Apple **and** Google purchases into Supabase, keyed on `revenuecat_app_user_id` = Supabase uuid.
4. **Backfill**:
   - Apple/Google: export RC customers (appUserID = Supabase uuid) → upsert `vinetrack_subscriptions` rows (`billing_provider='apple'`, correct plan/status/period) via a service-role script; idempotent on `(owner_user_id, plan)`.
   - Portal/Stripe: same pattern from Stripe subscriptions (needs the Portal's Stripe account mapping — outside this repo).
   - Trials: one-time backfill creating `status='trialing'`, `trial_end = auth.created_at + 3 months` rows for accounts still inside their window, so the trial becomes server-recorded without shortening anyone's access.
   - Grants: already uuid-linked; add an optional `invited_email` claim flow (consume `vinetrack_user_licences.invited_email` on signup) for pre-signup grants.
5. **iOS enforcement**: wire `VineTrackAccessResolver` into `NewBackendRootView` behind a `system_feature_flags` key (e.g. `entitlement_resolver_enforced`), keeping `SubscriptionService.hasAccess` as fallback exactly as Android does. Extend `EntitlementVerificationSnapshot` to record the resolver outcome (`vineyardAccessActive` slot is already reserved) so grants/portal subs survive offline.
6. **Parallel run & rollout**: flag off = today's behaviour; flag on for System Admins first, then all users. No user can be locked out while the RC + free-window fallbacks remain in the chain.
7. **Rollback**: flip the flag; webhook/backfill data is additive and can be ignored by clients; no destructive changes anywhere.
8. **Deprecations (later phases)**: retire the client-side 3-month window in favour of server trials; replace `is_admin()` email allowlist with `system_admins`; add a Stripe webhook; encrypt the Android session store; add seat enforcement.

### Files likely to change in Phase 2
- `sql/132+` (schema formalisation, resolver v2, backfills, invited-email claim)
- `supabase/functions/revenuecat-webhook/index.ts` (finalise), new `stripe-webhook` (later)
- iOS: `NewBackendRootView.swift`, `SubscriptionService.swift`, `VineTrackAccessResolver.swift`, `EntitlementVerificationStore.swift`, `SubscriptionSettingsView.swift`, `VineTrackAccessRepository.swift`
- Android: `AppViewModel.kt` (`resolveVineTrackAccess`), `RevenueCatManager.kt`, `SubscriptionState.kt`, `VineTrackAccessRepository.kt`

## 15. Questions not answerable from code/schema

1. Live auth/grant/membership state for `jonathan@stockmansridge.com.au` (queries provided in §8) — the sandbox has no service-role or Management-API credentials.
2. RevenueCat dashboard truth: actual product IDs, live entitlement id (`pro` assumed from both apps), offering contents.
3. The Portal (Lovable) implementation: how its Billing Grants page creates grants (uuid RPC vs a service-role email-based path), and its Stripe checkout/webhook wiring.
4. Whether `vinetrack_solo_yearly` is live on Google Play.
5. Definitive confirmation that draft-01 was applied to production (strongly inferred from the `sql/096` dependency).

## 16. Phase confirmations

- Typecheck/builds: **not run — no application code was changed** (this document is the only new file).
- Files changed: none in `ios/`, `android-vinetrack/`, `sql/`, or `supabase/`; added `docs/access-entitlement-audit-phase1.md` only.
- Migrations executed: **none.**
- Production behaviour: **unchanged.**
