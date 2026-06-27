# Trip Report Export — Backend Spec

This document describes the iOS Trip Report PDF (`TripPDFService.generatePDF`) so the Lovable backend can produce a byte-equivalent (or close) export from Supabase data.

It covers:

1. Data sources (Supabase tables / columns)
2. Section-by-section layout
3. Field formatting rules
4. Manual-correction event vocabulary
5. File naming

---

## 1. Data sources

All trip data lives in `public.trips` and is joined with vineyard / paddock metadata.

### `public.trips` columns used by the report

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | Trip id |
| `vineyard_id` | uuid | FK → `vineyards.id` |
| `paddock_id` | uuid | Single-block trips |
| `paddock_ids` | jsonb (uuid[]) | Multi-block trips |
| `paddock_name` | text | Snapshot at trip time |
| `tracking_pattern` | text | `sequential`, `every_other_row`, etc. |
| `start_time` | timestamptz | |
| `end_time` | timestamptz | nullable while active |
| `total_distance` | numeric | metres |
| `current_row_number` | numeric | |
| `next_row_number` | numeric | |
| `row_sequence` | jsonb (number[]) | Planned row/path sequence (decimals like 0.5, 2.5) |
| `path_points` | jsonb | `[{lat,lng,timestamp,...}]`, used for the route map |
| `completed_paths` | jsonb (number[]) | Paths the operator finished |
| `skipped_paths` | jsonb (number[]) | Paths marked partial / skipped |
| `pin_ids` | jsonb (uuid[]) | Pins logged during trip |
| `tank_sessions` | jsonb | Spray-only — see schema below |
| `active_tank_number` | int | |
| `total_tanks` | int | |
| `pause_timestamps` | jsonb (timestamptz[]) | For `activeDuration` calc |
| `resume_timestamps` | jsonb (timestamptz[]) | |
| `person_name` | text | Operator |
| `trip_function` | text | `seeding`, `harrowing`, `mowing`, `repairs`, `other`, or `custom:<slug>` |
| `trip_title` | text | Free-text label / details |
| `seeding_details` | jsonb | See schema below; only when `trip_function = 'seeding'` |
| `manual_correction_events` | jsonb (text[]) | Audit trail; see §4 |

### Joins

- **Vineyard name** → `vineyards.name`
- **Block grouping** → `paddocks` rows for each `paddock_id` in `paddock_ids`
- **Custom function label** → `vineyard_trip_functions` where `slug = right(trip_function, length(trip_function) - 7)` for `custom:<slug>` values
- **Pin count** → `count(*) from pins where id = any(trip.pin_ids)`

### `seeding_details` JSONB shape

```json
{
  "sowing_depth_cm": 2.5,
  "front_box": {
    "mix_name": "Autumn Cover Mix A",
    "rate_per_ha": 30,
    "shutter_slide": "3/4",
    "bottom_flap": "1",
    "metering_wheel": "N",
    "seed_volume_kg": 120,
    "gearbox_setting": 4
  },
  "back_box": { /* same shape, optional */ },
  "mix_lines": [
    {
      "id": "uuid",
      "name": "Ryecorn",
      "percent_of_mix": 60,
      "seed_box": "Front",
      "kg_per_ha": 18,
      "supplier_manufacturer": "AgriSeeds"
    }
  ]
}
```

A box should be treated as **used** only if it has at least one non-empty value (any of the 7 fields). Don't render the box section otherwise.

### `tank_sessions` JSONB shape (per element)

```json
{
  "id": "uuid",
  "tank_number": 1,
  "start_time": "2026-05-08T09:42:00Z",
  "end_time": "2026-05-08T10:05:00Z",
  "paths_covered": [0.5, 2.5],
  "start_row": 0.5,
  "end_row": 2.5,
  "fill_start_time": "2026-05-08T10:05:00Z",
  "fill_end_time": "2026-05-08T10:11:00Z"
}
```

---

## 2. Report layout

PDF page: A4 portrait, 595 × 842 pt, 40 pt margins.

### Title

```
Trip Report — {functionLabel}
```

`functionLabel` resolution:

