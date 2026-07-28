# Irrigation Records Phase 2A — Portal Import Contract (Lovable handover)

Rork is the master platform for the shared Supabase schema and this contract.
The Portal implements the upload → mapping → review → commit wizard on top of
the objects below. **Clients never insert imported sessions directly** — every
write goes through security-definer RPCs gated to VineTrack System
Administrators (`is_system_admin() AND is_vineyard_member(vineyard_id)`).

Delivered by: `sql/142_irrigation_import_framework.sql` + Edge Function
`parse-galcon-irrigation-import`.

---

## 1. Provider selection

```sql
select list_irrigation_import_providers();
```

Returns the adapter registry. Initial entry:

```json
{
  "provider_id": "galcon_gsi",
  "display_name": "Galcon GSI",
  "supported_file_types": ["xlsx", "csv"],
  "max_file_size_bytes": 10485760,
  "max_source_rows": 50000,
  "required_headers": ["Unit Name","Date","Start Time","End Time","Program",
                       "Valve Name","Run Time","Water Quantity","Average Flow","Comment"],
  "optional_headers": ["Irrigation Head","Fert Program Name","Fertilizer Quantity"],
  "date_format": "DD/MM/YYYY",
  "time_format": "HH:mm:ss",
  "volume_units": "m3",           // converted server-side: L = m³ × 1000
  "flow_units": "m3_per_hour",    // converted server-side: L/h = m³/h × 1000
  "default_import_thresholds": {
    "minimum_import_volume_litres": 1000,
    "comparison": "greater_than",
    "exclude_test_programs": true
  },
  "parser_edge_function": "parse-galcon-irrigation-import"
}
```

The workflow must start with an explicit provider selection — automatic file
detection is only a verification step, never the selector.

## 2. Provider/controller settings

```sql
select get_irrigation_import_provider_settings(p_vineyard_id, 'galcon_gsi', p_external_controller_key);
select set_irrigation_import_provider_settings(
  p_vineyard_id, 'galcon_gsi', p_external_controller_key,
  p_external_controller_name, p_minimum_volume_litres, p_volume_comparison,
  p_exclude_test_programs, p_timezone);
```

- `external_controller_key` is the normalised Unit Name (`''` = provider default).
- Defaults: `minimum_volume_litres = 1000`, `comparison = greater_than`
  (strictly **more than** 1.0 m³ — exactly 1.0 m³ does NOT pass),
  `exclude_test_programs = true`.
- Changing settings updates future previews only; committed sessions never change.

## 3. Upload + parse (Edge Function)

`POST /functions/v1/parse-galcon-irrigation-import` with the **user's** JWT:

```json
{
  "vineyard_id": "<uuid>",
  "provider": "galcon_gsi",
  "file_name": "HistoryIrrigation.xlsx",
  "file_base64": "<raw file bytes, base64>",
  "timezone": "Australia/Sydney",
  "allow_revalidation": false
}
```

Success `200`:

```json
{
  "ok": true,
  "batch_id": "<uuid>",
  "duplicate_file": false,
  "file": { "name", "sha256", "size_bytes", "worksheet", "unit_name",
            "source_rows", "rows_with_parse_errors" },
  "preview": { ...preview totals, see §6 }
}
```

Duplicate file content (`200`): `{ ok: true, duplicate_file: true, batch_id,
message, batch }` → show the earlier batch and offer "open results" or
"reprocess for validation only" (`allow_revalidation: true`; such batches can
NEVER be committed).

Errors:
- `400` size/row limits, bad base64, unsupported type
- `401` no JWT, `403` not a System Administrator
- `422` format mismatch → `"This file does not match the expected Galcon GSI
  irrigation export format."` plus `missing_headers: [...]` when applicable;
  also empty files, password-protected workbooks, ambiguous duplicate columns.

Parsing notes: first *visible* worksheet containing the required headers is
used (never assume `Sheet1`); headers match case/whitespace-insensitively;
dates are strictly DD/MM/YYYY; overnight events (End < Start) roll to the next
day; bare `0` water parses as 0 m³; station codes `(S12)` and `S7` both parse.

## 4. Valve mapping

```sql
select list_irrigation_import_valves(p_batch_id);
```

One row per DISTINCT controller valve (not per event):

