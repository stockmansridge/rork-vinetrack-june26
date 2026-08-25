import Foundation
import Testing
@testable import VineTrack

/// Pins the boundary between a **Tractor** and a **Vineyard Machine**.
///
/// # What went wrong in production
///
/// The Vineyard Machines creation picker offered every `VineyardMachineType`,
/// including `.tractor`. A grower adding the JH Testing "new holand t4.85n"
/// naturally used that path, producing a *native tractor-machine*:
///
/// ```
/// machine_type      = tractor
/// legacy_tractor_id = null
/// ```
///
/// To the user that record is a tractor, but it is invisible under Manage
/// Tractors (JH Testing had no `tractors` row at all) and unavailable to the
/// legacy `trips.tractor_id` costing path. The Tractors screen actively taught
/// the mistake, telling users "Tractors also appear under Vineyard Machines".
///
/// The fix has three layers, and these tests cover all three:
///
/// * **Taxonomy** — Tractor is not offered when creating a Vineyard Machine.
/// * **Backstop** — the save path refuses to CREATE the orphan state, while
///   leaving rows that are already in it fully editable so they can be
///   repaired rather than stranded.
/// * **Display** — a tractor appears under Tractors only, even though a linked
///   machine row exists underneath it for the Fuel Log and legacy costing.
///
/// The database half of the same boundary is `sql/206` (guards) and `sql/207`
/// (the JH promotion + the C9 orphan report).
@MainActor
struct EquipmentTaxonomyBoundaryTests {

    // MARK: - Storage keys (mirror MigratedDataStore's private constants)

    private static let tractorsKey = "vinetrack_tractors"
    private static let machinesKey = "vinetrack_vineyard_machines"
    private static let fuelPurchasesKey = "vinetrack_fuel_purchases"
    private static let fuelLogsKey = "vinetrack_tractor_fuel_logs"

    /// JH Testing stand-in.
    private static let jhTesting = UUID(uuidString: "59973ced-1fb9-42ec-a66d-9eaad3172824")!
    /// Stockmans Ridge stand-in.
    private static let stockmans = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    /// The real JH Testing machine id, preserved by the sql/207 promotion.
    private static let jhMachineId = UUID(uuidString: "70861e55-2f9c-4a1a-af52-e1a8fe8bffe5")!

    // MARK: - Fixtures

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

    private func machine(
        _ id: UUID = UUID(),
        vineyard: UUID,
        name: String,
        type: VineyardMachineType,
        legacyTractorId: UUID? = nil,
        lph: Double = 0
    ) -> VineyardMachine {
        VineyardMachine(
            id: id,
            vineyardId: vineyard,
            name: name,
            machineType: type,
            fuelTrackingEnabled: true,
            availableForJobCosting: true,
            fuelUsageLPerHour: lph,
            legacyTractorId: legacyTractorId
        )
    }

    /// The Vineyard Machines management list predicate, mirrored so the display
    /// rule is asserted rather than assumed.
    private func vineyardMachineList(_ store: MigratedDataStore) -> [VineyardMachine] {
        store.machines().filter { $0.legacyTractorId == nil }
    }

    // MARK: - 1. The creation picker no longer offers Tractor

    @Test("The Vineyard Machine picker does not offer Tractor")
    func pickerDoesNotOfferTractor() {
        let creatable = VineyardMachineType.userCreatableCases

        #expect(!creatable.contains(.tractor))
        #expect(creatable == [.atv, .sideBySide, .harvester, .utilityVehicle, .otherVineyardMachine])

        // Creating a new machine: five options, no Tractor.
        #expect(VineyardMachineType.pickerCases(editing: nil) == creatable)
        #expect(!VineyardMachineType.pickerCases(editing: nil).contains(.tractor))

        // Editing an ATV: unchanged, still no Tractor.
        #expect(VineyardMachineType.pickerCases(editing: .atv) == creatable)
    }

    @Test("Tractor remains a valid stored type — this is a UI restriction only")
    func tractorRemainsAValidType() {
        // The enum case, its raw value and its label must all survive: the
        // database CHECK constraint still accepts 'tractor' and tractor-backed
        // machine rows still decode.
        #expect(VineyardMachineType.allCases.contains(.tractor))
        #expect(VineyardMachineType.tractor.rawValue == "tractor")
        #expect(VineyardMachineType(rawValue: "tractor") == .tractor)
        #expect(VineyardMachineType.allCases.count == VineyardMachineType.userCreatableCases.count + 1)
    }