1. If `trip_function` is a known enum (`seeding`, `harrowing`, `mowing`, `repairs`, `other`, …) → use its display name (`"Seeding"`, etc.).
2. If it starts with `custom:` → look up `vineyard_trip_functions.name` for that slug. If missing, fall back to the slug humanised (`custom:rolling` → `"Rolling"`).
3. If `trip_function` is null/empty → just `"Trip Report"` (no dash).

### Section: Trip Details

Two-column rows (label / bold value), in this order, omitting any blank value:

```
Vineyard            {vineyards.name}
Block               {paddock_name}                    -- if 1 block
Blocks              {p1}, {p2}, ...                   -- if 2+ blocks
Trip type           {functionLabel}
Trip details        {trip_title}                      -- only if non-empty AND != functionLabel
Operator            {person_name}
Date                {start_time → "8 May 2026"}        -- formatted in export TZ
Start time          {start_time → "9:42 AM"}
Finish time         {end_time   → "10:31 AM"}          -- if end_time
Duration            {activeDuration → "49m" or "1h 12m"}
Distance            {total_distance → "1.24 km" or "823m"}
Average speed       {avg → "5.4 km/h" or "—"}
Pattern             {tracking_pattern display name}
Pins logged         {pin_count}
```

**Important formatting**

- `Date` and `Start time` are on **separate lines** (do not combine).
- All timestamps render in the export `timeZone` chosen by the operator (default = device TZ).
- `activeDuration = (end_time ?? now) - start_time - sum(pause→resume gaps)`.
  - Pair `pause_timestamps[i]` with `resume_timestamps[i]`. If a pause has no matching resume, the trip ended while paused; stop accumulating at the pause time.
- `Average speed = total_distance / activeDuration`, displayed as `"%.1f km/h"`. Show `"—"` if either is zero.

### Section: Seeding Details

Only render when `trip_function = 'seeding'` and `seeding_details` has at least one meaningful value.

```
Sowing depth       {sowing_depth_cm} cm        -- if present
Front box used     Yes / No
Rear box used      Yes / No

[Front Box]                                    -- subheader, only if front used
  Mix              {mix_name}
  Rate/ha          {rate_per_ha} kg/ha
  Shutter slide    {shutter_slide}
  Bottom flap      {bottom_flap}
  Metering wheel   {metering_wheel}
  Seed volume      {seed_volume_kg} kg
  Gearbox setting  {gearbox_setting}

[Rear Box]                                     -- same shape, only if rear used

[Mix Lines]                                    -- only if mix_lines non-empty
  Line 1 — {name}
    % of mix       {percent_of_mix}%
    Seed box       {seed_box}
    Kg/ha          {kg_per_ha} kg/ha
    Supplier       {supplier_manufacturer}
  Line 2 — ...
```

Skip any individual field that is null/empty. Don't render an unused box at all.

### Section: Rows / Paths Covered

Only render when `row_sequence` is non-empty.

Group by paddock. For each block in `paddock_ids` (in order), include the subset of `row_sequence` that belongs to that paddock. (If you can't determine ownership, use the trip's single `paddock_name` as the only group.)

```
[Block name]                                   -- subheader (omit if only 1 group + empty name)
  Total planned                  {count}
  Completed                      {sorted list or "—"}
  Partial                        {sorted list}            -- only if non-empty
  Missed                         {sorted list}            -- only if non-empty
  Manually marked complete       {sorted list}            -- only if non-empty
```

- **Completed** = `plannedPaths ∩ completed_paths`
- **Partial**  = `plannedPaths ∩ skipped_paths`
- **Missed**   = `plannedPaths − completed_paths − skipped_paths`
- **Manually marked complete** = `Completed ∩ parseEndReviewCompleted(manual_correction_events)` — see §4.

Path numbers are formatted as integers when whole, otherwise `%.1f` (e.g. `0.5, 2.5, 4`).

### Section: Tank Sessions

Only for spray trips (`tank_sessions` non-empty).

```
Tank {n}             Complete | Active
  Rows               Row 0.5–2.5     -- omit if no startRow/endRow
  Duration           {end - start}    -- if end_time
  Fill Duration      {fill_end - fill_start}  -- if both present
```

### Section: Manual Corrections

