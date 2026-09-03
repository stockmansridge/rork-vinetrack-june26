# VineTrack — E-L Ripeness Heatmap Cross-Platform Contract

Contract version **1.1.0** · Fixture version **1.1.0** · Implementation-neutral.

> **Revision 1.1.0** corrects three defects found during mobile verification:
> (1) the 1 January Vintage rule now matches the authoritative database resolver
> (`resolve_vintage_year`, SQL 119) — a 1 January season start returns the
> observation's **calendar year**; (2) published sample weights are regenerated from
> **full-precision** intermediate values (the previous file used a rounded influence
> radius for three cells); (3) the two northern fixture records are classified
> `wrong_vineyard`, not `no_observation_date` — their dates are valid.

This document defines the *exact* deterministic behaviour of the shipped VineTrack Portal
E-L Ripeness Heatmap so that iOS and Android can reproduce it numerically without access
to the Portal repository. It contains no file paths and no repository references.

Companion files:

* `el-ripeness-heatmap-fixture.json` — deterministic synthetic input data.
* `el-ripeness-heatmap-expected.json` — machine-readable expected outputs for that fixture.
* Appendix A of this document — the exact pure calculation source, verbatim.

Nothing in this package changes behaviour. No SQL or backend change is authorised.

---

## 0. Constants (authoritative)

| Name | Value |
|---|---|
| `EL_MIN` | `1` |
| `EL_MAX` | `43` |
| `RECENCY_HALF_LIFE_DAYS` | `21` |
| `RECENCY_MAX_AGE_DAYS` | `84` |
| `RECENCY_TAPER_DAYS` | `14` |
| `IDW_POWER` | `2` |
| Grid resolution (per axis) | `48` (default; caller-overridable) |
| Halo influence fraction | `0.22` of block bounding-box diagonal |
| Gradient influence fraction | `0.35` of block bounding-box diagonal |
| Zero-distance epsilon | squared distance `< 1e-14` (deg²) |
| Max alpha | `0.72` |
| Min alpha factor | `0.12` |

---

## 1. E-L parsing

Input is the stored growth-stage code (any type). Algorithm, in order:

1. `null` / `undefined` → **excluded** (`null`).
2. Convert to string, `trim()` (leading/trailing Unicode whitespace removed).
3. Empty string → excluded.
4. Strip a leading E-L prefix with the case-insensitive regular expression
   `/^e\s*-?\s*l\s*/i`, then `trim()` again. This accepts `EL23`, `E-L 23`, `e l 23`,
   `e-l23`, `  el 12  `. Only a **leading** prefix is stripped.
5. Numeric conversion uses JavaScript `Number(cleaned)` semantics:
   * decimals accepted (`23.5` → `23.5`);
   * a leading `+`/`-` accepted;
   * exponent form accepted (`1e1` → `10`);
   * hexadecimal literals accepted (`0x1F` → `31`) — an accepted quirk, reproduce it;
   * internal whitespace is *not* allowed (`4 3` → `NaN`);
   * trailing letters not allowed (`23a` → `NaN`).
6. Non-finite result (`NaN`, `Infinity`) → excluded.
7. `n < 1` or `n > 43` → **excluded**. There is **no clamping** at parse time.
8. Otherwise return `n` (decimals preserved; no rounding).

Consequences:

* `0`, `0.9`, `-5` → excluded.
* `44`, `47`, `E-L 47`, `43.0000001` → excluded. **E-L 47 is never clamped to 43**; it is
  simply not part of the ripeness heat surface. It may still be listed in Growth Stage
  Records elsewhere, but it never contributes a pin, a colour, a median or an IDW value here.
* Malformed values (`flowering`, `EL`, `E-L`, `""`) → excluded.

Display formatting: integers render as `E-L 23`; non-integers render with one decimal
(`E-L 23.5`); `null` renders as the em dash `—`.

Machine-readable cases: `el_parsing` in the expected file.

---

## 2. Colour scale

Fixed for every vineyard, block and vintage. The scale **never** rescales to the data.

### Anchors

| E-L | R | G | B | Hex | Label |
|---|---|---|---|---|---|
| 1 | 220 | 38 | 38 | `#dc2626` | E-L 1 — dormant |
| 12 | 234 | 129 | 24 | `#ea8118` | E-L 12 — early development |
| 23 | 234 | 199 | 24 | `#eac718` | E-L 23 — mid-season |
| 35 | 132 | 204 | 22 | `#84cc16` | E-L 35 — advanced |
| 43 | 22 | 143 | 60 | `#168f3c` | E-L 43 — harvest ripe |

### Interpolation

* Input is first clamped to `[1, 43]` **for colouring only** (values reaching this function
  are already inside the range because parsing excluded anything else; the clamp only
  affects the interpolated IDW output, which cannot leave the hull of its inputs anyway).
* Piecewise **linear interpolation in non-linear sRGB 8-bit space** — plain channel
  interpolation on the stored 0–255 values. No linear-light conversion, no HSL, no Lab.
* Segment parameter: `t = (v - prevAnchorEl) / (curAnchorEl - prevAnchorEl)`, where the
  segment is the first one whose upper anchor satisfies `v <= cur.el`.
* Per channel: `round(prev + (cur - prev) * t)` using **half-up rounding of .5 toward
  +∞** (JavaScript `Math.round`: `Math.round(-0.5) === -0. `, `Math.round(0.5) === 1`).
  Channel values are integers in `[0, 255]`; no further clamping is required because the
  result always lies between two in-range anchors.
* `v <= 1` returns the E-L 1 anchor exactly; `v >= 43` returns the E-L 43 anchor exactly.
* Colour carries **no alpha**. Alpha is computed separately (section 6).

### Verified intermediate colours

