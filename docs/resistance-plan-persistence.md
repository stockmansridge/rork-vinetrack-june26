# Resistance Plan persistence contract

**Owner: Rork/VineTrack mobile.** Lovable (the web portal) CONSUMES this contract. The
portal must not create, rename or repurpose any column, constraint, policy or RPC
described here, and must not invent a competing representation of a plan.

Schema: `sql/196_resistance_plans.sql`
Verification: `sql/tests/196_resistance_plans_tests.sql` (rollback-only)
Clients: `ResistancePlan.swift` / `ResistancePlan.kt` (domain),
`SupabaseResistancePlanRepository.swift` / `SupabaseResistancePlanRemote.kt` (transport)

---

## 1. What a Resistance Plan is

An ordered, forward-looking sequence of intended fungicide applications for **one disease**
across **one or more blocks** in **one season**, together with the resistance strategy
version it was authored under.

It is **advisory planning data**. It is not a spray record, not a work order and not
compliance evidence. Nothing in this table ever modifies `spray_records`,
`saved_chemicals`, `spray_targets`, application snapshots or block attribution.

## 2. The rule that governs everything: facts, never verdicts

The table stores **what a human decided**. It never stores **what the engine concluded**.

There is deliberately no column for `status`, `good_fit`, `would_exceed`, warning text,
resistance counters, threshold results or rendered explanations. A resistance verdict is a
function of three inputs:

```
plan positions  +  actual spray history  +  ruleset
```

Two of those change after the plan is saved. The moment an operator logs an unplanned
Group 3 spray, a stored "Good fit" becomes a lie that still looks authoritative. So every
verdict is recomputed on read, by the client, from `spray_records` (sql/193 targets +
sql/195 block attribution) and the client's ruleset registry.

**The portal must follow the same rule.** If Lovable renders a plan, it must evaluate it
against current history at render time, not cache a status on the row or in its own tables.

## 3. Identity

| Thing | Identity | Stability guarantee |
|---|---|---|
| Plan | `resistance_plans.id` (uuid) | Minted **by the client**, before first upload. Never reassigned. |
| Planned position | `positions[].id` (text) | Stable across edits **and reorders**. |
| Planned product | `positions[].products[].id` (text) | Stable across edits. |

A plan is **not** keyed by `(season, disease, block set)`. Growers legitimately keep more
than one plan for the same season and disease (e.g. a conservative and an aggressive
rotation), so that tuple is not unique and must never be treated as an identity.

Position ids are the association target for future plan-vs-actual work. **Reordering
changes sequence, not identity** — "Spray 4" is a display ordinal derived from array
position plus completed-spray count, never an identifier.

