# Phase 2B — Irrigation Reporting Portal Contract (SQL 147)

Audience: Lovable portal team. This is the complete, authoritative contract for
the Phase 2B irrigation reporting layer. Do not reverse-engineer the SQL —
everything the portal needs is here.

Apply order: `sql/147_irrigation_phase_2b_reporting.sql`, then verify with
`sql/tests/147_irrigation_reporting_tests.sql` (single transaction, always
rolled back; expect `SQL 147 irrigation reporting tests: ALL PASSED`).

---

## 1. Core rules

- **All calculations are server-side.** The portal renders values verbatim and
  converts units for display only.
- **Canonical units (every response):** litres, litres_per_hour, hectares
  (with square-metre detail), millimetres, minutes. The envelope repeats this
  in `unit_context`.
- **Gating:** every RPC independently enforces System Administrator +
  vineyard membership (`irrigation_access_denied` error otherwise). Hidden
  navigation is not the security boundary.
- **Reversed sessions are excluded by default** (`p_include_reversed`).
- **Historical sessions are never recalculated** — reports aggregate the
  frozen `irrigation_session_blocks` snapshot values.
- **Null means "cannot be calculated safely"** (e.g. depth without saved
  serviced area), never zero. Warnings explain every gap.
- The **Phase 1 RPCs are unchanged** (`get_irrigation_vintage_summary`,
  `get_irrigation_valve_summary`, `get_irrigation_block_summary`,
  `get_irrigation_variety_summary`, `get_irrigation_daily_summary`,
  `get_irrigation_monthly_summary`) — released mobile builds still use them.
  The portal should use the Phase 2B namespace below.

## 2. Vintage and dates

- Vintage resolver: existing `resolve_vineyard_vintage_year` + the shared
  season settings (`vineyards.season_start_month/day`, default 1 July).
- Vintage period: `[season start in (vintage−1), day before season start in
  vintage]`. E.g. vintage 2026 with the default = 2025-07-01 → 2026-06-30.
- `p_vintage_year = null` → current vintage (server date).
- Custom ranges: pass `p_date_from` / `p_date_to` (applied inside the vintage).
- Sessions are matched on their **frozen** `vintage_year`.
- Week definition: **ISO weeks (Monday start)**.
- All dates are local vineyard dates; `timezone` in the envelope is
  informational (controller-import timezone where saved, else
  `Australia/Sydney`).

## 3. Rainfall source

`public.rainfall_daily` (SQL 028) is the single rainfall source. Best source
per day: `manual > davis_weatherlink > open_meteo`. A missing ELAPSED day
means "no data" — reports return `rainfall_data_complete=false` plus a
`missing_rainfall` / `partial_rainfall_coverage` warning, never a false zero.
`combined_water_input_mm = rainfall_mm + irrigation_depth_mm` (both mm; never
rainfall added to litres). Percent splits are null when combined input is 0.

### Rainfall coverage (SQL 149 — future dates never count as missing)

Coverage is measured against the elapsed part of the report period only,
cut at the **vineyard-local** today (vineyard timezone, never the UTC date):

- `rainfall_coverage_start` = period_start; `rainfall_coverage_end` =
  `least(period_end, vineyard_local_today)`; both null for fully-future
  periods.
- `rainfall_expected_days` = elapsed local days only (0 when the period has
  not started); `rainfall_observed_days` = elapsed days with a valid rainfall
  record — a recorded **0.0 mm day counts as observed** (coverage is
  existence-based, never `mm > 0`); `rainfall_missing_days` =
  expected − observed; `rainfall_future_days` = days after local today.
- `rainfall_data_complete` = `missing_days = 0`; **JSON null** when nothing is
  expected yet (render as "not yet applicable", not as incomplete).
- Warnings fire only for genuinely missing elapsed days, e.g. *"Rainfall data
  is missing for 2 of 29 elapsed day(s) in this period."* Future days never
  warn, never lower `data_quality`, and never appear as zero rainfall
  (`rainfall_mm` stays null for future rows).

## 4. Classifications

### Record source (`source_type` → `source_group`, label)

| source_type | source_group | source_label |
|---|---|---|
| manual_ios | manual | Manual (iOS) |
| manual_android | manual | Manual (Android) |
| manual_portal | manual | Manual (Portal) |
| galcon_gsi_import | controller_import | Galcon GSI import |
| controller_api | controller_import | Controller API |
| csv_import | controller_import | CSV import |
| system_generated | system | System generated |

