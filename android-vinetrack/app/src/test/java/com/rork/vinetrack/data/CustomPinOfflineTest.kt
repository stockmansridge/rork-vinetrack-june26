package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CustomPinCreateParams
import com.rork.vinetrack.data.model.CustomPinTypeCreateParams
import com.rork.vinetrack.data.model.ManualIssueSegment
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Offline outbox payload tests for the unified pin composer (sql/170 queue).
 *
 * A custom type or Custom pin queued offline must replay byte-identically
 * after an app restart — including the stable client ids that make replays
 * idempotent and the structural custom-type reference. These tests pin the
 * serialization contract used by [CustomPinSync].
 */
class CustomPinOfflineTest {

    /** Same JSON configuration as [CustomPinSync]. */
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test
    fun `offline custom type create keeps its stable client id through the queue`() {
        val op = CustomPinSync.QueuedOp(
            kind = CustomPinSync.QueuedOp.KIND_TYPE_CREATE,
            typeParams = CustomPinTypeCreateParams(
                id = "33333333-3333-3333-3333-333333333333",
                vineyardId = "22222222-2222-2222-2222-222222222222",
                name = "Broken Wire",
            ),
        )
        val decoded = json.decodeFromString(
            CustomPinSync.QueuedOp.serializer(),
            json.encodeToString(CustomPinSync.QueuedOp.serializer(), op),
        )
        assertEquals(CustomPinSync.QueuedOp.KIND_TYPE_CREATE, decoded.kind)
        assertEquals("33333333-3333-3333-3333-333333333333", decoded.typeParams?.id)
        assertEquals("Broken Wire", decoded.typeParams?.name)
    }

    @Test
    fun `offline custom pin keeps its type reference location and segments`() {
        val op = CustomPinSync.QueuedOp(
            kind = CustomPinSync.QueuedOp.KIND_PIN_CREATE,
            pinParams = CustomPinCreateParams(
                id = "44444444-4444-4444-4444-444444444444",
                vineyardId = "22222222-2222-2222-2222-222222222222",
                title = "Broken Wire",
                locationScope = "row",
                customTypeId = "33333333-3333-3333-3333-333333333333",
                paddockId = "block-1",
                latitude = -34.0005,
                longitude = 138.00008,
                clientUpdatedAt = "2026-08-06T10:00:00Z",
                segments = listOf(ManualIssueSegment(3, 1), ManualIssueSegment(3, 2)),
            ),
        )
        val encoded = json.encodeToString(CustomPinSync.QueuedOp.serializer(), op)
        val decoded = json.decodeFromString(CustomPinSync.QueuedOp.serializer(), encoded)
        val params = decoded.pinParams
        assertNotNull(params)
        assertEquals("33333333-3333-3333-3333-333333333333", params?.customTypeId)
        assertEquals("row", params?.locationScope)
        assertEquals(listOf(ManualIssueSegment(3, 1), ManualIssueSegment(3, 2)), params?.segments)

        // The RPC argument names must be exact (p_-prefixed) so the queued
        // payload replays against create_custom_pin without translation.
        val paramsJson = json.parseToJsonElement(encoded).jsonObject["pin_params"]!!.jsonObject
        assertEquals("Broken Wire", paramsJson["p_title"]?.jsonPrimitive?.content)
        assertEquals("row", paramsJson["p_location_scope"]?.jsonPrimitive?.content)
        assertTrue(paramsJson.containsKey("p_custom_type_id"))
    }

    @Test
    fun `queued row segments op round-trips for repair and growth pins`() {
        val op = CustomPinSync.QueuedOp(
            kind = CustomPinSync.QueuedOp.KIND_SEGMENTS,
            pinId = "55555555-5555-5555-5555-555555555555",
            segments = listOf(
                ManualIssueSegment(2, 1), ManualIssueSegment(2, 2),
                ManualIssueSegment(2, 3), ManualIssueSegment(2, 4),
            ),
        )
        val decoded = json.decodeFromString(
            CustomPinSync.QueuedOp.serializer(),
            json.encodeToString(CustomPinSync.QueuedOp.serializer(), op),
        )
        assertEquals("55555555-5555-5555-5555-555555555555", decoded.pinId)
        assertEquals(4, decoded.segments?.size)
    }

    @Test
    fun `replay order is type then pin then segments`() {
        assertTrue(
            CustomPinSync.QueuedOp.replayOrder(CustomPinSync.QueuedOp.KIND_TYPE_CREATE) <
                CustomPinSync.QueuedOp.replayOrder(CustomPinSync.QueuedOp.KIND_PIN_CREATE),
        )
        assertTrue(
            CustomPinSync.QueuedOp.replayOrder(CustomPinSync.QueuedOp.KIND_PIN_CREATE) <
                CustomPinSync.QueuedOp.replayOrder(CustomPinSync.QueuedOp.KIND_SEGMENTS),
        )
    }

    @Test
    fun `unknown queued payloads decode safely instead of crashing the queue`() {
        val legacy = """{"kind":"future_kind","extra_field":true}"""
        val decoded = json.decodeFromString(CustomPinSync.QueuedOp.serializer(), legacy)
        assertEquals("future_kind", decoded.kind)
        assertNull(decoded.typeParams)
        assertNull(decoded.pinParams)
        // An unknown kind sorts after every known kind, so it can never block
        // the ordered replay of real writes.
        assertTrue(CustomPinSync.QueuedOp.replayOrder(decoded.kind) > CustomPinSync.QueuedOp.replayOrder(CustomPinSync.QueuedOp.KIND_SEGMENTS))
    }
}
