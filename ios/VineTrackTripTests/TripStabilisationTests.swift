import Foundation
import XCTest
@testable import VineTrack

@MainActor final class AuthoritativeCompletionRepository: TripSyncRepositoryProtocol {
    private let completed: BackendTrip
    private(set) var uploaded: [BackendTripUpsert] = []

    init(completed: BackendTrip) { self.completed = completed }

    func upsertTrips(_ trips: [BackendTripUpsert]) async throws { uploaded += trips }
    func upsertTrip(_ trip: BackendTripUpsert) async throws { uploaded.append(trip) }
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { [completed] }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [completed] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { [completed] }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {}
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {}
    func softDeleteTrip(id: UUID) async throws {}
}

@MainActor
final class TripStabilisationTests: XCTestCase {
    private let vineyardId = UUID(uuidString: "81000000-0000-4000-8000-000000000001")!
    private let tripId = UUID(uuidString: "81000000-0000-4000-8000-000000000010")!
    private let startedAt = Date(timeIntervalSince1970: 1_780_000_120)
    private let endedAt = Date(timeIntervalSince1970: 1_780_000_600)

    private func activeTrip() -> Trip {
        Trip(id: tripId, vineyardId: vineyardId, paddockName: "Disposable test block", isActive: true, totalTanks: 2)
    }

    func testStaleEndedTankReconcilesWithoutChangingSessionsOrRoute() {
        var trip = activeTrip()
        trip.tankSessions = [TankSession(tankNumber: 1, startTime: startedAt, endTime: endedAt)]
        trip.activeTankNumber = 1
        let originalSessions = trip.tankSessions
        let originalRoute = trip.pathPoints
        let repaired = TankSessionLifecycle.reconciled(trip)
        XCTAssertNil(repaired.activeTankNumber)
        XCTAssertTrue(repaired.isActive)
        XCTAssertEqual(repaired.tankSessions, originalSessions)
        XCTAssertEqual(repaired.pathPoints, originalRoute)
        XCTAssertEqual(TripEndGate.evaluate(trip: repaired), .allowed)
        XCTAssertEqual(TankSessionLifecycle.reconciled(repaired), repaired)
    }

    func testOpenTankRemainsBlockedUntilEnded() {
        let started = TankSessionLifecycle.start(trip: activeTrip(), at: startedAt, currentRow: nil, plannedTankNumbers: [1, 2])
        XCTAssertEqual(TankSessionLifecycle.reconciled(started), started)
        let decision = TripEndGate.evaluate(trip: started)
        XCTAssertEqual(decision, .blocked(.activeTank(tankNumber: 1)))
        XCTAssertEqual(decision.blocker?.requiredAction, "Tap End Tank to close it, then end the trip.")
        let ended = TankSessionLifecycle.end(trip: started, at: endedAt, currentRow: nil)
        XCTAssertNil(ended.activeTankNumber)
        XCTAssertEqual(TripEndGate.evaluate(trip: ended), .allowed)
    }

    func testTwoTankLifecycleReusesNoEndedTankAndEndsOnce() {
        let first = TankSessionLifecycle.start(trip: activeTrip(), at: startedAt, currentRow: nil, plannedTankNumbers: [1, 2])
        let endedFirst = TankSessionLifecycle.end(trip: first, at: endedAt, currentRow: nil)
        let second = TankSessionLifecycle.start(trip: endedFirst, at: endedAt.addingTimeInterval(60), currentRow: nil, plannedTankNumbers: [1, 2])
        XCTAssertEqual(second.activeTankNumber, 2)
        XCTAssertEqual(second.tankSessions.count, 2)
        XCTAssertEqual(second.tankSessions[0], endedFirst.tankSessions[0])
        let endedSecond = TankSessionLifecycle.end(trip: second, at: endedAt.addingTimeInterval(120), currentRow: nil)
        XCTAssertEqual(TripEndGate.evaluate(trip: endedSecond), .allowed)
        XCTAssertEqual(TankSessionLifecycle.start(trip: endedSecond, at: endedAt.addingTimeInterval(180), currentRow: nil, plannedTankNumbers: [1, 2]), endedSecond)
    }

