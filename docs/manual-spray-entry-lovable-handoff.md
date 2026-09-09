# Manual spray entry contract for Portal

## Deployment status and prerequisites

Jonathan confirmed that `sql/232_manual_spray_entry_v1.sql` and its supplied rollback-only test SQL ran successfully. **Do not rerun either file.** The deployed 232 contract is therefore available now.

Latest synced implementation baseline: `f90b8658` (`Finished mobile corrections and delivered the shared manual spray entry groundwork`).

Jonathan successfully applied `sql/233_manual_spray_entry_corrections.sql`. Its first behavioral-test run then exposed a pre-existing runtime grouping defect in the canonical report layer from SQL 228 (`SQLSTATE 42803`); the SQL 233 transaction itself is not to be rerun. The additive repair is `sql/234_spray_report_chemical_aggregate_fix.sql`. Jonathan must run SQL 234, then rerun the updated rollback-isolated `sql/tests/233_manual_spray_entry_behavior_tests.sql`. SQL 234 changes no public RPC signature or report schema.

## Source and identity

Database fields on both `spray_records` and `trips`:

- `entry_source`: `manual`, `tracked`, or `NULL` (historical origin unknown).
- `manual_entry_id`: UUID, required only for `manual`; the same UUID is stored on the spray record and its exclusively owned backing trip.

Never infer source. A manual application is exactly `entry_source === "manual"`. Display **Manual entry** and a pencil icon separately from **Completed**. Unknown is not tracked. Triggers preserve an existing manual source when an older client omits or tries to clear it.

## Released-client and report compatibility

SQL 232 changes `get_spray_report_v1` to schema `1.2` for manual **and tracked** applications. The change is additive: existing tracked report fields, planned-versus-actual semantics, rows, route, weather and financial visibility remain unchanged. Current iOS and Android decoders accept the 1.2 additions and do not reject a report merely because `schemaVersion` changed.

Already released clients still matter. Their report decoders ignore unknown additive fields, so tracked report parsing remains compatible. However, released spray-record decoders require legacy tank JSON keys. SQL 232's first manual projection omitted several of those keys, so an older installation may fail to decode a manual `spray_records` row even though its canonical report is valid. SQL 233 adds/backfills only those compatibility keys without inventing planned quantities; actual authority remains `spray_tank_actuals`. Lovable should not work around this by inventing plan values.

Lovable must parse schema 1.2 now, preserve tracked behavior, read `provenance` additively, allow nullable planned amounts, and use `captured` (never `filled`) for historical weather responses.

## Functions

### Save or edit

`save_manual_spray_v1(p_operation_id uuid, p_payload jsonb, p_expected_version integer default null)`

- Create: pass `p_expected_version: 0` (or null).
- Edit: pass the current spray-record `syncVersion`.
- Allocate `operationId`, `manualEntryId`, `sprayRecordId`, `tripId`, every tank `id`/`actualId`, and every chemical-line `id` once. Persist them in the draft and reuse them for every retry.
- A repeated operation ID with the identical payload returns its original result while the application is active. After deletion, the tombstone is authoritative and SQL 233 makes the same cached save retry fail with SQLSTATE `55000`; clients must never present that historical response as current confirmation.
- Reuse with a different payload/expected version is rejected.
- A stale edit is rejected with SQLSTATE `40001`; reload and ask the user to reconcile. Never silently overwrite.

Request:

