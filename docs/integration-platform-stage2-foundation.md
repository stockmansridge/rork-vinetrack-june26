# VineTrack Integration Platform — Stage 2: Database Foundation

Status: **SQL written, ready to apply** (sql/172 + rollback-only test suite)
Scope: database + permission + audit foundation ONLY. No public API endpoint,
no webhook dispatching, no UI, no operational-table changes.

Deliverables:

- `sql/172_integration_platform_foundation.sql` — the migration
- `sql/tests/172_integration_platform_tests.sql` — rollback-only security test suite
- this report

How to apply (same convention as SQL 143–171):

1. Open the Supabase SQL editor of the shared VineTrack project (`tbafuqwruefgkbyxrxyb`).
2. Run `sql/172_integration_platform_foundation.sql` (wrapped in one transaction; additive only).
3. Run `sql/tests/172_integration_platform_tests.sql`.
   Expected final output: `NOTICE: SQL 172 integration platform tests: ALL PASSED`
   followed by `ROLLBACK` — the tests create and discard all fixtures; no
   production row is touched.

---

## 1. Complete schema created

| Table | Purpose |
| --- | --- |
| `integration_scope_catalog` | Canonical catalogue of 28 grantable scopes (seeded). Scope grants FK here — free-text scopes are impossible. |
| `integration_webhook_event_catalog` | Canonical catalogue of 25 future webhook event names (seeded). Subscriptions FK here. |
| `integration_clients` | One row per integration: name, description, `integration_type` (`custom_api` / `custom_webhook` / `managed_integration`), `status` (`active` / `paused` / `revoked`), owning account, lifecycle timestamps. Check constraint keeps status and timestamps consistent. |
| `integration_api_keys` | Credential metadata: environment (`live`/`test`), display `key_prefix`, unique SHA-256 `key_hash`, optional label, created/expires/last-used/revoked timestamps. **No recoverable secret exists anywhere.** |
| `integration_client_vineyards` | Explicit vineyard grants (grantor, granted/revoked timestamps). Partial unique index: one ACTIVE grant per (integration, vineyard); revoked history retained. |
| `integration_client_scopes` | Explicit scope grants, FK to the scope catalogue, same active-uniqueness + history model. |
| `integration_audit_log` | Append-only management audit (12 action codes). UPDATE/DELETE blocked by trigger, even for the table owner. Never contains secrets. |
| `integration_api_requests` | Future API traffic diagnostics: method, canonical path, status, duration, error code. **No request/response bodies by design.** |
| `webhook_endpoints` | Future delivery targets. HTTPS-only URL check; stores signing-secret hash + display prefix only. |
| `webhook_subscriptions` | Future event subscriptions; event names FK-constrained to the catalogue; optional per-vineyard restriction; duplicate subscriptions blocked. |
| `integration_idempotency_keys` | Foundation for `Idempotency-Key` on future write endpoints (see §7). Unused in Stage 2. |

## 2. Ownership mapping

VineTrack has no separate organisations table. The canonical account anchor is
a **profile/user id** — the same convention as `vinetrack_subscriptions.owner_user_id`
and `vineyards.owner_id`. So `integration_clients.owner_user_id` is that anchor:
the integration belongs to the account, not to a session or a vineyard.

## 3. Access chain (the future request path)

```
API key ──> integration client ──> ACTIVE vineyard grant
                             └──> ACTIVE scope grant
        ──> VineTrack API layer ──> data
```

Proven invariants (all covered by tests):

- No path from an API key to vineyard data via the creating user's own
  membership. `integration_validate_api_request()` checks **only**
  `integration_client_vineyards` — never `vineyard_members`. Test T10 proves a
  vineyard the human owner controls but never granted is refused
  (`vineyard_not_granted`).
- Scope and vineyard checks are independent; neither substitutes for the other.
- Sensitive scopes (`labour:read`, `costs:read`, `team:read`) are flagged
  `is_sensitive` in the catalogue and are never implied by resource scopes
  (T8/T10 prove `trips:read` does not leak `costs:read`).
- Pause/revoke on the integration refuses API access immediately regardless of
  key validity (`integration_not_active`).

## 4. Human authority mapping (existing role system — nothing new invented)

| Existing role | Integration capability |
| --- | --- |
| Owner (`vineyard_members.role='owner'` or legacy `vineyards.owner_id`) | Create integrations; grant/revoke vineyards they own; grant/revoke scopes; create/revoke API keys; pause/reactivate/revoke; read audit. |
| Manager (of a vineyard with an ACTIVE grant) | View-only: list the integration, its grants/scopes and audit history. Cannot create integrations, issue credentials, grant anything, or list key metadata. |
| Supervisor / Operator | No integration access at all. |
| Platform admin (`is_system_admin()`, sql/062) | Full manage on any integration — but can never retrieve a plaintext secret (only hashes exist). |

Cross-account probing is blocked: "does not exist" and "not yours" raise the
identical `integration_not_found` error.

## 5. API key security model

