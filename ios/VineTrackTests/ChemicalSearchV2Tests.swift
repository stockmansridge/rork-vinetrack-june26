import Testing
@testable import VineTrack

struct ChemicalSearchV2Tests {
    @Test func deterministicRankingCoversPrimaryAndSecondaryFields() {
        let common = ["kocide blue"]
        #expect(ChemicalSearchV2Rank.rank(query: "Kocide Blue Xtra", productName: "Kocide Blue Xtra", commonNames: common, registrationNumber: "62764", activeNames: ["copper hydroxide"], registrant: "Corteva") == 1)
        #expect(ChemicalSearchV2Rank.rank(query: "Kocide", productName: "Kocide Blue Xtra", commonNames: common, registrationNumber: "62764", activeNames: ["copper hydroxide"], registrant: "Corteva") == 2)
        #expect(ChemicalSearchV2Rank.rank(query: "62764", productName: "Kocide Blue Xtra", commonNames: common, registrationNumber: "62764", activeNames: ["copper hydroxide"], registrant: "Corteva") == 5)
        #expect(ChemicalSearchV2Rank.rank(query: "hydroxide", productName: "Kocide Blue Xtra", commonNames: common, registrationNumber: "62764", activeNames: ["copper hydroxide"], registrant: "Corteva") == 6)
    }

    @Test func staleRequestCannotReplaceActiveRequest() {
        let old = UUID(); let current = UUID()
        #expect(!ChemicalSearchV2RequestGate.accepts(completed: old, active: current))
        #expect(ChemicalSearchV2RequestGate.accepts(completed: current, active: current))
    }

    @Test func minimumReviewSaveDoesNotRequireRegisteredUse() {
        let rate = ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")
        #expect(ChemicalSaveContract.evaluateMinimumOperational(productName: "Test", productUnit: "Litres", rates: [rate]).canSave)
    }

    @Test func photoRegistrationIdentityIsExtractedBeforeFallback() {
        #expect(ChemicalLabelIdentityOCR.apvmaNumber(in: "APVMA Product No. 62764") == "62764")
    }

    @Test func viticultureRatesKeepBothBasesAndSeparateOptions() {
        let uses = [
            ChemicalRegisteredUse(crop: "ORCHARDS, PLANTATIONS AND VINEYARDS", targetRaw: "Weeds", rates: [
                ChemicalLabelRate(basis: .rangePerHectare, minValue: 2.4, maxValue: 3.2, unit: "L"),
                ChemicalLabelRate(basis: .rangePer100Litres, minValue: 240, maxValue: 320, unit: "mL")
            ]),
            ChemicalRegisteredUse(crop: "Grapes", targetRaw: "Weeds", rates: [
                ChemicalLabelRate(basis: .per100Litres, value: 40, unit: "mL")
            ])
        ]
        let rates = ViticultureRates.fromRegisteredUses(uses)
        #expect(rates.perHectare.count == 1)
        #expect(rates.per100Litres.count == 2)
    }

