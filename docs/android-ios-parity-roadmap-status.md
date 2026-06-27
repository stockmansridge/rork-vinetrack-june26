# Android ⇄ iOS Parity Roadmap — Audit / Design Note (Stage Q)

Internal status tracker for the **Android (`android-vinetrack`) → iOS benchmark
parity roadmap**. This is the **audit/design entry point (Stage Q-0)** opened
after the offline write-queue (Stages 4A–N) and read-cache/offline-restart
(Stages O–P) packages closed.

> **Direction:** the **existing iOS app (`ios/VineTrackV2`) is the benchmark.**
> Android is brought up to match it. **No iOS app changes. No Supabase
> schema/RLS/RPC changes. No Android code changes in Stage Q-0** (audit/design
> only — this note is the only artifact).

---

## Stage Q closure state

| Stage | Scope | Status |
|---|---|---|
| Q-0 | Full Android↔iOS parity audit + staged roadmap (this note). | **CLOSED / DESIGN ONLY** |
| Q-1 | Highest-value low-risk UI/data-contract polish. | **CLOSED** (Q-1b/c/d shipped, Q-1e QA+doc closure; see `android-q1-ui-polish-plan.md`) |
| Q-2 | Map / pin / row-path parity fixes. | **PLANNED — next recommended** |
| Q-3 | Trip detail-stream (GPS/row/tank) read parity. | **PLANNED — parked next** |
| Q-4 | Photo offline/read-cache parity (beyond pin photos). | **PLANNED** |
| Q-5 | Damage feature foundation (online CRUD + read). | **PLANNED** |
| Q-6 | Damage offline write + read-cache. | **PLANNED** |
| Q-7 | Report / export / admin / team parity. | **PLANNED** |
| Q-8 | Final QA / regression. | **PLANNED** |
| Q-9 | Documentation closure + parity checkpoint. | **PLANNED** |

---

## Areas / files inspected

- **Docs:** `android-offline-field-reliability-status.md`,
  `android-cost-rollup-status.md`, `android-map-pins-parity-status.md`,
  `ios-sync-status-parity-status.md`, `growth-stage-records-contract.md`,
  `supabase-schema.md`, `trip-report-export-spec.md`, `paddock-geometry-spec.md`.
- **Android:** `ui/screens/*` (24 screens), `ui/main` navigation, `data/*`
  (repositories, sync coordinators, caches, overlay), `data/model/Models.kt`.
- **iOS:** `App/*` (~110 files), `LegacyImported/Views/*` (19 feature folders),
  `LegacyImported/Models/*` (42 models), `Backend/Models`, `Backend/Repositories`,
  `Backend/Sync`.

This audit is structural (screen/model/repository inventory + existing contract
docs). It is sufficient to drive the staged roadmap; per-field contract
verification is folded into each implementation stage's own pre-work.

---

## Parity matrix by module

Legend: **Full** = at parity · **Near** = minor polish gap · **Partial** =
core present, meaningful gaps · **Missing** = no Android surface · **Ahead** =
Android ahead of iOS.