Only when `manual_correction_events` is non-empty.

Render each event as `{time}  {description}` where the time is `HH:mm` formatted (`9:48 AM`) in export TZ. See §4 for the description mapping.

### Section: Costs

Only when `includeCostings` is true and at least one cost > 0.

```
{chemicalName1}      $1234.56
{chemicalName2}      $...
Chemical Subtotal    $...

Fuel Cost            $...     -- if > 0
{operatorCategory}   $...     -- if > 0; defaults to "Operator"
Total Cost           $...
```

Costs are computed app-side (chemicals from spray records, fuel/operator from settings). The backend can replicate using the same lookups or expose them as part of the export request payload.

### Section: Route Map

A snapshot of the path overlaid on Apple/Google hybrid map tiles, with green start dot and red end dot, gradient red→green polyline. Optional for backend; if not feasible, a static map link or omission is acceptable.

### Footer

```
Generated {now formatted} ({tz abbrev}) • VineTrack
```

---

## 3. Number / format rules

| Type | Rule |
|---|---|
| Path number | integer if whole (`%.0f`), else `%.1f` |
| Distance | `< 1000m` → `"{int}m"`; else `"%.2f km"` (metres / 1000) |
| Duration | `mins < 60` → `"{m}m"`; else `"{h}h {m}m"` |
| Average speed | `"%.1f km/h"`, or `"—"` |
| Money | `"$%.2f"` |
| Generic number | integer if whole, else `%g` |
| Date | localised long date (e.g. `"8 May 2026"`) |
| Time | localised short time (e.g. `"9:42 AM"`) |

---

## 4. Manual correction events

`trips.manual_correction_events` is `jsonb` storing `text[]`. Each entry is:

```
"<ISO8601 timestamp> <note>"
```

Example:

```json
[
  "2026-05-08T09:48:00+10:00 manual_next_path",
  "2026-05-08T10:22:00+10:00 end_review_completed: [10.5]",
  "2026-05-08T10:24:00+10:00 end_review_finalised"
]
```

### Note → human-readable description

| Note pattern | Description |
|---|---|
| `manual_next_path` | `Operator advanced to next row` |
| `manual_back_path: <row>` | `Stepped back to row <row>` |
| `manual_complete: <row>` | `Row <row> manually marked complete` |
| `manual_skip: <row>` | `Row <row> manually skipped` |
| `confirm_locked_path: <row>` | `Operator confirmed current row <row>` |
| `snap_to_live_path: <row>` | `Snapped planned sequence to live row <row>` |
| `auto_realign_accepted: <row>` | `Auto-realign accepted for row <row>` |
| `auto_realign_ignored: <row>` | `Auto-realign ignored for row <row>` |
| `paddocks_added: <names>` | `Added blocks: <names>` |
| `end_review_completed: [r1, r2, …]` | `End-review manually marked complete: [r1, r2, …]` |
| `end_review_finalised` | `End-trip review finalised` |
| anything else | passthrough as-is |

### Parsing `end_review_completed` for §2 "Manually marked complete"

For every entry whose note starts with `end_review_completed: [`, parse the comma-separated decimals between `[` and `]` and union the resulting set across all events. Intersect with `Completed` to derive the row list rendered under each block.

### Sorting

Render events in the order they appear in the array (chronological order is preserved on insert).

---

## 5. File naming

```
TripReport_{vineyardName}{suffix}_{startDate yyyy-MM-dd}.pdf
```

with spaces → `_`, slashes → `-`, colons → `-`. `suffix` may include the function label, e.g. `_Seeding`.

---

## 6. iOS reference

Source-of-truth implementation (so Lovable can match wording exactly):

- `ios/VineTrackV2/LegacyImported/Exports/Trips/TripPDFService.swift`
- `ios/VineTrackV2/LegacyImported/Models/Trip.swift`
- `ios/VineTrackV2/LegacyImported/Models/SeedingDetails.swift`
- `ios/VineTrackV2/Backend/Models/BackendTrip.swift` (Supabase column mapping)
- `sql/039_trips_manual_correction_events.sql` (migration)

If wording / ordering ever drifts, the iOS PDF service is canonical.
