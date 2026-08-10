# VineTrack Integration Platform — Stage 3D Completion Report

Environmental & advisory read API: `/v1/weather`, `/v1/rainfall`,
`/v1/disease-risk` on the existing `vinetrack-api` gateway. Read-only; no
write API, no webhook delivery, no Lovable UI, no iOS/Android UI changes,
no new disease models, no arbitrary-coordinate weather proxying.

Supabase project: `tbafuqwruefgkbyxrxyb`.

---

## 1. Files changed

| File | Change |
| --- | --- |
| `supabase/functions/vinetrack-api/index.ts` | 3 new routes + environmental helpers (cache, coordinate resolution, provider fetchers, disease models); 1 new error code; Stage 3A–3C code behaviour untouched |
| `sql/176_integration_api_stage3d_environment.sql` | NEW — environment cache table + service-role rainfall reader (see §2) |
| `sql/tests/176_integration_api_stage3d_environment_tests.sql` | NEW — 12 read-only verification checks |
| `scripts/test-vinetrack-api.sh` | Stage 3D sections (~40 new checks) + fixture doc update |
| `docs/vinetrack-api-v1.md` | Weather/rainfall/disease-risk contracts, freshness policy, provider abstraction, units, error/scope tables, curl examples |
| `docs/vinetrack-api-openapi.yaml` | 3 new paths + 8 new schemas (now 30 routes) |
| `docs/integration-platform-stage3d-report.md` | This report |

No proxy edge function, disease algorithm, rainfall upsert path, or
app-facing RPC was modified. No mobile code was touched.

## 2. SQL migration added

`sql/176_integration_api_stage3d_environment.sql` — strictly additive,
idempotent, production-safe; does not touch SQL 172–175:

1. **`integration_environment_cache`** — one row per (vineyard, kind ∈
   `forecast` | `disease_risk`), `payload jsonb`, `fetched_at`. RLS on
   with NO policies and no anon/authenticated grants — service-role
   (gateway) only. This is the upstream-protection layer (§17/§19 of the
   brief): the public API can trigger at most one provider request per
   vineyard per TTL window. Payloads contain only the normalised external
   contract — never credentials or raw provider payloads.
2. **`integration_get_rainfall(p_vineyard_id, p_from, p_to, p_before, p_limit)`**
   — SECURITY DEFINER, revoked from public/anon/authenticated, granted to
   service_role only. Returns the priority-resolved daily rainfall series
   (`distinct on (date)`, priority `manual` > `davis_weatherlink` >
   `wunderground_pws` > `open_meteo` — the exact contract of
   `get_daily_rainfall`, sql/028–030) with keyset pagination date DESC,
   capped at 1001 rows. Unlike the app RPC it lists observations (no
   empty calendar rows) and relies on the gateway's SQL 172 five-check
   validation instead of `auth.uid()` membership.

Apply via the Supabase SQL editor, then run `sql/tests/176`.

## 3. Canonical weather source audit

| Aspect | Finding |
| --- | --- |
| Current observations | `vineyard_weather_observations` (sql/026 + sql/104) — the ONLY canonical stored observation source. Written exclusively by the `davis-proxy` edge function (Davis WeatherLink v2); one row per (vineyard, source). Fields already normalised METRIC at ingestion (°F→°C, mph→km/h, in→mm): temperature_c, humidity_pct, wind_speed_kmh, wind_gust_kmh (= Davis high over last 10 min, sql/104), wind_direction_deg, rain_today_mm, rain_rate_mm_per_hr, leaf_wetness (measured sensor), observed_at (station time), fetched_at (cache time), station_id/name, raw_payload (scrubbed jsonb — NOT exposed). |
| Cache behaviour | The app RPC `get_vineyard_current_weather` is **cache-only by design** — it never triggers an upstream Davis fetch; the davis-proxy is the only writer. Stage 3D preserves this exactly. Canonical stale threshold: **20 minutes**, statuses `ok` / `no_data` / `not_configured`. |
| Forecast | Two canonical providers, selected by `vineyards.forecast_provider` (sql/061: `auto` \| `open_meteo` \| `willyweather`). WillyWeather: **global** `WILLYWEATHER_API_KEY` secret (per-vineyard keys deprecated), per-vineyard location saved in `vineyard_weather_integrations` (provider `willyweather`; station_id = WW location id, station_name/lat/lon cached); combined call `forecasts=rainfall,temperature,wind,rainfallprobability`, live-fetched by the proxy with NO DB cache today; normalisation: rainfall range midpoint, probability, tmin/tmax, max wind, Hargreaves ET0 estimate. Open-Meteo: free, keyless, fetched directly by the apps (daily `precipitation_sum`, `wind_speed_10m_max`, `temperature_2m_min/max`, `et0_fao_evapotranspiration` across the rain/degree-day/irrigation features). |
| WU weather-current | The `weather-current` function (Weather Underground PWS by lat/lon) is a device-location current-conditions helper, NOT a vineyard-canonical store — deliberately not exposed. |
| Location semantics | No lat/lon columns exist on `vineyards`. Server-side canonical resolution order (open-meteo-proxy): weather-integration station coords → paddock polygon centroid → pin centroid. WillyWeather forecasts represent the saved town/location. |

