# App Review — Guideline 2.1(b) Information Needed (Aug 11)

App: VineTrack (ASC app ID 6761143377) · Version 2.8.9 · Build 35

Apple asked:

1. What is the purchase flow in VineTrack once the free trial expires?
2. Provide login credentials for an account whose free trial has already expired.

This document contains (A) the audited purchase-flow facts for build 35, (B) the
demo-account setup, and (C) the exact Resolution Center reply to send.

---

## A. Audited expired-trial flow (build 2.8.9 / 35)

Verified in source (`EntitlementGate.swift`, `PaywallView.swift`,
`SubscriptionService.swift`, `NewBackendRootView.swift`,
`SubscriptionSettingsView.swift`):

- After sign-in, the app resolves entitlement (server first, then App Store /
  RevenueCat). An expired trial with no subscription resolves to `denied`.
- `denied` routes to a **full-screen, non-dismissable** `SubscriptionPaywallView`.
  The only other action is **Sign Out**. No app content is reachable.
- The paywall lists the RevenueCat default offering packages — **Monthly
  (US$9.99/month)** and **Annual (US$99/year)**, both auto-renewable
  subscriptions purchased through **StoreKit / Apple In-App Purchase**
  (RevenueCat SDK `Purchases.purchase(package:)`).
- **Restore Purchases** is on the paywall (and in Settings → Subscription); it
  calls `Purchases.restorePurchases()` and re-evaluates access.
- After a successful purchase the `pro` entitlement activates, the gate
  re-resolves, and the app unlocks immediately (server webhook sync happens in
  the background and never blocks entry).
- **No external purchase path**: the app contains no link, button, or wording
  directing users to buy outside Apple IAP. The only outbound links are the
  Privacy Policy, Apple's standard EULA, and (for active subscribers only)
  Apple's own `apps.apple.com/account/subscriptions` management page.
- Multiplatform note: accounts whose organisation already has access through
  the VineTrack web business portal unlock automatically (Guideline 3.1.3(b));
  the iOS app itself never advertises or links to web purchasing.

## B. Demo account (expired trial)

- Email: `appreview@vinetrack.com.au`
- Password: set when creating the user (record it in ASC App Review Information)

Setup (once): create the user in Supabase Dashboard → Authentication → Add user
(Auto Confirm), then run `scripts/app-review-expired-trial-demo.sql` in the SQL
editor. The script backdates account creation 4 months, forces the
server-authoritative trial row to `expired`, provisions "App Review Demo
Vineyard", and verifies nothing else grants access.

Where to put it in ASC: App Store Connect → App → App Review Information →
enable "Sign-in required", enter the email + password, and paste the reviewer
steps (below) into Notes.

## C. Draft Resolution Center reply

> Hello, and thank you for the review.
>
> **Purchase flow after the free trial expires:**
>
> When a user whose 3-month free trial has expired signs in, VineTrack presents
> a full-screen subscription paywall immediately after login. No app content is
> accessible until a subscription is active — the only other option on that
> screen is Sign Out.
>
> The paywall offers two auto-renewable subscriptions, both purchased entirely
> through Apple In-App Purchase (StoreKit): Vineyard Tracker Pro Monthly
> (US$9.99/month) and Vineyard Tracker Pro Annual (US$99/year). Tapping a plan
> starts the standard App Store purchase sheet. On successful purchase the app
> unlocks immediately. The paywall and the Subscription settings screen both
> include Restore Purchases. Active subscribers can manage or cancel via
> Apple's subscription management page, which the app links to directly.
>
> The app contains no links, buttons, or text directing users to purchase
> outside Apple In-App Purchase. (Some enterprise users receive access through
> a subscription their organisation purchased on our web business portal, per
> Guideline 3.1.3(b); the iOS app never advertises or links to purchasing
> outside the app.)
>
> **Expired-trial demo account:**
>
> Email: appreview@vinetrack.com.au
> Password: [PASSWORD]
>
> Steps to reach the paywall:
> 1. Launch VineTrack and complete the brief first-launch intro.
> 2. Sign in with the credentials above.
> 3. Accept the one-time agronomy disclaimer.
> 4. The subscription paywall appears — this account's free trial has already
>    expired, so no content is accessible. From here you can complete a
>    sandbox purchase of either plan; the app unlocks into "App Review Demo
>    Vineyard" immediately.
>
> Please let us know if any further information would help. Thank you!

## Pre-submission checklist (do NOT resubmit until all ticked)

- [ ] Demo user created in Supabase Auth (Auto Confirm) with the final password
- [ ] `scripts/app-review-expired-trial-demo.sql` run — ends with
      "will resolve to DENIED (paywall)"
- [ ] Real device/TestFlight check: sign in as the demo user → paywall appears;
      Monthly & Yearly load with prices; Restore Purchases responds
- [ ] RevenueCat dashboard: default offering contains BOTH monthly and yearly
      packages mapped to the live App Store products, entitlement `pro`
- [ ] ASC: both auto-renewable subscriptions are in "Ready to Submit"/Approved
      state and attached to the 2.8.9 submission (first-IAP submissions must
      ship with a build)
- [ ] ASC App Review Information updated with credentials + notes
- [ ] Resolution Center reply sent (Section C), THEN resubmit build 35

## Known follow-up (not required for this reply)

The paywall headline hard-codes "Start with 3 months free". Apple's intro offer
applies once per Apple ID subscription group, so a real user who already
consumed the trial would see wording StoreKit won't honour. Recommend gating
that copy on RevenueCat's `checkTrialOrIntroDiscountEligibility` in a follow-up
build (App Review's fresh sandbox ID *is* trial-eligible, so this does not
affect the current review).
