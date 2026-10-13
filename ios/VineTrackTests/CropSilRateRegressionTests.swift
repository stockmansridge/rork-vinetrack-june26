import Foundation
import Testing
@testable import VineTrack

@Suite("Crop Sil stored label rates")
struct CropSilRateRegressionTests {
    // Exact rate fields supplied by the user, inside a synthetic REST envelope.
    // The full live registered-use object remains unavailable; no production reads/writes.
    private let payload = #"{"id":"ae9a8166-a052-41d4-af07-d7bc4de01c9a","vineyard_id":"11111111-1111-4111-8111-111111111111","name":"Crop Sil","unit":"Litres","registered_uses":[{"crop":"Grapevines (viticulture)","target_raw":"","rates":[{"basis":"range_per_hectare","min_value":3,"max_value":5,"unit":"L/ha","condition":"Monthly as required","raw_text":"3-5L"},{"basis":"range_per_100_litres","min_value":500,"max_value":1000,"unit":"mL/100 L water","condition":"If using high volumes of water for foliar sprays","raw_text":"500-1000mls/100L water"}]}]}"#

    private func chemical() throws -> SavedChemical {
        try JSONDecoder().decode(BackendSavedChemical.self, from: Data(payload.utf8)).toSavedChemical()
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
            #expect(normalized.condition == rate.condition)
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

    @Test @MainActor func backendCacheEditAndSyncProjectionPreserveExistingRates() throws {
        let original = try chemical()
        let uses = try #require(original.chemicalIntelligence?.registeredUses)
        #expect(uses[0].rates.map(\.condition) == ["Monthly as required", "If using high volumes of water for foliar sprays"])
        #expect(uses[0].rates.map(\.rawText) == ["3-5L", "500-1000mls/100L water"])
        let ids = SprayRegisteredUseRates.vineyardRates(for: original).map(\.id)
        var draft = ChemicalManualEntry.draft(from: original, fallbackCountry: "NZ")
        draft.productName = "Edited display name"
        let proposed = ChemicalManualEntry.proposedIntelligence(from: draft, existing: original.chemicalIntelligence)
        #expect(proposed.registeredUses == uses)
        #expect(ChemicalLabelRateNormalizer.normalize(proposed)?.registeredUses == uses)
        var edited = original
        edited.chemicalIntelligence = proposed
        edited.notes = "An unrelated note"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SprayRepository(persistence: PersistenceStore(directory: directory))
        repository.saveChemicalsSlice([edited], for: edited.vineyardId)
        let reopened = try #require(SprayRepository(persistence: PersistenceStore(directory: directory)).loadChemicals(for: edited.vineyardId).first)
        #expect(reopened.chemicalIntelligence?.registeredUses == uses)
        #expect(SprayRegisteredUseRates.vineyardRates(for: reopened).map(\.id) == ids)
        let outbound = BackendSavedChemical.upsert(from: reopened, createdBy: nil, clientUpdatedAt: Date())
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(outbound)) as? [String: Any])
        let outboundUses = try JSONDecoder().decode([ChemicalRegisteredUse].self, from: JSONSerialization.data(withJSONObject: try #require(json["registered_uses"])))
        #expect(outboundUses == uses)
    }

    @Test func legacyLabelsSeparateConditionsUnknownEvidenceAndUnsupportedBasis() throws {
        let text = #"[{"crop":"Grapes","target_raw":"Powdery mildew","target":"future_target","withholding_statement":"Original historical wording","future_use":{"a":[1,null,true]},"rates":[{"basis":"per_hectare","value":2,"unit":"L/ha","label":"Description","condition":"Only before flowering","raw_text":"  2 L/ha  ","rate_id":"unchanged-server-id","future_rate":{"evidence":"original"}},{"basis":"per_100_litres","value":100,"unit":"mL","label":"Legacy condition"}]}]"#
        let uses = try JSONDecoder().decode([ChemicalRegisteredUse].self, from: Data(text.utf8))
        let reloaded = try JSONDecoder().decode([ChemicalRegisteredUse].self, from: JSONEncoder().encode(uses))
        #expect(reloaded == uses)
        #expect(reloaded[0].rates[0].label == "Description")
        #expect(reloaded[0].rates[0].applicationCondition == "Only before flowering")
        #expect(reloaded[0].rates[1].applicationCondition == "Legacy condition")
        #expect(reloaded[0].unknownFields["future_use"] != nil)
        #expect(reloaded[0].unknownFields["target"] == .string("future_target"))
        #expect(reloaded[0].unknownFields["withholding_statement"] != nil)
        #expect(reloaded[0].rates[0].unknownFields["future_rate"] != nil)
        let unsupported = try JSONDecoder().decode(ChemicalLabelRate.self, from: Data(#"{"basis":"per_vine_future","value":2,"unit":"L","raw_text":"2 L/ha"}"#.utf8))
        #expect(ChemicalLabelRateNormalizer.normalize(unsupported) == nil)
        #expect(try JSONDecoder().decode(ChemicalLabelRate.self, from: JSONEncoder().encode(unsupported)).unsupportedBasis == "per_vine_future")
    }

    @Test @MainActor func explicitSelectionFreezesRateConditionAndQuantityInRecord() throws {
        let chem = try chemical()
        let offered = SprayRegisteredUseRates.vineyardRates(for: chem)
        let context = SprayQuantityContext(grossAreaHectares: 6, treatedAreaHectares: nil, carrierLitres: 1200, concentrationFactor: 1, rowLengthMetres: nil)
        for (basis, expected) in [(ChemicalRateBasis.perHectare, 24000.0), (.per100Litres, 9000.0)] {
            let chosen = try #require(offered.first { $0.basis == basis && $0.preset == .midpoint })
            let rate = try #require(chosen.seed.seedableValue)
            let productBasis: SprayProductRateBasis = basis == .perHectare ? .wholeBlockArea : .per100Litres
            let quantity = try #require(SprayProductQuantityCalculator.totalQuantity(rate: rate, basis: productBasis, context: context))
            #expect(quantity == expected)
            let line = ChemicalLine(chemicalId: chem.id, selectedRateId: chosen.id, basis: basis == .perHectare ? .perHectare : .per100Litres)
            let result = SprayProductLineResult(productId: chem.id.uuidString, name: chem.name, unit: "mL", basis: productBasis, rate: rate, totalQuantity: quantity, quantityPerFullTank: quantity, quantityInLastTank: quantity, costPerUnit: nil, basisInput: basis == .perHectare ? 6 : 1200)
            let frozen = try #require(SprayConfirmedRateSeeding.snapshot(base: nil, chemical: chem, line: line, planLine: result, at: Date(timeIntervalSince1970: 1_800_000_000)))
            #expect(frozen.rateCondition == chosen.condition)
            #expect(frozen.registeredRate?.rawText == chosen.registeredRate?.rawText)
            let chemicalLine = SprayChemical(name: chem.name, volumePerTank: quantity, unit: .litres, rateBasis: productBasis, savedChemicalId: chem.id, chemicalSnapshot: frozen)
            let record = SprayRecord(tanks: [SprayTank(waterVolume: 1200, concentrationFactor: 1, chemicals: [chemicalLine])])
            let reopened = try JSONDecoder().decode(SprayRecord.self, from: JSONEncoder().encode(record))
            #expect(reopened.tanks[0].chemicals[0].volumePerTank == expected)
            #expect(reopened.tanks[0].chemicals[0].chemicalSnapshot == frozen)
        }
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
