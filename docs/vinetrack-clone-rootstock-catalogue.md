# Clone & Rootstock catalogues + Block allocation contract (sql/182)

Status: **live on iOS + Android** · Lovable Portal can adopt any time.
Rork owns this schema — the Portal must NOT create or alter these tables.

## Domain model (read this first)

- A **Clone belongs to exactly ONE grape variety** (Shiraz → BVRC12,
  Chardonnay → ENTAV-INRA 95). Clone selectors are always filtered by the
  selected variety.
- A **Rootstock is independent of scion variety** (1103 Paulsen, Ramsey,
  101-14 Mgt can carry many varieties). There is deliberately NO
  variety → rootstock relationship.
- A clone/selection number is only meaningful WITH its selection system:
  **FPS 07 (UC Davis) and an ENTAV-INRA clone with a similar number are
  different plant material.** `clone_code`, `selection_system`, and
  `source_country` are stored separately and must never be collapsed by
  visible number.

## Tables

Mirrors the grape variety catalogue architecture (sql/073:
`grape_variety_catalog` + `vineyard_grape_varieties`).

### `public.grape_clone_catalog` — global system clones

| column | type | notes |
| --- | --- | --- |
| `key` | text PK | Immutable, embeds the variety: `shiraz:pt23`, `pinot_noir:mv6` |
| `variety_key` | text | `grape_variety_catalog.key` of the owning variety |
| `display_name` | text | e.g. `ENTAV-INRA 115`, `Gin Gin` |
| `clone_code` | text | e.g. `115`, `PT23`, `FPS 07` |
| `selection_system` | text null | `Australian selection` / `ENTAV-INRA` / `FPS (UC Davis)` / `Geisenheim` / `New Zealand selection` |
| `source_country` | text null | |
| `aliases` | jsonb `[]` | Searchable alternates (`"Dijon 115"`, `"Salt Creek"`) |
| `source_reference` | text null | Where the seed record came from (SARDI 2006, BVI Shiraz dossier 2022, AWRI/Yalumba Chardonnay timeline, ENTAV-INRA catalogue, FPS UC Davis, Geisenheim) |
| `is_builtin`, `is_active` | boolean | |
| `created_at`, `updated_at` | timestamptz | |

~65 curated seed clones across Chardonnay, Shiraz, Pinot Noir, Cabernet
Sauvignon, Sauvignon Blanc, Merlot, Riesling, Pinot Gris, Grenache, Semillon.

### `public.vineyard_grape_clones` — vineyard custom clones

