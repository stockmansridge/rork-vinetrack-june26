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

## Additive SQL 228 — canonical facts and trip corrections

Run `sql/228_spray_report_canonical_facts_and_trip_corrections_v1.sql` once, then the rollback-only `sql/tests/228_spray_report_canonical_facts_and_trip_corrections_v1_tests.sql`. SQL 224–227 are already applied and must not be rerun.

The exact payload is `docs/spray-report-v1.schema.json`; real-shape fixtures are:

- `docs/fixtures/spray-report-v1-stockmans-ridge.json`
- `docs/fixtures/spray-report-v1-actual-corrections.json`

Online worksheet, detail and export renderers must consume `get_spray_report_v1` only. New canonical sections are `application`, `programStep`, `tankSessions`, `plannedChemicalTotals`, expanded `trip`/`equipment`, role-gated `cost`, `metadataCorrectionVersion`, and `metadataAmendments`. Base chemical amounts remain mL/g even when `unit` selects L/kg display; divide by 1,000 once. `plannedChemicalTotals` and `actualChemicalTotals` group by saved-product identity plus physical dimension, falling back to normalized name plus dimension only when no saved identity exists.

### Tractor, spray unit, operator and trip fuel correction

RPC: `correct_spray_trip_metadata_v1`.

Request fields:

```json
{
  "p_operation_id": "one UUID per Save attempt",
  "p_trip_id": "trip UUID",
  "p_expected_version": 2,
  "p_machine_id": "vineyard machine UUID or null",
  "p_tractor_id": "legacy tractor UUID or null",
  "p_spray_equipment_id": "spray unit UUID or null",
  "p_operator_user_id": "active vineyard member UUID or null",
  "p_fuel_consumption_l_per_hour": 6.8,
  "p_start_engine_hours": 1200.0,
  "p_end_engine_hours": 1203.1
}
```

The request is a complete correction snapshot: explicit null clears an overlay. Blank fuel rate means null; zero is invalid, not free fuel. A positive finite engine pair uses `end - start`; otherwise costing uses pause-adjusted active duration without synthesizing a start reading. Changing the spray unit never changes frozen tanks, chemicals, rows, route, actuals, weather or program provenance.

Response is `{ "correction": { ... "version": 3 }, "report": { ...schema 1.1... } }`. Reuse the operation UUID only for retries of the same Save. SQLSTATE `40001` means reload and reconcile; do not overwrite. Cross-vineyard equipment/operators and unauthorized roles are rejected. No-op snapshots do not increment the version or append history. Refresh worksheet, list and export state from `response.report` only after success.

Canonical precedence is: explicit correction overlay → trip recorded identity → spray-record historical snapshot. Fuel rate precedence is explicit trip correction → selected machine default → legacy tractor default → Not recorded. Metadata history is separate from the original operator identity and from tank-actual history.

### Row/block recovery action

RPC: `recover_spray_row_assignments_v1(p_operation_id, p_trip_id, p_assignments)` is Owner/Manager/Supervisor only. Each assignment requires stable `blockId` plus a `rowIdentity`; row number alone is never accepted as identity. Preserve source evidence verbatim:

```json
{
  "blockId": "uuid",
  "blockName": "North Block",
  "rowIdentity": "north-block:row:24.5",
  "rowNumber": 24.5,
  "tankSessionId": "recorded session id or null",
  "tankNumber": 1,
  "status": "Complete | Partial | Skipped/Not complete | Not recorded",
  "assignmentSource": "recorded_path_identity | saved_plan_identity | session_boundary_order | gps_geometry_intersection",
  "confidence": 1.0,
  "originalEvidence": { "immutable": "provider/input evidence" }
}
```

Precedence is recorded stable path identity, explicitly labelled saved-plan identity, valid session boundaries over the recorded ordered row sequence, then GPS/geometry intersection. GPS/geometry evidence is rejected below 0.90 confidence. Repeated row numbers across blocks remain separate because block and row identities are mandatory. Render `isDerived`, source and confidence; never rewrite or hide `originalEvidence`. If the evidence does not clear these thresholds, leave the assignment null and show the warning.

## Additive SQL 229 — genuine hourly weather and archive recovery

