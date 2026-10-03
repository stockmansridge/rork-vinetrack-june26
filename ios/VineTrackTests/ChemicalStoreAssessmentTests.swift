import Foundation
import Testing
@testable import VineTrack

@MainActor
struct ChemicalStoreAssessmentTests {
    @Test func twelveCatalogueProductsAreCompleteWithoutLegacyCopiesOrAttention() {
        let revisionId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let revision = CatalogueWire(fields: ["id": .string(revisionId.uuidString), "product_name": .string("Catalogue Wetter"), "review_status": .string("approved"), "resistance_classification_state": .string("not_applicable")])
        let chemicals = (1...12).map { index in
            var chemical = SavedChemical(name: "Catalogue Wetter \(index)")
            chemical.chemicalV3RevisionId = revisionId
            return chemical
        }
        // Reproduces the old screenshot path before using the exact revision.
        #expect(chemicals.allSatisfy { ChemicalDetailsCompleteness.assess($0).title == "Basic details" })
        let assessments = ChemicalStoreAssessment.activeAssessments(chemicals, resolutions: [revisionId: .resolved(revision)])
        #expect(assessments.count == 12)
        #expect(assessments.values.filter { $0.title == "Complete details" }.count == 12)
        #expect(assessments.values.filter(\.needsAttention).isEmpty)
        #expect(chemicals.allSatisfy { $0.defaultRates == nil && $0.chemicalIntelligence == nil && $0.rates.isEmpty })
    }

    @Test func validResistanceClassificationsNeverRequireCompatibilityEnrichment() {
        let id = UUID()
        var chemical = SavedChemical(name: "Catalogue fungicide")
        chemical.chemicalV3RevisionId = id
        for state in ["NOT_APPLICABLE", "not_applicable", "classified"] {
            let revision = CatalogueWire(fields: ["id": .string(id.uuidString), "product_name": .string("Catalogue fungicide"), "resistance_classification_state": .string(state), "activity_group_scheme": .string("frac"), "activity_groups": .array([.string("3"), .string("11")])])
            let assessment = ChemicalStoreAssessment.assess(chemical, resolution: .resolved(revision))
            #expect(assessment.title == "Complete details")
            #expect(assessment.details.missing.isEmpty)
            #expect(!assessment.needsAttention)
        }
    }

    @Test func operationalMinimumManualSingleAndRangeAreBasicWithoutAttention() {
        for slot in [StoredChemicalDefaultRate.manual(basis: .perHectare, unit: "L", value: 2), .manual(basis: .per100Litres, unit: "L", minValue: 0.5, maxValue: 1)] {
            let defaults = slot.basis == "per_hectare" ? StoredChemicalDefaultRates(perHectare: slot) : StoredChemicalDefaultRates(per100Litres: slot)
            let chemical = SavedChemical(name: "Manual Wetter", defaultRates: defaults, entrySource: "customer_entered")
            let assessment = ChemicalStoreAssessment.assess(chemical)
            #expect(assessment.title == "Basic details")
            #expect(!assessment.needsAttention)
            #expect(assessment.attentionReasons.isEmpty)
        }
    }

    @Test func optionalManualMetadataDoesNotCreateAttention() {
        let minimum = SavedChemical(name: "Manual Fungicide", productCategory: "fungicide", defaultRates: .init(perHectare: .manual(basis: .perHectare, unit: "L", value: 2)), entrySource: "manual_v2")
        #expect(ChemicalDetailsCompleteness.assess(minimum).missing.contains("active ingredients"))
        #expect(ChemicalDetailsCompleteness.assess(minimum).missing.contains("product label link"))
        #expect(!ChemicalStoreAssessment.assess(minimum).needsAttention)
        var enriched = minimum
        enriched.manufacturer = "Optional maker"
        enriched.labelURL = "https://example.com/label"
        enriched.inventoryQuantity = 0
        enriched.purchase = ChemicalPurchase(costDollars: 100, containerSizeML: 20)
        #expect(!ChemicalStoreAssessment.assess(enriched).needsAttention)
    }

    @Test func genuineConflictRemainsAttentionForManualAndCatalogue() {
        let conflict = ChemicalVerificationConflict(field: "activity_group", activeIngredientName: "Flumioxazin", extractedValue: "HRAC 2", authoritativeValue: "HRAC 14")
        var chemical = SavedChemical(name: "Manual product", chemicalIntelligence: ChemicalIntelligence(verification: ChemicalVerification(status: .verified, conflicts: [conflict])), defaultRates: .init(perHectare: .manual(basis: .perHectare, unit: "L", value: 2)), entrySource: "customer_entered")
        #expect(ChemicalStoreAssessment.assess(chemical).needsAttention)
        let id = UUID()
        chemical.chemicalV3RevisionId = id
        let revision = CatalogueWire(fields: ["id": .string(id.uuidString), "product_name": .string("Catalogue product"), "review_status": .string("approved")])
        let assessment = ChemicalStoreAssessment.assess(chemical, resolution: .resolved(revision))
        #expect(assessment.title == "Review required" && assessment.needsAttention)
        chemical.chemicalIntelligence = ChemicalIntelligence(verification: ChemicalVerification(status: .conflict))
        #expect(ChemicalStoreAssessment.assess(chemical, resolution: .resolved(revision)).needsAttention)
    }

