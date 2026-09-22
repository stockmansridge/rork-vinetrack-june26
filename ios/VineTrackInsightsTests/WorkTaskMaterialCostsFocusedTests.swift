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

    @Test func temporaryGateAllowsOnlyAuthenticatedSystemAdminVineyardMembers() {
        #expect(WorkTaskMaterialCostsAccess.isTemporarySystemAdminGateActive)
        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true,
            isResolving: false,
            isSystemAdmin: true,
            selectedVineyardID: vineyardA,
            isMemberOfSelectedVineyard: true
        ) == .allowed)
        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true,
            isResolving: false,
            isSystemAdmin: false,
            selectedVineyardID: vineyardA,
            isMemberOfSelectedVineyard: true
        ) == .unavailable(.notSystemAdmin))
        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true,
            isResolving: false,
            isSystemAdmin: true,
            selectedVineyardID: vineyardA,
            isMemberOfSelectedVineyard: false
        ) == .unavailable(.notVineyardMember))
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
}