| E-L | RGB | Hex |
|---|---|---|
| 2 | 221, 46, 37 | `#dd2e25` |
| 6 | 226, 79, 32 | `#e24f20` |
| 6.5 | 227, 84, 31 | `#e3541f` |
| 17 | 234, 161, 24 | `#eaa118` |
| 18 | 234, 167, 24 | `#eaa718` |
| 29 | 183, 202, 23 | `#b7ca17` |
| 29.5 | 179, 202, 23 | `#b3ca17` |
| 39 | 77, 174, 41 | `#4dae29` |

Full list: `colour_scale` in the expected file.

---

## 3. Observation dates and recency

### 3.1 Timestamp precedence

The observation timestamp is the first non-null of:

1. `date`
2. `completed_at`
3. `created_at`

`updated_at` is **never** used. If all three are null, the record is excluded entirely.

### 3.2 Date handling

* All timeline arithmetic is performed on the **calendar-day key**: the first 10
  characters of the ISO string (`"2026-01-10T05:22:00Z"` → `"2026-01-10"`). This is a pure
  string slice — **no timezone conversion is performed at all**. The stored ISO string's
  own date component is treated as the vineyard-local observation day.
* Day difference: `daysBetween(from, to) = round((Date.parse(toKey + "T00:00:00Z") -
  Date.parse(fromKey + "T00:00:00Z")) / 86400000)`. Both endpoints are start-of-day UTC,
  so the result is always an **integer number of whole days**; there is no elapsed-time or
  fractional-day component. Unparseable input yields `0`.
* `recencyWeight` itself accepts fractional ages (used only in tests); production always
  supplies integers.

### 3.3 Future observations

An observation qualifies for timeline date `D` only when `dayKey(obsDate) <= dayKey(D)`.
Future observations are hidden completely — not stale, not counted, not rendered.
(If a future date is ever passed directly into `recencyWeight`, the negative age is
clamped to 0 → weight 1; the qualification filter prevents that path in production.)

### 3.4 Recency equation

```
age  = max(0, ageDays)
if age >= 84 -> 0
decay = 0.5 ^ (age / 21)
taper = clamp((84 - age) / 14, 0, 1)      // == 1 for age <= 70
weight = decay * taper
```

Exact values:

| age (days) | weight |
|---|---|
| 0 | 1 |
| 1 | 0.9675317785 |
| 7 | 0.7937005260 |
| 14 | 0.6299605249 |
| 21 | 0.5 |
| 42 | 0.25 |
| 63 | 0.125 |
| 69 | 0.1025419195 |
| 70 | 0.0992125657 |
| 71 | 0.0891347880 |
| 77 | 0.0393725328 |
| 83 | 0.0046140972 |
| 84 | 0 |
| 85+ | 0 |

Note the taper only engages **after day 70** (`taper = 1` for `age <= 70`), which is why
day 70 is pure exponential decay and day 71 is visibly lower.

### 3.5 Effect of recency

Recency weight `w` is applied in **two** places:

* **Spatially, inside IDW**: each observation's inverse-distance weight is multiplied by
  its `w` when accumulating the value numerator/denominator. So a fresher pin pulls the
  interpolated E-L value toward itself.
* **In opacity**: a separate per-cell weight accumulator (section 6) drives alpha.

Recency does **not** change the pin colour and does **not** change the parsed E-L value.

### 3.6 Current vs stale

For a qualifying observation at timeline date `D`:

* `age = daysBetween(obsDate, D)`
* **current / influencing** ⟺ `age >= 0 && recencyWeight(age) > 0` ⟺ `0 <= age < 84`
* **stale** otherwise (`age >= 84`).

Stale observations remain visible as historical pins but contribute **nothing** to the
surface, the block median or the influencing count. Rendering distinction: stale pins are
smaller (12 px vs 16 px), dashed white border (vs solid), and 0.55 opacity (vs 1.0).

Historical playback is unaffected: moving the timeline back near the observation's own
date makes it influencing again.

---

## 4. Vintage

**The database / shared VintageResolver is authoritative.** The Portal, iOS and Android
must all reproduce `resolve_vintage_year` (SQL 119); no platform may invent its own season
logic. The Vintage anchor is the vineyard's stored **`season_start_month`** and
**`season_start_day`** only. There is **no stored hemisphere field driving Vintage**. (A
hemisphere value exists in the Portal solely as a display label, resolved from vineyard
latitude → block-polygon mean latitude → country; it never affects any Vintage or heatmap
calculation.)

### Rules

```
// Season-year offset — the SQL 119 rule.
seasonYearOffset(month, day) = (month == 1 && day == 1) ? 0 : 1

currentVintageForSeason(month, day, now):
    offset = seasonYearOffset(month, day)
    start  = local civil date (now.year, month, day)
    return now >= start ? now.year + offset : now.year - 1 + offset

vintageForDate(date, month, day) = currentVintageForSeason(month, day, date)

seasonRangeForVintage(month, day, vintage):
    startYear       = vintage - seasonYearOffset(month, day)
    startISO        = civil date (startYear,     month, day)
    endExclusive    = civil date (startYear + 1, month, day)
    endISO          = endExclusive - 1 day        // inclusive display end
```

Invariant: for every season configuration and every date,
`seasonRangeForVintage(m, d, vintageForDate(date, m, d))` contains `date`.

All comparisons are civil-calendar, using the device's local calendar; no timezone
conversion is applied to the ISO date keys used for filtering.

The Vintage **label** is the ending year for every season start except 1 January: a season
starting 1 July 2025 is Vintage **2026**. A **1 January season start is the calendar year
itself** — the season starting 1 January 2026 is Vintage **2026**.

### Configurations

* **Southern (typical AU), `season_start = 7/1`:** Vintage 2026 = `2025-07-01` →
  `2026-06-30`. A 2026-01-10 observation is Vintage 2026.
