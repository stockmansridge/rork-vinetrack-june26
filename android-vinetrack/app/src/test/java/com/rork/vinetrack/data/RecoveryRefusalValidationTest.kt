package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

/** Exercises the production refusal callback without changing the recovery policy. */
class RecoveryRefusalValidationTest {
    @Test fun unidentifiedWriteRefusesValidPinPhotoAndTripAfterQueueRecreation() {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val pin = PendingWrite("valid-pin", PendingEntityType.PIN, PendingOpType.UPDATE,
            "{\"pinId\":\"known-pin\",\"isCompleted\":true}", "known-pin", 1, 1)
        val trip = PendingWrite("valid-trip", PendingEntityType.TRIP_GPS, PendingOpType.UPDATE,
            "{}", "known-trip", 1, 1)
        val unknown = PendingWrite("unknown", PendingEntityType.PIN, PendingOpType.DELETE,
            "{\"pinId\":\"unknown-pin\"}", "unknown-pin", 1, 1)
        val frozen = listOf(pin, trip, unknown)
        val queueBytes = json.encodeToString(ListSerializer(PendingWrite.serializer()), frozen)
        val photoFile = Files.createTempFile("refusal-validation", ".jpg").toFile()
        try {
            val bytes = byteArrayOf(1, 2, 3, 4)
            photoFile.writeBytes(bytes)
            val photo = PendingPhotoAttachment(id = "valid-photo", clientPinId = "known-pin", vineyardId = "A",
                localPath = photoFile.absolutePath, createdAt = 1, updatedAt = 1)
            repeat(3) {
                val recreated = json.decodeFromString(ListSerializer(PendingWrite.serializer()), queueBytes)
                val preserved = mutableSetOf<String>()
                var tripReplayCalls = 0
                val result = RecoveryPreservation.preserveBeforeReplay(recreated, mapOf("known-trip" to "B"),
                    mapOf("known-pin" to "A"), null, additionalVineyardIds = setOf(photo.vineyardId),
                    preserve = { preserved += it; true }, quarantine = { it.isEmpty() }, replay = { tripReplayCalls++ })
                assertEquals(setOf("A", "B"), preserved)
                assertFalse(result.didRun)
                assertEquals(0, tripReplayCalls)
                val permit = AffectedPinReplayOrchestration.prepare(recreated, listOf(photo)) { _, _ -> result }
                assertNull(permit)
                assertEquals(frozen, recreated)
                assertArrayEquals(bytes, photoFile.readBytes())
                assertTrue(result.message!!.contains("original records were left unchanged"))
            }
        } finally { photoFile.delete() }
    }
}
