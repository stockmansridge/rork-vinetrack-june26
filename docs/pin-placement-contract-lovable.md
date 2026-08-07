# Canonical pin placement contract — portal (Lovable) handoff

Applies after `sql/171_pin_placement_contract.sql`. iOS and Android already
follow this contract; the portal must adopt it verbatim.

> **Important:** running SQL 171 alone does NOT change what the portal
> displays. The portal computes "Unassigned location" in its own front-end
> code from the base `pins` columns. Until the portal's queries are switched
> to `pin_placements` / `pins_export`, it will keep showing the old, wrong
> labels. See "Prompt to paste into Lovable" at the bottom.

## The bug this replaces

The portal currently treats a pin as assigned only when
`paddock_id IS NOT NULL AND <a row number exists on the pins row>`.
That is incorrect and mislabels as "unassigned":

- block-scope pins (no row is ever required),
- row-scope pins (their rows live in `pin_row_segments`, not on the base row),
- older pins assigned to a block but never snapped to a row,
- unified-composer pins.

**Remove every local rule equivalent to `assigned = paddock exists AND row
exists`. Do not reconstruct placement from base-row fields.**

## Server-authoritative surfaces

Use these — never re-derive placement in portal code:

- `public.pin_placements` (view) — set-based, one row per pin, for lists and
  maps. Filter `deleted_at IS NULL` for live surfaces.
- `public.resolve_pin_placement(p_pin_id uuid)` (RPC) — single-pin JSON for
  detail/spot checks. Never call per pin in a list.
- `public.pins_export` (view) — reporting/CSV source with the placement
  columns plus identity fields.

### Fields (identical meaning in all three)

- `location_scope` — effective scope `point` / `row` / `block` (derived at
  read time for legacy pins; historical rows are never rewritten).
- `is_location_assigned` — boolean.
- `location_assignment_basis` — `point_coordinates` | `snapped_point` |
  `row_segments` | `block` | `legacy_block` | `unassigned`.
- `paddock_id`, `paddock_name` (`block_id`, `block_name` on `pins_export`).
- `row_summary` — segment-derived display text (see below).
- `has_row_segments`, `latitude`, `longitude`, `snapped_to_row`,
  `driving_row_number`, `pin_row_number`, `pin_side`, `along_row_distance_m`.
- `location_warning_code` — `null` | `location_metadata_incomplete` |
  `unassigned_location`.

## Assignment rules (what the fields encode)

- **Point**: assigned when coordinates are valid. Block and snapped row are
  optional associations. A point pin must never be shown as unassigned
  solely because `paddock_id` is null.
- **Row**: assigned when `paddock_id` exists AND at least one live segment
  exists in `pin_row_segments`. No row number is required on the base row.
- **Block**: assigned when `paddock_id` exists. No row information required.
- **Legacy (no stored scope)**: segments → row; block + row/snap values →
  snapped point; block only → block (`legacy_block`); coordinates only →
  point; nothing usable → unassigned.

## Warning display rules

- Show the strong amber "Unassigned location" state ONLY when
  `location_warning_code = 'unassigned_location'`.
- `location_metadata_incomplete` means a stored scope's structured data is
  missing but a safe fallback assignment exists — an informational state at
  most, never the amber warning.
- Never hide a known block name because a row value is absent.

## Row summary

`row_summary` is generated server-side from `pin_row_segments` with the same
canonical formatting the mobile composer uses:

- `Row 8` (one whole row) · `Rows 2–4, 6` (whole-row ranges)
- `Row 5 (sections 1–2)` (partial, contiguous) · `Row 5 (sections 1, 3)`
- Mixed: `Rows 2–3 · Row 5 (sections 1–2)` (whole rows first, joined " · ")

Display it as-is. For snapped point pins keep the existing wording built from
the exact path row (`driving_row_number`, e.g. 19.5 stays 19.5), the
customer-facing row (`pin_row_number`) and `pin_side` only when it genuinely
exists — **never invent a side**.

## Exports

Portal exports must include: `location_scope`, `is_location_assigned`,
`location_assignment_basis`, `block_id`, `block_name`, `row_summary`,
`latitude`, `longitude`, `location_warning_code` — all available directly on
`public.pins_export`. Block-scope pins export their block; row-scope pins the
segment-derived summary; point pins without a block their coordinates without
an unassigned mark.

## Writes are unchanged

sql/170 write behaviour stays valid: point (coordinates required, block and
snapping optional), row (derived `paddock_id` + `pin_row_segments` +
representative marker; no duplicated row number on the base row), block
(`paddock_id` + block scope + marker). Do NOT "fix" anything by copying row
values onto the base pins row — the read contract understands the structured
model.

## Prompt to paste into Lovable

Copy the block below into Lovable verbatim:

```text
The database now provides a canonical, server-authoritative pin placement
contract. Replace ALL pin location logic in the portal with it.

1. Data source changes
- Pins list / map / dashboard counts: stop selecting placement fields from
  the base `pins` table. Query `public.pin_placements` instead (it has one
  row per pin and respects RLS; filter `deleted_at IS NULL`). Join it to any
  other pin data you need by `pin_id`.
- Pin detail: you may call the RPC `resolve_pin_placement(p_pin_id uuid)`
  which returns the same fields as JSON, or reuse the row already fetched
  from `pin_placements`. Never call the RPC per pin in a list.
- CSV / report exports: select from `public.pins_export`.

2. Delete the old rule
- Remove every rule equivalent to "assigned = paddock_id exists AND a row
  number exists". Do not re-derive assignment client-side under any
  circumstances.

3. Render strictly from these fields
- Block column: show `paddock_name` when present. When `location_scope` is
  'point' and there is no block, show "Point location" (with coordinates on
  hover/detail) — this is a VALID location, not a warning.
- Row column: show `row_summary` when present (e.g. "Rows 2–4, 6",
  "Row 5 (sections 1–2)"). For snapped point pins without segments, keep the
  existing "On Row: … / Side: …" wording from `pin_row_number`,
  `driving_row_number` (preserve decimals like 19.5) and `pin_side` — but
  only show a side when `pin_side` is non-null; never invent one. Otherwise
  show "—".
- The amber "Unassigned location" badge/text may appear ONLY when
  `location_warning_code = 'unassigned_location'`. The value
  'location_metadata_incomplete' is informational at most — never amber.
- Never hide a known block name because a row value is absent.
- Use `is_location_assigned` for any "assigned/unassigned" filter or count.

4. Do not change any write path. Do not copy row values onto the pins table.
```

## Verification query (Supabase SQL editor)

Run this to see how the new contract classifies the pins the portal is
currently flagging:

```sql
select pin_id, title, location_scope, is_location_assigned,
       location_assignment_basis, paddock_name, row_summary,
       round(latitude::numeric, 6) as lat, round(longitude::numeric, 6) as lng,
       location_warning_code
from public.pin_placements
where deleted_at is null
order by (location_warning_code = 'unassigned_location') desc, created_at desc
limit 50;
```

Expected: pins the portal shows as "Unassigned location" but which have
coordinates resolve to `location_scope = 'point'`,
`is_location_assigned = true`, `location_warning_code = null`. Only pins
with no coordinates, no block and no segments keep
`location_warning_code = 'unassigned_location'`.
