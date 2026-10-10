package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Focused production start/reconciliation seams with durable host recreation. */
class TripStartReliabilityTest {
    private val json = SupabaseClient.json
    private val start = "2026-10-10T00:00:00Z"
    private val edited = "2026-10-10T01:00:00Z"
    private val trip = reviewTrip().copy(startTime = start, tripTitle = "original", startEngineHours = 100.0,
        clientUpdatedAt = start, manualCorrectionEvents = emptyList())

    private fun metadata(queue: PendingWriteRepository, title: String?, hours: Double?, id: String = trip.id): PendingWrite =
        queue.enqueue(PendingEntityType.TRIP_METADATA, PendingOpType.UPDATE,
            json.encodeToString(TripMetadataSync.Payload.serializer(), TripMetadataSync.Payload(
                id, tripTitle = title, startEngineHours = hours, clientUpdatedAt = edited, baseClientUpdatedAt = start)), id)

    @Test(timeout = 10000) fun delayedStartReplyPreservesDurableScalarIntentAndLiveRuntime() = runBlocking {
        val root = Files.createTempDirectory("trip-start-delay").toFile()
        try {
            val file = File(root, "queue")
            val localFile = File(root, "local")
            val queue = PendingWriteRepository(ReviewWriteDisk(file))
            val entered = CompletableDeferred<Unit>()
            val response = CompletableDeferred<Trip>()
            val sync = TripStartSync(queue, { entered.complete(Unit); response.await() }) { _, _ -> error("No activation") }
            sync.enqueue(trip)
            var published: Trip? = null
            val replay = async {
                sync.replayAll { server ->
                    val saved = json.decodeFromString(Trip.serializer(), localFile.readText())
                    published = TripStartReconciliation.reconcile(server, saved, queue.list())
                }
            }
            entered.await()
            val local = trip.copy(tripTitle = "new title", startEngineHours = 234.567,
                personName = "local person", clientUpdatedAt = edited,
                isPaused = true, pathPoints = listOf(CoordinatePoint(-33.123456789, 149.987654321)),
                totalDistance = 78.9, completedPaths = listOf(1.5), skippedPaths = listOf(2.5),
                sequenceIndex = 2, currentRowNumber = 3.5, nextRowNumber = 4.5,
                tankSessions = listOf(TankSession("tank", 2, startTime = edited)), activeTankNumber = 2,
                isFillingTank = true, fillingTankNumber = 3,
                pauseTimestamps = listOf(edited), resumeTimestamps = listOf(start),
                completionNotes = "local notes", endEngineHours = 240.123)
            val pending = metadata(queue, local.tripTitle, local.startEngineHours)
            commitReviewBytes(localFile, json.encodeToString(Trip.serializer(), local).toByteArray())
            // A restart can recover the exact scalar marker and saved values before the old reply arrives.
            assertEquals(pending, PendingWriteRepository(ReviewWriteDisk(file)).list().last())
            response.complete(trip.copy(personName = "server person", tripTitle = "stale", startEngineHours = 99.0))
            replay.await()
            assertEquals(local.copy(personName = "server person"), published)
            assertEquals(listOf(pending), queue.list())
            assertEquals(listOf(pending), PendingWriteRepository(ReviewWriteDisk(file)).list())
        } finally { root.deleteRecursively() }
    }

    @Test fun legitimateServerScalarsAreAdoptedWithoutMatchingUnresolvedEdit() {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        metadata(queue, "unrelated", 400.0, "other-trip")
        val resolved = metadata(queue, "resolved", 500.0)
        queue.markSynced(resolved.id)
        val server = trip.copy(tripTitle = "server title", startEngineHours = 150.123, personName = "server operator")
        val reconciled = TripStartReconciliation.reconcile(server, trip, queue.list())
        assertEquals(server, reconciled)
    }

    @Test fun unresolvedEditsIncludingBlockedConflictsKeepExactNullableScalarsWithoutAuthorisingServerWrites() {
        for (status in PendingWriteStatus.unresolved) {
            val queue = PendingWriteRepository(InMemoryPendingWriteStore())
            val pending = metadata(queue, null, null)
            queue.updateStatus(pending.id, status, "Existing conflict")
            val before = queue.list()
            val server = trip.copy(tripTitle = "newer remote", startEngineHours = 777.0, clientUpdatedAt = edited,
                personName = "remote person")
            val reconciled = TripStartReconciliation.reconcile(server, trip, queue.list())
            assertNull(reconciled.tripTitle)
            assertNull(reconciled.startEngineHours)
            assertEquals("remote person", reconciled.personName)
            assertEquals(trip.clientUpdatedAt, reconciled.clientUpdatedAt)
            assertEquals(before, queue.list())
            val payload = json.decodeFromString(TripMetadataSync.Payload.serializer(), before.single().payloadJson)
            assertEquals(start, payload.baseClientUpdatedAt)
            assertEquals(edited, payload.clientUpdatedAt)
        }
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        queue.enqueue(PendingEntityType.TRIP_METADATA, PendingOpType.UPDATE, "unreadable", trip.id)
        assertEquals(trip, TripStartReconciliation.reconcile(trip.copy(tripTitle = "stale", startEngineHours = 1.0), trip, queue.list()))
        assertEquals(trip, TripStartReconciliation.reconcile(trip.copy(vineyardId = "foreign"), trip, queue.list()))
    }