| Module | iOS surface | Android surface | Parity |
|---|---|---|---|
| Auth / login | NewBackendLogin, Apple sign-in, reset password | LoginScreen | **Near** |
| Dashboard / home | NewMainTabView, Home cards (rain/alerts/sync chip) | HomeDashboard | **Partial** |
| Vineyard / blocks / paddocks | Vineyard list/detail, BlocksHub, EditPaddock, BoundaryMapEditor | Blocks, BlockDetail | **Partial** (no paddock geometry editor) |
| Map | Google + offline vector map, block chips, pins, rows | VineyardMap (Google, 3D toggle) | **Near** (no offline vector map) |
| Pins | PinsView, PinDrop, duplicate warn, PinsPDFService | PinsScreen + offline queue | **Near** (no pin PDF) |
| Pin photos | Multi-photo, retry | One photo/pin + retry | **Partial** |
| Trips (active) | ActiveTripView, start/end, GPS/row/tank | TripsScreen + ActiveTripStore + queues | **Near** |
| Trips (history/detail) | TripDetailView w/ GPS/row/tank streams | List + snapshot cache | **Partial** (no detail-stream cache) |
| Spray records | Form, detail, program, calculator | Sprays, SprayManagement, Calculator | **Near** |
| Spray program/templates | SprayProgramView, saved inputs | SprayManagement + presets | **Near** |
| Fuel | Fuel, FuelPurchases, FuelLog | FuelLog + queue | **Partial** (no fuel purchases UI) |
| Work tasks | Hub, AddEdit, machine line, calculator | WorkTasks + queues + line cache | **Near** |
| Maintenance | List/detail/add-edit | Maintenance + queue + cache | **Full** |
| Yield | Estimation, sampling, determination calc, reports, actual | YieldScreen + queue + cache | **Partial** |
| Growth stages | Records list, report, EL confirm, images | Growth + queue + cache | **Near** (photos online-only) |
| Phenology / ripeness / GDD | OptimalRipenessHub, RipenessSurfaces, GDD, budburst | — | **Missing** |
| Damage | DamageRecordsList, RecordDamage | — | **Missing** |
| Weather / rain | Davis/WillyWeather/Wunderground/OpenMeteo, rain calendar, forecast | WeatherHourly, DiseaseRisk, Irrigation | **Partial** |
| Irrigation | Recommendation, soil profile editor | IrrigationScreen | **Near** |
| Equipment mgmt | Tractor/machine/spray/other equipment | SprayEquipment only | **Partial** |
| Chemicals / operators / presets | Chemicals, OperatorCategories, SavedInputs, Presets | Chemicals, OperatorCategories, Presets | **Near** |
| Grape varieties | GrapeVarietyManagement | — | **Missing** |
| Reports / exports | Spray PDF/CSV, yield report, cost reports, pins PDF | Spray PDF/CSV (cost rollups) | **Partial** |
| Cost reports hub | CostReportsView, costing wizard | Inline cost rollups only | **Partial** |
| Admin / system | AdminDashboard, trip audit, users, billing, flags | — | **Missing** |
| Team / roles / invites | TeamAccess, invite, pending invitations | (role gating only) | **Missing** (mgmt UI) |
| Alerts | AlertsCentre, settings, diagnostics | — | **Missing** |
| Biometric lock | BiometricLock/settings/enrollment | — | **Missing** |
| Onboarding / setup | OnboardingView, SetupWizard, disclaimer | — | **Missing** |
| Button templates / quick actions | ButtonsAndQuickActions, templates | — | **Missing** |
| Sync Status / offline | GlobalSyncStatusBar, per-record badges | **Itemised Sync Status + queues + cache** | **Ahead** |

---

## Android-ahead areas (do not regress)

- **Itemised offline write queues** with per-item attempt counts, dependency
  gates, and ordered replay (pins, pin photos, trips incl. GPS/row/tank, fuel,
  spray, work tasks + lines, maintenance, yield, growth). iOS uses
  last-write-wins dirty-tracking with no itemised list or attempt count.
- **Read-cache / offline-restart browsing** with pending-write overlay
  (maintenance, yield, growth, fuel, spray, work-task header + lines, historical
  trips). Already documented in the O/P stages.
- **Sync Status screen** with per-item retry, Retry-all, blocked-item details,
  and copy diagnostics.
- **Map 3D / top-down toggle** (iOS has no equivalent).

---

## iOS-ahead / missing-on-Android areas (ranked)

1. **Damage records** — fully absent on Android (no model/repo/read/screen/state/
   write path). Exists on iOS + Supabase. Largest functional gap.
2. **Phenology / optimal-ripeness / GDD suite** — budburst dates, GDD tracking,
   ripeness surfaces, variety GDD detail. Absent on Android.
3. **Weather/rain depth** — iOS has 4 weather providers, rain calendar, history
   backfill, forecast cards. Android has hourly + disease risk + irrigation only.
4. **Admin / system-admin / billing / feature flags** — absent on Android.
5. **Team / roles management UI** — invite members, pending invitations, access
   view. Android enforces role gating but has no management surface.
6. **Alerts centre** — absent on Android.
7. **Equipment management** — tractors, vineyard machines, other equipment, fuel
   purchases. Android only manages spray equipment.
