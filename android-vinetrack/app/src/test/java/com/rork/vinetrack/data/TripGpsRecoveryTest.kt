package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class TripGpsRecoveryTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val points = List(4584) { CoordinatePoint(-33.0 + it * 0.000001, 149.0 + it * 0.000001) }
    private val trip = Trip("synthetic-trip", "vineyard", isActive = false, endTime = "2026-10-14T10:00:00Z", pathPoints = points, updatedAt = "2026-10-14T10:00:01.123456+00:00")
    private class SnapshotDisk : ActiveTripSnapshotStorage {
        var raw: String? = null
        override fun read() = raw
        override fun write(value: String) { raw = value }
        override fun remove() { raw = null }
    }
    private fun queue(store: PendingWriteStoring): PendingWriteRepository = PendingWriteRepository(store).also {
        it.configureReplayScope { PendingWriteRepository.ReplayScope("owner", 1) }
    }
    private fun marker(queue: PendingWriteRepository, path: List<CoordinatePoint>? = null): PendingWrite = queue.enqueue(
        PendingEntityType.TRIP_GPS, PendingOpType.UPDATE,
        json.encodeToString(TripGpsSync.Payload.serializer(), TripGpsSync.Payload(trip.id, 4584, null, "2026-10-14T10:00:00Z", 1,
            if (path != null) "owner" else null, if (path != null) "vineyard" else null, path)), trip.id)

    @Test(timeout = 10000) fun interruptedLegacyMarkerRetainsBytesThenVerifiesCompletedServerWithoutPatch() = runBlocking {
        val disk = InMemoryPendingWriteStore()
        val first = queue(disk)
        val original = marker(first)
        first.claimReplay(original)
        val snapshotDisk = SnapshotDisk()
        ActiveTripStore(snapshotDisk).save("owner", "vineyard", trip)
        val restarted = queue(disk)
        val recovered = restarted.list().single()
        assertEquals(original.id, recovered.id)
        assertEquals(original.payloadJson, recovered.payloadJson)
        assertEquals(original.attemptCount, recovered.attemptCount)
        assertEquals(PendingWriteStatus.FAILED, recovered.status)
        val sync = TripGpsSync(restarted, ActiveTripStore(snapshotDisk), { trip }) { _, _, _, _ -> error("Completed trip was patched") }
        sync.replayAll { error("Completed trip was published as active") }
        assertEquals(0, restarted.currentPendingCount())
        assertEquals(PendingWriteStatus.SYNCED, restarted.list().single().status)
        val retained = json.decodeFromString(TripGpsSync.Payload.serializer(), restarted.list().single().payloadJson)
        assertEquals(original.payloadJson, retained.originalPayloadJson)
        assertEquals(points, retained.pathEvidence)
        assertEquals(points, ActiveTripStore(snapshotDisk).load()?.trip?.pathPoints)
        assertEquals(PendingWriteStatus.SYNCED, queue(disk).list().single().status)
    }

    @Test(timeout = 10000) fun largerServerWithMissingLocalPointIsHeldAndEvidenceRetained() = runBlocking {
        val q = queue(InMemoryPendingWriteStore())
        val local = points + CoordinatePoint(-32.9, 148.9)
        val original = marker(q, local)
        val remote = trip.copy(pathPoints = points + points.take(20))
        TripGpsSync(q, ActiveTripStore(SnapshotDisk()), { remote }) { _, _, _, _ -> error("patched") }.replayAll {}
        assertEquals(PendingWriteStatus.BLOCKED, q.list().single().status)
        assertEquals(original.payloadJson, q.list().single().payloadJson)
        assertEquals(1, q.currentPendingCount())
        assertTrue(q.list().single().lastError!!.contains("Completed trip"))
    }

    @Test(timeout = 10000) fun missingForeignAndCorruptLegacySnapshotsNeverAcknowledge() = runBlocking {
        for (owner in listOf<String?>(null, "foreign", "corrupt")) {
            val q = queue(InMemoryPendingWriteStore()); val original = marker(q)
            val storage = SnapshotDisk()
            if (owner != null) ActiveTripStore(storage).save(owner, "vineyard", trip)
            if (owner == "corrupt") storage.raw = "{broken"
            TripGpsSync(q, ActiveTripStore(storage), { error("Unauthorised read") }) { _, _, _, _ -> error("patched") }.replayAll {}
            assertEquals(PendingWriteStatus.BLOCKED, q.list().single().status)
            assertEquals(original.payloadJson, q.list().single().payloadJson)
        }
    }

    @Test(timeout = 10000) fun frozenNewEvidenceSurvivesSnapshotReplacementAndIsVerified() = runBlocking {
        val q = queue(InMemoryPendingWriteStore()); val storage = SnapshotDisk()
        val snapshots = ActiveTripStore(storage)
        snapshots.save("owner", "vineyard", trip)
        val sync = TripGpsSync(q, snapshots, { trip }) { _, _, _, _ -> error("patched") }
        val original = sync.enqueue(trip)
        snapshots.save("owner", "vineyard", trip.copy(id = "other", pathPoints = emptyList()))
        sync.replayAll {}
        assertEquals(PendingWriteStatus.SYNCED, q.list().single().status)
        assertEquals(points, json.decodeFromString(TripGpsSync.Payload.serializer(), original.payloadJson).pathEvidence)
    }

    @Test(timeout = 10000) fun accountChangeDuringReadCannotAcknowledgeOrPatch() = runBlocking {
        val q = queue(InMemoryPendingWriteStore()); val original = marker(q, points)
        var scope = PendingWriteRepository.ReplayScope("owner", 1)
        q.configureReplayScope { scope }
        TripGpsSync(q, ActiveTripStore(SnapshotDisk()), { scope = PendingWriteRepository.ReplayScope("other", 2); trip }) { _, _, _, _ -> error("patched") }.replayAll {}
        assertEquals(PendingWriteStatus.IN_PROGRESS, q.list().single().status)
        assertEquals(original.payloadJson, q.list().single().payloadJson)
    }

    @Test(timeout = 10000) fun sameCountReorderedOrDifferentOptionalEvidenceDoesNotMatch() {
        assertFalse(TripGpsSync.containsEvidence(points.reversed(), points))
        assertFalse(TripGpsSync.containsEvidence(points, points.dropLast(1) + CoordinatePoint(0.0, 0.0)))
        assertFalse(TripGpsSync.containsEvidence(listOf(points[0]), listOf(points[0].copy(accuracy = 1.0))))
        assertTrue(TripGpsSync.containsEvidence(points, points.take(3)))
    }

    @Test(timeout = 10000) fun networkFailureRetainsMarkerAndFrozenEvidenceForManualRetry() = runBlocking {
        val disk = InMemoryPendingWriteStore(); val q = queue(disk); val original = marker(q, points)
        TripGpsSync(q, ActiveTripStore(SnapshotDisk()), { throw java.io.IOException("offline") }) { _, _, _, _ -> error("patched") }.replayAll {}
        assertEquals(PendingWriteStatus.FAILED, q.list().single().status)
        assertEquals(original.payloadJson, q.list().single().payloadJson)
        assertTrue(q.resetFailedRowForRetry(original.id))
        TripGpsSync(q, ActiveTripStore(SnapshotDisk()), { trip }) { _, _, _, _ -> error("patched") }.replayAll {}
        assertEquals(0, q.currentPendingCount())
    }

    @Test(timeout = 10000) fun overlappingReplayAndNewerMarkerCannotBeAcknowledgedByOldRead() = runBlocking {
        val q = queue(InMemoryPendingWriteStore()); marker(q, points)
        val started = CompletableDeferred<Unit>(); val result = CompletableDeferred<Trip>()
        val sync = TripGpsSync(q, ActiveTripStore(SnapshotDisk()), { started.complete(Unit); result.await() }) { _, _, _, _ -> error("patched") }
        val replay = async { sync.replayAll {} }; started.await()
        sync.replayAll { error("overlap") }
        val current = q.list().single()
        val replacement = q.upsertCoalesced(PendingEntityType.TRIP_GPS, trip.id, current.payloadJson + " ")
        result.complete(trip); replay.await()
        assertEquals(listOf(replacement), q.list())
    }

    @Test(timeout = 10000) fun newestDurableSnapshotTailIsFrozenBeforeRecoveryAndNeverAcknowledgedAsAnOldPrefix() = runBlocking {
        val q = queue(InMemoryPendingWriteStore()); val original = marker(q, points.take(20))
        val storage = SnapshotDisk(); ActiveTripStore(storage).save("owner", "vineyard", trip)
        TripGpsSync(q, ActiveTripStore(storage), { trip.copy(pathPoints = points.take(20)) }) { _, _, _, _ -> error("completed patched") }.replayAll {}
        val held = q.list().single()
        assertEquals(PendingWriteStatus.BLOCKED, held.status)
        val retained = json.decodeFromString(TripGpsSync.Payload.serializer(), held.payloadJson)
        assertEquals(points, retained.pathEvidence)
        assertEquals(original.payloadJson, retained.originalPayloadJson)
    }

    @Test(timeout = 10000) fun iosRepairsPayloadPreservesIdentityAndColourInAndroidReader() {
        val data = """{"id":"71000000-0000-4000-8000-000000000003","vineyardId":"71000000-0000-4000-8000-000000000001","name":"Repairs custom","color":"orange","index":3,"mode":"Repairs","isGrowthStageButton":false}"""
        val button = json.decodeFromString(LauncherButton.serializer(), data)
        assertEquals("orange", button.color)
        assertEquals("71000000-0000-4000-8000-000000000003", button.id)
        assertEquals(3, button.index)
    }

    @Test(timeout = 10000) fun activeTripWritesOnlySupersetAndRequiresCompleteAcknowledgement() = runBlocking {
        val q = queue(InMemoryPendingWriteStore()); marker(q, points)
        var patches = 0
        TripGpsSync(q, ActiveTripStore(SnapshotDisk()), { trip.copy(isActive = true, endTime = null, pathPoints = points.take(2)) }) { _, path, _, _ ->
            patches++; assertEquals(points, path); trip.copy(isActive = true, endTime = null, pathPoints = points.take(2))
        }.replayAll { error("Incomplete acknowledgement published") }
        assertEquals(1, patches)
        assertEquals(PendingWriteStatus.BLOCKED, q.list().single().status)
    }
}
