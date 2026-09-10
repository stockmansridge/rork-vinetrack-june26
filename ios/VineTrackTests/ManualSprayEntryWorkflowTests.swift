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

    func testNotesOnlyEditPreservesRecordedWeatherProvenance() throws {
        var payload = fixture()
        let observedAt = Date(timeIntervalSince1970: 1_788_999_100)
        payload.manualWeather = ManualSprayWeather(
            observedAt: observedAt, source: "Recorded station override", temperatureC: 12,
            humidityPct: nil, windSpeedKmh: nil, windGustKmh: nil, windDirectionDeg: nil, rainMm: nil
        )
        payload.notes = "Changed note"
        let validated = try payload.validated()
        XCTAssertEqual(validated.manualWeather?.observedAt, observedAt)
        XCTAssertEqual(validated.manualWeather?.source, "Recorded station override")
    }

    func testPersistenceFailureDoesNotSendOrCreateMemoryShortcut() async {
        let repository = ManualSprayRepositoryDouble()
        let store = ManualSprayMemoryStore(failSaves: 1)
        let coordinator = ManualSprayEntryCoordinator(repository: repository, store: store)
        do {
            _ = try await coordinator.save(payload: fixture(), expectedVersion: 0)
            XCTFail("Expected persistence failure")
        } catch {}
        XCTAssertTrue(coordinator.pendingPayloads.isEmpty)
        let saveCount = await repository.saveCalls.count
        XCTAssertEqual(saveCount, 0)
    }

    func testUnconfirmedResponseRetainsExactRetry() async throws {
        let payload = fixture()
        let repository = ManualSprayRepositoryDouble(serverConfirmed: false)
        let coordinator = ManualSprayEntryCoordinator(repository: repository, store: ManualSprayMemoryStore())
        let response = try await coordinator.save(
            payload: payload,
            expectedVersion: 0
        )
        XCTAssertNil(response)
        XCTAssertEqual(coordinator.pendingPayloads, [payload])
    }

    func testReplayUsesOwningVineyardRole() async throws {
        let payload = fixture()
        let repository = ManualSprayRepositoryDouble(failSaves: 1)
        let coordinator = ManualSprayEntryCoordinator(repository: repository, store: ManualSprayMemoryStore())
        _ = try await coordinator.save(payload: payload, expectedVersion: 0)
        await coordinator.replay(currentVineyardId: UUID(), currentRole: .owner)
        let saveCount = await repository.saveCalls.count
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(coordinator.pendingPayloads, [payload])
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

    func testTerminalConflictAndDeletedErrorsAreNotQueuedForReplay() async throws {
        let payload = fixture()
        for terminalError in [ManualSprayMutationError.staleVersion, .deleted] {
            let repository = ManualSprayTerminalRepositoryDouble(error: terminalError)
            let store = ManualSprayMemoryStore()
            let coordinator = ManualSprayEntryCoordinator(repository: repository, store: store)
            do {
                _ = try await coordinator.save(payload: payload, expectedVersion: 1)
                XCTFail("Expected terminal mutation error")
            } catch let error as ManualSprayMutationError {
                XCTAssertEqual(error.localizedDescription, terminalError.localizedDescription)
            }
            XCTAssertTrue(coordinator.pendingPayloads.isEmpty)
        }
    }

    func testDeleteBeforeReplaySuppressesSave() async throws {
        let repository = ManualSprayRepositoryDouble(failSaves: 1, failDeletes: 1)
        let store = ManualSprayMemoryStore()
        let coordinator = ManualSprayEntryCoordinator(repository: repository, store: store)
        let payload = fixture()
        _ = try await coordinator.save(payload: payload, expectedVersion: 0)
        _ = try await coordinator.delete(payload: payload)
        XCTAssertTrue(coordinator.pendingPayloads.isEmpty)
        await coordinator.replay(currentVineyardId: payload.vineyardId, currentRole: .operator)
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
    private let serverConfirmed: Bool
    private(set) var saveCalls: [Call] = []

    init(failSaves: Int = 0, failDeletes: Int = 0, serverConfirmed: Bool = true) {
        remainingSaveFailures = failSaves
        remainingDeleteFailures = failDeletes
        self.serverConfirmed = serverConfirmed
    }
    func save(operationId: UUID, payload: ManualSprayPayload, expectedVersion: Int?) async throws -> ManualSpraySaveResponse {
        saveCalls.append(Call(operationId: operationId, payload: payload))
        if remainingSaveFailures > 0 { remainingSaveFailures -= 1; throw URLError(.notConnectedToInternet) }
        return ManualSpraySaveResponse(operationId: operationId, manualEntryId: payload.manualEntryId, sprayRecordId: payload.sprayRecordId, tripId: payload.tripId, source: "manual", status: "completed", syncVersion: 1, serverConfirmed: serverConfirmed)
    }
    func delete(operationId: UUID, payload: ManualSprayPayload) async throws {
        if remainingDeleteFailures > 0 { remainingDeleteFailures -= 1; throw URLError(.notConnectedToInternet) }
    }
}

private actor ManualSprayTerminalRepositoryDouble: ManualSprayEntryRepositoryProtocol {
    let error: ManualSprayMutationError
    init(error: ManualSprayMutationError) { self.error = error }
    func save(operationId: UUID, payload: ManualSprayPayload, expectedVersion: Int?) async throws -> ManualSpraySaveResponse { throw error }
    func delete(operationId: UUID, payload: ManualSprayPayload) async throws {}
}

private final class ManualSprayMemoryStore: ManualSprayEntryStoring, @unchecked Sendable {
    private var values: [PendingManualSprayOperation] = []
    private var failSaves: Int
    init(failSaves: Int = 0) { self.failSaves = failSaves }
    func load() -> [PendingManualSprayOperation] { values }
    func save(_ operations: [PendingManualSprayOperation]) -> Bool {
        if failSaves > 0 { failSaves -= 1; return false }
        values = operations
        return true
    }
}
