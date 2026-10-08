import Foundation
import Testing
@testable import VineTrack

@MainActor
struct RegionResidualBoundaryTests {
    private var us: RegionFormatter {
        RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", currencyCode: "USD", areaUnit: AreaUnit.acres.rawValue, volumeUnit: VolumeUnit.gallons.rawValue, distanceUnit: "imperial", fuelUnit: FuelUnit.gallons.rawValue, sprayRateAreaUnit: SprayRateAreaUnit.acre.rawValue))
    }

    @Test func fuelCorrectionRoundTripAndUntouchedPrecision() {
        for fmt in [RegionFormatter.australian, us] {
            let seed = RegionalInput(canonical: 12.1234567890123, forward: fmt.fuelValue)
            #expect(seed.resolve(seed.text, inverse: fmt.fuelToCanonical) == seed.canonical)
            #expect(abs((seed.resolve(String(fmt.fuelValue(litres: 25)), inverse: fmt.fuelToCanonical) ?? 0) - 25) < 1e-10)
            let boundary = seed.resolve(String(fmt.fuelValue(litres: 1000)), inverse: fmt.fuelToCanonical) ?? 0
            #expect(abs(boundary - 1000) < 1e-9)
            #expect((seed.resolve("1000", inverse: us.fuelToCanonical) ?? 0) > 1000)
        }
    }

    @Test func canopyCalibrationRoundTripSeedAndCanonicalDefaults() {
        for fmt in [RegionFormatter.australian, us] {
            let value = 42.1234567890123
            let seed = RegionalInput(canonical: value, forward: fmt.volumePer100LengthValue)
            #expect(seed.resolve(seed.text, inverse: fmt.volumePer100LengthToCanonical) == value)
            let edited = seed.resolve(String(fmt.volumePer100LengthValue(60)), inverse: fmt.volumePer100LengthToCanonical) ?? 0
            #expect(abs(edited - 60) < 1e-9)
            #expect(abs(CanopyWaterRate.litresPerHa(litresPer100m: edited, rowSpacingMetres: 3) - 2000) < 1e-7)
            #expect(fmt.formatLength(metres: 3).contains(fmt.lengthUnitAbbreviation))
        }
        #expect(us.volumePer100LengthUnit == "gal/100 ft")
        #expect(CanopyWaterRateEntry.defaults.mediumLow > 0)
    }

    @Test func irrigationEmitterRoundTripKeepsCanonicalDerivedRate() {
        for fmt in [RegionFormatter.australian, us] {
            let flow = RegionalInput(canonical: 2.1234567890123, forward: fmt.volumeValue)
            let spacing = RegionalInput(canonical: 0.61234567890123, forward: fmt.lengthValue)
            #expect(flow.resolve(flow.text, inverse: fmt.volumeToCanonical) == flow.canonical)
            #expect(spacing.resolve(spacing.text, inverse: fmt.lengthToCanonical) == spacing.canonical)
            let editedFlow = flow.resolve(String(fmt.volumeValue(litres: 4)), inverse: fmt.volumeToCanonical) ?? 0
            let editedSpacing = spacing.resolve(String(fmt.lengthValue(metres: 0.5)), inverse: fmt.lengthToCanonical) ?? 0
            #expect(abs(editedFlow / (3 * editedSpacing) - 2.6666666666666665) < 1e-9)
        }
    }

    @Test func damageAreaAndSprayCostsUseRegionalPresentationWithoutFx() {
        #expect(RegionFormatter.australian.formatArea(hectares: 2.1) == "2.10 ha")
        #expect(us.formatArea(hectares: 2.1) == "5.19 ac")
        for (country, currency, symbol) in [("AU", "AUD", "$"), ("US", "USD", "$"), ("GB", "GBP", "£")] {
            let fmt = RegionFormatter(settings: OrganizationRegionSettings(countryCode: country, currencyCode: currency))
            #expect(fmt.formatCurrency(42.5).contains(symbol))
            #expect(fmt.formatCurrency(42.5).contains("42.50"))
        }
    }

    @Test func sprayReferenceUsesRegionalCarrierAndGeometryOnly() {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .foliarSpray
        inputs.blocks = [SprayBlockInput(blockId: "block", grossAreaHectares: 10, mappedRowLengthMetres: 31250, rowSpacingMetres: 3.2)]
        inputs.targets = [.powderyMildew]
        inputs.sprayHeadTarget = .fullCanopy
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.tankCapacityLitres = 2000
        inputs.carrierBasis = .manualTotalVolume
        inputs.manualTotalLitres = 400
        let flow = SprayGuidedFlow(inputs: inputs)
        let au = SprayCalculationReferenceBuilder.make(flow: flow, formatter: .australian)
        let regional = SprayCalculationReferenceBuilder.make(flow: flow, formatter: us)
        #expect(au.water.first { $0.id == "totalWater" }?.value == RegionFormatter.australian.formatVolume(litres: 400))
        #expect(regional.water.first { $0.id == "totalWater" }?.value == us.formatVolume(litres: 400))
        #expect(regional.water.first { $0.id == "treatedArea" }?.value == us.formatArea(hectares: 10))
        #expect(regional.water.first { $0.id == "impliedPerHa" }?.value == us.formatVolumePerArea(litresPerHectare: 40))
        var canopy = SprayCanopySelection.unconfirmed
        canopy.choose(type: .vsp)
        canopy.choose(size: .medium)
        canopy.choose(density: .high)
        inputs.canopy = canopy
        inputs.canopyWaterRates = .defaults
        inputs.carrierBasis = .litresPerHectare
        inputs.sprayVolumeChoice = .useCustomSprayerRate
        inputs.customSprayerBasis = .litresPerHectare
        inputs.customSprayerRate = 600
        let calibrated = SprayGuidedFlow(inputs: inputs)
        let calibratedReference = SprayCalculationReferenceBuilder.make(flow: calibrated, formatter: us)
        #expect(calibratedReference.canopy.first { $0.id == "recommendedPer100m" }?.value.contains("gal/100 ft") == true)
        #expect(calibratedReference.canopy.first { $0.id == "rowSpacing" }?.value == us.formatLength(metres: 3.2))
        #expect(calibratedReference.volume.first { $0.id == "actualOutput" }?.value == us.formatVolumePerArea(litresPerHectare: 600))
        #expect(regional.products == au.products)
        #expect(flow.carrier?.totalLitres == 400)
    }
}