    @Test func missingOrWrongRevisionIsReviewButLoadingIsNotAnOperatorTask() {
        var chemical = SavedChemical(name: "Catalogue product")
        chemical.chemicalV3RevisionId = UUID()
        #expect(!ChemicalStoreAssessment.assess(chemical).needsAttention)
        let missing = ChemicalStoreAssessment.assess(chemical, resolution: .unavailable)
        #expect(missing.title == "Review required" && missing.needsAttention)
        #expect(missing.attentionReasons.first?.contains("Catalogue information unavailable") == true)
        let wrong = CatalogueWire(fields: ["id": .string(UUID().uuidString), "product_name": .string("Other product")])
        #expect(ChemicalStoreAssessment.assess(chemical, resolution: .resolved(wrong)).needsAttention)
    }

    @Test func catalogueReviewStatesDistinguishOperatorActionFromInternalReview() {
        let id = UUID()
        var chemical = SavedChemical(name: "Catalogue product")
        chemical.chemicalV3RevisionId = id
        for status in ["approved", "pending_review", "superseded", "needs_attention", "rejected"] {
            let revision = CatalogueWire(fields: ["id": .string(id.uuidString), "product_name": .string("Catalogue product"), "review_status": .string(status)])
            let assessment = ChemicalStoreAssessment.assess(chemical, resolution: .resolved(revision))
            let actionable = ["needs_attention", "rejected"].contains(status)
            #expect(assessment.needsAttention == actionable)
            #expect(assessment.title == (actionable ? "Review required" : "Complete details"))
        }
        let corrupt = CatalogueWire(fields: ["id": .string(id.uuidString), "product_name": .string(" ")])
        #expect(ChemicalStoreAssessment.assess(chemical, resolution: .resolved(corrupt)).needsAttention)
    }

    @Test func legacyRateRemainsUsableWithoutOptionalEnrichmentOrMutation() {
        let legacy = SavedChemical(name: "Legacy product", ratePerHa: 2, activeIngredient: "Historical text", purchase: ChemicalPurchase(costDollars: 200, containerSizeML: 20))
        let original = legacy
        let assessment = ChemicalStoreAssessment.assess(legacy)
        #expect(assessment.title == "Basic details" && !assessment.needsAttention)
        #expect(legacy == original)
        #expect(legacy.purchase?.costPerBaseUnit == original.purchase?.costPerBaseUnit)
        for source in ["manual", "manual_v2", "customer_entered"] {
            var oldManual = legacy
            oldManual.entrySource = source
            #expect(!ChemicalStoreAssessment.assess(oldManual).needsAttention)
        }
        let perWater = SavedChemical(name: "Legacy water rate", rates: [ChemicalRate(value: 100, basis: .per100Litres)])
        #expect(!ChemicalStoreAssessment.assess(perWater).needsAttention)
        #expect(ChemicalStoreAssessment.assess(SavedChemical(name: "Unusable legacy")).needsAttention)
    }

    @Test func malformedManualOperationalDataStillRequiresAction() {
        for slot in [StoredChemicalDefaultRate.manual(basis: .perHectare, unit: "L", value: -1), .manual(basis: .perHectare, unit: "L", minValue: 3, maxValue: 2), .manual(basis: .perHectare, unit: "", value: 2)] {
            let chemical = SavedChemical(name: "Bad manual", defaultRates: .init(perHectare: slot), entrySource: "manual_v2")
            #expect(ChemicalStoreAssessment.assess(chemical).needsAttention)
            #expect(ChemicalStoreAssessment.assess(chemical).title == "Review required")
        }
        #expect(ChemicalStoreAssessment.assess(SavedChemical(name: " ", entrySource: "manual_v2")).needsAttention)
    }

    @Test func archivedChemicalsNeverCountAndRemainAvailableForHistoricalResolution() {
        let archived = SavedChemical(name: "Broken archived product", isActive: false)
        let valid = SavedChemical(name: "Valid manual", defaultRates: .init(perHectare: .manual(basis: .perHectare, unit: "L", value: 2)), entrySource: "manual_v2")
        let rows = [valid, archived]
        let assessments = ChemicalStoreAssessment.activeAssessments(rows, resolutions: [:])
        #expect(assessments.count == 1)
        #expect(assessments.values.filter(\.needsAttention).isEmpty)
        #expect(!ChemicalStoreAssessment.assess(archived).needsAttention)
        #expect(rows.count == 2 && rows.last == archived)
    }
}
