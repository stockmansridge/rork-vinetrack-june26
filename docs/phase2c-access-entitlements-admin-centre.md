# Phase 2C — System Admin Access & Entitlements Centre (Portal Hand-off)

Contract for the Lovable head-office portal page **`/admin/access-entitlements`**.
Everything server-side ships in **`sql/140`** + **`sql/141`** (apply in that order,
after 132–139). The portal calls RPCs only — **no direct table writes, no raw
billing events in the browser, no service-role key**.

> Same connection rules as every portal feature: Supabase URL + anon key,
> Supabase Auth session, RLS + `is_system_admin()` enforce access server-side.

---

## 1. Route, navigation, guard

- Route: `/admin/access-entitlements`, nav label **Access & Entitlements**,
  under the System Administration / Billing area.
- UI guard: hide the nav item unless `select public.is_system_admin()` returns
  true for the session user.
- Server guard (the real one): **every** RPC below raises `42501` for
  non-admins. A hidden route is never the security boundary — treat a `42501`
  from any call as "render the access-denied state".

## 2. Health header

Call `select public.admin_store_billing_monitor();` (returns one JSON object).

| Card | JSON source | Severity rule |
| --- | --- | --- |
| Needs Review | `events_needing_review.count` | 0 → Healthy, ≥1 → Attention |
| Failed Events | `failed_events.count` | 0 → Healthy, ≥1 → **Critical** |
| Unknown Products | `unknown_products` (array length) | 0 → Healthy, ≥1 → Attention |
| Unresolved Users | `unresolved_users.count` | 0 → Healthy, ≥1 → Attention |
| Ownership Conflicts | `ownership_conflicts.count` | 0 → Healthy, ≥1 → **Critical** |
| Sync Delays | `rc_active_supabase_missing` + `stuck_deliveries` lengths | 0 → Healthy, ≥1 → **Critical** |
| Expiring Soon | `expiring_within_7_days` length | informational |
| Recent Changes | `recent_status_changes` | informational |

The JSON already truncates app-user ids and contains **no payloads, receipts or
tokens** — render fields as-is, never fetch `billing_provider_events` directly.

## 3. Billing alert inbox

- List: `select * from public.admin_billing_alerts(p_include_acknowledged => false, p_limit => 100);`
  Columns map 1:1: `alert_type`, `severity`, `resolved_user_id` (join to the
  users table client-side from the directory you already loaded, or show the
  uuid), `product_id`, `provider_event_id`, `event_type`, `detail` (reason),
  `created_at`, `acknowledged_at`, `acknowledged_by`.
- Acknowledge: `select public.admin_acknowledge_billing_alert('<alert-id>');`
- Toggle "show acknowledged" re-calls with `p_include_acknowledged => true`.
- **No delete action exists and none must be added** — the inbox is append-only.

## 4. Users & access table

`public.admin_access_users(...)` — paginated, server-filtered. Never load all
users unfiltered into memory; page size is clamped to 200 server-side.

Parameters (all optional):

- `p_search` — email / full-name substring
- `p_has_access` — `true` (granted) / `false` (denied)
- `p_plan_code` — effective plan (`internal_unlimited`, `solo`, `team`, …)
- `p_vineyard_id`, `p_role` (`owner|manager|supervisor|operator`)
- `p_billing_source` — `apple | google | stripe | manual | internal | trial | none`
- `p_status_filter` — `trial | expired | cancelled | needs_review | failed | mismatch | manual_override`
- `p_limit` (≤200), `p_offset`

Returned columns → table columns:

User (`full_name`), Email, Auth status (`is_disabled`), Email confirmed,
Vineyard + role (`vineyards` jsonb array), Effective plan (`plan_name` /
`plan_code`), Access status (`has_access`), Access reason (`reason_code`),
Billing source (`billing_provider`), Purchase platform (`purchase_platform`),
Product (`product_id`), Subscription status (`subscription_status`), Current
period end, Licence assignment (`licence_count`), Manual override
(`manual_override`), Review status (`review_status`), Last verified
(`last_verified_at`), plus `total_count` (same on every row — drive the pager
from it).

`reason_code` display strings:

- `internal_unlimited` → Internal Unlimited
- `enterprise_subscription` → Enterprise contract
- `portal_subscription` → Portal subscription
- `assigned_licence` → Team licence
- `app_store_subscription` → Apple/Google purchase (disambiguate with `billing_provider`)
- `active_trial` → Trial
- `expired` / `revoked` / `no_entitlement` → denied states

## 5. User detail drawer

One call: `select public.admin_user_access_detail('<user-uuid>');` → JSON with:

- `identity` — full name, email, confirmation state + timestamp, Supabase user
  id, account created, last sign-in, disabled, system-admin flag. **No tokens
  or password data exist in the response.**
- `memberships.active` — vineyard, role, joined, licence for that vineyard.
  `memberships.historical` — soft-deleted vineyards (collapse under an
  "administrative history" section, hidden by default).
  `memberships.pending_invitations` — invitation state.
- `effective_access` — granted/denied, plan, `reason_code`, source, unlimited,
  `portal_access`, `can_use_ios_app`, `can_use_android_app`, expiry fields,
  `last_verified_at`, and `cached_state` (the stored resolver state — show
  "live vs cached" by comparing it with the freshly computed fields).
- `billing_sources` — EVERY subscription (active + historical) with status,
  product, platform, start, period end, grace, cancel-at-period-end, expiry,
  last provider event, last verified, `is_effective`, `is_currently_valid`.
  Render `is_currently_valid = false` rows visually separated (Inactive /
  historical). External ids arrive **redacted** (`abcd…wxyz`) — display as-is.