    @Test("Editing a tractor-typed row keeps Tractor in the picker")
    func editingATractorTypedRowKeepsItsOwnType() {
        // A SwiftUI Picker whose selection is absent from its options renders
        // blank and re-types the record on the next save. Hiding the real
        // current value would silently corrupt exactly the mis-classified rows
        // this boundary exists to protect.
        let options = VineyardMachineType.pickerCases(editing: .tractor)

        #expect(options.contains(.tractor))
        #expect(options.first == .tractor)
        // …and the reclassification route stays open.
        #expect(options.contains(.atv))
        #expect(options.count == VineyardMachineType.userCreatableCases.count + 1)
    }

    // MARK: - 2. The save path refuses to create an unlinked tractor

    @Test("A new Vineyard Machine cannot be saved as an unlinked tractor")
    func newUnlinkedTractorMachineIsRejected() {
        defer { cleanUp() }
        let store = makeStore(selected: Self.jhTesting)

        let orphan = machine(vineyard: Self.jhTesting, name: "new holand t4.85n", type: .tractor)
        #expect(orphan.isUnlinkedTractorMachine)

        let saved = store.addVineyardMachine(orphan)

        #expect(saved == false)
        #expect(store.currentVineyardMachines.isEmpty)
        // Rejected means *not written* — not written-then-hidden.
        #expect(store.persistedVineyardMachines(forVineyard: Self.jhTesting).isEmpty)
    }

    @Test("Every other machine type still saves normally")
    func nonTractorTypesStillSave() {
        defer { cleanUp() }
        let store = makeStore(selected: Self.jhTesting)

        for type in VineyardMachineType.userCreatableCases {
            let saved = store.addVineyardMachine(
                machine(vineyard: Self.jhTesting, name: "T\(type.rawValue)", type: type)
            )
            #expect(saved, "\(type.displayName) should still be creatable")
        }

        #expect(store.currentVineyardMachines.count == VineyardMachineType.userCreatableCases.count)
        #expect(store.currentVineyardMachines.allSatisfy { !$0.isUnlinkedTractorMachine })
    }

    @Test("A tractor-backed machine is still supported internally")
    func tractorBackedMachineIsStillSupported() {
        defer { cleanUp() }
        let store = makeStore(selected: Self.stockmans)

        // This is the row the Tractors path and the sql/097 backfill create.
        // It is tractor-typed AND linked, so it is legitimate and must save.
        let backing = UUID()
        let linked = machine(
            vineyard: Self.stockmans,
            name: "New Holland T4.85N",
            type: .tractor,
            legacyTractorId: backing,
            lph: 6.8
        )
        #expect(!linked.isUnlinkedTractorMachine)

        #expect(store.addVineyardMachine(linked))
        #expect(store.currentVineyardMachines.contains { $0.id == linked.id })

        // The same must hold for a row arriving from the server.
        let store2 = makeStore(selected: Self.stockmans)
        store2.applyRemoteVineyardMachineUpsert(linked)
        #expect(store2.currentVineyardMachines.map(\.id) == [linked.id])
    }

    @Test("An existing machine cannot be converted into an unlinked tractor")
    func convertingAMachineIntoAnUnlinkedTractorIsRejected() {
        defer { cleanUp() }

        let atv = machine(vineyard: Self.jhTesting, name: "Polaris Ranger", type: .atv)
        let store = makeStore(machines: [atv], selected: Self.jhTesting)

        var converted = atv
        converted.machineType = .tractor          // no legacyTractorId

        #expect(store.updateVineyardMachine(converted) == false)
        // The stored row is unchanged, not partially written.
        #expect(store.currentVineyardMachines.first?.machineType == .atv)
    }

    @Test("A row that is ALREADY an unlinked tractor stays editable")
    func existingOrphanStaysEditable() {
        defer { cleanUp() }

        // The JH Testing record as it exists today, before the sql/207 repair.
        let orphan = machine(
            Self.jhMachineId,
            vineyard: Self.jhTesting,
            name: "new holand t4.85n",
            type: .tractor
        )
        let store = makeStore(machines: [orphan], selected: Self.jhTesting)

        // The guard mirrors the sql/206 triggers: it refuses to CREATE the bad
        // state, never to maintain one that already exists. Stranding the row
        // would leave the grower unable to correct it from the app at all.
        var renamed = orphan
        renamed.name = "New Holland T4.85N"
        #expect(store.updateVineyardMachine(renamed))
        #expect(store.currentVineyardMachines.first?.name == "New Holland T4.85N")

        // Reclassifying it away from tractor is also allowed — that is one of
        // the two valid repairs.
        var reclassified = renamed
        reclassified.machineType = .otherVineyardMachine
        #expect(store.updateVineyardMachine(reclassified))
        #expect(store.currentVineyardMachines.first?.machineType == .otherVineyardMachine)
    }

    // MARK: - 3. Display: a tractor appears in exactly one place

