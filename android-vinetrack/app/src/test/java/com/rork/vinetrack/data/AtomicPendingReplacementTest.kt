package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/** Production enqueue paths with durable failure/recreation, not migration fixtures. */
class AtomicPendingReplacementTest {
    private val trip = Trip("trip", "vineyard", isActive = true, clientUpdatedAt = "2026-10-10T00:00:00Z")
    private fun tanks(queue: PendingWriteRepository) = TripTankSync(null, queue, ActiveTripStore(object : ActiveTripSnapshotStorage {
        override fun read(): String? = null
        override fun write(value: String) { error("Unexpected snapshot write") }
        override fun remove() { error("Unexpected snapshot removal") }
    }))

    @Test fun failedCompletionReplacementRetainsExactEarlierOperationAcrossRestart() = failure(false, false)
    @Test fun thrownCompletionReplacementRetainsExactEarlierOperationAcrossRestart() = failure(false, true)
    @Test fun failedTankReplacementRetainsExactEarlierOperationAcrossRestart() = failure(true, false)
    @Test fun thrownTankReplacementRetainsExactEarlierOperationAcrossRestart() = failure(true, true)

    private fun failure(tank: Boolean, throws: Boolean) {
        val root = Files.createTempDirectory("atomic-markers").toFile()
        try {
            val file = File(root, "queue")
            val disk = ReviewWriteDisk(file)
            var failSave = false
            var saves = 0
            val adapter = object : PendingWriteStoring {
                override fun load() = disk.load()
                override fun clear() = disk.clear()
                override fun save(writes: List<PendingWrite>): Boolean {
                    saves++
                    if (failSave) {
                        if (throws) throw java.io.IOException("Injected persistence failure")
                        return false
                    }
                    return disk.save(writes)
                }
            }
            val queue = PendingWriteRepository(adapter)
            val completion = PinCompletionSync(queue) { id, value -> Pin(id, "vineyard", isCompleted = value) }
            val sync = tanks(queue)
            val original = if (tank) sync.enqueue(trip) else completion.enqueue("pin", true)
            val before = file.readBytes()
            failSave = true
            try {
                if (tank) sync.enqueue(trip.copy(activeTankNumber = 2)) else completion.enqueue("pin", false)
                fail("Failed persistence accepted")
            } catch (_: IllegalStateException) { } catch (_: java.io.IOException) { }
            assertEquals(2, saves)
            assertEquals(listOf(original), queue.list())
            assertEquals(1, queue.currentPendingCount())
            assertArrayEquals(before, file.readBytes())
            assertEquals(listOf(original), PendingWriteRepository(ReviewWriteDisk(file)).list())
        } finally { root.deleteRecursively() }
    }

    @Test fun successfulReplacementUsesOneCommitFreshIdentityAndKeepsOtherDiscriminators() {
        val store = InMemoryPendingWriteStore()
        var saves = 0
        val queue = PendingWriteRepository(object : PendingWriteStoring {
            override fun load() = store.load()
            override fun clear() = store.clear()
            override fun save(writes: List<PendingWrite>): Boolean { saves++; return store.save(writes) }
        })
        val completion = PinCompletionSync(queue) { id, value -> Pin(id, "vineyard", isCompleted = value) }
        val original = completion.enqueue("pin", true)
        val unrelated = queue.enqueue(PendingEntityType.PIN_EDIT, PendingOpType.UPDATE, "{}", "pin")
        val claimed = requireNotNull(queue.claimReplay(original))
        val beforeSaves = saves
        val replacement = completion.enqueue("pin", false)
        assertEquals(beforeSaves + 1, saves)
        assertNotEquals(original.id, replacement.id)
        assertEquals(listOf(unrelated, replacement), queue.list())
        assertFalse(queue.removeIfCurrent(claimed))
        assertEquals(0, replacement.attemptCount)
    }

    @Test fun tankReplacementPreservesEarliestBaselineAndSyncedHistoryAcrossRestart() {
        val root = Files.createTempDirectory("atomic-tank-baseline").toFile()
        try {
            val file = File(root, "queue")
            val queue = PendingWriteRepository(ReviewWriteDisk(file))
            val sync = tanks(queue)
            val original = sync.enqueue(trip.copy(activeTankNumber = 1))
            val replaced = sync.enqueue(trip.copy(tankSessions = listOf(TankSession("session", 2)), activeTankNumber = 2,
                clientUpdatedAt = "2026-10-10T01:00:00Z"))
            val payload = SupabaseClient.json.decodeFromString(TripTankSync.Payload.serializer(), replaced.payloadJson)
            assertNotEquals(original.id, replaced.id)
            assertEquals(0, payload.baseSessionCount)
            assertEquals(1, payload.baseActiveTankNumber)
            assertEquals(trip.clientUpdatedAt, payload.baseClientUpdatedAt)
            val restarted = PendingWriteRepository(ReviewWriteDisk(file))
            assertEquals(listOf(replaced), restarted.list())
            restarted.markSynced(replaced.id)
            val history = restarted.list().single()
            val next = tanks(restarted).enqueue(trip)
            assertEquals(listOf(history, next), PendingWriteRepository(ReviewWriteDisk(file)).list())
        } finally { root.deleteRecursively() }
    }
}
