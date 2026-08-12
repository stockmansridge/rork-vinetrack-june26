# Portal Handoff — Yield Final Parity: Bunch Count Trips, Vintage Reports, Picking Financial Privacy

Status: implemented in Rork (iOS + Android + SQL 187). The Portal is NOT modified
by this work — this document is the contract for bringing it in line.

Applies after running, in order, in the Supabase SQL editor:

1. `sql/187_yield_reports_picking_financial_privacy.sql`
2. `sql/tests/187_picking_financial_privacy_tests.sql` (rollback-only; expect
   `SQL 187 picking financial privacy tests: ALL PASSED`)

---

## 1. Bunch Count Trip payload (yield_estimation_sessions)

The canonical camelCase payload is UNCHANGED except for two ADDITIVE keys.
Everything the Portal already parses keeps working; decoders must simply
tolerate (and preserve on write-back) the new keys:

| Key | Type | Default when absent | Meaning |
|---|---|---|---|
| `applyDamage` | boolean | `true` | Whether the CURRENT effective damage adjustment is applied to this trip's displayed Yield Estimate. Pre-187 sessions have no key → treat as `true` so historical numbers don't change. |
| `routeSourceSessionId` | UUID string / absent | absent | Id of the earlier session whose route/sample sites were reused for this trip. Purely provenance — never required for parsing. |

Unchanged quirks that still apply:

- `blockBunchWeightsKg` may be a FLAT alternating array (`["UUID", 0.15, ...]`)
  — Swift's non-String-keyed dictionary encoding — or a plain object.
- UUIDs inside the payload may be uppercase (iOS); compare case-insensitively.
- One session = one sync unit; `is_completed` / `completed_at` are mirrored as
  promoted columns AND inside the payload.

### Multiple trips per vintage

Mobile no longer maintains "one working session per vineyard". A vineyard can
now hold MANY sessions: at most one active draft (`isCompleted = false`) plus
any number of completed trips. Every completed trip is a dated observation and
is preserved forever — the Portal must not assume `sessions.first` is "the"
session.

### Route reuse

When a new trip reuses an earlier route, the sample sites are copied with
their ORIGINAL site `id`s (and row/lat/lon), `bunchCountEntry` stripped, and
`siteIndex` re-numbered sequentially. Matching `SampleSite.id` across sessions
therefore identifies "the same physical sample location" for season-over-season
comparison. `pathWaypoints` are regenerated per trip.

---

## 2. Current Yield Estimate — latest-completed selection rule

For each **Vintage + Block**:

> The current Yield Estimate is the LATEST COMPLETED session (by
> `completedAt`, falling back to `createdAt`) that has at least one RECORDED
> sample site in that block, within that vintage. Sessions are never summed
> and never averaged. Drafts never drive the estimate.

- Session vintage = `VintageResolver`/`resolve_vineyard_vintage_year`
  semantics applied to `completedAt ?? createdAt` (season-end year from the
  shared `vineyards.season_start_month/day`).
- A partial index `idx_yield_sessions_latest_completed`
  (`vineyard_id, completed_at desc WHERE is_completed AND deleted_at IS NULL`)
  supports this lookup server-side.

### Base vs damage-adjusted estimate

The canonical formula is unchanged:

```
baseKg = totalVines × avgBunchesPerVine(2dp) × blockBunchWeightKg
adjustedKg = baseKg × damageFactor(block)     -- multiplicative viability from damage_records
```

- The BASE estimate is always recoverable — damage never mutates the recorded
  bunch counts or the payload.
- Display rule: show `adjusted` when the trip's `applyDamage` is true,
  otherwise `base`. The damage factor is computed LIVE from current
  `damage_records`, so recording damage after a trip changes the displayed
  estimate without touching the observation.

---

## 3. Vintage-based Yield Reports (mobile behaviour to mirror)

- **Current vintage** → Estimated Yield per Block (rule above), with variety
  label(s) from the block's allocations, area and t/ha (regional unit). Where
  picking has already begun, "Picked so far" totals are shown ALONGSIDE the
  estimate — the estimate is never silently replaced because one pick exists.
- **Past vintages** → Actual Yield per Block + Variety:
  - Detailed Picking Log totals (`SUM(weight_kg)/1000` per Block + Variety +
    Vintage) supersede a Basic actual (`historical_yield_records`
    `block_results[].actualYieldTonnes` with `year = vintage`) for the same
    combination — never added on top (sql/180 rule, unchanged).
  - A block-level Basic actual is also treated as superseded when the block
    has multiple varieties and ANY of them has picks (it cannot be split
    against them).
  - Estimates remain available for variance drilldown (archived record
    estimate preferred, allocation-share split for multi-variety blocks).
- Terminology: **Vintage** (never Year/Season), **Bunch Count Trip** (the
  field activity), **Yield Estimate** (the calculated figure). Backend field
  names are unchanged.

## 4. Shared sampling default (sql/187)

