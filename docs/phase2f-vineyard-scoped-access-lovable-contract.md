# Phase 2F — Vineyard-Scoped Access & Grant Scope: Lovable Portal Contract

Backend delivered by Rork in `sql/155_billing_grant_scope.sql` and
`sql/156_vineyard_access_matrix.sql`. Apply both (155 first), then this
contract is live. Rollback-only tests: `sql/tests/156_phase2f_access_tests.sql`.

Cohort unchanged: `use_shared_supabase_entitlement` stays `internal`.
RevenueCat fallback stays enabled. No Stripe/RevenueCat/store-catalogue changes.

---

## 1. Core model change

VineTrack now separates **account access** from **vineyard access**:

- **Account access** — may the signed-in user use VineTrack at all
  (see invitations, the vineyard chooser, billing/support, restore purchases).
- **Vineyard access** — may the user enter and operate a SPECIFIC vineyard.

A vineyard is funded ("entitled") by, in precedence order
(`public._vineyard_entitlement_for`):

1. an active **vineyard-scoped Billing Grant** (`grant_scope = 'vineyard'`,
   `primary_vineyard_id` = the vineyard);
2. an active **multi-seat subscription anchored to it** (tier
   `team | enterprise | legacy`, non-manual, non-store provider, via
   `primary_vineyard_id`) — a user-scoped grant or solo/store subscription
   with an informational primary vineyard NEVER funds the vineyard this way;
3. any active vineyard **Owner** (membership role `owner`, or legacy
   `vineyards.owner_id`) whose OWN entitlement is valid — including the
   Owner's account trial (3 calendar months from `auth.users.created_at`).

A member may enter a vineyard when they have an **active membership** AND
(**their own account entitlement** OR the **vineyard entitlement** above).

The shared resolver `get_my_vinetrack_access()` (same 34 columns) gained one
granting step BELOW the account trial: when the user has no own entitlement
but one of their vineyards is funded, it returns
`has_supabase_access = true`, `access_source = 'vineyard'`,
`reason_code = 'vineyard_entitlement'`, `plan_tier = 'vineyard'`,
`billing_provider = 'vineyard'`, `vineyard_id` = the funded vineyard.
**An expired vineyard can no longer blank the whole account.**

## 2. Vineyard access matrix RPC (route guard source of truth)

```
select public.get_my_vineyard_access_matrix();  -- returns jsonb
```

Authenticated only (401/42501 otherwise). No parameters — always the caller.

```jsonc
{
  "generated_at": "2026-07-31T…",
  "account": {
    "user_id": "uuid",
    "account_access_state": "full | vineyard_only | restricted | no_vineyards",
    "has_account_entitlement": true,
    "account_reason_code": "active_trial | portal_subscription | … | expired | no_entitlement",
    "account_access_source": "solo | team | trial | none | …",
    "account_plan_code": "trial",
    "account_expires_at": "timestamptz | null",
    "has_any_accessible_vineyard": true,
    "accessible_vineyard_count": 2,
    "vineyard_count": 3,
    "pending_invitation_count": 1,
    "can_create_vineyard": true,
    "last_verified_at": "timestamptz"
  },
  "vineyards": [
    {
      "vineyard_id": "uuid",
      "vineyard_name": "Stockmans Ridge",
      "membership_role": "owner | manager | supervisor | operator",
      "membership_status": "active",
      "has_vineyard_access": true,
      "vineyard_access_reason": "account | vineyard_grant | vineyard_subscription | owner_subscription | owner_trial | owner_grant | no_vineyard_entitlement",
      "vineyard_access_source": "account | vineyard_grant | vineyard_subscription | owner_subscription | owner_trial | owner_grant | none",
      "plan_code": "team | internal_unlimited | trial | …",
      "subscription_status": "active | manual | trialling | …",
      "starts_at": "timestamptz | null",
      "expires_at": "timestamptz | null",   // null = open-ended
      "is_trial": false,
      "is_vineyard_wide": false,            // funded by a vineyard-scoped grant
      "is_billing_owner": false,            // the caller owns the funding entitlement
      "can_manage_billing": true,           // membership role = owner
      "can_enter_vineyard": true,
      "requires_billing_attention": false,  // owner of a denied vineyard
      "last_verified_at": "timestamptz"
    }
  ]
}
```

Notes:

- When `vineyard_access_source = "account"` the user's OWN entitlement opens
  the vineyard; plan fields describe THAT entitlement.
- The funding `subscription_id` of another owner is never returned.
- `account_access_state` semantics:
  - `full` — own entitlement active (all memberships open);
  - `vineyard_only` — no own entitlement, ≥1 vineyard funded;
  - `restricted` — memberships exist, none accessible;
  - `no_vineyards` — no memberships (chooser/onboarding).

### Single-vineyard variant

```
select public.get_my_vineyard_access(p_vineyard_id := '<uuid>');  -- jsonb
```

Same row shape (one object). Non-members receive
`{"vineyard_id": …, "has_vineyard_access": false, "vineyard_access_reason": "not_a_member", "vineyard_access_source": "none", "can_enter_vineyard": false, …}`
with **no vineyard name** — do not treat it as an error, treat it as denial.

## 3. Required portal behaviour

