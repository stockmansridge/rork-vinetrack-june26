import Foundation
import Testing
@testable import VineTrack

@MainActor struct CatalogueCutoverTests {
    private func row(_ json: String) throws -> CatalogueWire { try JSONDecoder().decode(CatalogueWire.self, from: Data(json.utf8)) }
    @Test func fuzzyStifleAndWeedmasterAreBackendRows() throws {
        let stifle = try row(#"{"revision_id":"approved-stifle","product_name":"STIFLE™ DORMANT SPRAY OIL","manufacturer":"SACOA Pty Ltd","review_status":"approved"}"#)
        #expect(stifle.text("product_name") == "STIFLE™ DORMANT SPRAY OIL")
        #expect(stifle.badge == "VineTrack catalogue")
        #expect(CatalogueWire.compactManufacturer(stifle.text("manufacturer")!) == "SACOA")
        let weedmaster = try row(#"{"revision_id":"approved-weedmaster","product_name":"Weedmaster DUO","review_status":"approved"}"#)
        #expect(weedmaster.badge == stifle.badge)
    }
    @Test(arguments: ["text", "photo"])
    func completedCatalogueMatchIsSuccess(_ kind: String) throws {
        let job = try row(#"{"id":"same-job","status":"completed","stage":"catalogue_match","revision_id":"approved-stifle","product_id":"existing-stifle"}"#)
        #expect(job.isSuccess && job.isTerminal)
        #expect(job.text("revision_id") == "approved-stifle")
        let saved = CatalogueDiscoveryContext(jobId: "same-job", userId: "user", vineyardId: UUID(), query: "socoa stifle", country: "AU", inputKind: kind, photoPath: kind == "photo" ? "search-inputs/user/input.jpg" : nil, startedAt: Date())
        let reopened = try JSONDecoder().decode(CatalogueDiscoveryContext.self, from: JSONEncoder().encode(saved))
        #expect(reopened.jobId == saved.jobId)
        #expect(reopened.inputKind == kind)
    }
    @Test(arguments: ["pending_review", "needs_attention"])
    func candidatesUseCustomerSafeWording(_ status: String) throws {
        #expect(try row("{\"status\":\"\(status)\"}").isSuccess)
        #expect(try row("{\"review_status\":\"\(status)\"}").badge == "Pending VineTrack review")
    }
    @Test func usedForAndBackendResistance() throws {
        let product = try row(#"{"activity_group_scheme":"frac","activity_groups":["3"],"vineyard_uses":[{"targets":["Powdery mildew","Downy mildew","Eutypa dieback"]},{"targets":["powdery mildew"]}]}"#)
        #expect(product.targets == ["Powdery mildew", "Downy mildew", "Eutypa dieback"])
        #expect(product.groupText == "FRAC 3")
        #expect(product.targets.joined(separator: " ").localizedStandardContains("powdery"))
    }
    @Test func openingDefaultsRespectPhysicalOverrideAndFinishedStatus() throws {
        #expect(CatalogueInventoryContainer.openingQuantity(count: "1", size: "20", physical: "", edited: false) == "20")
        #expect(CatalogueInventoryContainer.openingQuantity(count: "2", size: "20", physical: "20", edited: false) == "40")
        #expect(CatalogueInventoryContainer.openingQuantity(count: "2", size: "20", physical: "12", edited: true) == "12")
        #expect(try row(#"{"tracking_status":"finished","out_of_stock":true}"#).inventoryStatus == "Finished")
        #expect(try row(#"{"tracking_status":"needs_opening_stock","out_of_stock":true}"#).inventoryStatus == "Opening stock not set")
        #expect(try row(#"{"tracking_status":"low_stock"}"#).inventoryStatus == "Low stock")
    }
    @Test func inventoryContainersKeepPhysicalStockSeparate() throws {
        let fields = CatalogueInventoryContainer.fields(count: 1, size: 20, unit: "L")
        let stock = CatalogueInventoryContainer.stockFields(quantity: 12, unit: "L")
        #expect(fields["p_container_size"] == .number(20))
        #expect(fields["p_container_count"] == .number(1))
        #expect(stock["p_current_quantity"] == .number(12))
        #expect(stock["p_current_unit"] == .string("L"))
        #expect(fields["p_quantity"] == nil && fields["p_percent_remaining"] == nil)
        #expect(try row(#"{"current_quantity":12,"percent_remaining":60}"#).number("percent_remaining") == 60)
        #expect(CatalogueInventoryContainer.preview(count: 2, size: 20, unit: "L") == "2 × 20 L = 40 L total")
        #expect(CatalogueInventoryContainer.units(form: "solid", packUnit: "") == ["kg", "g"])
        #expect(CatalogueInventoryContainer.units(form: "liquid", packUnit: "") == ["L", "mL"])
        #expect(CatalogueInventoryContainer.units(form: "", packUnit: "g") == ["kg", "g"])
        #expect(!CatalogueInventoryContainer.valid(count: 1.5, size: 20))
        #expect(!CatalogueInventoryContainer.valid(count: 1, size: 0))
    }
    @Test func inventoryV2HistoryAndLegacyFallback() throws {
        let modern = try row(#"{"container_count":2,"container_size":20,"container_unit":"L","quantity":40,"unit":"L"}"#)
        #expect(CatalogueInventoryContainer.historyText(modern) == "2 × 20 L · 40 L total")
        let legacy = try row(#"{"container_count":null,"quantity":8,"unit":"kg"}"#)
        #expect(CatalogueInventoryContainer.historyText(legacy) == "8 kg total")
        #expect(CatalogueInventoryMutation.history == "chemical_inventory_purchase_history_v2")
    }
    @Test func inventoryV2AdminGateAndCompatibility() async throws {
        let id = UUID(); var writes = 0; var refreshed: [UUID] = []
        for operation in [CatalogueInventoryMutation.purchase, CatalogueInventoryMutation.stocktake] {
            do { try await CatalogueInventoryMutation.perform(systemAdmin: false, operation: operation, chemicalId: id, mutate: { writes += 1 }, refresh: { refreshed.append($0) }) } catch { }
            #expect(writes == 0 && refreshed.isEmpty)
        }
        try await CatalogueInventoryMutation.perform(systemAdmin: true, operation: CatalogueInventoryMutation.purchase, chemicalId: id, mutate: { writes += 1 }, refresh: { refreshed.append($0) })
        #expect(writes == 1 && refreshed == [id])
        #expect(CatalogueInventoryMutation.operations.contains("chemical_inventory_record_purchase"))
        #expect(CatalogueInventoryMutation.operations.contains("chemical_inventory_record_stocktake"))
    }
    @Test func inventoryUnknownIsNotZeroAndUsesServedValue() throws {
        let unknown = try row(#"{"tracking_status":"needs_opening_stock","current_quantity":null,"estimated_stock_value":null,"out_of_stock":false}"#)
        #expect(unknown.inventoryStatus == "Opening stock not set")
        #expect(unknown.number("current_quantity") == nil)
        #expect(unknown.number("estimated_stock_value") == nil)
        let known = try row(#"{"current_quantity":10,"estimated_stock_value":123.45,"percent_remaining":30}"#)
        #expect(known.number("estimated_stock_value") == 123.45)
        #expect(known.number("percent_remaining") == 30)
    }
    @Test func exactSavedIdentityAndRevisionSurviveLocalCache() throws {
        let id = UUID(); let revision = UUID(); let vineyard = UUID()
        let json = "{\"id\":\"\(id)\",\"vineyard_id\":\"\(vineyard)\",\"chemical_v3_revision_id\":\"\(revision)\",\"name\":\"Belanty\",\"rates\":{\"per_hectare\":[]}}"
        let saved = try JSONDecoder().decode(BackendSavedChemical.self, from: Data(json.utf8)).toSavedChemical()
        #expect(saved.id == id); #expect(saved.chemicalV3RevisionId == revision)
        let reopened = try JSONDecoder().decode(SavedChemical.self, from: JSONEncoder().encode(saved))
        #expect(reopened.id == id); #expect(reopened.chemicalV3RevisionId == revision)
    }
    @Test func catalogueSearchDoesNotInvokeDiscovery() async {
        let backend = CatalogueFixtureBackend()
        let model = CatalogueSearchModel(repository: backend)
        model.query = "socoa stifle"
        await model.search(country: "AU")
        #expect(model.matches.first?.text("product_name") == "STIFLE™ DORMANT SPRAY OIL")
        #expect(model.searched && !model.matches.isEmpty)
        #expect(backend.started == 0)
        backend.emptySearch = true
        await model.search(country: "AU")
        #expect(model.searched && model.matches.isEmpty)
        #expect(backend.started == 0)
    }
    @Test(arguments: [false, true])
    func resumeUsesExactRevisionWithoutNewDiscovery(_ failFetch: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let vineyard = UUID()
        let context = CatalogueDiscoveryContext(jobId: "same-job", userId: "user", vineyardId: vineyard, query: "socoa stifle", country: "AU", inputKind: "photo", photoPath: "search-inputs/user/input.jpg", startedAt: Date())
        try persistence.saveOrThrow(context, key: "chemical_catalogue_discovery_user_\(vineyard)")
        let backend = CatalogueFixtureBackend(); backend.failRevision = failFetch
        let model = CatalogueSearchModel(persistence: persistence, repository: backend)
        model.restore(vineyard: vineyard, user: "user")
        for _ in 0..<100 where model.result == nil && model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(backend.fetched == ["approved-stifle"])
        #expect(backend.started == 0)
        let retained: CatalogueDiscoveryContext? = persistence.load(key: "chemical_catalogue_discovery_user_\(vineyard)")
        if failFetch { #expect(retained?.jobId == "same-job"); #expect(model.result == nil) }
        else {
            #expect(model.result?.badge == "VineTrack catalogue"); #expect(retained == nil)
            let reopened = CatalogueSearchModel(persistence: persistence, repository: backend)
            reopened.restore(vineyard: vineyard, user: "user")
            #expect(reopened.result?.id == "approved-stifle")
        }
    }
    @Test func inventoryAccessAndLinkedRevisionFixtures() throws {
        #expect(CatalogueTerminalResolver.inventoryAllowed(systemAdmin: true))
        #expect(!CatalogueTerminalResolver.inventoryAllowed(systemAdmin: false))
        for (name, targets) in [("Belanty", ["Powdery mildew"]), ("Greenshield", ["Black spot", "Downy mildew", "Phomopsis Cane and Leaf spot"]), ("Sprayseal", ["Eutypa dieback", "Botryosphaeria dieback"]), ("THIOVIT", ["Powdery mildew", "Bud mite"])] {
            let revision = CatalogueWire(fields: ["product_name": .string(name), "front_label_image_path": .string("labels/\(name).jpg"), "vineyard_uses": .array([.object(["targets": .array(targets.map { .string($0) })])])])
            #expect(revision.targets == targets)
            #expect(revision.text("front_label_image_path") == "labels/\(name).jpg")
        }
    }
    @Test func inventoryMutationRefreshesOnlyAffectedSummary() async throws {
        let id = UUID(); var mutated = false; var refreshed: [UUID] = []
        try await CatalogueInventoryMutation.perform(systemAdmin: true, operation: "chemical_inventory_record_stocktake", chemicalId: id,
            mutate: { mutated = true }, refresh: { refreshed.append($0) })
        #expect(mutated); #expect(refreshed == [id])
        mutated = false; refreshed = []
        do {
            try await CatalogueInventoryMutation.perform(systemAdmin: false, operation: "chemical_inventory_record_purchase", chemicalId: id,
                mutate: { mutated = true }, refresh: { refreshed.append($0) })
        } catch { }
        #expect(!mutated && refreshed.isEmpty)
    }
    @Test func savedIDHandoffPreservesExistingSprayRecordAndTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID(); store.selectedVineyardId = vineyard
        let trip = Trip(vineyardId: vineyard, isActive: true)
        store.trips = [trip]
        let spray = SprayRecord(tripId: trip.id, vineyardId: vineyard, temperature: 18, sprayReference: "Keep draft", tanks: [SprayTank(waterVolume: 1000)], notes: "Keep blocks and weather")
        store.sprayRecords = [spray]
        let backend = CatalogueFixtureBackend()
        let model = CatalogueSearchModel(persistence: persistence, repository: backend)
        model.result = CatalogueWire(fields: ["id": .string("approved-stifle"), "review_status": .string("approved")])
        let saved = try await model.add(vineyard: vineyard, store: store)
        #expect(saved.id == backend.savedId)
        #expect(store.savedChemicals.first?.id == backend.savedId)
        #expect(store.sprayRecords == [spray]); #expect(store.trips == [trip])
    }
    @Test(arguments: ["failed", "cancelled"])
    func unsuccessfulDiscoveryNeverResolvesAnOldRevision(_ status: String) async throws {
        let job = try row("{\"status\":\"\(status)\",\"revision_id\":\"old-revision\"}")
        var fetched = false
        do { _ = try await CatalogueTerminalResolver.result(job: job, fetch: { _ in fetched = true; return job }); Issue.record("Failed job must not produce a result") } catch { }
        #expect(job.isTerminal && !job.isSuccess && !fetched)
    }
    @Test func ratesRemainSeparate() throws {
        let product = try row(#"{"default_rate_options":{"per_hectare":[{"value":2,"unit":"L"}],"per_100_litres":[{"min_value":150,"max_value":200,"unit":"g"}]}}"#)
        #expect(product.rateRows("per_hectare").first?.number("value") == 2)
        #expect(product.rateRows("per_100_litres").first?.number("min_value") == 150)
        #expect(product.rateRows("per_100_litres").first?.number("max_value") == 200)
    }
}

@MainActor private final class CatalogueFixtureBackend: CatalogueBackendProtocol {
    var fetched: [String] = []
    var started: Int = 0
    var failRevision: Bool = false
    var emptySearch: Bool = false
    let savedId: UUID = UUID()
    func search(query: String, country: String) async throws -> [CatalogueWire] {
        emptySearch ? [] : [CatalogueWire(fields: ["revision_id": .string("approved-stifle"), "product_name": .string("STIFLE™ DORMANT SPRAY OIL"), "manufacturer": .string("SACOA Pty Ltd"), "review_status": .string("approved")])]
    }
    func revision(_ id: String) async throws -> CatalogueWire {
        fetched.append(id)
        if failRevision { throw URLError(.notConnectedToInternet) }
        return CatalogueWire(fields: ["id": .string(id), "review_status": .string("approved")])
    }
    func job(_ id: String) async throws -> CatalogueWire { CatalogueWire(fields: ["id": .string(id), "status": .string("completed"), "stage": .string("catalogue_match"), "revision_id": .string("approved-stifle")]) }
    func invoke(_ id: String) async throws { started += 1 }
    func photo(_ data: Data) async throws -> String { "search-inputs/user/input.jpg" }
    func rpc(_ name: String, _ params: [String: SprayReportPayloadV1.JSONValue]) async throws -> [CatalogueWire] { started += 1; return [] }
    func add(revisionId: String, vineyardId: UUID) async throws -> SavedChemical { SavedChemical(id: savedId, vineyardId: vineyardId, name: "Server product") }
}