- `licences_held`, `open_alerts`.

History timeline: `select * from public.admin_user_access_history('<uuid>', 100);`
→ `occurred_at`, `source` (`entitlement_audit | billing_event | alert`),
`event_type`, `platform`, `detail` (already stripped of receipt/token keys).
Covers: access granted/denied/source changed, manual grant created/extended/
revoked, licence assigned/removed, store created/renewed/cancelled/expired,
ownership conflict, mismatch detected, alert created/acknowledged.

Refresh entitlement button: `select public.admin_refresh_user_entitlement('<uuid>');`
→ `{has_access, reason_code, plan_code, changed, refreshed_at}`.

## 6. Manual Billing Grants

Create: `select public.admin_create_billing_grant(p_owner_user_id, p_grant_type, p_reason, p_starts_at, p_expires_at, p_vineyard_id);`

Grant types (exact strings): `internal_unlimited`, `complimentary_solo`,
`complimentary_team`, `beta_tester`, `temporary_access`, `support_access`,
`enterprise_contract`.

Form rules (server-enforced; mirror in UI):

- User: resolve by searching the directory and submit the **auth.users.id
  uuid** — never an email. If a person has no Auth account, show
  **"Account setup required"** and stop; the RPC returns `user_not_found` and
  will never silently create an Auth user.
- Reason: required, non-empty (`reason_required` otherwise).
- Start date optional (future starts deny access until reached — the resolver
  enforces `started_at`).
- Expiry optional, **required** for `temporary_access` and `support_access`
  (`expiry_required_for_grant_type`), must be in the future.
- Vineyard optional.
- Show a confirmation dialog before submit: user, grant type, vineyard, dates,
  and the resulting access change.

Extend: `admin_extend_billing_grant(subscription_id, new_expires_at, reason)`
(null expiry = no longer expires; revoked grants refuse with
`grant_revoked_create_new`).
Revoke: `admin_revoke_billing_grant(subscription_id, reason, revoke_licences)`.
Both operate **only** on manual grants — Apple/Google/Stripe records return
`not_a_manual_grant`.

Licences: `admin_assign_licence(subscription_id, user_id, reason, vineyard_id)`
(seat-checked; store subscriptions refuse) and
`admin_remove_licence(licence_id, reason)`.

Every mutation writes an append-only audit row and immediately refreshes the
user's entitlement state — the drawer and table reflect the change on reload.

## 7. Other safe admin actions

- Send invitation → existing `create_invitation(...)` RPC (vineyard-scoped).
- Send password-reset email → `supabase.auth.resetPasswordForEmail(email)`
  from the portal client (GoTrue sends the mail; no admin RPC needed).
- Acknowledge alert → §3.
- High-risk actions (grant create/revoke, licence remove, disable) always show
  a confirmation dialog naming the user, vineyard and resulting access change.

## 8. Existing Billing Grants page

Preferred: redirect it to `/admin/access-entitlements?billing_source=internal`
(the Grants filter active). If kept as a simplified view, back it with
`select * from public.admin_list_billing_grants();` — one grants system only.

Display fix (required): use `licences_display` and `platforms_display` from
that RPC. Internal Unlimited must render as **Licences: Unlimited** and
**Platforms: Portal, iOS, Android** — never "Licences: 0".

## 9. Security summary (what the server already enforces)

- All listed RPCs: `SECURITY DEFINER`, pinned `search_path`, `is_system_admin()`
  gate, `42501` for everyone else. Table RLS on `billing_provider_events`,
  `billing_admin_alerts`, `vinetrack_entitlement_audit` is admin-SELECT-only;
  `vinetrack_*` billing tables have zero client write policies.
- Vineyard owners/managers have no route into other vineyards' data — none of
  these RPCs are membership-scoped reads; they are admin-or-nothing.
- Clients cannot modify verified provider records, expiry, product mappings, or
  their own entitlement: writes exist only via the webhook (service role) and
  the reason-required admin RPCs above; store rows are refused by the grant
  RPCs by design.
- External subscription/transaction ids stay redacted; raw payloads are never
  returned by any RPC the portal calls.

## 10. Test checklist (Phase 2C acceptance)

- [ ] Non-admin cannot open the route (UI) and every RPC raises 42501 (server).
- [ ] Search finds users by email and name; pagination works with `total_count`.
- [ ] Internal Unlimited shows plan Internal Unlimited, Licences: Unlimited,
      Platforms: Portal, iOS, Android.
- [ ] Apple subscription row shows source Apple, platform ios, correct product.
- [ ] Google subscription row shows source Google, platform android.
- [ ] Portal (Stripe) subscription shows source Portal.
- [ ] Expired subscription renders in the inactive/historical section.
- [ ] Cancel-at-period-end shows as ACTIVE access with a "cancels on …" badge.
- [ ] Creating a grant updates effective access (table + drawer) immediately.
- [ ] Revoking a grant removes access and appears in the history timeline.
- [ ] Every mutation produces a history entry (billing event + entitlement audit).
- [ ] Alerts can be acknowledged; no delete control exists.
- [ ] No receipts, tokens, webhook secrets or unredacted external ids anywhere.
- [ ] 1,000-user directory stays responsive (server pagination, page ≤ 200).

## 11. Apply order

1. `sql/140_access_entitlements_admin_centre.sql`
2. `sql/141_billing_grants_and_admin_actions.sql`

Both are transactional, additive, and carry rollback SQL in their headers.
Feature flag `use_shared_supabase_entitlement` stays at cohort **internal**
throughout Phase 2C.