- Route guards: call the matrix after login. Never reduce it to one boolean.
  - `restricted` → restricted state (billing help for owners, "managed by the
    Vineyard Owner" for staff) — never hide invitations, never sign out.
  - `vineyard_only` / `full` → allow entry to vineyards with
    `has_vineyard_access = true`; show a chooser if the previously selected
    vineyard is denied. Suggested copy:
    "Access to {name} has expired, but you still have access to other vineyards."
  - An expired vineyard must never globally block the account.
- Persist the selected vineyard per user; validate against the matrix before
  opening it.
- Query keys (suggested): `["access","matrix"]`,
  `["access","vineyard", vineyardId]`. Invalidate on login, account switch,
  returning from billing/Stripe, invitation accept, and grant mutations from
  the admin centre. Clear ALL access queries on logout/account switch.
- Mobile apps already do the same via `get_my_vinetrack_access` +
  the matrix; do not re-derive precedence in TypeScript.

## 4. Billing Grant scope (Access & Entitlements)

### Creation RPC (additive parameter)

```
select public.admin_create_billing_grant(
  p_owner_user_id := '<user uuid>',
  p_grant_type    := 'internal_unlimited',
  p_reason        := 'required text',
  p_starts_at     := null,
  p_expires_at    := null,
  p_vineyard_id   := '<vineyard uuid>',   -- REQUIRED for vineyard scope
  p_grant_scope   := 'user' | 'vineyard'  -- default 'user'
);
```

Allowed-scope matrix (server-enforced, `_billing_grant_allowed_scopes`):

- internal_unlimited → user, vineyard
- complimentary_solo → user
- complimentary_team → vineyard
- beta_tester → user, vineyard
- temporary_access → user, vineyard
- support_access → user, vineyard
- enterprise_contract → vineyard

Error codes (message contains the code):

- `invalid_grant_scope` → "Choose whether this grant applies to a user or a vineyard."
- `grant_scope_not_allowed_for_type` → "That grant type does not support the selected scope."
- `vineyard_required_for_vineyard_scope` → "Select the vineyard this grant should cover."
- `vineyard_not_found` → "That vineyard could not be found."
- `reason_required`, `expiry_required_for_grant_type`, `expiry_must_be_future`,
  `start_after_expiry`, `user_not_found` — unchanged from Phase 2C.

UI requirements:

- Explicit control: "Grant applies to: ○ This user only ○ An entire vineyard".
- Vineyard scope: vineyard selector is REQUIRED; explain that all active
  members inherit access (and new members inherit automatically).
- User scope: do not describe any vineyard as the grant's access scope.

### Listing

`admin_list_billing_grants()` — same columns as Phase 2C plus appended
`grant_scope text`. `licences_display` shows `Vineyard-wide` for
vineyard-scoped grants. Extend/revoke RPCs unchanged in signature; a
vineyard-scoped revoke/extend recalculates every member's entitlement state.

### Migration behaviour

Every pre-existing grant (and all non-manual rows) backfilled to
`grant_scope = 'user'`. Nothing was silently converted — recreate a grant as
vineyard-scoped where that was the intent.

## 5. Invitations

New shared RPC for the INVITED user (fixes nameless invitation cards —
RLS hides `vineyards` rows from non-members, so the embedded
`vineyards(name)` join returned null):

```
select * from public.list_my_pending_invitations();
-- (id, vineyard_id, vineyard_name, vineyard_country, email, role, status,
--  invited_by_name, expires_at, created_at)
```

Pending + unexpired + non-deleted vineyards, keyed on the caller's JWT email.
Use it wherever the portal shows the signed-in user's own pending invitations,
and always display `vineyard_name` + `role` per card. Accept/decline by
invitation id (`accept_invitation` / `decline_invitation`, unchanged).
Invitations must remain visible in the `restricted` account state.

## 6. Diagnostics (System Admin)

```
select public.admin_explain_vineyard_access('<user uuid>', '<vineyard uuid>');
```

Returns jsonb: `decision` (has_vineyard_access, reason_code, access_source),
`account_access`, `vineyard_entitlement` (funding source, grant_scope,
billing_owner_user_id, expiry), `inheriting_members` (for vineyard-wide
grants, cap 200), `cached_result` vs `server_result`, and `mismatch_type`
(`no_cached_state | access_mismatch | reason_mismatch | null`).
System Admin only (42501 otherwise). Suitable for an "Explain access" drawer
in Access & Entitlements.

## 7. Permission error copy (portal mapping)

- `not_a_member` → "You don't have access to this vineyard."
- `no_vineyard_entitlement` → "This vineyard doesn't have an active subscription, trial, or grant."
- `owner_trial` (source, active) → show "Owner trial" with expiry.
- `vineyard_grant` (source) → show "Vineyard-wide grant" with expiry/open-ended.
- `restricted` state, staff roles → "Access for this vineyard is managed by its Vineyard Owner."
- Never show raw SQL/PostgREST errors.

## 8. Fixed contracts the portal may also rely on

- `admin_list_user_vineyards(p_user_id)` — `is_owner` and `member_count`
  are now guaranteed non-null (previously NULL `is_owner` broke strict
  decoders).
- Resolver `access_source` may now be `'vineyard'` and `reason_code`
  `'vineyard_entitlement'`; `billing_provider`/`plan_tier` may be
  `'vineyard'`. Treat unknown values as "has access, funded by the vineyard".