8. **Cost reports hub + costing setup wizard** — Android has inline rollups only.
9. **Grape variety management**, **paddock boundary/geometry editor**, **pin PDF
   export**, **button templates / quick actions**, **biometric lock**,
   **onboarding / setup wizard / disclaimer** — all absent on Android.

---

## Data-contract risks

- **Client IDs + `client_updated_at`:** confirmed consistent for queued families
  (pins, fuel, spray, work tasks, maintenance, yield, growth). New families
  (damage, equipment) must mint client ids + `client_updated_at` the same way.
- **Soft-delete:** server uses `deleted_at` / `soft_delete_*` RPCs. Any new
  Android write path must preserve soft-delete semantics (never hard delete).
- **Nested child arrays:** spray tanks (embedded), yield block results (embedded),
  work-task labour/machine lines (separate tables, task-scoped). Damage and
  equipment contracts need the same explicit nested handling decision before
  implementation.
- **DB-generated totals** (work-task labour `total_hours`/`total_cost`) must not
  be invented on the client — already handled; keep this rule for damage/cost.
- **Row/path/side:** Android prefers `drivingRowNumber` (e.g. `19.5`) then
  `pinRowNumber`, side appended. Matches iOS display contract.
- **Photo paths:** deterministic `{vineyardId}/pins/{clientPinId}/photo.jpg` for
  pins. Maintenance/growth/damage photos need their own deterministic path
  contracts before offline photo parity.

---

## Offline write gaps (vs iOS local-first)

- **Photos beyond pin photos** — maintenance, growth, damage photos are
  online-only (no offline capture/retry).
- **Damage** — no feature, therefore no queue.
- **Equipment / fuel-purchases / variety / paddock-geometry writes** — online-only
  where they exist; mostly no Android surface.
- **Spray template/program import + trip-coupled spray create variants** — remain
  online-only by design.
- **Active-trip edge cases** — provisional offline-start reconciliation is
  implemented; deep multi-device active-trip conflict remains parked.

## Offline read / restart gaps

- **Trip GPS / row / tank detail streams** — historical trip *list* is cached, but
  opening a trip detail offline shows no breadcrumb/row/tank data.
- **Photos / signed URLs** — not cached (by design; no signed-URL caching).
- **Reference/picker lists** — chemicals, operator categories, equipment,
  varieties may render blank labels offline if not already in memory.
- **Damage** — no read cache (no feature).
- **Report/export cached dependencies** — exports require live data; not
  offline-capable.

---

## Module gap detail

- **Map/pin:** offline tile-free/vector map fallback (iOS has
  `OfflineVineyardMapView`); pin PDF export; multi-photo per pin; paddock
  boundary editor. Core polygons/labels/rows/duplicate-warnings already at near
  parity.
- **Trip:** detail-stream read cache (Q-3) is the main gap; active-trip and
  history list are near parity.
- **Spray:** near parity; risk areas are trip-coupled create variants and
  program import edge cases (intentionally online-only).
- **Work-task:** near parity; calculator + finalization present.
- **Maintenance:** full parity.
- **Yield:** estimation/sampling/determination-calculator/report suite is thinner
  on Android than iOS — partial.
- **Growth:** near parity; growth photos online-only.
- **Damage:** missing entirely — needs feature foundation first (Q-5) before any
  offline stage (Q-6).

## Photos & signed-URL gap analysis

- **Pin photos:** one-per-pin offline retry implemented (Android). iOS supports
  multiple — Android partial.
- **Maintenance / growth / damage photos:** online-only on Android (no offline
  capture, retry, or read cache).
- **Signed URLs:** not cached on either side by Android design; offline photo
  *viewing* is therefore unavailable — acceptable, documented limitation.
- **Privacy:** no signed URLs or secrets are cached anywhere; keep this invariant.

## Reports / export / admin gaps

- **Spray PDF/CSV + program PDF/CSV:** at parity (owner/manager gated, import-safe
  cost columns).
- **Yield report, cost reports hub, pins PDF:** missing/partial on Android.
- **Admin metrics, trip audit, system-admin, billing, feature flags:** missing on
  Android.
