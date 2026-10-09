import Foundation
import Testing
@testable import VineTrack

@Suite("Crop Sil stored label rates")
struct CropSilRateRegressionTests {
    // Rate fields and conditions supplied from the verified Crop Sil record; no live writes.
    private func chemical() throws -> SavedChemical {
        let payload = #"[{"basis":"range_per_hectare","min_value":3,"max_value":5,"unit":"L/ha","label":"Monthly as required","raw_text":"3–5 L/ha"},{"basis":"range_per_100_litres","min_value":500,"max_value":1000,"unit":"mL/100 L water","label":"If using high volumes of water for foliar sprays","raw_text":"500–1000 mL/100 L water"}]"#
        let rates = try JSONDecoder().decode([ChemicalLabelRate].self, from: Data(payload.utf8))
        return SavedChemical(id: UUID(uuidString: "ae9a8166-a052-41d4-af07-d7bc4de01c9a")!, name: "Crop Sil", unit: .litres,
            chemicalIntelligence: ChemicalIntelligence(registeredUses: [ChemicalRegisteredUse(crop: "Grapevines (viticulture)", targetRaw: "", rates: rates)]))
    }

    @Test func bothBasesOfferCorrectDisplayAndDeliberatePresets() throws {
        let chem = try chemical()
        #expect(!SprayRegisteredUseRates.hasInvalidStructuredRates(chem))
        let rates = SprayRegisteredUseRates.vineyardRates(for: chem)
        #expect(rates.count == 8)
        let area = rates.filter { $0.basis == .perHectare && $0.isRangePreset }
        let volume = rates.filter { $0.basis == .per100Litres && $0.isRangePreset }
        #expect(area.map(\.displayText) == ["3 L/ha", "4 L/ha", "5 L/ha"])
        #expect(area.map { $0.seed.seedableValue } == [3000, 4000, 5000])
        #expect(volume.map(\.displayText) == ["500 mL/100 L", "750 mL/100 L", "1000 mL/100 L"])
        #expect(volume.allSatisfy { $0.menuText.contains("If using high volumes of water for foliar sprays") })
        #expect(Set(rates.map(\.id)).count == rates.count)
        for basis in [ChemicalRateBasis.perHectare, .per100Litres] {
            let selected = try #require(SprayRegisteredUseRates.defaultSelection(for: chem, preferring: basis))
            #expect(selected.requiresOperatorRate && !selected.isRangePreset)
            #expect(selected.seed.seedableValue == nil)
        }
    }

    @Test func chosenAndManualValuesCalculateWithoutThousandFoldErrors() throws {
        let chem = try chemical()
        let rates = SprayRegisteredUseRates.vineyardRates(for: chem)
        let context = SprayQuantityContext(grossAreaHectares: 6, treatedAreaHectares: nil, carrierLitres: 1200, concentrationFactor: 1, rowLengthMetres: nil)
        for (basis, unit, typed, expected) in [(ChemicalRateBasis.perHectare, "L", 4.0, 24000.0), (.per100Litres, "mL", 750.0, 9000.0)] {
            let band = try #require(rates.first { $0.basis == basis && $0.requiresOperatorRate })
            let base = try #require(SprayRegisteredUseRates.baseValue(typed, labelUnit: unit, chemical: chem))
            let midpoint = try #require(rates.first { $0.basis == basis && $0.preset == .midpoint })
            #expect(midpoint.seed.seedableValue == base)
            #expect(SprayLabelRangeCheck.warning(appliedBaseValue: base, rate: band) == nil)
            for endpoint in [band.labelRange?.lowerBound, band.labelRange?.upperBound] {
                #expect(SprayLabelRangeCheck.warning(appliedBaseValue: endpoint, rate: band) == nil)
            }
            #expect(SprayLabelRangeCheck.warning(appliedBaseValue: basis == .perHectare ? 6000 : 1001, rate: band) != nil)
            #expect(SprayProductQuantityCalculator.totalQuantity(rate: base, basis: basis == .perHectare ? .wholeBlockArea : .per100Litres, context: context) == expected)
            #expect(SprayRegisteredUseRates.seedValue(for: chem, rateId: band.id, basis: basis == .perHectare ? .per100Litres : .perHectare) == nil)
        }
    }

    @Test func normalizationPreservesStoredEvidenceAndRejectsContradictions() throws {
        let chem = try chemical()
        let originals = try #require(chem.chemicalIntelligence?.registeredUses.first?.rates)
        for rate in originals {
            let normalized = try #require(ChemicalLabelRateNormalizer.normalize(rate))
            #expect(normalized.rawText == rate.rawText && normalized.label == rate.label && normalized.basis == rate.basis)
            #expect(normalized.rateId == rate.rateId && normalized.conditionIsAmbiguous == rate.conditionIsAmbiguous)
        }
        #expect(originals.map(\.unit) == ["L/ha", "mL/100 L water"])
        let evidence = ChemicalIntelligence(registeredUses: chem.chemicalIntelligence!.registeredUses, fieldProvenance: ["label_rates": "manufacturer_label"])
        #expect(ChemicalLabelRateNormalizer.normalize(evidence)?.fieldProvenance == evidence.fieldProvenance)
        #expect(chem.vineyardPreferredRate == nil)
        var bad = originals[1]; bad.unit = "mL/ha"
        #expect(ChemicalLabelRateNormalizer.normalize(bad) == nil)
        bad = originals[1]; bad.maxValue = 400
        #expect(ChemicalLabelRateNormalizer.normalize(bad) == nil)
        bad = originals[1]; bad.unit = "mL/100 L water or per ha"
        #expect(ChemicalLabelRateNormalizer.normalize(bad) == nil)
        var unsafe = chem
        unsafe.chemicalIntelligence?.registeredUses[0].rates[1] = bad
        #expect(SprayRegisteredUseRates.hasInvalidStructuredRates(unsafe))
    }

    @Test func explicitEquivalentNotationsOnly() {
        for text in ["500–1000 mL/100 L water", "500–1000 mL per 100 litres of water", "500–1000 mL / 100\tL water"] {
            #expect(ChemicalLabelRateNormalizer.parse(text)?.basis == .rangePer100Litres)
        }
        #expect(ChemicalLabelRateNormalizer.parse("3–5 L per hectare")?.unit == "L")
        for text in ["3–5 L/ha water", "500 mL/100 L or ha", "500 mL/100 L concentrate", "5–3 L/ha", "500 mL/200 L water"] {
            #expect(ChemicalLabelRateNormalizer.parse(text) == nil)
        }
    }
}
