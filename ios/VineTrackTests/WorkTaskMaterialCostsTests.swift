import Foundation
import Testing
@testable import VineTrack

/// WORK TASK MATERIAL COSTS — foundation contract (sql/247).
///
/// The Android twin is `WorkTaskMaterialCostsTest.kt`; both suites assert the
/// SAME fixtures and the SAME stable catalogue keys, so a divergence between
/// the platforms fails a build.
///
/// The rules under test:
///
/// ```text
/// quantity × unitCost = materialTotal          (decimal, money-safe)
/// a task with no material rows                 = $0, no row required
/// a library reprice / retirement               NEVER alters a saved task line
/// a vineyard's custom materials                are invisible to another vineyard
/// a replayed offline create                    upserts the SAME id, never a second line
/// ```
@MainActor
struct WorkTaskMaterialCostsTests {

    // MARK: - Fixtures

    private static let vineyardA = UUID(uuidString: "00000000-0000-0000-0000-00000000aa01")!
    private static let vineyardB = UUID(uuidString: "00000000-0000-0000-0000-00000000aa02")!
    private static let taskOne = UUID(uuidString: "00000000-0000-0000-0000-00000000aa03")!
    private static let taskTwo = UUID(uuidString: "00000000-0000-0000-0000-00000000aa04")!