    @Test("Tractor-backed machines do not appear under Vineyard Machines")
    func tractorBackedMachinesAreHiddenFromVineyardMachines() {
        defer { cleanUp() }

        let newHolland = Tractor(
            vineyardId: Self.stockmans,
            name: "New Holland T4.85N",
            brand: "New Holland",
            model: "T4.85N",
            fuelUsageLPerHour: 6.8
        )
        let kubota = Tractor(
            vineyardId: Self.stockmans,
            name: "Kubota M5",
            brand: "Kubota",
            model: "M5",
            fuelUsageLPerHour: 8.5
        )
        let backedA = machine(
            vineyard: Self.stockmans, name: "New Holland T4.85N",
            type: .tractor, legacyTractorId: newHolland.id, lph: 6.8
        )
        let backedB = machine(
            vineyard: Self.stockmans, name: "Kubota M5",
            type: .tractor, legacyTractorId: kubota.id, lph: 8.5
        )
        let atv = machine(vineyard: Self.stockmans, name: "Polaris Ranger", type: .atv)

        let store = makeStore(
            tractors: [newHolland, kubota],
            machines: [backedA, backedB, atv],
            selected: Self.stockmans
        )

        // Stockmans acceptance: both tractors under Tractors…
        #expect(store.currentTractorsSorted.map(\.id) == [kubota.id, newHolland.id])
        // …and neither as a user-managed Vineyard Machine.
        #expect(vineyardMachineList(store).map(\.id) == [atv.id])

        // The underlying rows still exist for the Fuel Log / costing pickers,
        // which read the unfiltered list.
        #expect(store.currentVineyardMachines.count == 3)
    }

    @Test("A properly created tractor is listed under Manage Tractors")
    func properTractorsAppearUnderTractors() {
        defer { cleanUp() }

        let store = makeStore(selected: Self.jhTesting)
        #expect(store.currentTractors.isEmpty)   // the "No Tractors" state

        store.addTractor(Tractor(
            vineyardId: Self.jhTesting,
            name: "New Holland T4.85N",
            brand: "New Holland",
            model: "T4.85N",
            fuelUsageLPerHour: 0
        ))

        #expect(store.currentTractorsSorted.map(\.displayName) == ["New Holland T4.85N"])
    }

    // MARK: - 4. The JH Testing promotion, as the client must see it

    @Test("Promoting the JH machine preserves its id and its fuel history")
    func jhPromotionPreservesMachineIdAndFuelHistory() {
        defer { cleanUp() }

        // Starting state: the orphan machine, a fuel log against it, no tractor.
        let orphan = machine(
            Self.jhMachineId,
            vineyard: Self.jhTesting,
            name: "new holand t4.85n",
            type: .tractor,
            lph: 0
        )
        let fuelLog = TractorFuelLog(
            vineyardId: Self.jhTesting,
            machineId: Self.jhMachineId,
            fillDateTime: Date(timeIntervalSince1970: 1_000_000),
            litresAdded: 120,
            engineHours: 1420.0,
            filledToFull: true
        )
        let store = makeStore(machines: [orphan], fuelLogs: [fuelLog], selected: Self.jhTesting)

        #expect(store.currentTractors.isEmpty)
        #expect(vineyardMachineList(store).map(\.id) == [Self.jhMachineId])

        // The promotion, as it arrives from the server after sql/207: one new
        // tractor, and the SAME machine updated in place with a link.
        let promoted = Tractor(
            id: UUID(uuidString: "207e0001-2f9c-4a1a-af52-e1a8fe8bffe5")!,
            vineyardId: Self.jhTesting,
            name: "New Holland T4.85N",
            brand: "New Holland",
            model: "T4.85N",
            fuelUsageLPerHour: 0
        )
        var linked = orphan
        linked.legacyTractorId = promoted.id
        store.applyRemoteTractorUpsert(promoted)
        store.applyRemoteVineyardMachineUpsert(linked)

        // Acceptance: it appears under Tractors…
        #expect(store.currentTractorsSorted.map(\.displayName) == ["New Holland T4.85N"])
        // …and no longer under Vineyard Machines…
        #expect(vineyardMachineList(store).isEmpty)
        // …with exactly one machine row, still carrying the original id.
        #expect(store.currentVineyardMachines.map(\.id) == [Self.jhMachineId])
        #expect(store.currentTractors.count == 1)

        // The fuel log is untouched: same machine link, no tractorId written.
        let logs = store.currentTractorFuelLogs
        #expect(logs.count == 1)
        #expect(logs.first?.machineId == Self.jhMachineId)
        #expect(logs.first?.tractorId == nil)
        #expect(logs.first?.litresAdded == 120)

        // And the promoted machine now resolves its backing tractor.
        #expect(store.historicalTractor(id: linked.legacyTractorId, inVineyard: Self.jhTesting)?.id == promoted.id)
    }

