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

    func testDailyContributionsNeverGoNegativeAndTotalsUseUnroundedValues() throws {
        let service = DegreeDayService(timeZone: TimeZone(identifier: "UTC")!)
        service.installDailyTemps([
            "20260901": DailyTemp(high: 8.2, low: 1.4),
            "20260902": DailyTemp(high: 23.33, low: 10.11),
        ], for: source)
        let start = try date("2026-09-01T00:00:00Z")
        let end = try date("2026-09-03T00:00:00Z")

        let points = service.dailyGDDSeries(
            stationId: source.sourceKey,
            from: start,
            to: end,
            latitude: nil,
            useBEDD: false
        )

        XCTAssertEqual(points[0].daily, 0)
        XCTAssertEqual(points[1].daily, 6.72, accuracy: 0.000_001)
        XCTAssertEqual(points.last?.cumulative ?? -1, points.reduce(0) { $0 + $1.daily }, accuracy: 0.000_001)
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

    func testCapturedDavisResponseMatchesAndroidDailyAndCumulativeGDD() throws {
        let service = DegreeDayService(timeZone: try XCTUnwrap(TimeZone(identifier: "Australia/Sydney")))
        let source = GDDSource.davisWeatherLink(stationId: "123345")
        let fixture: [[String: Any]] = [
            ["sensor_type": 23, "data": [
                ["ts": 1_789_480_800, "temp_hi": 77.0, "temp_lo": 51.8],
                ["ts": 1_789_567_200, "temp_hi": 75.2, "temp_lo": 50.0],
                ["ts": 1_789_653_600, "temp_hi": 73.4, "temp_lo": 48.2],
                ["ts": 1_789_740_000, "temp_hi": 71.6, "temp_lo": 50.0],
                ["ts": 1_789_826_400, "temp_hi": 69.8, "temp_lo": 48.2],
                ["ts": 1_789_912_800, "temp_hi": 68.0, "temp_lo": 50.0],
                ["ts": 1_789_916_400, "temp_avg": 90.0, "temp_last": 90.0],
                ["ts": 1_789_917_000, "temp_hi": NSNull(), "temp_lo": NSNull()],
            ]],
            ["sensor_type": 27, "data": [["ts": 1_789_480_800, "temp_hi": 95.0, "temp_lo": 80.0]]],
        ]
        let records = DavisWeatherLinkService.parseHistoricTemperatures(sensorsArr: fixture)
        XCTAssertEqual(records.count, 6)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        var highs: [String: Double] = [:]
        var lows: [String: Double] = [:]
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"
        for (timestamp, highF, lowF) in records {
            let key = formatter.string(from: timestamp)
            let highC = (highF - 32) * 5 / 9
            let lowC = (lowF - 32) * 5 / 9
            highs[key] = max(highs[key] ?? -.greatestFiniteMagnitude, highC)
            lows[key] = min(lows[key] ?? .greatestFiniteMagnitude, lowC)
        }
        service.installDailyTemps(
            highs.reduce(into: [String: DailyTemp]()) { values, pair in
                if let low = lows[pair.key] { values[pair.key] = DailyTemp(high: pair.value, low: low) }
            },
            for: source
        )
        let start = try date("2026-09-15T14:00:00Z")
        let end = try date("2026-09-21T14:00:00Z")
        let points = service.dailyGDDSeries(stationId: source.sourceKey, from: start, to: end, latitude: -33.28, useBEDD: false)

        let expected: [Double] = [8, 7, 6, 6, 5, 5]
        XCTAssertEqual(points.count, expected.count)
        for (point, value) in zip(points, expected) {
            XCTAssertEqual(point.daily, value, accuracy: 0.000_001)
        }
        XCTAssertEqual(points.reduce(0) { $0 + $1.daily }, 37, accuracy: 0.000_001)
        XCTAssertEqual(points.last?.cumulative ?? -1, points.reduce(0) { $0 + $1.daily }, accuracy: 0.000_001)
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
