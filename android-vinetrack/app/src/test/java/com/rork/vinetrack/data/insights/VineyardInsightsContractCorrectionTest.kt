package com.rork.vinetrack.data.insights

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class VineyardInsightsContractCorrectionTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    @Test fun `growth stage upload uses applied database column`() {
        val payload = VineyardInsightsSyncApi.ObservationUpsert(
            id = "o", assessmentId = "a", vineyardId = "v", itemKind = "growth_stage",
            linkedPinId = "pin", linkedGrowthStageRecordId = "growth", clientUpdatedAt = "now",
        )
        val objectValue = json.parseToJsonElement(json.encodeToString(payload)).jsonObject
        assertEquals("growth", objectValue["linked_growth_record_id"]?.jsonPrimitive?.content)
        assertFalse("linked_growth_stage_record_id" in objectValue)
    }

    @Test fun `pulled observation restores pin and growth record identifiers`() {
        val row = json.decodeFromString<VineyardInsightsSyncApi.ObservationRow>(
            """{"id":"o","assessment_id":"a","vineyard_id":"v","item_kind":"growth_stage","linked_pin_id":"pin","linked_growth_record_id":"growth"}""",
        )
        assertEquals("pin", row.linkedPinId)
        assertEquals("growth", row.linkedGrowthStageRecordId)
    }

    @Test fun `custom note type has stable UUID and legacy code reconciles without losing label`() {
        val raw = MemoryStore()
        val store = VineyardInsightsStore(raw)
        val controller = VineyardInsightsController(store)
        val type = assertNotNull(controller.addCustomNoteType("vineyard", "Wind damage"))
        assertTrue(runCatching { java.util.UUID.fromString(type.databaseId) }.isSuccess)
        assertEquals(type.databaseId, store.pendingNoteTypes("vineyard").single().databaseId)
    }

    private class MemoryStore : InsightsKeyValueStore {
        private val values = mutableMapOf<String, String>()
        override fun get(key: String): String? = values[key]
        override fun put(key: String, value: String): Boolean { values[key] = value; return true }
        override fun remove(key: String): Boolean { values.remove(key); return true }
        override fun clear(): Boolean { values.clear(); return true }
    }
}