- New column `vineyards.yield_samples_per_hectare` (int, default 20, 1–100).
- RPCs: `get_vineyard_yield_sampling_settings(p_vineyard_id)` (member read)
  and `set_vineyard_yield_sampling_settings(p_vineyard_id, p_samples_per_hectare)`
  (owner/manager/supervisor/operator — every trip-capable role).
- Mobile prompts for the density before route generation, prefilled from this
  default; a changed value is written back so the NEXT trip on any device
  starts from it. Portal should read/write the same RPCs if it exposes the
  setting.

---

## 5. Picking Log financial privacy (BREAKING for money display — read carefully)

### What changed server-side (sql/187)

`sold_to`, `price_per_tonne` and the generated `grape_value` on
`public.picking_records` are now **permanently NULL for every reader**.
Commercial values live in a new companion table:

```
public.picking_record_financials (
  picking_record_id uuid primary key,   -- no FK by design (BEFORE INSERT routing)
  vineyard_id uuid not null,
  sold_to text,
  price_per_tonne double precision,
  updated_by uuid, updated_at timestamptz
)
-- RLS: SELECT owner/manager only. No client writes (trigger-managed).
```

A `BEFORE INSERT OR UPDATE` trigger (`picking_records_route_financials`)
routes client-supplied financial values into the companion table and strips
them from the base row. Existing rows were backfilled and stripped by the
migration.

`sold` (boolean) REMAINS member-visible by design: it is operational status
(the fruit left the property) and carries no monetary value or counterparty.
This was the explicit outcome of the privacy audit.

### How the Portal reads money now

- Owner/manager: call `get_picking_record_financials(p_vineyard_id)` →
  rows `(picking_record_id, sold_to, price_per_tonne, grape_value)` where
  `grape_value = weight_kg/1000 × price_per_tonne` for sold picks. Merge by
  id into the base rows. Lower roles get errcode `42501` — treat as
  "no financial access", never retry-loop it.
- Owner/manager may also SELECT `picking_record_financials` directly (RLS).
- `picking_yield_totals` and `picking_yield_planting_totals` keep their exact
  column lists, but `total_grape_value` now derives from the companion table
  THROUGH THE CALLER'S RLS: managers see real totals, everyone else reads
  NULL. No Portal query changes are required for the views.

### How the Portal writes money

Keep writing `sold`, `sold_to`, `price_per_tonne` on `picking_records`
inserts/updates exactly as today — the trigger routes them. Rules the trigger
enforces (writer = owner/manager or service role; other roles never touch the
companion):

- `sold = false` → companion row deleted (unsold picks carry no commercial
  fields, unchanged sql/180 contract).
- `sold = true` and ANY of `sold_to`/`price_per_tonne` non-null → companion
  upserted with BOTH values as sent.
- `sold = true` and BOTH null → **no-op**. This protects data: post-187
  clients read masked NULLs and echo them back on unrelated edits. Therefore
  the Portal MUST always send the full financial state (both fields) on
  updates that intend to change money, and cannot "clear both while sold"
  through a base write (toggle `sold` off instead).
- Never send `grape_value` (generated column, unchanged rule).

### UI rule (all clients)

Hide the commercial fields entirely for non-owner/manager users — no masked
dollar amounts. Operational fields (date, vintage, block, variety, clone,
weight, Brix/Baumé, pH, TA, purpose) plus the bare `sold` flag stay visible.

---

## 6. Mobile UX summary (for parity reference)

- Yield Estimation now opens as **Bunch Count Trips**: explanation + "Start
  Bunch Count Trip", a resume card for the in-progress draft, and the
  completed-trip history.
- Flow: select Block(s) → if an earlier route covers them, choose
  **Use Existing Route** or **Generate New Route** (no prompt when none
  exists) → confirm sample density (shared default) → full-screen guided
  sampling map (block boundary, route, done/remaining sites, live position;
  GPS is guidance only — manual entry is never blocked) → **Complete
  Estimation** → per-block summary (variety, samples, avg bunches/vine),
  per-block average bunch weight confirmation, **Apply recorded damage**
  toggle, estimate preview (t and t/ha or t/ac) → **Save Bunch Count Trip**.
- Offline: unchanged session outbox — every mutation persists the whole
  session locally and replays; an interrupted trip resumes exactly where it
  stopped.

## 7. Portal action checklist

- [ ] Tolerate + preserve `applyDamage` / `routeSourceSessionId` in the
      session payload (defaults: `true` / absent).
- [ ] Overview/Yield Reports: adopt the latest-completed-per-Block+Vintage
      rule and the `applyDamage` display rule.
- [ ] Switch financial reads to `get_picking_record_financials` (or direct
      companion SELECT) for owner/manager; hide money for other roles.
- [ ] Verify no Portal code depends on non-null `picking_records.sold_to /
      price_per_tonne / grape_value` (they are NULL for everyone now).
- [ ] Always send full financial state on picking updates (both fields).
- [ ] Optionally surface the shared sampling default via the sql/187 RPCs.
- [ ] Use "Vintage", "Bunch Count Trip", "Yield Estimate" terminology.