    @Test fun failedStartReplacementRetainsOriginalAfterRestart() = replacementFailure(activation = false, throws = false)
    @Test fun thrownStartReplacementRetainsOriginalAfterRestart() = replacementFailure(activation = false, throws = true)
    @Test fun failedActivationReplacementRetainsOriginalAfterRestart() = replacementFailure(activation = true, throws = false)
    @Test fun thrownActivationReplacementRetainsOriginalAfterRestart() = replacementFailure(activation = true, throws = true)

    private fun replacementFailure(activation: Boolean, throws: Boolean) {
        val root = Files.createTempDirectory("trip-start-commit").toFile()
        try {
            val file = File(root, "queue")
            val disk = ReviewWriteDisk(file)
            var failSave = false
            var saves = 0
            val queue = PendingWriteRepository(object : PendingWriteStoring {
                override fun load() = disk.load()
                override fun clear() = disk.clear()
                override fun save(writes: List<PendingWrite>): Boolean {
                    saves++
                    if (failSave) {
                        if (throws) throw IOException("Injected commit failure")
                        return false
                    }
                    return disk.save(writes)
                }
            })
            val sync = TripStartSync(queue)
            val original = if (activation) sync.enqueueActivation(trip) else sync.enqueue(trip)
            val metadata = metadata(queue, "keep metadata", 321.123)
            val before = queue.list()
            val bytes = file.readBytes()
            val previousSaves = saves
            failSave = true
            try {
                if (activation) sync.enqueueActivation(trip.copy(tripTitle = "replacement"))
                else sync.enqueue(trip.copy(tripTitle = "replacement"))
                fail("Failed commit accepted")
            } catch (_: IllegalStateException) { } catch (_: IOException) { }
            assertEquals(previousSaves + 1, saves)
            assertEquals(before, queue.list())
            assertArrayEquals(bytes, file.readBytes())
            assertEquals(listOf(original, metadata), PendingWriteRepository(ReviewWriteDisk(file)).list())
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 10000) fun staleStartAndActivationRepliesCannotConsumeFreshReplacement() = runBlocking {
        for (activation in listOf(false, true)) {
            val root = Files.createTempDirectory("trip-start-stale").toFile()
            try {
                val file = File(root, "queue")
                val disk = ReviewWriteDisk(file)
                var saves = 0
                val queue = PendingWriteRepository(object : PendingWriteStoring {
                    override fun load() = disk.load()
                    override fun clear() = disk.clear()
                    override fun save(writes: List<PendingWrite>): Boolean { saves++; return disk.save(writes) }
                })
                val entered = CompletableDeferred<Unit>()
                val reply = CompletableDeferred<Trip>()
                val sync = TripStartSync(queue, {
                    if (!activation) { entered.complete(Unit); reply.await() } else trip.copy(isActive = false)
                }) { _, _ -> entered.complete(Unit); reply.await() }
                val original = if (activation) sync.enqueueActivation(trip) else sync.enqueue(trip)
                val history = queue.enqueue(PendingEntityType.TRIP_START, PendingOpType.CREATE, "history", trip.id)
                queue.markSynced(history.id)
                val resolved = queue.list().last()
                val metadata = metadata(queue, "metadata", 345.678)
                var callbacks = 0
                val replay = async { sync.replayAll { callbacks++ } }
                entered.await()
                val beforeSaves = saves
                val replacementTrip = trip.copy(tripTitle = "replacement", startEngineHours = 456.789)
                val replacement = if (activation) sync.enqueueActivation(replacementTrip) else sync.enqueue(replacementTrip)
                assertEquals(beforeSaves + 1, saves)
                assertNotEquals(original.id, replacement.id)
                assertEquals(0, replacement.attemptCount)
                val payload = json.decodeFromString(TripStartSync.Payload.serializer(), replacement.payloadJson)
                assertEquals(trip.id, payload.tripId)
                assertEquals(trip.startTime, payload.startTime)
                assertEquals(activation, payload.activateExisting)
                assertEquals(456.789, payload.startEngineHours)
                reply.complete(trip)
                replay.await()
                assertEquals(0, callbacks)
                assertEquals(listOf(resolved, metadata, replacement), queue.list())
                assertEquals(queue.list(), PendingWriteRepository(ReviewWriteDisk(file)).list())
            } finally { root.deleteRecursively() }
        }
    }

    @Test(timeout = 10000) fun activationServerConflictsStillBlockAndLegitimateResponsesStillPublish() = runBlocking {
        val servers = listOf(
            trip.copy(isActive = false),
            trip,
            trip.copy(endTime = edited),
            trip.copy(startTime = edited),
            trip.copy(isActive = false, completedPaths = listOf(1.5)),
        )
        for ((index, server) in servers.withIndex()) {
            val queue = PendingWriteRepository(InMemoryPendingWriteStore())
            val sync = TripStartSync(queue, { server }) { _, _ -> trip.copy(tripTitle = "activated", startEngineHours = 123.456) }
            sync.enqueueActivation(trip)
            var published: Trip? = null
            sync.replayAll { published = TripStartReconciliation.reconcile(it, trip, queue.list()) }
            if (index < 2) {
                assertTrue(queue.list().isEmpty())
                assertEquals(if (index == 0) "activated" else trip.tripTitle, published?.tripTitle)
                assertEquals(if (index == 0) 123.456 else trip.startEngineHours, published?.startEngineHours)
            } else {
                assertNull(published)
                assertEquals(PendingWriteStatus.BLOCKED, queue.list().single().status)
            }
        }
    }
}
