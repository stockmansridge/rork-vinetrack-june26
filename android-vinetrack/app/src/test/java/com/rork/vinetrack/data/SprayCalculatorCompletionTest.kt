package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class SprayCalculatorCompletionTest {
    private val input = SprayRecordRepository.SprayInput(date = "2026-10-14", startTime = "12:00", temperature = null,
        windSpeed = null, windDirection = null, humidity = null, sprayReference = "Synthetic", notes = "Original",
        numberOfFansJets = null, averageSpeed = null, equipmentType = null, tractor = null, tractorGear = null, machineId = null, sprayEquipmentId = null, operationType = null, tripId = null, tanks = emptyList())

    @Test fun failedPendingCreateReplacementRetainsOriginalDurableEvidence() {
        var disk: List<PendingWrite> = emptyList()
        var reject = false
        val store = object : PendingWriteStoring {
            override fun load() = disk
            override fun save(writes: List<PendingWrite>): Boolean {
                // Reproduce interruption after deletion but before replacement.
                if (reject && writes.isNotEmpty()) return false
                disk = writes
                return true
            }
            override fun clear(): Boolean { disk = emptyList(); return true }
        }
        val queue = PendingWriteRepository(store)
        val sync = SprayRecordCreateSync(null, queue)
        val original = sync.enqueue("record", "vineyard", input, "revision1")
        reject = true
        assertThrows(IllegalStateException::class.java) { sync.foldEdit("record", input.copy(notes = "Edited"), "revision2") }
        assertEquals(listOf(original), queue.list())
        assertEquals(listOf(original), PendingWriteRepository(store).list())
    }

    @Test fun blockedAndInFlightCreatesCannotBeReplacedOrUnblocked() {
        for (status in listOf(PendingWriteStatus.BLOCKED, PendingWriteStatus.IN_PROGRESS)) {
            val queue = PendingWriteRepository(InMemoryPendingWriteStore())
            val sync = SprayRecordCreateSync(null, queue)
            val original = sync.enqueue("record", "vineyard", input, "revision1")
            queue.incrementAttempt(original.id)
            queue.updateStatus(original.id, status, "Retained evidence")
            val before = queue.list()
            assertThrows(IllegalStateException::class.java) { sync.foldEdit("record", input.copy(notes = "Edited"), "revision2") }
            assertEquals(before, queue.list())
        }
    }

    @Test fun pendingCreateEditKeepsOperationScopeAndRetryMetadata() {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val sync = SprayRecordCreateSync(null, queue)
        val original = sync.enqueue("record", "vineyard", input, "revision1")
        queue.incrementAttempt(original.id)
        queue.updateStatus(original.id, PendingWriteStatus.FAILED, "Offline")
        val before = queue.list().single()
        assertTrue(sync.foldEdit("record", input.copy(notes = "Edited"), "revision2"))
        val after = queue.list().single()
        assertEquals(before.id, after.id)
        assertEquals(before.createdAt, after.createdAt)
        assertEquals(before.attemptCount, after.attemptCount)
        val payload = Json.decodeFromString(SprayRecordCreateSync.Payload.serializer(), after.payloadJson)
        assertEquals("vineyard", payload.vineyardId)
        assertEquals("Edited", payload.notes)
        assertEquals("revision2", payload.clientUpdatedAt)
    }
}