### Calculation method (`calculation_method` → `measurement_group`, label)

| calculation_method | flow_is_estimated | measurement_group | calculation_label |
|---|---|---|---|
| total_volume | — | directly_reported | Total volume entered |
| controller_reported_volume | — | directly_reported | Controller-reported volume |
| meter_readings | — | directly_measured | Meter readings |
| session_flow | — | calculated | Session flow override × duration |
| configured_flow | false | calculated | Configured valve flow × duration |
| configured_flow | true | estimated | Configured valve flow × duration |

`flow_is_estimated` is the frozen snapshot flag from SQL 131 (emitter-derived
automatic flow). Galcon controller-reported volume is **never** classified as
a meter reading. Measurement labels: Directly reported / Directly measured /
Calculated / Estimated.

## 5. Effective irrigation & normalisation

- Efficiency source (priority order): the **frozen block-level value only**
  (`paddocks.irrigation_efficiency_percent` frozen into each session/block at
  record time). There is no system/valve/vineyard-level efficiency.
- `effective_* = gross × efficiency/100`, computed at record time and summed.
- Effective totals are returned **only when every included session/block has a
  frozen effective value**; otherwise null + `missing_irrigation_efficiency`
  warning (never a silent 100% assumption).
- Depth: `depth_mm = litres ÷ serviced_area_m²` (1 L/m² = 1 mm), using the
  SAVED session-block serviced area only.
- Per-hectare / per-vine: weighted totals — litres on covered blocks ÷ latest
  saved covered area/vines (`normalisation_basis:
  "latest_saved_serviced_values_weighted"`). Never averaged averages; vines
  and area are never double-counted across sessions.

## 6. Common filter parameters (identical names on every RPC)

```
p_vineyard_id uuid          (required)
p_vintage_year integer      (null = current vintage)
p_date_from date, p_date_to date
p_system_id uuid, p_water_source text, p_valve_id uuid,
p_block_id uuid, p_variety_id uuid
p_source_type text          (exact type, e.g. 'galcon_gsi_import')
p_source_group text         ('manual' | 'controller_import' | 'system')
p_calculation_method text
p_measurement_group text    ('directly_reported' | 'directly_measured' | 'calculated' | 'estimated')
p_include_estimated boolean default true
p_include_imported boolean default true
p_include_reversed boolean default false
```

Defaults: current vintage, imported + manual included, reversed excluded,
estimated included (but identified).

## 7. Envelope (every report response)

```json
{
  "report": "vintage_overview",
  "vineyard_id": "…", "vintage_year": 2026,
  "period_start": "2025-07-01", "period_end": "2026-06-30",
  "timezone": "Australia/Sydney", "generated_at": "…",
  "unit_context": {"volume":"litres","flow":"litres_per_hour","area":"hectares",
                   "area_detail":"square_metres","depth":"millimetres",
                   "rainfall":"millimetres","duration":"minutes"},
  "filters_applied": { …non-null filters… },
  "rows": [...] | …flat totals…,
  "warnings": [ {"code":"missing_serviced_area","severity":"warning",
                 "message":"…","affected_count":4} ]
}
```

Warning codes: `missing_serviced_area`, `missing_serviced_vines`,
`missing_irrigation_efficiency`, `missing_rainfall`,
`partial_rainfall_coverage`, `incomplete_historical_configuration`,
`estimated_flow_used`, `unknown_variety`, `missing_water_source`.

Data-quality score (`complete | mostly_complete | partial | limited`) on the
overview and trends: weakest of area/vines/efficiency completeness ratios
(≥99.9% + full rainfall = complete, ≥80% = mostly_complete, ≥40% = partial),
no sessions = limited.

## 8. The 13 RPCs

All take the §6 filters unless noted. All return jsonb envelopes.

1. **`get_irrigation_vintage_overview`** — flat totals: volume splits
   (total/effective/directly_reported/directly_measured/calculated/estimated/
   manual/imported/average_session_litres), runtime stats, coverage
   (systems/water_sources/valves/blocks/varieties/serviced area & vines),
   normalised (litres_per_hectare, litres_per_vine, irrigation_depth_mm,
   effective_irrigation_depth_mm), timing (first/last/days-since/highest-use
   day & month), previous-vintage comparison (previous_total_litres,
   volume_difference_litres/percent [null when base 0], previous_depth_mm,
   depth_difference_mm, previous_runtime_minutes, runtime_difference_minutes,
   previous_session_count, session_count_difference), rainfall_mm,
   rainfall_data_complete, rainfall_expected_days, rainfall_observed_days,
   rainfall_missing_days, rainfall_future_days, rainfall_coverage_start,
   rainfall_coverage_end, data_quality, warnings.