```json
{
  "external_station_code": "S7", "external_valve_number": 7,
  "external_valve_name": "7 - Pinot Noir W1 90-108 S7",
  "external_valve_label": "Pinot Noir W1 90-108",
  "row_count": 37,
  "status": "saved | conflict | ignored | suggested | unmapped",
  "mapping_id": "...", "irrigation_valve_id": "...", "vinetrack_valve_name": "...",
  "name_changed": false, "previous_external_name": null,
  "suggested_valve_id": "...", "suggested_valve_name": "..."
}
```

Resolution priority (only 1–4 auto-map): saved station mapping → saved
valve-number mapping → `irrigation_valves.external_station_id` match →
`irrigation_valves.valve_number` match → name suggestion (**requires
confirmation**) → unmapped. Save/confirm/ignore with:

```sql
select set_irrigation_controller_valve_mapping(
  p_vineyard_id, 'galcon_gsi', p_external_controller_key, p_external_valve_name,
  p_external_station_code, p_external_valve_number, p_external_controller_name,
  p_irrigation_valve_id, p_ignore, p_confirm_change);
```

- `status = 'conflict'` (materially changed name/target) raises
  `mapping_conflict:` unless `p_confirm_change = true` — surface the message,
  e.g. *"Galcon station S7 was previously mapped as 'Pinot Noir W1 90-108'.
  Review the mapping change before continuing."*
- A different Unit Name is a NEW controller identity — mappings never cross
  controllers silently.
- After any mapping change, call `validate_irrigation_import(p_batch_id)` to
  refresh classifications.

## 5. Validation / re-validation

```sql
select validate_irrigation_import(p_batch_id, p_threshold_litres, p_volume_comparison, p_exclude_test_programs);
```

Optional args change THIS batch's settings (audited) and re-classify. Returns
the preview (§6).

Row fields (via `list_irrigation_import_rows(p_batch_id, p_validation_status,
p_classification, p_limit, p_offset, p_include_raw)` — paginated; raw payloads
excluded unless explicitly requested):

- `classification`: `completed | ended_manually | cancelled_manual |
  cancelled_error | cancelled_not_enabled | paused | continued |
  low_flow_error | high_flow_error | no_flow_error | test | zero_activity |
  below_volume_threshold | at_volume_threshold | needs_review | unknown_comment`
- `validation_status`: `eligible | excluded | needs_review | error`
- `primary_exclusion_reason` + `additional_reason_codes[]` (show ALL reasons,
  e.g. `Excluded: • Test program • Below minimum water quantity`)
- `duplicate_status`: `new | duplicate_imported | duplicate_ignored |
  duplicate_reviewed | possible_duplicate_changed_values` (+ `duplicate_reference`)
- `water_flow_reconciliation`: `reconciled | minor_rounding_difference |
  material_mismatch | cannot_compare` (+ `expected_water_litres`)
- originals preserved: `original_water_value/unit`, `original_flow_value/unit`,
  `parsed_water_litres`, `parsed_flow_litres_per_hour`, `raw_payload` (audit only)

Threshold explanation copy (info icon on excluded rows):

> This event was not selected because its reported water quantity is 0.2 m³.
> The Galcon import minimum is more than 1.0 m³, which helps exclude
> controller tests and very short runs.

Exactly at threshold: *"…because the rule requires more than 1.0 m³."*

## 6. Preview totals

`preview_irrigation_import(p_batch_id)` / `get_irrigation_import_batch(p_batch_id)`:

`total_source_rows, eligible_completed, below_threshold, at_threshold,
test_program, cancelled, controller_errors, zero_activity, needs_review,
parse_errors, unmapped_valves, exact_duplicates, possible_changed_duplicates,
selected_for_import, already_imported, distinct_valves, threshold_litres,
volume_comparison, exclude_test_programs, threshold_explanation, batch{...}`

One primary classification per row — top-level totals never double count.

## 7. Overrides (threshold / Test)

```sql
select set_irrigation_import_row_override(p_row_id, p_override_threshold, p_override_test, p_reason);
```

Require the acknowledgement dialog first:

> This event is below the Galcon minimum-volume threshold and may represent a
> test or short diagnostic run.

Audited (user, time, original threshold, reported volume, reason). Overrides
lift ONLY the threshold/Test exclusion — other failures still block. The
vineyard default threshold is never changed by an override. Returns the
refreshed preview.

## 8. Commit

```sql
select commit_irrigation_import(p_batch_id, p_row_ids /* null = all eligible */,
                                p_acknowledge_current_configuration => true);
```

