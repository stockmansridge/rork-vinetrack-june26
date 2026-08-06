# Unified "Add Pin / Action" composer — Lovable portal contract (sql/170)

The mobile apps (iOS + Android) have replaced the separate Manual Issues
workflow with one unified, location-first pin composer. The portal must do
the same.

## Portal changes required

1. **Remove** the `Work → Manual Issues` navigation item.
2. **Retire** `/manual-issues` from normal navigation. If it must remain
   temporarily for old deep links, redirect it to the existing
   Pins / Repairs / Observations page — do not keep a separate feature
   surface.
3. **Add one button** on the existing Pins / Repairs / Observations page:
   - Label: `Add Pin / Action`
   - Supporting text: `Drop a pin, select a row or select a block`
4. That button opens the location-first workflow described below, then
   returns to the existing pins map/list after save. No separate Manual
   Issues list is shown after saving.

## Workflow

### Step 1 — location method (always first)

Three options, in this order:

- `Drop a pin manually` — map click; a block is NEVER required. Snap to the
  nearest mapped row when the click falls inside a block (same canonical
  snapping data as sql/041: `snapped_latitude/longitude`, `pin_row_number`,
  `along_row_distance_m`, `snapped_to_row`).
- `Select a row` — block picker + the existing row / row-section (quarter)
  selector. Requires a block and at least one segment.
- `Select a block` — block picker only. Marker = block centroid.

### Step 2 — type tabs (after location)

Three tabs in this exact order and wording — tappable AND swipeable:

`Repair | Growth | Custom`

- **Repair tab** — the EXISTING vineyard Repair buttons from
  `vineyard_button_configs` (same ids, labels, colours). No second catalogue.
- **Growth tab** — the EXISTING vineyard Growth buttons. No second catalogue.
- **Custom tab** — the vineyard-shared list from
  `vineyard_custom_pin_types` (below) plus `+ Add custom item` (one required
  field: name).

**No Left/Right side selection anywhere.** `pin_side` is stored null for
composer-created pins.
**No Category / Priority / Due date / Assigned user / Status controls.**

### Validation (identical on all platforms)

- point: selected type + marker coordinates. Block NOT required.
- row: selected type + block + ≥ 1 row segment.
- block: selected type + block.

## Custom type catalogue

Table `vineyard_custom_pin_types` (RLS: select for vineyard members; writes
via RPCs only):

| column | type |
|---|---|
| id | uuid pk (client-generated) |
| vineyard_id | uuid |
| name | text not null |
| color | text null |
| icon | text null |
| is_active | boolean default true |
| created_by / created_at / updated_at | audit |

Duplicate ACTIVE names are blocked per vineyard with trimmed,
case-insensitive comparison (unique partial index); the create RPC converges
on the existing entry instead of erroring. Deactivated items stay on
historical pins but are hidden from new selection.

### Catalogue RPCs

```text
create_vineyard_custom_pin_type(p_id uuid, p_vineyard_id uuid, p_name text,
                                p_color text default null, p_icon text default null)
  -> custom_pin_type_json   (idempotent by p_id; duplicate active name returns existing;
                             also back-links historical ManualIssue pins whose trimmed,
                             case-insensitive title exactly matches the new name)

list_vineyard_custom_pin_types(p_vineyard_id uuid, p_include_inactive boolean default false)
  -> jsonb array

set_vineyard_custom_pin_type_active(p_id uuid, p_is_active boolean)
  -> custom_pin_type_json   (owner/manager/supervisor)
```

## Save routing (which write path creates what)

- **Repair** → the EXISTING direct `pins` insert (PostgREST), `mode = 'Repairs'`.
  Never a Manual Issue RPC.
- **Growth** → the EXISTING direct `pins` insert, `mode = 'Growth'`.
- **Custom** → `create_custom_pin` RPC (the only remaining creation use of
  `mode = 'ManualIssue'`).

All three include `location_scope` (`point` / `row` / `block`) on the pin.
For row scope, Repair/Growth saves persist the structured selection with:

```text
set_pin_row_segments(p_pin_id uuid, p_segments jsonb)   -- [{"row":3,"segment":1}, ...]
  -> jsonb array of stored segments
  (replaces atomically; raises PIN_NOT_FOUND until the pin insert has landed — retryable)
```

### Repair / Growth insert payload (direct `pins` insert)

```json
{
  "id": "<client uuid>", "vineyard_id": "...", "paddock_id": "... or null",
  "mode": "Repairs" | "Growth",
  "title": "<button name>", "category": "<button name>",
  "button_name": "<button name>", "button_color": "<button colour token>",
  "side": null,
  "location_scope": "point" | "row" | "block",
  "latitude": ..., "longitude": ...,
  "snapped_latitude": ..., "snapped_longitude": ...,
  "pin_row_number": ..., "along_row_distance_m": ..., "snapped_to_row": false,
  "row_number": null, "is_completed": false, "created_by": "<user uuid>"
}
```

- point: `paddock_id` = containing block when the click falls inside one,
  else null. Snap fields populated only on a confident snap.
- row: `paddock_id` = selected block; marker latitude/longitude = mean of
  selected segment midpoints (fallback block centroid); then call
  `set_pin_row_segments`.
- block: `paddock_id` = selected block; marker = block centroid.

### Custom create RPC

```text
create_custom_pin(
  p_id uuid,                 -- client-generated (idempotent replay)
  p_vineyard_id uuid,
  p_title text,              -- the custom item name
  p_location_scope text,     -- 'point' | 'row' | 'block'
  p_custom_type_id uuid,     -- vineyard_custom_pin_types.id
  p_paddock_id uuid,         -- null allowed for point
  p_notes text default null,
  p_latitude/p_longitude double precision,
  p_snapped_latitude/p_snapped_longitude double precision,
  p_driving_row_number numeric, p_pin_row_number numeric,
  p_along_row_distance_m numeric, p_snapped_to_row boolean,
  p_client_updated_at timestamptz,
  p_segments jsonb           -- row scope only
) -> manual_issue_json (now includes custom_type_id)
```

Backend defaults applied automatically: `category='general'`,
`priority='normal'`, `status='open'`, `pin_side=null`,
`button_color='orange'`. Never shown in the creation UI.

## After save

- The record appears on the existing pins map/list (it IS a `pins` row).
- Filters: customer wording `Repairs | Growth | Custom` — Custom records
  remain `mode = 'ManualIssue'` internally.
- Existing sql/169 records keep decoding/rendering unchanged; the 169 RPCs
  (list/get/status/cancel/delete) remain for viewing/managing old records
  where currently supported.

## Offline expectations (parity with mobile)

- Custom type created offline: stable client id minted immediately; a pin
  may reference it straight away; the type create replays before the pin.
- Row segments replay after the pin insert (PIN_NOT_FOUND is retryable).
- All creates are idempotent by client id — retries never duplicate.
