package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.chemical.ChemicalStoreAssessment.RevisionResolution
import com.rork.vinetrack.data.model.ChemicalPurchase
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChemicalStoreAssessmentTest {
    @Test fun twelveCatalogueProductsAreCompleteWithoutLegacyCopiesOrAttention() {
        val revisionId = "11111111-1111-1111-1111-111111111111"
        val revision = CatalogueRow(Json.parseToJsonElement("""{"id":"$revisionId","product_name":"Catalogue Wetter","review_status":"approved","resistance_classification_state":"not_applicable"}""").jsonObject)
        val chemicals = (1..12).map { SavedChemical(id = "$it", vineyardId = "vineyard", name = "Catalogue Wetter $it", chemicalV3RevisionId = revisionId) }
        // Reproduces the old screenshot path before exact revision assessment.
        assertTrue(chemicals.all { ChemicalDetailsCompleteness.assess(it).title == "Basic details" })
        val assessments = ChemicalStoreAssessment.activeAssessments(chemicals, mapOf(revisionId to RevisionResolution.Resolved(revision)))
        assertEquals(12, assessments.size)
        assertEquals(12, assessments.values.count { it.title == "Complete details" })
        assertEquals(0, assessments.values.count { it.needsAttention })
        assertTrue(chemicals.all { it.defaultRates == null && it.activeIngredients == null && it.rates.isEmpty() })
    }

    @Test fun validResistanceClassificationsNeverRequireCompatibilityEnrichment() {
        val chemical = SavedChemical(id = "chemical", vineyardId = "vineyard", name = "Catalogue fungicide", chemicalV3RevisionId = "exact")
        for (state in listOf("NOT_APPLICABLE", "not_applicable", "classified")) {
            val revision = CatalogueRow(Json.parseToJsonElement("""{"id":"exact","product_name":"Catalogue fungicide","resistance_classification_state":"$state","activity_group_scheme":"frac","activity_groups":["3","11"]}""").jsonObject)
            val assessment = ChemicalStoreAssessment.assess(chemical, RevisionResolution.Resolved(revision))
            assertEquals("Complete details", assessment.title)
            assertTrue(assessment.details.missing.isEmpty())
            assertFalse(assessment.needsAttention)
        }
    }

    @Test fun operationalMinimumManualSingleAndRangeAreBasicWithoutAttention() {
        for (slot in listOf(StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_HECTARE, "L", value = 2.0), StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_100_LITRES, "L", minValue = 0.5, maxValue = 1.0))) {
            val defaults = if (slot.basis == "per_hectare") StoredChemicalDefaultRates(perHectare = slot) else StoredChemicalDefaultRates(per100Litres = slot)
            val chemical = SavedChemical(id = "manual", vineyardId = "vineyard", name = "Manual Wetter", defaultRates = defaults, entrySource = "customer_entered")
            val assessment = ChemicalStoreAssessment.assess(chemical)
            assertEquals("Basic details", assessment.title)
            assertFalse(assessment.needsAttention)
            assertTrue(assessment.attentionReasons.isEmpty())
        }
    }

    @Test fun optionalManualMetadataDoesNotCreateAttention() {
        val minimum = SavedChemical(id = "manual", vineyardId = "vineyard", name = "Manual Fungicide", productCategory = "fungicide", defaultRates = StoredChemicalDefaultRates(perHectare = StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_HECTARE, "L", value = 2.0)), entrySource = "manual_v2")
        assertTrue(ChemicalDetailsCompleteness.assess(minimum).missing.contains("active ingredients"))
        assertTrue(ChemicalDetailsCompleteness.assess(minimum).missing.contains("product label link"))
        assertFalse(ChemicalStoreAssessment.assess(minimum).needsAttention)
        val enriched = minimum.copy(manufacturer = "Optional maker", labelUrl = "https://example.com/label", inventoryQuantity = 0.0, purchase = ChemicalPurchase(costDollars = 100.0, containerSizeML = 20.0))
        assertFalse(ChemicalStoreAssessment.assess(enriched).needsAttention)
    }

    @Test fun genuineConflictRemainsAttentionForManualAndCatalogue() {
        val conflict = ChemicalVerificationConflict(field = "activity_group", activeIngredientName = "Flumioxazin", extractedValue = "HRAC 2", authoritativeValue = "HRAC 14")
        val chemical = SavedChemical(id = "manual", vineyardId = "vineyard", name = "Manual product", verificationStatusRaw = "verified", verificationConflicts = listOf(conflict), defaultRates = StoredChemicalDefaultRates(perHectare = StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_HECTARE, "L", value = 2.0)), entrySource = "customer_entered")
        assertTrue(ChemicalStoreAssessment.assess(chemical).needsAttention)
        val linked = chemical.copy(chemicalV3RevisionId = "exact")
        val revision = CatalogueRow(Json.parseToJsonElement("""{"id":"exact","product_name":"Catalogue product","review_status":"approved"}""").jsonObject)
        val assessment = ChemicalStoreAssessment.assess(linked, RevisionResolution.Resolved(revision))
        assertEquals("Review required", assessment.title)
        assertTrue(assessment.needsAttention)
        assertTrue(ChemicalStoreAssessment.assess(linked.copy(verificationConflicts = emptyList(), verificationStatusRaw = "conflict"), RevisionResolution.Resolved(revision)).needsAttention)
    }

    @Test fun missingOrWrongRevisionIsReviewButLoadingIsNotAnOperatorTask() {
        val chemical = SavedChemical(id = "chemical", vineyardId = "vineyard", name = "Catalogue product", chemicalV3RevisionId = "exact")
        assertFalse(ChemicalStoreAssessment.assess(chemical).needsAttention)
        val missing = ChemicalStoreAssessment.assess(chemical, RevisionResolution.Unavailable)
        assertEquals("Review required", missing.title)
        assertTrue(missing.needsAttention)
        assertTrue(missing.attentionReasons.first().contains("Catalogue information unavailable"))
        val wrong = CatalogueRow(Json.parseToJsonElement("""{"id":"wrong","product_name":"Other product"}""").jsonObject)
        assertTrue(ChemicalStoreAssessment.assess(chemical, RevisionResolution.Resolved(wrong)).needsAttention)
    }

    @Test fun catalogueReviewStatesDistinguishOperatorActionFromInternalReview() {
        val chemical = SavedChemical(id = "chemical", vineyardId = "vineyard", name = "Catalogue product", chemicalV3RevisionId = "exact")
        for (status in listOf("approved", "pending_review", "superseded", "needs_attention", "rejected")) {
            val revision = CatalogueRow(Json.parseToJsonElement("""{"id":"exact","product_name":"Catalogue product","review_status":"$status"}""").jsonObject)
            val assessment = ChemicalStoreAssessment.assess(chemical, RevisionResolution.Resolved(revision))
            val actionable = status in listOf("needs_attention", "rejected")
            assertEquals(actionable, assessment.needsAttention)
            assertEquals(if (actionable) "Review required" else "Complete details", assessment.title)
        }
        val corrupt = CatalogueRow(Json.parseToJsonElement("""{"id":"exact","product_name":" "}""").jsonObject)
        assertTrue(ChemicalStoreAssessment.assess(chemical, RevisionResolution.Resolved(corrupt)).needsAttention)
    }

    @Test fun legacyRateRemainsUsableWithoutOptionalEnrichmentOrMutation() {
        val legacy = SavedChemical(id = "legacy", vineyardId = "vineyard", name = "Legacy product", ratePerHa = 2.0, activeIngredient = "Historical text", purchase = ChemicalPurchase(costDollars = 200.0, containerSizeML = 20.0))
        val original = legacy.copy()
        val assessment = ChemicalStoreAssessment.assess(legacy)
        assertEquals("Basic details", assessment.title)
        assertFalse(assessment.needsAttention)
        assertEquals(original, legacy)
        assertEquals(original.costPerUnit, legacy.costPerUnit)
        for (source in listOf("manual", "manual_v2", "customer_entered")) {
            assertFalse(ChemicalStoreAssessment.assess(legacy.copy(entrySource = source)).needsAttention)
        }
        val perWater = SavedChemical(id = "water", vineyardId = "vineyard", name = "Legacy water rate", rates = listOf(ChemicalRate(value = 100.0, basis = CHEMICAL_RATE_PER_100L)))
        assertFalse(ChemicalStoreAssessment.assess(perWater).needsAttention)
        assertTrue(ChemicalStoreAssessment.assess(SavedChemical(id = "bad", vineyardId = "vineyard", name = "Unusable legacy")).needsAttention)
    }

    @Test fun malformedManualOperationalDataStillRequiresAction() {
        for (slot in listOf(StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_HECTARE, "L", value = -1.0), StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_HECTARE, "L", minValue = 3.0, maxValue = 2.0), StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_HECTARE, "", value = 2.0))) {
            val chemical = SavedChemical(id = "bad", vineyardId = "vineyard", name = "Bad manual", defaultRates = StoredChemicalDefaultRates(perHectare = slot), entrySource = "manual_v2")
            assertTrue(ChemicalStoreAssessment.assess(chemical).needsAttention)
            assertEquals("Review required", ChemicalStoreAssessment.assess(chemical).title)
        }
        assertTrue(ChemicalStoreAssessment.assess(SavedChemical(id = "blank", vineyardId = "vineyard", name = " ", entrySource = "manual_v2")).needsAttention)
    }

    @Test fun archivedChemicalsNeverCountAndRemainAvailableForHistoricalResolution() {
        val archived = SavedChemical(id = "archived", vineyardId = "vineyard", name = "Broken archived product", isActive = false)
        val valid = SavedChemical(id = "valid", vineyardId = "vineyard", name = "Valid manual", defaultRates = StoredChemicalDefaultRates(perHectare = StoredChemicalDefaultRate.manual(ChemicalDefaultRateBasis.PER_HECTARE, "L", value = 2.0)), entrySource = "manual_v2")
        val deleted = archived.copy(id = "deleted", isActive = true, deletedAt = "2026-10-03T00:00:00Z")
        val rows = listOf(valid, archived, deleted)
        val assessments = ChemicalStoreAssessment.activeAssessments(rows, emptyMap())
        assertEquals(1, assessments.size)
        assertEquals(0, assessments.values.count { it.needsAttention })
        assertFalse(ChemicalStoreAssessment.assess(archived).needsAttention)
        assertFalse(ChemicalStoreAssessment.assess(deleted).needsAttention)
        assertEquals(3, rows.size)
        assertEquals(archived, rows[1])
    }
}
