import Foundation
import Testing
@testable import VineTrack

/// Regression suite for the tractor / vineyard-machine integrity defect.
///
/// # What went wrong in production
///
/// Four collections — `tractors`, `vineyardMachines`, `fuelPurchases`,
/// `tractorFuelLogs` — were loaded from a single MULTI-vineyard blob into
/// in-memory state and then read unfiltered by pickers, reports and setup
/// checklists. `reloadCurrentVineyardData()` never touched them, so switching
/// from Stockmans Ridge to JH Testing left Stockmans' New Holland 6.8 and
/// Kubota 8.5 selectable inside JH Testing. Worse, the blob was append-only:
/// a tractor hard-deleted on the server had no tombstone to replay, so stale
/// 9.0/9.2 rows survived every sync and could only be cleared by reinstalling.
///
/// These tests pin the two halves of the fix:
///
/// * **Scope** — in-memory operational state represents ONLY the selected
///   vineyard, while the on-disk blob stays multi-vineyard so no vineyard's
///   slice is lost when another one saves.
/// * **Reconciliation** — a FULL pull (`since == nil`) is authoritative and
///   retires ghosts; a DELTA pull never is.
///
/// Historical resolution is asserted separately: a saved Trip, Spray or Fuel
/// Log must resolve equipment through its OWN `vineyardId`, never through
/// whatever vineyard happens to be selected.
@MainActor
struct EquipmentVineyardIsolationTests {

    // MARK: - Storage keys (mirror MigratedDataStore's private constants)

    private static let tractorsKey = "vinetrack_tractors"
    private static let machinesKey = "vinetrack_vineyard_machines"
    private static let fuelPurchasesKey = "vinetrack_fuel_purchases"
    private static let fuelLogsKey = "vinetrack_tractor_fuel_logs"

    // MARK: - Fixtures

    /// Stockmans Ridge stand-in.
    private static let vineyardA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    /// JH Testing stand-in.
    private static let vineyardB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    /// A third vineyard that must never be disturbed by A or B's sync.
    private static let vineyardC = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func tractor(
        _ id: UUID = UUID(),
        vineyard: UUID,
        brand: String,
        model: String,
        lph: Double = 0
    ) -> Tractor {
        Tractor(
            id: id,
            vineyardId: vineyard,
            name: "\(brand) \(model)",
            brand: brand,
            model: model,
            fuelUsageLPerHour: lph
        )
    }

    private func machine(
        _ id: UUID = UUID(),
        vineyard: UUID,
        name: String,
        legacyTractorId: UUID? = nil,
        lph: Double = 0
    ) -> VineyardMachine {
        VineyardMachine(
            id: id,
            vineyardId: vineyard,
            name: name,
            machineType: .tractor,
            fuelTrackingEnabled: true,
            availableForJobCosting: true,
            fuelUsageLPerHour: lph,
            notes: nil,
            serialNumber: nil,
            vinNumber: nil,
            legacyTractorId: legacyTractorId
        )
    }

    /// Seeds the persisted multi-vineyard blobs and returns a store scoped to
    /// `selected`. Uses the shared persistence store because the management
    /// write paths do too — reads and writes must agree or the test proves
    /// nothing about the real app.
    private func makeStore(
        tractors: [Tractor] = [],
        machines: [VineyardMachine] = [],
        fuelLogs: [TractorFuelLog] = [],
        selected: UUID?
    ) -> MigratedDataStore {
        let persistence = PersistenceStore.shared
        persistence.save(tractors, key: Self.tractorsKey)
        persistence.save(machines, key: Self.machinesKey)
        persistence.save(fuelLogs, key: Self.fuelLogsKey)
        let store = MigratedDataStore()
        store.selectedVineyardId = selected
        store.reloadCurrentVineyardData()
        return store
    }

    private func cleanUp() {
        let persistence = PersistenceStore.shared
        persistence.remove(key: Self.tractorsKey)
        persistence.remove(key: Self.machinesKey)
        persistence.remove(key: Self.fuelPurchasesKey)
        persistence.remove(key: Self.fuelLogsKey)
    }

    // MARK: - 1. Vineyard isolation across a switch