2. **`get_irrigation_daily_report`** (+`p_include_zero_days` default false) —
   `rows[]`: period_key (YYYY-MM-DD), totals, manual/imported/estimated/
   directly_reported litres, valves_used, blocks_irrigated, depth/effective
   depth, rainfall_mm, combined_water_input_mm, rainfall_data_complete
   (null for not-yet-elapsed rows), rainfall_expected_days,
   rainfall_observed_days, rainfall_missing_days, rainfall_future_days.
3. **`get_irrigation_weekly_summary`** (+`p_include_zero_weeks`) — ISO weeks;
   rows add `week_number`, period_key `IYYY-Wxx`.
4. **`get_irrigation_monthly_report`** — every month of the vintage incl.
   zero months; rows add month_key/month_label/month_start/month_end,
   serviced_area_hectares, litres_per_hectare, litres_per_vine, and
   previous-vintage month comparison (previous_vintage_total_litres,
   previous_vintage_depth_mm, difference_litres, difference_percent).
5. **`get_irrigation_valve_report`** — rows: valve identity, system,
   water_source, allocation_method ('mixed' when varying), automatic_flow_source
   ('measured_valve_flow' | 'configured_valve_flow' | null), counts, litres
   splits, runtime, average_session_minutes, **volume/runtime-weighted**
   average_flow_litres_per_hour, blocks_supplied, rows_supplied (from saved
   row ranges; null when unknown), first/last use, days_since_last_use,
   percent_of_vineyard_total, row-level warnings. Envelope has `total_litres`.
6. **`get_irrigation_block_report`** — per saved session-block allocation:
   block identity + latest variety, litres splits, runtime, saved area/vines,
   per-ha/per-vine/depth/effective depth, rainfall_mm + combined, first/last,
   previous_vintage_litres + difference, row warnings.
7. **`get_irrigation_variety_report`** — weighted per variety (variety_name
   'Unassigned' where blocks lack an assignment — those totals reconcile to
   the block report, not to a variety; flagged with `unknown_variety`).
8. **`get_irrigation_water_source_summary`** — per `irrigation_systems.water_source`
   ('unspecified' when null + `missing_water_source` warning): system/valve/
   session counts, litres splits, runtime, percent_of_vineyard_total,
   first/last use.
9. **`get_irrigation_calculation_source_summary`** — one row per
   (calculation_method, measurement_group): labels, session_count,
   total_litres, percent_of_total_litres, runtime_minutes.
10. **`get_irrigation_record_source_summary`** — one row per source_type:
    source_label, source_group, session_count, total_litres,
    percent_of_total_litres, first/last_recorded_at. Galcon is distinct.
11. **`get_irrigation_rainfall_summary`** (+`p_group_by`: 'day'|'week'|'month'|
    'vintage', default 'month'; extra param sits after `p_vintage_year`) —
    rows: period_key/start/end, rainfall_mm, gross_irrigation_depth_mm,
    effective_irrigation_depth_mm, combined_water_input_mm,
    irrigation/rainfall_percent_of_combined, rainfall_data_complete (null for
    not-yet-elapsed rows) + the coverage day counts (§3). The 'vintage'
    grouping recomputes depth over the whole period (never a sum of
    unweighted sub-period depths) and adds rainfall_coverage_start/end.
12. **`get_irrigation_vintage_trends`** (`p_vintage_year` = latest,
    `p_vintage_count` 1–10 default 5; **no date params**) — ascending rows per
    vintage: period, litres splits, runtime, session_count, area, per-ha/vine,
    depth/effective depth, rainfall_mm, rainfall_data_complete + coverage day
    counts (§3), combined, data_quality, warnings.
13. **`list_irrigation_report_sessions`** (+`p_limit` ≤200 default 50,
    `p_offset`) — drill-down. Returns `{sessions:[…existing session-detail
    model… + source_group, source_label, measurement_group,
    calculation_label], total_count, vintage_year, generated_at}`. Open
    individual sessions with the existing `get_irrigation_session`.

## 9. Drill-down contract

Every report row carries enough context to call
`list_irrigation_report_sessions` with the same filters plus the row key:
daily/weekly/monthly rows → `p_date_from/p_date_to = period_start/period_end`;
valve rows → `p_valve_id`; block rows → `p_block_id`; source rows →
`p_source_type`; calculation rows → `p_calculation_method`; water rows →
`p_water_source`.