```json
{
  "p_operation_id": "10000000-0000-4000-8000-000000000001",
  "p_expected_version": 0,
  "p_payload": {
    "vineyardId": "20000000-0000-4000-8000-000000000001",
    "manualEntryId": "30000000-0000-4000-8000-000000000001",
    "sprayRecordId": "40000000-0000-4000-8000-000000000001",
    "tripId": "50000000-0000-4000-8000-000000000001",
    "reference": "Night mildew application",
    "operationType": "Foliar Spray",
    "startUtc": "2026-09-08T13:30:00Z",
    "endUtc": "2026-09-08T16:15:00Z",
    "vineyardTimeZone": "Australia/Adelaide",
    "tractorId": "60000000-0000-4000-8000-000000000001",
    "operatorUserId": "70000000-0000-4000-8000-000000000001",
    "sprayEquipmentId": "80000000-0000-4000-8000-000000000001",
    "startEngineHours": 1432.4,
    "endEngineHours": 1435.1,
    "notes": "Completed before rain.",
    "clientUpdatedAt": "2026-09-09T01:20:00Z",
    "blocks": [
      {"blockId":"90000000-0000-4000-8000-000000000001","blockName":"Home Shiraz"},
      {"blockId":"90000000-0000-4000-8000-000000000002","blockName":"Creek Cabernet"}
    ],
    "tanks": [
      {
        "id":"a0000000-0000-4000-8000-000000000001",
        "actualId":"b0000000-0000-4000-8000-000000000001",
        "tankNumber":1,
        "waterVolumeLitres":2000,
        "chemicals":[{
          "id":"c0000000-0000-4000-8000-000000000001",
          "savedChemicalId":"d0000000-0000-4000-8000-000000000001",
          "name":"Example Liquid Fungicide",
          "actualAmountBase":2500,
          "unit":"Litres",
          "productCategory":"fungicide",
          "physicalForm":"liquid",
          "snapshotAt":"2026-09-09T01:18:00Z"
        }]
      },
      {
        "id":"a0000000-0000-4000-8000-000000000002",
        "actualId":"b0000000-0000-4000-8000-000000000002",
        "tankNumber":2,
        "waterVolumeLitres":1500,
        "chemicals":[{
          "id":"c0000000-0000-4000-8000-000000000002",
          "savedChemicalId":"d0000000-0000-4000-8000-000000000002",
          "name":"Example Solid Fungicide",
          "actualAmountBase":750,
          "unit":"Kg",
          "productCategory":"fungicide",
          "physicalForm":"solid",
          "snapshotAt":"2026-09-09T01:18:00Z"
        }]
      }
    ],
    "manualWeather": {
      "observedAt":"2026-09-08T13:30:00Z",
      "source":"Operator observation",
      "temperatureC":18.2,
      "humidityPct":71,
      "windSpeedKmh":6.4,
      "windGustKmh":9.1,
      "windDirectionDeg":210,
      "rainMm":0
    }
  }
}
```

`actualAmountBase` is always mL for liquid products and g for solid products, regardless of display unit. Thus the fixture means 2.5 L and 0.75 kg. `unit` records the selected wire/display unit and must stay dimension-compatible. Valid wire values are `Litres`, `mL`, `Kg`, `g`.

Response:

```json
{
  "operationId":"10000000-0000-4000-8000-000000000001",
  "manualEntryId":"30000000-0000-4000-8000-000000000001",
  "sprayRecordId":"40000000-0000-4000-8000-000000000001",
  "tripId":"50000000-0000-4000-8000-000000000001",
  "source":"manual",
  "status":"completed",
  "syncVersion":1,
  "serverConfirmed":true
}
```

### Delete

`delete_manual_spray_v1(p_operation_id, p_vineyard_id, p_manual_entry_id, p_spray_record_id, p_trip_id)`

This writes a durable tombstone first, then soft-deletes the manual spray, its exclusively owned manual trip, and tank actuals. It is idempotent even if deletion reaches the server before an offline create replay. A later save/replay for that manual ID is rejected. It never accepts a tracked trip.

### Report

`get_spray_report_v1(p_trip_id)` remains the only canonical online report read. SQL 232 advances it to schema `1.2` and adds:

```json
{
  "provenance": {
    "source":"manual",
    "manualEntryId":"30000000-0000-4000-8000-000000000001",
    "isManualEntry":true,
    "label":"Manual entry"
  },
  "recordingEvidence": {
    "route":"Not recorded — manual application",
    "rows":"Not recorded — manual application"
  }
}
```