## 4. Canonical rainfall source audit

`rainfall_daily` (sql/028–031): persistent per-(vineyard, date, source,
station) daily rainfall. Sources write independently and never touch each
other's rows; read-time priority `manual(1)` > `davis_weatherlink(2)` >
`wunderground_pws(3)` > `open_meteo(4)`. Manual rows soft-delete only;
provider rows indefinite retention (sql/031 contract). Open-Meteo gap-fill
skips today/yesterday and refuses to write over better sources —
**everything in this table is observed rainfall**, never forecast. Units:
mm, `numeric(8,2)`, `>= 0`. Index `(vineyard_id, date desc)` already
supports the new reader — no new index needed.

## 5. Canonical disease-risk source audit

- Risk is computed **client-side** in both apps from a shared MVP
  calculator (Android `DiseaseRiskCalculator.kt`, ported 1:1 from iOS):
  exactly **three models** — downy mildew (simplified 10:10:24: ≥10 mm
  rain + min ≥10°C + ≥10 wet hours in 48 h; high at ≥20 mm and ≥18 wet
  hours), powdery mildew (simplified Gubler-Thomas: days in last 72 h with
  ≥6 consecutive hours at 21–30°C and RH ≥60%; medium at 3 days, high if
  also latest temp ≥25°C), botrytis (simplified Broome/Bulit: wet hours at
  15–25°C over 36 h; medium ≥15, high ≥24).
- Inputs: Open-Meteo hourly `temperature_2m`, `dew_point_2m`,
  `relative_humidity_2m`, `precipitation` (past 3 days), coordinates =
  vineyard/station location.
- Wetness is the canonical **estimated proxy** (sql/019: rain > 0 OR RH ≥
  90% OR T−dewpoint ≤ 2°C) — never presented as measured leaf wetness.
- **No storage**: results are computed on demand; no historical risk
  exists anywhere. The apps' 10/60/90 "score" is a chart index derived
  from the severity tier — not a canonical score.
- No model version exists today; sql/019 only stores per-vineyard alert
  preferences (not exposed — they are notification settings, not risk).

## 6. Routes implemented

- `GET /v1/weather?vineyard_id=` — singleton (`data` + `meta`, not paginated)
- `GET /v1/rainfall?vineyard_id=[&from=&to=&limit=&cursor=]` — collection
- `GET /v1/disease-risk?vineyard_id=` — singleton

All run the full five-check chain (key → integration active → key
active/unexpired → scope → explicit vineyard grant) via SQL 172's
canonical validator, plus the shared rate limit. `vineyard_id` is required
everywhere; `/v1/weather/{anything}` returns `resource_not_found`;
`lat`/`lon` (or any unknown parameter) → `invalid_request`. No
cross-vineyard environmental collections exist.

## 7. Scope mapping

| Route | Scope |
| --- | --- |
| `/v1/weather` | `weather:read` |
| `/v1/rainfall` | `rainfall:read` |
| `/v1/disease-risk` | `disease_risk:read` |

All three already existed in the SQL 172 scope catalogue — no scope
migration needed. Scopes never imply each other (harness-tested:
blocks-only key gets 403 on all three). `costs:read` / `labour:read` are
irrelevant here and never affect access — no environmental field is
cost- or labour-bearing.

## 8. Weather external schema

