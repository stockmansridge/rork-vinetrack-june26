package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class YieldCompletionPersistenceTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val trip = YieldEstimationSession(id = "trip", vineyardId = "vineyard", createdAt = "2026-10-01T00:00:00Z")
    private val completed = trip.copy(isCompleted = true, completedAt = "2026-10-27T01:00:00Z")
    private val stamp = "2026-10-27T01:00:01Z"
    private class Server : YieldSessionWriting {
        val rows = mutableMapOf<String, YieldEstimationSession>()
        val sent = mutableListOf<Pair<String, String?>>()
        var action: (() -> Unit)? = null
        var failure: Exception? = null
        override suspend fun upsertSession(session: YieldEstimationSession, clientUpdatedAt: String?): YieldEstimationSession {
            sent += session.id to clientUpdatedAt
            rows[session.id] = session
            action?.invoke()
            failure?.let { throw it }
            return session
        }
    }

    @Test fun completionAndTimestampSurviveQueueRestart() {
        val disk = InMemoryPendingWriteStore()
        val server = Server()
        YieldSessionSaveSync(server, PendingWriteRepository(disk)).enqueue(completed, stamp)
        val reopened = PendingWriteRepository(disk)
        val payload = json.decodeFromString(YieldSessionSaveSync.Payload.serializer(), reopened.list().single().payloadJson)
        assertTrue(payload.session.isCompleted)
        assertEquals(completed.completedAt, payload.session.completedAt)
        assertEquals(trip.id, payload.session.id)
    }

    @Test fun failedReplacementCommitRetainsOriginalDraft() {
        val disk = object : PendingWriteStoring {
            var rows = emptyList<PendingWrite>()
            var fail = false
            override fun load() = rows
            override fun save(writes: List<PendingWrite>): Boolean { if (fail) return false; rows = writes; return true }
            override fun clear() = false
        }
        val queue = PendingWriteRepository(disk)
        val sync = YieldSessionSaveSync(Server(), queue)
        val original = sync.enqueue(trip, stamp)
        disk.fail = true
        assertTrue(runCatching { sync.enqueue(completed, stamp) }.isFailure)
        assertEquals(listOf(original), queue.list())
        assertEquals(listOf(original), disk.rows)
    }

    @Test fun olderDraftAcknowledgementCannotRemoveOrPublishNewCompletion() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val server = Server()
        val sync = YieldSessionSaveSync(server, queue)
        sync.enqueue(trip, stamp)
        server.action = { sync.enqueue(completed, stamp) }
        val callbacks = mutableListOf<YieldEstimationSession>()
        sync.replayAll { callbacks += it }
        assertTrue(callbacks.isEmpty())
        val payload = json.decodeFromString(YieldSessionSaveSync.Payload.serializer(), queue.list().single().payloadJson)
        assertTrue(payload.session.isCompleted)
        server.action = null
        sync.replayAll { callbacks += it }
        assertTrue(callbacks.single().isCompleted)
        assertTrue(queue.list().isEmpty())
    }

    @Test fun interruptedUploadRetriesSameTripAndOriginalCompletionTime() = runBlocking {
        val disk = InMemoryPendingWriteStore()
        val queue = PendingWriteRepository(disk)
        val server = Server()
        YieldSessionSaveSync(server, queue).enqueue(completed, stamp)
        queue.claimReplay(queue.list().single())
        val reopened = PendingWriteRepository(disk)
        assertEquals(PendingWriteStatus.FAILED, reopened.list().single().status)
        YieldSessionSaveSync(server, reopened).replayAll { assertEquals(completed.completedAt, it.completedAt) }
        assertEquals(listOf(trip.id to stamp), server.sent)
        assertTrue(reopened.list().isEmpty())
    }

    @Test fun lostNetworkAcknowledgementIsIdempotentOnRetry() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val server = Server().apply { failure = IllegalStateException("connection lost after commit") }
        val sync = YieldSessionSaveSync(server, queue)
        sync.enqueue(completed, stamp)
        sync.replayAll { fail("Unknown outcome must stay queued") }
        assertEquals(1, server.rows.size)
        assertEquals(PendingWriteStatus.FAILED, queue.list().single().status)
        server.failure = null
        sync.replayAll { assertTrue(it.isCompleted) }
        assertEquals(1, server.rows.size)
        assertEquals(listOf(trip.id to stamp, trip.id to stamp), server.sent)
        assertTrue(queue.list().isEmpty())
    }

    @Test fun confirmedSnapshotMustCommitBeforeQueueAcknowledgement() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val sync = YieldSessionSaveSync(Server(), queue)
        sync.enqueue(completed, stamp)
        sync.replayAll(retainConfirmed = { false }) { fail("Unretained confirmation") }
        assertEquals(PendingWriteStatus.FAILED, queue.list().single().status)
        sync.replayAll(retainConfirmed = { true }) { assertTrue(it.isCompleted) }
        assertTrue(queue.list().isEmpty())
    }

    @Test fun staleFailureDoesNotFailNewerCompletion() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val server = Server().apply { failure = IllegalStateException("timeout") }
        val sync = YieldSessionSaveSync(server, queue)
        sync.enqueue(trip, stamp)
        server.action = { sync.enqueue(completed, stamp) }
        sync.replayAll { fail("Unexpected acknowledgement") }
        val saved = queue.list().single()
        assertEquals(PendingWriteStatus.PENDING, saved.status)
        assertEquals(0, saved.attemptCount)
        assertTrue(json.decodeFromString(YieldSessionSaveSync.Payload.serializer(), saved.payloadJson).session.isCompleted)
    }

    @Test fun completedSaveWithoutActualTimestampIsRejected() {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        assertTrue(runCatching { YieldSessionSaveSync(Server(), queue).enqueue(trip.copy(isCompleted = true), stamp) }.isFailure)
        assertTrue(queue.list().isEmpty())
    }

    @Test fun queuedDeletePreventsSaveResurrection() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val server = Server()
        val sync = YieldSessionSaveSync(server, queue)
        sync.enqueue(completed, stamp)
        queue.enqueue(PendingEntityType.YIELD_SESSION, PendingOpType.DELETE, "{}", trip.id)
        sync.replayAll { fail("Deleted trip") }
        assertTrue(server.sent.isEmpty())
        assertEquals(PendingOpType.DELETE, queue.list().single().opType)
    }

    @Test fun promotedCompletionOverridesStaleDraftPayloadOnReload() {
        val row = YieldEstimationSessionRepository.SessionRow(trip.id, trip.vineyardId, trip,
            isCompleted = true, completedAt = completed.completedAt)
        assertTrue(row.toSession()!!.isCompleted)
        assertEquals(completed.completedAt, row.toSession()!!.completedAt)
    }

    @Test fun explicitDraftDoesNotBecomeCompleteFromRecordedSamples() {
        val sampled = trip.copy(sampleSites = listOf(SampleSite("site", "block", rowNumber = 1,
            latitude = 1.0, longitude = 2.0, siteIndex = 1, bunchCountEntry = BunchCountEntry(20.0, stamp))))
        val row = YieldEstimationSessionRepository.SessionRow(trip.id, trip.vineyardId, sampled, isCompleted = false)
        assertFalse(row.toSession()!!.isCompleted)
    }

    @Test fun legacyRowsPreservePayloadCompletion() {
        assertTrue(YieldEstimationSessionRepository.SessionRow(trip.id, trip.vineyardId, completed).toSession()!!.isCompleted)
    }

    @Test fun deletedRowDoesNotReloadAsCompletedTrip() {
        assertNull(YieldEstimationSessionRepository.SessionRow(trip.id, trip.vineyardId, completed, deletedAt = stamp).toSession())
    }

    @Test fun encodedTopLevelCompletionAndPayloadAreConsistent() {
        val body = YieldEstimationSessionRepository.SessionUpsert(trip.id, trip.vineyardId, completed,
            true, completed.completedAt, trip.createdAt, clientUpdatedAt = stamp)
        val encoded = json.encodeToString(YieldEstimationSessionRepository.SessionUpsert.serializer(), body)
        val decoded = json.decodeFromString(YieldEstimationSessionRepository.SessionRow.serializer(), encoded)
        assertEquals(true, decoded.isCompleted)
        assertEquals(decoded.isCompleted, decoded.payload!!.isCompleted)
        assertEquals(decoded.completedAt, decoded.payload.completedAt)
    }

    @Test fun accountChangeDuringUploadCannotAcknowledgeOriginalQueue() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        var scope = PendingWriteRepository.ReplayScope("original", 1)
        queue.configureReplayScope { scope }
        val server = Server().apply { action = { scope = PendingWriteRepository.ReplayScope("other", 2) } }
        val sync = YieldSessionSaveSync(server, queue)
        sync.enqueue(completed, stamp)
        sync.replayAll { fail("Stale account response") }
        assertEquals(1, queue.list().size)
    }
}