For manual entries, `plannedWaterLitres` and `plannedAmountBase` are null, actual quantities come from `spray_tank_actuals`, `plannedChemicalTotals` is empty, and `application.actualUseBasis` is `manually_recorded_actual_use`. Normal tracked reports keep existing planned-versus-actual behavior. Costs remain present only for Owner/Manager.

Portal report rendering must automatically place a pale diagonal **MANUAL ENTRY** watermark on every page when `provenance.isManualEntry` is true. There is no toggle. Mixed reports watermark only manual application pages/sections. CSV adds a `Source` column with `Manual entry`, `Tracked application`, or `Origin not recorded`.

## Permission and validation rules

Create, edit, delete, and the manual-specific report action are Owner/Manager/Supervisor only. Operators can still create/update normal tracked sprays, but direct writes to manual rows are rejected. Recheck the current vineyard role immediately before RPC replay.

The save RPC requires:

- authenticated Owner, Manager, or Supervisor;
- nonblank reference;
- end after start (midnight crossing is valid because UTC instants are compared);
- exactly one active vineyard tractor, one vineyard member as operator, and one active spray unit;
- at least one active vineyard block;
- at least one tank and at least one Chemical Store product per tank;
- unique stable tank IDs/numbers and finite nonnegative water/chemical quantities;
- optional finite nonnegative engine readings, with end not below start when both are supplied;
- product category and physical form as separate frozen facts, an honest `snapshotAt`, and a unit matching liquid/mass dimension.

The RPC never updates the tractor's current meter. Costing uses a strictly positive end-minus-start delta; otherwise canonical reporting uses recorded duration.

## Offline behavior

Persist the complete request before showing success. Until the RPC response is stored, say **Saved on this device — awaiting sync**. Replay the identical IDs and payload. A delete removes/suppresses the visible local application and records a durable delete operation; do not replay queued saves, actuals, or weather after that tombstone.

## Weather contract

Manual weather is optional. It is stored as manual evidence and wins over later station recovery. Do not put current weather into a historical application.

Station recovery is an explicit post-save action against the completed backing trip:

`POST /functions/v1/spray-weather-recovery`

```json
{"tripId":"50000000-0000-4000-8000-000000000001","through":"2026-09-08T16:15:00Z"}
```

Response (there is no `filled` field):

```json
{
  "success":true,
  "captured":3,
  "unavailable":0,
  "pending":0,
  "provider":"davis_weatherlink",
  "stationId":"station-123",
  "errors":[]
}
```

Supported recovery providers are `davis_weatherlink` and `wunderground`. `captured` means persisted genuine observations. Reload `get_spray_report_v1` after recovery. Missing credentials/archive data must not block manual save.

**Deployment status, verified separately from SQL:** source exists at `supabase/functions/spray-weather-recovery/index.ts`, but live deployment is still **unverified**. Repository searches show it is not included by the default deploy scripts. The available project deployment/log tooling could not enumerate this external Supabase project, so SQL 232 confirmation must not be treated as Edge Function confirmation. Portal and mobile must show `unavailable`/`pending` clearly and keep saving independent of this endpoint.

## Portal implementation boundary

Lovable owns the Portal form and PDF renderer. It should reuse current vineyard catalog queries for tractors, team members, spray units, blocks and Chemical Store products; call only the RPCs above for mutations; consume canonical report 1.2; and remove its expectation of weather `filled`.

Current dependency status: SQL 232 and its supplied tests are confirmed complete, and SQL 233 is applied. SQL 233's behavioral test stopped at a pre-existing canonical-report aggregate error; SQL 234 and the updated SQL 233/234 behavioral-test rerun are pending with Jonathan. Live deployment/configuration of `spray-weather-recovery` remains separately unverified.
