# VineTrack Spray Report v1 contract

`SprayReportPayloadV1` is the only semantic input to a Spray Trip PDF. Export entry points may use native PDF drawing, but must not independently infer report facts.

## Classification

A trip is spraying when `trips.trip_function = 'spraying'` or a non-template, non-deleted `spray_records` row links to it. A spraying trip without a linked spray record must not fall back to a generic Trip Report.

## Canonical rules

- Active duration is wall time less valid pause intervals.
- Distance stays in metres in the payload; render km or miles according to vineyard region settings, including distances below one unit.
- Historical blocks come only from `spray_records.application_blocks`. Missing attribution is `null` and displays as “Not recorded”.
- Rows use `Complete`, `Partial`, or `Skipped/Not complete` and retain a source label.
- Tank attribution precedence is exact `tank_sessions.paths_covered`, explicit planned `rowApplications`, then session start/end boundaries against ordered `row_sequence`. Overlap is `Multiple` plus a warning.
- Planned chemistry is keyed by the frozen spray line ID. Actual matching precedence is `plannedChemicalId`, unique `savedChemicalId`, then unique normalized name and unit. Ambiguity remains unrecorded and produces a warning.
- Missing actual quantities are `null`; confirmed zero is a real zero and displays as “Not added”.
- Hourly weather is append-only and ordered by `sampleSlot`. The old scalar spray condition is only a labelled legacy start snapshot.
- The route image is private, generated once, and reused by all exporters. Style `spray-route-red-green-v1` uses a hybrid background, red/orange/yellow/green chronology, red start, and green finish.
- Cost is optional and returned only to owners and managers.

## Report and filename

Every spraying export is titled **Spray Report**. New files use:

`SprayReport_<Vineyard>_<YYYY-MM-DD>_<Reference>_<trip-id-first-8>-<ios|android|portal>.pdf`

The date is the trip start date in the vineyard timezone. Components are Unicode-normalized, trimmed, whitespace-to-underscore, and restricted to letters, numbers, underscores, and hyphens.

## Server paths

- `capture_trip_weather_observation_v1`: controlled idempotent capture into `trip_weather_observations`.
- `get_spray_report_v1`: authenticated membership-checked canonical report read.
- `trip_report_assets`: metadata for the private route PNG in `trip-report-assets`.

Clients may retain an offline projection with exactly the same rules, but an online final export should refresh from `get_spray_report_v1` after SQL 224 and 225 are deployed.
