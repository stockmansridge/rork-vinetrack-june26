# Spray Block Attribution — backend contract (sql/195)

**Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the web
portal) CONSUMES it.** The portal must not invent a competing block-attribution
schema, add its own columns, or write the derived projection.

Status: **APPLIED to production** (`tbafuqwruefgkbyxrxyb`).
`sql/tests/195_spray_block_attribution_tests.sql` **PASSED**. No further migration
is expected for this contract.

`vinetrack-api` source exposes the fields but **has not been confirmed deployed** —
see [Read API](#read-api).

---

## What this answers

Which blocks a spray application actually treated.

Before sql/195 a `spray_records` row knew its `vineyard_id` and nothing more. The
operator's Blocks-step selection reached the canonical geometry engine, every
block's area and row length was resolved individually, and the whole per-block
list was then collapsed into aggregate totals and discarded. Planned jobs already
had block identity via the `spray_job_paddocks` junction (sql/032); the actual
compliance record did not. This closes that asymmetry.

---

## The columns

Both live on `public.spray_records`. Both nullable, no defaults, no backfill.

### `application_blocks jsonb`

The authoritative, ordered, structured snapshot. **The only one a client writes.**

```json
[
  {
    "blockId": "11111111-1111-4111-8111-111111111111",
    "blockName": "Home Block",
    "grossAreaHa": 10.0,
    "rowLengthMetres": 31250,
    "rowSpacingMetres": 3.2,
    "rowCount": 40,
    "geometrySource": "mapped_rows",
    "geometryQuality": "authoritative"
  }
]
```

- `blockId` — **required**, a uuid, the stable `paddocks.id`. THE identity.
- `blockName` — display snapshot at application time. **Never match on it.**
- The remaining fields are the per-block breakdown of the sql/191 aggregate
  geometry, copied verbatim from the calculation.

Order is the operator's selection order. Duplicates are collapsed.

### `block_ids uuid[]`

A queryable projection of `application_blocks[].blockId`, GIN-indexed.

**DERIVED BY TRIGGER on every insert and update. Do not write it.** Anything you
send is overwritten from `application_blocks`. This is what guarantees the
queryable ids can never disagree with the per-block geometry — a record whose
geometry was calculated from blocks A+C cannot claim it treated A+B.

---

## NULL means "blocks not recorded"

This is the load-bearing rule.

`NULL` in both columns means, exactly and only, **this record predates block
attribution**. It does **not** mean:

- all blocks
- no blocks
- the vineyard's current blocks
- the block containing matching row numbers

**Do not backfill.** Do not infer attribution from row ranges, block-name
similarity, current geometry, vineyard size or chemical history.

In the UI, a record with `NULL` attribution must read **"Blocks not recorded"**.
Rendering the vineyard's present-day blocks against it would turn an unknown into
a false statement of fact.

An **empty array is rejected** by constraint. "Recorded as treating no blocks" is
not a state a real application can be in, so absence is spelled `NULL` and only
`NULL`. The two columns are also constrained to be recorded together or not at
all.

---

## Integrity rules the database enforces

| Rule | Behaviour |
|---|---|
| `application_blocks` shape | Must be a non-empty array of objects, each with a parseable uuid `blockId`. A block *name* used as identity is rejected. |
| `block_ids` derivation | Overwritten from `application_blocks` on every write. |
| Duplicates | Collapsed to first occurrence, order preserved. |
| Empty array | Rejected on both columns. |
| Paired presence | `application_blocks IS NULL` ⇔ `block_ids IS NULL`. |
| Vineyard isolation | A block belonging to a **different** vineyard is **rejected**. |
| Unknown / deleted block id | **Allowed.** See below. |

### Why there is no foreign key

A `uuid[]` cannot carry one — but more importantly, a completed spray is a
compliance document. When a block is later deleted or archived, the historical
application must keep saying which block it treated. An FK (or an existence check)
would force the system either to cascade the id away or to refuse the write, both
of which destroy history for referential tidiness. Unknown ids are preserved and
rendered from the `blockName` snapshot.

Vineyard isolation is therefore asymmetric on purpose: a block that **exists** in
another vineyard is refused; a block matching **no** paddock row is kept.

---

## Querying per-block history

```sql
select *
  from public.spray_records
 where vineyard_id = $1
   and block_ids @> array[$2]::uuid[]
   and deleted_at is null
   and is_template = false
 order by date;
```

Backed by `idx_spray_records_block_ids` (GIN, partial on `block_ids is not null`),
so historical NULL rows cost nothing.

Records with `NULL` attribution **never appear** in any block's history. They are
not irrelevant, though — they happened somewhere in that vineyard and are simply
unplaceable. Anything reasoning about a single block must be able to say
*"historical block attribution is incomplete"* rather than *"no issue detected"*.

---

## Read API

`vinetrack-api` exposes both fields additively on the spray detail payload. No
existing field is removed or renamed.

```json
{
  "block_ids": ["1111...", "3333..."],
  "application_blocks": [ { "blockId": "1111...", "blockName": "Home Block" } ]
}
```

Filter on `block_ids`; render from `application_blocks`. Both are `null` for
records predating sql/195.

**Redeploy required** after applying the migration — the function selects an
explicit column list:

```bash
supabase functions deploy vinetrack-api --project-ref <ref>
```

---

## Display rule for names (implement this exactly)

Both mobile clients resolve a treated block's label with one deterministic rule.
The portal must match it, or the same application will read differently in two
places:

```text
1. The id still resolves to a live block  -> that block's CURRENT name
2. The id no longer resolves              -> the STORED blockName snapshot
3. Neither is available                   -> "Unknown block"
```

Step 1 is deliberately the *current* name: after a rename, that is what the
operator will find in the app today, so showing the old snapshot would send them
looking for a block that no longer appears anywhere. The snapshot exists for step
2 — an archived block whose name would otherwise be lost. Readability must not
depend on the block still existing.

When attribution is `null`, show **"Blocks not recorded"**. Never the vineyard's
current blocks.

**Note on id casing:** iOS writes `UUID.uuidString` (uppercase); Postgres and
Android use lowercase. The same block legitimately appears in both spellings, so
compare ids **case-insensitively**. This is normalisation of one identity, not name
matching.

---

## Machine-readable exports

The mobile CSV exports add two **export-only** columns, deliberately absent from
the re-importable template (no operator should be typing uuids into a
spreadsheet):

- `Block IDs` — stable identity, the column to join on.
- `Blocks` — human names, resolved by the rule above.

Multi-value cells use `"; "` (semicolon + space), not a comma: these are CSV
files, and a comma inside a cell forces quoting and invites splitting on the wrong
character. A semicolon cannot occur in a uuid, so the ID cell stays unambiguously
splittable.

Both cells are **empty** when attribution was never recorded — emptiness is how
every other never-recorded spray field is already exported, and a parser must not
have to string-match English prose. The `"Blocks not recorded"` wording is for
human-facing surfaces (PDF, screen) only.

---

## Templates

`spray_jobs` is deliberately **not** changed. Planned jobs and templates already
carry intended blocks in `spray_job_paddocks` (sql/032); adding a second
representation there is exactly the disconnected-list mistake this migration
exists to avoid.

Templates stored as `spray_records` rows (`is_template = true`) use the columns
above and keep block **identity** as reusable intent while dropping the per-block
geometry **outputs** — mirroring the existing sql/191 template rule:

- **Kept:** `blockId`, `blockName`
- **Cleared:** `grossAreaHa`, `rowLengthMetres`, `rowSpacingMetres`, `rowCount`,
  `geometrySource`, `geometryQuality`

A template must state which blocks the operator intends without freezing one
season's areas and row lengths. When a template is instantiated the operator can
change the selection, and the **new** spray freezes whatever they finally chose —
an old template never dictates historical attribution.

If a template references a block that no longer exists, surface it (e.g. *"1
template block is no longer available"*) and require the operator to resolve the
Blocks step. **Never silently substitute another block.**

---

## Three independent unknowns

Do not collapse these into a generic "missing data" state. They have different
causes and different remedies:

| Dimension | Absent when | Meaning |
|---|---|---|
| **Block** | `application_blocks IS NULL` | Which blocks were treated was never recorded (pre-sql/195). |
| **Target** | `targets IS NULL` (sql/193) | What the spray was for was never recorded. `[]` means recorded as none. |
| **Chemistry** | no `chemicalSnapshot` on a line (sql/194) | The product's resistance classification was not captured. |

An application may legitimately have block = known, target = unknown, chemistry =
verified — or any other combination.

---

## Multi-block applications

One application remains **one** spray record. A spray covering three blocks is not
split into three records; its attribution simply contains three ids. Anything
needing per-block granularity projects the record into per-block events at read
time, all sharing the original application id, so general spray history and cost
reporting never double-count the pass.
