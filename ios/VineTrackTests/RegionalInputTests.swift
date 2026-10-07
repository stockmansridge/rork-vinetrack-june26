import Foundation
import Testing
@testable import VineTrack

@MainActor
struct RegionalInputTests {
    @Test func auAndUsWaterAndCarrierRoundTrips() {
        let au = RegionFormatter.australian
        let us = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", areaUnit: AreaUnit.acres.rawValue, volumeUnit: VolumeUnit.gallons.rawValue, distanceUnit: "imperial", sprayRateAreaUnit: SprayRateAreaUnit.acre.rawValue))
        for fmt in [au, us] {
            let water = RegionalInput(canonical: 1500.123456789, forward: { fmt.volumeValue(litres: $0) })
            #expect(water.resolve(water.text, inverse: fmt.volumeToCanonical) == 1500.123456789)
            let edited = water.resolve(String(fmt.volumeValue(litres: 2000)), inverse: fmt.volumeToCanonical) ?? 0
            #expect(abs(edited - 2000) < 1e-9)
            let rate = RegionalInput(canonical: 750.123456789, forward: fmt.volumePerAreaValue)
            #expect(rate.resolve(rate.text, inverse: fmt.volumePerAreaToCanonical) == 750.123456789)
            #expect(abs((rate.resolve(String(fmt.volumePerAreaValue(500)), inverse: fmt.volumePerAreaToCanonical) ?? 0) - 500) < 1e-9)
        }
    }

    @Test func compoundSoilCapacityKeepsCanonicalMath() {
        let fmt = RegionFormatter(settings: OrganizationRegionSettings(distanceUnit: "imperial"))
        #expect(fmt.soilWaterCapacityUnit == "in/ft")
        #expect(abs(fmt.soilWaterCapacityValue(150) - 1.8) < 1e-8)
        let awc = RegionalInput(canonical: 150.123456, forward: fmt.soilWaterCapacityValue)
        #expect(awc.resolve(awc.text, inverse: fmt.soilWaterCapacityToCanonical) == 150.123456)
        let depth = RegionalInput(canonical: 0.654321, forward: { fmt.lengthValue(metres: $0) })
        #expect(depth.resolve(depth.text, inverse: fmt.lengthToCanonical) == 0.654321)
        let editedAwc = awc.resolve(String(fmt.soilWaterCapacityValue(180)), inverse: fmt.soilWaterCapacityToCanonical) ?? 0
        let editedDepth = depth.resolve(String(fmt.lengthValue(metres: 0.8)), inverse: fmt.lengthToCanonical) ?? 0
        #expect(abs(editedAwc * editedDepth - 144) < 1e-9)
    }

    @Test func presetCacheReplayKeepsCanonicalValuesAndConcentration() throws {
        let fmt = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", volumeUnit: VolumeUnit.gallons.rawValue, sprayRateAreaUnit: SprayRateAreaUnit.acre.rawValue))
        let water = RegionalInput(canonical: 1500.123456, forward: { fmt.volumeValue(litres: $0) })
        let rate = RegionalInput(canonical: 750.123456, forward: fmt.volumePerAreaValue)
        let preset = SavedSprayPreset(name: "Test", waterVolume: water.resolve(water.text, inverse: fmt.volumeToCanonical) ?? 0,
            sprayRatePerHa: rate.resolve(String(fmt.volumePerAreaValue(500)), inverse: fmt.volumePerAreaToCanonical) ?? 0, concentrationFactor: 2.5)
        let replay = try JSONDecoder().decode(SavedSprayPreset.self, from: JSONEncoder().encode(preset))
        #expect(replay.waterVolume == 1500.123456)
        #expect(abs(replay.sprayRatePerHa - 500) < 1e-9)
        #expect(replay.concentrationFactor == 2.5)
    }

    @Test func emptyAndInvalidInputsRemainUnavailable() {
        let input = RegionalInput(canonical: nil, forward: { $0 })
        #expect(input.resolve("", inverse: { $0 }) == nil)
        #expect(input.resolve("nan", inverse: { $0 }) == nil)
        #expect(input.resolve("inf", inverse: { $0 }) == nil)
        #expect(input.resolve("1,25", inverse: { $0 }) == 1.25)
    }
}
