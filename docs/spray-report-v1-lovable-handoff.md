# Lovable handoff — Spray Report v1

Lovable must implement these portal changes separately after SQL 224 and 225 are run:

- Fetch `get_spray_report_v1(p_trip_id)` for every spraying export from Trips, Spray Records, and Documents.
- Classify linked legacy spray records as spraying and never send them to generic `downloadTripPdf`.
- Block export with “Spray record not available yet—sync and retry” when a spraying trip has no linked record.
- Render only the canonical payload; remove direct legacy tank-key parsing from `sprayRecordPdf.ts`.
- Render hourly weather, equipment/engine hours, canonical rows/tanks, completeness warnings, and role-gated costs.
- For generic legacy parsing only, accept `tank_sessions[*].paths_covered`; do not use that generic path for Spray Reports.
- Fetch and embed the private route object identified by payload metadata. If absent, generate the deterministic hybrid five-stop red-to-green fallback once, upload it, and write metadata through the controlled backend path.
- Use `SprayReport_<Vineyard>_<YYYY-MM-DD>_<Reference>_<trip-id-first-8>-portal.pdf` with the shared sanitization rules.
- Update portal copy so Trip Reports means non-spray reports and spraying rows download a Spray Report.
- Add portal fixture/schema tests and RLS tests; compare semantic output against `docs/fixtures/spray-report-v1-stockmans-ridge.json`.

Do not create a competing payload, weather table, route style, or tank matching rule in Lovable.
