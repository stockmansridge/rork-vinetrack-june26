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

    /// Alert Settings threshold editors: the user types the display unit and
    /// the inverse helpers convert it back to canonical mm / km/h / °C. Editing
    /// "1.00 in" saves 25.4 mm, "6.2 mph" ≈ 10 km/h, "68°F" saves 20°C.
    @Test func editingDisplayValuesSavesCanonically() {
        #expect(abs(imperial.rainfallMm(fromDisplay: 1.0) - 25.4) < 1e-9)
        #expect(abs(imperial.speedKmh(fromDisplay: 6.21371192) - 10.0) < 1e-6)
        #expect(abs(imperial.speedKmh(fromDisplay: 6.2) - 10.0) < 0.05)
        #expect(abs(imperial.celsius(fromDisplay: 68) - 20.0) < 1e-9)
        #expect(abs(imperial.celsius(fromDisplay: 32) - 0.0) < 1e-9)
        // Metric editors are pure identities — no conversion applied.
        #expect(metric.rainfallMm(fromDisplay: 25.4) == 25.4)
        #expect(metric.speedKmh(fromDisplay: 10) == 10)
        #expect(metric.celsius(fromDisplay: 20) == 20)
    }

    /// Populate-editor → save round trip: presenting a canonical threshold in
    /// either unit system and converting it straight back never mutates the
    /// stored value, so switching Metric ↔ Imperial is lossless.
    @Test func unitSwitchDoesNotMutateStoredThreshold() {
        for fmt in [metric, imperial] {
            #expect(abs(fmt.rainfallMm(fromDisplay: fmt.rainfallValue(mm: 25.4)) - 25.4) < 1e-9)
            #expect(abs(fmt.speedKmh(fromDisplay: fmt.speedValue(kmh: 10)) - 10.0) < 1e-9)
            #expect(abs(fmt.celsius(fromDisplay: fmt.temperatureValue(celsius: 20)) - 20.0) < 1e-9)
            #expect(abs(fmt.celsius(fromDisplay: fmt.temperatureValue(celsius: -2)) - (-2.0)) < 1e-9)
        }
    }
}
