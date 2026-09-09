import XCTest
@testable import VineTrack

@MainActor
final class ManualSprayEntryWorkflowTests: XCTestCase {
    func testSupervisorCapabilityAndOperatorRejection() {
        XCTAssertTrue(BackendRole.supervisor.canManageManualSprays)
        XCTAssertFalse(BackendRole.operator.canManageManualSprays)
    }

    func testUnitRoundTripAndValidationAcrossMidnight() throws {
        var payload = fixture()
        payload.startUtc = ISO8601DateFormatter().date(from: "2026-09-08T23:30:00Z")!
        payload.endUtc = ISO8601DateFormatter().date(from: "2026-09-09T01:00:00Z")!
        XCTAssertNoThrow(try payload.validated())
        XCTAssertEqual(ChemicalUnit.litres.toBase(2.5), 2_500)
        XCTAssertEqual(ChemicalUnit.kilograms.fromBase(750), 0.75)
    }

    func testLostResponseRetainsSameIdsForReplay() async throws {
        let repository = ManualSprayRepositoryDouble(failSaves: 1)
        let store = ManualSprayMemoryStore()
        let coordinator = ManualSprayEntryCoordinator(repository: repository, store: store)
        let payload = fixture()
        let response = try await coordinator.save(payload: payload, expectedVersion: 0)
        XCTAssertNil(response)
        XCTAssertEqual(coordinator.pendingPayloads.first?.manualEntryId, payload.manualEntryId)
        let retryResponse = try await coordinator.save(payload: payload, expectedVersion: 0)
        XCTAssertTrue(retryResponse?.serverConfirmed == true)
        XCTAssertTrue(coordinator.pendingPayloads.isEmpty)
        let calls = await repository.saveCalls
        XCTAssertEqual(Set(calls.map(\.operationId)).count, 1)
        XCTAssertEqual(Set(calls.map(\.payload.manualEntryId)), [payload.manualEntryId])
    }

    func testDeleteBeforeReplaySuppressesSave() async throws {
        let repository = ManualSprayRepositoryDouble(failSaves: 1, failDeletes: 1)
        let store = ManualSprayMemoryStore()
        let coordinator = ManualSprayEntryCoordinator(repository: repository, store: store)
        let payload = fixture()
        _ = try await coordinator.save(payload: payload, expectedVersion: 0)
        _ = try await coordinator.delete(payload: payload)
        XCTAssertTrue(coordinator.pendingPayloads.isEmpty)
        await coordinator.replay(currentRole: .operator)
        let saveCount = await repository.saveCalls.count
        XCTAssertEqual(saveCount, 1)
    }

    private func fixture() -> ManualSprayPayload {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        return ManualSprayPayload(
            vineyardId: UUID(), manualEntryId: UUID(), sprayRecordId: UUID(), tripId: UUID(), reference: "Manual 1",
            operationType: OperationType.foliarSpray.rawValue, startUtc: start, endUtc: start.addingTimeInterval(3_600),
            vineyardTimeZone: "Australia/Adelaide", tractorId: UUID(), operatorUserId: UUID(), sprayEquipmentId: UUID(),
            startEngineHours: 10, endEngineHours: 11, notes: nil, clientUpdatedAt: start,
            blocks: [ManualSprayBlock(blockId: UUID(), blockName: "Block A")],
            tanks: [ManualSprayTank(id: UUID(), actualId: UUID(), tankNumber: 1, waterVolumeLitres: 1_000, chemicals: [ManualSprayChemical(id: UUID(), savedChemicalId: UUID(), name: "Liquid", actualAmountBase: 2_500, unit: .litres, productCategory: "fungicide", physicalForm: .liquid, snapshotAt: start)])],
            manualWeather: nil
        )
    }
}

private actor ManualSprayRepositoryDouble: ManualSprayEntryRepositoryProtocol {
    struct Call: Sendable { let operationId: UUID; let payload: ManualSprayPayload }
    private var remainingSaveFailures: Int
    private var remainingDeleteFailures: Int
    private(set) var saveCalls: [Call] = []

    init(failSaves: Int = 0, failDeletes: Int = 0) { remainingSaveFailures = failSaves; remainingDeleteFailures = failDeletes }
    func save(operationId: UUID, payload: ManualSprayPayload, expectedVersion: Int?) async throws -> ManualSpraySaveResponse {
        saveCalls.append(Call(operationId: operationId, payload: payload))
        if remainingSaveFailures > 0 { remainingSaveFailures -= 1; throw URLError(.notConnectedToInternet) }
        return ManualSpraySaveResponse(operationId: operationId, manualEntryId: payload.manualEntryId, sprayRecordId: payload.sprayRecordId, tripId: payload.tripId, source: "manual", status: "completed", syncVersion: 1, serverConfirmed: true)
    }
    func delete(operationId: UUID, payload: ManualSprayPayload) async throws {
        if remainingDeleteFailures > 0 { remainingDeleteFailures -= 1; throw URLError(.notConnectedToInternet) }
    }
}

private final class ManualSprayMemoryStore: ManualSprayEntryStoring, @unchecked Sendable {
    private var values: [PendingManualSprayOperation] = []
    func load() -> [PendingManualSprayOperation] { values }
    func save(_ operations: [PendingManualSprayOperation]) -> Bool { values = operations; return true }
}
