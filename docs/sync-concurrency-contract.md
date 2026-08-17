# VineTrack sync concurrency contract

Status: **Stage 1 LIVE (sql/198 applied and tested). Stage 2 (mobile adoption) implemented.**
Read this before touching any sync path, and before adding a `client_updated_at` comparison
anywhere.

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

- **Stage 1 — DONE.** `sql/198` applied and its test suite run in production.
- **Stage 2 — DONE.** iOS and Android send `base_revision`, request the row back, and handle
  `REVISION_CONFLICT`. This could not have shipped before Stage 1: a client that sends
  `base_revision` to a database without the column gets a hard `PGRST204` on every write.
- **Stage 3 — NOT STARTED.** Once `sync_discarded_writes` shows no legacy-path traffic,
  delete the timestamp branch from `reject_stale_client_write()`. Check that table before
  assuming the old path is dead — released clients in the field still use it.

## Implementation matrix

Which concurrency authority each client actually uses per table. "Revision" means the client
sends `base_revision`, requests the row back, adopts the returned `server_revision`, and
handles `REVISION_CONFLICT` explicitly. "Timestamp" means it still relies on
`client_updated_at` ordering and therefore still carries the clock-skew defects.

| Entity | Android | iOS |
| --- | --- | --- |
| Resistance Plans | Revision | Revision |
| Pruning Seasons | Revision | Revision |
| Pruning Yield Settings | Revision | Revision |

A cell may only be changed to "Revision" once the PRODUCTION write path on that platform
actually sends `base_revision` and classifies `REVISION_CONFLICT` — not when tests exist, and
not when the model merely carries the field. An inaccurate cell here is worse than no table:
it is the thing a future reader will trust instead of re-reading the code.

On iOS the two pruning entities were migrated after Resistance Plans, in
`SupabasePruningSyncRepository.upsertSeason` and
`SupabasePruningYieldSettingsSyncRepository.upsertSettings`. Both route every response through
the shared `VersionedWriteClassifier`, and both pull paths now decide staleness by revision
(`SyncRevisionContract.isRemoteBehind`) instead of comparing `client_updated_at`.

## Client implementation (Stage 2, shipped)

One shared helper per platform — `SyncRevisionContract.kt` and `SyncRevisionContract.swift`
— owns conflict detection and revision parsing for ALL versioned entities. Three subtly
different PT409 parsers is how one of them ends up classifying a conflict as a network error
and silently dropping an edit, so there is exactly one.

Rules the repositories follow, and which any new versioned entity must also follow:

- **`server_revision` is server state, not content.** Cached alongside each record and
  re-stamped from the cache on every local save, so a stale view model or a copied object
  cannot assert a version the device never read.
- **Never fabricate a revision.** A record the server has not yet accepted carries `null`,
  and `base_revision` is then omitted — which sql/198 reads as a create. A made-up number
  would either be refused forever or match by luck and overwrite an unseen edit.
- **Never compute `base + 1`.** The new revision is taken from the returned row. Any actor
  (portal, RPC, maintenance) can advance a row, so the increment is not the client's to
  predict.
- **`return=representation` is mandatory.** The response body is the only place the new
  `server_revision` appears. With `return=minimal` a device could never learn what version
  its own edit became and would resend the previous `base_revision` forever.
- **One request per row.** A multi-row upsert is one transaction, so a single conflict would
  abort every other row in the batch and strand valid edits.
- **A conflict is not an exception.** It is returned as an outcome
  (`VersionedWriteOutcome.Applied` / `.Conflict`), because a thrown conflict gets counted as
  a transport failure and blindly retried.
- **Replica lag is decided by revision.** A pulled row at a strictly older `server_revision`
  than one this device has had confirmed is ignored. The old timestamp version of this check
  failed in exactly the case that mattered: on a slow phone the newer edit looks older than
  the row it just wrote.
- **A 2xx with an empty representation is treated as a conflict, never a success.** That is
  the legacy silent-skip signature, and reporting it as success is the original defect.

### Sync states

`synced`, `pendingUpload`, `syncing`, `failed`, `conflict`. `conflict` outranks the others
and is deliberately NOT worded as "sync failed — retry", because retrying is the one thing
that cannot work: the same `base_revision` is refused every time. Wording shipped:

> Changes need review. This plan was also edited on another device — both versions are
> saved, so you can choose which one to keep.

For the queued pruning writes the same idea is a `PendingWriteStatus.CONFLICT`, excluded
from `PendingWriteStatus.retryable` so the replay loop cannot pick it up.

### Conflict durability

