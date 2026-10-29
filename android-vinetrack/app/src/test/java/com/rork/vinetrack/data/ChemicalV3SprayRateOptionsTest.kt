package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChemicalV3SprayRateOptionsTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val payload = """{"id":"synthetic","vineyard_id":"synthetic-vineyard","name":"SPRAY.SEED","unit":"Litres",
      "chemical_v3_revision_id":"synthetic-revision","chemical_v3_review_status_snapshot":"approved",
      "rates":{"per_hectare":[{"option_id":"hectare","basis":"per_hectare","unit":"L/ha","min_value":2.4,"max_value":3.2,"needs_review":false}],
      "per_100_litres":[{"option_id":"carrier","basis":"per_100_litres","unit":"mL/100 L","min_value":240,"max_value":320,"needs_review":false}],"future_evidence":"retain"}}"""

    @Test fun approvedRangesRemainIndependentAndNeverChooseAnAmount() {
        val chemical = json.decodeFromString<SavedChemical>(payload)
        val options = SprayRegisteredUseRates.vineyardRates(chemical)
        val originals = options.filter { it.preset == null }
        assertEquals(2, originals.size)
        assertEquals(SprayRateAmount.Range(2.4, 3.2), originals[0].amount)
        assertEquals(SprayRateAmount.Range(240.0, 320.0), originals[1].amount)
        assertEquals(SprayCalculator.RateBasis.PER_100L, originals[1].basis)
        assertEquals(6, options.count { it.preset != null })
        assertNull(SprayRegisteredUseRates.confirmedSelection(chemical))
        assertEquals(options, SprayRegisteredUseRates.vineyardRates(chemical))
    }

    @Test fun originalV3ObjectSurvivesSavedChemicalCacheRoundTrip() {
        val chemical = json.decodeFromString<SavedChemical>(payload)
        val encoded = json.parseToJsonElement(json.encodeToString(chemical)).jsonObject
        assertEquals(json.parseToJsonElement(payload).jsonObject["rates"], encoded["rates"])
    }

    @Test fun unapprovedRevisionDoesNotFallBackToLegacyRates() {
        val chemical = json.decodeFromString<SavedChemical>(payload).copy(chemicalV3ReviewStatusSnapshot = "pending")
        assertTrue(SprayRegisteredUseRates.vineyardRates(chemical).isEmpty())
        assertTrue(SprayRegisteredUseRates.hasCatalogueEvidence(chemical))
    }

    @Test fun reviewAndIncompleteOptionsCannotSeedRates() {
        val review = json.decodeFromString<SavedChemical>(payload.replace("\"needs_review\":false", "\"needs_review\":true"))
        assertTrue(SprayRegisteredUseRates.vineyardRates(review).isEmpty())
        val incomplete = json.decodeFromString<SavedChemical>(payload.replace("\"max_value\":3.2,", "").replace("\"max_value\":320,", ""))
        assertTrue(SprayRegisteredUseRates.vineyardRates(incomplete).isEmpty())
    }
}
