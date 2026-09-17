import XCTest
@testable import VineTrack

@MainActor
final class OptimalRipenessParityTests: XCTestCase {
    private let source = GDDSource.openMeteoArchive(latitude: -33.28, longitude: 149.10)

    func testSharedFixedSeriesHasCanonicalDailyContributionsCumulativeValuesAndTotal() throws {
        let service = DegreeDayService(timeZone: TimeZone(identifier: "UTC")!)
        service.installDailyTemps([
            "20260901": DailyTemp(high: 20, low: 10),
            "20260902": DailyTemp(high: 24, low: 12),
            "20260903": DailyTemp(high: 18, low: 8),
            "20260904": DailyTemp(high: 30, low: 14),
        ], for: source)
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-05T00:00:00Z"))

        let points = service.dailyGDDSeries(
            stationId: source.sourceKey,
            from: start,
            to: end,
            latitude: nil,
            useBEDD: false
        )

        XCTAssertEqual(points.map(\.daily), [5, 8, 3, 12])
        XCTAssertEqual(points.map(\.cumulative), [5, 13, 16, 28])
        XCTAssertEqual(points.last?.cumulative, 28)
        XCTAssertTrue(service.hasCompleteData(forKey: source.sourceKey, coveringFrom: start, to: end))
    }

    func testProviderCachesCannotCombineInOneCalculation() throws {
        let service = DegreeDayService(timeZone: TimeZone(identifier: "UTC")!)
        let davis = GDDSource.davisWeatherLink(stationId: "station-1")
        service.installDailyTemps(["20260901": DailyTemp(high: 30, low: 20)], for: davis)
        service.installDailyTemps(["20260902": DailyTemp(high: 12, low: 8)], for: source)
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-03T00:00:00Z"))

        let davisPoints = service.dailyGDDSeries(stationId: davis.sourceKey, from: start, to: end, latitude: nil, useBEDD: false)
        let openMeteoPoints = service.dailyGDDSeries(stationId: source.sourceKey, from: start, to: end, latitude: nil, useBEDD: false)

        XCTAssertTrue(davisPoints.allSatisfy { $0.daily == 15 })
        XCTAssertTrue(openMeteoPoints.allSatisfy { $0.daily == 0 })
        XCTAssertFalse(service.hasCompleteData(forKey: davis.sourceKey, coveringFrom: start, to: end))
        XCTAssertFalse(service.hasCompleteData(forKey: source.sourceKey, coveringFrom: start, to: end))
    }
}