- **Team/role visibility management:** missing UI (gating works).

## UX polish gaps

- Terminology + Australian spelling already aligned in shipped slices; re-check
  any new surfaces.
- Empty states / offline banners: reuse the existing saved/cached field-data
  banner; avoid per-screen inline banners (parked).
- Field-worker/operator restrictions and owner/manager-only surfaces: enforced by
  role gating; verify any new module follows the omit-don't-blank pattern.
- Units / date-time formatting: verify per new module.

---

## Risk classification of gaps

- **Small UI polish:** login/dashboard wording, empty states, pin PDF.
- **Data-contract risk:** damage model, equipment model, nested-array decisions.
- **Offline-consistency risk:** trip detail-stream cache, photo offline queues.
- **Schema/RLS risk:** none required for any Q stage (all reuse existing
  tables/RPCs) — **must stay true**; if a gap appears to need schema, park it.
- **Export/report risk:** yield/cost report parity (read-only, owner gated).
- **Photo/storage risk:** maintenance/growth/damage photo offline handling.
- **High complexity / park:** admin/system-admin, alerts, weather-provider depth,
  phenology/ripeness/GDD, biometric lock, onboarding.

---

## Recommended staged roadmap (Stage Q)

- **Q-1 — Low-risk UI/data-contract polish.** Dashboard/home parity, reference
  picker-label offline resilience, login/empty-state wording, pin PDF export.
  *Low risk, high daily-use value.*
- **Q-2 — Map/pin/row-path parity.** Offline vector/tile-free map fallback,
  multi-photo per pin, paddock-detail entry refinements.
- **Q-3 — Trip detail-stream read parity.** Cache GPS/row/tank streams for
  historical trip detail offline (snapshot-only, no overlay), mirroring P-4.
- **Q-4 — Photo offline/read-cache parity.** Extend the pin-photo retry pattern to
  maintenance/growth photos (and damage later); deterministic storage paths.
- **Q-5 — Damage feature foundation.** Build Android damage model + repository +
  read path + screen + online CRUD against the existing iOS/Supabase contract.
- **Q-6 — Damage offline write + read-cache.** Apply the established queue +
  overlay + snapshot-cache pattern once Q-5 lands.
- **Q-7 — Reports / export / admin / team parity.** Yield report + cost reports
  hub; read-only team/role visibility; defer system-admin/billing.
- **Q-8 — Final QA / regression.** Full lifecycle + cache-purity + role-gating +
  offline regression sweep across all families.
- **Q-9 — Documentation closure + parity checkpoint.**

Out of explicit scope for the Q series (parked): system-admin/billing/feature
flags, alerts centre, biometric lock, onboarding/setup wizard, full
weather-provider depth, phenology/optimal-ripeness/GDD suite, button templates.
These are large, lower field-value, or higher-risk and revisited only if
prioritised.

---

## Recommended next implementation slice

**Start with Q-1 (low-risk UI/data-contract polish), then Q-3 (trip
detail-stream read parity).**

Rationale:
- **User value in the vineyard:** dashboard/picker-label/offline-resilience fixes
  touch everyday flows; trip detail offline closes a visible gap from P-4.
- **Risk:** both are read/display-side, reuse proven cache patterns, and need no
  schema/RLS change.
- **Architecture fit:** Q-3 reuses the exact `DomainCacheStore` snapshot-cache
  pattern already shipped for historical trips.
- **Parity impact:** removes the most-noticed "looks blank offline" gaps before
  the larger Damage build (Q-5/Q-6).

Defer **Damage (Q-5/Q-6)** until after the low-risk read-side slices — it is the
biggest gap but also the largest build (new feature + contract), so it should
land on a stabilised base.

---

## Audit completion

- **Stage Q-0 can be marked complete.** This note is the audit/design artifact.
- **No Android code changed. No iOS change. No schema/RLS/RPC change.**
- **No build required** (documentation only).
- **Parked items:** system-admin/billing, alerts, biometric lock, onboarding,
  weather-provider depth, phenology/ripeness/GDD, button templates, multi-device
  active-trip conflict, signed-URL/offline photo viewing.