* **Northern, `season_start = 11/1`:** Vintage 2026 = `2025-11-01` → `2026-10-31`.
* **Calendar-year, `season_start = 1/1`:** Vintage 2026 = `2026-01-01` → `2026-12-31`;
  Vintage 2027 = `2027-01-01` → `2027-12-31`.

### 1 January boundary case (SQL 119)

With `season_start = 1/1` the Vintage **is the observation's calendar year**:

| Observation date | Vintage |
|---|---|
| `2025-12-31` | **2025** |
| `2026-01-01` | **2026** |
| `2026-02-15` | **2026** |
| `2026-12-31` | **2026** |
| `2027-01-01` | **2027** |

This matches the database resolver and the Yield, Costing and Pruning surfaces. Any
implementation that assigns `2026-02-15` to Vintage 2027 under a 1 January season start is
non-conformant.

### Missing season settings

If the season RPC returns no usable value, fall back to **1 July** (`month = 7, day = 1`).
An out-of-range month falls back to 7; an invalid day falls back to 1; the day is clamped
to the month's maximum (Feb → 29, Apr/Jun/Sep/Nov → 30, otherwise 31).

### Vintage filtering in the heatmap

Observations are filtered to the season by **inclusive day-key string comparison**:
`startISO <= dayKey(obsDate) <= endISO`. The Vintage picker lists only Vintages that
actually contain observations (descending); it defaults to the current Vintage when that
Vintage has observations, otherwise to the newest Vintage that does.

Machine-readable cases: `vintage_assignment` and `season_ranges` in the expected file.

---

## 5. IDW interpolation

Per block, over that block's **influencing observations only**.

* **Power:** `2`.
* **Projection:** none. Raw degrees are used, with longitude scaled by
  `cos(latitude_of_the_evaluated_cell × π / 180)`. Latitude deltas are unscaled.
  Distance unit is therefore **"cosine-corrected degrees"**, not metres:

  ```
  dLat = cellLat - obsLat
  dLng = (cellLng - obsLng) * cos(cellLat * π / 180)
  d2   = dLat² + dLng²
  d    = sqrt(d2)
  ```

  Note: the cosine factor uses the **cell's** latitude, evaluated per cell. (The block
  bounding-box diagonal, section 7, uses the bounding box's `minLat` instead — reproduce
  both exactly as written.)

* **Zero-distance epsilon:** if `d2 < 1e-14` (i.e. `d < 1e-7` deg, ≈ 1.1 cm), the loop
  **breaks immediately** and the cell takes that observation's exact E-L value and exact
  recency weight — no blending, and remaining observations are not examined. Observation
  iteration order is the block's observation order, so an exact hit resolves to the
  first matching observation in that order.

* **Accumulation** (per observation `p` with recency weight `p.w`):

  ```
  wDist = 1 / d^2
  w     = wDist * p.w
  num  += p.el * w
  den  += w
  wNum += p.w * wDist        // identical to w; accumulated separately for opacity
  nearest = min(nearest, d)
  ```

* **Value:** `el = num / den` (weight normalisation is the standard Shepard division).
  If `den == 0` the cell is empty (`null`).

* **Cell opacity weight:**

  ```
  falloff  = isFinite(maxInfluence) ? clamp(1 - nearest / maxInfluence, 0, 1) : 1
  cellW    = clamp((wNum / (den || 1)) * falloff, 0, 1)
  ```

  In dense (`surface`) mode `maxInfluence` is `Infinity`, so `falloff = 1` and
  `wNum/den = 1`, giving `cellW = 1` — full alpha inside the polygon.

* **Grid:** fixed `resolution × resolution` with `resolution = 48` by default.
  `latStep = (maxLat - minLat) / (resolution - 1)`, likewise for longitude, so both edges
  of the bounding box are sampled. Grid row index `i` runs **south → north**
  (`lat = minLat + latStep*i`), column index `j` runs west → east. When rasterising,
  grid row 0 maps to the **bottom** image row (image row `rows - 1 - i`).

* **Bounding box:** the polygon's exact min/max latitude and longitude. **No padding.**

* **Polygon edges:** every grid cell outside the polygon (see section 8) is `null` in both
  the value grid and the weight grid → fully transparent. There is no feathering or
  extrapolation beyond the polygon; the raster is a hard clip.

Machine-readable per-point results: `per_date[].sample_points` in the expected file
(`idw_el`, `cell_weight`, `rgb`, `alpha_0_255`).

---

## 6. Rendering: colour and alpha

For each grid cell:

```
if (el == null) -> alpha = 0 (fully transparent, RGB irrelevant)
else:
   rgb   = elColour(el)
   w     = weightGrid[i][j] ?? 1
   alpha = round(255 * 0.72 * clamp(w, 0.12, 1))     // lower bound 0.12, upper bound 1
```

Precisely: `Math.round(255 * maxAlpha * Math.max(0.12, Math.min(1, w)))` with
`maxAlpha = 0.72`. Fully-weighted cells therefore render `alpha = 184` (0.7216).
The floor of `0.12` applies **only to cells that have a value**; it never resurrects
`null` cells, and stale observations produce no cells at all.

The raster is drawn as an image overlay aligned to the block's grid bounding box
(`[[minLat, minLng], [maxLat, maxLng]]`).

---

## 7. Sparse modes

Mode selection uses the count of **influencing** observations in the block:

| Condition | Mode |
|---|---|
| polygon has fewer than 3 points | `no_polygon` |
| influencing = 0 and total qualifying = 0 | `none` |
| influencing = 0 and total qualifying > 0 | `stale` |
| influencing = 1 | `halo` |
| influencing = 2 | `gradient` |
| influencing >= 3 | `surface` |

