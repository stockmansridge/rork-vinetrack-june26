import Foundation
import Testing
@testable import VineTrack

@MainActor
struct ScoutReportRegionTests {
    @Test func reportWeatherUsesRegionAndVineyardClockWithoutChangingSnapshot() throws {
        let observed = try #require(ISO8601DateFormatter().date(from: "2026-01-02T02:30:00Z"))
        let weather = ScoutWeatherSnapshot(observedAt: observed, capturedAt: observed, source: "Station",
            temperatureCelsius: 20.125, humidityPercent: 55, windSpeedKph: 12.345,
            windGustKph: 20, recentRainfallMm: 3.25, isStale: true)
        for zone in ["Australia/Sydney", "America/Los_Angeles", "Pacific/Auckland"] {
            let fmt = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", timezone: zone, distanceUnit: "imperial"))
            let text = ScoutReportPDFService.weatherText(weather, formatter: fmt)
            #expect(text.contains(fmt.formatTemperature(celsius: 20.125)))
            #expect(text.contains(fmt.formatSpeed(kmh: 12.345)))
            #expect(text.contains(fmt.formatDateTime(observed)))
            #expect(text.contains("STALE") && text.contains("Station"))
        }
        #expect(weather.temperatureCelsius == 20.125)
        #expect(weather.windSpeedKph == 12.345)
        #expect(weather.observedAt == observed)
    }
}
