import Foundation
import Testing
@testable import VineTrack

@MainActor struct SprayForecastWindowsTests {
    private let zone = TimeZone(identifier: "Australia/Sydney")!
    private let now = ISO8601DateFormatter().date(from: "2026-09-24T14:00:00Z")!

    private func period(_ hour: Int, date: String = "2026-09-25", low: Double? = 11,
                        high: Double? = 34, wind: Double? = 14, rain: Double? = 0.1,
                        humidity: Double? = nil) -> SprayForecastPeriod {
        SprayForecastPeriod(date: date, startHour: hour, startTimeLocal: String(format: "%02d:00", hour),
            endTimeLocal: String(format: "%02d:00", hour + 4), tempMinC: low, tempMaxC: high,
            windMaxKmh: wind, humidityMinPct: humidity, humidityMaxPct: humidity,
            rainMm: rain, sampleCount: 4)
    }

    @Test func strictThresholdsAndMissingMeasurements() {
        #expect(SprayForecastWindows.qualifiesOptimal(period(0)))
        #expect(!SprayForecastWindows.qualifiesHighHumidity(period(0)))
        #expect(!SprayForecastWindows.qualifiesOptimal(period(0, low: 10)))
        #expect(!SprayForecastWindows.qualifiesOptimal(period(0, high: 35)))
        #expect(!SprayForecastWindows.qualifiesOptimal(period(0, wind: 15)))
        #expect(!SprayForecastWindows.qualifiesOptimal(period(0, rain: 0.101)))
        #expect(!SprayForecastWindows.qualifiesOptimal(period(0, low: nil)))
        #expect(!SprayForecastWindows.qualifiesOptimal(period(0, high: nil)))
        #expect(!SprayForecastWindows.qualifiesOptimal(period(0, wind: nil)))
        #expect(!SprayForecastWindows.qualifiesOptimal(period(0, rain: nil)))
        #expect(SprayForecastWindows.qualifiesHighHumidity(period(0, humidity: 90)))
        #expect(!SprayForecastWindows.qualifiesHighHumidity(period(0, humidity: 89.9)))
    }

    @Test func sharedFixtureSplitsHumidityAndMergesCrossMidnightWithoutOverlap() {
        let fixture = [period(4), period(8, humidity: 90), period(12),
                       period(16, wind: nil), period(20), period(0, date: "2026-09-26")]
        let windows = SprayForecastWindows.windows(fixture, timezone: zone, now: now)
        #expect(windows.count == 4)
        let times = windows.map { "\(Int($0.start.timeIntervalSince(now) / 3600))-\(Int($0.end.timeIntervalSince(now) / 3600)):\($0.kind)" }
        #expect(times == ["4-8:optimal", "8-12:highHumidity", "12-16:optimal", "20-28:optimal"])
        #expect(windows[3].label(in: zone, now: now).contains("Fri 8:00 pm – Sat 4:00 am"))
        #expect(SprayForecastWindows.windows([period(4), period(8), period(12, humidity: 90)], timezone: zone, now: now).count == 2)
        #expect(SprayForecastWindows.windows([period(4), period(12)], timezone: zone, now: now).count == 2)
    }

    @Test func supplementsNullFieldsWithoutOverwritingPrimaryOrCrossingDays() {
        let primary = period(4, low: 12, wind: nil, rain: nil)
        let result = SprayForecastWindows.supplement([primary], with: [period(4, low: 99, wind: 8, rain: 0), period(4, date: "2026-09-26")])
        #expect(result[0].tempMinC == 12 && result[0].windMaxKmh == 8 && result[0].rainMm == 0)
        #expect(result[1].date == "2026-09-26")
        let cross = SprayForecastWindow(start: ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!,
                                        end: ISO8601DateFormatter().date(from: "2026-09-25T20:00:00Z")!, kind: .optimal)
        #expect(cross.label(in: zone, now: now).contains("Fri 10:00 pm – Sat 6:00 am"))
    }
}
