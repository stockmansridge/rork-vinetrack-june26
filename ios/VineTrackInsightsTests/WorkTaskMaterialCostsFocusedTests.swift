import Foundation
import Testing
@testable import VineTrack

@MainActor
struct WorkTaskMaterialCostsFocusedTests {
    private let vineyardA = UUID(uuidString: "00000000-0000-0000-0000-00000000aa01")!
    private let vineyardB = UUID(uuidString: "00000000-0000-0000-0000-00000000aa02")!
    private let taskID = UUID(uuidString: "00000000-0000-0000-0000-00000000aa03")!

    private func persistence() throws -> PersistenceStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaterialCostsFocused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return PersistenceStore(directory: url)
    }

    @Test func catalogueAndUnitsMatchTheSharedContract() {
        #expect(MaterialCatalogueSeed.items.count == 18)
        #expect(MaterialCatalogueSeed.items.first {
            $0.key == "material.trellis.gripple"
        }?.name == "Gripple / Wire Joiner-Tensioner")
        #expect(Set(MaterialCatalogueSeed.items.map(\.key)).count == 18)
        #expect(MaterialUnitCatalog.suggested == ["Each", "Metre", "Roll", "Pack", "Box", "Bag"])
        #expect(MaterialUnitCatalog.normalised("Pallet") == "Pallet")
    }

    @Test func vineyardLibraryIsIsolatedAndSupportsOverridesAndCustomMaterials() {
        var base = MaterialCatalogueSeed.items.first { $0.key == "material.trellis.gripple" }!
        base.remoteId = UUID()
        let override = VineyardMaterial.override(
            vineyardId: vineyardA,
            base: base,
            defaultUnitCost: Decimal(string: "1.82")
        )!
        let custom = VineyardMaterial.custom(
            vineyardId: vineyardA,
            name: "Gripple Plus Medium",
            category: MaterialCategoryCatalog.trellis,
            unit: "Each",
            defaultUnitCost: Decimal(string: "2.15")
        )
        var catalogue = MaterialCatalogueSeed.items
        catalogue[catalogue.firstIndex { $0.key == base.key }!] = base

        let libraryA = MaterialLibrary.merged(
            catalogue: catalogue,
            vineyardMaterials: [override, custom],
            vineyardId: vineyardA
        )
        let libraryB = MaterialLibrary.merged(
            catalogue: catalogue,
            vineyardMaterials: [override, custom],
            vineyardId: vineyardB
        )
        #expect(libraryA.count == 19)
        #expect(libraryA.first { $0.baseMaterialKey == base.key }?.defaultUnitCost == Decimal(string: "1.82"))
        #expect(libraryA.contains { $0.name == "Gripple Plus Medium" && $0.isCustom })
        #expect(libraryB.count == 18)
        #expect(!libraryB.contains { $0.name == "Gripple Plus Medium" })
    }

    @Test func decimalCostingSupportsMultipleLinesAndNoRowsMeansZero() {
        let posts = WorkTaskMaterial(
            workTaskId: taskID, vineyardId: vineyardA,
            materialName: "Line / Trellis Post", unit: "Each",
            quantity: 3, unitCost: Decimal(string: "12.40")!
        )
        let wire = WorkTaskMaterial(
            workTaskId: taskID, vineyardId: vineyardA,
            materialName: "Trellis Wire", unit: "Metre",
            quantity: Decimal(string: "42.5")!, unitCost: Decimal(string: "0.31")!
        )
        #expect(posts.totalCost == Decimal(string: "37.20"))
        #expect(wire.totalCost == Decimal(string: "13.18"))
        #expect(WorkTaskMaterialCosting.total([posts, wire], for: taskID) == Decimal(string: "50.38"))
        #expect(WorkTaskMaterialCosting.total([], for: taskID) == 0)
    }

    @Test func frozenTaskSnapshotSurvivesLibraryRepriceAndDeactivation() throws {
        let store = try persistence()
        let taskRepository = WorkTaskMaterialRepository(persistence: store)
        var custom = VineyardMaterial.custom(
            vineyardId: vineyardA,
            name: "2.4 m Eco Trellis Post",
            unit: "Each",
            defaultUnitCost: Decimal(string: "14.80")
        )
        let line = WorkTaskMaterial(
            workTaskId: taskID,
            vineyardId: vineyardA,
            vineyardMaterialId: custom.id,
            materialName: custom.name,
            category: custom.category,
            unit: custom.unit,
            quantity: 3,
            unitCost: custom.defaultUnitCost!
        )
        taskRepository.saveSlice([line], for: vineyardA)

        custom.defaultUnitCost = Decimal(string: "18.50")
        custom.isActive = false
        let historical = taskRepository.load(forWorkTask: taskID)
        #expect(historical.count == 1)
        #expect(historical[0].materialName == "2.4 m Eco Trellis Post")
        #expect(historical[0].unitCost == Decimal(string: "14.80"))
        #expect(historical[0].totalCost == Decimal(string: "44.40"))
    }

    @Test func offlinePersistenceAndRepeatedMergeKeepOneStableLine() throws {
        let store = try persistence()
        let id = UUID()
        let line = WorkTaskMaterial(
            id: id,
            workTaskId: taskID,
            vineyardId: vineyardA,
            materialName: "Vine Guard",
            unit: "Each",
            quantity: 20,
            unitCost: Decimal(string: "1.10")!
        )
        WorkTaskMaterialRepository(persistence: store).saveSlice([line], for: vineyardA)
        let relaunched = WorkTaskMaterialRepository(persistence: store)
        #expect(relaunched.load(forWorkTask: taskID).first?.id == id)
        _ = relaunched.merge([line], for: vineyardA)
        _ = relaunched.merge([line], for: vineyardA)
        #expect(relaunched.load(forWorkTask: taskID).count == 1)
    }

    @Test func backendNumericRecordsDecodeConsistently() throws {
        let raw = """
        {
          "id": "00000000-0000-0000-0000-00000000aa05",
          "work_task_id": "00000000-0000-0000-0000-00000000aa03",
          "vineyard_id": "00000000-0000-0000-0000-00000000aa01",
          "material_name": "Trellis Wire",
          "category": "Trellis",
          "unit": "Metre",
          "quantity": 42.5,
          "unit_cost": 0.31,
          "total_cost": 13.18,
          "notes": ""
        }
        """
        let backend = try JSONDecoder().decode(BackendWorkTaskMaterial.self, from: Data(raw.utf8))
        let line = backend.toWorkTaskMaterial()
        #expect(line.quantity == Decimal(string: "42.5"))
        #expect(line.unitCost == Decimal(string: "0.31"))
        #expect(line.totalCost == Decimal(string: "13.18"))
    }

    @Test func workTaskMaterialsAllowAuthenticatedVineyardMembers() {
        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true,
            isResolving: false,
            selectedVineyardID: vineyardA,
            isMemberOfSelectedVineyard: true
        ) == .allowed)
        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true,
            isResolving: false,
            selectedVineyardID: vineyardA,
            isMemberOfSelectedVineyard: false
        ) == .unavailable(.notVineyardMember))
    }

    @Test func taskEditorDefaultsAndOverridesRemainIndependent() {
        var base = MaterialCatalogueSeed.items.first { $0.key == "material.trellis.gripple" }!
        base.remoteId = UUID()
        let libraryDefault = VineyardMaterial.override(
            vineyardId: vineyardA,
            base: base,
            defaultUnitCost: Decimal(string: "1.82")
        )!
        let entry = MaterialLibrary.merged(
            catalogue: MaterialCatalogueSeed.items.map { $0.key == base.key ? base : $0 },
            vineyardMaterials: [libraryDefault],
            vineyardId: vineyardA
        ).first { $0.baseMaterialKey == base.key }!

        let defaultLine = entry.makeTaskMaterial(workTaskId: taskID, vineyardId: vineyardA, quantity: 12)
        let overriddenLine = entry.makeTaskMaterial(
            workTaskId: taskID,
            vineyardId: vineyardA,
            quantity: Decimal(string: "0.5")!,
            unitCost: Decimal(string: "1.95")!,
            unit: "Pack"
        )
        #expect(defaultLine.unitCost == Decimal(string: "1.82"))
        #expect(defaultLine.totalCost == Decimal(string: "21.84"))
        #expect(overriddenLine.totalCost == Decimal(string: "0.98"))
        #expect(libraryDefault.defaultUnitCost == Decimal(string: "1.82"))
        #expect(libraryDefault.unit == "Each")
    }

    @Test func editReplacesStableLineAndDeleteRemovesOnlyTaskUsage() throws {
        let persistence = try persistence()
        let taskRepository = WorkTaskMaterialRepository(persistence: persistence)
        let libraryRepository = VineyardMaterialRepository(persistence: persistence)
        let custom = VineyardMaterial.custom(
            vineyardId: vineyardA,
            name: "Gripple Plus Medium",
            category: MaterialCategoryCatalog.trellis,
            unit: "Each",
            defaultUnitCost: Decimal(string: "2.15")
        )
        libraryRepository.saveSlice([custom], for: vineyardA)
        var line = WorkTaskMaterial(
            id: UUID(), workTaskId: taskID, vineyardId: vineyardA,
            vineyardMaterialId: custom.id, materialName: custom.name,
            category: custom.category, unit: custom.unit,
            quantity: 10, unitCost: custom.defaultUnitCost!
        )
        taskRepository.saveSlice([line], for: vineyardA)

        line.quantity = 12
        line.unitCost = Decimal(string: "2.35")!
        _ = taskRepository.merge([line], for: vineyardA)
        #expect(taskRepository.load(forWorkTask: taskID).count == 1)
        #expect(taskRepository.load(forWorkTask: taskID)[0].totalCost == Decimal(string: "28.20"))

        taskRepository.saveSlice([], for: vineyardA)
        #expect(taskRepository.load(forWorkTask: taskID).isEmpty)
        #expect(libraryRepository.load(for: vineyardA).first?.id == custom.id)
    }

    @Test func offlineCustomMaterialSurvivesRestartAndDeactivationOnlyAffectsSelection() throws {
        let persistence = try persistence()
        let id = UUID()
        var custom = VineyardMaterial.custom(
            vineyardId: vineyardA,
            name: "Offline Vine Guard",
            category: MaterialCategoryCatalog.establishment,
            unit: "Box",
            defaultUnitCost: Decimal(string: "42.50"),
            id: id
        )
        VineyardMaterialRepository(persistence: persistence).saveSlice([custom], for: vineyardA)
        let relaunched = VineyardMaterialRepository(persistence: persistence)
        #expect(relaunched.load(for: vineyardA).first?.id == id)

        custom.isActive = false
        relaunched.saveSlice([custom], for: vineyardA)
        let selectable = MaterialLibrary.merged(
            catalogue: MaterialCatalogueSeed.items,
            vineyardMaterials: relaunched.load(for: vineyardA),
            vineyardId: vineyardA
        )
        #expect(!selectable.contains { $0.name == custom.name })
        #expect(relaunched.load(for: vineyardA).first?.name == "Offline Vine Guard")
    }

    @Test func cachedCatalogueRemainsUsableWhenRefreshHasNoResult() throws {
        let persistence = try persistence()
        let repository = MaterialCatalogueRepository(persistence: persistence)
        var gripple = MaterialCatalogueSeed.items.first { $0.key == "material.trellis.gripple" }!
        gripple.remoteId = UUID()
        repository.replace([gripple])
        let effective = MaterialCatalogueSeed.resolve(server: nil, cached: repository.loadCached())
        #expect(effective.count == 1)
        #expect(effective[0].name == "Gripple / Wire Joiner-Tensioner")
        repository.replace([])
        #expect(repository.loadEffective().first?.remoteId == gripple.remoteId)
    }

    @Test func existingWorkTaskCostingRemainsAdditiveAndGateFree() {
        var task = WorkTask(vineyardId: vineyardA, taskType: "Wire Lifting", durationHours: 4)
        task.resources = [WorkTaskResource(workerTypeName: "Casual", hourlyRate: 32, count: 2)]
        #expect(task.totalCost == 256)
        #expect(WorkTaskMaterialCosting.total([], for: task.id) == 0)

        let custom = VineyardMaterial.custom(
            vineyardId: vineyardA,
            name: "Zip Tie 300mm",
            unit: "Pack",
            defaultUnitCost: Decimal(string: "8.40")
        )
        let line = WorkTaskMaterial(
            workTaskId: taskID,
            vineyardId: vineyardA,
            vineyardMaterialId: custom.id,
            materialName: custom.name,
            unit: custom.unit,
            quantity: 2,
            unitCost: custom.defaultUnitCost!
        )
        let payload = BackendWorkTaskMaterial.upsert(
            from: line,
            createdBy: nil,
            updatedBy: nil,
            clientUpdatedAt: Date()
        )
        #expect(payload.id == line.id)
        #expect(task.totalCost == 256)
    }

    @Test func totalCostRollupIncludesEveryAuthoritativeSourceExactlyOnce() {
        let tripID = UUID()
        let task = WorkTask(id: taskID, vineyardId: vineyardA)
        let labour = WorkTaskLabourLine(
            workTaskId: taskID, vineyardId: vineyardA,
            workerCount: 1, hoursPerWorker: 4, hourlyRate: 25
        )
        let machine = WorkTaskMachineLine(
            workTaskId: taskID, vineyardId: vineyardA,
            fuelCost: 10, totalMachineCost: 40
        )
        let trip = Trip(id: tripID, vineyardId: vineyardA, totalDistance: 99_999, workTaskId: taskID)
        let allocation = TripCostAllocation(
            vineyardId: vineyardA, tripId: tripID, seasonYear: 2026,
            totalCost: 75.25
        )
        let material = WorkTaskMaterial(
            workTaskId: taskID, vineyardId: vineyardA,
            materialName: "Posts", quantity: 1, unitCost: 180
        )

        let result = WorkTaskCostRollup.resolve(
            task: task, labourLines: [labour], machineLines: [machine],
            trips: [trip], tripCostAllocations: [allocation], materials: [material],
            includeMaterials: true
        )
        #expect(result.labourCost == 100)
        #expect(result.manualMachineCost == 50)
        #expect(result.linkedTripCost == Decimal(string: "75.25"))
        #expect(result.materialCost == 180)
        #expect(result.totalCost == Decimal(string: "405.25"))
        #expect(result.costPerHectare(areaHectares: 2) == Decimal(string: "202.625"))
    }

    @Test func materialOnlyAndTemporaryGateBehaveConsistently() {
        let task = WorkTask(id: taskID, vineyardId: vineyardA)
        let material = WorkTaskMaterial(
            workTaskId: taskID, vineyardId: vineyardA,
            materialName: "Posts", quantity: 1, unitCost: 180
        )
        let allowed = WorkTaskCostRollup.resolve(
            task: task, labourLines: [], machineLines: [], trips: [],
            tripCostAllocations: [], materials: [material], includeMaterials: true
        )
        let denied = WorkTaskCostRollup.resolve(
            task: task, labourLines: [], machineLines: [], trips: [],
            tripCostAllocations: [], materials: [material], includeMaterials: false
        )
        #expect(allowed.totalCost == 180)
        #expect(denied.totalCost == 0)
    }

    @Test func pieceRateRemainsTheSingleLabourSource() {
        let task = WorkTask(
            id: taskID, vineyardId: vineyardA, costingMethodRaw: "piece_rate",
            pieceRatePerVine: 0.50, pieceVineCount: 200
        )
        let historicalHours = WorkTaskLabourLine(
            workTaskId: taskID, vineyardId: vineyardA,
            workerCount: 10, hoursPerWorker: 10, hourlyRate: 99
        )
        let result = WorkTaskCostRollup.resolve(
            task: task, labourLines: [historicalHours], machineLines: [], trips: [],
            tripCostAllocations: [], materials: [], includeMaterials: true
        )
        #expect(result.labourCost == 100)
        #expect(result.totalCost == 100)
    }

    @Test func unresolvedLabourDoesNotPresentMaterialSubtotalAsComplete() {
        let task = WorkTask(id: taskID, vineyardId: vineyardA)
        let unresolved = WorkTaskLabourLine(
            workTaskId: taskID, vineyardId: vineyardA,
            workerCount: 1, hoursPerWorker: 4, hourlyRate: nil
        )
        let material = WorkTaskMaterial(
            workTaskId: taskID, vineyardId: vineyardA,
            materialName: "Posts", quantity: 1, unitCost: 180
        )
        let result = WorkTaskCostRollup.resolve(
            task: task, labourLines: [unresolved], machineLines: [], trips: [],
            tripCostAllocations: [], materials: [material], includeMaterials: true
        )
        #expect(result.totalCost == 180)
        #expect(!result.isComplete)
        #expect(result.costPerHectare(areaHectares: 1) == nil)
    }

    @Test func workTaskEditorFirstSaveRetainsStableParentAndKeepsEditorOpen() {
        let stableID = UUID()
        var lifecycle = WorkTaskEditorLifecycle()
        #expect(lifecycle.saveTitle == "Save")
        #expect(!lifecycle.childControlsEnabled)
        #expect(!lifecycle.shouldCloseAfterAcceptedSave())

        lifecycle.acceptFirstSave(taskID: stableID)
        #expect(lifecycle.persistedTaskID == stableID)
        #expect(lifecycle.saveTitle == "Save & Close")
        #expect(lifecycle.childControlsEnabled)
        #expect(lifecycle.shouldCloseAfterAcceptedSave())
    }

    @Test func existingWorkTaskEditorStartsInSaveAndCloseMode() {
        let lifecycle = WorkTaskEditorLifecycle(persistedTaskID: taskID)
        #expect(lifecycle.persistedTaskID == taskID)
        #expect(lifecycle.childControlsEnabled)
        #expect(lifecycle.saveTitle == "Save & Close")
    }

    @Test func materialSelectionTransitionsWithinOneFlowState() {
        let entry = MaterialLibrary.merged(
            catalogue: MaterialCatalogueSeed.items,
            vineyardMaterials: [],
            vineyardId: vineyardA
        ).first { $0.baseMaterialKey == "material.trellis.gripple" }!
        var phase = WorkTaskMaterialFlowPhase.selecting
        #expect(phase == .selecting)
        phase = .editing(entry)
        #expect(phase == .editing(entry))
    }

    @Test func offlineParentAndChildrenPersistWithOneStableParentID() throws {
        let persistence = try persistence()
        let parent = WorkTask(id: taskID, vineyardId: vineyardA, taskType: "Wire Lifting")
        let labour = WorkTaskLabourLine(
            workTaskId: taskID, vineyardId: vineyardA,
            workerCount: 2, hoursPerWorker: 4, hourlyRate: 25
        )
        let machine = WorkTaskMachineLine(
            workTaskId: taskID, vineyardId: vineyardA,
            durationHours: 2, totalMachineCost: 80
        )
        let material = WorkTaskMaterial(
            workTaskId: taskID, vineyardId: vineyardA,
            materialName: "Gripple / Wire Joiner-Tensioner",
            quantity: 10, unitCost: Decimal(string: "1.80")!
        )

        WorkTaskRepository(persistence: persistence).saveSlice([parent], for: vineyardA)
        WorkTaskLabourLineRepository(persistence: persistence).saveSlice([labour], for: vineyardA)
        WorkTaskMachineLineRepository(persistence: persistence).saveSlice([machine], for: vineyardA)
        WorkTaskMaterialRepository(persistence: persistence).saveSlice([material], for: vineyardA)

        #expect(WorkTaskRepository(persistence: persistence).load(for: vineyardA).map(\.id) == [taskID])
        #expect(WorkTaskLabourLineRepository(persistence: persistence).load(for: vineyardA).map(\.workTaskId) == [taskID])
        #expect(WorkTaskMachineLineRepository(persistence: persistence).load(for: vineyardA).map(\.workTaskId) == [taskID])
        #expect(WorkTaskMaterialRepository(persistence: persistence).load(forWorkTask: taskID).map(\.workTaskId) == [taskID])
    }
}
