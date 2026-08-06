package com.rork.vinetrack.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Offline outbox payload tests for pin creates (Stage 4A-iv queue).
 *
 * A pin queued offline must replay with its FULL placement — block, fractional
 * row, side, along-row distance, snapped point and the explicit snap flag —
 * exactly as resolved at commit time. These tests pin the serialization
 * contract used by [PinCreateSync] so a payload written today replays
 * losslessly after an app restart or a later app update.
 */
class PinOfflinePayloadTest {

    /** Same JSON configuration as [PinCreateSync]. */
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun fullPlacementInput() = PinRepository.PinInput(
        id = "0f8a3a52-6a1e-4a7e-9a1c-2d3e4f5a6b7c",
        vineyardId = "vineyard-1",
        paddockId = "block-1",
        title = "Vine Issue",
        category = "Vine Issue",
        buttonName = "Vine Issue",
        buttonColor = "green",
        mode = "Repairs",
        side = "left",
        heading = 271.5,
        rowNumber = 19,
        // Fractional rows must survive the queue byte-exactly (19.5 ≠ 19).
        pinRowNumber = 19.5,
        pinSide = "left",
        alongRowDistanceM = 42.25,
        snappedLatitude = -34.001234,
        snappedLongitude = 138.000456,
        snappedToRow = true,
        latitude = -34.001239,
        longitude = 138.000470,
        createdBy = "user-1",
    )

    @Test
    fun `queued payload round-trips the full placement losslessly`() {
        val input = fullPlacementInput()
        val encoded = json.encodeToString(PinRepository.PinInput.serializer(), input)
        val decoded = json.decodeFromString(PinRepository.PinInput.serializer(), encoded)
        assertEquals(input, decoded)
    }

    @Test
    fun `fractional rows and snap columns are written under their server names`() {
        val encoded = json.encodeToString(PinRepository.PinInput.serializer(), fullPlacementInput())
        val obj = json.parseToJsonElement(encoded).jsonObject
        assertEquals(19.5, obj.getValue("pin_row_number").jsonPrimitive.double, 1e-12)
        assertEquals(42.25, obj.getValue("along_row_distance_m").jsonPrimitive.double, 1e-12)
        assertEquals(-34.001234, obj.getValue("snapped_latitude").jsonPrimitive.double, 1e-12)
        assertEquals(138.000456, obj.getValue("snapped_longitude").jsonPrimitive.double, 1e-12)
        assertTrue(obj.getValue("snapped_to_row").jsonPrimitive.boolean)
        assertEquals("left", obj.getValue("pin_side").jsonPrimitive.content)
        assertEquals("block-1", obj.getValue("paddock_id").jsonPrimitive.content)
    }

    @Test
    fun `payloads queued before the snap columns existed still decode safely`() {
        // A legacy outbox row written by an older build: no snapped_* keys.
        val legacy = """
            {"id":"0f8a3a52-6a1e-4a7e-9a1c-2d3e4f5a6b7c","vineyard_id":"vineyard-1",
             "title":"Broken Post","mode":"Repairs","side":"right",
             "row_number":7,"pin_row_number":7.0,"pin_side":"right",
             "along_row_distance_m":12.5,"is_completed":false,
             "latitude":-34.0,"longitude":138.0}
        """.trimIndent()
        val decoded = json.decodeFromString(PinRepository.PinInput.serializer(), legacy)
        assertFalse(decoded.snappedToRow)
        assertEquals(null, decoded.snappedLatitude)
        assertEquals(null, decoded.snappedLongitude)
        assertEquals(7.5 - 0.5, decoded.pinRowNumber!!, 1e-12)
    }

    @Test
    fun `unsnapped placement serialises an explicit false flag, not a missing key`() {
        val input = fullPlacementInput().copy(
            pinRowNumber = null,
            pinSide = null,
            alongRowDistanceM = null,
            snappedLatitude = null,
            snappedLongitude = null,
            snappedToRow = false,
        )
        val encoded = json.encodeToString(PinRepository.PinInput.serializer(), input)
        val obj = json.parseToJsonElement(encoded).jsonObject
        assertFalse(obj.getValue("snapped_to_row").jsonPrimitive.boolean)
    }
}
