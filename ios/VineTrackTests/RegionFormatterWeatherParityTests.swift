import Foundation
import Testing
@testable import VineTrack

/// Weather display parity with the Portal: the shared Metric/Imperial
/// Distance setting alone drives rainfall, temperature and wind display.
///
/// Contract (identical on iOS, Android and the Portal):
/// - `distance_unit` metric  → mm, °C, km/h
/// - `distance_unit` imperial → in, °F, mph
///
/// Raw values stay canonical everywhere (mm, Celsius, km/h) — there is no
/// separate temperature/wind/rainfall unit setting, column or RPC argument.
/// These tests pin the display-only conversion so the platforms cannot drift.
struct RegionFormatterWeatherParityTests {

    private let metric = RegionFormatter(
        settings: OrganizationRegionSettings(distanceUnit: DistanceSystem.metric.rawValue)
    )
    private let imperial = RegionFormatter(
        settings: OrganizationRegionSettings(distanceUnit: DistanceSystem.imperial.rawValue)
    )

    @Test func rainfallFollowsDistanceSetting() {
        #expect(metric.formatRainfall(mm: 25.4) == "25.4 mm")
        #expect(imperial.formatRainfall(mm: 25.4) == "1.00 in")
        #expect(metric.rainfallUnitAbbreviation == "mm")
        #expect(imperial.rainfallUnitAbbreviation == "in")
    }

    @Test func temperatureFollowsDistanceSetting() {
        #expect(metric.formatTemperature(celsius: 20) == "20.0°C")
        #expect(imperial.formatTemperature(celsius: 20) == "68.0°F")
        #expect(imperial.formatTemperature(celsius: 0) == "32.0°F")
        #expect(metric.temperatureUnitAbbreviation == "°C")
        #expect(imperial.temperatureUnitAbbreviation == "°F")
        #expect(metric.formatTemperatureRange(minCelsius: 21, maxCelsius: 30) == "21–30°C")
        #expect(imperial.formatTemperatureRange(minCelsius: 21, maxCelsius: 30) == "70–86°F")
    }

    @Test func windSpeedFollowsDistanceSetting() {
        #expect(metric.formatSpeed(kmh: 10) == "10.0 km/h")
        #expect(imperial.formatSpeed(kmh: 10) == "6.2 mph")
        #expect(metric.speedUnitAbbreviation == "km/h")
        #expect(imperial.speedUnitAbbreviation == "mph")
    }

    /// Conversion is display-only: metric value functions are pure identities,
    /// proving canonical stored values are never rebased.
    @Test func conversionIsDisplayOnly() {
        #expect(metric.rainfallValue(mm: 25.4) == 25.4)
        #expect(metric.temperatureValue(celsius: 20) == 20)
        #expect(metric.speedValue(kmh: 10) == 10)
        #expect(imperial.temperatureValue(celsius: 20) == 68)
        #expect(abs(imperial.speedValue(kmh: 10) - 6.21371192) < 1e-6)
        #expect(abs(imperial.rainfallValue(mm: 25.4) - 1.0) < 1e-9)
    }
}
