import CoreLocation
import XCTest
@testable import VineTrack

final class TrailDisplayProcessorTests: XCTestCase {
    private let displayCap = 500

    func testGeneratedRoutesFollowCompleteRouteDisplayContract() {
        for count in [100, 2_000, 5_000, 20_000] {
            let source = makeRoute(count: count)
            let original = source
            let displayed = TrailDisplayProcessor.makeDisplayPoints(
                points: source,
                maxDisplayPoints: displayCap
            )
            print("route-display full=\(count) displayed=\(displayed.count)")

            if count <= displayCap {
                XCTAssertEqual(displayed, source, "Routes below the cap must remain complete")
            } else {
                XCTAssertLessThanOrEqual(displayed.count, displayCap)
            }
            XCTAssertEqual(displayed.first, source.first)
            XCTAssertEqual(displayed.last, source.last)
            XCTAssertTrue(containsProgress(0.25, in: displayed), "Missing first-quarter section for \(count) points")
            XCTAssertTrue(containsProgress(0.50, in: displayed), "Missing middle section for \(count) points")
            XCTAssertTrue(containsProgress(0.75, in: displayed), "Missing third-quarter section for \(count) points")
            XCTAssertEqual(displayed.map(\.latitude).min(), source.map(\.latitude).min())
            XCTAssertEqual(displayed.map(\.latitude).max(), source.map(\.latitude).max())
            XCTAssertEqual(displayed.map(\.longitude).min(), source.map(\.longitude).min())
            XCTAssertEqual(displayed.map(\.longitude).max(), source.map(\.longitude).max())
            XCTAssertEqual(source, original, "Display processing must not mutate persisted path points")
        }
    }

    func testTwentyThousandPointRouteRepresentsBeginningMiddleAndEnd() {
        let source = makeRoute(count: 20_000)
        let displayed = TrailDisplayProcessor.makeDisplayPoints(
            points: source,
            maxDisplayPoints: displayCap
        )

        XCTAssertEqual(displayed.first, source.first)
        XCTAssertTrue(displayed.contains { $0.longitude < 149.02 })
        XCTAssertTrue(displayed.contains { $0.longitude > 149.09 && $0.longitude < 149.11 })
        XCTAssertTrue(displayed.contains { $0.longitude > 149.18 })
    }

    func testMapRenderingStaysWithinPointAndPolylineCaps() {
        let source = makeRoute(count: 20_000)
        let segments = TrailDisplayProcessor.makeDisplayTrailSegments(
            points: source,
            maxDisplayPoints: displayCap,
            maxColourBuckets: 5
        )

        XCTAssertLessThanOrEqual(segments.count, 5)
        XCTAssertLessThanOrEqual(segments.reduce(0) { $0 + $1.coordinates.count }, displayCap)
        XCTAssertEqual(segments.first?.coordinates.first?.longitude, source.first?.longitude)
        XCTAssertEqual(segments.last?.coordinates.last?.longitude, source.last?.longitude)
        for index in 1..<segments.count {
            XCTAssertEqual(
                segments[index - 1].coordinates.last?.longitude,
                segments[index].coordinates.first?.longitude,
                "Colour buckets must join into one continuous route"
            )
        }
    }

    func testSprayDetailPreparationBoundsAffectedAndLargeRoutesWithoutMutation() {
        for count in [8_330, 20_000] {
            let source = makeRoute(count: count)
            let original = source
            let startedAt = CFAbsoluteTimeGetCurrent()
            let segments = SprayDetailTrailDisplayPreparation.makeSegments(points: source)
            let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            let coordinates = segments.flatMap(\.coordinates)

            print(String(format: "spray-detail-display full=%d displayed=%d overlays=%d preparation_ms=%.3f", count, coordinates.count, segments.count, elapsedMilliseconds))
            XCTAssertLessThanOrEqual(coordinates.count, SprayDetailTrailDisplayPreparation.maxDisplayPoints)
            XCTAssertLessThanOrEqual(segments.count, SprayDetailTrailDisplayPreparation.maxColourBuckets)
            XCTAssertEqual(coordinates.first?.latitude, source.first?.latitude)
            XCTAssertEqual(coordinates.first?.longitude, source.first?.longitude)
            XCTAssertEqual(coordinates.last?.latitude, source.last?.latitude)
            XCTAssertEqual(coordinates.last?.longitude, source.last?.longitude)
            XCTAssertEqual(coordinates.map(\.latitude).min(), source.map(\.latitude).min())
            XCTAssertEqual(coordinates.map(\.latitude).max(), source.map(\.latitude).max())
            XCTAssertEqual(coordinates.map(\.longitude).min(), source.map(\.longitude).min())
            XCTAssertEqual(coordinates.map(\.longitude).max(), source.map(\.longitude).max())
            XCTAssertEqual(source, original)
            for index in 1..<segments.count {
                XCTAssertEqual(segments[index - 1].coordinates.last?.latitude, segments[index].coordinates.first?.latitude)
                XCTAssertEqual(segments[index - 1].coordinates.last?.longitude, segments[index].coordinates.first?.longitude)
            }
        }
    }

    func testSprayDetailPreparationHandlesEmptyAndSinglePointRoutes() {
        XCTAssertTrue(SprayDetailTrailDisplayPreparation.makeSegments(points: []).isEmpty)
        XCTAssertTrue(SprayDetailTrailDisplayPreparation.makeSegments(points: makeRoute(count: 1)).isEmpty)
    }

    func testSprayDetailPreparationRefreshesForSameCountCoordinateChanges() {
        let source = makeRoute(count: 8_330)
        var changed = source
        let changedIndex = changed.count / 2
        changed[changedIndex] = CoordinatePoint(
            id: changed[changedIndex].id,
            latitude: -34.5,
            longitude: 150.5
        )

        let initial = SprayDetailTrailDisplayPreparation.makeSegments(points: source).flatMap(\.coordinates)
        let refreshed = SprayDetailTrailDisplayPreparation.makeSegments(points: changed).flatMap(\.coordinates)

        XCTAssertEqual(source.count, changed.count)
        XCTAssertNotEqual(initial.map(\.latitude), refreshed.map(\.latitude))
        XCTAssertTrue(refreshed.contains { $0.latitude == -34.5 && $0.longitude == 150.5 })
        XCTAssertFalse(initial.contains { $0.latitude == -34.5 && $0.longitude == 150.5 })
    }

    private func makeRoute(count: Int) -> [CoordinatePoint] {
        (0..<count).map { index in
            let progress = count > 1 ? Double(index) / Double(count - 1) : 0
            var latitude = -33.0 + sin(progress * .pi * 8.0) * 0.01
            if index == count / 3 { latitude = -33.03 }
            if index == (count * 2) / 3 { latitude = -32.97 }
            return CoordinatePoint(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID(),
                latitude: latitude,
                longitude: 149.0 + progress * 0.2
            )
        }
    }

    private func containsProgress(_ progress: Double, in points: [CoordinatePoint]) -> Bool {
        let expectedLongitude = 149.0 + progress * 0.2
        return points.contains { abs($0.longitude - expectedLongitude) < 0.01 }
    }
}
