package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

/** Conflict read-back through the production coordinator and disk-backed queue recreation. */
class PinCreateConflictTest {
    private val input = PinRepository.PinInput(
        id = "pin", vineyardId = "vineyard-A", createdBy = "account-A",
        paddockId = "block", tripId = "trip", latitude = -34.123456789,
        longitude = 138.987654321, growthStageCode = "EL-23", notes = "Original capture",
        createdAt = "2026-10-10T01:00:00Z", snappedLatitude = -34.123456780,
        snappedLongitude = 138.987654320, snappedToRow = true,
    )
    private val duplicate = Pin("pin", "vineyard-A", createdBy = "account-A")
    private val scope = PendingWriteRepository.ReplayScope("account-A", 1)

    private suspend fun fixture(action: suspend (PendingWriteRepository, ReviewWriteDisk, File) -> Unit) {
        val root = Files.createTempDirectory("pin-conflict").toFile()
        try {
            val disk = ReviewWriteDisk(File(root, "queue"))
            val queue = PendingWriteRepository(disk)
            queue.configureReplayScope { scope }
            action(queue, disk, root)
        } finally { root.deleteRecursively() }
    }

    private fun sync(queue: PendingWriteRepository, read: suspend (PinRepository.PinInput, String) -> Pin?) =
        PinCreateSync(queue, createRemote = { throw BackendError.Server(409, "conflict") }, fetchDuplicate = read)

    private fun assertRetained(original: PendingWrite, queue: PendingWriteRepository, disk: ReviewWriteDisk) {
        val retained = queue.list().single { it.id == original.id }
        assertEquals(original.payloadJson, retained.payloadJson)
        assertEquals(original.clientId, retained.clientId)
        assertEquals(original.createdAt, retained.createdAt)
        assertEquals(original.attemptCount, retained.attemptCount)
        assertNotNull(retained.lastError)
        assertEquals(queue.list(), PendingWriteRepository(disk).list())
    }

    @Test(timeout = 10000) fun verifiedDuplicateAcknowledgesOnlyExactCreateAndLeavesLinkedEvidence() = runBlocking {
        fixture { queue, disk, root ->
            val photo = File(root, "retained.jpg").apply { writeBytes(byteArrayOf(-1, -40, 12, 34, -1, -39)) }
            val bytes = photo.readBytes()
            val linked = queue.enqueue(PendingEntityType.PIN_EDIT, PendingOpType.UPDATE, "{\"growth_stage_code\":\"EL-23\"}", "pin")
            var reads = 0
            val sync = sync(queue) { frozen, actor ->
                reads++; assertEquals(input, frozen); assertEquals("account-A", actor); duplicate
            }
            sync.enqueue(input)
            var callbacks = 0
            sync.replayAll { callbacks++ }
            assertEquals(1, reads)
            assertEquals(0, callbacks) // No full-row publication from a conflict probe.
            assertEquals(listOf(linked), PendingWriteRepository(disk).list())
            assertArrayEquals(bytes, photo.readBytes())
        }
    }

    @Test(timeout = 10000) fun unrelatedConflictOrUnprovenAuthorityNeverAcknowledges() = runBlocking {
        for (remote in listOf(duplicate.copy(id = "other"), duplicate.copy(vineyardId = "other"),
            duplicate.copy(createdBy = "account-B"), duplicate.copy(createdBy = null),
            duplicate.copy(deletedAt = "2026-10-10T02:00:00Z"))) {
            fixture { queue, disk, _ ->
                val sync = sync(queue) { _, _ -> remote }
                val original = sync.enqueue(input)
                sync.replayAll { fail("Conflict published") }
                assertEquals(PendingWriteStatus.BLOCKED, queue.list().single().status)
                assertRetained(original, queue, disk)
            }
        }
        for (actor in listOf<String?>(null, "account-B")) {
            fixture { queue, disk, _ ->
                val sync = sync(queue) { _, _ -> fail("Unproven author must not probe"); null }
                val original = sync.enqueue(input.copy(createdBy = actor))
                sync.replayAll { fail("Conflict published") }
                assertRetained(original, queue, disk)
            }
        }
        fixture { queue, disk, _ ->
            val sync = sync(queue) { _, _ -> queue.configureReplayScope { null }; duplicate }
            val original = sync.enqueue(input)
            sync.replayAll { fail("Revoked callback published") }
            val held = queue.list().single()
            assertEquals(original.payloadJson, held.payloadJson)
            assertEquals(original.id, held.id)
            assertEquals(queue.list(), PendingWriteRepository(disk).list())
            assertEquals(PendingWriteStatus.IN_PROGRESS, held.status)
        }
    }

    @Test(timeout = 10000) fun missingServerRecordRetainsExactOperationWithReviewStatus() = runBlocking {
        fixture { queue, disk, _ ->
            val sync = sync(queue) { _, _ -> null }
            val original = sync.enqueue(input)
            sync.replayAll { fail("Missing row published") }
            assertEquals(PendingWriteStatus.BLOCKED, queue.list().single().status)
            assertRetained(original, queue, disk)
        }
    }

    @Test(timeout = 10000) fun interruptedReadBackRetainsOperationAndPropagatesCancellation() = runBlocking {
        fixture { queue, disk, _ ->
            val started = CompletableDeferred<Unit>()
            val sync = sync(queue) { _, _ -> started.complete(Unit); awaitCancellation() }
            val original = sync.enqueue(input)
            val job = launch { sync.replayAll { fail("Interrupted row published") } }
            started.await()
            job.cancelAndJoin()
            assertTrue(job.isCancelled)
            assertEquals(PendingWriteStatus.FAILED, queue.list().single().status)
            assertRetained(original, queue, disk)
        }
        fixture { queue, disk, _ ->
            val sync = sync(queue) { _, _ -> throw java.io.IOException("private transport detail") }
            val original = sync.enqueue(input)
            sync.replayAll { fail("Failed probe published") }
            val retained = queue.list().single()
            assertEquals(PendingWriteStatus.FAILED, retained.status)
            assertEquals(original.attemptCount + 1, retained.attemptCount)
            assertFalse(retained.lastError.orEmpty().contains("private transport detail"))
            assertEquals(original.payloadJson, retained.payloadJson)
            assertEquals(queue.list(), PendingWriteRepository(disk).list())
        }
    }

    @Test(timeout = 10000) fun heldConflictSurvivesRestartWithoutResendOrReplacementConsumption() = runBlocking {
        fixture { queue, disk, _ ->
            val sync = sync(queue) { _, _ -> null }
            val original = sync.enqueue(input)
            sync.replayAll { fail("Missing row published") }
            val restarted = PendingWriteRepository(disk).apply { configureReplayScope { scope } }
            val held = restarted.list()
            PinCreateSync(restarted, createRemote = { fail("Held conflict resent"); duplicate },
                fetchDuplicate = { _, _ -> fail("Held conflict probed"); duplicate }).replayAll { fail("Held row published") }
            assertEquals(held, restarted.list())
            assertRetained(original, restarted, disk)
        }
        fixture { queue, disk, _ ->
            lateinit var replacement: PendingWrite
            val sync = sync(queue) { _, _ ->
                queue.remove(queue.list().single().id)
                replacement = PinCreateSync(queue).enqueue(input.copy(notes = "Newer capture"))
                duplicate
            }
            sync.enqueue(input)
            sync.replayAll { fail("Obsolete callback published") }
            assertEquals(listOf(replacement), PendingWriteRepository(disk).list())
        }
    }
}
