import Foundation
import Testing
@testable import VineTrack

@MainActor
struct FertigationHistoryTests {
    let vineyard = UUID(), sessionId = UUID(), stepId = UUID(), appId = UUID(), productId = UUID(), chemicalId = UUID()
    var product: FertigationDomain.Object { ["id": .string(productId.uuidString), "saved_chemical_id": .string(chemicalId.uuidString), "product_name": .string("Frozen nutrient"), "planned_rate": .number(3), "rate_unit": .string("kg/ha"), "planned_quantity": .number(6), "actual_quantity": .null, "quantity_unit": .string("kg"), "cost_per_unit": .number(2), "product_snapshot": .object(["opaque": .bool(true)])] }
    var application: FertigationDomain.Application { .init(raw: ["id": .string(appId.uuidString), "irrigation_session_id": .string(sessionId.uuidString), "program_step_id": .string(stepId.uuidString), "program_step_name": .string("Frozen name"), "growth_stage_code": .string("EL12"), "notes": .string("Frozen notes"), "status": .string("active"), "products": .array([.object(product)])]) }
    func session(source: String = "manual_ios", status: String = "completed") throws -> IrrigationSession {
        let raw: FertigationDomain.Object = ["id": .string(sessionId.uuidString), "vineyard_id": .string(vineyard.uuidString), "irrigation_system_id": .string(UUID().uuidString), "valve_id": .string(UUID().uuidString), "session_date": .string("2026-10-08"), "vintage_year": .number(2027), "duration_minutes": .number(60), "calculation_method": .string("total_volume"), "total_volume_litres": .number(1000), "status": .string(status), "source_type": .string(source), "blocks": .array([])]
        return try JSONDecoder().decode(IrrigationSession.self, from: JSONEncoder().encode(raw))
    }
    @Test func normalExistingSessionCanReceive() throws {
        var draft = FertigationSessionDraft()
        try draft.select(.init(raw: ["id": .string(stepId.uuidString), "name": .string("Selected nutrient step"), "chemical_lines": .array([.object(["chemical_id": .string(chemicalId.uuidString), "name": .string("Nutrient"), "rate": .number(5), "fertigation_rate_basis": .string("per_irrigation_cycle"), "fertigation_rate_unit": .string("kg")])])]), totals: .init(allocations: []))
        let entry = try draft.entry(session: session(), ownerId: UUID())
        #expect(entry.acknowledgedProducts?.count == 1 && entry.id == draft.id)
        #expect(entry.existingSession == true && entry.phase == .fertigationPending && entry.irrigation.id == sessionId)
    }
    @Test func importedExistingSessionCanReceive() throws {
        var draft = FertigationSessionDraft()
        try draft.select(.init(raw: ["id": .string(stepId.uuidString), "chemical_lines": .array([.object(["chemical_id": .string(chemicalId.uuidString), "name": .string("Nutrient"), "rate": .number(5), "fertigation_rate_basis": .string("per_irrigation_cycle"), "fertigation_rate_unit": .string("kg")])])]), totals: .init(allocations: []))
        let entry = try draft.entry(session: session(source: "galcon_gsi_import", status: "imported"), ownerId: UUID())
        #expect(entry.phase == .fertigationPending)
    }
    @Test func addingNeverRecordsIrrigation() async throws { try await replay(mode: "online") }
    @Test func offlineWritePersistsAcrossRestart() async throws { try await replay(mode: "offline") }
    @Test func retryOnlyUpsertsFertigation() async throws { try await replay(mode: "permanent") }
    @Test func retryPreservesApplicationAndProductUUIDs() async throws { try await replay(mode: "identity") }
    @Test func onePendingApplicationPerSession() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let box = FertigationLinkedOutbox(file: file)
        let entry = try FertigationSessionDraft(application: application).entry(session: session(), ownerId: UUID())
        try box.enqueueExisting(entry)
        #expect(throws: (any Error).self) { try box.enqueueExisting(entry) }
        #expect(try box.entries().count == 1)
    }
    @Test func viewEditLoadsExistingValues() {
        let draft = FertigationSessionDraft(application: application)
        #expect(draft.id == appId && draft.step?.id == stepId && draft.notes == "Frozen notes")
        #expect(draft.products == [product] && draft.actuals == [""])
    }
    @Test func frozenValuesDriveDisplay() {
        #expect(FertigationHistory.rate(product).contains("3"))
        #expect(FertigationHistory.quantity(product, key: "planned_quantity").contains("6"))
        #expect(FertigationDomain.string(application.raw, "program_step_name") == "Frozen name")
    }
    @Test func laterProgramEditsDoNotRestateHistory() throws {
        var draft = FertigationSessionDraft(application: application)
        try draft.select(.init(raw: ["id": .string(stepId.uuidString), "name": .string("Renamed today"), "chemical_lines": .array([])]), totals: .init(allocations: []))
        #expect(draft.products == [product] && draft.step?.name == "Frozen name")
    }
    @Test func oneIrrigationRowPlusBadge() {
        let irrigationRows = [sessionId]
        let index = FertigationHistory.index([application, application], isSystemAdmin: true)
        #expect(irrigationRows.count == 1 && index.count == 1 && index[sessionId] != nil)
    }
    @Test func bulkHistoryRequestsOnce() async throws {
        var calls = 0
        let repo = SupabaseFertigationRepository(adminCheck: { true }, transport: { name, _ in
            calls += 1; #expect(name == "list_fertigation_applications")
            return try JSONEncoder().encode([application])
        })
        let index = try await repo.historyIndex(vineyardId: vineyard, vintageYear: 2027, isSystemAdmin: true)
        for _ in 0..<100 { #expect(index[sessionId] != nil) }
        #expect(calls == 1)
    }
    @Test func nonAdminHistoryUnchangedAndNoRPC() async throws {
        var calls = 0
        let repo = SupabaseFertigationRepository(adminCheck: { calls += 1; return false }, transport: { _, _ in calls += 1; return Data() })
        let index = try await repo.historyIndex(vineyardId: vineyard, isSystemAdmin: false)
        let detail = try await repo.historicalSession(vineyardId: vineyard, sessionId: sessionId, vintageYear: 2027, isSystemAdmin: false)
        #expect(index.isEmpty && detail == nil && calls == 0)
    }
    @Test func nullActualIsNotZero() { #expect(FertigationHistory.quantity(product, key: "actual_quantity") == "Actual not entered") }
    @Test func missingAndZeroCostUnavailable() {
        var p = product; p["actual_quantity"] = .number(4); p["cost_per_unit"] = .null
        #expect(FertigationDomain.frozenCost(product: p) == nil)
        p["cost_per_unit"] = .number(0); #expect(FertigationDomain.frozenCost(product: p) == nil)
    }
    @Test func programHistoryUsesExactUUID() async throws {
        let repo = SupabaseFertigationRepository(adminCheck: { true }, transport: { name, params in
            #expect(name == "list_fertigation_applications" && params["p_program_step_id"] == .string(stepId.uuidString))
            return Data("[]".utf8)
        })
        _ = try await repo.applications(vineyardId: vineyard, programStepId: stepId, includeReversed: true)
    }
    @Test func programHistoryIncludesReversed() async throws {
        let repo = SupabaseFertigationRepository(adminCheck: { true }, transport: { _, params in
            #expect(params["p_include_reversed"] == .bool(true)); return Data("[]".utf8)
        })
        _ = try await repo.applications(vineyardId: vineyard, programStepId: stepId, includeReversed: true)
    }
    @Test func irrigationReversalReloadsReversedState() async throws {
        var status = "active", displayed = "active"
        try await FertigationHistory.afterIrrigationReversal(reverse: { status = "reversed" }, reload: { displayed = status })
        #expect(displayed == "reversed")
    }
    @Test func reversedRemainsVisibleWhenActiveLookupNull() async throws {
        var reversed = application; reversed.raw["status"] = .string("reversed")
        var calls: [String] = []
        let repo = SupabaseFertigationRepository(adminCheck: { true }, transport: { name, _ in
            calls.append(name)
            if name == "get_irrigation_session_fertigation" { return Data("null".utf8) }
            return try JSONEncoder().encode([reversed])
        })
        let result = try await repo.historicalSession(vineyardId: vineyard, sessionId: sessionId, vintageYear: 2027, isSystemAdmin: true)
        #expect(result?.id == appId && result?.isEditable == false)
        #expect(calls == ["get_irrigation_session_fertigation", "list_fertigation_applications"])
    }
    @Test func reversedIsReadOnly() throws {
        var reversed = application; reversed.raw["status"] = .string("reversed")
        let draft = FertigationSessionDraft(application: reversed)
        #expect(draft.isReadOnly)
        #expect(throws: (any Error).self) { try draft.payloads() }
        #expect(throws: (any Error).self) { try draft.entry(session: session(), ownerId: UUID()) }
    }
    @Test func reversalNeverCallsIndependentFertigationReverse() async throws {
        var calls: [String] = []
        try await FertigationHistory.afterIrrigationReversal(reverse: { calls.append("reverse_irrigation_session") }, reload: { calls.append("reload") })
        #expect(calls == ["reverse_irrigation_session", "reload"])
    }
    @Test func importedRestrictionDoesNotHideFertigation() throws {
        let imported = try session(source: "galcon_gsi_import", status: "corrected")
        #expect(imported.isImported)
        #expect(FertigationSessionDraft.canAttach(vineyardId: vineyard, selectedVineyardId: vineyard, status: imported.status, isSystemAdmin: true))
    }
    @Test func normalIrrigationWithoutFertigationUnchanged() throws {
        let normal = try session()
        #expect(FertigationHistory.index([], isSystemAdmin: true)[normal.id] == nil)
        #expect(normal.totalVolumeLitres == 1000 && normal.status == "completed" && !normal.isImported)
    }
    @Test func normalProgramMethodsRemainUnchanged() {
        #expect(OperationType.allCases.map(\.rawValue) == ["Foliar Spray", "Banded Spray", "Spreader"])
    }
    @Test func retainedProductKeepsUUIDOnDeliberateStepChange() throws {
        var draft = FertigationSessionDraft(application: application)
        let next = FertigationDomain.ProgramStep(raw: ["id": .string(UUID().uuidString), "name": .string("New step"), "chemical_lines": .array([.object(["chemical_id": .string(chemicalId.uuidString), "rate": .number(3), "fertigation_rate_unit": .string("kg/ha")])])])
        try draft.select(next, totals: .init(allocations: []))
        #expect(draft.id == appId && draft.products == [product] && draft.step?.id == next.id)
    }
    @Test func changedProductLineGetsNewSnapshot() throws {
        var draft = FertigationSessionDraft(application: application)
        let next = FertigationDomain.ProgramStep(raw: ["id": .string(UUID().uuidString), "name": .string("New step"), "chemical_lines": .array([.object(["chemical_id": .string(chemicalId.uuidString), "name": .string("Nutrient"), "rate": .number(99), "fertigation_rate_basis": .string("per_irrigation_cycle"), "fertigation_rate_unit": .string("kg")])])])
        try draft.select(next, totals: .init(allocations: []))
        #expect(draft.id == appId && FertigationDomain.uuid(draft.products[0], "id") != productId)
        #expect(draft.products[0]["planned_rate"] == .number(99))
    }
    @Test func actualOnlyEditPreservesFrozenFields() throws {
        var draft = FertigationSessionDraft(application: application); draft.actuals = ["4.5"]
        var expected = product; expected["actual_quantity"] = .number(4.5)
        #expect(try draft.payloads() == [expected])
    }
    @Test func deletedAndReversedSessionsCannotWrite() throws {
        var deleted = try session(); deleted.deletedAt = "2026-10-08"
        let draft = FertigationSessionDraft(application: application)
        #expect(throws: (any Error).self) { try draft.entry(session: deleted, ownerId: UUID()) }
        #expect(throws: (any Error).self) { try draft.entry(session: session(status: "reversed"), ownerId: UUID()) }
    }
    private func replay(mode: String) async throws {
        let owner = UUID(), file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let box = FertigationLinkedOutbox(file: file)
        let entry = try FertigationSessionDraft(application: application).entry(session: session(), ownerId: owner)
        try box.enqueueExisting(entry)
        var recordCalls = 0, upsertCalls = 0
        try await box.flush(vineyardId: vineyard, ownerId: owner, record: { _ in recordCalls += 1; return try session() }, upsert: { e, products in
            upsertCalls += 1; #expect(e.id == appId && products[0]["id"] == .string(productId.uuidString))
            if mode != "online" { throw URLError(.notConnectedToInternet) }
            return application
        }, permanent: { _ in mode == "permanent" })
        let restarted = FertigationLinkedOutbox(file: file)
        let retained = try #require(restarted.entries().first)
        #expect(retained.existingSession == true && retained.id == appId && retained.acknowledgedProducts == [product])
        #expect(recordCalls == 0 && upsertCalls == 1)
        if mode != "online" {
            try restarted.retry(id: appId)
            #expect(try restarted.entries()[0].phase == .fertigationPending)
            try await restarted.flush(vineyardId: vineyard, ownerId: owner, record: { _ in recordCalls += 1; return try session() }, upsert: { e, products in
                upsertCalls += 1; #expect(e.id == appId && products == [product]); return application
            }, permanent: { _ in false })
            #expect(recordCalls == 0 && upsertCalls == 2)
        }
        #expect(try restarted.entries()[0].phase == .acknowledged)
    }
}
