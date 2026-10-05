package com.rork.vinetrack.data

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class PinCaptureEvidenceContractTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private fun evidence(side: String?, pinSide: String?) = PinCaptureEvidenceStore.Evidence(
        pinId = "pin-1", vineyardId = "vineyard-1", tripId = "trip-1", buttonName = "Repair", mode = "Repair",
        side = side, latitude = -33.0, longitude = 149.0, fixTimeEpochMs = 123456L,
        accuracyMetres = 4.0, observationTimeIso = "2026-10-05T01:20:30Z", headingDegrees = 180.0,
        paddockId = "block-1", pinRowNumber = 32.0, pinSide = pinSide,
        snappedLatitude = -33.0001, snappedLongitude = 149.0002, alongRowDistanceMetres = 15.0,
        snappedToRow = true, drivingRowNumber = 32.5, evidenceRevision = 1,
        geometryRevision = "pin-geometry-v1", geometryHash = "frozen-hash",
    )
    private fun payload(record: PinCaptureEvidenceStore.Evidence): JsonObject =
        json.encodeToJsonElement(PinRepository.captureEvidencePayload(record)).jsonObject

    @Test fun `new evidence RPC emits canonical sides without changing local placement`() {
        for ((input, canonical) in listOf("left" to "Left", "right" to "Right", "LEFT" to "Left", "rIgHt" to "Right")) {
            val record = evidence(input, input)
            val wire = payload(record)
            assertEquals(canonical, wire["pressed_side"]?.jsonPrimitive?.content)
            assertEquals(canonical, wire["supported_pin_side"]?.jsonPrimitive?.content)
            assertEquals(input, record.side)
            assertEquals(input, record.pinSide)
            assertEquals(payload(record.copy(side = canonical, pinSide = canonical)), wire)
        }
    }

    @Test fun `offline decoded evidence uses identical canonical upload and retains geometry`() {
        val original = evidence("left", "right")
        val restored = json.decodeFromString<PinCaptureEvidenceStore.Evidence>(json.encodeToString(original))
        val wire = payload(restored)
        assertEquals(payload(original), wire)
        assertEquals(original, restored)
        assertEquals("Left", wire["pressed_side"]?.jsonPrimitive?.content)
        assertEquals("Right", wire["supported_pin_side"]?.jsonPrimitive?.content)
        assertEquals(32.0, wire["supported_pin_row"]!!.jsonPrimitive.double, 0.0)
        assertEquals(32.5, wire["supported_driving_row"]!!.jsonPrimitive.double, 0.0)
        assertEquals(-33.0001, wire["supported_snapped_latitude"]!!.jsonPrimitive.double, 0.0)
        assertEquals(149.0002, wire["supported_snapped_longitude"]!!.jsonPrimitive.double, 0.0)
        assertEquals("frozen-hash", wire["geometry_hash"]!!.jsonPrimitive.content)
    }

    @Test fun `23514 failure survives disk reload and retries same revision without duplicates`() = runBlocking {
        val disk = Files.createTempFile("pin-evidence-contract", ".json").toFile()
        try {
            val original = evidence("left", "right")
            disk.writeText(json.encodeToString(listOf(original)))
            fun records(): List<PinCaptureEvidenceStore.Evidence> = json.decodeFromString(disk.readText())
            val acknowledgements = mutableListOf<Pair<String, Int>>()
            val mark: (String, Int) -> Boolean = { id, revision ->
                acknowledgements.add(id to revision)
                disk.writeText(json.encodeToString(records().map {
                    if (it.pinId == id && it.evidenceRevision == revision) it.copy(uploaded = true) else it
                }))
                true
            }
            val failedAttempt = mutableListOf<JsonObject>()
            replayPinCaptureEvidence(records().filterNot { it.uploaded }, {
                failedAttempt.add(payload(it))
                throw BackendError.Server(400, "23514 check constraint violation")
            }, mark)
            assertTrue(acknowledgements.isEmpty())
            assertEquals(listOf(original), records())
            val server = mutableMapOf<Pair<String, Int>, JsonObject>()
            val upload: suspend (PinCaptureEvidenceStore.Evidence) -> Unit = {
                val identity = it.pinId to it.evidenceRevision
                val wire = payload(it)
                assertEquals(failedAttempt.single(), wire)
                val previous = server.putIfAbsent(identity, wire)
                if (previous != null) assertEquals(previous, wire)
            }
            val restoredPending = records().filterNot { it.uploaded }
            replayPinCaptureEvidence(restoredPending, upload, mark)
            // Model a repeated delivery after an uncertain acknowledgement: same server identity, no new revision.
            replayPinCaptureEvidence(restoredPending, upload, mark)
            assertEquals(1, server.size)
            assertEquals(listOf(original.copy(uploaded = true)), records())
            assertTrue(records().filterNot { it.uploaded }.isEmpty())
            assertTrue(acknowledgements.all { it == (original.pinId to original.evidenceRevision) })
        } finally { disk.delete() }
    }

    @Test fun `null and non directional evidence values are not invented or changed`() {
        assertEquals(JsonNull, payload(evidence(null, null))["pressed_side"])
        assertEquals(JsonNull, payload(evidence(null, null))["supported_pin_side"])
        assertEquals("none", payload(evidence("none", null))["pressed_side"]?.jsonPrimitive?.content)
    }
}
