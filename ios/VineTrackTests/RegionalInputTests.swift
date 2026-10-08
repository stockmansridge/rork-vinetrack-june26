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
            #expect(abs((rate.resolve(String(fmt.volumePerAreaValue(litresPerHectare: 500)), inverse: fmt.volumePerAreaToCanonical) ?? 0) - 500) < 1e-9)
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
            sprayRatePerHa: rate.resolve(String(fmt.volumePerAreaValue(litresPerHectare: 500)), inverse: fmt.volumePerAreaToCanonical) ?? 0, concentrationFactor: 2.5)
        let replay = try JSONDecoder().decode(SavedSprayPreset.self, from: JSONEncoder().encode(preset))
        #expect(replay.waterVolume == 1500.123456)
        #expect(abs(replay.sprayRatePerHa - 500) < 1e-9)
        #expect(replay.concentrationFactor == 2.5)
    }

    @Test func seedingInputsCacheCanonicalDepthAndRates() throws {
        let formatter = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", areaUnit: AreaUnit.acres.rawValue, distanceUnit: DistanceSystem.imperial.rawValue))
        let rate = RegionalInput(canonical: 20.123456789, forward: formatter.perAreaValue)
        let depth = RegionalInput(canonical: 2.54123456789, forward: formatter.smallLengthValue)
        #expect(rate.resolve(rate.text, inverse: formatter.perAreaToCanonical) == 20.123456789)
        #expect(depth.resolve(depth.text, inverse: formatter.smallLengthToCanonical) == 2.54123456789)
        let details = SeedingDetails(frontBox: SeedingBox(ratePerHa: rate.resolve("10", inverse: formatter.perAreaToCanonical), seedVolumeKg: 40), sowingDepthCm: depth.resolve("2", inverse: formatter.smallLengthToCanonical))
        let restored = try JSONDecoder().decode(SeedingDetails.self, from: JSONEncoder().encode(details))
        #expect(abs((restored.frontBox?.ratePerHa ?? 0) - 24.71053814672) < 1e-9)
        #expect(restored.frontBox?.seedVolumeKg == 40)
        #expect(abs((restored.sowingDepthCm ?? 0) - 5.08) < 1e-9)
    }

    @Test func untouchedGeometryAndIrrigationPreserveExactCanonicalPrecision() throws {
        for fmt in [RegionFormatter.australian, RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", volumeUnit: "gallons", distanceUnit: "imperial"))] {
            for metres in [315.75, 3.2123456789, 0.123456789, 1.23456789, 6.123456789, 0.6123456789] {
                let seed = RegionalInput(canonical: metres, forward: fmt.lengthValue)
                #expect(seed.resolve(seed.text, inverse: fmt.lengthToCanonical) == metres)
                let edited = try #require(seed.resolve(String(fmt.lengthValue(metres: 2.75)), inverse: fmt.lengthToCanonical))
                #expect(abs(edited - 2.75) < 1e-9)
            }
            let flow = RegionalInput(canonical: 2.123456789, forward: fmt.volumeValue)
            #expect(flow.resolve(flow.text, inverse: fmt.volumeToCanonical) == 2.123456789)
        }
    }

    @Test func emptyAndInvalidInputsRemainUnavailable() {
        let input = RegionalInput(canonical: nil, forward: { $0 })
        #expect(input.resolve("", inverse: { $0 }) == nil)
        #expect(input.resolve("nan", inverse: { $0 }) == nil)
        #expect(input.resolve("inf", inverse: { $0 }) == nil)
        #expect(input.resolve("1,25", inverse: { $0 }) == 1.25)
    }
}
