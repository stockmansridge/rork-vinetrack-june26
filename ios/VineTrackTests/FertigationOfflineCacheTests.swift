import Foundation
import Testing
@testable import VineTrack

@MainActor
struct FertigationOfflineCacheTests {
    @Test func accountSwitchDuringFetchCannotPersistResponse() async throws {
        let owner = UUID(), vineyard = UUID()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var stillCurrent: Bool = true
        await #expect(throws: CancellationError.self) {
            _ = try await FertigationProgramStepCache(directory: directory).load(ownerId: owner, vineyardId: vineyard,
                adminCheck: { true }, isCurrentAccount: { stillCurrent }, fetch: { stillCurrent = false; return [] })
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(owner.uuidString)-\(vineyard.uuidString).json").path))
    }

    @Test(arguments: ["online", "restart", "vineyard", "account", "denied", "firstOffline", "exact", "invalidResponse", "emptyResponse"])
    func scopedCanonicalCache(scenario: String) async throws {
        let owner = UUID(), vineyard = UUID(), stepId = UUID(), chemicalId = UUID()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let line: FertigationDomain.Object = ["chemical_id": .string(chemicalId.uuidString), "name": .string("N"), "rate": .number(12.345), "fertigation_rate_basis": .string("per_vine"), "fertigation_rate_unit": .string("mL/vine"), "unknown": .array([.null, .bool(true)])]
        let step = FertigationDomain.ProgramStep(raw: ["id": .string(stepId.uuidString), "vineyard_id": .string(vineyard.uuidString), "is_template": .bool(true), "operation_type": .string("Fertigation"), "chemical_lines": .array([.object(line)])])
        let cache = FertigationProgramStepCache(directory: directory)
        let repository = SupabaseFertigationRepository(adminCheck: { true }, transport: { name, _ in
            #expect(name == "list_fertigation_program_steps")
            return try JSONEncoder().encode([step])
        })
        if scenario != "firstOffline" {
            let online = try await cache.load(ownerId: owner, vineyardId: vineyard, adminCheck: { true }, fetch: { try await repository.programSteps(vineyardId: vineyard) })
            #expect(online?.isCached == false)
            #expect(online?.steps.first?.raw == step.raw)
            let file = directory.appending(path: "\(owner.uuidString)-\(vineyard.uuidString).json")
            let disk = try JSONDecoder().decode(FertigationProgramStepCache.Snapshot.self, from: Data(contentsOf: file))
            #expect(disk.steps.first?.raw == step.raw)
        }
        if scenario == "denied" {
            await #expect(throws: FertigationDomain.Failure.self) {
                _ = try await cache.load(ownerId: owner, vineyardId: vineyard, adminCheck: { false }, fetch: { Issue.record("Non-admin must not fetch"); return [] })
            }
        }
        if scenario == "invalidResponse" {
            let invalid = FertigationDomain.ProgramStep(raw: step.raw.merging(["vineyard_id": .string(UUID().uuidString)]) { _, new in new })
            let retained = try await cache.load(ownerId: owner, vineyardId: vineyard, adminCheck: { true }, fetch: { [invalid] })
            #expect(retained?.isCached == true && retained?.steps.first?.raw == step.raw)
        }
        if scenario == "emptyResponse" {
            _ = try await cache.load(ownerId: owner, vineyardId: vineyard, adminCheck: { true }, fetch: { [] })
        }
        let restarted = FertigationProgramStepCache(directory: directory)
        let offline = try await restarted.load(ownerId: scenario == "account" ? UUID() : owner,
            vineyardId: scenario == "vineyard" ? UUID() : vineyard,
            adminCheck: { throw URLError(.notConnectedToInternet) }, fetch: { Issue.record("Must not fetch without admin confirmation"); return [] })
        if ["account", "vineyard", "denied", "firstOffline"].contains(scenario) {
            #expect(offline == nil)
            #expect(IrrigationRecordEntryView().fertigationStepId == nil)
            #expect(try IrrigationLocalCalculator.totalVolume(method: .totalVolume, flowLitresPerHour: nil, durationMinutes: 60, meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: 1000) == 1000)
        } else if scenario == "emptyResponse" { #expect(offline?.steps.isEmpty == true) }
        else {
            #expect(offline?.isCached == true)
            #expect(offline?.steps.first?.id == stepId)
            #expect(offline?.steps.first?.lines == [line])
            #expect(offline?.steps.first?.raw == step.raw)
        }
    }

