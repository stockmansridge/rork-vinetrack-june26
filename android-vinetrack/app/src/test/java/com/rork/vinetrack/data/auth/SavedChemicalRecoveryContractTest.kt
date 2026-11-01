package com.rork.vinetrack.data.auth

import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.chemical.VineyardPreferredRate
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Production serializers, not JSON/model doubles. All fixtures are synthetic. */
class SavedChemicalRecoveryContractTest {
    private val owner = "00000000-0000-4000-8000-0000000000a1"
    private val vineyard = "00000000-0000-4000-8000-0000000000b2"
    private val other = "00000000-0000-4000-8000-0000000000c3"
    private val id = "00000000-0000-4000-8000-0000000000d4"
    private val codec = Json { encodeDefaults = true; ignoreUnknownKeys = false }
    private val serializer = ListSerializer(SavedChemical.serializer())
    private fun row(scope: String = vineyard): JsonObject = codec.encodeToJsonElement(
        SavedChemical.serializer(), SavedChemical(id, scope, name = "Synthetic chemical", ratePerHa = 1.5),
    ).jsonObject
    private fun values(row: JsonObject, key: String = "$owner|$vineyard") =
        linkedMapOf<String, Any>(key to JsonArray(listOf(row)).toString())
    private fun recover(values: Map<String, *>, original: String = owner) =
        CleanExitCacheContract.chemicalRecoveryScopes(values, emptyMap<String, Any>(), original)
    private fun denied(rule: String, action: () -> Unit) {
        val error = runCatching(action).exceptionOrNull()
        assertTrue("Expected fixed diagnostic, got ${error?.javaClass?.simpleName}", error is EvidenceContractFailure)
        val evidence = (error as EvidenceContractFailure).diagnostic
        assertEquals("vinetrack_saved_chemicals_local", evidence.category)
        assertEquals(rule, evidence.rule)
        assertNull(error.cause)
        assertFalse(evidence.toString().contains(owner))
        assertFalse(evidence.toString().contains(vineyard))
        assertFalse(evidence.toString().contains("PRIVATE_SENTINEL"))
    }
    @Test fun currentWriterEncodingRecoversWithoutChangingSource() {
        val input = values(row()); val before = input.toMap()
        assertEquals(setOf(vineyard), recover(input))
        assertEquals(before, input)
    }
    @Test fun olderSnapshotMissingNewOptionalFieldRecoversWithoutBackfillingIt() {
        val old = JsonObject(row() - "vineyard_preferred_rate")
        val encoded = JsonArray(listOf(old))
        val decoded = codec.decodeFromJsonElement(serializer, encoded)
        // The previous gate fails this supported decode solely because it adds a nullable field.
        assertNotEquals(encoded, codec.encodeToJsonElement(serializer, decoded))
        val input = values(old); val before = input.toMap()
        assertEquals(setOf(vineyard), recover(input))
        assertEquals(before, input)
        assertFalse(input.values.single().toString().contains("vineyard_preferred_rate"))
    }
    @Test fun oldOmittedDefaultsAreNotClassifiedAsLostData() {
        val old = Json { encodeDefaults = false }.encodeToJsonElement(
            SavedChemical.serializer(), SavedChemical(id, vineyard, name = "Synthetic old chemical"),
        ).jsonObject
        val input = values(old); val before = input.toMap()
        assertEquals(setOf(vineyard), recover(input)); assertEquals(before, input)
    }
    @Test fun legacyRateWithoutUiIdRetainsQuantityAndBasis() {
        val rates = codec.parseToJsonElement("""[{"value":300,"basis":"Per 100 L"}]""")
        val input = values(JsonObject(row() + ("rates" to rates)))
        val before = input.toMap()
        assertEquals(setOf(vineyard), recover(input)); assertEquals(before, input)
    }
    @Test fun storageAccountNamespaceIsNotSilentlyRedirected() {
        // The store's load/save keys are exact. Do not admit an alias namespace
        // without separately proving that ordinary reads address that namespace.
        denied("CHEMICAL_ORIGINAL_ACCOUNT_MISMATCH") {
            recover(values(row(), "${owner.uppercase()}|$vineyard"))
        }
    }
    @Test fun storageVineyardNamespaceRemainsExact() {
        denied("CHEMICAL_RECORD_SCOPE") {
            recover(values(row(), "$owner|${vineyard.uppercase()}"))
        }
    }
    @Test fun differentAccountIsStillRefused() {
        denied("CHEMICAL_ORIGINAL_ACCOUNT_MISMATCH") { recover(values(row()), other) }
    }
    @Test fun differentVineyardIsStillRefused() {
        denied("CHEMICAL_RECORD_SCOPE") { recover(values(row(other))) }
    }
    @Test fun arbitraryNonUuidCaseIsNotNormalised() {
        denied("CHEMICAL_RECORD_SCOPE") { recover(values(row("Vineyard"), "$owner|vineyard")) }
    }
    @Test fun duplicateRecordIdsAreRefused() {
        val alias = row()
        val input = mapOf("$owner|$vineyard" to JsonArray(listOf(row(), alias)).toString())
        denied("CHEMICAL_DUPLICATE_RECORD_ID") { recover(input) }
    }
    @Test fun malformedAndUnscopedSnapshotsAreNotEmptyCaches() {
        denied("CHEMICAL_KEY_SCOPE") { recover(mapOf(vineyard to "[]")) }
        denied("CHEMICAL_JSON_SCHEMA") { recover(mapOf("$owner|$vineyard" to "PRIVATE_SENTINEL")) }
        denied("CHEMICAL_JSON_SCHEMA") { recover(mapOf("$owner|$vineyard" to "{}")) }
        denied("CHEMICAL_DECODE_SCHEMA") { recover(mapOf("$owner|$vineyard" to "[{}]")) }
    }
    @Test fun unknownTopLevelFieldsRemainProtected() {
        denied("CHEMICAL_DECODE_SCHEMA") {
            recover(values(JsonObject(row() + ("future_private_value" to JsonPrimitive("PRIVATE_SENTINEL")))))
        }
    }
    @Test fun lossyLegacyRateParserCannotEraseMalformedEvidence() {
        denied("CHEMICAL_SUPPLIED_FIELDS_CHANGED") {
            recover(values(JsonObject(row() + ("rates" to codec.parseToJsonElement("""[{"unreadable":"PRIVATE_SENTINEL"}]""")))))
        }
        denied("CHEMICAL_SUPPLIED_FIELDS_CHANGED") {
            recover(values(JsonObject(row() + ("rates" to JsonPrimitive("PRIVATE_SENTINEL")))))
        }
    }
    @Test fun invalidPreferredRateStillRefuses() {
        val invalid = codec.encodeToJsonElement(SavedChemical.serializer(), SavedChemical(id, vineyard,
            vineyardPreferredRate = VineyardPreferredRate(0.0, "L", "per_hectare"))).jsonObject
        denied("CHEMICAL_PREFERRED_RATE_INVALID") { recover(values(invalid)) }
    }
    @Test fun unresolvedWritesStillBlockCleanExit() {
        denied("CHEMICAL_PENDING_WRITES_HELD") {
            CleanExitCacheContract.validateSavedChemicals(values(row()), mapOf("pending_writes_json" to "[{}]"))
        }
    }
    @Test fun numericFormattingMayDifferButNotNumericValue() {
        assertTrue(RetainedJsonFields.preserves(JsonPrimitive(300), JsonPrimitive(300.0)))
        assertFalse(RetainedJsonFields.preserves(JsonPrimitive("300"), JsonPrimitive(300.0)))
        assertFalse(RetainedJsonFields.preserves(codec.parseToJsonElement("9007199254740993"), codec.parseToJsonElement("9007199254740992")))
        assertFalse(RetainedJsonFields.preserves(JsonPrimitive(1.5), JsonPrimitive(1.6)))
    }
    @Test fun suppliedFieldsAndArrayOrderMayNotDisappear() {
        assertFalse(RetainedJsonFields.preserves(codec.parseToJsonElement("""{"value":2}"""), JsonObject(emptyMap())))
        assertFalse(RetainedJsonFields.preserves(codec.parseToJsonElement("[1,2]"), codec.parseToJsonElement("[2,1]")))
        assertFalse(RetainedJsonFields.preserves(codec.parseToJsonElement("[1,2]"), codec.parseToJsonElement("[1]")))
        assertFalse(RetainedJsonFields.preserves(JsonNull, JsonPrimitive(0)))
    }
    @Test fun populatedMixedLegacyAndCurrentChemicalListSurvivesUnchanged() {
        val rows = (0 until 100).map { index -> JsonObject(
            row() + ("id" to JsonPrimitive("synthetic-$index")) +
                ("notes" to JsonPrimitive("Synthetic retained information ".repeat(25))) -
                if (index % 2 == 0) setOf("vineyard_preferred_rate") else emptySet(),
        ) }
        val input = mapOf("$owner|$vineyard" to JsonArray(rows).toString()); val before = input.toMap()
        assertEquals(setOf(vineyard), recover(input)); assertEquals(before, input)
    }
}