`no_polygon` is evaluated first and wins over every other condition.
`none` and `stale` produce **no grid** (`grid = null`, `weightGrid = null`,
`gridBounds = null`), so nothing is painted.

### Radius

```
diag = sqrt( (maxLat - minLat)²
           + ((maxLng - minLng) * cos(minLat * π / 180))² )     // bounding-box diagonal

maxInfluence = halo     -> diag * 0.22
               gradient -> diag * 0.35
               surface  -> Infinity
```

Units: cosine-corrected degrees, as in section 5. Note the cosine here uses the bounding
box `minLat`, whereas per-cell distances use the cell latitude.

### Falloff

A cell whose `nearest` observation distance exceeds `maxInfluence` is `null`
(transparent) — unless it is an exact zero-distance hit, which always paints.
Otherwise the opacity falloff is linear in distance:
`falloff = clamp(1 - nearest / maxInfluence, 0, 1)`, multiplied into the cell weight,
then subject to the 0.12 alpha floor. So a halo is a disc of radius `0.22 × diag` whose
alpha decays linearly from the pin to the rim and clips hard at the rim, and a gradient is
the union of two such discs of radius `0.35 × diag` with IDW-blended colour between them.

`gradient` endpoint behaviour: at each observation the cell takes that observation's exact
E-L value (zero-distance rule) and that observation's recency weight; between them the
value moves smoothly with inverse-square weighting.

### Interaction with recency

Only influencing observations are counted for mode selection and drawn, so:

* A block whose only observations are 84+ days old is mode `stale` — no surface, median
  `null`, and the map reports "No current observations".
* An old-but-still-influencing observation produces a **dim** halo (its recency weight
  scales the cell weight and hence alpha) rather than a missing one.

---

## 8. Polygon processing

* **Coordinate ordering:** vertices are `{ lat, lng }` objects in stored order. Winding
  direction is irrelevant (even-odd test).
* **Algorithm:** standard ray-casting / even-odd crossing test:

  ```
  inside = false
  for i, j = 0, n-1; i < n; j = i++:
      yi, xi = poly[i].lat, poly[i].lng
      yj, xj = poly[j].lat, poly[j].lng
      if ((yi > pt.lat) != (yj > pt.lat)) and
         (pt.lng < ((xj - xi) * (pt.lat - yi)) / ((yj - yi) || EPSILON) + xi):
          inside = !inside
  ```

  `EPSILON` is the platform's smallest representable epsilon (JavaScript
  `Number.EPSILON = 2.220446049250313e-16`), used only to avoid division by zero on
  perfectly horizontal edges.
* **Edges and vertices:** results on an exact edge or vertex are the natural, unspecified
  outcome of the strict comparisons above; they are never special-cased. Grid cells rarely
  land exactly on an edge. Reproduce the comparisons exactly (strict `<`, strict `>`) and
  the behaviour matches.
* **Closure:** the polygon is treated as implicitly closed (the `j` index wraps). A
  duplicated final vertex equal to the first is harmless.
* **Invalid polygons:** fewer than 3 points → mode `no_polygon`, no grid, block listed
  separately in the status area as "observations recorded but no block boundary".
  Self-intersecting polygons are accepted as-is (even-odd semantics apply).
* **Holes / multipart:** **not supported.** A single ring per block.
* **Outside the polygon:** fully transparent (alpha 0). Colour never bleeds across a
  shared boundary because each block is interpolated from its own observations only.

---

## 9. Median and status

* **Median input:** the E-L values of the block's (or the map's) **influencing**
  observations only. Stale observations and unassigned observations are excluded.
* **Sorting:** ascending numeric (`a - b`).
* **Odd count:** middle element. **Even count:** arithmetic mean of the two middle
  elements (e.g. `[10, 20, 30, 40]` → `25`; `[12, 13]` → `12.5`).
* **Empty input:** `null`.
* **Display:** integers as `E-L 25`, non-integers to one decimal `E-L 12.5`, `null` as `—`.
  The underlying value is not rounded before comparison or storage.

### Status wording and meaning

| Phrase | Exact meaning |
|---|---|
| *N recorded observations available* | Count of qualifying observations at the selected date (`dayKey(obs) <= dayKey(D)`), within the selected Vintage, **including stale and unassigned ones**. |
| *N influencing the heat surface* | Count of qualifying observations that are **assigned to a block** and have `recencyWeight(age) > 0`. |
| *Typical current stage E-L X* | Median of those influencing, assigned observations. |
| *No current recorded stage influencing the surface* | Shown when that median is `null`. |
| *N stale observations (older than 84 days) shown as faded, dashed pins* | Assigned qualifying observations with `age >= 84`. |
| Block *"No observations"* (`none`) | Block has zero qualifying observations at this date. |
| Block *"No current observations"* (`stale`) | Block has qualifying observations but none influencing. |

---

## 10. Assignment and filtering

### Canonical assignment

**`pin_placements` is canonical, with the record's own `paddock_id` as fallback.**

For each record id, look up the canonical placement row. Let
`hasSignal = (row.is_location_assigned != null) || row.location_warning_code`.

```
explicitAssigned = hasSignal
    ? (row.is_location_assigned === true && row.location_warning_code !== "unassigned_location")
    : undefined

assigned  = explicitAssigned === undefined
              ? Boolean(record.paddock_id)                       // fallback
              : explicitAssigned && Boolean(record.paddock_id)

paddockId = assigned ? (record.paddock_id ?? null) : null
```

So the placement contract can only ever **revoke** an assignment or confirm it; the block
identity itself always comes from `paddock_id`.

### Exclusion / inclusion rules

