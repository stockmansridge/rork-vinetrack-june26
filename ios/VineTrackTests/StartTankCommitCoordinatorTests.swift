import XCTest
@testable import VineTrack

@MainActor
final class StartTankCommitCoordinatorTests: XCTestCase {
    private let vineyardId = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let tripId = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let sessionId = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
    private let actualId = UUID(uuidString: "20000000-0000-4000-8000-000000000004")!

    private func makeHarness() throws -> (URL, PersistenceStore, MigratedDataStore, SprayTankActualStore, Trip, Trip, SprayTankActual) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        let original = Trip(id: tripId, vineyardId: vineyardId, paddockName: "Block", startTime: Date(timeIntervalSince1970: 100), isActive: true)
        store.trips = [original]
        var updated = original
        updated.tankSessions = [TankSession(id: sessionId, tankNumber: 1, startTime: Date(timeIntervalSince1970: 200))]
        updated.activeTankNumber = 1
        let actual = try SprayTankActual(
            id: actualId, vineyardId: vineyardId,
            sprayRecordId: UUID(uuidString: "20000000-0000-4000-8000-000000000005")!,
            tripId: tripId, tankSessionId: sessionId.uuidString, tankNumber: 1,
            waterVolumeL: 500, chemicals: [], confirmedAt: Date(timeIntervalSince1970: 200),
            confirmedBy: UUID(uuidString: "20000000-0000-4000-8000-000000000006")!
        )
        return (directory, persistence, store, SprayTankActualStore(persistence: persistence), original, updated, actual)
    }

    func testFailureBeforeEitherSaveMutatesNeitherStore() throws {
        let (directory, persistence, store, actualStore, source, updated, actual) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = StartTankCommitCoordinator(persistence: persistence, actualStore: actualStore, failurePoint: .beforeActual)
        XCTAssertThrowsError(try coordinator.commit(sourceTrip: source, updatedTrip: updated, actual: actual, store: store))
        XCTAssertTrue(actualStore.records.isEmpty)
        XCTAssertTrue(store.trips[0].tankSessions.isEmpty)
        XCTAssertNotNil(persistence.load(key: StartTankCommitCoordinator.persistenceKey) as StartTankCommitCoordinator.Journal?)
    }

    func testInterruptedCommitRecoversOntoNewerRouteWithStableIds() throws {
        let (directory, persistence, store, actualStore, source, updated, actual) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        let interrupted = StartTankCommitCoordinator(persistence: persistence, actualStore: actualStore, failurePoint: .afterActual)
        XCTAssertThrowsError(try interrupted.commit(sourceTrip: source, updatedTrip: updated, actual: actual, store: store))

        var progressed = source
        progressed.pathPoints = [
            CoordinatePoint(latitude: -33.0, longitude: 149.0),
            CoordinatePoint(latitude: -33.0001, longitude: 149.0001)
        ]
        progressed.totalDistance = 73
        progressed.completedPaths = [4.5]
        progressed.endEngineHours = 130
        progressed.completionNotes = "new metadata"
        store.trips = [progressed]

        let relaunchedActualStore = SprayTankActualStore(persistence: persistence)
        let recovery = StartTankCommitCoordinator(persistence: persistence, actualStore: relaunchedActualStore)
        XCTAssertTrue(recovery.recover(store: store))
        XCTAssertFalse(recovery.recover(store: store))
        XCTAssertEqual(relaunchedActualStore.records.filter { $0.id == actualId }.count, 1)
        XCTAssertEqual(store.trips.first?.pathPoints, progressed.pathPoints)
        XCTAssertEqual(store.trips.first?.totalDistance, 73)
        XCTAssertEqual(store.trips.first?.completedPaths, [4.5])
        XCTAssertEqual(store.trips.first?.endEngineHours, 130)
        XCTAssertEqual(store.trips.first?.completionNotes, "new metadata")
        XCTAssertEqual(store.trips.first?.tankSessions.filter { $0.id == sessionId }.count, 1)
        XCTAssertNil(persistence.load(key: StartTankCommitCoordinator.persistenceKey) as StartTankCommitCoordinator.Journal?)
    }

    func testEveryInterruptedStateRecoversWithSameIdsAndRepeatedRecoveryIsIdempotent() throws {
        for point in [StartTankCommitCoordinator.FailurePoint.afterActual, .afterTrip, .beforeClear] {
            let (directory, persistence, store, actualStore, source, updated, actual) = try makeHarness()
            defer { try? FileManager.default.removeItem(at: directory) }
            let interrupted = StartTankCommitCoordinator(persistence: persistence, actualStore: actualStore, failurePoint: point)
            XCTAssertThrowsError(try interrupted.commit(sourceTrip: source, updatedTrip: updated, actual: actual, store: store))

            let relaunchedActualStore = SprayTankActualStore(persistence: persistence)
            let recovery = StartTankCommitCoordinator(persistence: persistence, actualStore: relaunchedActualStore)
            XCTAssertTrue(recovery.recover(store: store))
            XCTAssertFalse(recovery.recover(store: store))
            XCTAssertEqual(relaunchedActualStore.records.filter { $0.id == actualId }.count, 1)
            XCTAssertEqual(relaunchedActualStore.records.first?.tankSessionId, sessionId.uuidString)
            XCTAssertEqual(store.trips.first?.tankSessions.filter { $0.id == sessionId }.count, 1)
            XCTAssertNil(persistence.load(key: StartTankCommitCoordinator.persistenceKey) as StartTankCommitCoordinator.Journal?)
        }
    }

    func testEndedOrLaterConflictingTankOperationIsPreservedAndJournalRemainsRecoverable() throws {
        let (directory, persistence, store, actualStore, source, updated, actual) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        let interrupted = StartTankCommitCoordinator(persistence: persistence, actualStore: actualStore, failurePoint: .afterActual)
        XCTAssertThrowsError(try interrupted.commit(sourceTrip: source, updatedTrip: updated, actual: actual, store: store))

        var conflicting = source
        let laterId = UUID(uuidString: "20000000-0000-4000-8000-000000000099")!
        conflicting.tankSessions = [TankSession(id: laterId, tankNumber: 2, startTime: Date(timeIntervalSince1970: 300))]
        conflicting.activeTankNumber = 2
        store.trips = [conflicting]
        let recovery = StartTankCommitCoordinator(persistence: persistence, actualStore: SprayTankActualStore(persistence: persistence))
        XCTAssertFalse(recovery.recover(store: store))
        XCTAssertEqual(store.trips.first?.tankSessions, conflicting.tankSessions)
        XCTAssertEqual(store.trips.first?.activeTankNumber, 2)
        XCTAssertNotNil(persistence.load(key: StartTankCommitCoordinator.persistenceKey) as StartTankCommitCoordinator.Journal?)

        var ended = source
        ended.isActive = false
        ended.endTime = Date(timeIntervalSince1970: 400)
        store.trips = [ended]
        XCTAssertFalse(recovery.recover(store: store))
        XCTAssertFalse(store.trips.first?.isActive ?? true)
        XCTAssertTrue(store.trips.first?.tankSessions.isEmpty ?? false)
    }

    func testNewCommitDoesNotOverwriteUnresolvedJournal() throws {
        let (directory, persistence, store, actualStore, source, updated, actual) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        let interrupted = StartTankCommitCoordinator(persistence: persistence, actualStore: actualStore, failurePoint: .afterActual)
        XCTAssertThrowsError(try interrupted.commit(sourceTrip: source, updatedTrip: updated, actual: actual, store: store))
        let original: StartTankCommitCoordinator.Journal? = persistence.load(key: StartTankCommitCoordinator.persistenceKey)

        let coordinator = StartTankCommitCoordinator(persistence: persistence, actualStore: actualStore)
        XCTAssertThrowsError(try coordinator.commit(sourceTrip: source, updatedTrip: updated, actual: actual, store: store))
        let remaining: StartTankCommitCoordinator.Journal? = persistence.load(key: StartTankCommitCoordinator.persistenceKey)
        XCTAssertEqual(remaining?.actualRecordId, original?.actualRecordId)
        XCTAssertEqual(remaining?.tankSessionId, original?.tankSessionId)
    }
}
