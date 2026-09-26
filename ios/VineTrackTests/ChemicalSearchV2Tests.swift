import Foundation
import Testing
@testable import VineTrack

struct ChemicalSearchV2Tests {
    @Test func completenessUsesFieldsNotRegistrationOrEvidenceGrade() {
        let active = ChemicalActiveIngredient(
            name: "Tebuconazole", concentration: 200, concentrationUnit: .gramsPerLitre,
            activityGroup: ChemicalActivityGroup(scheme: .frac, code: "3")
        )
        let intel = ChemicalIntelligence(
            activeIngredients: [active], verification: .manual(),
            registeredUses: [ChemicalRegisteredUse(crop: "Grapes", targetRaw: "Mildew", rates: [
                ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")
            ])], productCategory: "fungicide"
        )
        let complete = ChemicalDetailsCompleteness.assess(
            name: "Spray", category: "fungicide", form: "liquid", intelligence: intel,
            labelURL: "https://example.com/label.pdf", hasDefaultRate: true, hasLabelRate: true
        )
        #expect(intel.resolvedVerificationStatus == .unverified)
        #expect(complete.title == "Complete details")
        #expect(complete.missingText == nil)
        let basic = ChemicalDetailsCompleteness.assess(
            name: "Spray", category: "fungicide", form: "", intelligence: intel,
            labelURL: "", hasDefaultRate: true, hasLabelRate: false
        )
        #expect(basic.title == "Basic details")
        #expect(basic.missingText == "Missing: product form, label rate, product label link")
    }

    @Test func nonProtectionProductsDoNotNeedResistanceGroupsOrActives() {
        let basic = ChemicalDetailsCompleteness.assess(
            name: "Seaweed", category: "seaweed", form: "liquid",
            intelligence: ChemicalIntelligence(productCategory: "seaweed"),
            labelURL: "https://example.com/seaweed-label", hasDefaultRate: true, hasLabelRate: false
        )
        #expect(basic.title == "Complete details")
        #expect(!basic.missing.contains("FRAC group"))
    }

    @Test func genuineConflictsTakePriorityOverMissingFields() {
        let conflict = ChemicalVerificationConflict(field: "activity_group", extractedValue: "3", authoritativeValue: "11")
        let intel = ChemicalIntelligence(verification: ChemicalVerification(conflicts: [conflict]))
        let result = ChemicalDetailsCompleteness.assess(
            name: "Spray", category: "fungicide", form: "", intelligence: intel,
            labelURL: "", hasDefaultRate: false, hasLabelRate: false
        )
        #expect(result.title == "Review required")
        #expect(result.missing.contains("product form"))
    }
    @Test func historicalFlumioxazinGroupWordingIsNotReviewRequired() {
        let historical = ChemicalVerificationConflict(
            field: "activity_group", activeIngredientName: "Flumioxazin",
            extractedValue: "HRAC 14", authoritativeValue: "HRAC E"
        )
        let intel = ChemicalIntelligence(
            activeIngredients: [ChemicalActiveIngredient(name: "Flumioxazin", activityGroup: ChemicalActivityGroup(scheme: .hrac, code: "14"))],
            verification: ChemicalVerification(status: .conflict, conflicts: [historical]),
            productCategory: "herbicide"
        )
        #expect(intel.verification.conflicts == [historical])
        #expect(intel.resolvedVerificationStatus != .conflict)
        let complete = ChemicalDetailsCompleteness.assess(
            name: "Flumioxazin", category: "herbicide", form: "liquid", intelligence: intel,
            labelURL: "https://example.com/label", hasDefaultRate: true, hasLabelRate: true
        )
        #expect(complete.title == "Basic details")
        #expect(complete.missing.contains("active concentration"))
        let basic = ChemicalDetailsCompleteness.assess(
            name: "Flumioxazin", category: "herbicide", form: "", intelligence: intel,
            labelURL: "", hasDefaultRate: false, hasLabelRate: false
        )
        #expect(basic.title == "Basic details")
    }

    @Test func genuineFlumioxazinGroupConflictRequiresReview() {
        let genuine = ChemicalVerificationConflict(
            field: "activity_group", activeIngredientName: "Flumioxazin",
            extractedValue: "HRAC 2", authoritativeValue: "HRAC 14"
        )
        let intel = ChemicalIntelligence(
            activeIngredients: [ChemicalActiveIngredient(name: "Flumioxazin", activityGroup: ChemicalActivityGroup(scheme: .hrac, code: "14"))],
            verification: ChemicalVerification(status: .verified, conflicts: [genuine]),
            productCategory: "herbicide"
        )
        #expect(intel.resolvedVerificationStatus == .conflict)
        let result = ChemicalDetailsCompleteness.assess(
            name: "Flumioxazin", category: "herbicide", form: "", intelligence: intel,
            labelURL: "", hasDefaultRate: false, hasLabelRate: false
        )
        #expect(result.title == "Review required")
    }