    func testEndTripAutoClosesSecondTankBeforeTripMayEnd() {
        let firstStarted = TankSessionLifecycle.start(
            trip: activeTrip(), at: startedAt, currentRow: nil, plannedTankNumbers: [1, 2]
        )
        let firstEnded = TankSessionLifecycle.end(
            trip: firstStarted, at: startedAt.addingTimeInterval(80), currentRow: nil
        )
        let secondStarted = TankSessionLifecycle.start(
            trip: firstEnded, at: startedAt.addingTimeInterval(120),
            currentRow: nil, plannedTankNumbers: [1, 2]
        )
        XCTAssertEqual(TripEndGate.evaluate(trip: secondStarted), .blocked(.activeTank(tankNumber: 2)))
        let endRequestedAt = startedAt.addingTimeInterval(190)
        let ready = TankSessionLifecycle.endRunningTankBeforeTripEnd(
            trip: secondStarted, at: endRequestedAt, currentRow: 74.5
        )
        XCTAssertNil(ready.activeTankNumber)
        XCTAssertEqual(ready.tankSessions.count, 2)
        XCTAssertEqual(ready.tankSessions[0].endTime, firstEnded.tankSessions[0].endTime)
        XCTAssertEqual(ready.tankSessions[1].endTime, endRequestedAt)
        XCTAssertEqual(TripEndGate.evaluate(trip: ready), .allowed)
        XCTAssertTrue(ready.isActive) // Local tank persist happens BEFORE Trip End.
        XCTAssertNil(ready.endTime)
        XCTAssertEqual(
            TankSessionLifecycle.endRunningTankBeforeTripEnd(
                trip: ready, at: endRequestedAt.addingTimeInterval(5), currentRow: 75.5
            ),
            ready
        )
    }

    func testEndTripNeverAutoClosesRunningFillOrAmbiguousTankSessions() {
        let first = TankSessionLifecycle.start(
            trip: activeTrip(), at: startedAt, currentRow: nil, plannedTankNumbers: [1, 2]
        )
        var filling = first
        filling.isFillingTank = true
        filling.fillingTankNumber = 1
        let unchanged = TankSessionLifecycle.endRunningTankBeforeTripEnd(
            trip: filling, at: endedAt, currentRow: nil
        )
        XCTAssertEqual(unchanged, filling)
        XCTAssertFalse(TripEndGate.evaluate(trip: unchanged).isAllowed)

        var ambiguous = first
        ambiguous.tankSessions.append(TankSession(
            tankNumber: 2, startTime: startedAt.addingTimeInterval(10)
        ))
        XCTAssertEqual(
            TankSessionLifecycle.endRunningTankBeforeTripEnd(
                trip: ambiguous, at: endedAt, currentRow: nil
            ),
            ambiguous
        )
        XCTAssertFalse(TripEndGate.evaluate(trip: ambiguous).isAllowed)
    }

