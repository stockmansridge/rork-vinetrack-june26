import Foundation
import Testing
@testable import VineTrack

@MainActor
struct SprayRegionClosureTests {
    private var us: RegionFormatter {
        RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", areaUnit: "acres", volumeUnit: "gallons", distanceUnit: "imperial", sprayRateAreaUnit: "acre"))
    }

    @Test func weatherEditsAndUntouchedSeedsRemainCanonical() {
        for fmt in [RegionFormatter.australian, us] {
            let temperature = RegionalInput(canonical: 21.123456789, forward: fmt.temperatureValue)
            let wind = RegionalInput(canonical: 12.123456789, forward: fmt.speedValue)
            let speed = RegionalInput(canonical: 6.123456789, forward: fmt.speedValue)
            #expect(temperature.resolve(temperature.text, inverse: fmt.celsius) == 21.123456789)
            #expect(wind.resolve(wind.text, inverse: fmt.speedKmh) == 12.123456789)
            #expect(speed.resolve(speed.text, inverse: fmt.speedKmh) == 6.123456789)
            #expect(abs((temperature.resolve(String(fmt.temperatureValue(celsius: 30)), inverse: fmt.celsius) ?? 0) - 30) < 1e-9)
            #expect(abs((wind.resolve(String(fmt.speedValue(kmh: 20)), inverse: fmt.speedKmh) ?? 0) - 20) < 1e-9)
        }
        #expect(us.temperatureValue(celsius: 20) == 68)
        #expect(abs(us.speedKmh(fromDisplay: 10) - 16.09344) < 1e-8)
    }

    @Test func guidedCarrierAndTankAreaAreConverted() {
        let au = SprayGuidedFormat(formatter: .australian)
        let local = SprayGuidedFormat(formatter: us)
        #expect(au.hectares(2.1) == "2.10 ha")
        #expect(local.hectares(2.1) == "5.19 ac")
        #expect(local.litres(100).contains("gal"))
        #expect(local.litresPerHectare(500).contains("gal/ac"))
        #expect(local.litresPer100m(40).contains("gal/100 ft"))
        #expect(local.metres(100).contains("328 ft"))
        #expect(local.carrierBasisLabel(.litresPerHectare) == "gal/ac")
        #expect(local.volumeSourceLabel(.litresPer100Metres) == "gal/100 ft")
        #expect(local.hectares(nil) == "—")
    }

    @Test func irrigationAdviceChangesUnitsNotRecommendations() throws {
        let soil = SoilProfileInputs(irrigationSoilClass: "sand_loamy_sand", availableWaterCapacityMmPerM: 70, effectiveRootDepthM: 0.4, managementAllowedDepletionPercent: 40, modelVersion: "test")
        let days = [ForecastDay(date: Date(timeIntervalSince1970: 0), forecastEToMm: 80, forecastRainMm: 0)]
        let settings = IrrigationSettings(irrigationApplicationRateMmPerHour: 4, cropCoefficientKc: 0.7, irrigationEfficiencyPercent: 90, rainfallEffectivenessPercent: 80, replacementPercent: 100, soilMoistureBufferMm: 0)
        let au = try #require(IrrigationCalculator.calculate(forecastDays: days, settings: settings, soil: soil, soilAwareV2Enabled: true))
        let local = try #require(IrrigationCalculator.calculate(forecastDays: days, settings: settings, soil: soil, soilAwareV2Enabled: true, formatter: us))
        #expect(au.v2?.soilAdjustedGrossMm == local.v2?.soilAdjustedGrossMm)
        #expect(au.recommendedIrrigationMinutes == local.recommendedIrrigationMinutes)
        #expect(local.v2?.adjustmentReason?.contains("in") == true)
        #expect(local.v2?.adjustmentReason?.contains("mm") == false)
        #expect(local.soilAdviceText?.contains(us.formatRainfall(mm: 11.2)) == true)
    }

    @Test func carrierRatesConvertBothDimensionsAndPreserveSeeds() {
        for fmt in [RegionFormatter.australian, us] {
            let areaRate = RegionalInput(canonical: 500.123456789, forward: fmt.volumePerAreaValue)
            let lengthRate = RegionalInput(canonical: 40.123456789, forward: fmt.volumePer100LengthValue)
            #expect(areaRate.resolve(areaRate.text, inverse: fmt.volumePerAreaToCanonical) == 500.123456789)
            #expect(lengthRate.resolve(lengthRate.text, inverse: fmt.volumePer100LengthToCanonical) == 40.123456789)
            #expect(abs(fmt.volumePer100LengthToCanonical(fmt.volumePer100LengthValue(40)) - 40) < 1e-9)
            #expect(abs(fmt.volumePerAreaToCanonical(fmt.volumePerAreaValue(litresPerHectare: 500)) - 500) < 1e-9)
        }
        #expect(abs(us.volumePer100LengthValue(40) - us.volumeValue(litres: 40) / us.lengthValue(metres: 1)) < 1e-12)
        #expect(abs(us.volumePerAreaValue(litresPerHectare: 500) - 53.45331826273184) < 1e-7)
    }
}