    @Test func unambiguousPerHectareRateInitialisesAndEnablesSave() {
        let rate = ChemicalLabelRate(basis: .perHectare, value: 2.4, unit: "L")
        let defaults = ChemicalSearchV2OperationalDefaults.unambiguousRates(
            from: ViticultureRates(perHectare: [rate], per100Litres: [])
        )
        #expect(defaults[.perHectare] == rate)
        #expect(ChemicalSaveContract.evaluateMinimumOperational(
            productName: "Test", productUnit: "Litres", rates: Array(defaults.values)
        ).isSatisfied)
    }

    @Test func unambiguousPer100LitresRateInitialisesAndEnablesSave() {
        let rate = ChemicalLabelRate(basis: .per100Litres, value: 240, unit: "mL")
        let defaults = ChemicalSearchV2OperationalDefaults.unambiguousRates(
            from: ViticultureRates(perHectare: [], per100Litres: [rate])
        )
        #expect(defaults[.per100Litres] == rate)
        #expect(ChemicalSaveContract.evaluateMinimumOperational(
            productName: "Test", productUnit: "Millilitres", rates: Array(defaults.values)
        ).isSatisfied)
    }

    @Test func oneRatePerBasisPersistsBothWithoutChangingRangeOrUnit() {
        let perHa = ChemicalLabelRate(basis: .rangePerHectare, minValue: 2.4, maxValue: 3.2, unit: "L")
        let per100 = ChemicalLabelRate(basis: .rangePer100Litres, minValue: 240, maxValue: 320, unit: "mL")
        let masterRates = ViticultureRates(perHectare: [perHa], per100Litres: [per100])
        let snapshot = masterRates
        let initial = ChemicalSearchV2OperationalDefaults.unambiguousRates(from: masterRates)
        let effective = ChemicalSearchV2OperationalDefaults.effectiveRates(automatic: initial, edited: nil)
        let stored = ChemicalSearchV2OperationalDefaults.storedDefaults(rates: effective, selectedAt: "2026-09-18T00:00:00Z")

        #expect(effective.count == 2)
        #expect(stored?.perHectare?.value == nil)
        #expect(stored?.perHectare?.minValue == 2.4)
        #expect(stored?.perHectare?.maxValue == 3.2)
        #expect(stored?.perHectare?.unit == "L")
        #expect(stored?.per100Litres?.value == nil)
        #expect(stored?.per100Litres?.minValue == 240)
        #expect(stored?.per100Litres?.maxValue == 320)
        #expect(stored?.per100Litres?.unit == "mL")
        #expect(masterRates == snapshot)
    }

    @Test func multipleAlternativesAreNotSelectedAndManualOverrideRemainsAvailable() {
        let low = ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")
        let high = ChemicalLabelRate(basis: .perHectare, value: 3, unit: "L")
        let initial = ChemicalSearchV2OperationalDefaults.unambiguousRates(
            from: ViticultureRates(perHectare: [low, high], per100Litres: [])
        )
        #expect(initial[.perHectare] == nil)

        let manual = ChemicalLabelRate(basis: .perHectare, value: 2.5, unit: "L")
        let effective = ChemicalSearchV2OperationalDefaults.effectiveRates(automatic: initial, edited: manual)
        #expect(effective == [manual])
        #expect(ChemicalSaveContract.evaluateMinimumOperational(
            productName: "Test", productUnit: "Litres", rates: effective
        ).isSatisfied)
    }

    @Test func punctuationNormalisationFindsSpraySeed() {
        let name = "SPRAY.SEED 250 HERBICIDE"
        #expect(ChemicalSearchV2Rank.rank(query: "Spray Seed 250", productName: name, commonNames: [], registrationNumber: "46516", activeNames: [], registrant: nil) == 2)
        #expect(ChemicalSearchV2Rank.rank(query: "Spray.Seed 250", productName: name, commonNames: [], registrationNumber: "46516", activeNames: [], registrant: nil) == 2)
    }

    @Test func normalMasterSearchHasNoAIPath() {
        #expect(MasterChemicalV2Repository.invokesAI == false)
    }

    @Test func manualEntryPrefillsTypedSearchAndStaysVineyardOnly() {
        #expect(ChemicalSearchV2ManualPrefill.productName(from: "  My Local Sulphur  ") == "My Local Sulphur")
        let rate = ChemicalManualRateDraft(basis: .per100Litres, minText: "200", maxText: "400", unit: "g")
        let details = ChemicalSearchV2ManualDetails(
            manufacturer: "Local supplier",
            registrationNumber: "",
            productCategory: "fungicide",
            activeIngredient: "Sulphur",
            activityGroupScheme: .frac,
            activityGroupCode: "M02",
            notes: "Optional note"
        )
        let intelligence = details.intelligence(productName: "My Local Sulphur", rate: rate)

        #expect(intelligence.registeredUses.isEmpty)
        #expect(intelligence.resolvedVerificationStatus == .unverified)
        #expect(intelligence.activeIngredients.map(\.name) == ["Sulphur"])
    }

    @Test func manualSingleAndRangePersistToExactDefaultRateBasis() throws {
        let single = ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")
        let range = ChemicalLabelRate(basis: .rangePer100Litres, minValue: 200, maxValue: 400, unit: "g")
        let area = try #require(ChemicalSearchV2OperationalDefaults.storedDefaults(rates: [single], selectedAt: "2026-09-19T00:00:00Z")?.perHectare)
        let volume = try #require(ChemicalSearchV2OperationalDefaults.storedDefaults(rates: [range], selectedAt: "2026-09-19T00:00:00Z")?.per100Litres)

        #expect(area.value == 2 && area.unit == "L")
        #expect(volume.minValue == 200 && volume.maxValue == 400 && volume.unit == "g")
        #expect(area.entryMethod == "manual" && volume.entryMethod == "manual")
    }

    @Test func optionalDetailsAndRegisteredUsesDoNotBlockManualSave() {
        let rate = ChemicalLabelRate(basis: .per100Litres, value: 200, unit: "g")
        let evaluation = ChemicalSaveContract.evaluateMinimumOperational(
            productName: "Wettable Sulphur", productUnit: "g", rates: [rate]
        )
        #expect(evaluation.isSatisfied)
        #expect(!evaluation.violations.contains { $0.code == .grapevineUseMissing })
        #expect(!evaluation.violations.contains { $0.code == .productCategoryMissing })
    }

    @Test func manualDuplicateUsesExactNormalisedVineyardNameOnly() {
        let existing = SavedChemical(name: "Wettable Sulphur")
        let intelligence = ChemicalIntelligence(verification: .manual())
        #expect(ChemicalSearchV2Duplicate.existing(
            master: nil, intelligence: intelligence, name: "wettable-sulphur", in: [existing]
        )?.id == existing.id)
        #expect(ChemicalSearchV2Duplicate.existing(
            master: nil, intelligence: intelligence, name: "Wettable Sulphur Plus", in: [existing]
        ) == nil)
    }
}
