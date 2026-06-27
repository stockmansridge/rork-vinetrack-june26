# Android Cost / Export Rollup — Status Note

Internal status tracker for the Android (`android-vinetrack`) spray/trip cost
rollup and export work. No schema/RLS changes were made by any stage below; all
cost outputs are read-only and owner/manager gated. iOS remains the source of
truth for parity.

---

## Stage 3F-3 cost/export series — CLOSED

Status: **Complete and QA-passed.** Build/checks pass.

Android now has read-only spray/trip cost rollups based on the pure
`TripCostEstimator`. Costing uses:

- **Labour** — operator category hourly rate × active duration.
- **Fuel** — engine-hours/duration × machine fuel rate × weighted
  `fuel_purchases` (via `TripFuelEstimator`).
- **Chemicals** — spray record chemical cost snapshots.
- **Total** — labour + fuel + chemical.
- **Cost / ha** — single-paddock trips only, where reliable.

### Completed and QA-passed items

| Stage | Scope |
|---|---|
| 3F-3a | Read-only fuel litres + fuel cost estimate. |
| 3F-3b-i | Labour + fuel + chemical + total cost rollup. |
| 3F-3b-ii | Read-only cost per hectare for single-paddock linked trips. |
| 3F-3c-i | Single spray-record PDF Cost Breakdown. |
| 3F-3c-ii | Program CSV owner/manager-only trailing cost columns. |
| 3F-3c-iii | Program PDF full cost summary. |

### Where cost outputs appear

- Trip detail
- Spray detail
- Single spray-record PDF
- Program CSV (trailing owner/manager-only columns)
- Program PDF (full cost summary)

### Guarantees

- All financial UI/export surfaces are owner/manager gated; non-financial roles
  receive no cost sections/columns (omitted, not blanked).
- Program CSV remains import-safe — new cost columns are trailing and
  export-only; the importer ignores them by name.
- No cost allocations are persisted (`TripCostAllocation` not written).
- No schema/RLS changes.

### Key files

- `android-vinetrack/.../data/TripCostEstimator.kt`
- `android-vinetrack/.../data/TripFuelEstimator.kt`
- `android-vinetrack/.../data/SprayRecordPdfExporter.kt`
- `android-vinetrack/.../data/SprayProgramCsvExporter.kt`
- `android-vinetrack/.../data/SprayProgramPdfExporter.kt`
- `android-vinetrack/.../ui/screens/SpraysScreen.kt`
- `android-vinetrack/.../ui/screens/TripsScreen.kt`

---

## Parked items

- Program-level estimator-area cost/ha reconciliation.
- Yield / cost-per-tonne.
- Multi-block area summing (Android persists a single `paddock_id` only).
- `TripCostAllocation` persistence.
- Automatic row-lock / GPS completion.
- iOS/Android fuel-model unification (iOS Program PDF uses a legacy season-rate
  fuel model; Android uses the weighted `fuel_purchases` model) — revisit only
  if parity is later required.