    @Test func staleCachedStepRejectionRetainsAcknowledgedIrrigationAndRetryIdentity() async throws {
        let owner = UUID(), vineyard = UUID(), sessionId = UUID(), appId = UUID()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let line: FertigationDomain.Object = ["chemical_id": .string(UUID().uuidString), "name": .string("N"), "rate": .number(1), "fertigation_rate_basis": .string("per_irrigation_cycle"), "fertigation_rate_unit": .string("kg")]
        let step = FertigationDomain.ProgramStep(raw: ["id": .string(UUID().uuidString), "vineyard_id": .string(vineyard.uuidString), "is_template": .bool(true), "operation_type": .string("Fertigation"), "chemical_lines": .array([.object(line)])])
        _ = try await FertigationProgramStepCache(directory: directory).load(ownerId: owner, vineyardId: vineyard, adminCheck: { true }, fetch: { [step] })
        let cached = try #require(try await FertigationProgramStepCache(directory: directory).load(ownerId: owner, vineyardId: vineyard, adminCheck: { throw URLError(.notConnectedToInternet) }, fetch: { [] }))
        let pending = IrrigationPendingSession(id: sessionId, vineyardId: vineyard, irrigationSystemId: UUID(), valveId: UUID(), valveName: "Valve", sessionDate: "2026-10-08", durationMinutes: 60, calculationMethod: "total_volume", flowLitresPerHour: nil, meterStartLitres: nil, meterFinishLitres: nil, totalVolumeLitres: 1000, startedAt: nil, finishedAt: nil, notes: nil, localTotalVolumeLitres: nil, createdAt: Date())
        let ack: FertigationDomain.Object = ["id": .string(sessionId.uuidString), "vineyard_id": .string(vineyard.uuidString), "irrigation_system_id": .string(pending.irrigationSystemId.uuidString), "valve_id": .string(pending.valveId.uuidString), "session_date": .string("2026-10-08"), "vintage_year": .number(2027), "duration_minutes": .number(60), "calculation_method": .string("total_volume"), "total_volume_litres": .number(1000), "status": .string("completed"), "source_type": .string("manual_ios"), "blocks": .array([])]
        let saved = try JSONDecoder().decode(IrrigationSession.self, from: JSONEncoder().encode(ack))
        let file = directory.appending(path: "outbox.json")
        let outbox = FertigationLinkedOutbox(file: file)
        let product = FertigationDomain.DraftProduct(line: cached.steps[0].lines[0])
        try outbox.enqueue(.init(id: appId, ownerId: owner, irrigation: pending, step: cached.steps[0], products: [product], notes: nil))
        var irrigationWrites: Int = 0
        try await outbox.flush(vineyardId: vineyard, ownerId: owner, record: { _ in irrigationWrites += 1; return saved }, upsert: { _, _ in throw FertigationDomain.Failure.invalidStep }, permanent: { $0 is FertigationDomain.Failure })
        let rejected = try #require(try outbox.entries().first)
        #expect(rejected.phase == .permanentError && rejected.acknowledgedTotals != nil)
        #expect(rejected.irrigation.id == sessionId && rejected.message.contains("needs attention"))
        let restarted = FertigationLinkedOutbox(file: file)
        try restarted.retry(id: appId)
        #expect(try restarted.entries().first?.phase == .fertigationPending)
        try await restarted.flush(vineyardId: vineyard, ownerId: owner, record: { _ in irrigationWrites += 1; return saved }, upsert: { entry, products in
            #expect(entry.id == appId && entry.irrigation.id == sessionId)
            #expect(products[0]["id"] == .string(product.id.uuidString))
            throw FertigationDomain.Failure.invalidStep
        }, permanent: { $0 is FertigationDomain.Failure })
        #expect(irrigationWrites == 1)
        #expect(try restarted.entries().first?.phase == .permanentError)
    }
}
