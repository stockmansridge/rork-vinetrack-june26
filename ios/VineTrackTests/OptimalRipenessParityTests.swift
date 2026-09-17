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

    func testWarmCachePlansOnlyThreeRecentCompletedDays() throws {
        let service = DegreeDayService(timeZone: TimeZone(identifier: "UTC")!)
        let values = Dictionary(uniqueKeysWithValues: (1...10).map { day in
            (String(format: "202609%02d", day), DailyTemp(high: 20, low: 10))
        })
        service.installDailyTemps(values, for: source)
        let start = try date("2026-09-01T00:00:00Z")
        let end = try date("2026-09-11T00:00:00Z")

        let planned = service.refreshDates(forKey: source.sourceKey, coveringFrom: start, to: end)

        XCTAssertEqual(planned.map(dayKey), ["20260908", "20260909", "20260910"])
        XCTAssertEqual(planned.count, DegreeDayService.recentCompletedDayRefreshCount)
    }

    func testRefreshPlanIncludesMissingDateAndRecentOverlapWithoutHistoricalRows() throws {
        let service = DegreeDayService(timeZone: TimeZone(identifier: "UTC")!)
        var values = Dictionary(uniqueKeysWithValues: (1...10).map { day in
            (String(format: "202609%02d", day), DailyTemp(high: 20, low: 10))
        })
        values.removeValue(forKey: "20260904")
        service.installDailyTemps(values, for: source)
        let start = try date("2026-09-01T00:00:00Z")
        let end = try date("2026-09-11T00:00:00Z")

        let planned = service.refreshDates(forKey: source.sourceKey, coveringFrom: start, to: end)

        XCTAssertEqual(planned.map(dayKey), ["20260904", "20260908", "20260909", "20260910"])
    }

    func testRevisedRecentProviderRowReplacesCacheAndRecalculatesGDD() throws {
        let service = DegreeDayService(timeZone: TimeZone(identifier: "UTC")!)
        let davis = GDDSource.davisWeatherLink(stationId: "revision-isolation")
        let values = Dictionary(uniqueKeysWithValues: (1...5).map { day in
            (String(format: "202609%02d", day), DailyTemp(high: 20, low: 10))
        })
        service.installDailyTemps(values, for: source)
        service.installDailyTemps(["20260905": DailyTemp(high: 12, low: 8)], for: davis)
        let start = try date("2026-09-01T00:00:00Z")
        let end = try date("2026-09-06T00:00:00Z")
        let before = service.dailyGDDSeries(stationId: source.sourceKey, from: start, to: end, latitude: nil, useBEDD: false)

        service.applyRefreshOutcome(["20260905": DailyTemp(high: 30, low: 20)], for: source)
        let after = service.dailyGDDSeries(stationId: source.sourceKey, from: start, to: end, latitude: nil, useBEDD: false)

        XCTAssertEqual(before.last?.cumulative, 25)
        XCTAssertEqual(after.last?.cumulative, 35)
        XCTAssertEqual(service.dailyTemp(forKey: "20260905", source: source)?.high, 30)
        XCTAssertEqual(service.dailyTemp(forKey: "20260905", source: davis)?.high, 12)
    }

    func testFailedOverlapRefreshPreservesPreviousCalculation() throws {
        let service = DegreeDayService(timeZone: TimeZone(identifier: "UTC")!)
        let values = Dictionary(uniqueKeysWithValues: (1...5).map { day in
            (String(format: "202609%02d", day), DailyTemp(high: 20, low: 10))
        })
        service.installDailyTemps(values, for: source)
        let start = try date("2026-09-01T00:00:00Z")
        let end = try date("2026-09-06T00:00:00Z")
        let before = service.dailyGDDSeries(stationId: source.sourceKey, from: start, to: end, latitude: nil, useBEDD: false)

        service.applyRefreshOutcome(nil, for: source)
        let after = service.dailyGDDSeries(stationId: source.sourceKey, from: start, to: end, latitude: nil, useBEDD: false)

        XCTAssertEqual(after.map(\.daily), before.map(\.daily))
        XCTAssertEqual(after.last?.cumulative, 25)
        XCTAssertEqual(service.dailyTemp(forKey: "20260905", source: source)?.high, 20)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
