# Android Stage Q-1 — Low-Risk UI / Data-Contract Polish Plan

Implementation plan for **Stage Q-1** of the Android (`android-vinetrack`)
→ iOS (`ios/VineTrackV2`) parity roadmap. Source of truth: `docs/android-ios-parity-roadmap-status.md` (Stage Q-0).

> **STATUS: Q-1 CLOSED** (Q-1b/Q-1c/Q-1d shipped + build-passed; Q-1e QA/doc closure
> this pass). See the closure summary at the end of this note.

## Sub-stage closure state

| Sub-stage | Scope | Status |
|---|---|---|
| Q-1a | Dashboard / empty-state terminology | **FOLDED INTO Q-1b/Q-1c** |
| Q-1b | Cached/offline banner + Home Sync Status discoverability card | **CLOSED** (shipped, QA-passed, build-passed) |
| Q-1c | Fuel / yield / weather read-only UI polish | **CLOSED** (shipped, QA-passed, build-passed) |
| Q-1d | Reference picker-label offline resilience | **CLOSED** (shipped, build-passed) |
| Q-1e | Q-1 QA/regression sweep + documentation closure | **CLOSED / DOC + QA** (this pass) |
| **Q-1 (overall)** | **Low-risk UI/data-contract polish** | **CLOSED** |

> **Constraints (hard):** No iOS changes. No Supabase schema/RLS/RPC changes. No
> changes to offline write queues, read-cache implementation, photo queues, or the
> (absent) damage feature. Q-1 is **UI / read-only / wording** only — nothing that
> touches data contracts on the write/replay path. **No code is written in this
> planning pass.**

---

## 1. Method

Read the Q-0 roadmap note, then inspected the candidate low-risk Android surfaces and
shared components:

- `ui/screens/HomeDashboard.kt` (+ `DashboardContent`)
- `ui/screens/MoreScreen.kt`, `ui/screens/SettingsScreen.kt`
- `ui/screens/SyncStatusScreen.kt` (cached-data banner block)
- `ui/screens/FuelLogScreen.kt`, `ui/screens/YieldScreen.kt`
- `ui/screens/IrrigationScreen.kt`, `ui/screens/DiseaseRiskScreen.kt` (weather/rain surfaces)
- `ui/components/Components.kt` (`EmptyState`, `SectionHeader`, `VineyardCard`)
- `ui/main/Navigation.kt` (`MainTab`, `ToolGroup`, `ToolRoute`)
- `ui/AppViewModel.kt` (`isUsingCachedFieldData`, `cachedFieldDataLastSyncedAt`)

Key structural facts found:

- The **saved/cached field-data banner already exists** and is shown in **two
  places**: the **Home dashboard** ("Saved Field Data" section) and the **Sync Status
  screen**. Both read `state.isUsingCachedFieldData` + `cachedFieldDataLastSyncedAt`.
  No new banner component is needed — reuse only.
- **Sync Status** is reachable today only via **More → Account → "Sync Status"**.
  There is no Home entry point for it.
- The **More hub** is a clean single-source-of-truth list driven by the `ToolRoute`
  enum, grouped by `ToolGroup`. Wording lives in the enum `title`/`subtitle`.
- There is **no Reports/Export tool entry** in `ToolRoute`. Export lives inside Spray
  surfaces; a "reports/export entry-point" in Q-1 would mean *label clarity only*,
  not a new screen (a new hub is Q-7).

---

## 2. Candidate area comparison (iOS benchmark vs Android)

| Area | iOS | Android today | Gap | User impact | Risk |
|---|---|---|---|---|---|
| Cached/offline banner wording | Global sync chip + per-record badges | "Showing saved field data" + "Last saved …" on Home & Sync Status | Wording is good; minor consistency/tone polish only | Low–med (confidence offline) | **Low** |
| Sync Status discoverability | Global sync status bar always visible | Only via More → Account | No Home/at-a-glance entry to pending/blocked sync | Med (operators miss blocked writes) | **Low** |
| Dashboard parity | Rain/alert/sync cards | Vineyard cards + map + shortcuts | Terminology + empty-state tone | Low | **Low** |
| Empty states | Consistent iOS copy | `EmptyState` component used widely | A few terse/inconsistent strings | Low | **Low** |
| Reference picker labels offline | Labels resolve from cached refs | Some pickers may show blank labels offline (chemicals/operators/equipment) | Read resilience gap | Med (confusing offline) | **Low–med** |
| Fuel UI | Fuel + FuelPurchases | FuelLog only | No purchases UI (parked, Q-7), but log wording/units polish possible | Low | **Low** |
| Yield thinness | Estimation/sampling/determination/report suite | Partial | Structural (parked); only wording/empty-state in Q-1 | Low | **Low** (polish) / park (features) |
| Weather/rain display | 4 providers + rain calendar | Hourly + disease risk + irrigation | Structural (parked); only label/units polish in Q-1 | Low | **Low** (polish) / park |
| Units / date-time formatting | AU formatting | Mostly aligned | Spot-check new surfaces | Low | **Low** |
| AU spelling/terminology | AU English | Mostly aligned | Spot-check | Low | **Low** |
| Data-contract wording (client id / timestamp / soft-delete) | n/a (display) | Diagnostic copy in Sync Status | "Last saved/synced" labels only — no contract change | Low | **Low** |

