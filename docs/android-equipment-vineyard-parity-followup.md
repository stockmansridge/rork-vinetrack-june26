# Deferred Android follow-up — tractor/machine vineyard isolation & fuel-rate parity

**Status:** DEFERRED — not started. Explicitly out of scope for the iOS + database
equipment-integrity fix (sql/206 + the iOS vineyard-scoped equipment work).

**Why deferred:** Android has unrelated open issues. Partially fixing equipment
scoping on top of them would produce a half-migrated client that disagrees with
both the corrected iOS behaviour and the database contract, and would make the
existing Android problems harder to diagnose. No Android source, repository,
ViewModel, screen or test was touched by this task.

**Trigger to pick this up:** once the current Android issues are resolved.

---

## The contract Android must be brought in line with

The corrected contract, now implemented on iOS and enforced server-side:

1. **Local persistence may hold several vineyards. Active in-memory operational
   state must represent only the selected vineyard.**
2. **Two read classes, never mixed.**
   - *Operational* ("what may be picked right now") → selected vineyard only.
   - *Historical/reference* ("what does this saved record point at") → resolved
     through the record's own `vineyardId` and its own saved equipment id.
3. **Absence-based reconciliation only on a full pull** (`since == nil`).
   A delta response is not an authoritative list. Rows with queued local work
   are never treated as ghosts.
4. **Soft deletes stay soft.** Server queries deliberately return tombstones so
   the delete can be replayed; a tombstoned row and a row absent from a full
   authoritative response must both end up unavailable as operational equipment.
5. **`fuel_usage_l_per_hour` is the configured/expected machine rate.** A
   fill-to-fill calculation is an *observation* and must never be written into
   it implicitly.

---

## Work items

### 1. Vineyard isolation in Android state
- `AppViewModel.kt` clears machines on vineyard switch (~L5001) but the wider
  equipment state needs the same audit iOS just had: tractors, vineyard
  machines, fuel purchases and fuel logs must all be re-scoped on switch, in
  both directions, without a logout/reinstall.
- `repo.listMachines(vineyardId)` (~L12687) is correctly scoped — confirm every
  other equipment read is too, and that none falls back to a cross-vineyard union.
- `DomainCacheStore.kt` has **no** machine cache today. Decide deliberately
  whether to add one; if added it must be vineyard-keyed from day one.

### 2. Machine write semantics
- `VineyardMachineRepository.kt`'s `MachineInput` is a **full-row replace**.
  Audit it: a partial update expressed as a full-row write can silently reset
  fields (including `fuel_usage_l_per_hour`) that the caller never intended to
  touch. This is the most likely mechanism behind unexplained rate changes.

### 3. Fuel Log fuel-rate guard (parity with iOS)
- `FuelLogScreen.kt` (~L890–910, write at ~L899) applies a calculated L/hr with
  **no confirmation** and **no legacy-tractor cascade**.
- Required behaviour, identical to iOS:
  - calculated L/hr stays an observation and is never written automatically;
  - "Use as machine default" is explicitly user-initiated;
  - the confirmation shows **Current default** → **Calculated from this interval**;
  - it warns that fill-to-fill figures are unreliable when a fill is missed,
    tanks are not filled to the same level, or an engine-hour reading is skipped;
  - the configured value is preserved until confirmation;
  - the legacy-tractor cascade matches iOS, so the two platforms cannot leave
    machine and backing tractor holding different rates.
- The asymmetry matters: the Stockmans `1.20361083249749` value was almost
  certainly written from Android, where no cascade and no confirmation existed.

### 4. Full-pull reconciliation
- Mirror the iOS `planFullPullReconciliation` contract for tractors, vineyard
  machines, fuel purchases and fuel logs. Reconcile only on a full pull, only
  for the vineyard being synced, never for rows with queued local work, and
  never from a delta response.

### 5. Server-side guards now in place (no Android change required, but note them)
- `sql/206` refuses **new** cross-vineyard `vineyard_machines.legacy_tractor_id`
  and `tractor_fuel_logs.machine_id` / `.tractor_id` links with errcode `23514`.
  Android must surface that as a clean, user-readable sync error rather than a
  raw Postgres message.

### 6. Tests
Port the iOS regression suite (`ios/VineTrackTests/EquipmentVineyardIsolationTests.swift`):
vineyard isolation across a switch, multi-vineyard persistence, ghost
reconciliation (full vs delta), soft delete, scoped pickers, legacy-id
cross-binding, historical resolution, and the fuel-default confirmation flow.

---

## Explicitly still NOT in scope, on any platform

Retiring the legacy tractor architecture. `tractors`, `legacy_tractor_id`, and
the historical `tractor_id` references on trips, spray records, spray jobs,
fuel logs and maintenance logs all remain load-bearing. No deletion, no
bulk conversion, no reclassification.
