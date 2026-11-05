import Foundation
import Testing
import CoreLocation
@testable import VineTrack

@MainActor
struct ActiveTripHistoryPerformanceTests {
    @Test func offMainPreparationMatchesOriginalAndSkipsUnchangedRoute() async {
        for count in [0, 1, 2, 9, 100, 2_000, 10_000, 60_000] {
            let points = (0..<count).map {
                CoordinatePoint(latitude: -35 + sin(Double($0) / 30) * 0.001, longitude: 149 + Double($0) * 0.000001)
            }
            let expected = TrailDisplayProcessor.makeDisplayTrailSegments(points: points)
            let preparation = ActiveTripTrailPreparation()
            let id = UUID()
            #expect(preparation.request(tripID: id, points: points))
            // Another tick while work is in flight must not enqueue another worker.
            #expect(!preparation.request(tripID: id, points: points))
            await preparation.waitForPreparation()
            #expect(preparation.lastWorkerWasOffMain)
            #expect(preparation.completedPreparations == 1)
            #expect(!preparation.request(tripID: id, points: points))
            #expect(preparation.segments.count == expected.count)
            for (actual, original) in zip(preparation.segments, expected) {
                #expect(actual.coordinates.map(\.latitude) == original.coordinates.map(\.latitude))
                #expect(actual.coordinates.map(\.longitude) == original.coordinates.map(\.longitude))
                #expect(actual.color == original.color)
            }
            var appended = points
            appended.append(CoordinatePoint(latitude: -34, longitude: 150))
            #expect(preparation.request(tripID: id, points: appended))
            await preparation.waitForPreparation()
            #expect(preparation.fullCount == count + 1)
            #expect(preparation.completedPreparations == 2)
        }
    }

    @Test func cancelledAndSwitchedTripsNeverPublishOldWork() async {
        let points = (0..<60_000).map { CoordinatePoint(latitude: Double($0) / 1_000_000, longitude: 149) }
        let preparation = ActiveTripTrailPreparation()
        #expect(preparation.request(tripID: UUID(), points: points))
        preparation.stop()
        await preparation.waitForPreparation()
        #expect(preparation.segments.isEmpty)
        #expect(preparation.completedPreparations == 0)
        #expect(preparation.request(tripID: UUID(), points: points))
        let replacement = [CoordinatePoint(latitude: -35, longitude: 149), CoordinatePoint(latitude: -34, longitude: 150)]
        #expect(preparation.request(tripID: UUID(), points: replacement))
        await preparation.waitForPreparation()
        #expect(preparation.fullCount == 2)
        #expect(preparation.completedPreparations == 1)
        #expect(preparation.segments.first?.coordinates.first?.latitude == -35)
    }

    @Test func historySizedAtomicPersistenceAndTrailBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trip-perf-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let repository = TripRepository(persistence: persistence)
        let vineyard = UUID()
        for count in [100, 2_000, 10_000, 60_000] {
            var trip = Trip(vineyardId: vineyard, startTime: Date(timeIntervalSince1970: 1_700_000_000), pathPoints: (0..<count).map {
                CoordinatePoint(latitude: -35 + Double($0 % 200) * 0.00001, longitude: 149 + Double($0 / 200) * 0.00001)
            }, isActive: true)
            try repository.saveSliceOrThrow([trip], for: vineyard)
            var saveTimes: [Double] = []
            var trailTimes: [Double] = []
            for step in 0..<3 {
                trip.pathPoints.append(CoordinatePoint(latitude: -35 + Double(step) * 0.00002, longitude: 149))
                let start = ProcessInfo.processInfo.systemUptime
                try repository.saveSliceOrThrow([trip], for: vineyard)
                saveTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                let trailStart = ProcessInfo.processInfo.systemUptime
                let segments = TrailDisplayProcessor.makeDisplayTrailSegments(points: trip.pathPoints)
                trailTimes.append((ProcessInfo.processInfo.systemUptime - trailStart) * 1000)
                #expect(segments.reduce(0) { $0 + $1.coordinates.count } <= 500)
                #expect(segments.count <= 5)
            }
            let loaded = TripRepository(persistence: PersistenceStore(directory: directory)).loadAll()
            #expect(loaded == [trip])
            #expect(loaded.first?.pathPoints.count == count + 3)
            print("P0_HISTORY points=\(count) atomic_save_main_ms=\(saveTimes) trail_main_ms=\(trailTimes) samples=3; sized history, not a complete point-by-point soak")
        }
    }
}
