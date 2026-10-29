import Foundation
import Testing
@testable import VineTrack

struct ChemicalV3SprayRateOptionsTests {
    private static let payload = """
    {
      "per_hectare": [{
        "option_id": "9c12f98e-710a-4f44-9d30-075d3e0043d1",
        "basis": "per_hectare", "unit": "L/ha",
        "min_value": 2.4, "max_value": 3.2, "needs_review": false
      }],
      "per_100_litres": [{
        "option_id": "f01d33d1-2be7-4f49-83e1-5a2f804c2657",
        "basis": "per_100_litres", "unit": "mL/100 L",
        "min_value": 240, "max_value": 320, "needs_review": false
      }]
    }
    """

    @Test("SPRAY.SEED V3 catalogue decodes two independent rate bases and ranges")
    func spraySeedApprovedRates() throws {
        let rates = try JSONDecoder().decode(
            ChemicalV3LabelRateOptions.self, from: Data(Self.payload.utf8))
        #expect(rates.validOptions.count == 2)
        #expect(rates.validOptions[0].sprayBasis == .perHectare)
        #expect(rates.validOptions[0].productUnit == "L")
        #expect(rates.validOptions[0].minValue == 2.4)
        #expect(rates.validOptions[0].maxValue == 3.2)
        #expect(rates.validOptions[1].sprayBasis == .per100Litres)
        #expect(rates.validOptions[1].productUnit == "mL")
        #expect(rates.validOptions[1].minValue == 240)
        #expect(rates.validOptions[1].maxValue == 320)

        var chemical = SavedChemical(name: "SPRAY.SEED 250 Herbicide")
        chemical.chemicalV3RevisionId = UUID(uuidString: "f08dbf08-8294-4488-a961-fc83ea3d9c05")
        chemical.chemicalV3ReviewStatusSnapshot = "approved"
        chemical.chemicalV3LabelRates = rates
        let offered = SprayRegisteredUseRates.vineyardRates(for: chemical)
        #expect(offered.filter { !$0.isRangePreset }.count == 2)
        #expect(offered.contains { $0.basis == .perHectare && $0.labelRangeText?.contains("2.4") == true })
        #expect(offered.contains { $0.basis == .per100Litres && $0.labelRangeText?.contains("240") == true })
        #expect(SprayRegisteredUseRates.defaultSelection(for: chemical, preferring: [.perHectare])?.seed.seedableValue == nil)
    }

    @Test func reopeningHistoricalApplicationKeepsRecordedDoseAndProvenance() {
        let chemical = SavedChemical(name: "Current product")
        let recorded = SprayChemical(name: "Historical product", ratePer100L: 240, unit: .millilitres, rateBasis: .per100Litres)
        let line = SprayConfirmedRateSeeding.restoredLine(for: chemical, recorded: recorded)
        #expect(line.overrideRate == 240)
        #expect(line.basis == .per100Litres)
        #expect(line.operationalRateUnit == "mL")
        #expect(line.operationalRateSource == .savedApplication)
        #expect(recorded.ratePer100L == 240)
    }

    @Test func twoV3BasesDoNotSelectDoseFromCarrierPreference() throws {
        var chemical = SavedChemical(name: "Example")
        chemical.chemicalV3RevisionId = UUID()
        chemical.chemicalV3ReviewStatusSnapshot = "approved"
        chemical.chemicalV3LabelRates = try JSONDecoder().decode(ChemicalV3LabelRateOptions.self, from: Data(Self.payload.utf8))
        let line = SprayConfirmedRateSeeding.seededLine(for: chemical, preferring: [.per100Litres], fallbackBasis: .perHectare)
        #expect(line.overrideRate == nil)
        #expect(SprayRegisteredUseRates.rate(for: chemical, id: line.selectedRateId) == nil)
    }

    @Test("Unapproved V3 options cannot be presented as verified catalogue rates")
    func unapprovedSnapshot() throws {
        var chemical = SavedChemical(name: "Example")
        chemical.chemicalV3RevisionId = UUID()
        chemical.chemicalV3ReviewStatusSnapshot = "pending"
        chemical.rates = [ChemicalRate(label: "Obsolete rate", value: 2400)]
        chemical.chemicalV3LabelRates = try JSONDecoder().decode(
            ChemicalV3LabelRateOptions.self, from: Data(Self.payload.utf8))
        #expect(SprayRegisteredUseRates.vineyardRates(for: chemical).isEmpty)
    }
}