    @Test("Switching vineyards re-scopes equipment in both directions")
    func switchingVineyardsRescopesEquipment() {
        defer { cleanUp() }

        let stockmansNewHolland = tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N", lph: 6.8)
        let stockmansKubota = tractor(vineyard: Self.vineyardA, brand: "Kubota", model: "M5", lph: 8.5)
        let jhTestingMachine = machine(vineyard: Self.vineyardB, name: "new holand t4.85n")

        let store = makeStore(
            tractors: [stockmansNewHolland, stockmansKubota],
            machines: [jhTestingMachine],
            selected: Self.vineyardA
        )

        // Stockmans selected: its own equipment, nothing from JH Testing.
        #expect(store.currentTractors.count == 2)
        #expect(store.currentVineyardMachines.isEmpty)

        // Switch to JH Testing.
        store.selectedVineyardId = Self.vineyardB
        store.reloadCurrentVineyardData()

        // Acceptance criteria: neither Stockmans tractor may appear.
        #expect(store.currentTractors.isEmpty)
        #expect(!store.currentTractors.contains { $0.id == stockmansNewHolland.id })
        #expect(!store.currentTractors.contains { $0.id == stockmansKubota.id })
        // JH Testing's own machine stays available.
        #expect(store.currentVineyardMachines.map(\.id) == [jhTestingMachine.id])
        // Raw in-memory state is scoped too, not just the accessor.
        #expect(store.tractors.isEmpty)

        // Switching back restores Stockmans without a reinstall or cache wipe.
        store.selectedVineyardId = Self.vineyardA
        store.reloadCurrentVineyardData()
        #expect(Set(store.currentTractors.map(\.id)) == [stockmansNewHolland.id, stockmansKubota.id])
        #expect(store.currentVineyardMachines.isEmpty)
    }

