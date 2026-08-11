# VineTrack API & Webhooks — Changelog

The canonical developer-facing change history for the VineTrack public
API and webhook platform. Newest entries first.

Categories: `added` | `changed` | `fixed` | `deprecated` | `removed` |
`security` | `docs`.

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
- No public write endpoints exist in v1.
