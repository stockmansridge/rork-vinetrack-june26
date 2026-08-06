# Unified pin composer — Lovable portal contract (sql/170)

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
   - Label: `Manual Pin / Repair / Observation` (EXACT wording — do not use
     the earlier "Add Pin / Action" label)
   - Supporting text: `Drop a pin, select a row or select a block`
   - Colour: the shared semantic burgundy `#800020` (gradient second stop
     `#5C0017`). This applies to this button/card only — saved Repair,
     Growth and Custom pin colours are unchanged.
4. That button opens the location-first workflow described below, then
   returns to the existing pins map/list after save. No separate Manual
   Issues list is shown after saving.

## Workflow

### Step 1 — location method (always first)

Three large controls (mobile renders them full-width at a minimum height of
128, roughly double a standard list card — keep the portal's equivalents
visually prominent with a clear selected state), in this order:

- `Drop a pin manually` — subtitle `Tap a point on the map — no block
  selection needed`. Map click; a block is NEVER required. Snap to the
  nearest mapped row when the click falls inside a block (same canonical
  snapping data as sql/041: `snapped_latitude/longitude`, `pin_row_number`,
  `along_row_distance_m`, `snapped_to_row`).
- `Select a row` — subtitle `Tap rows or row sections — the block is
  detected automatically`. **Row-first: there is NO block picker.** Show the
  existing row / row-section (quarter) selector for every block that has
  mapped rows, grouped under block headers (map or grouped list — the block
  context must make "Row 41" unambiguous across blocks; never a bare
  row-number text field). The pin's `paddock_id` is DERIVED from the block
  that owns the tapped row geometry. Tapping a row in a different block
  switches the derived block and starts a fresh selection. Requires ≥ 1
  segment; if the tapped row can't be associated with a block, show
  `Couldn't match the selected row to a block.` and prevent save — do not
  fall back to a block dropdown.
- `Select a block` — subtitle `Flag a whole block`. Block picker only.
  Marker = block centroid.

### Step 2 — type tabs (after location)

Three tabs in this exact order and wording — tappable AND swipeable:

`Repair | Growth | Custom`

- **Repair tab** — the EXISTING vineyard Repair buttons from
  `vineyard_button_configs` (same ids, labels, colours), deduplicated by
  name + colour (left/right launcher duplicates collapse to one tile). No
  second catalogue.
- **Growth tab** — `Growth Stage` exactly once, FIRST, at the same tile size
  as the other Growth buttons, then the EXISTING vineyard Growth buttons
  deduplicated (default catalogue: Growth Stage, Powdery, Downy,
  Blackberries). Tapping `Growth Stage` opens the EXISTING E-L growth-stage
  picker (same images, labels, order and stage identifiers as the standard
  Growth workflow — never a second stage list). The chosen stage returns to
  the composer; cancelling the picker changes nothing and creates no pin.
- **Custom tab** — the vineyard-shared list from
  `vineyard_custom_pin_types` (below) plus `+ Add custom item` (one required
  field: name).

**No Left/Right side selection anywhere.** `pin_side` is stored null for
composer-created pins.
**No Category / Priority / Due date / Assigned user / Status controls.**

### Validation (identical on all platforms — exact wording)

- point: selected type + marker coordinates. Block NOT required.
  (`Tap the map to place the pin.` when no click yet.)
- row: selected type + ≥ 1 row segment (`Select at least one row.`), and the
  derived block (`Couldn't match the selected row to a block.` when
  derivation fails).
- block: selected type + block (`Select a block.`).
- any scope: `Select a pin type.` / `A map location is required.`

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
- row: `paddock_id` = the block DERIVED from the tapped row geometry; marker
  latitude/longitude = mean of selected segment midpoints (fallback block
  centroid); then call `set_pin_row_segments`.
- block: `paddock_id` = selected block; marker = block centroid.

### Growth Stage save (Growth tab)

A growth-stage save is the same direct `pins` insert with:

```json
{
  "mode": "Growth",
  "title": "Growth Stage <EL code>", "button_name": "Growth Stage <EL code>",
  "button_color": "darkgreen",
  "growth_stage_code": "<EL code>",
  "notes": "<stage description>"
}
```

plus the same location/scope fields as any other composer save. The stage
identifier is the EXISTING E-L `code` from the standard growth-stage list —
never a new identifier scheme.

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
