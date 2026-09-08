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

## Controlled canonical route registration

After SQL 226 is applied, stop writing `trip_report_assets` directly. Upload the PNG to the private `trip-report-assets` bucket through the existing trusted upload path, beneath `{tripId}/`, then call the RPC with the exporting user's authenticated JWT.

RPC: `register_spray_report_route_asset_v1`

Request fields:

- `p_trip_id`: trip UUID.
- `p_bucket`: exactly `trip-report-assets`.
- `p_object_path`: safe `.png` path beginning `{tripId}/`.
- `p_sha256`: lowercase 64-character SHA-256 of the PNG.
- `p_route_hash`: non-empty shared route-input hash.
- `p_style_version`: exactly `spray-route-red-green-v1`.

Response fields are the canonical `SprayReportPayloadV1.route` object: `bucket`, `objectPath`, `sha256`, `routeHash`, and `styleVersion`. Always use the returned object; when another export registered first, the RPC returns that existing immutable winner instead of replacing it.

## Audited actual-use corrections (SQL 227)

Run `sql/227_spray_actual_corrections_v1.sql`, then the rollback-only `sql/tests/227_spray_actual_corrections_v1_tests.sql`. Do not rerun SQL 224–226.

Use only `correct_spray_tank_actual_v1`; never write `spray_tank_actuals` or `spray_tank_actual_amendments` directly. Send the authenticated user's JWT. The server derives the editor ID, display-name snapshot, and timestamp.

Request:

- `p_operation_id`: a new UUID generated once per Save attempt and reused for retries of that same Save.
- `p_actual_id`: existing `tanks[].actualId`, or a new UUID when `actualVersion` is `0` and no actual row exists.
- `p_trip_id`, `p_spray_record_id`, `p_tank_session_id`, `p_tank_number`: the exact canonical identities; they are cross-checked against the frozen trip and spray plan.
- `p_expected_version`: the current `tanks[].actualVersion`; use `0` for first entry. SQLSTATE `40001` means reload and reconcile a version conflict.
- `p_water_volume_l`: litres, nullable. JSON `null` means Not recorded; `0` is an explicit recorded zero.
- `p_chemicals`: the complete saved actual-chemical snapshot for that tank. Omitting a prior line clears/removes that actual observation. Amounts are non-negative base units: mL for liquid dimensions and g for solid dimensions.

Each chemical object is:

```json
{
  "id": "stable-actual-line-uuid",
  "plannedChemicalId": "planned-line-uuid-or-null",
  "savedChemicalId": "vineyard-product-uuid-or-null",
  "replacesPlannedChemicalId": "planned-line-uuid-or-null",
  "usageKind": "planned | substitution | additional",
  "name": "Recorded product name",
  "actualAmountBase": 1250,
  "unit": "Litres | mL | Kg | g"
}
```

Rules:

- `planned` requires `plannedChemicalId` and no replacement ID.
- `substitution` requires `plannedChemicalId: null` plus `replacesPlannedChemicalId`; the planned line remains unchanged and visible.
- `additional` has both planned/replacement IDs null.
- Any `savedChemicalId` must be a live product in the trip vineyard. Planned/replacement IDs must belong to that exact frozen tank plan.
- Blank UI quantity means remove/omit the actual line; zero means retain the line with `actualAmountBase: 0`.
- Save all edited tanks separately with distinct operation IDs. Do not update worksheet state or export draft values until every required RPC has succeeded and `get_spray_report_v1` has been refreshed. Cancel performs no calls.

Response:

```json
{
  "actual": { "id": "...", "water_volume_l": 1200, "chemicals": [], "correction_version": 3, "last_corrected_at": "..." },
  "amendments": []
}
```

A repeated operation ID is idempotent. A semantic no-op appends no history. Actual and history changes commit in one transaction. Once a row has a correction version, the legacy offline-confirmation RPC cannot overwrite it; mobile sync receives the authoritative row.

Canonical report schema is now `1.1`:

- `tanks[].actualId` and `tanks[].actualVersion` drive version-checked edits.
- Planned chemical rows remain in `tanks[].chemicals` with `usageKind: "planned"` and their frozen `plannedAmountBase`.
- Substituted/additional rows are appended with nullable `plannedChemicalId`/`plannedAmountBase`, `matchSource: "actualOnly"`, and explicit `usageKind`/`replacesPlannedChemicalId`.
- Top-level `actualChemicalTotals[]` groups every recorded actual line once by saved-product identity, or normalized name + unit when no saved identity exists.
- Top-level `amendments[]` contains `operationId`, tank/product identities, field, change kind, previous/new JSON value and units, revision, server-authored `editedBy`, `editorName`, and `editedAt`.

Render the current actuals and a readable amendment history in the vineyard timezone. Actual totals must include every actual line once, including substitutions and additions, without changing planned totals. Keep all monetary output under the existing financial-role gate.

For PDF branding, resolve the vineyard from `identity.vineyardId`, not the portal's currently selected vineyard. Wait for that configured logo to load; fail with an honest warning if a configured object cannot be fetched/decoded. Draw it aspect-fit at top left. Draw the bundled official VineTrack mark at bottom left of every page, reserve header/footer space, and keep page numbering clear.