---

## 3. Explicitly parked (not in Q-1)

- Map / pin row-snapping changes → **Q-2**
- Trip GPS/row/tank detail-stream cache → **Q-3**
- Photo offline queues / multi-photo / signed-URL viewing → **Q-4**
- Damage feature (no Android surface) → **Q-5/Q-6**
- Yield report suite, cost reports hub, fuel-purchases UI, pins PDF → **Q-7**
- Admin / system-admin / billing / team management / alerts → parked
- Weather-provider depth, phenology/ripeness/GDD → parked
- Any schema/RLS/RPC change → **never** in Q-series

---

## 4. Recommended Q-1 scope

A small, read-only batch that maximises everyday clarity with near-zero contract risk:

1. **Sync Status discoverability** — add a lightweight Home entry point to the Sync
   Status screen (e.g. a tappable status row/chip on the dashboard surfacing
   pending/blocked counts that already exist in `AppUiState`). Reuse existing state;
   no new sync logic.
2. **Cached/offline banner wording consistency** — align the Home and Sync Status
   "Saved field data" copy and tense; confirm the relative-time string reads
   naturally; ensure it is never shown when fresh.
3. **Reference picker-label offline resilience** — where a picker (chemicals,
   operator categories, equipment) can render a blank label offline, fall back to a
   stored name snapshot / "Unavailable offline" placeholder. **Display-only**, no
   write-path change.
4. **Empty-state + terminology spot-fixes** — sweep `EmptyState` usages and the
   More hub `ToolRoute` subtitles for AU spelling/tone consistency.
5. **QA + build + docs.**

---

## 5. Sub-stages, acceptance criteria, risk

### Q-1a — Dashboard / empty-state terminology
- **Files likely touched:** `ui/screens/HomeDashboard.kt`, `ui/components/Components.kt`, `ui/main/Navigation.kt` (subtitle strings).
- **Change:** tighten empty-state copy + tool subtitles for AU tone/consistency.
- **Must not change:** layout structure, navigation routes, any state/data.
- **QA:** visual check of each touched empty state; no behaviour change.
- **Build:** `runChecks` Android.
- **Risk:** **Low.**

### Q-1b — Cached/offline banner + Sync Status discoverability
- **Files likely touched:** `ui/screens/HomeDashboard.kt`, `ui/screens/SyncStatusScreen.kt`, possibly a small dashboard row that calls the existing `onOpenTool(ToolRoute.SyncStatus)`.
- **Change:** (1) align banner wording across Home + Sync Status; (2) add a Home tap-through to Sync Status surfacing existing pending/blocked counts.
- **Must not change:** cache state computation, `isUsingCachedFieldData` logic, any sync/replay code.
- **QA:** offline restart shows banner correctly; fresh state hides it; Home row opens Sync Status; counts match Sync Status screen.
- **Build:** `runChecks` Android.
- **Risk:** **Low.**

### Q-1c — Fuel / yield / weather read-only UI polish
- **Files likely touched:** `ui/screens/FuelLogScreen.kt`, `ui/screens/YieldScreen.kt`, `ui/screens/IrrigationScreen.kt`, `ui/screens/DiseaseRiskScreen.kt`.
- **Change:** units/date-time formatting consistency, label wording, empty-state tone. **No new features.**
- **Must not change:** calculations, data fetch, write paths, cache usage.
- **QA:** numbers/dates render identically; no functional change.
- **Build:** `runChecks` Android.
- **Risk:** **Low.**

### Q-1d — Reference picker-label offline resilience
- **Files likely touched:** the picker composables for chemicals / operator categories / equipment (within Spray/SprayManagement screens) + read-side label resolution.
- **Change:** display fallback to a name snapshot or neutral placeholder when a referenced label is unavailable offline. **Read/display only.**
- **Must not change:** the reference data contract, write payloads, cache write-through, replay.
- **QA:** force-offline with empty reference memory → labels show snapshot/placeholder, never blank or crash; online unchanged.
- **Build:** `runChecks` Android.
- **Risk:** **Low–medium** (verify no contract coupling) — drop to a placeholder-only fix if any contract risk appears.

### Q-1e — QA / build / docs
- **Files likely touched:** `docs/android-ios-parity-roadmap-status.md` (mark Q-1 closed), this plan doc.
- **Change:** record QA results, mark Q-1 closed, list parked items.
- **QA:** full low-risk regression sweep of touched screens; offline restart sanity.
- **Build:** `runChecks` Android (final).
- **Risk:** **Low.**