For Resistance Plans a conflict record stores the **whole local document, the whole server
document, and both revisions** — persisted, not in memory. A `hasConflict = true` flag would
tell the grower something went wrong having already destroyed the plan they wrote, which is
worse than the silent loss this contract exists to fix. Resolution is explicit
(`resolveKeepingLocal` / `resolveKeepingServer`); nothing resolves a conflict by comparing
timestamps, because both versions descend from the same revision and device time cannot
adjudicate authorship.

The two pruning entities persist the same guarantee with less duplication, because their
local authored copy already lives in a persisted store of its own:

- the **queued write stays queued** (`pendingUpserts` keeps its entry), so the grower's
  authored values survive a restart — that is the half that exists nowhere else;
- a persisted `SyncRevisionConflictMark` (both revisions plus a detection time) records that
  the row is conflicted, so the state survives a cold launch rather than clearing on relaunch
  and leaving a queued write nobody ever retries or reviews;
- the **server copy is re-fetched on demand** (`serverCopyOfSeason`,
  `serverCopyOfSettings`) rather than stored side by side. A cached "server version" starts
  drifting the moment it is written, and a review screen showing a stale server copy is worse
  than one that fetches.

On both platforms a conflicted row is excluded from the replay candidate set, and a pull is
forbidden from overwriting it — either rule alone would be insufficient: replay would refuse
forever, and a pull would destroy the authored edit.

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

### `client_updated_at` still has a NON-concurrency job on `pruning_yield_settings`

This one is easy to "clean up" and break. The `sql/181` resurrection trigger un-deletes a
soft-deleted block configuration when a client upsert arrives whose `client_updated_at` is
**distinct from** the stored value:

```sql
if tg_op = 'UPDATE' and new.client_updated_at is distinct from old.client_updated_at then
  new.deleted_at := null;
```

That is a **change detector**, not an ordering comparison. Dropping the field, sending it as
null, or freezing it to a constant would silently stop un-deleting a block's settings — the row
would stay soft-deleted and the grower's saved values would look permanently gone. The soft‑
delete RPC deliberately does not touch `client_updated_at`, which is what keeps the two
behaviours independent.

So the rule is: **remove timestamp ORDERING as the concurrency authority, not every use of the
timestamp.** iOS therefore still encodes `client_updated_at` unconditionally on every pruning
yield-settings write, and `PruningYieldSettingsRevisionSyncTests` asserts both that it is
present and non-null, and that two successive edits send different values.

## Verification

### Before a client release may be called revision-safe

All four of these must be GREEN, from an actual test run:

1. `sql/tests/198_sync_concurrency_revisions_tests.sql`
2. Android revision tests — `PruningYieldSettingsRevisionSyncTest`,
   `PruningSeasonRevisionSyncTest`, `ResistancePlanRevisionSyncTest`,
   `ResistancePlanRepositoryTest`
3. iOS revision tests — `ResistancePlanRevisionSyncTests`, `ResistancePlanRepositoryTests`,
   `PruningSeasonRevisionSyncTests`, `PruningYieldSettingsRevisionSyncTests`
4. The cross-platform parity fixture — `SyncRevisionParityTest` (Android) AND
   `SyncRevisionParityTests` (iOS), whose final section asserts that all THREE entities
   classify the same canonical server responses identically

The parity fixture is listed separately on purpose. The per-platform suites each prove their
own platform behaves; only the paired fixture proves the two platforms make the SAME decision
about the same server response. Two clients drifting apart here is not cosmetic — one of them
would report a refused write as saved.

### A build is not a test run

**Compiling the app target is NOT equivalent to executing the unit tests, and must never be
reported as if it were.** `runChecks` (Android `assembleRelease`, iOS app-target build) proves
the code compiles. It executes no assertion, and on iOS it does not even compile the test
target — a type error inside the test files will not surface. Every claim of the form "the
revision contract is verified" requires the four green runs above.

When reporting status, state authored counts and executed counts separately. "Authored but
unexecuted" is an honest and useful state; "green" applied to an unexecuted suite is not.

### Editing the parity fixture

Never change a fixture constant on one platform alone. `SyncRevisionParityTest.Fixture` and
its Swift mirror carry identical literals — row ids, revisions, PostgREST bodies. If one
changes without the other, the fixtures still pass and the parity guarantee is silently void.

### SQL test-role requirement

- `sql/tests/198_sync_concurrency_revisions_tests.sql` — rollback-only, every write test
  runs as `authenticated` with RLS active.
- Owner-role tests are **not** sufficient for these functions: the guard writes to the
  RLS-protected `sync_discarded_writes`, and a table owner bypasses RLS. This is the same
  class of blindness found in `sql/195`/`sql/197`. Any new test of a cross-table write
  guard must switch to `authenticated` and assert the caller genuinely lacks access to the
  row being validated against.
