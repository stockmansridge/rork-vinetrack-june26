package com.rork.vinetrack.data

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Golden/decoder contract tests only; no authenticated PostgreSQL calls. */
class LegacySprayPairReceiptTest {
    private val golden = Json.parseToJsonElement(requireNotNull(javaClass.classLoader?.getResource("legacy-spray-pair-v1-golden.json")).readText()).jsonObject
    private val request = golden.getValue("request").jsonObject
    private val trip = request.getValue("p_trip").jsonObject
    private val record = request.getValue("p_record").jsonObject
    @Test fun postgresGoldenHashUsesExactPostgresTextAndNotSerializerBytes() {
        val bytes = golden.getValue("postgres_jsonb_canonical_text").jsonPrimitive.content.toByteArray(Charsets.UTF_8)
        assertEquals(944, bytes.size)
        assertEquals(golden.getValue("postgres_sha256_hex").jsonPrimitive.content,
            java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
        assertTrue(trip.keys.all { it in LegacySprayPairReceipt.tripKeys })
        assertTrue(record.keys.all { it in LegacySprayPairReceipt.recordKeys })
    }
    @Test fun payloadFreezesOperationAndBodiesWithoutAClientHash() {
        val frozen = LegacySprayPairReceipt.prepare(trip, record)
        assertEquals(trip, frozen.body()["p_trip"])
        assertEquals(record, frozen.body()["p_record"])
        assertEquals(frozen.body(), frozen.body())
        assertEquals(setOf("p_operation_id", "p_trip", "p_record"), frozen.body().keys)
        java.util.UUID.fromString(frozen.operation)
    }
    @Test fun unknownPlanningFieldsAreRefusedRatherThanStripped() {
        for (field in listOf("planning_target_area_ha", "end_time", "created_at", "block_ids", "sync_version")) {
            assertTrue(runCatching { LegacySprayPairReceipt.prepare(trip, JsonObject(record + (field to JsonPrimitive(1)))) }.isFailure)
        }
        assertTrue(runCatching { LegacySprayPairReceipt.prepare(JsonObject(trip + ("occurrence_coverage" to buildJsonObject {})), record) }.isFailure)
    }
    @Test fun errorsAndRowsetsCannotBeReceiptObjects() {
        for (value in listOf("[]", "{}", "{\"code\":\"409\"}", "null", "not json")) {
            assertTrue(runCatching { LegacySprayPairReceipt.decode(value) }.isFailure)
        }
    }
    @Test fun unknownAndConflictAreNotSuccessfulStatuses() {
        val unknown = LegacySprayPairReceipt.decode("{\"version\":1,\"status\":\"unknown\",\"operation_id\":\"${request["p_operation_id"]?.jsonPrimitive?.content}\"}")
        val conflict = LegacySprayPairReceipt.decode("{\"version\":1,\"status\":\"conflict\",\"code\":\"operation_payload_mismatch\"}")
        assertEquals("unknown", unknown.status); assertEquals("conflict", conflict.status)
        assertNull(conflict.request_sha256)
    }
}
