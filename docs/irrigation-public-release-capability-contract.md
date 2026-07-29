# Irrigation Records Public Release — Portal (Lovable) Capability Contract

SQL 151 (`sql/151_irrigation_public_release_capabilities.sql`) replaces the
temporary System Administrator gate with shared role-based capabilities.
**No irrigation calculation, import, or reporting logic changed** — access
control only. The Portal must gate visibility from the shared server answer
below and must NOT hardcode role names.

## 1. The one RPC the Portal needs

```
public.get_irrigation_capabilities(p_vineyard_id uuid) returns jsonb
```

Example response:

```json
{
  "vineyard_id": "…",
  "role": "supervisor",
  "is_system_admin": false,
  "can_view_irrigation_records": true,
  "can_record_irrigation": true,
  "can_edit_irrigation": false,
  "can_reverse_irrigation": true,
  "can_manage_irrigation_setup": false,
  "can_view_irrigation_reports": true,
  "can_import_irrigation": false,
  "can_reverse_irrigation_import": false,
  "generated_at": "2026-07-29T…"
}
```

`role` is `null` when the caller is not a member of the vineyard.
`has_irrigation_records_access(p_vineyard_id)` still exists and now equals
`can_view_irrigation_records` (any vineyard member) — existing Portal calls
keep working and start returning `true` for normal members after SQL 151.

## 2. Capability matrix (server-enforced)

| capability | owner | manager | supervisor | operator |
|---|---|---|---|---|
| can_view_irrigation_records | ✓ | ✓ | ✓ | ✓ |
| can_record_irrigation | ✓ | ✓ | ✓ | ✓ |
| can_edit_irrigation | ✓ | ✓ | — | — |
| can_reverse_irrigation | ✓ | ✓ | ✓* | — |
| can_manage_irrigation_setup | ✓ | ✓ | — | — |
| can_view_irrigation_reports | ✓ | ✓ | ✓ | — |
| can_import_irrigation | ✓ | ✓ | — | — |
| can_reverse_irrigation_import | ✓ | ✓ | — | — |

- \* Supervisor reversal follows the existing VineTrack work-record
  convention (owner/manager/supervisor may soft-delete work records).
- System Administrators who are members of the vineyard hold every
  capability (identical semantics to the old gate). A System Administrator
  who is NOT a member of the vineyard gets nothing — unchanged.
- No vineyard membership / revoked membership ⇒ every capability `false`.
- Manager intentionally matches Owner for imports and import reversal (the
  release default). `can_reverse_irrigation_import` is a separate flag so it
  can become Owner-only later without a Portal change.

## 3. Which capability each RPC enforces

The server enforces these independently — hidden UI is never the boundary.

- `view_irrigation_records` (any member): `list_irrigation_systems`,
  `list_irrigation_valves`, `list_irrigation_valve_blocks`,
  `list_irrigation_valve_rows`, `list_irrigation_available_rows`,
  `get_irrigation_setup_status`, `validate_irrigation_configuration`,
  `calculate_irrigation_preview`, `get_irrigation_session`,
  `list_irrigation_sessions`, plus SELECT on all core irrigation tables (RLS).
- `record_irrigation`: `record_irrigation_session`.
- `edit_irrigation`: `update_irrigation_session`.
- `reverse_irrigation`: `reverse_irrigation_session`.
- `manage_irrigation_setup`: `create_irrigation_system`,
  `update_irrigation_system`, `create_irrigation_valve`,
  `update_irrigation_valve`, `set_irrigation_valve_blocks`,
  `set_irrigation_valve_rows`.
- `view_irrigation_reports`: all Phase 1 summaries
  (`get_irrigation_vintage_summary`, `get_irrigation_valve_summary`,
  `get_irrigation_block_summary`, `get_irrigation_variety_summary`,
  `get_irrigation_daily_summary`, `get_irrigation_monthly_summary`) and all
  Phase 2B reporting RPCs (`get_irrigation_vintage_overview`,
  `get_irrigation_daily_report`, `get_irrigation_weekly_summary`,
  `get_irrigation_monthly_report`, `get_irrigation_valve_report`,
  `get_irrigation_block_report`, `get_irrigation_variety_report`,
  `get_irrigation_water_source_summary`,
  `get_irrigation_calculation_source_summary`,
  `get_irrigation_record_source_summary`, `get_irrigation_rainfall_summary`,
  `get_irrigation_vintage_trends`, `list_irrigation_report_sessions`).
- `import_irrigation`: every SQL 142 import RPC —
  `list_irrigation_import_providers` (catalogue),
  `get/set_irrigation_import_provider_settings`,
  `create_irrigation_import_batch`, `stage_irrigation_import_rows`,
  `list_irrigation_import_valves`,
  `set_irrigation_controller_valve_mapping`, `validate_irrigation_import`,
  `set_irrigation_import_row_override`, `preview_irrigation_import`,
  `commit_irrigation_import`, `get_irrigation_import_batch`,
  `list_irrigation_import_batches`, `list_irrigation_import_rows` — plus the
  `parse-galcon-irrigation-import` Edge Function (it calls these RPCs with
  the caller's JWT, so access follows automatically) and SELECT on the four
  import tables (RLS).
- `reverse_irrigation_import`: `reverse_irrigation_import_batch`.

## 4. Error contract

- `irrigation_access_denied: …` — caller cannot view Irrigation Records at
  all (not a member / revoked). Unchanged message; existing handling works.
- `irrigation_permission_denied: Your role does not allow this irrigation
  action (<capability>)` — NEW. Caller can view, but the role lacks the
  specific action. Show a friendly "your role does not allow this" message.
- `import_access_denied: Controller imports require Owner or Manager access
  to this vineyard` — unchanged prefix, updated wording.

## 5. Required Portal changes

1. On entering Irrigation Records, call `get_irrigation_capabilities` once
   per vineyard and cache it for the visit.
2. Route/menu gates: replace any System-Admin-only checks for Irrigation
   Records with `can_view_irrigation_records`.
3. Setup navigation: show only when `can_manage_irrigation_setup`.
4. Reports navigation (incl. the Phase 2B report centre): show only when
   `can_view_irrigation_reports`.
5. Import area (upload, mappings, validation, commit) : show only when
   `can_import_irrigation`; the "Reverse import batch" action only when
   `can_reverse_irrigation_import`.
6. Session detail: Edit → `can_edit_irrigation`; Reverse →
   `can_reverse_irrigation`; Record/Duplicate → `can_record_irrigation`.
7. Keep the existing confirmation dialogs for session reversal and import
   reversal — destructive-action confirmation is unchanged.
8. Do NOT hide errors: if a server call returns
   `irrigation_permission_denied`, surface it — never retry as a different
   user or suppress it in TypeScript.

Vintage summary note: the Phase 1 "This Vintage" summary RPCs are reports —
an Operator viewing the landing page must not call them (both mobile apps
now skip the summary fetch for operators).

## 6. What did NOT change

- All report/RPC parameters and response shapes (SQL 147/149 contract).
- Import workflow, thresholds, classification, reversal semantics.
- Historical sessions and frozen snapshots.
- Audit trails on setup changes, mapping changes, imports.
- Writes to irrigation tables remain definer-RPC-only (no direct writes).

## 7. Rollout order

1. Apply `sql/151_irrigation_public_release_capabilities.sql`.
2. Run `sql/tests/151_irrigation_release_capabilities_tests.sql`
   (single transaction, rolls back; expect
   `SQL 151 irrigation capability tests: ALL PASSED`).
3. Ship the Portal gating changes above.
4. Mobile apps already gate from the same RPC (this release).