- Secrets: `vt_live_<48 hex>` / `vt_test_<48 hex>` from `gen_random_bytes(24)`
  (cryptographically secure).
- Stored: SHA-256 hex hash (unique) + safe display prefix (`vt_live_ab12cd34`).
- The plaintext is returned **exactly once** by `integration_create_api_key()`
  and appears in no table, no audit row, no log (T9 scans the stored row and
  all audit metadata for the secret).
- Revocation sets `revoked_at` and keeps the row — full history, immediate
  refusal (T10).
- Expiry (`expires_at`) is checked independently at validation time.

## 6. RLS / lockdown model

- Catalogue tables: `SELECT` for authenticated (non-sensitive reference data).
- Every other integration table: RLS enabled with **no policies** and **all
  table privileges revoked** from `anon`/`authenticated`. The only path is the
  SECURITY DEFINER management RPC surface. Test T2 proves direct reads fail and
  vineyard grants cannot be forged by direct INSERT.
- `integration_validate_api_request()` is executable by `service_role` only
  (the Stage-3 API gateway); T15 proves authenticated clients cannot call it.

## 7. Idempotency (decision: foundation table created + documented)

`integration_idempotency_keys` is created now so the write-API stage has a
settled model:

- Uniqueness boundary: `(integration_client_id, idempotency_key)`.
- Stores reconciliation metadata only (method, canonical path, request hash,
  response status, created resource type/id, 24 h default expiry) — never
  payload bodies.
- Behaviour contract for the future write API: same key + same request hash →
  replay the stored result; same key + different hash → reject as a conflict.
  Nothing consumes this table in Stage 2.

## 8. Management RPC surface (14 functions, `authenticated`)

`integration_list_clients`, `integration_create_client`,
`integration_update_client`, `integration_set_status` (pause / reactivate /
revoke — revoked is terminal), `integration_list_vineyard_grants`,
`integration_grant_vineyard`, `integration_revoke_vineyard`,
`integration_list_scopes`, `integration_grant_scope`,
`integration_revoke_scope`, `integration_list_api_keys` (metadata only, never
hashes), `integration_create_api_key` (one-time secret),
`integration_revoke_api_key`, `integration_audit_history`.

Every state change writes an audit row (12 action codes; `api_key.rotated` is
reserved for a future rotation flow).

## 9. Provenance audit of existing operational tables (findings)

Audited: `pins` (sql/004), `trips` (sql/006), `work_tasks` (sql/014),
`spray_jobs` (sql/032), fuel, irrigation, pruning, yield tables.

- All carry `created_by` / `updated_by` (auth.users) + timestamps, but **none
  has an origin/channel column** — today every row is implicitly first-party
  (iOS/Android/portal are indistinguishable from each other and from any
  future API write).
- Existing precedents for the pattern: `email_delivery_events.source_platform`
  (sql/121) and session telemetry `app_platform`/`app_version` (sql/094, 154).
- **Recommendation (required before any external write endpoint):** add
  nullable `created_source text check (created_source in
  ('ios','android','portal','api','import','system'))` and
  `created_integration_client_id uuid references integration_clients(id)` to
  each externally writable operational table. Null = legacy first-party rows;
  no backfill needed; purely additive. Deliberately **not** included in
  Stage 2 (the brief forbids operational-table changes, and the first API
  release is read-only).

## 10. Explicitly NOT in this stage

- No public `/v1` endpoint exists; nothing serves external requests.
- No webhook HTTP is sent; endpoints/subscriptions are inert configuration.
- Write scopes are catalogued but no external write behaviour exists.
- Usable webhook signing secrets are NOT in the database — the dispatch stage
  must keep them in secure server-side storage (e.g. Vault); only hash +
  prefix are stored now.
- No UI (portal/iOS/Android) and no changes to any existing table, RPC or
  policy — the migration is purely additive (verified: existing-RLS test T16).

## 11. Test suite summary (sql/tests/172, rollback-only)

16 test groups / ~60 assertions: object existence + catalogue seeds (T1),
client-side lockdown & forgery prevention (T2), creation + audit (T3),
cross-account isolation without ID probing (T4), explicit vineyard grants
(T5), Manager view-only boundary (T6), Supervisor/Operator exclusion (T7),
catalogue-checked scopes and sensitive-scope separation (T8), hash-only key
storage & one-time secret (T9), the five independent validation failures
(T10), lifecycle incl. terminal revoke (T11), append-only audit (T12), webhook
schema constraints (T13), idempotency uniqueness (T14), service-role-only
validation (T15), existing-RLS safety (T16). Final `ROLLBACK` discards all
fixtures.

## 12. Recommended next stages

1. **Stage 3 — read-only API gateway**: service-role edge/worker layer calling
   `integration_validate_api_request()`, logging to
   `integration_api_requests`, serving the read scopes.
2. **Portal UI** for integration management on the existing Lovable portal
   (RPCs are the complete contract).
3. **Provenance columns** (§9) + write scopes + idempotency enforcement.
4. **Webhook dispatcher** with Vault-held signing secrets, retries and
   delivery logging.
