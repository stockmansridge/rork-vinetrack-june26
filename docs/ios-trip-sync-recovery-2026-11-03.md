# VineTrack iOS Trip Sync — P0 recovery contract (3 November 2026)

## Scope and release rule

**iOS-only. Do not change Android sync, the shared Supabase schema, production Trip/Spray/Actual rows, or retained device archives as part of this incident.**

Trip work remains blocked for iOS release acceptance until a source-attested physical TestFlight run proves the original Trip lifecycle and durable receipt closure. GitHub commits, simulator builds and a green individual entity sync timestamp are not sufficient.

## What happened and what previous fixes actually did

| Area | Prior fix | What it did not prove |
|---|---|---|
| Start/Resume | Improved original spray start, distinct-work consent, preserved original operation IDs | A held create+activate WAL could still stay held after backend repair |
| Creation RPC | Lowercase UUID emission plus production RPC UUID-identity SQL comparison | A previously held ORIGINAL operation could automatically recover during normal Sync |
| Failed queue | Vineyard-slice upload admission and protection of foreign/global legacy metadata | Global counts were not selected-vineyard receipts |
| Finished Trip | Exact-ID ended readback, linked Spray/Actual proof, durable acknowledgement before clearing | Server terminal timestamps and local tank timestamps were genuinely equivalent |
| Tank discrepancy | Field-specific discrepancy codes and <=1ms representation allowance | The original device/server field-by-field differences on affected devices |
| Spray child | Exact linked-parent server verification before new occurrence Spray upload | Historic partially accepted Spray/Trip pairs were automatically repaired |
| Delete | Guarded queued-Trip cancellation with retained tombstone evidence | A broad hard purge or replacement for legitimate completed Trip reconciliation |

## Change 1 — iOS Recovery v3 diagnostics

Use **Settings → Sync Diagnostics → Inspect Trip sync with server (read-only) → Copy Trip Sync Recovery v3**.

- Captures the selected account/vineyard, original queued IDs, journal stage and operation IDs, exact server Trip readback, tank ID/time differences in milliseconds, linked Spray IDs and Actual Use readback outcome.
- No server write, no journal replay, no queue acknowledgement, no creation of replacement IDs.
- Never looks up foreign/unattributed queue IDs using the selected account's authority; those remain visible as protected counts.
- Raw operational archives can be exported privately with the existing explicit retained-evidence exporter, not posted to public issues.
- An embedded source SHA is meaningful only when the signed build/archive receipt independently matches that SHA.

## Change 2 — exact original reconciliation

1. **Completed server Trip**: require exact ID, vineyard, lifecycle, route inclusion, tank IDs and fields, Spray completion, tank-session dependencies, Actual Use quantities and cleared completion intents. <=1ms numeric timestamp difference is allowed as bounded precision loss; a larger time difference remains held for review.
2. **Never-accepted original occurrence Trip**: only a retained held two-operation create+activate journal with `creationConfirmed=false` and `serverActive=false` can trigger an authoritative absence check. If the scoped authenticated server row is absent, unhold the exact frozen original operations, without modifying IDs or amounts, then replay via the normal idempotent RPC journal. If the server row exists or the scope cannot be proven, retain evidence and do not re-create.
3. Only a verified ended Trip may have its corresponding queue entry durably acknowledged; never clear a cross-vineyard or unmatched queue entry.

## Change 3 — status isolation

Foreign/unattributed legacy Trip queue IDs are still retained as unresolved **global** work and must continue to prevent a global full-upload receipt. They must not, on their own, raise a false **current-vineyard failed Trip** error. Selected-vineyard failures are still errors; genuine unverified historical Trip evidence is still held.

## Test and acceptance gates

- Exact Git SHA must be recorded at build, and matched to the signed TestFlight archive. Native source-pinned workflow: `.github/workflows/ios-trip-sync-recovery-v3.yml`.
- Native assertions: original held WAL IDs unchanged on release, malformed or changed coverage stays held, terminal same-instant tolerance bounded at 1ms, larger end/tank differences held, other-vineyard queue remains unresolved without a current-scope failure.
- Simulator failures need classification. Previous Issue 43 runs compiled but some selected tests crashed with `malloc: pointer being freed was not allocated`; these are not automatically proven assertion failures, nor do they mean tests passed.
- **Physical iPhone acceptance:** start an original queued spray without creating replacement IDs, open live map, record an actual mix, end Trip, sync parent + linked Spray + Actual Use, verify independent server acceptance and exact original queued-ID durable clearance, close/reopen without regression.
- Test a genuinely different server tank time and a foreign-vineyard historical queue: do not overwrite, delete, reopen or silently acknowledge either.
- Do not uninstall TestFlight or clear original device data before completing recovery verification.
- If the v3 report indicates a tank time difference larger than 1ms, do not expand a tolerance merely to make the queue green. Investigate that exact original field and the wire-format contract.

## Follow-up if any gate fails

Preserve: installed build and embedded source revision, original v3 report, private retained archive, exact affected Trip ID, native .xcresult, and server-authoritative readbacks. Change only the failing iOS field/admission path; no broad sync rewrite.