---

## 6. Risk summary

- **Low risk:** Q-1a, Q-1b, Q-1c, Q-1e — pure UI/wording + a tap-through reusing
  existing state.
- **Low–medium:** Q-1d — verify the offline label fallback has no contract coupling;
  if it does, reduce to a placeholder-only display fix or park to Q-2.
- **Park:** anything requiring new screens, new models, schema, or write-path change.

---

## 7. Final recommendation

- **Recommended first implementation prompt:** start with **Q-1b** (cached/offline
  banner wording + Sync Status Home discoverability). It is the highest
  daily-confidence win, reuses state that already exists, and touches no data
  contract — the safest possible first slice.
- **Then:** Q-1a → Q-1c → Q-1d → Q-1e in that order, each its own small build-checked
  commit.
- **After Q-1:** proceed to **Q-3 (trip detail-stream read parity)** per the Q-0
  recommendation — it reuses the proven P-4 snapshot-cache pattern and closes a
  visible offline gap before the larger Damage build (Q-5/Q-6).
- **Q-1 planning can be marked complete** — this note is the design artifact; no code
  changed, no build required.

---

## 8. Q-1 closure summary (Q-1e)

Q-1 is **CLOSED**. All slices shipped, QA-passed, and build-passed via Android `runChecks`.
No new product features added; all changes are presentation / read-only.

### Files changed across Q-1

- `ui/screens/HomeDashboard.kt` — Q-1b Home `SyncStatusCard` (conditional, tap-through
  to existing Sync Status); Q-1c dashboard `WeatherCard` relabel + route to Disease Risk.
- `ui/screens/FuelLogScreen.kt` — Q-1c offline-aware empty state.
- `ui/screens/YieldScreen.kt` — Q-1c offline-aware empty state + stale-comment fix.
- `ui/screens/TripsScreen.kt` — Q-1d block-label offline fallback ("Block unavailable offline").
- `ui/screens/WorkTasksScreen.kt` — Q-1d block-label offline fallback ("Block unavailable offline").

### Q-1b — Home Sync Status card behaviour

- Rendered in `DashboardContent` between the Active Trip slot and the info card.
- Visible **only when useful**: offline, pending sync, pending photo uploads,
  blocked photo/pin items, or saved/cached field data in use. Hidden otherwise
  (renders nothing; column spacing collapses cleanly).
- Wording priority: blocked/needs-attention → offline → pending sync → pending
  photos → "Showing saved field data". Calm tone, no false "synced" wording.
- Taps call `onOpenTool(ToolRoute.SyncStatus)` — opens the **existing** Sync Status
  screen. No duplicate route. More → Account → Sync Status still works.

### Q-1c — Fuel / yield / weather wording changes

- Dashboard weather card: old "Forecast not connected yet" placeholder removed;
  now "Weather" / "Rainfall & disease risk outlook", routing to the existing
  Disease Risk screen. No new weather integration or API calls.
- Fuel empty state: offline branch says saved fuel fills are unavailable on this
  device and to reconnect; does not imply fuel purchases exist.
- Yield empty state: offline branch says saved yield records are unavailable on
  this device and to reconnect; actual-vs-estimate wording preserved.
- Rainfall units remain mm; Disease Risk / Irrigation surfaces unchanged.

### Q-1d — Reference-label fallback changes

- Resolver layer (`data/model/Models.kt`) already provides comprehensive name
  resolution + fallbacks; reused, not modified.
- Trips and WorkTasks block-name display now falls back to "Block unavailable
  offline" when the live lookup fails (e.g. offline restart) instead of blank.
- No raw UUIDs surfaced in normal UI; no new reference-cache architecture.

### Safety boundaries (held across Q-1)

- No changes to data models, repositories, cache read/write behaviour,
  pending-write queues, retry/replay semantics, role gates, backend/API calls,
  schema/RLS/RPC, or iOS.
- Rendering Home/Fuel/Yield/Weather/Trips/WorkTasks triggers no sync/replay,
  mutates no pending markers, increments no attempt counts, writes no cache, and
  exposes no secrets/payload JSON. Sync Status remains the sole authority for
  retry/diagnostics.

### Parked follow-ups

- Multi-photo per pin, maintenance/growth/damage photo offline → **Q-4**.
- Trip GPS/row/tank detail-stream read cache → **Q-3**.
- Fuel-purchases UI, yield report suite, cost reports hub, pins PDF → **Q-7**.
- Larger reference-list cache architecture → revisit if blank-label gaps recur.

### Recommended next stage

**Q-2 (map / pin / row-path parity)** as the next implementation slice, with
**Q-3 (trip detail-stream read parity)** queued after it per the Q-0 roadmap.