## 4. Columns

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid` PK | Client-minted. |
| `vineyard_id` | `uuid` NOT NULL | FK → `vineyards`, `on delete cascade`. |
| `season_id` | `text` NOT NULL | `"2026/27"`. Never a bare year — an AU season spans two. |
| `season_start_year` | `integer` | Sortable projection of `season_id`. |
| `disease` | `text` NOT NULL | `powdery_mildew`, `downy_mildew`. See §7. |
| `jurisdiction` | `text` NOT NULL | `AU` \| `NZ` \| `unknown`. |
| `crop` | `text` NOT NULL | `grape`. |
| `block_ids` | `uuid[]` | **No FK.** See §5. |
| `positions` | `jsonb` NOT NULL | Ordered array. See §6. |
| `notes` | `text` | |
| `ruleset_id` | `text` | e.g. `AU_GRAPE_POWDERY_2026_07_22`. Required once planned. |
| `ruleset_version` | `text` | e.g. `2026.07.22`. Required once planned. |
| `created_by` | `uuid` | Attribution only, **not** a visibility scope. Write-once. |
| `updated_by` | `uuid` | Follows the last editor. |
| `created_at` / `updated_at` | `timestamptz` | Server-owned. |
| `deleted_at` | `timestamptz` | Soft-delete tombstone. |
| `client_updated_at` | `timestamptz` | The **grower's** edit time. Drives conflict resolution. |
| `sync_version` | `integer` | Reserved. |

## 5. `block_ids` has no foreign key, on purpose

Same historical-survival principle as sql/195. A plan must not be destroyed or corrupted
because a block was later archived:

- `on delete cascade` would erase a season's planning because someone tidied a block list.
- `on delete set null` would silently turn the plan into one covering nothing.

Instead ids are validated **at write time only** (a block from a different vineyard is
rejected) and left alone thereafter. An id matching no paddock is **allowed** — that is how
a plan survives the deletion of one of its blocks. Clients resolve the current block name
where possible and otherwise render the block as unavailable, keeping the plan intact.

A `null` element or a duplicate is rejected: "one of these blocks is nothing" is not a
statement a plan can make, and a duplicated block would be counted twice in multi-block
aggregation.

## 6. The `positions` document

An **ordered JSON array**. **Array order is the planned chronology** — the engine derives
sequence from order, not from dates, so a stale `target_date_epoch_ms` can never contradict
the sequence the operator is looking at. Preserve order exactly; never sort on read.

```jsonc
[
  {
    "id": "pos-1",                          // required, non-empty, unique in the plan
    "products": [                            // optional; [] = an unfilled slot
      {
        "id": "prod-1",                      // required, non-empty
        "group_codes": ["11", "3"],          // FRAC codes. >1 code = CO-FORMULATION
        "source": "group",                   // "group" | "saved_chemical"
        "saved_chemical_id": "…",            // present when source = saved_chemical
        "product_name": "…",
        "chemical_availability": "available_verified",
        "registered_for_planned_disease": true
      }
    ],
    "target_date_epoch_ms": 1790000000000,   // DISPLAY METADATA ONLY
    "growth_stage": "flowering",
    "note": "…"
  }
]
```

Structure is enforced by `resistance_plan_positions_are_valid(jsonb)`: array at top level,
objects as elements, non-empty unique position ids, `products` an array of objects, each
with a non-empty id, `group_codes` an array of strings, `source` one of the two known
values. An **empty position is deliberately allowed** — it is a slot the grower created but
has not filled, and rejecting it would refuse to save a half-built plan.

### Co-formulation vs tank mix

A position holds a **list** of products, not one flattened group set. `FRAC 11 + 3` is two
genuinely different things: one co-formulated product carrying both codes, or two products
tank-mixed. The engine treats them differently. Do not flatten.

### Product identity is stored twice, on purpose

A position stores **both** `saved_chemical_id` **and** `group_codes`. The plan must be able
to say *what chemistry it intended* independently of *which product was chosen to fulfil
it*. If the Chemical Store product is later edited or deleted, the intended FRAC group is
still known. **Never reconstruct planned intent by re-reading today's product record.**

### Cross-platform wire contract

Keys are `snake_case` and **byte-identical on iOS and Android**. A plan authored on an
iPhone decodes on Android and vice versa. Enum raw values: `powdery_mildew`,
`downy_mildew`, `AU`/`NZ`/`unknown`, `grape`, `group`/`saved_chemical`,
`available_verified` / `available_partially_verified` / `available_unverified` /
`conflict` / `unavailable`. Absent optionals are **omitted**, not sent as `null`.

## 7. `disease` is intentionally not a hard enum

The CHECK requires non-empty lower-case text, **not** an allow-list of today's two
diseases. Botrytis, black spot and eutypa are foreseeable, and a pinned constraint would
mean the day botrytis rules ship, every client saving a botrytis plan gets a database
rejection until a migration lands — schema gating a client feature. The real guard is the
client enum plus the ruleset registry: a disease with no ruleset simply cannot be
evaluated, which is a far better failure than a refused write.

`jurisdiction` **is** constrained, because that vocabulary is small, external and stable.

## 8. Ruleset metadata is mandatory once a plan has content

`ruleset_id` + `ruleset_version` are required whenever `positions` is non-empty. A plan with
planned chemistry but no recorded strategy version is a compliance trap: when the next
CropLife strategy lands there is no way to tell whether the plan predates it.

**Never rewrite a stored version.** When the active ruleset is newer, clients surface
"a newer resistance strategy is available — review this plan" and leave the stamp alone. A
2026 plan must never be silently re-presented as though it were authored against 2027
guidance. An empty plan is exempt so a freshly created plan is savable.

## 9. Visibility and permissions (RLS)

Plans are **vineyard data shared with the team**, not private documents.

| Operation | Rule |
|---|---|
| `select` | `is_vineyard_member(vineyard_id)` — any member. |
| `insert` / `update` | `has_vineyard_role(vineyard_id, ['owner','manager','supervisor','operator'])`. |
| `delete` | **Denied to all clients** (`using (false)`). |

A spray operator must be able to open the plan they are expected to execute, so reads are
not scoped to `created_by`. `created_by` is retained purely for attribution and is
**write-once** — both clients push edits through the same upsert as creates, so without the
guard the last editor would overwrite the original author on the first colleague edit.

## 10. Deletion is always soft

Hard delete is denied to clients and this is not tidiness. A hard delete is **invisible to
other devices**: Device B, holding the plan in its cache, has nothing to observe and would
push the plan back on its next sync. The tombstone is what makes a delete propagate.

- `soft_delete_resistance_plan(p_id uuid)` — sets `deleted_at`.
- `restore_resistance_plan(p_id uuid)` — clears it.

Deleting a plan removes **advisory planning data only**. There is no FK from this table into
operational data, so the statement cannot reach spray, chemical or resistance history even
in principle. `sql/tests/196` asserts this both behaviourally and structurally.

Pulls **must include tombstones** so other devices can observe the delete.

## 11. Conflict resolution

**Whole-document last-write-wins, arbitrated by `client_updated_at`** (the sql/185
`reject_stale_client_write()` trigger, reused unchanged).

```
1. Device A edits offline               (client_updated_at = T1)
2. Device B reorders positions online   (T2 > T1)  → applied
3. Device A reconnects, replays T1                → SKIPPED silently
4. B's version is authoritative; A converges on its next pull
```

The skip is silent: PostgREST reports success with an empty representation, so replay
queues resolve instead of retrying forever. An equal timestamp is applied (idempotent
re-send). Rows with `null` on either side are never blocked.

**Position arrays are never merged element-wise.** There is no defensible automatic
reconciliation of "A moved the Group 11 spray earlier" against "B removed that spray": any
row-wise merge could produce a sequence *neither operator authored* and then present it as
resistance-compliant. Losing the older edit is visible and recoverable; inventing a third
plan is not. **The portal must treat a plan as one document too.**

## 12. Client sync model

Offline-first, server-authoritative:

1. Mutations commit to a local cache **first** and return immediately. Ids are minted on
   the device, so a plan created offline already has its final identity and is immediately
   editable. Nothing waits for Supabase to allocate an id.
2. An id-keyed **outbox** records plans with unpushed changes.
3. A pass **pushes before pulling**, so an offline edit is offered to the server before any
   remote version can overwrite the cache.
4. Only the **plan definition** is queued. Engine output is never cached or uploaded.
5. A failed pass leaves the cache and outbox intact; the grower keeps working.

### One-time adoption of Planner v1 plans

Existing users hold plans in `UserDefaults` / `SharedPreferences` that the server has never
seen, so only the device can supply them — **there is no SQL backfill and this migration
performs none**. Each plan keeps its existing id, which makes the upload idempotent (an
upsert on the same primary key, not a second copy of the season). A per-vineyard flag is
set only **after** the push succeeds, so a mid-migration failure leaves the plans local,
usable and still queued rather than marked done and silently unsynced.

## 13. Not exposed in `vinetrack-api`

Resistance Plans are **not** part of the public API surface. The API's current stage covers
operational records, not planning resources, and publishing a v1 planning shape would
commit to a contract still settling. Mobile sync uses this direct backend contract.
Exposing plans through the public API is a **documented future item**.

## 14. Future work (not built)

- Plan-vs-actual association (`positions[].id` is the seam).
- Portal read/write UI.
- Ruleset-update review UX beyond the existing `rulesetUpdateAvailable` flag.
- Public API resource.