    @Test("With no vineyard selected no equipment is operationally available")
    func noSelectionExposesNothing() {
        defer { cleanUp() }
        let store = makeStore(
            tractors: [tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N")],
            selected: nil
        )
        #expect(store.currentTractors.isEmpty)
        #expect(store.currentVineyardMachines.isEmpty)
        #expect(store.currentFuelPurchases.isEmpty)
        #expect(store.currentTractorFuelLogs.isEmpty)
    }

    // MARK: - 2. Multi-vineyard persistence survives a scoped save

    @Test("Saving the selected vineyard leaves another vineyard's slice intact")
    func savingOneVineyardKeepsTheOtherPersisted() {
        defer { cleanUp() }

        let aTractor = tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N")
        let bTractor = tractor(vineyard: Self.vineyardB, brand: "Kubota", model: "M5")
        let store = makeStore(tractors: [aTractor, bTractor], selected: Self.vineyardA)

        // Selecting A exposes only A.
        #expect(store.currentTractors.map(\.id) == [aTractor.id])

        // A write while A is selected must not drop B's persisted rows.
        store.addTractor(tractor(vineyard: Self.vineyardA, brand: "Fendt", model: "211V"))
        let persisted = store.persistedTractors()
        #expect(persisted.filter { $0.vineyardId == Self.vineyardA }.count == 2)
        #expect(persisted.contains { $0.id == bTractor.id })

        // Selecting B exposes only B.
        store.selectedVineyardId = Self.vineyardB
        store.reloadCurrentVineyardData()
        #expect(store.currentTractors.map(\.id) == [bTractor.id])
    }

    @Test("A remote upsert for another vineyard persists but never enters operational state")
    func remoteUpsertForOtherVineyardStaysOffOperationalState() {
        defer { cleanUp() }

        let store = makeStore(selected: Self.vineyardA)
        let foreign = tractor(vineyard: Self.vineyardB, brand: "Kubota", model: "M5")
        store.applyRemoteTractorUpsert(foreign)

        #expect(store.currentTractors.isEmpty)
        #expect(store.tractors.isEmpty)
        // Still persisted, so selecting B later shows it.
        #expect(store.persistedTractors(forVineyard: Self.vineyardB).map(\.id) == [foreign.id])
    }

    // MARK: - 3. Ghost reconciliation (full pull only)

    @Test("A full pull retires rows the server no longer returns")
    func fullPullRetiresGhosts() {
        let a = UUID(), b = UUID(), ghost = UUID()
        let local = [a, b, ghost]
        let plan = planFullPullReconciliation(
            local: local,
            remoteIds: [a, b],
            queuedIds: [],
            id: { $0 }
        )
        #expect(plan.ghosts == [ghost])
        #expect(plan.seedable.isEmpty)
    }

    @Test("A full pull never touches a row with queued local work")
    func fullPullSeedsQueuedRowsInsteadOfDeletingThem() {
        let synced = UUID(), offlineCreate = UUID()
        let plan = planFullPullReconciliation(
            local: [synced, offlineCreate],
            remoteIds: [],
            queuedIds: [offlineCreate],
            id: { $0 }
        )
        // The offline create is the grower's only copy — seed it, never drop it.
        #expect(plan.seedable == [offlineCreate])
        // The row this device believed was synced yet the server does not have
        // is a server-side hard delete.
        #expect(plan.ghosts == [synced])
    }

    @Test("A tombstoned row is returned by the server, so it is not a ghost")
    func tombstonedRowIsNotAGhost() {
        // Server queries deliberately include soft-deleted rows so the delete
        // can be replayed locally. A tombstone is therefore PRESENT in the
        // authoritative response and must be handled by the delete branch, not
        // by ghost removal — otherwise the two paths could disagree.
        let tombstoned = UUID()
        let plan = planFullPullReconciliation(
            local: [tombstoned],
            remoteIds: [tombstoned],
            queuedIds: [],
            id: { $0 }
        )
        #expect(plan.ghosts.isEmpty)
        #expect(plan.seedable.isEmpty)
    }

    @Test("Reconciliation only ever considers the vineyard being synced")
    func reconciliationIsVineyardScoped() {
        defer { cleanUp() }

        let aTractor = tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N")
        let bTractor = tractor(vineyard: Self.vineyardB, brand: "Kubota", model: "M5")
        let cGhost = tractor(vineyard: Self.vineyardC, brand: "Deutz", model: "9.0")
        let store = makeStore(tractors: [aTractor, bTractor, cGhost], selected: Self.vineyardA)

        // Full authoritative response for C contains nothing.
        let localForC = store.persistedTractors(forVineyard: Self.vineyardC)
        let plan = planFullPullReconciliation(
            local: localForC,
            remoteIds: [],
            queuedIds: [],
            id: { $0.id }
        )
        #expect(plan.ghosts.map(\.id) == [cGhost.id])

        for ghost in plan.ghosts { store.applyRemoteTractorDelete(ghost.id) }

        // C's ghost is gone; A and B are untouched on disk.
        let persisted = store.persistedTractors()
        #expect(!persisted.contains { $0.id == cGhost.id })
        #expect(persisted.contains { $0.id == aTractor.id })
        #expect(persisted.contains { $0.id == bTractor.id })
    }

    @Test("A delta response is never used for absence-based deletion")
    func deltaResponseNeverDeletes() {
        defer { cleanUp() }

        let aTractor = tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N")
        let bTractor = tractor(vineyard: Self.vineyardA, brand: "Kubota", model: "M5")
        let store = makeStore(tractors: [aTractor, bTractor], selected: Self.vineyardA)

        // A delta pull carrying only A must leave B alone. Reconciliation is
        // gated on `lastSync == nil`, so the only correct action here is the
        // normal upsert loop.
        store.applyRemoteTractorUpsert(aTractor)

        #expect(store.currentTractors.count == 2)
        #expect(store.currentTractors.contains { $0.id == bTractor.id })
    }

    // MARK: - 4. Soft delete

    @Test("A server tombstone removes the machine from operational state and disk")
    func tombstoneRemovesMachine() {
        defer { cleanUp() }

        let live = machine(vineyard: Self.vineyardA, name: "Fendt 211V")
        let deleted = machine(vineyard: Self.vineyardA, name: "Retired Kubota")
        let store = makeStore(machines: [live, deleted], selected: Self.vineyardA)
        #expect(store.currentVineyardMachines.count == 2)

        store.applyRemoteVineyardMachineDelete(deleted.id)

        #expect(store.currentVineyardMachines.map(\.id) == [live.id])
        #expect(!store.persistedVineyardMachines().contains { $0.id == deleted.id })
    }

    // MARK: - 5. UI-facing accessors

    @Test("Pickers and lists read the selected vineyard only")
    func pickerAccessorsAreScoped() {
        defer { cleanUp() }

        let stockmans = tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N")
        let jhMachine = machine(vineyard: Self.vineyardB, name: "new holand t4.85n")
        let store = makeStore(tractors: [stockmans], machines: [jhMachine], selected: Self.vineyardB)

        // Tractor Management, Maintenance, Work Task machine lines and the
        // Spray Calculator all read these.
        #expect(store.currentTractorsSorted.isEmpty)
        #expect(store.currentVineyardMachinesSorted.map(\.id) == [jhMachine.id])
        // `machines()` is the pre-existing correctly-scoped accessor and must
        // stay in agreement with the new one.
        #expect(store.machines().map(\.id) == store.currentVineyardMachinesSorted.map(\.id))
        #expect(store.currentVineyardHasMachinery)
    }

    @Test("Sorted accessors order by display name")
    func sortedAccessorsAreOrdered() {
        defer { cleanUp() }
        let store = makeStore(
            tractors: [
                tractor(vineyard: Self.vineyardA, brand: "Zetor", model: "Major"),
                tractor(vineyard: Self.vineyardA, brand: "Fendt", model: "211V")
            ],
            selected: Self.vineyardA
        )
        #expect(store.currentTractorsSorted.map(\.brand) == ["Fendt", "Zetor"])
    }

    @Test("A legacy tractor id cannot resolve a machine in another vineyard")
    func legacyTractorIdCannotCrossVineyards() {
        defer { cleanUp() }

        let legacyId = UUID()
        // Same legacy id recorded against a machine in a DIFFERENT vineyard —
        // the exact shape that let a Fuel Log bind to foreign equipment.
        let foreignMachine = machine(vineyard: Self.vineyardB, name: "Foreign", legacyTractorId: legacyId)
        let store = makeStore(machines: [foreignMachine], selected: Self.vineyardB)

        #expect(store.historicalMachine(legacyTractorId: legacyId, inVineyard: Self.vineyardA) == nil)
        #expect(store.historicalMachine(legacyTractorId: legacyId, inVineyard: Self.vineyardB)?.id == foreignMachine.id)
    }

    // MARK: - 6. Historical compatibility

    @Test("Saved records resolve equipment through their own vineyard, not the selected one")
    func historicalResolutionUsesTheRecordsVineyard() {
        defer { cleanUp() }

        let aTractor = tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N")
        let bTractor = tractor(vineyard: Self.vineyardB, brand: "Kubota", model: "M5")
        let aMachine = machine(vineyard: Self.vineyardA, name: "Sprayer", legacyTractorId: aTractor.id)
        let store = makeStore(
            tractors: [aTractor, bTractor],
            machines: [aMachine],
            selected: Self.vineyardA
        )

        // A record in A resolves inside A.
        #expect(store.historicalTractor(id: aTractor.id, inVineyard: Self.vineyardA)?.id == aTractor.id)
        #expect(store.historicalTractor(named: "New Holland T4.85N", inVineyard: Self.vineyardA)?.id == aTractor.id)
        #expect(store.historicalMachine(legacyTractorId: aTractor.id, inVineyard: Self.vineyardA)?.id == aMachine.id)

        // The SAME id asked for under the wrong vineyard resolves to nothing —
        // history can never be re-pointed at another vineyard's machine.
        #expect(store.historicalTractor(id: aTractor.id, inVineyard: Self.vineyardB) == nil)

        // A combined lookup prefers the canonical machine but still surfaces
        // the legacy tractor for costing paths that read `trips.tractor_id`.
        let resolved = store.historicalEquipment(
            machineId: nil,
            tractorId: aTractor.id,
            inVineyard: Self.vineyardA
        )
        #expect(resolved.machine?.id == aMachine.id)
        #expect(resolved.tractor?.id == aTractor.id)
    }

    @Test("Historical resolution keeps working after switching vineyards")
    func historicalResolutionSurvivesASwitch() {
        defer { cleanUp() }

        let aTractor = tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N")
        let store = makeStore(tractors: [aTractor], selected: Self.vineyardA)

        // While A is selected its own history resolves.
        #expect(store.historicalTractor(id: aTractor.id, inVineyard: Self.vineyardA) != nil)

        // Switch to B: A's history is no longer in memory, which is correct —
        // B's screens only ever show B's records.
        store.selectedVineyardId = Self.vineyardB
        store.reloadCurrentVineyardData()
        #expect(store.historicalTractor(id: aTractor.id, inVineyard: Self.vineyardA) == nil)

        // Coming back restores it in full.
        store.selectedVineyardId = Self.vineyardA
        store.reloadCurrentVineyardData()
        #expect(store.historicalTractor(id: aTractor.id, inVineyard: Self.vineyardA)?.displayName == "New Holland T4.85N")
    }

    // MARK: - 7. Fuel-rate default is never overwritten implicitly

    @Test("Saving a fuel fill leaves the machine's configured rate untouched")
    func calculatedRateDoesNotChangeTheConfiguredDefault() {
        defer { cleanUp() }

        // The production shape: a machine configured at 6.8 L/hr and a fill
        // interval that computes 120 / (1420.0 - 1320.3) = 1.2036 L/hr.
        let configured = machine(vineyard: Self.vineyardA, name: "New Holland T4.85N", lph: 6.8)
        let store = makeStore(machines: [configured], selected: Self.vineyardA)

        let earlier = TractorFuelLog(
            vineyardId: Self.vineyardA,
            machineId: configured.id,
            fillDateTime: Date(timeIntervalSince1970: 1_000_000),
            litresAdded: 100,
            engineHours: 1320.3,
            filledToFull: true
        )
        let later = TractorFuelLog(
            vineyardId: Self.vineyardA,
            machineId: configured.id,
            fillDateTime: Date(timeIntervalSince1970: 2_000_000),
            litresAdded: 120,
            engineHours: 1420.0,
            filledToFull: true
        )
        store.addTractorFuelLog(earlier)
        store.addTractorFuelLog(later)

        let previous = store.previousFuelLog(
            forMachineGroupOf: later,
            before: later.fillDateTime,
            excluding: later.id
        )
        let result = TractorFuelRateCalculator.rate(current: later, previous: previous)

        // The observation is produced…
        #expect(result.litresPerHour != nil)
        if let lph = result.litresPerHour {
            #expect(abs(lph - 1.20361083249749) < 0.0001)
        }
        // …and the CONFIGURED rate is completely unaffected by it.
        #expect(store.currentVineyardMachines.first { $0.id == configured.id }?.fuelUsageLPerHour == 6.8)
    }

    @Test("Applying the calculated rate is an explicit, confirmed write")
    func applyingTheDefaultReplacesBothMachineAndLegacyTractor() {
        defer { cleanUp() }

        let legacyTractor = tractor(vineyard: Self.vineyardA, brand: "New Holland", model: "T4.85N", lph: 6.8)
        let backed = machine(
            vineyard: Self.vineyardA,
            name: "New Holland T4.85N",
            legacyTractorId: legacyTractor.id,
            lph: 6.8
        )
        let store = makeStore(tractors: [legacyTractor], machines: [backed], selected: Self.vineyardA)

        // Nothing has been confirmed yet → both values stand.
        #expect(store.currentVineyardMachines.first?.fuelUsageLPerHour == 6.8)
        #expect(store.currentTractors.first?.fuelUsageLPerHour == 6.8)

        // The confirmed action mirrors `FuelFillFormSheet.applyAsMachineDefault`
        // and must move machine AND backing tractor together — a half-applied
        // rate is how the two models drifted apart in the first place.
        var updated = backed
        updated.fuelUsageLPerHour = 1.2036
        store.updateVineyardMachine(updated)
        if var t = store.historicalTractor(id: backed.legacyTractorId, inVineyard: backed.vineyardId) {
            t.fuelUsageLPerHour = 1.2036
            store.updateTractor(t)
        }

        #expect(store.currentVineyardMachines.first?.fuelUsageLPerHour == 1.2036)
        #expect(store.currentTractors.first?.fuelUsageLPerHour == 1.2036)
    }

    @Test("The legacy cascade cannot reach another vineyard's tractor")
    func legacyCascadeStaysInsideTheMachinesVineyard() {
        defer { cleanUp() }

        let sharedId = UUID()
        let foreignTractor = tractor(sharedId, vineyard: Self.vineyardB, brand: "Kubota", model: "M5", lph: 8.5)
        let machineInA = machine(vineyard: Self.vineyardA, name: "Fendt", legacyTractorId: sharedId, lph: 6.8)
        let store = makeStore(tractors: [foreignTractor], machines: [machineInA], selected: Self.vineyardA)

        // Resolving the cascade target inside the MACHINE's vineyard finds
        // nothing, so vineyard B's 8.5 L/hr rate is never rewritten.
        #expect(store.historicalTractor(id: machineInA.legacyTractorId, inVineyard: machineInA.vineyardId) == nil)
        #expect(store.persistedTractors(forVineyard: Self.vineyardB).first?.fuelUsageLPerHour == 8.5)
    }
}