| Case | Behaviour |
|---|---|
| `deleted_at` set | Excluded entirely (not a pin, not counted). |
| Wrong vineyard | Never fetched: every query is scoped to the selected vineyard id. Exclusion reason **`wrong_vineyard`**. This is *not* a date error — such records may carry perfectly valid dates and a valid Vintage under their own vineyard's season settings. |
| Missing / invalid coordinates | Excluded entirely. Valid latitude: finite number in `[-90, 90]` **and not exactly 0**. Valid longitude: finite number in `[-180, 180]` **and not exactly 0**. (Exact 0 is treated as an unset sentinel — Null Island is not a vineyard.) |
| No usable timestamp | Excluded entirely. Exclusion reason **`no_observation_date`**, used **only** when all of `date`, `completed_at` and `created_at` are absent. |
| E-L outside 1–43 or unparseable | Excluded entirely (see section 1). |
| Unassigned (per placement contract) | **Included** as a visible pin and counted in "recorded observations available", rendered with an outlined (transparent-fill) marker; contributes to **no** block, **no** median and **no** surface. |
| Future relative to the timeline date | Hidden completely at that date. |
| Block with no polygon | Mode `no_polygon`; its observations remain visible pins and are listed in the status area. |
| Block filter selected | Only that block is built; unassigned observations are hidden entirely while a single block is selected. |

---

## 11. Data source

### Primary read

`v_growth_stage_observations`, selected with `*` and filtered by `vineyard_id`. This view
already unifies the `growth_stage_records` table with legacy `pins`-based growth
observations and de-duplicates pins that have a mirrored `growth_stage_records` row.
It is the canonical remote source for mobile too.

### Fallback read

If the view is missing or not exposed — detected by an error message matching
`/relation|does not exist|not found|schema cache/i` — read `pins` directly with **all**
of the following conditions, in this order:

```
.eq("vineyard_id", <vineyardId>)
.is("deleted_at", null)
.or("mode.eq.Growth,growth_stage_code.not.is.null")
```

The two growth-identification branches live inside **one** grouped `OR`, so `OR` precedence
can never let a deleted record, a record from another vineyard, or an unrelated pin type
escape the vineyard and soft-delete scopes. Any other error is rethrown, not swallowed.

### Field mapping (view/pins row → normalised observation)

| Normalised field | Source, in precedence order |
|---|---|
| `id` | `id` |
| `vineyard_id` | `vineyard_id` |
| `paddock_id` | `paddock_id` |
| `paddock_name` | `paddock_name`, else the paddock lookup's `name` |
| `variety` | `variety`, else first entry of the paddock's `variety_allocations[].variety` |
| `growth_stage_code` | `el_stage_code` → `growth_stage_code` → `stage_code` |
| `growth_stage_label` | `el_stage_label` → `growth_stage_label` → `stage_label` |
| `date` (observation timestamp) | `date` → `observed_at` → `completed_at` → `created_at` |
| `photo_paths` | `photo_paths[]` if non-empty, else `[photo_path]`, else `[]` |
| `latitude` / `longitude` | `latitude` / `longitude` |
| `source` | `source` (`'record'` or `'pin'`) when the view reports it |

`updated_at` is carried but never used for timeline maths.

Blocks come from `paddocks` for the vineyard, excluding `deleted_at IS NOT NULL`, using
the stored polygon points.

### Deduplication and pagination

* Deduplication is performed **by the view**. The client does no extra de-duplication; on
  the fallback path duplicates between mirrored rows are possible and accepted.
* Growth observations are fetched in a single unpaginated request (subject to the server's
  row cap). Canonical placement enrichment is batched: placement rows are fetched from
  `pin_placements` with `pin_id IN (...)` in **chunks of 300 ids** and merged into a map
  keyed by `pin_id`. A missing placement row means "no signal" → `paddock_id` fallback.

---

## 12. Decisions recorded for mobile

* Heatmap range remains **E-L 1–43**.
* **E-L 47 is outside the ripeness heat surface and must not be clamped to E-L 43.**
* Mobile Vintage logic uses `season_start_month` / `season_start_day` via its shared
  `VintageResolver`. There is no hemisphere-driven Vintage rule.
* Mobile canonical assignment uses its existing `PinPlacementContract`, matching the
  revoke-only semantics in section 10.
* Canonical remote heatmap observations come from `v_growth_stage_observations`.
* Mobile caches a normalised form of those observations (post section-1/section-10
  normalisation is recommended, but the cache must retain the raw stage code and all three
  timestamp candidates so re-normalisation stays possible) and merges pending local
  records for offline operation. Locally-pending records follow identical rules.
* Mobile Vintage logic reproduces the authoritative database rule, including the
  1 January calendar-year case.
* **Full-precision intermediate values drive every calculation; rounded values are
  presentation-only and are never fed back in.**
* **No SQL or backend changes are authorised.**

---

## 12a. Numeric precision policy

* Every intermediate value — polygon diagonal, sparse influence radius
  (`diagonal * 0.22` or `* 0.35`), distances, IDW numerator/denominator, recency weights
  and cell weights — is carried at **full IEEE-754 double precision**. Nothing is rounded
  before being used in a further calculation.
* Rounding exists **only** at presentation and publication boundaries: `*_display`
  strings, the 0–255 alpha channel, and the six-decimal fields in the expected file
  (`polygon_diagonal_deg`, `max_influence_deg`, `idw_el`, `cell_weight`, `alpha_float`).
* The expected file additionally publishes `max_influence_deg_full_precision`,
  `idw_el_full_precision` and `cell_weight_full_precision`. Those are the values that
  actually drove the calculation; the six-decimal siblings are display copies.
* A conformant implementation reproduces the full-precision fields; the rounded fields may
  be compared to within 1e-6.

---

## 13. Using the fixture and expected files