    /// Isolated on-disk persistence so each test starts from a clean install.
    private func store() throws -> PersistenceStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaterialCostsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return PersistenceStore(directory: url)
    }

    private func gripple() -> MaterialCatalogueItem {
        MaterialCatalogueSeed.items.first { $0.key == "material.trellis.gripple" }!
    }

    // MARK: - 1. Base catalogue

    @Test("Base catalogue seeds the 18 expected entries including Gripple / Wire Joiner-Tensioner")
    func baseCatalogueSeed() {
        let items = MaterialCatalogueSeed.items
        #expect(items.count == 18)

        let gripple = items.first { $0.key == "material.trellis.gripple" }
        #expect(gripple?.name == "Gripple / Wire Joiner-Tensioner")
        #expect(gripple?.category == MaterialCategoryCatalog.trellis)
        #expect(gripple?.defaultUnit == "Each")

        // Every listed item, with the unit the specification requires.
        let expected: [String: String] = [
            "material.trellis.line_post": "Each",
            "material.trellis.end_post": "Each",
            "material.trellis.wire": "Metre",
            "material.trellis.anchor": "Each",
            "material.trellis.gripple": "Each",
            "material.fastener.trellis_clip": "Each",
            "material.fastener.vine_tie": "Each",
            "material.fastener.zip_tie": "Each",
            "material.netting.post_cap": "Each",
            "material.netting.bird_netting": "Metre",
            "material.netting.clip_repair": "Each",
            "material.irrigation.dripline": "Metre",
            "material.irrigation.dripper": "Each",
            "material.irrigation.fitting": "Each",
            "material.establishment.vine_stake": "Each",
            "material.establishment.vine_guard": "Each",
            "material.establishment.vine": "Each",
            "material.other.miscellaneous": "Each",
        ]
        for (key, unit) in expected {
            let item = items.first { $0.key == key }
            #expect(item != nil, "missing catalogue key \(key)")
            #expect(item?.defaultUnit == unit, "wrong default unit for \(key)")
        }

        // The catalogue is deliberately price free — prices belong to a vineyard.
        #expect(items.allSatisfy { !$0.name.contains("$") })
        // Keys are unique: they are the cross-platform identity.
        #expect(Set(items.map(\.key)).count == 18)
    }

    @Test("Standard units are suggestions, not a closed set")
    func standardUnits() {
        #expect(MaterialUnitCatalog.suggested == ["Each", "Metre", "Roll", "Pack", "Box", "Bag"])
        // A future custom unit passes through untouched — no enum, no migration.
        #expect(MaterialUnitCatalog.normalised("Pallet") == "Pallet")
        // A blank unit can never be written (the database rejects it).
        #expect(MaterialUnitCatalog.normalised("   ") == "Each")
        #expect(MaterialUnitCatalog.normalised(nil) == "Each")
    }

    // MARK: - 2. Vineyard isolation

    @Test("Vineyard A custom materials never appear for Vineyard B")
    func customMaterialsAreVineyardScoped() throws {
        let repo = VineyardMaterialRepository(persistence: try store())
        let custom = VineyardMaterial.custom(
            vineyardId: Self.vineyardA,
            name: "Gripple Plus Medium",
            category: MaterialCategoryCatalog.trellis,
            unit: "Each",
            defaultUnitCost: Decimal(string: "2.15")
        )
        repo.saveSlice([custom], for: Self.vineyardA)

        #expect(repo.load(for: Self.vineyardA).count == 1)
        #expect(repo.load(for: Self.vineyardB).isEmpty)

        // And the merged library B sees carries no trace of A's custom item.
        let libraryB = MaterialLibrary.merged(
            catalogue: MaterialCatalogueSeed.items,
            vineyardMaterials: repo.loadAll(),
            vineyardId: Self.vineyardB
        )
        #expect(!libraryB.contains { $0.name == "Gripple Plus Medium" })
        #expect(libraryB.allSatisfy { !$0.isCustom })
        // B still gets the full base catalogue, just with no prices.
        #expect(libraryB.count == 18)
        #expect(libraryB.allSatisfy { $0.defaultUnitCost == nil })
    }

    // MARK: - 3. Default cost on a system material

    @Test("A vineyard can price a system material without creating rows for the rest")
    func vineyardOverridesSystemMaterialCost() {
        var base = gripple()
        base.remoteId = UUID()
        let override = VineyardMaterial.override(
            vineyardId: Self.vineyardA,
            base: base,
            defaultUnitCost: Decimal(string: "1.82")
        )
        #expect(override != nil)

        var catalogue = MaterialCatalogueSeed.items
        if let idx = catalogue.firstIndex(where: { $0.key == base.key }) { catalogue[idx] = base }

        let library = MaterialLibrary.merged(
            catalogue: catalogue,
            vineyardMaterials: [override!],
            vineyardId: Self.vineyardA
        )
        // Still 18 selectable entries: pricing one item does NOT create 18 rows.
        #expect(library.count == 18)

        let priced = library.first { $0.baseMaterialKey == "material.trellis.gripple" }
        #expect(priced?.name == "Gripple / Wire Joiner-Tensioner")
        #expect(priced?.defaultUnitCost == Decimal(string: "1.82"))
        #expect(priced?.unit == "Each")
        #expect(priced?.isCustom == false)
        // Every other base item remains unpriced rather than defaulting to zero.
        #expect(library.filter { $0.defaultUnitCost != nil }.count == 1)
    }

    @Test("An override keeps its link to the base catalogue item")
    func overrideRetainsBaseRelationship() {
        var base = gripple()
        let remoteId = UUID()
        base.remoteId = remoteId
        let override = VineyardMaterial.override(
            vineyardId: Self.vineyardA,
            base: base,
            defaultUnitCost: Decimal(string: "1.82")
        )
        #expect(override?.baseMaterialId == remoteId)
        #expect(override?.baseMaterialKey == "material.trellis.gripple")
        #expect(override?.isCustom == false)

        // Without a synced server id there is no valid override: the database's
        // custom-shape check requires a real base_material_id.
        #expect(VineyardMaterial.override(
            vineyardId: Self.vineyardA,
            base: gripple(),
            defaultUnitCost: Decimal(string: "1.82")
        ) == nil)
    }

    // MARK: - 4. Custom vineyard material

    @Test("A vineyard can create a reusable custom material with its own unit and cost")
    func customVineyardMaterial() {
        let custom = VineyardMaterial.custom(
            vineyardId: Self.vineyardA,
            name: "2.4 m Eco Trellis Post",
            category: MaterialCategoryCatalog.trellis,
            unit: "Each",
            defaultUnitCost: Decimal(string: "14.80")
        )
        #expect(custom.isCustom)
        #expect(custom.baseMaterialId == nil)
        #expect(custom.baseMaterialKey == nil)
        #expect(custom.defaultUnitCost == Decimal(string: "14.80"))

        let library = MaterialLibrary.merged(
            catalogue: MaterialCatalogueSeed.items,
            vineyardMaterials: [custom],
            vineyardId: Self.vineyardA
        )
        #expect(library.count == 19)
        let entry = library.first { $0.name == "2.4 m Eco Trellis Post" }
        #expect(entry?.isCustom == true)
        #expect(entry?.defaultUnitCost == Decimal(string: "14.80"))
        #expect(entry?.vineyardMaterialId == custom.id)
    }

    // MARK: - 5 & 6. Multiple lines, decimal quantities

    @Test("A task holds multiple material lines and decimal quantities cost exactly")
    func multipleLinesAndDecimalQuantities() {
        let posts = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            materialName: "Line / Trellis Post", category: MaterialCategoryCatalog.trellis,
            unit: "Each", quantity: 3, unitCost: Decimal(string: "12.40")!
        )
        let wire = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            materialName: "Trellis Wire", category: MaterialCategoryCatalog.trellis,
            unit: "Metre", quantity: Decimal(string: "42.5")!, unitCost: Decimal(string: "0.31")!
        )
        let netting = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            materialName: "Bird Netting", category: MaterialCategoryCatalog.netting,
            unit: "Roll", quantity: Decimal(string: "0.5")!, unitCost: Decimal(string: "245.00")!
        )

        // The worked example: 3 × $12.40 = $37.20 (not 37.199999...).
        #expect(posts.totalCost == Decimal(string: "37.20"))
        // 42.5 m × $0.31 = $13.175 → $13.18 half-up, matching the generated column.
        #expect(wire.totalCost == Decimal(string: "13.18"))
        // 0.5 roll × $245.00 = $122.50.
        #expect(netting.totalCost == Decimal(string: "122.50"))

        let lines = [posts, wire, netting]
        #expect(WorkTaskMaterialCosting.total(lines, for: Self.taskOne) == Decimal(string: "172.88"))
        #expect(WorkTaskMaterialCosting.lines(lines, for: Self.taskOne).count == 3)

        // Category roll-up uses each line's FROZEN category.
        let byCategory = WorkTaskMaterialCosting.totalByCategory(lines)
        #expect(byCategory[MaterialCategoryCatalog.trellis] == Decimal(string: "50.38"))
        #expect(byCategory[MaterialCategoryCatalog.netting] == Decimal(string: "122.50"))
    }

    @Test("A task with no material lines costs zero without needing a row")
    func taskWithoutMaterialsCostsNothing() {
        #expect(WorkTaskMaterialCosting.total([], for: Self.taskOne) == 0)
        // Another task's lines never leak into this one's total.
        let otherTaskLine = WorkTaskMaterial(
            workTaskId: Self.taskTwo, vineyardId: Self.vineyardA,
            materialName: "Vine Stake", unit: "Each", quantity: 10, unitCost: 3
        )
        #expect(WorkTaskMaterialCosting.total([otherTaskLine], for: Self.taskOne) == 0)
        #expect(WorkTaskMaterialCosting.lines([otherTaskLine], for: Self.taskOne).isEmpty)
    }

    // MARK: - 7. Historical snapshot survives a reprice

    @Test("Repricing the library never changes an existing Work Task snapshot")
    func repricingDoesNotRewriteHistory() throws {
        let persistence = try store()
        let libraryRepo = VineyardMaterialRepository(persistence: persistence)
        let taskRepo = WorkTaskMaterialRepository(persistence: persistence)

        var base = MaterialCatalogueSeed.items.first { $0.key == "material.trellis.line_post" }!
        base.remoteId = UUID()
        var libraryItem = VineyardMaterial.override(
            vineyardId: Self.vineyardA, base: base, defaultUnitCost: Decimal(string: "12.40")
        )!
        libraryRepo.saveSlice([libraryItem], for: Self.vineyardA)

        var catalogue = MaterialCatalogueSeed.items
        catalogue[catalogue.firstIndex { $0.key == base.key }!] = base
        let entry = MaterialLibrary.merged(
            catalogue: catalogue, vineyardMaterials: [libraryItem], vineyardId: Self.vineyardA
        ).first { $0.baseMaterialKey == base.key }!

        // Today: 3 posts at $12.40 = $37.20.
        let line = entry.makeTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA, quantity: 3
        )
        taskRepo.saveSlice([line], for: Self.vineyardA)
        #expect(line.unitCost == Decimal(string: "12.40"))
        #expect(line.totalCost == Decimal(string: "37.20"))

        // Next season the vineyard raises its standard post price.
        libraryItem.defaultUnitCost = Decimal(string: "14.50")
        libraryRepo.saveSlice([libraryItem], for: Self.vineyardA)

        // The historical task is untouched — still $12.40 and still $37.20.
        let reloaded = taskRepo.load(forWorkTask: Self.taskOne)
        #expect(reloaded.count == 1)
        #expect(reloaded[0].unitCost == Decimal(string: "12.40"))
        #expect(reloaded[0].totalCost == Decimal(string: "37.20"))
        #expect(reloaded[0].materialName == "Line / Trellis Post")

        // A NEW line added after the change picks up the new default.
        let newEntry = MaterialLibrary.merged(
            catalogue: catalogue, vineyardMaterials: [libraryItem], vineyardId: Self.vineyardA
        ).first { $0.baseMaterialKey == base.key }!
        let newLine = newEntry.makeTaskMaterial(
            workTaskId: Self.taskTwo, vineyardId: Self.vineyardA, quantity: 3
        )
        #expect(newLine.unitCost == Decimal(string: "14.50"))
    }

    @Test("A task line's quantity and unit cost can be changed without touching the library")
    func editingALineNeverEditsTheLibrary() {
        var base = gripple()
        base.remoteId = UUID()
        let libraryItem = VineyardMaterial.override(
            vineyardId: Self.vineyardA, base: base, defaultUnitCost: Decimal(string: "1.82")
        )!
        var catalogue = MaterialCatalogueSeed.items
        catalogue[catalogue.firstIndex { $0.key == base.key }!] = base
        let entry = MaterialLibrary.merged(
            catalogue: catalogue, vineyardMaterials: [libraryItem], vineyardId: Self.vineyardA
        ).first { $0.baseMaterialKey == base.key }!

        // This task got a different price and a different unit.
        var line = entry.makeTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            quantity: 25, unitCost: Decimal(string: "2.05"), unit: "Pack"
        )
        line.quantity = 30
        #expect(line.unitCost == Decimal(string: "2.05"))
        #expect(line.unit == "Pack")
        #expect(line.totalCost == Decimal(string: "61.50"))
        // The library defaults are unchanged.
        #expect(libraryItem.defaultUnitCost == Decimal(string: "1.82"))
        #expect(libraryItem.unit == "Each")
    }

    // MARK: - 8. Deactivation preserves history

    @Test("Deactivating a library material removes it from selection but not from history")
    func deactivationPreservesHistoricalUsage() throws {
        let persistence = try store()
        let libraryRepo = VineyardMaterialRepository(persistence: persistence)
        let taskRepo = WorkTaskMaterialRepository(persistence: persistence)

        var custom = VineyardMaterial.custom(
            vineyardId: Self.vineyardA, name: "Gripple Plus Medium",
            category: MaterialCategoryCatalog.trellis, unit: "Each",
            defaultUnitCost: Decimal(string: "2.15")
        )
        libraryRepo.saveSlice([custom], for: Self.vineyardA)

        let line = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            vineyardMaterialId: custom.id,
            materialName: "Gripple Plus Medium", category: MaterialCategoryCatalog.trellis,
            unit: "Each", quantity: 40, unitCost: Decimal(string: "2.15")!
        )
        taskRepo.saveSlice([line], for: Self.vineyardA)

        // Retire it.
        custom.isActive = false
        libraryRepo.saveSlice([custom], for: Self.vineyardA)

        // Gone from the picker…
        let library = MaterialLibrary.merged(
            catalogue: MaterialCatalogueSeed.items,
            vineyardMaterials: libraryRepo.load(for: Self.vineyardA),
            vineyardId: Self.vineyardA
        )
        #expect(!library.contains { $0.name == "Gripple Plus Medium" })

        // …but the historical task is intact and still costs the same.
        let history = taskRepo.load(forWorkTask: Self.taskOne)
        #expect(history.count == 1)
        #expect(history[0].materialName == "Gripple Plus Medium")
        #expect(history[0].totalCost == Decimal(string: "86.00"))
    }

    @Test("Removing the library row entirely still leaves the task line readable")
    func removedLibraryRowLeavesHistoryReadable() throws {
        let persistence = try store()
        let libraryRepo = VineyardMaterialRepository(persistence: persistence)
        let taskRepo = WorkTaskMaterialRepository(persistence: persistence)

        let custom = VineyardMaterial.custom(
            vineyardId: Self.vineyardA, name: "Retired Post Type",
            unit: "Each", defaultUnitCost: Decimal(string: "9.00")
        )
        libraryRepo.saveSlice([custom], for: Self.vineyardA)

        // Provenance is deliberately nullable — the database sets it null on
        // delete and the line must still read from its own snapshot.
        let line = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            vineyardMaterialId: nil,
            materialName: "Retired Post Type", unit: "Each",
            quantity: 5, unitCost: Decimal(string: "9.00")!
        )
        taskRepo.saveSlice([line], for: Self.vineyardA)
        libraryRepo.saveSlice([], for: Self.vineyardA)

        let history = taskRepo.load(forWorkTask: Self.taskOne)
        #expect(history.count == 1)
        #expect(history[0].materialName == "Retired Post Type")
        #expect(history[0].totalCost == Decimal(string: "45.00"))
    }

    // MARK: - 9 & 10. Offline durability and replay idempotency

    @Test("An offline-created material line survives restart and keeps its id")
    func offlineLineSurvivesRestart() throws {
        let persistence = try store()
        let created = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            materialName: "Dripper / Emitter", category: MaterialCategoryCatalog.irrigation,
            unit: "Each", quantity: 12, unitCost: Decimal(string: "0.85")!
        )
        WorkTaskMaterialRepository(persistence: persistence)
            .saveSlice([created], for: Self.vineyardA)

        // Relaunch: a brand-new repository over the same storage.
        let afterRestart = WorkTaskMaterialRepository(persistence: persistence)
            .load(forWorkTask: Self.taskOne)
        #expect(afterRestart.count == 1)
        #expect(afterRestart[0].id == created.id, "the id must be stable across restart")
        #expect(afterRestart[0].totalCost == Decimal(string: "10.20"))
    }

    @Test("Replaying the same offline create merges into one row, never two")
    func replayDoesNotDuplicate() throws {
        let repo = WorkTaskMaterialRepository(persistence: try store())
        let created = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            materialName: "Vine Guard", category: MaterialCategoryCatalog.establishment,
            unit: "Each", quantity: 20, unitCost: Decimal(string: "1.10")!
        )
        repo.saveSlice([created], for: Self.vineyardA)

        // The server echoes the SAME id back (the upsert is keyed on it).
        let serverEcho = BackendWorkTaskMaterial.upsert(
            from: created, createdBy: nil, updatedBy: nil, clientUpdatedAt: Date()
        )
        #expect(serverEcho.id == created.id)

        // Merge it twice — a retried replay plus the following pull.
        _ = repo.merge([created], for: Self.vineyardA)
        _ = repo.merge([created], for: Self.vineyardA)

        let lines = repo.load(forWorkTask: Self.taskOne)
        #expect(lines.count == 1, "a replay must never create a second material line")
        #expect(WorkTaskMaterialCosting.total(lines, for: Self.taskOne) == Decimal(string: "22.00"))
    }

    @Test("The upsert payload omits the generated total and clamps negatives")
    func upsertPayloadShape() throws {
        let line = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            materialName: "  Trellis Wire  ", unit: "Metre",
            quantity: Decimal(string: "-5")!, unitCost: Decimal(string: "-1")!
        )
        let payload = BackendWorkTaskMaterial.upsert(
            from: line, createdBy: nil, updatedBy: nil, clientUpdatedAt: Date()
        )
        #expect(payload.materialName == "Trellis Wire")
        #expect(payload.quantity == 0)
        #expect(payload.unitCost == 0)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try JSONSerialization.jsonObject(
            with: try encoder.encode(payload)
        ) as? [String: Any]
        // total_cost is GENERATED ALWAYS — sending it would be rejected.
        #expect(json?["total_cost"] == nil)
        #expect(json?["quantity"] != nil)
        #expect(json?["unit_cost"] != nil)
    }

    // MARK: - 11. Cross-platform interpretation

    @Test("A backend row decodes to the same values Android reads")
    func backendRowDecodesConsistently() throws {
        let raw = """
        {
          "id": "00000000-0000-0000-0000-00000000aa05",
          "work_task_id": "00000000-0000-0000-0000-00000000aa03",
          "vineyard_id": "00000000-0000-0000-0000-00000000aa01",
          "base_material_id": null,
          "vineyard_material_id": null,
          "material_name": "Trellis Wire",
          "category": "Trellis",
          "unit": "Metre",
          "quantity": 42.5,
          "unit_cost": 0.31,
          "total_cost": 13.18,
          "notes": "",
          "deleted_at": null
        }
        """
        let decoded = try JSONDecoder().decode(
            BackendWorkTaskMaterial.self, from: Data(raw.utf8)
        )
        let domain = decoded.toWorkTaskMaterial()
        #expect(domain.materialName == "Trellis Wire")
        #expect(domain.unit == "Metre")
        #expect(domain.quantity == Decimal(string: "42.5"))
        #expect(domain.unitCost == Decimal(string: "0.31"))
        // Locally recomputed total matches the server's generated column.
        #expect(domain.totalCost == Decimal(string: "13.18"))
        #expect(decoded.totalCost == Decimal(string: "13.18"))
    }

    @Test("The catalogue keys iOS ships are exactly the keys sql/247 seeds")
    func catalogueKeyParity() {
        // This list is duplicated verbatim in the Android suite and in the
        // migration's seed block. All three must agree.
        let shared = [
            "material.trellis.line_post", "material.trellis.end_post",
            "material.trellis.wire", "material.trellis.anchor", "material.trellis.gripple",
            "material.fastener.trellis_clip", "material.fastener.vine_tie",
            "material.fastener.zip_tie",
            "material.netting.post_cap", "material.netting.bird_netting",
            "material.netting.clip_repair",
            "material.irrigation.dripline", "material.irrigation.dripper",
            "material.irrigation.fitting",
            "material.establishment.vine_stake", "material.establishment.vine_guard",
            "material.establishment.vine",
            "material.other.miscellaneous",
        ]
        #expect(MaterialCatalogueSeed.keys.sorted() == shared.sorted())
    }

    // MARK: - 11b. Offline catalogue availability

    @Test("The base catalogue is available offline and a synced server copy wins")
    func catalogueOfflineResolution() throws {
        let repo = MaterialCatalogueRepository(persistence: try store())
        // Fresh offline install: the bundled catalogue is used.
        #expect(repo.loadCached() == nil)
        #expect(repo.loadEffective().count == 18)

        // A synced server copy becomes authoritative, carrying real row ids.
        var server = MaterialCatalogueSeed.items
        for index in server.indices { server[index].remoteId = UUID() }
        repo.replace(server)
        #expect(repo.loadEffective().allSatisfy { $0.remoteId != nil })

        // An empty read is refused rather than blanking every picker.
        repo.replace([])
        #expect(repo.loadEffective().count == 18)
    }

    // MARK: - 12 & 13. Work Task access

    @Test("A permitted vineyard member can enter Work Task Material Costs")
    func vineyardMemberCanAccess() {
        let access = WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true,
            isResolving: false,
            selectedVineyardID: Self.vineyardA,
            isMemberOfSelectedVineyard: true
        )
        #expect(access == .allowed)
        #expect(access.isAllowed)
    }

    @Test("A normal permitted Work Task user can use Materials without System Admin status")
    func normalWorkTaskUserCanAccess() {
        let member = WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true, isResolving: false,
            selectedVineyardID: Self.vineyardA, isMemberOfSelectedVineyard: true
        )
        #expect(member == .allowed)
        #expect(member.isAllowed)
    }

    @Test("The gate fails closed while resolving, signed out, or outside a vineyard")
    func gateFailsClosed() {
        // Still resolving — denied, so nothing flashes into view at launch.
        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true, isResolving: true,
            selectedVineyardID: Self.vineyardA, isMemberOfSelectedVineyard: true
        ) == .unavailable(.stillResolving))

        // Signed out.
        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: false, isResolving: false,
            selectedVineyardID: Self.vineyardA, isMemberOfSelectedVineyard: true
        ) == .unavailable(.notAuthenticated))

        // Vineyard tenancy still applies.
        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true, isResolving: false,
            selectedVineyardID: Self.vineyardA, isMemberOfSelectedVineyard: false
        ) == .unavailable(.notVineyardMember))

        #expect(WorkTaskMaterialCostsAccess.resolve(
            isAuthenticated: true, isResolving: false,
            selectedVineyardID: nil, isMemberOfSelectedVineyard: true
        ) == .unavailable(.notVineyardMember))
    }

    // MARK: - 16 & 17. Additive, with unchanged storage

    @Test("Material Costs is additive — existing Work Task behaviour is untouched")
    func existingWorkTaskBehaviourUnchanged() {
        // A task built exactly as before carries no material state and costs
        // what it always did.
        var task = WorkTask(vineyardId: Self.vineyardA, taskType: "Wire Lifting", durationHours: 4)
        task.resources = [WorkTaskResource(workerTypeName: "Casual", hourlyRate: 32, count: 2)]
        #expect(task.totalCost == 256)
        #expect(task.costingMethod == .hourly)
        #expect(!task.isPieceRate)

        // Materials are never mandatory: no row means no cost, and the labour
        // total is completely unaffected by the material total.
        #expect(WorkTaskMaterialCosting.total([], for: task.id) == 0)
        #expect(task.totalCost == 256)
    }

    @Test("Removing the gate needs no change to models, storage or the wire format")
    func gateIsIsolatedFromTheDataLayer() throws {
        // The data layer is exercised with NO admin input anywhere: if any of
        // these required an `isSystemAdmin` argument, this test would not compile.
        let persistence = try store()
        let taskRepo = WorkTaskMaterialRepository(persistence: persistence)
        let libraryRepo = VineyardMaterialRepository(persistence: persistence)
        let catalogueRepo = MaterialCatalogueRepository(persistence: persistence)

        let custom = VineyardMaterial.custom(
            vineyardId: Self.vineyardA, name: "Zip Tie 300mm", unit: "Pack",
            defaultUnitCost: Decimal(string: "8.40")
        )
        libraryRepo.saveSlice([custom], for: Self.vineyardA)
        let line = WorkTaskMaterial(
            workTaskId: Self.taskOne, vineyardId: Self.vineyardA,
            vineyardMaterialId: custom.id, materialName: "Zip Tie 300mm",
            unit: "Pack", quantity: 2, unitCost: Decimal(string: "8.40")!
        )
        taskRepo.saveSlice([line], for: Self.vineyardA)

        #expect(catalogueRepo.loadEffective().count == 18)
        #expect(taskRepo.load(forWorkTask: Self.taskOne).count == 1)
        #expect(WorkTaskMaterialCosting.total(taskRepo.loadAll(), for: Self.taskOne)
                == Decimal(string: "16.80"))

        // And the wire payloads carry no admin concept either.
        let taskPayload = BackendWorkTaskMaterial.upsert(
            from: line, createdBy: nil, updatedBy: nil, clientUpdatedAt: Date()
        )
        let libraryPayload = BackendVineyardMaterial.upsert(
            from: custom, createdBy: nil, updatedBy: nil, clientUpdatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let taskKeys = Set((try JSONSerialization.jsonObject(
            with: try encoder.encode(taskPayload)) as? [String: Any] ?? [:]).keys)
        let libraryKeys = Set((try JSONSerialization.jsonObject(
            with: try encoder.encode(libraryPayload)) as? [String: Any] ?? [:]).keys)
        #expect(!taskKeys.contains { $0.localizedCaseInsensitiveContains("admin") })
        #expect(!libraryKeys.contains { $0.localizedCaseInsensitiveContains("admin") })
        // A custom library row must send NO base id (database check constraint).
        #expect(libraryPayload.baseMaterialId == nil)
        #expect(libraryPayload.isCustom)
    }
}
