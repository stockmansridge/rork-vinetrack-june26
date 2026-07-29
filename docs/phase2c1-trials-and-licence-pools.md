# Phase 2C.1 — Server-Authoritative Trials & Global Licence Pools

Backend contract for the Lovable portal team. Apply SQL migrations in
order: `sql/143` → `sql/144` → `sql/145`. Tests:
`sql/tests/143_account_trial_tests.sql`, `sql/tests/145_licence_pool_tests.sql`
(both roll back all fixture data).

Rollout controls unchanged: `use_shared_supabase_entitlement` cohort =
`internal`; RevenueCat fallback = enabled.

---

## 1. The account trial (SQL 143/144)

Every VineTrack account receives **three calendar months** of trial from
its **original account creation date** (`auth.users.created_at`). The
trial is keyed permanently on `auth.users.id` — it never restarts on
reinstall, email change, device change or platform change, and no client
can write it (RLS: no write policies on `public.vinetrack_account_trials`).

### Exact trial fields (`admin_user_access_detail(...)  -> 'account_trial'`)

| Field | Type | Values |
|---|---|---|
| `source_type` | text | always `account_trial` |
| `trial_started_at` | timestamptz | = account creation date |
| `trial_ends_at` | timestamptz | creation + 3 calendar months |
| `status` | text | `active` \| `expired` \| `revoked` |
| `is_currently_valid` | boolean | server-time validity |
| `created_from` | text | `migrated` \| `signup` \| `derived` |
| `is_persisted` | boolean | row exists vs derived on the fly |

### Access & reason values

Active trial (resolver `get_my_vinetrack_access()` AND directory
`admin_access_users`):

- `has_access` / `has_supabase_access` = `true`
- `reason_code` = `active_trial`
- `access_source` = `trial`
- `plan_code` = `trial` (plan_tier `trial`, plan_name `Account Trial`)
- `subscription_status` / `status` = `trialling`
- `billing_provider` = `trial`
- `is_unlimited` = `false`, `seats_included` (licence limit) = `1`
- `expires_at` = `trial_end` = trial end
- `portal_access` = `can_use_ios_app` = `can_use_android_app` = `true`
- `purchase_platform` = `null`

Expired trial with no other entitlement:

- `has_access` = `false`
- `reason_code` = `expired` (revoked trial → `revoked`)
- `access_source` = `trial`, `plan_code` = `trial`
- `subscription_status` = `expired`
- `expires_at` = **original** trial end (distinguishes "Trial expired"
  from `no_entitlement` = never entitled)

Precedence (unchanged above the trial):
`internal_unlimited` > enterprise > team > legacy > solo (incl. verified
store subs) > **account trial** > no access. A trial never overrides any
paid/granted source, and an expired trial never hides one.

### Purchase-platform semantics

`purchase_platform` = **where the paid subscription was purchased**:
`ios` | `android` | `web` for real purchases. It is **`null`** (never the
text `none`) for: trial, Internal Unlimited, manual grants, support/beta
access, no entitlement. Display `null` as "Not applicable".

Available platforms remain the separate server booleans
`portal_access`, `can_use_ios_app`, `can_use_android_app` — never combine
the two concepts.

### Resolver response contract

`get_my_vinetrack_access()` keeps its first 33 columns byte-identical to
SQL 135 and appends **one** column:

- `expires_at timestamptz` — earliest known future expiry of the granted
  source (trial end / period+grace / manual grant expiry); on a
  trial-expired denial it carries the original trial end; `null` for
  open-ended grants.

### Trial history / audit

`admin_user_access_history(user_id, limit)` now includes:

- `account_created` (source `account`) with the trial window
- `trial_migrated` / `trial_started` / `trial_expired` / `trial_revoked`
  (source `billing_event`, provider `system`) — at most one
  migration/start event per user; resolver calls never spam events
- the existing entitlement grant/denial/source-change audit covers
  trial → paid conversion (`entitlement_source_changed`)

New admin mutation: `admin_revoke_account_trial(p_user_id uuid,
p_reason text) returns jsonb` — System Admin only, reason required,
audited.

---

## 2. Global licence pools (SQL 145)

### `admin_available_licence_pools(...)`

System-Admin-only, read-only, SECURITY DEFINER, paginated. Signature:

```sql
admin_available_licence_pools(
  p_search                text    default null,  -- owner name/email, vineyard name, subscription uuid
  p_vineyard_id           uuid    default null,
  p_plan_code             text    default null,
  p_billing_owner_user_id uuid    default null,
  p_has_available_seats   boolean default null,
  p_limit                 integer default 50,    -- clamped to 200
  p_offset                integer default 0
)
```

Returns one row per eligible pool:

| Column | PostgreSQL type |
|---|---|
| `subscription_id` | uuid |
| `billing_owner_user_id` | uuid |
| `billing_owner_name` | text |
| `billing_owner_email` | text |
| `vineyard_id` | uuid |
| `vineyard_name` | text |
| `plan_code` | text |
| `subscription_status` | text |
| `billing_source` | text (`portal_subscription` \| `complimentary_team` \| `enterprise_contract` \| `manual`) |
| `provider` | text (`stripe` \| `manual`) |
| `licence_limit` | integer (null when unlimited) |
| `assigned_licences` | integer (ACTIVE assignments only) |
| `available_licences` | integer (null when unlimited) |
| `is_unlimited` | boolean |
| `starts_at` | timestamptz |
| `current_period_end` | timestamptz |
| `expires_at` | timestamptz |
| `is_assignable` | boolean |
| `not_assignable_reason` | text (null \| `not_started` \| `expired` \| `suspended` \| `no_seats_available`) |
| `total_count` | bigint (window count over the filtered set) |

Included: plan tier `team`/`enterprise` (portal Team, Enterprise,
`complimentary_team`, `enterprise_contract`). Excluded structurally:
solo/legacy plans, Apple/Google store subscriptions, Internal Unlimited,
Complimentary Solo, Beta Tester, Temporary/Support Access, the account
trial, sandbox rows, deleted rows, revoked grants, `canceled`/`expired`
rows.

### Assignment (`admin_assign_licence`, same signature as before)

Hardened: locks the pool row (`FOR UPDATE`) and re-checks seat
availability **inside** the transaction — concurrent assignments cannot
over-allocate; UI-supplied availability is never trusted. New error
codes: `pool_not_started`, `pool_expired`, `pool_suspended`,
`sandbox_subscription_not_assignable` (existing: `reason_required`,
`no_seats_available`, `store_subscription_not_licence_assignable`,
`user_not_found`, `subscription_revoked`). `admin_remove_licence` is
unchanged. Both continue to write billing events and refresh the
recipient's effective entitlement.

---

## 3. Portal UI notes

- The users directory (`admin_access_users`) now shows most users as
  **Active — Trial** (reason `active_trial`) or **Trial expired**
  (reason `expired`, source `trial`) instead of "No Access".
- Filters: `p_billing_source => 'trial'` and `p_status_filter => 'trial'`
  match the account trial; `p_status_filter => 'expired'` matches
  expired trials and expired subscriptions.
- For trial rows the directory's `current_period_end` carries the trial
  end so the existing "expires" column keeps working.
- Licence assignment UI should list pools from
  `admin_available_licence_pools` (globally), not from the selected
  user's own subscriptions.