```json
{
  "data": {
    "vineyard_id": "…",
    "current": { "temperature_c", "humidity_percent", "wind_speed_kmh",
      "wind_gust_kmh", "wind_direction_degrees", "wind_direction",
      "rainfall_today_mm", "rainfall_rate_mm_per_hour", "leaf_wetness",
      "observed_at", "fetched_at", "is_stale",
      "source": { "provider": "davis_weatherlink", "station_id", "station_name" } },
    "current_status": "ok | no_data | not_configured",
    "forecast": [ { "date", "rain_mm", "rain_probability_percent",
      "temp_min_c", "temp_max_c", "wind_speed_max_kmh", "et0_mm" } ],
    "forecast_status": "ok | stale | unavailable | not_configured",
    "forecast_source": { "provider", "location": { "latitude", "longitude",
      "label", "basis" }, "horizon_days", "fetched_at", "is_stale" }
  },
  "meta": { "generated_at" }
}
```

Only canonical fields are exposed — no `apparent_temperature_c` or
`pressure_hpa` was invented (neither exists in VineTrack's stores).
Missing readings are `null`, never zero (VineTrack's missing-data rule).

## 9. Rainfall external schema

`{ date, rainfall_mm, source, station: { id, name } | null, notes,
updated_at }` — one record per vineyard-local day with data, newest first,
standard collection envelope. `source` ∈ `manual` | `davis_weatherlink` |
`wunderground_pws` | `open_meteo` (manual/provider provenance per §9 of
the brief). Daily records only — no silent aggregation (brief §10 option
A); consumers aggregate. Filters: `from`/`to` inclusive ISO dates
(validated, `from>to` rejected), `limit`, opaque date-keyed `cursor`.

## 10. Disease-risk external schema

`data`: `vineyard_id`, `calculated_at`, `model_version` (`mvp-1`),
`wetness_source` (`estimated_proxy`), `weather_source` (`provider`,
coarse `location` + `basis`, `fetched_at`, `observed_through`,
`hours_used`, `source_status` ∈ `ok`|`stale_fallback`), `risks[]` with
`{ disease, risk_level (low|medium|high), summary, window_hours, inputs }`.
Per-model inputs: downy `{rainfall_mm, min_temperature_c, wet_hours}`;
powdery `{favourable_days_of_last_3, latest_temperature_c}`; botrytis
`{wet_hours_15_to_25_c}`. **No numeric score** — the 10/60/90 chart index
would be manufactured pseudo-precision. Only the three implemented
diseases are returned. Advisory text is the models' canonical one-line
`summary`; no AI-generated agronomy advice.

## 11. Observed vs forecast behaviour

Never mixed. `current` = the vineyard's own station observation (separate
provenance + status + timestamps); `forecast` = provider forecast items
with explicit dates; `/v1/rainfall` = observed rainfall ONLY (forecast
rain lives solely in `forecast[].rain_mm`, labelled as forecast).
WillyWeather/Open-Meteo forecast provenance is preserved via
`forecast_source.provider`.

## 12. Freshness / staleness contract

| Data | Fresh window | Stale behaviour |
| --- | --- | --- |
| Current observation | 20 min (canonical, sql/026) | Always served with `is_stale: true` when older — a station reading is history, not a fallback |
| Forecast | 3 h server cache TTL | Upstream failure → last same-provider bundle served, `forecast_status: "stale"` + `is_stale: true`; no cache → `"unavailable"` (still HTTP 200 — current may exist) |
| Disease risk | 30 min compute TTL | Upstream failure → last assessment ≤ 24 h served with `source_status: "stale_fallback"` + `meta.is_stale: true`; otherwise 503 `disease_risk_unavailable` |

Every environmental response carries explicit freshness metadata
(`observed_at`/`fetched_at`/`is_stale` per section, `meta.generated_at`,
`meta.source_updated_at`). **Stale fallback is a 200, not an error** —
documented in both docs and OpenAPI.

## 13. Provider abstraction

All external field names are VineTrack-normalised (`wind_speed_kmh`,
`rain_mm`, `temp_min_c`, …) and survive a provider change. Safe provider
metadata only: `provider` name, station id/name, coarse location. NOT
exposed: API keys/secrets (credential presence is tested with NOT-NULL
filters — values are never selected into the gateway), signed URLs,
`raw_payload`, provider debugging payloads, upstream error bodies
(gateway logs upstream HTTP status only). WillyWeather normalisation
(rain midpoint, ET0 estimate, temp/wind extremes) is ported 1:1 from the
canonical proxy so the API shows the same numbers as the apps.

## 14. Units / conversions

Metric everywhere: °C, mm, mm/h, km/h, %, ET0 mm. Imperial→metric happens
once, deterministically, in the canonical ingestion proxies (Davis °F/mph/
inches) — the API performs no unit conversion. Coordinates are rounded to
2 dp (~1 km) externally — coarse weather location, never precise private
geometry (brief §7). Wind semantics documented per §8: current
`wind_speed_kmh` = station current wind; `wind_gust_kmh` = Davis high over
last 10 min (sql/104 mapping); forecast `wind_speed_max_kmh` = daily max.

## 15. Disease model / version handling

No algorithm was changed. A `model_version` identifier (`mvp-1`, a
gateway constant — no schema change needed since results aren't stored)
now lets consumers interpret future model evolution safely; the docs
commit to bumping it whenever the shared models change. `window_hours`
and `wetness_source` complete the interpretability contract. Historical
risk does not exist and is not pretended (brief §15): current assessment
only, no date filter.

## 16. Filters / pagination

- `/v1/rainfall`: allowlist `vineyard_id`, `from`, `to`, `limit`,
  `cursor`; real-date validation identical to 3B/3C; date-keyed opaque
  keyset cursor (date DESC), default 100 / max 1000. Documented as the
  one cursor variant (the daily series has no per-row uuid after source
  resolution).
- `/v1/weather`, `/v1/disease-risk`: allowlist `vineyard_id` only;
  singleton `data` + `meta` (no pagination object — operational
  pagination metadata is not reused where it makes no sense, brief §16).
- Unknown parameters rejected with `invalid_request` on all three.

## 17. Cache / upstream rate behaviour

- Public API **never** triggers a Davis fetch (cache-only reads — same as
  the app RPC).
- Forecast: ≤ 1 WillyWeather or Open-Meteo request per vineyard per 3 h,
  via `integration_environment_cache` (provider-switch invalidates).
- Disease risk: ≤ 1 Open-Meteo hourly request per vineyard per 30 min.
- Upstream fetches carry an 8 s timeout; failures fall back to marked
  stale cache. Concurrent first requests may double-fetch once per TTL
  window (accepted, documented — no lock needed at this volume).
- The existing 300 req/min per-key limit is unchanged and applies before
  any upstream work. Result: API traffic cannot multiply provider costs
  or breach provider limits (brief §19), and API reliability is never
  worse than the current app experience (brief §18).

## 18. API logging

Unchanged canonical system (`integration_log_api_request`). New templates:
`/v1/weather`, `/v1/rainfall`, `/v1/disease-risk`; vineyard id stored in
its own column. Weather-provider payloads and credentials are never
logged (gateway logs upstream HTTP status codes only).

## 19. Automated test results

- `deno check supabase/functions/vinetrack-api/index.ts` — **passes**.
- `bash -n scripts/test-vinetrack-api.sh` — **passes**.
- `docs/vinetrack-api-openapi.yaml` — **YAML validates**.
- `sql/176` — dollar-quoting balanced; `sql/tests/176` (12 checks:
  table/RLS/no-policies/no-grants/unique/CHECK, function
  signature/definer/grants, smoke test, priority body) ready to run in
  the SQL editor after applying the migration.
- Harness now ≈165 checks. Stage 3D sections cover every brief item
  (§24–26): scope + grant enforcement per route, cross-vineyard denial,
  freshness metadata presence, unit field names, provider-secret /
  raw-payload leak checks, observed-vs-forecast separation, rainfall
  provenance family + mm units + descending dates + range filtering +
  date-cursor iteration + invalid cursor, disease model set exactness,
  risk-level domain, no-score assertion, model_version + wetness + weather
  provenance, 503 `disease_risk_unavailable` stable-error path, lat/lon
  rejection, unknown-param rejection, 405s, and no-{id}-form 404.
- Live execution requires the deployed function + fixtures (sandbox has
  no network to the project). Run after deploying (see §Go-live).

## 20. Prior-stage regression

The harness runs the FULL Stage 3A/3B/3C suite in the same invocation —
`/v1/vineyards`, `/v1/blocks` (3A); trips, spray jobs, fuel records, fuel
purchases, equipment (3B); work tasks, pruning, irrigation, growth
stages, yield, pins (3C); plus invalid/revoked/expired keys, paused and
revoked integrations, wrong scope, ungranted vineyard, rate-limit
headers, JSON error envelope (incl. the 403-body regression), 405s, and
logging via request-id header. No Stage 3A–3C handler, mapper, or route
was modified; only additive code paths were introduced.

## 21. Docs / OpenAPI updates

`docs/vinetrack-api-v1.md`: title, error table (+ `disease_risk_unavailable`
and the stale-is-not-an-error rule), scope table (30 routes), sensitive
matrix note, singleton/pagination notes, date-filter row, units section,
three full endpoint sections (freshness policy, provider abstraction,
location semantics, wind semantics, horizon, provenance, examples), three
curl examples, credentials snippet (+3 scopes), deployment notes (SQL 176 +
`WILLYWEATHER_API_KEY`). `docs/vinetrack-api-openapi.yaml`: 3 paths, 3
tags, 8 schemas (WeatherDocument, CurrentWeather, ForecastDay,
ForecastSource, RainfallRecord, DiseaseRiskDocument, DiseaseRiskItem,
EnvironmentalMeta), updated error/scheme descriptions. Both explicitly
descriptive — the implementation remains canonical.

## 22. Provider / licensing constraints discovered

1. **WillyWeather** is a paid, key-metered Australian API using a single
   global VineTrack key — the 3-hour cache is what makes exposing it
   publicly safe. Redistribution of WW-derived data to third-party
   integrations should be confirmed against the WillyWeather licence
   before granting `weather:read` to external partners at scale.
2. **Open-Meteo** free tier is for non-commercial use with fair-use
   limits; the per-vineyard cache keeps volume trivial, but a commercial
   Open-Meteo plan is worth confirming as integration traffic grows.
3. **Davis WeatherLink** data comes from the vineyard's own station and
   credentials — no redistribution concern beyond the vineyard's consent,
   which the explicit grant model already encodes.
4. **Weather Underground** rainfall (`wunderground_pws` rows) is PWS data
   redistributed under WU's terms — same review note as (1).

## 23. Canonical environmental-data issues to fix separately

1. WillyWeather forecasts are live-fetched by the app proxy with no DB
   cache — the apps could reuse the new `integration_environment_cache`
   pattern (or share its bundle) to cut provider spend.
2. `vineyards` has no canonical lat/lon columns; location is inferred
   from station/blocks/pins. A first-class vineyard coordinate (plus an
   optional coarse "weather location") would remove ambiguity.
3. Disease-risk inputs come from Open-Meteo even when a Davis station
   with measured leaf wetness exists; sql/019 already reserves
   `disease_use_measured_wetness` — wiring it up would upgrade the models
   from proxy to measured wetness.
4. The apps compute disease risk client-side; now that the gateway hosts
   the same models server-side, the apps could eventually consume the
   shared cached result (one computation, identical numbers everywhere).
5. `weather-current` (WU by device lat/lon) bypasses the vineyard model
   entirely — candidate for consolidation into the integration/station
   framework.
6. Davis current observations keep only the latest row per station
   (upsert) — no observation history exists server-side; if hourly
   station history is ever wanted in the API it needs a new time-series
   store, not this cache.

## 24. Confirmation — no write API

The gateway still accepts GET (and CORS OPTIONS) only; every other method
returns 405 with the JSON envelope (harness-asserted on the new routes
too). The only writes the gateway performs are internal plumbing via
service role: the SQL 173 request log / rate-limit counters and the new
`integration_environment_cache` upserts — no caller-controlled data is
ever written, and no canonical table is writable through any route.

## 25. Confirmation — no webhook / UI work

No webhook dispatch or subscriptions were built (SQL 172's webhook tables
remain dormant). No Lovable integration UI, no mobile
integration-management UI, zero iOS/Android code changes, no new disease
models, no AI agronomy advice, no SWNZ/GFA/Vinsight connectors, no
arbitrary lat/lon lookup.

---

## Go-live checklist

1. Apply `sql/176_integration_api_stage3d_environment.sql` in the SQL
   editor; run `sql/tests/176_integration_api_stage3d_environment_tests.sql`
   (expect 12 × PASS).
2. Confirm the `WILLYWEATHER_API_KEY` function secret is present (it
   already serves the willyweather-proxy; without it WillyWeather-backed
   forecasts report `not_configured` and everything else still works).
3. Redeploy: `./scripts/deploy-edge-functions.sh` (no flag changes).
4. Grant the three new scopes to the test integration (snippet in
   `docs/vinetrack-api-v1.md`), then run `scripts/test-vinetrack-api.sh`
   — it executes the full 3A/3B/3C regression plus Stage 3D.

Stopping here for review — the Lovable portal stage is not started.
