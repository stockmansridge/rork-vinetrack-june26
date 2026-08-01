# Customisable Operational Tools — shared contract (SQL 159)

Per-user layout for the Operational Tools grid. Implemented on iOS and Android;
this document is the exact contract for the Lovable portal if it later offers
the same customisation.

## Scope rules

- The preference is **per user**, never per vineyard. Switching vineyards must
  not change the layout.
- Hiding a tool is **display only**. It never deletes records, disables a
  feature, removes notifications, changes permissions, or affects reports,
  the portal or another user's layout.
- Customisation never overrides access. Each client filters the saved layout
  through the tools the caller is currently authorised to see **before**
  rendering. A tool the user has no access to appears in neither the grid nor
  the customisation screen.

## Storage

`public.user_operational_tool_preferences`

| column | type | notes |
| --- | --- | --- |
| `user_id` | uuid PK | `auth.users(id)`, cascade delete |
| `visible_tool_ids` | text[] | ordered; the user's grid order |
| `hidden_tool_ids` | text[] | user-hidden tools |
| `preference_version` | integer | currently always `1` |
| `created_at` / `updated_at` | timestamptz | |

RLS: authenticated users can select/insert/update/delete **their own row only**.
No row exists until the user customises something — absence means "VineTrack
default order, all authorised tools".

`public.operational_tool_catalogue` holds the recognised IDs and the default
order. It is readable by authenticated users and extended by future migrations.

## Stable tool IDs (VineTrack default order)

1. `work_tasks` — Work Tasks
2. `equipment_maintenance` — Maintenance Log
3. `fuel_log` — Fuel Log
4. `irrigation_advisor` — Irrigation Advisor
5. `disease_risk` — Disease Risk
6. `yield_records` — Yields
7. `growth_stages` — Growth Stage Records
8. `optimal_ripeness` — Optimal Ripeness
9. `cost_reports` — Cost Reports *(Owner/Manager costing permission only)*
10. `fertiliser_calculator` — Fertiliser Calculator
11. `pruning_tracker` — Pruning Tracker
12. `irrigation_records` — Irrigation Records

Renaming a tool keeps its ID and changes the display name/icon only. Never use
display names, screen titles or array positions as identifiers.

## RPCs

```sql
get_my_operational_tool_preferences()
  -> jsonb {
       has_preference:     boolean,
       version:            integer,
       visible_tool_ids:   text[],
       hidden_tool_ids:    text[],
       updated_at:         timestamptz | null,
       catalogue_tool_ids: text[]      -- active catalogue, default order
     }

set_my_operational_tool_preferences(
  p_visible_tool_ids   text[],
  p_hidden_tool_ids    text[] default '{}',
  p_preference_version integer default 1
) -> same shape as get_*

reset_my_operational_tool_preferences() -> same shape as get_*
```

All three derive the user from `auth.uid()`; there is no user parameter.

### Validation and error codes

| condition | behaviour |
| --- | --- |
| not authenticated | raises `authentication_required` (42501) |
| duplicate IDs within a list | raises `duplicate_tool_ids` (22023) |
| a tool in both lists | raises `tool_in_both_lists` (22023) |
| visible list empty while tools are hidden | raises `at_least_one_visible_tool` (22023) |
| `p_preference_version <> 1` | raises `unsupported_preference_version` (22023) |
| more than 64 IDs | raises `too_many_tool_ids` (22023) |
| unknown / retired tool ID | **ignored** (dropped from the stored arrays) |
| both lists resolve to empty | treated as a reset (row deleted) |

IDs are lowercased and trimmed before storage.

## Client rules (identical on iOS, Android and the portal)

1. Load the authorised tool catalogue for the caller.
2. Apply the locally cached layout **immediately** — never show a spinner or,
   worse, hidden tools while the server answers.
3. Refresh `get_my_operational_tool_preferences()` in the background.
4. Order: saved `visible_tool_ids` first (filtered to authorised tools), then
   any authorised tool that is in neither list, appended at the end. This is
   how newly released tools reach existing users.
5. Save on every change (reorder, hide, restore) — no explicit Save button.
6. On save failure keep the local layout, mark it pending, retry on the next
   load/change, and show:
   *"Your tool layout has been saved on this device and will sync when a
   connection is available."*
7. Refuse to hide the final visible tool with:
   *"At least one operational tool must remain visible."*
8. Reset shows a confirmation ("Reset Operational Tools?" /
   "This will show all available tools and return them to the default VineTrack
   order.") and calls `reset_my_operational_tool_preferences()`.
9. Cache keyed by auth user UUID; a different user never inherits a layout.

## Retention

The row lives as long as the account (cascade delete with `auth.users`). No
history is kept; there is nothing sensitive to retain or purge.

## Tests

- `sql/tests/159_operational_tool_preferences_tests.sql` (rollback-only)
- iOS `VineTrackTests/OperationalToolLayoutTests.swift`
- Android `OperationalToolLayoutTest.kt`
