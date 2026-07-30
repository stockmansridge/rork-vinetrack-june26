# User Activity Client Telemetry — Lovable Portal Contract

Backend: SQL 154 (`sql/154_user_activity_client_telemetry.sql`). Apply it before building the portal side.

This contract covers two portal responsibilities:

1. **Reporting** — the portal is itself a telemetry client and must send heartbeats (`app_type = portal-web`).
2. **Display** — the System Admin User Activity page consumes the updated activity RPC and the new device-detail RPC.

RevenueCat purchase platform remains billing information only. Never derive device activity from where the customer paid.

---

## 1. Heartbeat RPC (portal reporting)

```
record_my_client_activity(
  p_client_instance_id uuid,      -- required, random browser installation id
  p_app_type           text,      -- 'portal-web'
  p_platform           text,      -- 'web'
  p_device_family      text,      -- 'Desktop' | 'Tablet' | 'Mobile'
  p_device_model       text,      -- browser-safe device category, e.g. 'Desktop'
  p_os_name            text,      -- 'Windows' | 'macOS' | 'Linux' | 'Android' | 'iOS' | 'Other'
  p_os_version         text,      -- safe parsed version or null
  p_app_version        text,      -- portal release/version where available
  p_app_build          text,      -- null is fine for the portal
  p_browser_name       text default null,   -- 'Chrome', 'Safari', ...
  p_browser_version    text default null,
  p_vineyard_id        uuid default null    -- currently selected vineyard
) returns jsonb   -- { "ok": true, "client_count": <int> }
```

Rules enforced server-side (do not rely on the client):

- `auth.uid()` only — there is no user-id parameter and client-supplied user IDs are impossible.
- Anonymous calls are rejected (`42501`).
- Only the pairs `ios/ios`, `android/android`, `portal-web/web` are accepted; anything else raises `invalid_app_platform` (`22023`).
- All text is trimmed, control-characters stripped, and length-limited (model 80, browser name 60, everything else 40 chars).
- `p_vineyard_id` is stored only when the caller is a member/owner of that vineyard; a foreign ID is silently dropped (the heartbeat still succeeds).
- Upsert by `(user, client_instance_id)`: repeated heartbeats update `last_seen_at` and metadata; `first_seen_at` is preserved.
- History is bounded server-side to the newest 10 clients per user.
- `browser_name`/`browser_version` are only stored for `portal-web`.

### Browser installation ID

- Generate a random UUID with `crypto.randomUUID()` once and keep it in `localStorage` (e.g. key `vinetrack.telemetry.clientInstanceId`).
- Never use fingerprinting, hardware identifiers, or anything derived from the user.
- Keep the ID across logout; a different account on the same browser creates its own separate server-side association automatically.
- On logout / account switch, clear only the throttle bookkeeping (last-sent time / signature), not the installation ID.

### Parsing device metadata

Parse and sanitise in the portal client — do not send raw user-agent strings:

- `device_family`: coarse category from UA-CH / viewport (`Desktop`, `Tablet`, `Mobile`).
- `os_name`: one of the allowed display names above; use `Other` when unsure.
- `os_version`: major version where safely available (e.g. `11`, `14.5`), else null.
- `browser_name`/`browser_version`: major browser and major version only.

### Throttling (portal)

- Send one heartbeat after the authenticated session loads.
- Send once per browser session thereafter, plus at most every 15 minutes while the tab is actively used.
- Send immediately when the selected vineyard changes or the portal release/version changes (material metadata change).
- Never poll in a background/hidden tab; never block login or navigation on the heartbeat — fire-and-forget with a conservative retry (next natural trigger).

---

## 2. User Activity list RPC (System Admin page)

```
admin_list_user_login_activity(
  p_app_type    text        default null,  -- 'ios' | 'android' | 'portal-web'
  p_platform    text        default null,  -- 'ios' | 'android' | 'web'
  p_os_name     text        default null,  -- exact, case-insensitive ('iOS', 'Android', 'Windows', ...)
  p_seen_since  timestamptz default null,  -- last_client_seen_at >=
  p_seen_before timestamptz default null,  -- last_client_seen_at <
  p_app_version text        default null   -- exact
)
```

