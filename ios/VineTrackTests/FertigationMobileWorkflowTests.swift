import Foundation
import Testing
@testable import VineTrack

@MainActor
struct FertigationMobileWorkflowTests {
    @Test(arguments: ["Foliar Spray", "Banded Spray", "Spreader", "Fertigation", "Autonomous Future Method"])
    func operationMappingIsClosed(raw: String) {
        let row = BackendSprayJobTemplate(id: UUID(), vineyardId: UUID(), name: "Step", operationType: raw)
        let mapped = row.toSprayRecord().operationType
        #expect(mapped == (OperationType(rawValue: raw) ?? .unsupported))
        #expect(row.canPlanSpray == ["Foliar Spray", "Banded Spray", "Spreader"].contains(raw))
        if raw == "Fertigation" || raw == "Autonomous Future Method" { #expect(mapped != .foliarSpray) }
        #expect(!OperationType.allCases.contains(.fertigation))
    }

    @Test func controlsRequireAdminAndCanonicalTemplate() {
        #expect(!OperationType.programMethods(isSystemAdmin: false, isPortalTemplate: true).contains(.fertigation))
        #expect(!OperationType.programMethods(isSystemAdmin: true, isPortalTemplate: false).contains(.fertigation))
        #expect(OperationType.programMethods(isSystemAdmin: true, isPortalTemplate: true).contains(.fertigation))
    }

    @Test func recordingRouteDefaultsToNoFertigationAndCarriesOnlyUUID() {
        #expect(IrrigationRecordEntryView().fertigationStepId == nil)
        let id = UUID()
        let route = IrrigationRecordEntryView(fertigationStepId: id)
        #expect(route.fertigationStepId == id)
        #expect(route.editingSession == nil && route.duplicateFrom == nil)
    }

    @Test func portalEditorRoundTripPreservesFertigationAndUnknownJSON() throws {
        let chemicalId = UUID()
        let raw: FertigationDomain.Object = ["chemical_id": .string(chemicalId.uuidString), "name": .string("Nutrient"), "rate": .number(10), "fertigation_rate_basis": .string("per_hectare"), "fertigation_rate_unit": .string("kg/ha"), "future": .object(["array": .array([.null, .bool(true)])])]
        let line = try JSONDecoder().decode(SprayJobChemicalLine.self, from: JSONEncoder().encode(raw))
        let row = BackendSprayJobTemplate(id: UUID(), vineyardId: UUID(), name: "EL12 Nutrients", chemicalLines: [line], waterVolume: 1200, operationType: "Fertigation", target: "Botrytis", targets: ["Botrytis"], equipmentId: UUID(), tractorId: UUID())
        let step = SprayProgramStep(record: row.toSprayRecord(), source: .portal, growthStageCode: "EL12", portalChemicalLines: row.chemicalLines)
        var draft = SprayProgramStepDraft(step: step)
        #expect(draft.products[0].rate == 10)
        #expect(draft.products[0].fertigationRateUnit == "kg/ha")
        draft.name = "Edited name"; draft.notes = "Keep these notes"; draft.products[0].rate = 12
        let update = draft.portalPayload(updatedBy: nil)
        let object = try JSONDecoder().decode(FertigationDomain.Object.self, from: JSONEncoder().encode(update))
        let reopened = row.applying(update)
        #expect(reopened.chemicalLines[0].fertigationRateBasis == "per_hectare")
        #expect(reopened.chemicalLines[0].fertigationRateUnit == "kg/ha")
        #expect(reopened.chemicalLines[0].chemicalId == chemicalId)
        #expect(reopened.chemicalLines[0].rawLine["future"] == raw["future"])
        #expect(object["water_volume"] == .null)
        #expect(object["equipment_id"] == .null)
        #expect(object["tractor_id"] == .null)
        #expect(object["targets"] == .array([]))
        #expect(object["target"] == .null)
    }

    @Test func replacementKeepsDraftAndUsesNewUUIDWithoutInventingUnits() {
        let row = BackendSprayJobTemplate(id: UUID(), vineyardId: UUID(), name: "Name", operationType: "Fertigation")
        var draft = SprayProgramStepDraft(step: .init(record: row.toSprayRecord(), source: .portal, growthStageCode: "EL12"))
        draft.notes = "Draft notes"
        draft.products = [SprayProgramProductDraft(name: "First", rate: 10), SprayProgramProductDraft(name: "Second", rate: 20)]
        let intendedId = draft.products[1].id
        let chemical = SavedChemical(name: "New nutrient", unit: .litres, activeIngredient: "N")
        draft.products[1].replaceFertigationProduct(with: chemical)
        #expect(draft.name == "Name" && draft.notes == "Draft notes" && draft.growthStageCode == "EL12")
        #expect(draft.products[0].rate == 10)
        #expect(draft.products[1].id == intendedId)
        #expect(draft.chemicalLines()[1].chemicalId == chemical.id)
        #expect(draft.products[1].fertigationRateBasis == nil && draft.products[1].fertigationRateUnit == nil)
    }

    @Test(arguments: ["online", "fertigationFailure", "offline", "permanent", "wrongAck", "otherOwner"])
    func durableDependencyReplay(scenario: String) async throws {
        let vineyard = UUID(), owner = UUID(), sessionId = UUID(), applicationId = UUID(), productId = UUID(), stepId = UUID()
        let file = FileManager.default.temporaryDirectory.appending(path: "fertigation-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pending = IrrigationPendingSession(id: sessionId, vineyardId: vineyard, irrigationSystemId: UUID(), valveId: UUID(), valveName: "Valve", sessionDate: "2026-10-07", durationMinutes: 60, calculationMethod: "total_volume", flowLitresPerHour: nil, meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: 1000, startedAt: nil, finishedAt: nil, notes: nil, localTotalVolumeLitres: nil, createdAt: Date())
        let step = FertigationDomain.ProgramStep(raw: ["id": .string(stepId.uuidString), "name": .string("Nutrients"), "vineyard_id": .string(vineyard.uuidString), "is_template": .bool(true), "operation_type": .string("Fertigation")])
        let product = FertigationDomain.DraftProduct(id: productId, line: ["name": .string("N"), "chemical_id": .string(UUID().uuidString), "rate": .number(10), "fertigation_rate_basis": .string("per_hectare"), "fertigation_rate_unit": .string("kg/ha")])
        let outbox = FertigationLinkedOutbox(file: file)
        let entry = FertigationLinkedOutbox.Entry(id: applicationId, ownerId: owner, irrigation: pending, step: step, products: [product], notes: "Frozen notes")
        try outbox.enqueue(entry); try outbox.enqueue(entry)
        #expect(try outbox.entries().count == 1)
        var calls: [String] = []
        let ack: FertigationDomain.Object = ["id": .string((scenario == "wrongAck" ? UUID() : sessionId).uuidString), "vineyard_id": .string(vineyard.uuidString), "irrigation_system_id": .string(pending.irrigationSystemId.uuidString), "valve_id": .string(pending.valveId.uuidString), "session_date": .string("2026-10-07"), "vintage_year": .number(2027), "duration_minutes": .number(60), "calculation_method": .string("total_volume"), "total_volume_litres": .number(1000), "status": .string("completed"), "source_type": .string("manual_ios"), "blocks": .array([])]
        let saved = try JSONDecoder().decode(IrrigationSession.self, from: JSONEncoder().encode(ack))
        try await outbox.flush(vineyardId: vineyard, ownerId: scenario == "otherOwner" ? UUID() : owner, record: { _ in
            calls.append("irrigation")
            if scenario == "offline" { throw URLError(.notConnectedToInternet) }
            return saved
        }, upsert: { e, products in
            calls.append("fertigation")
            #expect(try FertigationLinkedOutbox(file: file).entries().first?.phase == .fertigationPending)
            #expect(products[0]["id"] == .string(productId.uuidString))
            #expect(products[0]["actual_quantity"] == .null)
            #expect(products[0]["planned_quantity"] == .null)
            if scenario == "fertigationFailure" || scenario == "permanent" { throw URLError(.cannotConnectToHost) }
            return .init(raw: ["id": .string(e.id.uuidString), "irrigation_session_id": .string(sessionId.uuidString)])
        }, permanent: { _ in scenario == "permanent" })
        if scenario == "otherOwner" { #expect(calls.isEmpty); return }
        if scenario == "wrongAck" { #expect(calls == ["irrigation"]); return }
        if scenario == "offline" { #expect(calls == ["irrigation"]) }
        else { #expect(calls == ["irrigation", "fertigation"]) }
        let restarted = FertigationLinkedOutbox(file: file)
        #expect(try restarted.entries().first?.products[0].id == productId)
        if scenario == "permanent" {
            try await restarted.flush(vineyardId: vineyard, ownerId: owner, record: { _ in Issue.record("Must not recreate irrigation"); return saved }, upsert: { _, _ in Issue.record("Must not automatically repeat permanent rejection"); return .init(raw: [:]) }, permanent: { _ in false })
            #expect(try restarted.entries().first?.phase == .permanentError)
            try restarted.retry(id: applicationId)
        }
        var resumed: [String] = []
        try await restarted.flush(vineyardId: vineyard, ownerId: owner, record: { _ in resumed.append("irrigation"); return saved }, upsert: { e, _ in resumed.append("fertigation"); return .init(raw: ["id": .string(e.id.uuidString), "irrigation_session_id": .string(sessionId.uuidString)]) }, permanent: { _ in false })
        #expect(resumed == (scenario == "online" ? [] : scenario == "offline" ? ["irrigation", "fertigation"] : ["fertigation"]))
        #expect(try restarted.entries().first?.phase == .acknowledged)
        var repeats: Int = 0
        try await restarted.flush(vineyardId: vineyard, ownerId: owner, record: { _ in repeats += 1; return saved }, upsert: { _, _ in repeats += 1; return .init(raw: [:]) }, permanent: { _ in false })
        #expect(repeats == 0)
    }
}