| column | type | notes |
| --- | --- | --- |
| `id` | uuid PK | |
| `vineyard_id` | uuid FK → vineyards, cascade | |
| `clone_key` | text | `custom:<vineyard_id>:<variety_slug>:<slug>` (server-derived) |
| `variety_key` | text | REQUIRED parent variety (built-in key or the vineyard's `custom:<vid>:<slug>` variety key) |
| `display_name` | text | |
| `is_custom`, `is_active` | boolean | |
| unique | | `(vineyard_id, clone_key)` |

The variety is baked into the key, so "115" under Pinot and "115" under
Chardonnay never collide, and a custom Shiraz clone can never surface under
Chardonnay.

### `public.rootstock_catalog` — global system rootstocks

| column | type | notes |
| --- | --- | --- |
| `key` | text PK | `1103_paulsen`, `101_14`, `ramsey`, `so4`, … |
| `canonical_name`, `display_name` | text | |
| `aliases` | jsonb `[]` | `"1103P"`, `"Salt Creek"`, `"Kober 5BB"` |
| `parentage` | text null | e.g. `V. berlandieri × V. rupestris` |
| `source_reference` | text null | Wine Australia / AWRI references; CSIRO Merbein series |
| `is_builtin`, `is_active`, timestamps | | |

26 seeded rootstocks (101-14, 3309C, Schwarzmann, 110R, 99R, 1103 Paulsen,
140 Ruggeri, 5BB, 5C, SO4, 420A, 161-49C, Ramsey, Dog Ridge, Freedom,
Harmony, 1613C, K51-40, Riparia Gloire, St George, Börner, Fercal, Gravesac,
Merbein 5489/5512/6262).

### `public.vineyard_rootstocks` — vineyard custom rootstocks

Same shape as custom clones, minus variety: `rootstock_key =
custom:<vineyard_id>:<slug>`, unique `(vineyard_id, rootstock_key)`.

## Sentinels (deliberately NOT catalogue rows)

Allocation-level reserved keys:

- `mass_selection` — vines propagated by mass selection; no certified clone.
  Write display snapshot `Mass selection`.
- `own_roots` — ungrafted / own-rooted vines; not a biological rootstock.
  Write display snapshot `Own roots`.
- `null` / absent key — clone "Not specified" / rootstock "Not recorded".

The upsert RPCs reject reserved names, so users can't mint fake records.
A user is never forced to invent a clone to save a block.

## Block allocation contract (`paddocks.variety_allocations` JSONB)

Each allocation element (additive to the sql/072/073 contract):

```json
{
  "id": "<uuid>",
  "varietyId": "<uuid>",
  "varietyKey": "shiraz",
  "name": "Shiraz / Syrah",
  "percent": 50,
  "clone": "PT23",              // display snapshot (legacy + picking log)
  "cloneKey": "shiraz:pt23",     // stable identity, or "mass_selection"
  "rootstock": "1103 Paulsen",  // display snapshot
  "rootstockKey": "1103_paulsen" // stable identity, or "own_roots"
}
```

Rules:

- **Always write BOTH the key and the display snapshot.** All existing
  display surfaces and the sql/180 picking log read the snapshot; the key
  is the identity. Keys are camelCase (`cloneKey`/`rootstockKey`); iOS also
  tolerates `clone_key`/`rootstock_key` on read.
- **Clone and Rootstock belong to the ALLOCATION, not the block.** A block
  may carry the same variety multiple times with different clone/rootstock
  (50% Shiraz PT23 on 1103 Paulsen + 50% Shiraz BVRC12 on Ramsey). Never
  merge or dedupe allocations of the same variety.
- **If the variety of an allocation changes, clear the clone** (it belongs
  to the old variety). Rootstock is variety-independent — keep it.
- **Legacy free text** (`clone`/`rootstock` strings with no key) stays valid
  forever. Preserve the text; offer catalogue matches as suggestions only;
  NEVER silently rewrite ambiguous text onto a key. Both apps show a
  "Keep "<text>"" option in the pickers.

## RPCs

| RPC | Who | Purpose |
| --- | --- | --- |
| `get_grape_clone_catalog()` | any authenticated | Active system clones, ordered by variety then name |
| `get_rootstock_catalog()` | any authenticated | Active system rootstocks |
| `list_vineyard_grape_clones(p_vineyard_id)` | member | Vineyard custom clones (incl. archived) |
| `list_vineyard_rootstocks(p_vineyard_id)` | member | Vineyard custom rootstocks |
| `upsert_vineyard_grape_clone(p_vineyard_id, p_variety_key, p_display_name, p_is_active default true)` | owner/manager | Creates/updates a custom clone; validates the parent variety exists (catalogue key, or the vineyard's custom variety); rejects reserved names; returns the row |
| `upsert_vineyard_rootstock(p_vineyard_id, p_display_name, p_is_active default true)` | owner/manager | Rejects reserved names AND near-duplicates of built-ins (`duplicates_builtin`) |
| `archive_vineyard_grape_clone(p_id)` / `archive_vineyard_rootstock(p_id)` | owner/manager | `is_active = false`; historical allocations keep resolving by key |

Errors use the same convention as the variety RPCs: `missing_vineyard_id`,
`not_authorized` (42501), `missing_display_name`, `unknown_variety_key`,
`reserved_name`, `duplicates_builtin`, `not_found`.

## RLS

- Global catalogues: SELECT for all authenticated; writes system-admin only
  (seeds live in the Rork migration).
- Vineyard tables: member read; owner/manager insert/update/delete — the
  exact isolation used by `vineyard_grape_varieties`.

## Selector behaviour (identical on iOS + Android; Portal must match)

Clone selector (per allocation):
1. "Not specified" (null) and "Mass selection" (sentinel) always available.
2. "Keep "<text>"" when the allocation has legacy free text without a key.
3. System catalogue clones for the allocation's `varietyKey` — search
   matches display name, `clone_code`, and aliases.
4. Vineyard custom clones for that variety.
5. "Add "<query>" as custom clone" when no existing option matches (RPC;
   on failure the value degrades to preserved free text on the block).

Rootstock selector (per allocation):
1. "Not recorded" (null) and "Own roots / ungrafted" (sentinel).
2. "Keep "<text>"" for legacy free text.
3. Full system rootstock catalogue — search matches name, canonical name,
   aliases, and parentage.
4. Vineyard custom rootstocks; then the custom-add action.

## Picking Log (sql/180) clone resolution

Unchanged and deliberately snapshot-based: when Block → Variety is chosen,
the entry form collects distinct `allocation.clone` display strings across
that variety's allocations — auto-selects a single option, offers a picker
for multiple, and never blocks entry when no clone is configured.
`picking_records.clone` stores the display snapshot so history never
mutates when catalogues change. Do not duplicate clone master data inside
the picking log.

## Legacy data migration

No destructive migration is performed. Existing `variety_allocations`
free-text `clone`/`rootstock` strings are preserved verbatim; keys are only
added when a user explicitly picks a catalogue record (the pickers surface
exact matches for one-tap adoption). Ambiguous text is never auto-mapped.

## Seed/update strategy

- Built-in keys are stable UUID-free text keys; records are never identified
  by display text.
- Re-running the migration upserts built-ins by `key` (metadata/alias
  updates), never touches vineyard custom rows, and never changes a key —
  block references can't break.
- New catalogue additions ship as new keyed rows in later Rork migrations.
- Clients bundle a fallback copy (iOS `BuiltInCloneCatalog` /
  `BuiltInRootstockCatalog`) used only until the first successful fetch.

## Sync behaviour

- iOS: `CloneRootstockCatalogStore` caches the system catalogues to disk and
  the vineyard's custom rows per vineyard; refreshed on sign-in and vineyard
  switch. Custom creation is an online RPC; offline the entry degrades to
  free text on the allocation (never blocks saving a block).
- Android: catalogues load with vineyard data (soft-fail keeps the last
  copy); custom creation mirrors iOS. Allocation writes ride the existing
  paddock upsert/outbox — a clone assigned on Android appears on iOS after
  the normal paddock sync, and vice versa.

## Files

- SQL: `sql/182_clone_rootstock_catalog.sql` +
  `sql/tests/182_clone_rootstock_catalog_tests.sql` (rollback-only; expected
  output `SQL 182 clone/rootstock catalogue tests: ALL PASSED`)
- iOS: `LegacyImported/Models/CloneRootstockCatalog.swift`,
  `Backend/Repositories/SupabaseCloneRootstockCatalogRepository.swift`,
  `LegacyImported/Views/Paddocks/CloneRootstockPickerSheets.swift`,
  `EditPaddockSheet.swift` (selector rows), allocation model in
  `GrapeVariety.swift`, tests `CloneRootstockCatalogTests.swift`
- Android: `data/model/CloneRootstockModels.kt`,
  `data/CloneRootstockRepository.kt`, `AppViewModel` wiring,
  `EditBlockScreen.kt` (dialogs), tests `CloneRootstockCatalogTest.kt`

## Deployment

1. Apply `sql/182_clone_rootstock_catalog.sql` in the shared Supabase
   project (idempotent).
2. Run `sql/tests/182_clone_rootstock_catalog_tests.sql` (rolls back).
3. Older app builds keep working — they simply ignore the new allocation
   keys and keep showing the display snapshots.