## 10. Export contract

The report RPCs **are** the export RPCs: stable schemas, raw numerics, plus
`unit_context`, `generated_at`, `filters_applied` and `warnings` in every
envelope — feed them directly into CSV/Excel/PDF generation. Paginate
session exports through `list_irrigation_report_sessions`.

## 11. Reconciliation guarantees (tested)

Under identical filters: Σdaily = Σweekly = Σmonthly = overview total =
Σvalve = Σblock-allocated = Σwater-source = Σsource-type =
Σcalculation-method. Variety totals reconcile to block totals (differences
only from 'Unassigned' blocks, which are reported). Verified by
`sql/tests/147_irrigation_reporting_tests.sql` with mixed manual + Galcon +
reversed + partially-allocated fixtures.

## 12. Example response (fixture data — vintage overview)

```json
{
  "report": "vintage_overview", "vineyard_id": "…", "vintage_year": 2026,
  "period_start": "2025-07-01", "period_end": "2026-06-30",
  "timezone": "Australia/Sydney", "generated_at": "2026-07-29T…Z",
  "unit_context": {"volume":"litres","depth":"millimetres","duration":"minutes","area":"hectares","area_detail":"square_metres","flow":"litres_per_hour","rainfall":"millimetres"},
  "filters_applied": {"vintage_year":2026,"include_estimated":true,"include_imported":true,"include_reversed":false},
  "total_irrigation_litres": 20400, "effective_irrigation_litres": null,
  "directly_reported_litres": 17000, "directly_measured_litres": 1000,
  "calculated_litres": 0, "estimated_litres": 2400,
  "manual_litres": 8400, "imported_litres": 12000,
  "session_count": 4, "total_runtime_minutes": 300,
  "serviced_area_hectares": 1.0, "serviced_vines": 1000,
  "litres_per_hectare": 17400, "litres_per_vine": 17.4,
  "irrigation_depth_mm": 1.74, "effective_irrigation_depth_mm": null,
  "normalisation_basis": "latest_saved_serviced_values_weighted",
  "previous_vintage_year": 2025, "previous_total_litres": 7000,
  "volume_difference_litres": 13400, "volume_difference_percent": 191.4,
  "rainfall_mm": 8, "rainfall_data_complete": false,
  "rainfall_expected_days": 365, "rainfall_observed_days": 2,
  "rainfall_missing_days": 363, "rainfall_future_days": 0,
  "rainfall_coverage_start": "2025-07-01", "rainfall_coverage_end": "2026-06-30",
  "data_quality": "partial",
  "warnings": [
    {"code":"missing_serviced_area","severity":"warning","message":"Serviced area is unavailable for 2 irrigation session(s).","affected_count":2},
    {"code":"missing_irrigation_efficiency","severity":"warning","message":"Effective irrigation could not be calculated for 2 session(s) without a frozen irrigation efficiency.","affected_count":2},
    {"code":"partial_rainfall_coverage","severity":"warning","message":"Rainfall data is missing for 363 of 365 elapsed day(s) in this period.","affected_count":363}
  ]
}
```

(Values from the rolled-back test fixtures — a fully-ended historical period,
so every day is expected. For an IN-PROGRESS vintage, expected days cover only
the elapsed part: e.g. vintage 2027 on 29 July 2026 returns
`rainfall_expected_days: 29, rainfall_future_days: 336`, and with all 29
elapsed days recorded, `rainfall_missing_days: 0`,
`rainfall_data_complete: true` and NO rainfall warning. Live Stockmans Ridge
examples can be captured after SQL 147+149 are applied and the first Galcon
import is committed.)

## 13. Portal implementation notes

- Sections to build: Vintage Overview, Daily, Weekly, Monthly, Blocks,
  Valves, Varieties, Water Sources, Rainfall Comparison, Record Sources,
  Calculation Sources, Vintage Trends — same list as iOS/Android.
- Charts must keep an accessible numeric table alternative.
- Render `warnings` wherever present; show `data_quality` on Overview/Trends.
- After SQL 149, the false "missing for 336 of 365 days" warning disappears
  server-side — simply refresh the report; do NOT hide or patch warnings in
  TypeScript. Treat `rainfall_data_complete: null` as "not yet applicable".
- Display `Unassigned` variety rows honestly; do not hide them.
- Do not compute any totals client-side; the reconciliation guarantees only
  hold for server responses.
