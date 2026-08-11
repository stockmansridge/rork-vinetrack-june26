# VineTrack API & Webhooks — Changelog

The canonical developer-facing change history for the VineTrack public
API and webhook platform. Newest entries first.

Categories: `added` | `changed` | `fixed` | `deprecated` | `removed` |
`security` | `docs`.

---

## 2026-08-11 — v1 Stage 8 (controlled external write API)

### added

- **Write API** — first production write surface, 8 routes (no DELETE):
  - `POST /v1/work-tasks`, `PATCH /v1/work-tasks/{work_task_id}` (`work_tasks:write`)
  - `POST /v1/fuel-records`, `PATCH /v1/fuel-records/{fuel_record_id}` (`fuel:write`; operational entry only — no cost fields)
  - `POST /v1/irrigation-records` (`irrigation:write`; create-only — VineTrack's calculation core derives volume, allocations and vintage)
  - `POST /v1/growth-stages` (`growth_stages:write`; create-only, catalogue E-L codes only)
  - `POST /v1/yield-records`, `PATCH /v1/yield-records/{yield_record_id}` (`yield:write`; canonical per-block shape)
- **Idempotency** — every POST requires an `Idempotency-Key` header;
  durable database-backed replay (same key + payload → original result +
  `Idempotency-Replayed: true`; different payload → `409
  idempotency_conflict`; missing → `400 idempotency_required`).
- **Optimistic concurrency** — every PATCH requires
  `expected_updated_at`; mismatch → `409 conflict` (external writes never
  silently overwrite newer in-app edits).
- **Provenance** — `origin` (`vinetrack` | `integration`) and
  integration-scoped `external_id` on work tasks, fuel records,
  irrigation records, growth stages and yield records; returned on all
  read/write responses. API-created records are never attributed to a
  human user.
- **New error codes** — `validation_failed` (422, field-level `details`),
  `idempotency_required` (400), `idempotency_conflict` (409), `conflict`
  (409).
- **Webhook payload provenance** (additive, backwards-compatible) — event
  `data` now carries `origin`, plus `external_id` when set, enabling
  receiver-side loop prevention. Signature scheme, headers, retry policy
  and `api_version` are unchanged.

### changed

- `method_not_allowed` (405) no longer claims the API is read-only;
  unsupported methods on known routes return 405, unknown paths 404.
- Activated the catalogue descriptions for the five write scopes.
- Pins remain **read-only** (`pins:write` stays reserved): pin placement
  is device-resolved at capture time and no server-side placement
  resolver exists.

---

## 2026-08-11 — v1 (initial public developer-platform release)

### added

- **Read-only REST API v1** — 30 routes under `/v1/`:
  - Core: `/v1/me`, `/v1/vineyards`(+`/{id}`), `/v1/blocks`(+`/{id}`)
  - Operations: `/v1/trips`, `/v1/spray-jobs`, `/v1/fuel-records`,
    `/v1/fuel-purchases`, `/v1/equipment` (each +`/{id}`)
  - Vineyard records: `/v1/work-tasks`, `/v1/pruning`,
    `/v1/irrigation-records`, `/v1/growth-stages`, `/v1/yield-records`,
    `/v1/pins` (each +`/{id}`)
  - Environmental: `/v1/weather`, `/v1/rainfall`, `/v1/disease-risk`
    (list/singleton only)
- **Authentication**: `Authorization: Bearer vt_live_…` / `vt_test_…`
  API keys — hashed at rest, shown once, revocable, optional expiry.
- **Access model**: explicit vineyard grants + explicit scopes (15
  resource read scopes; additive sensitive scopes `costs:read`,
  `labour:read`).
- **Pagination**: opaque cursor keyset pagination, default 100 / max
  1000 per page.
- **Rate limiting**: 300 requests/minute/API key with
  `X-RateLimit-Limit`, `X-RateLimit-Remaining` and `Retry-After` on 429.
- **Webhooks v1** — 26-event catalogue across `trip.*`, `spray_job.*`,
  `fuel_log.*`, `fuel_purchase.created`, `work_task.*`,
  `pruning_activity.*`, `irrigation_record.*`, `growth_stage.recorded`,
  `yield_record.*`, `pin.*`, `block.*` and `webhook.test`; HMAC-SHA256
  signatures (`v1=` scheme), at-least-once delivery, 7-attempt retry
  schedule (1m/5m/30m/2h/12h/24h), replay, test webhooks, automatic
  endpoint disable after 10 consecutive failures.

### docs

- Canonical developer guide: `docs/vinetrack-developer-platform.md`.
- OpenAPI 3.1 specification: `docs/openapi/vinetrack-v1.yaml`.
- Machine-readable event catalogue:
  `docs/webhooks/vinetrack-events-v1.json`.
- Postman collection:
  `docs/postman/VineTrack-v1.postman_collection.json`.
- Deep references: `docs/vinetrack-api-v1.md`,
  `docs/vinetrack-webhooks.md`.

### notes

- `spray_job.created` is catalogued but **not emitted** in v1
  (reserved — spray records represent completed applications).
- `team:read` is catalogued but not used by any route or event in v1.
- No public write endpoints existed in the initial release (superseded by
  the Stage 8 entry above).
