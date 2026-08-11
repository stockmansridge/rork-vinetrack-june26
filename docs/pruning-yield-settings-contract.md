# Pruning Yield Calculator — shared per-block settings contract (sql/181)

Status: **live on iOS + Android** · Portal (Lovable) can adopt any time.

## What changed

The Pruning Yield Calculator (Yields hub → "Pruning Yield Calculator", also
called Yield Determination) used to keep its per-block inputs **device-local**
(iOS `UserDefaults`, Android `SharedPreferences`). Those inputs are operational
vineyard data — bud counts and pruning method per block — so they are now a
shared, synced record:

- Table: `public.pruning_yield_settings`
- **ONE active record per block**: unique `(vineyard_id, paddock_id)`
- Members of the vineyard all read and write the SAME configuration
- Offline-first on both apps (outbox / dirty-queue replay), last write wins on
  `client_updated_at`

## Persistence model: inputs only, results derived

Only the INPUT ASSUMPTIONS are persisted. Calculated outputs are **never
stored** — every client derives them with the shared formula so results can't
go stale when an input or a block's area changes:

```
buds_per_vine  = buds_per_spur × spurs_per_vine      (prune_method = 'spur')
               = buds_per_cane × canes_per_vine      (prune_method = 'cane')
bunches_per_ha = bunches_per_bud × buds_per_vine × vines_per_ha
yield_kg_ha    = bunches_per_ha × bunch_weight_grams ÷ 1000
yield_t_ha     = yield_kg_ha ÷ 1000
block_total_t  = yield_t_ha × block area (ha), only when area > 0
```

Parity is pinned by identical test vectors on both apps
(`ios/VineTrackTests/PruningYieldSettingsTests.swift`,
`android .../data/PruningYieldFormulaParityTest.kt`), e.g. the spur vector
`1.5 × (2×6) × 2000 × 120 g → 4.32 t/ha → 7.776 t on 1.8 ha`.

## Table shape

| column | type | notes |
| --- | --- | --- |
| `id` | uuid PK | row id; clients converge via the block upsert key, not this id |
| `vineyard_id` | uuid FK → vineyards | cascade delete |
| `paddock_id` | uuid | **no FK** (matches picking_records); clients only surface settings for blocks that still exist |
| `prune_method` | text | `'spur'` \| `'cane'`, trigger lower/trims any casing |
| `bunches_per_bud` | double | default 1.5, ≥ 0 |
| `buds_per_spur` | double | default 2, ≥ 0 |
| `spurs_per_vine` | double | default 6, ≥ 0 |
| `buds_per_cane` | double | default 10, ≥ 0 |
| `canes_per_vine` | double | default 4, ≥ 0 |
| `vines_per_ha` | double, null | null = derive from block vine count ÷ area |
| `bunch_weight_grams` | double | default 120, ≥ 0 |
| audit | | `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`, `client_updated_at`, `sync_version` |

Defaults mirror the long-standing client defaults, so an unsaved block behaves
exactly as before.

## How to write (portal)

Always UPSERT on the block key — never plain-insert, never key on `id`:

```
POST /rest/v1/pruning_yield_settings?on_conflict=vineyard_id,paddock_id
Prefer: resolution=merge-duplicates, return=representation

{ "id": "<new-uuid>", "vineyard_id": "...", "paddock_id": "...",
  "prune_method": "spur", "bunches_per_bud": 1.5, "buds_per_spur": 2,
  "spurs_per_vine": 6, "buds_per_cane": 10, "canes_per_vine": 4,
  "vines_per_ha": 1800, "bunch_weight_grams": 120,
  "client_updated_at": "<now ISO>" }
```

- Two devices minting different `id`s for the same block converge on the FIRST
  row; take the returned representation as authoritative.
- Send `vines_per_ha: null` explicitly to clear it (clients then re-derive
  from the block configuration).
- A client upsert (changed `client_updated_at`) **resurrects** a soft-deleted
  row — the block has one current configuration again.
- **Stale-write protection (sql/185):** an UPDATE whose `client_updated_at`
  is OLDER than the stored `client_updated_at` is silently **skipped** — a
  late offline replay can never overwrite a newer edit from another
  device/portal. The skipped write returns success with an **empty
  representation**; clients must treat that as "a newer value already won"
  (resolve the queued write, pull the authoritative row), never as an error
  to retry. Equal timestamps (idempotent re-sends) and writes that don't
  move `client_updated_at` backwards apply normally. Offline replays must
  send the ORIGINAL edit time, not the replay time.

Read: `GET ...?vineyard_id=eq.<id>&deleted_at=is.null`.

## RLS / permissions

- Read: any vineyard member.
- Insert/update: `owner / manager / supervisor / operator`.
- Hard delete: blocked for all clients.
- Soft delete: `soft_delete_pruning_yield_settings(p_id uuid)` RPC,
  `owner / manager / supervisor` only. (Neither app exposes delete in UI —
  a block's configuration is only ever overwritten.)

## Block lifecycle

`paddock_id` has no FK on purpose. Clients render settings **only for blocks
in the current block list**, so a deleted/renumbered block's row simply
becomes invisible — no misleading "active calculator targets" and no data loss
if the block returns.

## Client behaviour (both apps, identical)

- Block picker → each block loads ITS OWN saved record; switching blocks fully
  resets every field (no leaking between blocks). Unsaved blocks show the
  canonical defaults with `vines/ha` seeded from vine count ÷ area.
- Autosave: edits persist automatically (iOS marks the dirty queue per change;
  Android debounces 800 ms into a coalesced one-marker-per-block outbox
  upsert). No-op saves are skipped, so merely viewing a block never creates a
  record.
- "Save Result" remains a device-local convenience (iOS keeps its local result
  history for the hub "Latest" detail; Android keeps the latest-t/ha pref).
  Nothing calculated is synced.

## Legacy migration (one-time, both apps)

Pre-181 device-local saves are adopted on the FIRST successful sync after
upgrade, **only for blocks with no shared record** — an existing shared
configuration always wins and is never overwritten by stale local values.
- iOS: `PruningYieldSettingsSyncService.adoptLegacyLocalSettings` (UserDefaults
  `vinetrack_yield_determination_{userId}_{paddockId}`).
- Android: `AppViewModel.migrateLegacyPruningInputs`
  (`YieldDeterminationPrefsStore`), queued through the coalesced outbox.

## Files

- SQL: `sql/181_pruning_yield_settings.sql` + `sql/tests/181_pruning_yield_settings_tests.sql`
  (rollback-only; expected output `SQL 181 pruning yield settings tests: ALL PASSED`)
- iOS: `PruningYieldSettings.swift`, `BackendPruningYieldSettings.swift`,
  `PruningYieldSettingsSyncService.swift`, repositories/store extensions,
  `YieldDeterminationCalculatorView.swift`
- Android: `data/model/PruningYieldSettings.kt` (model + formula + input
  format), `PruningYieldSettingsRepository.kt`, `PruningYieldSettingsSync.kt`,
  `PruningYieldSettingsStore.kt` (offline cache; Supabase authoritative),
  `AppViewModel` wiring, `YieldScreen.kt`

## Deployment

Apply `sql/181_pruning_yield_settings.sql` in the shared Supabase project,
then run the test file (it rolls back). Older app builds keep working — they
simply keep using their device-local values until upgraded.
