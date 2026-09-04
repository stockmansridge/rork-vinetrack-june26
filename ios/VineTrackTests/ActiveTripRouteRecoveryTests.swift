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