`el-ripeness-heatmap-fixture.json` provides a southern vineyard (`season_start 7/1`) with
six blocks — two adjacent (`BLOCK_A` / `BLOCK_B` sharing longitude `138.5040`), a
single-observation block, a no-observation block, a polygon-less block and an even-count
median block — plus a northern `season_start 1/1` vineyard for the 1 January calendar-year boundary
(its two observations are excluded from the southern vineyard as `wrong_vineyard`, with
their own 1 January Vintages recorded) and
a vineyard with no season settings for the 1 July fallback. Observations cover E-L 1,
E-L 43, intermediates, stale, exactly-day-84, future, deleted, invalid, E-L 47, missing
coordinates and unassigned cases.

`el-ripeness-heatmap-expected.json` was generated by executing the shipped Portal
calculation code against that fixture. Top-level keys:

| Key | Contents |
|---|---|
| `constants` | The values in section 0, including anchor stops. |
| `el_parsing` | Every parse case → parsed value or `null`. |
| `colour_scale` | E-L → `rgb`, `hex`, `css`. |
| `recency` | Age (days) → weight, 10 decimal places. |
| `vintage_assignment` | (season start, date) → Vintage. |
| `season_ranges` | (season start, Vintage) → `startISO` / `endISO`. |
| `observation_normalisation` | Per observation: parsed E-L, exclusion reason, assignment, resolved block, Vintage, in-season flag. |
| `block_mode_selection` | Mode-selection truth table. |
| `median_cases` | Odd, even, empty medians. |
| `per_date` | For each of `2026-01-08`, `2026-01-21`, `2026-01-25`, `2026-04-30`: status counts, per-block mode / ids / median / diagonal / `maxInfluence` / grid bounds / per-observation recency weights, and per-sample-point inside-polygon, IDW value, cell weight, RGB, hex and alpha. |
| `block_isolation` | Proof that adjacent blocks' influencing sets are disjoint. |

Suggested equivalence test: reproduce every scalar in `el_parsing`, `colour_scale`,
`recency`, `vintage_assignment`, `observation_normalisation`, `median_cases`,
`block_mode_selection` exactly; and reproduce `per_date[].sample_points` to **1e-6**
for `idw_el` / `cell_weight` and **exactly** for `inside_polygon`, `rgb` and
`alpha_0_255`. That is sufficient to prove parity without any pixel comparison.

Selected anchors worth calling out (date `2026-01-25`):

* Status: 14 recorded observations available, 11 influencing, 2 stale (assigned).
* `BLOCK_A` mode `surface`, influencing `obs-a1, obs-a2, obs-a3`, median `E-L 23`.
* `BLOCK_B` mode `gradient`, `BLOCK_C` mode `halo`, `BLOCK_D` mode `none`,
  `BLOCK_E` mode `no_polygon`.
* `sp-A-centre` sits exactly on `obs-a2` → zero-distance rule → `E-L 23`, `#eac718`,
  cell weight `0.847864`, alpha `156`.
* `sp-C-far` lies inside `BLOCK_C` but beyond the halo radius → `null`, alpha `0`.
* At `2026-04-30`, every block except `BLOCK_A` has aged out: `BLOCK_B`/`BLOCK_C`/`BLOCK_F`
  are mode `stale` with median `null`, and `BLOCK_A` is a dim `halo` driven only by the
  observation that was in the future at earlier dates.

---

## Appendix A — exact pure calculation source

Reference implementation (TypeScript). Semantics, not syntax, are normative; where this
document and the code differ, the code wins.

