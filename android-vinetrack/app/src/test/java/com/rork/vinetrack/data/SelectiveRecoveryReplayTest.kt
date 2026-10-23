package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class SelectiveRecoveryReplayTest {
    private val unknown = PendingWrite("delete", PendingEntityType.PIN, PendingOpType.DELETE,
        """{"pinId":"de6db596-f48b-416e-8af3-6f15c44633ed"}""",
        "de6db596-f48b-416e-8af3-6f15c44633ed", 1, 1,
        status = PendingWriteStatus.BLOCKED, attemptCount = 2,
        lastError = "This saved change couldn't be linked to a vineyard")

    @Test fun unknownBlockedDeleteDoesNotBlockIndependentOriginalCreateAfterRestart() = runBlocking {
        val disk = InMemoryPendingWriteStore()
        val first = PendingWriteRepository(disk)
        val create = PinCreateSync(first).enqueue(PinRepository.PinInput(
            id = "e6f85a09-c6fe-4390-9740-018fac176d71", vineyardId = "A", createdBy = "owner"))
        disk.save(listOf(create, unknown))
        val queue = PendingWriteRepository(disk)
        queue.configureReplayScope { PendingWriteRepository.ReplayScope("owner", 1) }
        val result = RecoveryPreservation.preserveSelective(queue.list(), emptyMap(), emptyMap(), null, preserve = { true })
        assertTrue(result.didRun)
        assertEquals(setOf(create.id), result.permittedWriteIds)
        assertEquals(setOf(unknown.id), result.unresolvedWriteIds)
        var calls = 0
        PinCreateSync(queue) { input ->
            calls++; assertEquals(create.clientId, input.id)
            Pin(requireNotNull(input.id), input.vineyardId, createdBy = "owner")
        }.replayAll(result.permittedWriteIds, queue.freezeReplayVersions(queue.list().filter { it.id in result.permittedWriteIds })) {}
        assertEquals(1, calls)
        assertEquals(listOf(unknown), queue.list())
        assertEquals(listOf(unknown), PendingWriteRepository(disk).list())
    }

    @Test fun unreadableOrLowStorageVineyardHoldsOnlyItsOwnWritesAndPhotos() {
        val good = PendingWrite("good", PendingEntityType.PIN, PendingOpType.CREATE,
            """{"id":"pin-good","vineyard_id":"A"}""", "pin-good", 1, 1)
        val bad = good.copy(id = "bad", clientId = "pin-bad", payloadJson = """{"id":"pin-bad","vineyard_id":"B"}""")
        val photos = listOf("A", "B").map { vineyard -> PendingPhotoAttachment(
            id = "photo-$vineyard", clientPinId = "pin-$vineyard", vineyardId = vineyard,
            localPath = "synthetic-only", createdAt = 1, updatedAt = 1) }
        val permit = AffectedPinReplayOrchestration.prepare(listOf(good, bad, unknown), photos) { writes, vineyards ->
            RecoveryPreservation.preserveSelective(writes, emptyMap(), emptyMap(), null, vineyards) {
                if (it == "B") throw java.io.IOException("synthetic full/unreadable")
                true
            }
        }!!
        assertEquals(setOf(good.id), permit.writeIds)
        assertEquals(setOf("photo-A"), permit.replayPhotoIds)
        assertEquals(setOf("photo-A"), permit.retainedPhotoPermits.mapTo(mutableSetOf()) { it.id })
        assertEquals(good, permit.writeVersions[good.id])
    }

    @Test fun heldDependencyIsStillVisibleAndCannotBeBypassed() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val create = queue.enqueue(PendingEntityType.PIN, PendingOpType.CREATE, "unreadable", unknown.clientId)
        queue.updateStatus(create.id, PendingWriteStatus.BLOCKED, "retained")
        val photos = PendingPhotoRepository(java.io.File("synthetic-unused"), object : PendingPhotoStoring {
            override fun load() = emptyList<PendingPhotoAttachment>()
            override fun save(attachments: List<PendingPhotoAttachment>) = Unit
            override fun loadCompletedCache() = emptyList<CompletedPhotoCacheEntry>()
            override fun saveCompletedCache(entries: List<CompletedPhotoCacheEntry>) = Unit
            override fun clear() = Unit
        })
        var deletes = 0
        val sync = PinDeleteSync(PinDeleteGateway { deletes++ }, queue, photos)
        val delete = sync.enqueue(unknown.clientId)
        sync.replayAll(permittedWrites = queue.freezeReplayVersions(listOf(delete))) {}
        assertEquals(0, deletes)
        assertEquals(0, queue.list().single { it.id == delete.id }.attemptCount)
        assertEquals(PendingWriteStatus.FAILED, queue.list().single { it.id == delete.id }.status)
    }

    @Test(timeout = 10000) fun synthetic4584PointEvidenceBenchmarkWithOfflineRecords() {
        val points = List(4584) { CoordinatePoint(0.0 + it * 0.000001, 1.0 + it * 0.000001) }
        val records = List(100) { index -> PendingWrite("write-$index", PendingEntityType.PIN, PendingOpType.CREATE,
            """{"id":"pin-$index","vineyard_id":"A"}""", "pin-$index", 1, 1) } + unknown
        val codec = kotlinx.serialization.json.Json { encodeDefaults = true }
        val snapshot = ActiveTripStore.Snapshot("owner", "A", Trip("synthetic-trip", "A", pathPoints = points), 1)
        val raw = codec.encodeToString(ActiveTripStore.Snapshot.serializer(), snapshot)
        val storage = object : ActiveTripSnapshotStorage {
            override fun read() = raw
            override fun write(value: String) = error("Benchmark must not replace original bytes")
            override fun remove() = error("Benchmark must not clear original bytes")
        }
        val store = ActiveTripStore(storage)
        val samples = LongArray(30)
        val coldDecode = LongArray(30)
        val unchangedRead = LongArray(30)
        repeat(5) { assertTrue(TripGpsSync.containsEvidence(points, points)); store.load() }
        repeat(samples.size) { index ->
            val start = System.nanoTime()
            assertTrue(TripGpsSync.containsEvidence(points, points))
            val result = RecoveryPreservation.preserveSelective(records, emptyMap(), emptyMap(), null, preserve = { true })
            assertEquals(100, result.permittedWriteIds.size)
            samples[index] = System.nanoTime() - start
            val decodeStart = System.nanoTime()
            assertEquals(snapshot, codec.decodeFromString(ActiveTripStore.Snapshot.serializer(), raw))
            coldDecode[index] = System.nanoTime() - decodeStart
            val readStart = System.nanoTime()
            assertEquals(snapshot, store.load())
            unchangedRead[index] = System.nanoTime() - readStart
        }
        fun report(label: String, values: LongArray) {
            values.sort()
            println("SYNC_BENCHMARK stage=$label syntheticPoints=4584 offlineRecords=100 iterations=30 medianMs=${values[15] / 1_000_000.0} p95Ms=${values[28] / 1_000_000.0} maxMs=${values.last() / 1_000_000.0}")
        }
        report("verification-and-admission", samples)
        report("uncached-snapshot-decode-reference", coldDecode)
        report("unchanged-snapshot-read", unchangedRead)
        assertEquals(raw, storage.read())
    }
}
