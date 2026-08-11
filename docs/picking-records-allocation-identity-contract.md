# VineTrack — Picking Record Planting-Group Identity Contract (sql/184)

Canonical shared contract for how a Detailed picking record links to the
**planting group** it was picked from. Defined and implemented in this
repository (iOS + Android + Supabase); the Lovable Portal consumes it as-is
and must NOT create portal-specific data structures or modify the schema
independently.

- Migration: `sql/184_picking_record_planting_groups.sql`
  (supersedes the never-deployed `sql/183` single-allocation design)
- Base picking-log contract: `docs/vinetrack-picking-log.md` (sql/180)
- iOS: `PickingRecord` / `PlantingGroup` / `BackendPickingRecord` / `RecordActualYieldSheet`
- Android: `PickingRecord` / `plantingGroupKey()` / `PickingRecordRepository` / `YieldScreen`
- Parity tests: `ios/VineTrackTests/PickingRecordEditTests.swift` ↔
  `android-vinetrack/.../PickingRecordEditParityTest.kt`

---

## 1. The problem this solves

A block's `paddocks.variety_allocations[]` array describes **physical
sections**. One block can carry several sections that are the same planting
in every agronomic sense — same **Variety + Clone + Rootstock** (the
motivating vineyard, Stockman's Ridge, has two Pinot Noir sections, both
Clone 777 · Richter 110).

- A picker cannot (and should not) attribute a bin to one of two identical
  sections, so linking a pick to ONE `variety_allocation_id` is wrong.
- Reporting wants one row per planting group, with the group's total.
- The physical section ids must still be preserved so the block's structure
  can always be reconciled later.

Therefore a picking record links to a **planting group**: the set of one or
more allocations on the block sharing Block + Variety + Clone + Rootstock.

## 2. Storage (`public.picking_records`, sql/184)

| Column | Type | Semantics |
| --- | --- | --- |
| `planting_group_key` | `text` NULL | Stable group identity (see §3). **Server-canonicalised on every write** — the BEFORE trigger recomputes it from the row's `variety_name`/`clone`/`rootstock` snapshots whenever the row is linked, so client drift can never fork a group. `NULL` = unlinked. |
| `variety_allocation_ids` | `uuid[]` NULL | **Member allocation ids** — every `paddocks.variety_allocations[].id` belonging to the group at entry time, in block-config order. Point-in-time snapshot, no FK. `'{}'` is a valid *linked* value (member allocations that never had ids minted). `NULL` = unlinked. |
| `clone` | `text` NULL | Display snapshot of the group's clone (existing sql/180 column). |
| `rootstock` | `text` NULL | Display snapshot of the group's rootstock (new in sql/184). |

Invariant enforced by the trigger: the row is either **fully linked**
(`planting_group_key` set + `variety_allocation_ids` non-null, possibly `{}`)
or **fully unlinked** (both NULL). A half-linked write is repaired
server-side (missing key derived; missing members coalesced to `{}`).

**Never** use one arbitrary `variety_allocation_id` to represent a group —
that column does not exist anymore (sql/183 was superseded before deploy).

## 3. The group key — exact shared algorithm

```
norm(x)             = lowercase( trim( collapse internal whitespace to one space ( x or "" ) ) )
planting_group_key  = norm(variety_name) + "|" + norm(clone) + "|" + norm(rootstock)
```

- Scope: **within a block** — the reporting identity is
  `(vineyard_id, vintage, paddock_id, planting_group_key)`. The key itself
  deliberately excludes the paddock id (the row already carries it).
- Examples:
  - `Pinot Noir`, `777`, `Richter 110` → `pinot noir|777|richter 110`
  - `Chardonnay`, NULL, NULL → `chardonnay||`
  - ` PINOT  Noir `, `777 `, `richter 110` → `pinot noir|777|richter 110` (same group)
- Implementations (must stay byte-identical):
  - SQL: `public.planting_group_key(variety, clone, rootstock)` (immutable,
    executable by `authenticated` — the Portal may call it via
    `POST /rest/v1/rpc/planting_group_key` if it ever needs the server to
    compute one, though it normally never needs to: the trigger canonicalises
    every write).
  - iOS: `PlantingGroup.key(varietyName:clone:rootstock:)`
  - Android: `plantingGroupKey(varietyName, clone, rootstock)`