BEFORE calling, show the historical-configuration warning with two choices:

> Imported water will be allocated using the valve's current VineTrack
> connection. Confirm that this connection reflects the imported period.
> [Use current saved valve configuration] [Hold for review]

Without `p_acknowledge_current_configuration = true` the RPC raises
`configuration_acknowledgement_required`.

Returns `{ imported, already_imported, skipped_duplicate, needs_review,
results: [{row_id, status, session_id?, reason?}] }` with per-row statuses
`imported | already_imported | skipped_duplicate | needs_review | skipped`.

Commit is **idempotent**: retries and concurrent calls cannot duplicate —
guarded by row→session linkage, the partial unique index on
`(vineyard_id, provider, event_fingerprint)` for live sessions, and the
sessions-side unique index on `(vineyard_id, external_source_id)`.

Created sessions are canonical `irrigation_sessions` rows:
`status='imported'`, `source_type='galcon_gsi_import'`,
`calculation_method='controller_reported_volume'`,
`external_source_id=<event fingerprint>`, `import_batch_id`, block allocations
via the EXISTING valve configuration, and a frozen snapshot with the full
`import` metadata block. They flow through all existing reporting RPCs
automatically. Galcon reported volume is controller-reported — never label it
as measured meter volume.

## 9. Batch history + reversal

```sql
select list_irrigation_import_batches(p_vineyard_id, p_provider, p_limit, p_offset);
select get_irrigation_import_batch(p_batch_id);
select reverse_irrigation_import_batch(p_batch_id, p_dry_run => true);   -- impact preview
select reverse_irrigation_import_batch(p_batch_id, p_dry_run => false);  -- execute
```

Dry run returns `{ sessions_affected, total_water_litres_removed,
date_range_from, date_range_to, valves_affected[] }` — show it before
confirming. Execute reverses ONLY that batch's sessions (excluded from all
reports), preserves batch + rows + audit, and frees the event fingerprints so
a corrected re-import is possible. Manual sessions are never touched.

## 10. Duplicate handling summary

- **File level**: sha256 of raw bytes; identical content for the same
  vineyard/provider returns the earlier batch (file NAME is irrelevant).
- **Event level**: deterministic fingerprint over provider, vineyard,
  controller key, station, valve number, date, start, end, runtime, water (L),
  flow (L/h), normalised comment, program — independent of file name,
  worksheet, row order and XLSX-vs-CSV.
- **Database level**: partial unique indexes make a second session for the
  same live event structurally impossible.
- Same valve+start with changed values → `possible_duplicate_changed_values`
  → review; the previous session is never overwritten.

Supplied-workbook simulation (`scripts/galcon-import-simulation.py`): second
import of the same file (renamed, CSV-converted, reordered, or overlapping
subset) creates **0** additional sessions.

## 11. Wizard step → contract mapping

| Wizard step | Contract call |
|---|---|
| Select import source | `list_irrigation_import_providers` |
| Upload + detect + parse + file summary | Edge Function `parse-galcon-irrigation-import` |
| Review provider settings | `get/set_irrigation_import_provider_settings`, `validate_irrigation_import(threshold…)` |
| Review valve mappings / resolve conflicts | `list_irrigation_import_valves`, `set_irrigation_controller_valve_mapping` |
| Review classifications / thresholds / duplicates | `list_irrigation_import_rows`, `set_irrigation_import_row_override` |
| Preview sessions to be created | `preview_irrigation_import` |
| Commit | `commit_irrigation_import` |
| Results / open sessions | commit result + `list_irrigation_sessions(p_source_type => 'imported')` |
| Batch history / reversal | `list_irrigation_import_batches`, `reverse_irrigation_import_batch` |

Import settings summary example (before commit):

> Import source: Galcon GSI · Controller: Stockman's Ridge Wines ·
> Minimum water quantity: more than 1.0 m³ · Test programs: excluded ·
> Duplicate handling: previously processed events are skipped ·
> Valve mappings: 12 matched / 0 requiring review

## 12. Security recap

- All import tables are RLS-protected (`is_system_admin() AND
  is_vineyard_member`); writes are RPC-only.
- The Edge Function forwards the caller's JWT — it has no service-role power.
- Raw payloads are stored for audit but excluded from list responses unless
  `p_include_raw = true`.
- Every settings change, mapping change, override, commit and reversal is
  written to `irrigation_audit`.