    func testOfflineEndedTankSurvivesLocalReloadAndEncodesExplicitNull() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let closed = TankSessionLifecycle.end(
            trip: TankSessionLifecycle.start(trip: activeTrip(), at: startedAt, currentRow: nil, plannedTankNumbers: [1, 2]),
            at: endedAt, currentRow: nil
        )
        TripRepository(persistence: PersistenceStore(directory: directory)).saveSlice([closed], for: vineyardId)
        let relaunched = try XCTUnwrap(TripRepository(persistence: PersistenceStore(directory: directory)).load(for: vineyardId).first)
        XCTAssertEqual(relaunched.tankSessions, closed.tankSessions)
        XCTAssertNil(relaunched.activeTankNumber)
        let payload = BackendTrip.upsert(from: relaunched, createdBy: nil, clientUpdatedAt: endedAt)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertTrue(json["active_tank_number"] is NSNull)
        XCTAssertEqual((json["tank_sessions"] as? [[String: Any]])?.count, 1)
    }

    func testFreeDriveAddedBlocksRemainInScopeAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocks = ["A", "B", "C"].map { Paddock(vineyardId: vineyardId, name: $0) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyardId
        store.paddocks = blocks
        var trip = activeTrip()
        trip.paddockId = blocks[0].id
        trip.paddockIds = [blocks[0].id]
        trip.isPaused = true
        store.startTrip(trip)
        store.claimDeviceTrip(trip.id)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        XCTAssertTrue(tracking.addPaddocksToActiveTrip([blocks[1].id, blocks[2].id]))
        let expanded = try XCTUnwrap(store.trips.first { $0.id == trip.id })
        XCTAssertTrue(expanded.rowSequence.isEmpty)
        XCTAssertEqual(Set(expanded.paddockIds), Set(blocks.map(\.id)))
        let reloaded = try XCTUnwrap(TripRepository(persistence: PersistenceStore(directory: directory)).load(for: vineyardId).first { $0.id == trip.id })
        XCTAssertEqual(Set(reloaded.paddockIds), Set(blocks.map(\.id)))
        XCTAssertEqual(reloaded.paddockId, blocks[0].id)
    }

    func testDirtyActiveTripYieldsToServerCompletionAndNeverReopens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        let blockA = UUID()
        let blockB = UUID()
        var local = activeTrip()
        local.paddockId = blockA
        local.paddockIds = [blockA, blockB]
        local.pathPoints = [CoordinatePoint(latitude: -41.0, longitude: 174.0), CoordinatePoint(latitude: -41.1, longitude: 174.1)]
        local.totalDistance = 810
        local.tankSessions = [TankSession(tankNumber: 1, startTime: startedAt, endTime: endedAt)]
        local.completedPaths = [0.5]
        local.skippedPaths = [1.5]
        store.startTrip(local)
        store.claimDeviceTrip(tripId)
        let metadata = TripSyncMetadata(persistence: persistence)
        metadata.markDirty(tripId, at: endedAt.addingTimeInterval(300))

        var server = local
        server.isActive = false
        server.endTime = endedAt
        server.pathPoints = []
        server.totalDistance = 0
        server.tankSessions = []
        server.paddockIds = [blockA]
        let serverRow = try JSONDecoder().decode(BackendTrip.self, from: JSONEncoder().encode(
            BackendTrip.upsert(from: server, createdBy: nil, clientUpdatedAt: endedAt)
        ))
        let repository = AuthoritativeCompletionRepository(completed: serverRow)
        let service = TripSyncService(repository: repository, metadata: metadata)
        let auth = NewBackendAuthService()
        auth.isSignedIn = true
        service.configure(store: store, auth: auth)

        try await service.pushLocalTrips(vineyardId: vineyardId)
        let completed = try XCTUnwrap(store.trips.first { $0.id == tripId })
        XCTAssertFalse(completed.isActive)
        XCTAssertEqual(completed.endTime, endedAt)
        XCTAssertEqual(completed.pathPoints, local.pathPoints)
        XCTAssertEqual(completed.totalDistance, local.totalDistance)
        XCTAssertEqual(completed.tankSessions, local.tankSessions)
        XCTAssertEqual(completed.completedPaths, local.completedPaths)
        XCTAssertEqual(completed.skippedPaths, local.skippedPaths)
        XCTAssertEqual(Set(completed.paddockIds), Set(local.paddockIds))
        XCTAssertNil(store.deviceActiveTripId)
        // The server's End wins: the Trip is never reopened and never re-uploaded. The server row carries none of
        // this device's route, tank session or block evidence, so the original queue entry is deliberately retained
        // under a durable TRIP_LOCAL_EVIDENCE_DIFFERS hold instead of being silently retired.
        XCTAssertNotNil(metadata.pendingUpserts[tripId])
        XCTAssertTrue(metadata.failedUpsertIds.contains(tripId))
        let firstUploads = await repository.uploaded
        XCTAssertTrue(firstUploads.isEmpty)

        try await service.pushLocalTrips(vineyardId: vineyardId)
        let replayUploads = await repository.uploaded
        XCTAssertTrue(replayUploads.isEmpty)
        // The retained entry is durable: it survives a relaunch and is still never uploaded.
        XCTAssertNotNil(TripSyncMetadata(persistence: PersistenceStore(directory: directory)).pendingUpserts[tripId])
        let reloaded = try XCTUnwrap(TripRepository(persistence: PersistenceStore(directory: directory)).load(for: vineyardId).first { $0.id == tripId })
        XCTAssertEqual(reloaded.pathPoints, local.pathPoints)
        XCTAssertEqual(reloaded.tankSessions, local.tankSessions)
        XCTAssertNil(MigratedDataStore(persistence: PersistenceStore(directory: directory)).deviceActiveTripId)

        let next = Trip(id: UUID(), vineyardId: vineyardId, paddockName: "Next test block", isActive: true, totalTanks: 1)
        store.startTrip(next)
        store.claimDeviceTrip(next.id)
        XCTAssertEqual(store.deviceActiveTripId, next.id)
        metadata.markDirty(next.id, at: Date())
        try await service.pushLocalTrips(vineyardId: vineyardId)
        let uploaded = await repository.uploaded
        XCTAssertEqual(uploaded.map(\.id), [next.id])
        XCTAssertTrue(uploaded[0].isActive)
        XCTAssertNil(metadata.pendingUpserts[next.id])
    }

    func testPortalEndTankIsAdoptedBeforeOfflineTripUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        let tank1End = startedAt.addingTimeInterval(60)
        let tank2Start = startedAt.addingTimeInterval(75)
        let administratorEnd = startedAt.addingTimeInterval(180)
        var local = activeTrip()
        local.tankSessions = [
            TankSession(tankNumber: 1, startTime: startedAt, endTime: tank1End),
            TankSession(tankNumber: 2, startTime: tank2Start)
        ]
        local.activeTankNumber = 2
        local.pathPoints = [CoordinatePoint(latitude: -33.15, longitude: 148.86)]
        local.totalDistance = 9019.5
        store.startTrip(local)
        store.claimDeviceTrip(local.id)
        let metadata = TripSyncMetadata(persistence: persistence)
        metadata.markDirty(tripId, at: administratorEnd.addingTimeInterval(5))

        var server = local
        server.tankSessions[1].endTime = administratorEnd
        server.activeTankNumber = nil
        server.pathPoints = []
        server.totalDistance = 0
        let serverRow = try JSONDecoder().decode(BackendTrip.self, from: JSONEncoder().encode(
            BackendTrip.upsert(from: server, createdBy: nil, clientUpdatedAt: administratorEnd)
        ))
        let repository = AuthoritativeCompletionRepository(completed: serverRow)
        let service = TripSyncService(repository: repository, metadata: metadata)
        let auth = NewBackendAuthService()
        auth.isSignedIn = true
        service.configure(store: store, auth: auth)

        try await service.pushLocalTrips(vineyardId: vineyardId)
        let adopted = try XCTUnwrap(store.trips.first { $0.id == tripId })
        XCTAssertTrue(adopted.isActive) // A Portal End Tank does not end the Trip.
        XCTAssertNil(adopted.activeTankNumber)
        XCTAssertEqual(adopted.tankSessions.count, 2)
        XCTAssertEqual(adopted.tankSessions[0].endTime, tank1End)
        XCTAssertEqual(adopted.tankSessions[1].endTime, administratorEnd)
        XCTAssertEqual(adopted.pathPoints, local.pathPoints)
        XCTAssertEqual(adopted.totalDistance, local.totalDistance)
        let uploaded = await repository.uploaded
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertNil(uploaded[0].activeTankNumber)
        XCTAssertEqual(uploaded[0].tankSessions[1].endTime, administratorEnd)
        XCTAssertEqual(uploaded[0].pathPoints, local.pathPoints)
    }

    func testPortalEndTripAdoptsTankEndAndStopsOwnedDeviceWithoutLosingRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyardId
        let tank1End = startedAt.addingTimeInterval(60)
        let tank2Start = startedAt.addingTimeInterval(75)
        let adminTankEnd = startedAt.addingTimeInterval(180)
        let adminTripEnd = startedAt.addingTimeInterval(190)
        var local = activeTrip()
        local.tankSessions = [
            TankSession(tankNumber: 1, startTime: startedAt, endTime: tank1End),
            TankSession(tankNumber: 2, startTime: tank2Start)
        ]
        local.activeTankNumber = 2
        local.pathPoints = [CoordinatePoint(latitude: -33.15, longitude: 148.86)]
        local.totalDistance = 9019.5
        store.startTrip(local)
        store.claimDeviceTrip(local.id)
        let metadata = TripSyncMetadata(persistence: persistence)
        metadata.markDirty(tripId, at: adminTripEnd.addingTimeInterval(20))

        var server = local
        server.tankSessions[1].endTime = adminTankEnd
        server.activeTankNumber = nil
        server.isActive = false
        server.endTime = adminTripEnd
        server.pathPoints = []
        server.totalDistance = 0
        let serverRow = try JSONDecoder().decode(BackendTrip.self, from: JSONEncoder().encode(
            BackendTrip.upsert(from: server, createdBy: nil, clientUpdatedAt: adminTripEnd)
        ))
        let repository = AuthoritativeCompletionRepository(completed: serverRow)
        let service = TripSyncService(repository: repository, metadata: metadata)
        let auth = NewBackendAuthService()
        auth.isSignedIn = true
        service.configure(store: store, auth: auth)
        try await service.pushLocalTrips(vineyardId: vineyardId)

        let adopted = try XCTUnwrap(store.trips.first { $0.id == tripId })
        XCTAssertFalse(adopted.isActive)
        XCTAssertEqual(adopted.endTime, adminTripEnd)
        XCTAssertNil(adopted.activeTankNumber)
        XCTAssertEqual(adopted.tankSessions[0].endTime, tank1End)
        XCTAssertEqual(adopted.tankSessions[1].endTime, adminTankEnd)
        XCTAssertEqual(adopted.pathPoints, local.pathPoints)
        XCTAssertEqual(adopted.totalDistance, local.totalDistance)
        XCTAssertNil(store.deviceActiveTripId)
        let uploads = await repository.uploaded
        XCTAssertTrue(uploads.isEmpty) // Never replay stale active state.
        // The original unacknowledged route is still held, rather than
        // falsely claiming it was uploaded by the Portal correction.
        XCTAssertNotNil(metadata.pendingUpserts[tripId])
    }

    func testServerTankEndRejectsMismatchedTankIdentity() {
        var local = activeTrip()
        let original = TankSession(tankNumber: 2, startTime: startedAt)
        local.activeTankNumber = 2
        local.tankSessions = [original]
        var remote = local
        remote.activeTankNumber = nil
        remote.tankSessions[0].endTime = endedAt
        XCTAssertNotNil(TankPathAttribution.adoptingServerTankEnds(local: local, remote: remote))
        remote.tankSessions[0].tankNumber = 1
        XCTAssertNil(TankPathAttribution.adoptingServerTankEnds(local: local, remote: remote))
    }

    func testAuthoritativeServerCompletionReleasesOwnedTripAndRetainsHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        store.selectedVineyardId = vineyardId
        let trip = activeTrip()
        store.startTrip(trip)
        store.claimDeviceTrip(trip.id)
        XCTAssertEqual(store.deviceActiveTripId, trip.id)
        var completed = trip
        completed.isActive = false
        completed.endTime = endedAt
        store.applyRemoteTripUpsert(completed)
        XCTAssertNil(store.deviceActiveTripId)
        XCTAssertEqual(store.trips.first(where: { $0.id == trip.id })?.endTime, endedAt)
        XCTAssertFalse(store.trips.first(where: { $0.id == trip.id })?.isActive ?? true)
        XCTAssertNil(MigratedDataStore(persistence: PersistenceStore(directory: directory)).deviceActiveTripId)
    }
}