    @Test func formulationAndCategorySynonymsCountAsApplicableDetails() {
        let herbicide = ChemicalIntelligence(productCategory: "non-selective herbicide")
        let liquid = ChemicalDetailsCompleteness.assess(
            name: "Herbicide", category: "Non-selective herbicide", form: "Suspension concentrate",
            intelligence: herbicide, labelURL: "https://example.com/label", hasDefaultRate: true, hasLabelRate: false
        )
        #expect(!liquid.missing.contains("product form"))
        #expect(liquid.missing.contains("active ingredients"))
        #expect(liquid.missing.contains("HRAC group"))
        let solid = ChemicalDetailsCompleteness.assess(
            name: "Herbicide", category: "herbicide", form: "WP",
            intelligence: herbicide, labelURL: "https://example.com/label", hasDefaultRate: true, hasLabelRate: false
        )
        #expect(!solid.missing.contains("product form"))
        for form in ["Wettable powder", "WG", "granule"] {
            #expect(!ChemicalDetailsCompleteness.assess(
                name: "Herbicide", category: "herbicide", form: form,
                intelligence: herbicide, labelURL: "https://example.com/label", hasDefaultRate: true, hasLabelRate: false
            ).missing.contains("product form"))
        }
        for category in ["Plant growth regulator", "PGR"] {
            let result = ChemicalDetailsCompleteness.assess(
                name: "Regulator", category: category, form: "Soluble concentrate",
                intelligence: ChemicalIntelligence(productCategory: category), labelURL: "https://example.com/label",
                hasDefaultRate: true, hasLabelRate: false
            )
            #expect(result.missing.contains("active ingredients"))
            #expect(result.missing.contains("label rate"))
            #expect(!result.missing.contains("product form"))
        }
    }

    @Test func webCandidateWithoutAPVMANumberCanBeSelected() throws {
        let payload = #"{"candidates":[{"name":"CropSure Beast 200 Herbicide","brand":"CropSure Pty Ltd","activeIngredient":"Glufosinate-ammonium","product_category":"herbicide","source":"research"}],"detail":null,"timings":{"search_ms":324,"extraction_ms":0}}"#
        let response = try JSONDecoder().decode(ChemicalInfoService.WebV2Lookup.self, from: Data(payload.utf8))
        #expect(response.candidates.first?.name == "CropSure Beast 200 Herbicide")
        #expect(response.detail == nil)
    }

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
        #expect(ChemicalLabelIdentityOCR.proposedQuery(apvma: "62764", identifiedName: "Dithane Rainshield") == "62764")
    }

    @Test func photoHeadingCannotSilentlyBecomeQuery() {
        for heading in ["WARNING", "CAUTION"] {
            let text = "\(heading)\nDITHANE RAINSHIELD\nFUNGICIDE"
            #expect(ChemicalLabelIdentityOCR.apvmaNumber(in: text) == nil)
            #expect(ChemicalLabelIdentityOCR.proposedQuery(apvma: nil, identifiedName: nil) == nil)
            #expect(ChemicalLabelIdentityOCR.proposedQuery(apvma: nil, identifiedName: "DITHANE RAINSHIELD") == "DITHANE RAINSHIELD")
        }
        #expect(ChemicalSearchV2ManualPrefill.productName(from: " Corrected name ") == "Corrected name")
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

    @Test func provenanceAndQueuedV2RepairPreserveEvidence() {
        let unverified = ChemicalIntelligence(verification: .manual())
        let verified = ChemicalIntelligence(
            registration: ChemicalRegistration(countryCode: "AU", scheme: .apvma, registrationNumber: "59688"),
            verification: ChemicalVerification(sources: [ChemicalDataSource(kind: .officialRegister, name: "APVMA")])
        )
        #expect(SavedChemicalEntrySource.reviewed(isManual: true, isMaster: false, intelligence: verified) == "customer_entered")
        #expect(SavedChemicalEntrySource.reviewed(isManual: false, isMaster: true, intelligence: verified) == "master_catalogue")
        #expect(SavedChemicalEntrySource.reviewed(isManual: false, isMaster: false, intelligence: verified) == "register_lookup")
        #expect(SavedChemicalEntrySource.reviewed(isManual: false, isMaster: false, intelligence: unverified) == "label_lookup")
        #expect(SavedChemicalEntrySource.repaired("manual_v2", intelligence: nil) == "customer_entered")
        #expect(SavedChemicalEntrySource.repaired("master_catalogue_v2", intelligence: nil) == "master_catalogue")
        #expect(SavedChemicalEntrySource.repaired("label_lookup_v2", intelligence: verified) == "register_lookup")
        #expect(SavedChemicalEntrySource.repaired("label_lookup_v2", intelligence: unverified) == "label_lookup")
        #expect(SavedChemicalEntrySource.repaired(nil, intelligence: verified) == nil)
    }

    @Test func savedFirstFindsDithaneWithoutNetworkAndDoesNotMatchHeadingsOrVariants() {
        let saved = SavedChemical(name: "DITHANE RAINSHIELD")
        let candidates = [saved]
        #expect(ChemicalSearchV2Duplicate.localMatches(query: "dithane-rainshield", in: candidates).first?.id == saved.id)
        #expect(ChemicalSearchV2Duplicate.localMatches(query: "DITHANE RAINSHIELD PLUS", in: candidates).isEmpty)
        #expect(ChemicalSearchV2Duplicate.localMatches(query: "WARNING", in: candidates).isEmpty)
        #expect(ChemicalSearchV2Duplicate.localMatches(query: "59688", in: candidates).isEmpty)
    }

    @Test func savedFirstRegistrationUsesCountryAndScheme() {
        var saved = SavedChemical(name: "Different Display Name")
        saved.chemicalIntelligence = ChemicalIntelligence(
            registration: ChemicalRegistration(countryCode: "AU", scheme: .apvma, registrationNumber: "59688")
        )
        #expect(ChemicalSearchV2Duplicate.localMatches(query: "APVMA 59688", in: [saved]).first?.id == saved.id)
        #expect(ChemicalSearchV2Duplicate.localMatches(query: "59689", in: [saved]).isEmpty)
        let other = ChemicalIntelligence(registration: ChemicalRegistration(countryCode: "AU", scheme: .apvma, registrationNumber: "59689"))
        #expect(ChemicalSearchV2Duplicate.existing(master: nil, intelligence: other, name: saved.name, in: [saved]) == nil)
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