```ts
export const EL_MIN = 1;
export const EL_MAX = 43;
export const RECENCY_HALF_LIFE_DAYS = 21;
export const RECENCY_MAX_AGE_DAYS = 84;
export const RECENCY_TAPER_DAYS = 14;
export const IDW_POWER = 2;

export type RGB = { r: number; g: number; b: number };

export const EL_COLOUR_STOPS: { el: number; rgb: RGB; label: string }[] = [
  { el: 1,  rgb: { r: 220, g: 38,  b: 38 }, label: "EL 1 — dormant" },
  { el: 12, rgb: { r: 234, g: 129, b: 24 }, label: "EL 12 — early development" },
  { el: 23, rgb: { r: 234, g: 199, b: 24 }, label: "EL 23 — mid-season" },
  { el: 35, rgb: { r: 132, g: 204, b: 22 }, label: "EL 35 — advanced" },
  { el: 43, rgb: { r: 22,  g: 143, b: 60 }, label: "EL 43 — harvest ripe" },
];

export function parseElStage(code: unknown): number | null {
  if (code == null) return null;
  const s = String(code).trim();
  if (!s) return null;
  const cleaned = s.replace(/^e\s*-?\s*l\s*/i, "").trim();
  const n = Number(cleaned);
  if (!Number.isFinite(n)) return null;
  if (n < EL_MIN || n > EL_MAX) return null;
  return n;
}

const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));
const mix = (a: number, b: number, t: number) => Math.round(a + (b - a) * t);

export function elColour(el: number): RGB {
  const v = clamp(el, EL_MIN, EL_MAX);
  const stops = EL_COLOUR_STOPS;
  if (v <= stops[0].el) return { ...stops[0].rgb };
  for (let i = 1; i < stops.length; i++) {
    const prev = stops[i - 1];
    const cur = stops[i];
    if (v <= cur.el) {
      const t = (v - prev.el) / (cur.el - prev.el);
      return {
        r: mix(prev.rgb.r, cur.rgb.r, t),
        g: mix(prev.rgb.g, cur.rgb.g, t),
        b: mix(prev.rgb.b, cur.rgb.b, t),
      };
    }
  }
  return { ...stops[stops.length - 1].rgb };
}

const validLat = (n: unknown): n is number =>
  typeof n === "number" && Number.isFinite(n) && n >= -90 && n <= 90 && n !== 0;
const validLng = (n: unknown): n is number =>
  typeof n === "number" && Number.isFinite(n) && n >= -180 && n <= 180 && n !== 0;

/** Observation timestamp — explicitly NOT `updated_at`. */
export function observationDate(r: GrowthStageRecord): string | null {
  return r.date ?? r.completed_at ?? r.created_at ?? null;
}

export function toObservations(
  records: GrowthStageRecord[],
  opts: { assignedById?: Map<string, boolean> } = {},
): HeatObservation[] {
  const out: HeatObservation[] = [];
  for (const r of records) {
    if ((r as any).deleted_at) continue;
    const el = parseElStage(r.growth_stage_code);
    if (el == null) continue;
    const lat = r.latitude;
    const lng = r.longitude;
    if (!validLat(lat) || !validLng(lng)) continue;
    const dateISO = observationDate(r);
    if (!dateISO) continue;
    const explicit = opts.assignedById?.get(r.id);
    const assigned = explicit === undefined ? !!r.paddock_id : explicit && !!r.paddock_id;
    out.push({
      id: r.id,
      paddockId: assigned ? r.paddock_id ?? null : null,
      assigned, el, lat, lng, dateISO, record: r,
    });
  }
  return out;
}

const dayKey = (iso: string) => String(iso).slice(0, 10);

export function filterToVintage(obs: HeatObservation[], startISO: string, endISO: string) {
  const s = dayKey(startISO);
  const e = dayKey(endISO);
  return obs.filter((o) => { const d = dayKey(o.dateISO); return d >= s && d <= e; });
}

export function qualifyingAt(obs: HeatObservation[], dateISO: string) {
  const d = dayKey(dateISO);
  return obs.filter((o) => dayKey(o.dateISO) <= d);
}

export function daysBetween(fromISO: string, toISO: string): number {
  const a = Date.parse(`${dayKey(fromISO)}T00:00:00Z`);
  const b = Date.parse(`${dayKey(toISO)}T00:00:00Z`);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return 0;
  return Math.round((b - a) / 86_400_000);
}

export function recencyWeight(ageDays: number): number {
  const age = Math.max(0, ageDays);
  if (age >= RECENCY_MAX_AGE_DAYS) return 0;
  const decay = Math.pow(0.5, age / RECENCY_HALF_LIFE_DAYS);
  const taper = clamp((RECENCY_MAX_AGE_DAYS - age) / RECENCY_TAPER_DAYS, 0, 1);
  return decay * taper;
}

export function isInfluencing(obs: HeatObservation, atDateISO: string): boolean {
  const age = daysBetween(obs.dateISO, atDateISO);
  return age >= 0 && recencyWeight(age) > 0;
}

export function partitionByInfluence(obs: HeatObservation[], atDateISO: string) {
  const influencing: HeatObservation[] = [];
  const stale: HeatObservation[] = [];
  for (const o of obs) (isInfluencing(o, atDateISO) ? influencing : stale).push(o);
  return { influencing, stale };
}

export function medianStage(obs: HeatObservation[]): number | null {
  if (!obs.length) return null;
  const v = obs.map((o) => o.el).sort((a, b) => a - b);
  const mid = v.length >> 1;
  return v.length % 2 ? v[mid] : (v[mid - 1] + v[mid]) / 2;
}

export function pointInPolygon(pt: LatLng, poly: LatLng[]): boolean {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const yi = poly[i].lat, xi = poly[i].lng;
    const yj = poly[j].lat, xj = poly[j].lng;
    const intersect =
      yi > pt.lat !== yj > pt.lat &&
      pt.lng < ((xj - xi) * (pt.lat - yi)) / (yj - yi || Number.EPSILON) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

export function polygonBounds(poly: LatLng[]) {
  let minLat = Infinity, maxLat = -Infinity, minLng = Infinity, maxLng = -Infinity;
  for (const p of poly) {
    minLat = Math.min(minLat, p.lat);
    maxLat = Math.max(maxLat, p.lat);
    minLng = Math.min(minLng, p.lng);
    maxLng = Math.max(maxLng, p.lng);
  }
  return { minLat, maxLat, minLng, maxLng };
}

export function blockHeatMode(count: number, hasPolygon: boolean, totalObservations = count) {
  if (!hasPolygon) return "no_polygon";
  if (count <= 0) return totalObservations > 0 ? "stale" : "none";
  if (count === 1) return "halo";
  if (count === 2) return "gradient";
  return "surface";
}

export function buildBlockHeat(input: BuildBlockHeatInput): BlockHeat {
  const { paddockId, paddockName, polygon, observations, atDateISO } = input;
  const resolution = input.resolution ?? 48;
  const hasPolygon = polygon.length >= 3;
  const { influencing, stale } = partitionByInfluence(observations, atDateISO);
  const mode = blockHeatMode(influencing.length, hasPolygon, observations.length);
  const base: BlockHeat = {
    paddockId, paddockName, polygon, observations, influencing, stale, mode,
    medianEl: medianStage(influencing), grid: null, weightGrid: null, gridBounds: null,
  };
  if (!hasPolygon || influencing.length === 0) return base;

  const b = polygonBounds(polygon);
  const grid: (number | null)[][] = [];
  const weightGrid: (number | null)[][] = [];
  const latStep = (b.maxLat - b.minLat) / (resolution - 1);
  const lngStep = (b.maxLng - b.minLng) / (resolution - 1);

  const pts = influencing.map((o) => ({
    lat: o.lat, lng: o.lng, el: o.el,
    w: recencyWeight(daysBetween(o.dateISO, atDateISO)),
  }));

  const diag = Math.sqrt(
    Math.pow(b.maxLat - b.minLat, 2) +
    Math.pow((b.maxLng - b.minLng) * Math.cos((b.minLat * Math.PI) / 180), 2),
  );
  const maxInfluence =
    mode === "halo" ? diag * 0.22 : mode === "gradient" ? diag * 0.35 : Infinity;

  for (let i = 0; i < resolution; i++) {
    const lat = b.minLat + latStep * i;
    const rowVals: (number | null)[] = [];
    const rowW: (number | null)[] = [];
    for (let j = 0; j < resolution; j++) {
      const lng = b.minLng + lngStep * j;
      if (!pointInPolygon({ lat, lng }, polygon)) { rowVals.push(null); rowW.push(null); continue; }
      let num = 0, den = 0, wNum = 0, nearest = Infinity;
      let exact: { el: number; w: number } | null = null;
      for (const p of pts) {
        const dLat = lat - p.lat;
        const dLng = (lng - p.lng) * Math.cos((lat * Math.PI) / 180);
        const d2 = dLat * dLat + dLng * dLng;
        nearest = Math.min(nearest, Math.sqrt(d2));
        if (d2 < 1e-14) { exact = { el: p.el, w: p.w }; break; }
        const wDist = 1 / Math.pow(Math.sqrt(d2), IDW_POWER);
        const w = wDist * p.w;
        num += p.el * w;
        den += w;
        wNum += p.w * wDist;
      }
      if (!exact && nearest > maxInfluence) { rowVals.push(null); rowW.push(null); }
      else if (exact) { rowVals.push(exact.el); rowW.push(exact.w); }
      else if (den > 0) {
        rowVals.push(num / den);
        const falloff = Number.isFinite(maxInfluence) ? clamp(1 - nearest / maxInfluence, 0, 1) : 1;
        rowW.push(clamp((wNum / (den || 1)) * falloff, 0, 1));
      } else { rowVals.push(null); rowW.push(null); }
    }
    grid.push(rowVals);
    weightGrid.push(rowW);
  }

  return { ...base, grid, weightGrid, gridBounds: b };
}

export function buildHeatModel(input: BuildHeatModelInput): HeatModel {
  const { observations, blocks, atDateISO } = input;
  const filter = input.blockFilter && input.blockFilter !== "all" ? input.blockFilter : null;
  const qualifyingAll = qualifyingAt(observations, atDateISO);
  const qualifying = filter ? qualifyingAll.filter((o) => o.paddockId === filter) : qualifyingAll;

  const byBlock = new Map<string, HeatObservation[]>();
  for (const o of qualifying) {
    if (!o.assigned || !o.paddockId) continue;
    const list = byBlock.get(o.paddockId) ?? [];
    list.push(o);
    byBlock.set(o.paddockId, list);
  }

  const wanted = filter ? blocks.filter((b) => b.id === filter) : blocks;
  const heat = wanted.map((b) => buildBlockHeat({
    paddockId: b.id, paddockName: b.name, polygon: b.polygon,
    observations: byBlock.get(b.id) ?? [], atDateISO, resolution: input.resolution,
  }));

  const assignedQualifying = qualifying.filter((o) => o.assigned && o.paddockId);
  const split = partitionByInfluence(assignedQualifying, atDateISO);

  return {
    blocks: heat,
    unassigned: filter ? [] : qualifying.filter((o) => !o.assigned || !o.paddockId),
    qualifying,
    influencing: split.influencing,
    stale: split.stale,
    medianEl: medianStage(split.influencing),
  };
}

export const formatEl = (el: number | null | undefined): string =>
  el == null ? "—" : `E-L ${Number.isInteger(el) ? el : el.toFixed(1)}`;
```