System-Admin-only (`42501` otherwise). The existing zero-argument call still works and returns every user.

Return columns — the first 14 are **unchanged** from the previous version:

| column | notes |
|---|---|
| `user_id, email, display_name, account_created_at, last_sign_in_at` | unchanged |
| `vineyard_ids, vineyard_names, roles` | unchanged |
| `app_platform, app_version, app_build, device_model, os_version` | legacy support-request metadata — prefer the new fields below |
| `status` | `never / active_recent / active_30d / inactive_30d / inactive_90d` |
| **`last_app_type`** | `ios` / `android` / `portal-web`, or null |
| **`last_platform`** | `ios` / `android` / `web`, or null |
| **`last_device_family`** | `iPhone` / `iPad` / `Phone` / `Tablet` / `Desktop` / `Mobile` |
| **`last_device_model`** | e.g. `iPhone16,2`, `Samsung SM-S928B`, `Desktop` |
| **`last_os_name`**, **`last_os_version`** | e.g. `iOS` + `18.6` |
| **`last_app_version`**, **`last_app_build`** | most recent client's app version |
| **`last_client_seen_at`** | timestamptz of the most recent heartbeat |
| **`client_count`** | integer, 0 when the user has never sent a heartbeat |

### Null semantics — "Not recorded"

All `last_*` fields are null (and `client_count = 0`) for users who have not yet sent a heartbeat. Display **Not recorded** — never "Unknown", and never substitute the purchase platform.

### Recommended display mapping

- App: `ios → iOS`, `android → Android`, `portal-web → Portal`
- Platform: `ios → iOS`, `android → Android`, `web → Web`
- Device: `last_device_model` (fallback `last_device_family`)
- OS: `last_os_name + ' ' + last_os_version` (e.g. `iOS 18.6`, `Android 16`, `Windows 11`)

Filters are server-side — pass the RPC params above. Do not add client-side global filters over a paginated/complete server result.

---

## 3. Device-detail RPC (per-user history)

```
admin_user_client_activity(p_user_id uuid)
```

System-Admin-only. Returns the user's recorded clients (newest first, bounded to 10):

| column | notes |
|---|---|
| `client_reference` | redacted stable reference (`client-a1b2c3d4`) — the raw installation UUID is never returned |
| `app_type, platform, device_family, device_model` | as reported |
| `os_name, os_version, app_version, app_build` | as reported |
| `browser_name, browser_version` | portal clients only, else null |
| `first_seen_at, last_seen_at` | timestamptz |
| `last_vineyard_name` | vineyard the client last reported (membership-validated), or null |
| `is_current` | true only on the most recently seen client |

---

## 4. Error mapping

| error | portal message |
|---|---|
| `42501` (list/detail/prune) | Only a System Administrator can view user activity. |
| `42501` (heartbeat) | silent — user is signed out; do not surface |
| `invalid_app_platform` / `invalid_client_instance` (`22023`) | silent — log to console, fix the payload; never show to the user |
| network failure on heartbeat | silent, retry at the next natural trigger |

Never display raw SQL errors.

---

## 5. Retention & privacy (for the privacy policy)

- One row per user + installation; bounded to the **newest 10 clients per user** (older rows are pruned automatically on heartbeat).
- Clients not seen for **24 months** can be purged with the admin-only `prune_stale_user_clients()` helper.
- Rows are deleted when the account is deleted (FK cascade).
- Stored: app type, platform, device family, sanitised model, OS name/version, app version/build, browser name/version (portal only), first/last-seen timestamps, last vineyard.
- Never stored: IMEI, serial numbers, MAC addresses, advertising IDs, precise location, personal device names, raw IP addresses, raw user agents.
- The table has RLS enabled with **no** client policies — all access is through the RPCs above.

---

## 6. Suggested query keys

```
["admin", "user-activity", filters]
["admin", "user-activity", "clients", userId]
```

Invalidate the list after changing filters; clear all admin activity query data on logout or account switch.
