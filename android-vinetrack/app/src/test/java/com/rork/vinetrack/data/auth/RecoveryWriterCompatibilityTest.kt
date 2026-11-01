package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.spray.SprayTarget
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Synthetic writer-shaped evidence, never a copy of customer records. */
class RecoveryWriterCompatibilityTest {
    private val owner = "00000000-0000-4000-8000-0000000000a1"
    private val vineyard = "00000000-0000-4000-8000-0000000000b2"
    private val reader = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val strict = Json { ignoreUnknownKeys = false; encodeDefaults = true }
    private val serializer = ListSerializer(SavedChemical.serializer())
    private fun source(extra: String) = """{"id":"synthetic-product","vineyard_id":"$vineyard",$extra}"""
    private fun written(extra: String): String {
        val row = reader.decodeFromString(SavedChemical.serializer(), source(extra))
        return reader.encodeToString(serializer, listOf(row))
    }
    private fun recover(raw: String): List<SavedChemical> {
        val input = mapOf("$owner|$vineyard" to raw)
        assertEquals(setOf(vineyard), CleanExitCacheContract.chemicalRecoveryScopes(input, emptyMap<String, Any>(), owner))
        assertEquals(raw, input.values.single())
        return reader.decodeFromString(serializer, raw)
    }
    @Test fun writerPreservedConcentrationWordingIsNotALoginBlocker() {
        val raw = written(""""active_ingredients":[{"name":"Synthetic active","concentration":1.0,"concentration_unit":"%"}]""")
        assertTrue(runCatching { strict.decodeFromString(serializer, raw) }.isFailure)
        val active = recover(raw).single().activeIngredients!!.single()
        assertNull(active.concentrationUnit)
        assertEquals("%", active.unresolvedConcentrationUnit)
    }
    @Test fun writerPreservedUnknownTargetIsNotMappedToAKnownTarget() {
        val raw = written(""""registered_uses":[{"crop":"Synthetic crop","target_raw":"Synthetic target","target":"synthetic_unmapped_target","rates":[]}]""")
        assertTrue(runCatching { strict.decodeFromString(serializer, raw) }.isFailure)
        val use = recover(raw).single().registeredUses!!.single()
        assertNull(use.target)
        assertEquals(JsonPrimitive("synthetic_unmapped_target"), use.unknownFields["target"])
    }
    @Test fun knownDiseaseTargetRemainsRecognisedInBothCodecs() {
        val raw = written(""""registered_uses":[{"crop":"Synthetic crop","target_raw":"Powdery mildew","target":"powdery_mildew","rates":[]}]""")
        val strictUse = strict.decodeFromString(serializer, raw).single().registeredUses!!.single()
        val recoveredUse = recover(raw).single().registeredUses!!.single()
        assertEquals(SprayTarget.POWDERY_MILDEW, strictUse.target)
        assertEquals(strictUse, recoveredUse)
        assertFalse(recoveredUse.unknownFields.containsKey("target"))
    }
    @Test fun unsupportedRateBasisIsPreservedWithoutOfferingAnExecutableRate() {
        val raw = written(""""registered_uses":[{"crop":"Synthetic crop","rates":[{"basis":"future_per_vine","value":2,"unit":"mL","future_note":{"revision":1}}]}]""")
        val rate = recover(raw).single().registeredUses!!.single().rates.single()
        assertEquals("future_per_vine", rate.unsupportedBasis)
        assertEquals(ChemicalLabelRateBasis.OTHER, rate.basis)
        assertTrue(rate.basis.compatibleProductRateBases.isEmpty())
        assertNotNull(rate.unknownFields["future_note"])
    }
    @Test fun opaqueTopLevelAndLossyNestedFieldsAreStillRefused() {
        for (extra in listOf(""""future_private":{"amount":5}""", """"purchase":{"future_private":5}""", """"rates":[{"value":"not-a-number"}]""")) {
            val raw = "[${source(extra)}]"
            val failure = runCatching { recover(raw) }.exceptionOrNull()
            assertTrue(failure is EvidenceContractFailure)
        }
    }
    @Test fun typeChangesAndMissingIdentityRemainRefused() {
        for (raw in listOf("""[{"id":"synthetic","vineyard_id":"$vineyard","rate_per_ha":"2"}]""", """[{"id":"synthetic"}]""")) {
            assertTrue(runCatching { recover(raw) }.exceptionOrNull() is EvidenceContractFailure)
        }
    }
    @Test fun twentySevenWriterShapedRowsPreserveEverySuppliedField() {
        val row = reader.parseToJsonElement(written(""""registered_uses":[{"crop":"Synthetic","target":"weeds","rates":[{"basis":"other","raw_text":"Retained wording","unit":""}]}],"active_ingredients":[{"name":"Synthetic","concentration_unit":"%"}]""")).jsonArray.single().jsonObject
        val rows = JsonArray((1..27).map { JsonObject(row + ("id" to JsonPrimitive("synthetic-$it"))) })
        val decoded = recover(rows.toString())
        assertEquals(27, decoded.size)
        assertTrue(RetainedJsonFields.preserves(rows, reader.encodeToJsonElement(serializer, decoded)))
    }
    @Test fun serverAndAndroidTerminologyTokensBothValidateWithoutRewriting() {
        for (token in listOf("AU_NZ", "US", "UK", "ZA", "au_nz", "us", "uk", "za")) {
            val input = mapOf("${vineyard}__terminology" to token)
            CleanExitCacheContract.validatePreferences("vinetrack_region_settings", input)
            assertEquals(token, input.values.single())
        }
    }
    @Test fun unknownRegionTokenAndNonStringStillRefuse() {
        for (value in listOf<Any>("UNKNOWN", 7)) {
            assertTrue(runCatching { CleanExitCacheContract.validatePreferences("vinetrack_region_settings", mapOf("${vineyard}__terminology" to value)) }.isFailure)
        }
    }
}