- Because the key embeds the normalised variety name, group rows nest exactly
  inside the sql/180 `picking_yield_totals` variety rows — variety-level
  totals are always the sum of their group-level rows plus unlinked rows.

## 4. Write rules (all clients incl. Portal)

- **Linked pick** (user selected a planting group): send
  `planting_group_key` (client-computed with §3 — the server recomputes it
  anyway), `variety_allocation_ids` (the group's member ids, `[]` when the
  members have no ids), and the `clone` + `rootstock` display snapshots.
  All four travel **atomically**.
- **"Not specified" / unlink**: send explicit JSON `null` for
  `planting_group_key`, `variety_allocation_ids`, `clone`, `rootstock` — a
  PATCH that omits them leaves stale values behind.
- Everything else follows the sql/180 contract unchanged: never send
  `vintage`, `grape_value` or server audit columns; always send
  `client_updated_at`.
- **Never auto-link, never backfill**: an unlinked (pre-184) record stays
  unlinked through unrelated edits and is linked only when a person
  explicitly picks a group while editing. Snapshot equality is NOT identity —
  do not infer links.

## 5. Create/edit form behaviour (identical on iOS, Android, Portal)

- The Planting picker shows **one option per group**: allocations of the
  selected variety are grouped by `norm(clone)|norm(rootstock)`.
  - Label: `clone · rootstock` (e.g. `777 · Richter 110`); a group with no
    clone or rootstock shows `No clone / rootstock`.
  - A multi-section group appends the section count and combined percent,
    e.g. `777 · Richter 110 — 2 plantings (85%)`.
- Dependency resets: Block change resets Variety + Planting; Variety change
  resets Planting.
- Editing preserves history: when the record's stored group no longer exists
  on the block (or the record was never linked), a legacy option shows the
  stored snapshots — suffixed `(not linked)` for unlinked records — and is
  preselected. Choosing it keeps the record exactly as stored.
- Single-group auto-select applies on CREATE only (mirror of both apps);
  edits never change the link without an explicit user selection.

## 6. Reporting — `public.picking_yield_planting_totals`

```
picking_yield_planting_totals
  (vineyard_id, vintage, paddock_id, planting_group_key,
   unlinked_variety_key, paddock_name, variety_name, clone, rootstock,
   member_allocation_ids, pick_count, total_weight_kg,
   actual_yield_tonnes, first_picked_at, last_picked_at, total_grape_value)
```

- `security_invoker` — the caller's RLS applies.
- Linked rows group per `(vineyard_id, vintage, paddock_id,
  planting_group_key)`; `variety_name`/`clone`/`rootstock` are `max()`
  display snapshots; `member_allocation_ids` is the **distinct union** of
  member ids across the group's picks (block config may change mid-vintage).
- Unlinked rows (`planting_group_key IS NULL`) split per
  `unlinked_variety_key` (lower/trimmed variety name) so historical picks
  stay visible per variety without being attributed to a group.
- `GET /rest/v1/picking_yield_planting_totals?vineyard_id=eq.{id}&vintage=eq.2026`
- The sql/180 `picking_yield_totals` view is **UNCHANGED** and remains the
  canonical actual-yield surface for the Basic-vs-Detailed supersede rule.
  Group between the two: every `picking_yield_totals` row equals the sum of
  its `picking_yield_planting_totals` rows (linked groups + its unlinked
  bucket).
- Display resolution: resolve the group against the block's **current**
  `variety_allocations` (match by §3 key) when it still exists; fall back to
  the row's stored snapshots when it doesn't.

## 7. Offline sync (apps; for Portal awareness)

- iOS: linked fields ride the existing dirty-mark → last-write-wins upsert;
  the upsert encodes explicit nulls for cleared group fields.
- Android: `PICKING_RECORD` CREATE/UPDATE outbox payloads carry
  `plantingGroupKey` + `varietyAllocationIds` + `rootstock`; the PATCH body
  writes explicit nulls when unlinked.
- The server trigger canonicalises whatever replays, so an offline pick
  entered under stale block config still lands in the right group by
  snapshot.

## 8. What the Portal must NOT do

- Do not invent or resurrect a single `variety_allocation_id` column.
- Do not represent a multi-section group by one member's id — always the
  full member list under the group key.
- Do not backfill or infer `planting_group_key` for existing rows.
- Do not group reporting by raw clone/rootstock strings — use
  `planting_group_key` (the server-canonicalised identity).
- Do not modify `picking_yield_totals` or the sql/180 schema.
