# VineTrack sync concurrency contract

Status: **Stage 1 authored (sql/198), not yet applied.** Read this before touching any
sync path, and before adding a `client_updated_at` comparison anywhere.

---

## The one rule

**A device wall clock is never the authority for whether an edit is stale.**

Two different concepts were conflated for a year, and conflating them cost data:

| Concept | Column | Authority |
|---|---|---|
| *When the human made this edit* | `client_updated_at` | Device clock. Metadata and display only. |
| *Which server version this edit was based on* | `base_revision` | Client-asserted, server-verified. |
| *Which version the row is at now* | `server_revision` | Server. The only concurrency authority. |

If you find yourself writing `new.client_updated_at < old.client_updated_at` to decide
whether to accept a write, stop. That is the defect this document exists to prevent.

## Why the timestamp contract failed

`sql/185` introduced a stale-write guard comparing `client_updated_at` values, and
`sql/196` reused it. The comparison mixed clocks:

- mobile writes device time (`Date()` on iOS, `System.currentTimeMillis()` on Android);
- portal, RPCs and the external write API (`sql/186`) write server `now()`.

Three consequences, all real:

1. **Slow device.** Phone 10 minutes behind opens a row the portal just saved, makes a
   genuine new edit, submits `09:55` against a stored `10:00`. Read as stale. Discarded.
2. **Fast device.** Phone 10 minutes ahead stores `10:10`. Every other device and the
   portal are locked out until the server clock passes it. One bad clock poisons the row.
3. **Silently.** Returning `NULL` from a `BEFORE UPDATE` trigger skips the row without
   raising. PostgREST reports success — `204 No Content` for the Android client, which
   asks for `return=minimal`. The app clears its outbox and shows "synced". The grower's
   work is gone with no error anywhere in the system.

## The contract (sql/198)

Three tables are covered — the ones clients upsert directly and that carried the guard:
`resistance_plans`, `pruning_seasons`, `pruning_yield_settings`.

### Writing a record

1. Read the row. Keep its `server_revision` alongside your local copy.
2. Let the user edit, online or offline. Stamp `client_updated_at` with the device clock —
   that is honest metadata about when they worked, and skew no longer matters.
3. When syncing, send the payload **plus `base_revision` = the `server_revision` you read
   in step 1**.
4. Outcomes:
   - **Applied.** The row is written, `server_revision` advances. Re-read it for the next edit.
   - **`REVISION_CONFLICT` / SQLSTATE `PT409` / HTTP 409.** Someone else wrote since you
     read. Your write did not land. Handle it (below).

`server_revision` is issued by `bump_server_revision()` on every write, so it also advances
for portal PATCHes, RPCs and server-side maintenance. Whatever a client puts in
`server_revision` is overwritten — it cannot be forged.

`base_revision` is a **transient write-only channel and is always stored as NULL.** This is
not tidiness. PostgREST `resolution=merge-duplicates` only assigns columns present in the
request body, so a persisted `base_revision` would be inherited by an old client's upsert
(which omits it) and the guard would refuse a write that is perfectly valid. Nulling it on
every write is what keeps the old and new paths independent.

### Handling a conflict

Match on the message `REVISION_CONFLICT`, not on the HTTP status alone (a gateway may
rewrite the status; the message is stable).

On conflict the repository **must**:

- keep the pending local edit in the outbox — it has not been saved anywhere;
- keep the latest server copy, so the user can see what changed;
- surface a conflict state.

It **must not**:

- clear the outbox as if the write succeeded;
- overwrite the local pending edit with the server row;
- report "Sync complete".

Both sides are preserved. The user decides.

### Resistance Plans are whole documents

Never merge `positions` element-wise. If device A moves the Group 11 spray earlier and
device B deletes that position, any row-wise reconciliation can produce an ordered spray
sequence **neither operator authored**, and then present it as resistance-compliant. One
authored version wins, or the user is shown an explicit conflict. Losing an edit is
recoverable and visible; inventing a third plan is neither.

## Old-client compatibility

Released clients send no `base_revision` and keep the timestamp path. Two things improve
for them without an app update:

- incoming `client_updated_at` is **clamped to server `now()`**, so a fast clock can no
  longer poison a row — the fast-device defect is fixed for every client immediately;
- a discarded write is recorded in **`public.sync_discarded_writes`** with its full
  payload, so the loss is visible and the grower's edit is recoverable.

The slow-device defect **cannot** be fixed for a released client: it sends nothing that
distinguishes "late replay of an old edit" from "new edit made on a slow phone". Only a
`base_revision` can. Hence the staged rollout:

- **Stage 1** — `sql/198`. Additive; no client change required; safe to apply alone.
- **Stage 2** — iOS and Android send `base_revision` and handle `REVISION_CONFLICT`.
  Cannot ship before Stage 1 is live in production, because the column would not exist.
- **Stage 3** — once `sync_discarded_writes` shows no legacy-path traffic, delete the
  timestamp branch from `reject_stale_client_write()`.

Do not collapse these stages. A client that sends `base_revision` to a database without
the column gets a hard `PGRST204` error on every write.

## What the Lovable portal must send

The portal is a first-class writer here, not an afterthought. To edit one of the three
tables safely it sends exactly what mobile sends:

- the row `id`;
- the updated payload;
- `base_revision` — the `server_revision` value it read with the row.

Nothing web-specific and no RPC is required. A plain PostgREST `PATCH`/upsert including
`base_revision` gets the same guarantees, and a conflict arrives as HTTP `409` with the
message `REVISION_CONFLICT`. The portal should show the same "changed on another device"
affordance rather than retrying blindly — a blind retry with the same `base_revision` will
conflict forever.

Suggested user-facing wording, once conflict UI is built:

> This record changed on another device. Review the latest version before saving again.

## Where the timestamp path still lives (deliberately)

These write guards compare `p_client_updated_at` inside RPCs and were **not** changed,
because they already return an explicit, visible `stale: true` result rather than silently
discarding — the client can tell:

- `sql/120` `edit_pruning_entry`
- `sql/161` pruning season canonical assignment
- `sql/166` pruning activity edit
- `sql/169` manual issue edit

They still inherit clock skew and should move to `base_revision` when each is next touched.
They are lower risk because the outcome is reported, not swallowed. Tracked, not fixed.

Ordinary display timestamps (`created_at`, `updated_at`, `date`) are out of scope and
should stay as they are.

## Verification

- `sql/tests/198_sync_concurrency_revisions_tests.sql` — rollback-only, every write test
  runs as `authenticated` with RLS active.
- Owner-role tests are **not** sufficient for these functions: the guard writes to the
  RLS-protected `sync_discarded_writes`, and a table owner bypasses RLS. This is the same
  class of blindness found in `sql/195`/`sql/197`. Any new test of a cross-table write
  guard must switch to `authenticated` and assert the caller genuinely lacks access to the
  row being validated against.
