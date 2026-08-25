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

### 5. Tractor vs Vineyard Machine UI boundary (added after the JH Testing repair)

This is the *cause* of the JH Testing defect, and Android still has the same
open path today. Until it is closed, Android can keep creating the exact orphan
records that sql/207 had to repair by hand.

- **Remove Tractor from the Vineyard Machines creation picker.** Android must
  offer only ATV, Side-by-side, Harvester, Utility vehicle and Other vineyard
  machine. Do NOT remove `tractor` from the Kotlin enum, from the
  `machine_type` CHECK constraint, or from any decoding path — tractor-backed
  machine rows remain required internally. This is a creation restriction only.
- **Keep the current type visible when editing.** If a row is already
  tractor-typed, the picker must still show Tractor while it is being edited.
  A dropdown whose selection is missing from its own options renders blank and
  silently re-types the record on save — corrupting precisely the
  mis-classified rows the change exists to protect. iOS does this through
  `VineyardMachineType.pickerCases(editing:)`.
- **Add the save-path backstop.** Refuse to CREATE a machine with
  `machineType == tractor && legacyTractorId == null`, and refuse an edit that
  turns a legitimate machine into one. Do NOT block edits to a row that is
  already in that state — same restraint as the sql/206 triggers, or existing
  records become unrepairable from the app. iOS exposes this as
  `VineyardMachine.isUnlinkedTractorMachine` and returns a `Bool` from the
  add/update store methods so the form can show an error instead of dismissing
  on a write that never happened.
- **Hide tractor-backed machines from the Vineyard Machines list** (filter
  `legacyTractorId == null`), so a tractor appears to the user under Tractors
  only, even though a machine row exists underneath for the Fuel Log and legacy
  costing.
- **Audit the equipment help text.** iOS removed "Tractors also appear under
  Vineyard Machines" in favour of "Add tractors used for vineyard work, fuel
  tracking and trip costing", and points users at Equipment → Tractors from the
  machine screens. Android copy must not teach the old model.
- **Allow an unknown fuel rate on a tractor.** The promoted JH tractor has
  `fuel_usage_l_per_hour = 0` ("not set"). If the Android tractor form requires
  a value greater than zero to save, that record cannot be edited without
  someone inventing a consumption figure. iOS now relaxes the rule for a
  tractor that already lacks a rate, shows blank rather than "0.0", and
  displays "Fuel usage not set" in the list.

### 6. Server-side guards now in place (no Android change required, but note them)
- `sql/206` refuses **new** cross-vineyard `vineyard_machines.legacy_tractor_id`
  and `tractor_fuel_logs.machine_id` / `.tractor_id` links with errcode `23514`.
  Android must surface that as a clean, user-readable sync error rather than a
  raw Postgres message.
- `sql/207` adds report check **C9 `native_tractor_machine_unlinked`**. If
  Android keeps creating tractor-typed machines with no backing tractor, that
  count will climb — it is the detector for this exact Android gap.

### 7. Tests
Port both iOS suites:
- `ios/VineTrackTests/EquipmentVineyardIsolationTests.swift` — vineyard
  isolation across a switch, multi-vineyard persistence, ghost reconciliation
  (full vs delta), soft delete, scoped pickers, legacy-id cross-binding,
  historical resolution, and the fuel-default confirmation flow.
- `ios/VineTrackTests/EquipmentTaxonomyBoundaryTests.swift` — picker excludes
  Tractor, unlinked tractor-machines are rejected on create, the other five
  types still save, tractor-backed machines stay supported internally and
  hidden from the machines list, an existing orphan stays editable, and the JH
  promotion preserves the machine id and its fuel history.

---

## Explicitly still NOT in scope, on any platform

Retiring the legacy tractor architecture. `tractors`, `legacy_tractor_id`, and
the historical `tractor_id` references on trips, spray records, spray jobs,
fuel logs and maintenance logs all remain load-bearing. No deletion, no
bulk conversion, no reclassification.