Run `sql/229_trip_hourly_weather_recovery_v1.sql` once after 228, then `sql/tests/229_trip_hourly_weather_recovery_v1_tests.sql`. Deploy `supabase/functions/spray-weather-recovery/index.ts` after SQL 229.

Clients call the authenticated function with `{ "tripId": "uuid", "through": "ISO-8601 UTC" }` at spray start, each scheduled hour, resume/restart, trip end and before an online export. The database computes every missing scheduled slot, so absence itself is a durable retry queue across suspension, offline periods and process restarts. A transient network/provider error leaves the slot missing for retry; it is not relabelled unavailable.

The deployed recovery function currently supports genuine Weather Underground PWS current observations and its hourly archive. It selects only an observation within 30 minutes of the requested slot and preserves `observedAt`, `stationId`, provider record identity, retrieval time, and `retrievalMode` (`live` or `historical_archive`). A definitive archive no-data response may record unavailable. Current observations and daily summaries must never fill historical slots. Providers without a supported hourly archive remain pending/not recorded rather than receiving invented values.

`weather[]` also carries a separate `legacy_snapshot` item when historical scalar values survive on the spray record. It is not an hourly sample. Genuine observed/manual evidence cannot be overwritten by a later unavailable/modelled retry.

## Authenticated canonical route upload/register/reuse

Deploy `supabase/functions/spray-report-route-upload/index.ts`; no production credential needs to be requested because it uses the deployment environment's existing Supabase variables. The function requires the exporting user's JWT, verifies trip visibility, accepts only a PNG up to 10 MB, computes SHA-256 server-side, uploads with service authority, and calls the already-applied SQL 226 registration RPC as that user. Direct bucket or metadata writes remain closed.

Request:

```json
{
  "tripId": "uuid",
  "routeHash": "64 lowercase SHA-256",
  "pngBase64": "optional base64 PNG bytes",
  "coordinates": [{ "latitude": -33.1, "longitude": 149.1 }],
  "width": 1030,
  "height": 700
}
```

Send either approved 1030×700 PNG bytes or the complete oldest-to-newest coordinate sequence. When bytes are absent, the trusted function generates a 1030×700 Google hybrid image using the deployment's existing server-side Maps key; it samples rendering vertices only to satisfy Static Maps URL limits while the route hash remains over the complete unchanged coordinate sequence.

Response: `{ "route": { "bucket", "objectPath", "sha256", "routeHash", "styleVersion" }, "uploadedSha256", "reusedExisting" }`. Always use/download `response.route`; it may be a concurrent immutable winner. Losing objects are removed. Verify downloaded bytes against `route.sha256` before export.

Route input hash bytes are UTF-8 for `spray-route-red-green-v1|1030x700|lat,lon|...` in oldest-to-newest order, each coordinate rounded to exactly six decimal places with `.` decimal separator. Image chronology is full-route red oldest/start → orange → yellow → lime → green newest/finish, hybrid imagery, 1030×700 pixels. Preserve aspect ratio. An offline local image is explicitly non-canonical and must retain a warning. All later online exports reuse the registered bytes.

## Portal rendering and edit rules

- Inline Edit changes supported worksheet values into controls in place. Save submits complete snapshots; Cancel performs no calls.
- During edit, export the last saved report or require Save/Cancel. Never export unsaved values silently.
- Use one wrapping `Item | Planned | Actual` table per tank, Water first. Missing actual is `Not recorded`; explicit chemical zero is `Not added`.
- Repeat table headers over page breaks. Render rate/basis details below the table, not inside squeezed legacy columns.
- Humanize status/provenance tokens while retaining their machine value for diagnostics.
- `cost` is null for non-Owner/Manager callers. Never reconstruct or leak financials locally.
- Show active, elapsed and paused duration separately. A completed trip with an open tank session is `End not recorded`, not Active.
- Fetch fresh canonical data on open and after every successful correction/recovery/upload action. A failed read is not an empty record.

## Deployment and verification boundary

Required order: SQL 228 + test, SQL 229 + test, deploy `spray-weather-recovery`, deploy `spray-report-route-upload`, then wire/release portal changes. The repository implementation is not production deployment evidence. Verify with an ordinary authorized user: correction/reopen/conflict, historical slot retrieval, upload/register/download/SHA reuse, repeated row numbers in two blocks, unauthorized cost read, and rendered multipage PDFs.