Rasterisation (colour + alpha) reference:

```ts
export function blockHeatDataUrl(block: BlockHeat, maxAlpha = 0.72) {
  // canvas is cols x rows; grid row 0 is the SOUTH edge, canvas row 0 is the NORTH edge.
  for (let i = 0; i < rows; i++) {
    const y = rows - 1 - i;
    for (let j = 0; j < cols; j++) {
      const el = block.grid[i][j];
      const idx = (y * cols + j) * 4;
      if (el == null) { img.data[idx + 3] = 0; continue; }
      const c = elColour(el);
      const w = block.weightGrid?.[i]?.[j] ?? 1;
      img.data[idx]     = c.r;
      img.data[idx + 1] = c.g;
      img.data[idx + 2] = c.b;
      img.data[idx + 3] = Math.round(255 * maxAlpha * Math.max(0.12, Math.min(1, w ?? 1)));
    }
  }
}
```

Vintage reference:

```ts
export const SEASON_DEFAULTS = { season_start_month: 7, season_start_day: 1 };

export function maxDayForMonth(month: number): number {
  if (month === 2) return 29;
  if ([4, 6, 9, 11].includes(month)) return 30;
  return 31;
}

function seasonYearOffset(month: number, day: number): number {
  return month === 1 && day === 1 ? 0 : 1; // SQL 119 resolve_vintage_year
}

export function currentVintageForSeason(month: number, day: number, now: Date = new Date()): number {
  const y = now.getFullYear();
  const offset = seasonYearOffset(month, day);
  const start = new Date(y, month - 1, day);
  return now >= start ? y + offset : y - 1 + offset;
}

export function seasonRangeForVintage(month: number, day: number, vintage: number) {
  const iso = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const startYear = vintage - seasonYearOffset(month, day);
  const start = new Date(startYear, month - 1, day);
  const endExclusive = new Date(startYear + 1, month - 1, day);
  const end = new Date(endExclusive.getTime() - 24 * 60 * 60 * 1000);
  return { startISO: iso(start), endISO: iso(end) };
}

export function vintageForDate(date: Date, month: number, day: number): number {
  return currentVintageForSeason(month, day, date);
}
```