    @Test("The promotion invents no fuel rate")
    func promotionDoesNotFabricateAFuelRate() {
        defer { cleanUp() }

        let promoted = Tractor(
            vineyardId: Self.jhTesting,
            name: "New Holland T4.85N",
            brand: "New Holland",
            model: "T4.85N",
            fuelUsageLPerHour: 0
        )
        let store = makeStore(tractors: [promoted], selected: Self.jhTesting)

        // 0 means "not known" — never a real 0 L/hr rate that costing could use.
        #expect(store.currentTractors.first?.fuelUsageLPerHour == 0)
        #expect(store.currentTractors.first?.hasFuelUsageRate == false)
    }

    @Test("A tractor with no known fuel rate is still valid to keep and edit")
    func unknownFuelRateTractorRemainsEditable() {
        defer { cleanUp() }

        let unknown = Tractor(
            vineyardId: Self.jhTesting,
            name: "New Holland T4.85N",
            brand: "New Holland",
            model: "T4.85N",
            fuelUsageLPerHour: 0
        )
        let known = Tractor(
            vineyardId: Self.jhTesting,
            name: "Kubota M5",
            brand: "Kubota",
            model: "M5",
            fuelUsageLPerHour: 8.5
        )
        let store = makeStore(tractors: [unknown, known], selected: Self.jhTesting)

        // The form's relaxation rule: only a tractor that ALREADY lacks a rate
        // may be saved without one. Requiring a figure here would force the
        // grower to fabricate fuel-consumption data to edit the name of a
        // record the app itself created.
        #expect(store.currentTractors.first { $0.id == unknown.id }?.hasFuelUsageRate == false)
        #expect(store.currentTractors.first { $0.id == known.id }?.hasFuelUsageRate == true)

        // Editing an unrelated field must not require inventing a rate.
        var renamed = unknown
        renamed.model = "T4.85N Cab"
        renamed.name = "New Holland T4.85N Cab"
        store.updateTractor(renamed)

        let reread = store.currentTractors.first { $0.id == unknown.id }
        #expect(reread?.displayName == "New Holland T4.85N Cab")
        #expect(reread?.fuelUsageLPerHour == 0)
    }

    // MARK: - 5. Stockmans Ridge is unaffected by the JH repair

    @Test("The JH repair leaves Stockmans equipment untouched")
    func stockmansIsUnaffected() {
        defer { cleanUp() }

        let newHolland = Tractor(
            vineyardId: Self.stockmans, name: "New Holland T4.85N",
            brand: "New Holland", model: "T4.85N", fuelUsageLPerHour: 6.8
        )
        let kubota = Tractor(
            vineyardId: Self.stockmans, name: "Kubota M5",
            brand: "Kubota", model: "M5", fuelUsageLPerHour: 8.5
        )
        let backedA = machine(
            vineyard: Self.stockmans, name: "New Holland T4.85N",
            type: .tractor, legacyTractorId: newHolland.id, lph: 6.8
        )
        let backedB = machine(
            vineyard: Self.stockmans, name: "Kubota M5",
            type: .tractor, legacyTractorId: kubota.id, lph: 8.5
        )
        let jhOrphan = machine(
            Self.jhMachineId, vineyard: Self.jhTesting,
            name: "new holand t4.85n", type: .tractor
        )

        let store = makeStore(
            tractors: [newHolland, kubota],
            machines: [backedA, backedB, jhOrphan],
            selected: Self.jhTesting
        )

        // Apply the JH promotion while JH Testing is selected.
        let promoted = Tractor(
            vineyardId: Self.jhTesting, name: "New Holland T4.85N",
            brand: "New Holland", model: "T4.85N", fuelUsageLPerHour: 0
        )
        var linked = jhOrphan
        linked.legacyTractorId = promoted.id
        store.applyRemoteTractorUpsert(promoted)
        store.applyRemoteVineyardMachineUpsert(linked)

        // Switch to Stockmans: two tractors, unchanged rates, both still hidden
        // from Vineyard Machines, and no JH row anywhere.
        store.selectedVineyardId = Self.stockmans
        store.reloadCurrentVineyardData()

        #expect(store.currentTractorsSorted.map(\.displayName) == ["Kubota M5", "New Holland T4.85N"])
        #expect(store.currentTractors.first { $0.id == newHolland.id }?.fuelUsageLPerHour == 6.8)
        #expect(store.currentTractors.first { $0.id == kubota.id }?.fuelUsageLPerHour == 8.5)
        #expect(vineyardMachineList(store).isEmpty)
        #expect(!store.currentVineyardMachines.contains { $0.id == Self.jhMachineId })
        #expect(store.currentVineyardMachines.count == 2)
    }
}
