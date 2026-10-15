import XCTest
@testable import VineTrack

@MainActor
final class ActiveTripRouteRecoveryTests: XCTestCase {
    func testFiveThousandPointActiveTripSurvivesRelaunchAndDisplayProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-trip-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vineyardId = UUID()
        let tripId = UUID()
        let source = makeRoute(count: 5_000)
        let expectedDistance = 42_750.25
        let initialStore = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        initialStore.selectedVineyardId = vineyardId
        initialStore.startTrip(Trip(
            id: tripId,
            vineyardId: vineyardId,
            paddockName: "Recovery block",
            pathPoints: source,
            isActive: true,
            totalDistance: expectedDistance
        ))

        let relaunchedStore = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        relaunchedStore.selectedVineyardId = vineyardId
        relaunchedStore.reloadCurrentVineyardData()
        let restored = try XCTUnwrap(relaunchedStore.trips.first { $0.id == tripId })

        XCTAssertEqual(restored.id, tripId)
        XCTAssertTrue(restored.isActive)
        XCTAssertEqual(restored.totalDistance, expectedDistance, accuracy: 0.000_001)
        XCTAssertEqual(restored.pathPoints.count, 5_000)
        XCTAssertEqual(restored.pathPoints.first, source.first)
        XCTAssertEqual(restored.pathPoints[2_500], source[2_500])
        XCTAssertEqual(restored.pathPoints.last, source.last)

        let beforeDisplay = restored.pathPoints
        let displayed = TrailDisplayProcessor.makeDisplayPoints(points: restored.pathPoints)
        XCTAssertLessThanOrEqual(displayed.count, 500)
        XCTAssertEqual(restored.pathPoints, beforeDisplay)
        XCTAssertEqual(relaunchedStore.trips.first?.pathPoints.count, 5_000)
    }

    func testShorterRemoteActiveRouteCannotReplaceLongerRestoredLocalRoute() throws {
        let vineyardId = UUID()
        let tripId = UUID()
        let localPath = makeRoute(count: 5_000)
        let remotePath = Array(localPath.prefix(2_000))
        let local = Trip(
            id: tripId,
            vineyardId: vineyardId,
            paddockName: "Recovery block",
            pathPoints: localPath,
            isActive: true,
            totalDistance: 42_750.25
        )
        let remote = Trip(
            id: tripId,
            vineyardId: vineyardId,
            paddockName: "Recovery block",
            pathPoints: remotePath,
            isActive: true,
            totalDistance: 17_100.10
        )

        let reconciled = ActiveTripPathReconciler.reconcile(local: local, remote: remote)

        XCTAssertEqual(reconciled.id, tripId)
        XCTAssertTrue(reconciled.isActive)
        XCTAssertEqual(reconciled.totalDistance, local.totalDistance, accuracy: 0.000_001)
        XCTAssertEqual(reconciled.pathPoints, localPath)
        XCTAssertEqual(reconciled.pathPoints.count, 5_000)
    }

    func testPlaceholderPullCannotAcknowledgeOwnedActivation() async throws {
        try await assertTerminalPull(endTime: nil)
    }

    func testCompletedPullRetainsEqualLengthDivergentEvidenceWithoutReopening() async throws {
        try await assertTerminalPull(endTime: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func assertTerminalPull(endTime: Date?) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let local = Trip(vineyardId: vineyard, pathPoints: makeRoute(count: 4), isActive: true)
        store.startTrip(local)
        store.claimDeviceTrip(local.id)
        var remote = local
        remote.isActive = false
        remote.endTime = endTime
        remote.pathPoints = [CoordinatePoint(latitude: 10, longitude: 20)] + Array(local.pathPoints.dropFirst())
        let repository = FakeTripSyncRepository()
        repository.remoteTrips = [try JSONDecoder().decode(BackendTrip.self,
            from: JSONEncoder().encode(BackendTrip.upsert(from: remote, createdBy: nil, clientUpdatedAt: Date())))]
        let metadata = TripSyncMetadata(persistence: persistence)
        let service = TripSyncService(repository: repository, metadata: metadata)
        let auth = NewBackendAuthService()
        service.configure(store: store, auth: auth)
        metadata.markDirty(local.id, at: Date())
        try await service.pullRemoteTrips(vineyardId: vineyard)
        let retained = try XCTUnwrap(store.trips.first { $0.id == local.id })
        XCTAssertEqual(retained.pathPoints, local.pathPoints)
        XCTAssertNotNil(metadata.pendingUpserts[local.id], "A placeholder or missing evidence is not acknowledgement")
        if endTime == nil {
            XCTAssertTrue(retained.isActive)
            XCTAssertEqual(store.deviceActiveTripId, local.id)
            try await service.pushLocalTrips(vineyardId: vineyard)
            XCTAssertEqual(repository.pushed.count, 1)
            XCTAssertEqual(repository.pushed.first?.id, local.id)
            XCTAssertEqual(repository.pushed.first?.isActive, true, "The accepted inactive parent must not suppress its original activation")
        } else {
            XCTAssertFalse(retained.isActive)
            XCTAssertEqual(retained.endTime, endTime)
            XCTAssertNil(store.deviceActiveTripId)
            try await service.pushLocalTrips(vineyardId: vineyard)
            XCTAssertTrue(repository.pushed.isEmpty, "Never reopen or patch completed history to resolve evidence")
        }
    }

    private func makeRoute(count: Int) -> [CoordinatePoint] {
        (0..<count).map { index in
            CoordinatePoint(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index)) ?? UUID(),
                latitude: -33.0 + Double(index) * 0.000_001,
                longitude: 149.0 + Double(index) * 0.000_002
            )
        }
    }
}
