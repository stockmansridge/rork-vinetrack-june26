package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Issue #41: incompatible originals are contained without vetoing independent replay. */
class LegacyReplayIsolationTest {
    private val old = "3bfb7f81-2ae2-4f33-8fd8-6666b2b45393"
    private val current = "b1dd59ab-ff1b-4ff4-9af6-a9688425db22"
    private val sessionId = "fdb6a4b8-5cbf-41a9-a780-816a5e5fa401"
    private val record = "b9222ef1-6702-4134-9878-f1fa460f43df"
    private val owner = "a9222ef1-6702-4134-9878-f1fa460f43df"
    private val vineyard = "59973ced-1fb9-42ec-a66d-9eaad3172824"
    private val raw get() = """[{"actorId":"$owner","trip":{"id":"$old","vineyardId":"$vineyard"},"recordId":"$record","input":{"unsupported_v318":"retain verbatim"}}]"""
    private fun inspect(text: String? = raw) = LegacyReplayIsolation.inspect(text) { false }

    @Test fun incompatibleButIdentifiedOriginalDoesNotBlockNewTrip() {
        assertNull(inspect().blocker(current))
        assertFalse(inspect().blocksPayload(current, """{"tripId":"$current"}"""))
        assertEquals(raw, raw)
    }
    @Test fun sameOriginalTripAndRecordRemainHeld() {
        assertEquals("LEGACY_SAME_TRIP_CONFLICT", inspect().blocker(old.uppercase()))
        assertEquals("LEGACY_SAME_TRIP_CONFLICT", inspect().blocker(current, record))
    }
    @Test fun malformedRootNeverMeansEmpty() {
        for (value in listOf("{", "{}", "null", "[7]")) {
            assertEquals("LEGACY_IDENTITY_UNRESOLVED", inspect(value).blocker(current))
        }
    }
    @Test fun missingIdentityProtectsAllTripWrites() {
        assertEquals("LEGACY_IDENTITY_UNRESOLVED", inspect(raw.replace("\"recordId\":\"$record\",", "")).blocker(current))
    }
    @Test fun nestedConflictingIdentityIsNotDiscarded() {
        val nested = raw.replace("retain verbatim", current)
        assertEquals("LEGACY_SAME_TRIP_CONFLICT", inspect(nested).blocker(current))
        assertTrue(inspect().blocksPayload(current, """{"tripId":"$current","originalRecord":"$record"}"""))
    }
    @Test fun malformedModernPayloadIsNotAdmitted() {
        assertTrue(inspect().blocksPayload(current, "bad"))
    }
    @Test fun absentJournalIsDistinctFromUnreadable() {
        assertNull(inspect(null).blocker(current))
        assertTrue(inspect(null).held.isEmpty())
        assertFalse(inspect("bad").held.isEmpty())
    }
    @Test fun duplicateIdentityCannotUseIndividuallyAcceptedEntriesToBypassHold() {
        val duplicated = raw.dropLast(1) + "," + raw.drop(1)
        val index = LegacyReplayIsolation.inspect(duplicated) { true }
        assertEquals(2, index.held.size)
        assertEquals("LEGACY_SAME_TRIP_CONFLICT", index.blocker(old))
    }
    @Test fun fingerprintTracksOriginalBytesWithoutReencoding() {
        assertEquals(inspect().fingerprint, inspect().fingerprint)
        assertNotEquals(inspect().fingerprint, inspect(raw + " ").fingerprint)
    }
    @Test fun foreignOriginalIsStillProtectedNotAdopted() {
        val other = raw.replace(owner, "c9222ef1-6702-4134-9878-f1fa460f43df")
        assertNull(inspect(other).blocker(current))
        assertEquals("LEGACY_SAME_TRIP_CONFLICT", inspect(other).blocker(old))
    }
    @Test fun eachQueueClaimRechecksEvidenceAfterFreeze() {
        val q = PendingWriteRepository(InMemoryPendingWriteStore())
        q.configureReplayScope { PendingWriteRepository.ReplayScope(owner, 1) }
        var text = raw
        q.configureReplayAdmission { !inspect(text).blocksPayload(it.clientId, it.payloadJson) }
        val entry = q.enqueue(PendingEntityType.TRIP_TANK, PendingOpType.UPDATE, """{"tripId":"$current"}""", current)
        val frozen = q.freezeReplayVersions(listOf(entry))
        text = "malformed after freeze"
        assertNull(q.claimReplay(entry, frozen))
        assertEquals(entry, q.list().single())
        assertEquals(0, q.list().single().attemptCount)
    }
    @Test(timeout = 10000) fun identifiedLegacyAllowsRealTankReplayWithExactRetainedSessionAndIndependentReadback() = runBlocking {
        val retainedBytes = raw
        val session = TankSession(sessionId, 1, startTime = "2026-11-02T01:00:00Z", endTime = "2026-11-02T01:10:00Z")
        val local = Trip(current, vineyard, isActive = true, tankSessions = listOf(session))
        var server = local.copy(tankSessions = emptyList())
        var bytes: String? = null
        val store = ActiveTripStore(object : ActiveTripSnapshotStorage {
            override fun read() = bytes
            override fun write(value: String) { bytes = value }
            override fun remove() { bytes = null }
        })
        store.save(owner, vineyard, local)
        val q = PendingWriteRepository(InMemoryPendingWriteStore())
        q.configureReplayScope { PendingWriteRepository.ReplayScope(owner, 1) }
        q.configureReplayAdmission { !inspect(retainedBytes).blocksPayload(it.clientId, it.payloadJson) }
        var patches = 0
        var readbacks = 0
        val sync = TripTankSync(null, q, store, { server }, { _, sessions, _, _, _ ->
            patches++; server = server.copy(tankSessions = sessions); server
        }, requiredSessionIds = { setOf(sessionId) }, readBackTrip = { readbacks++; server })
        sync.enqueue(local)
        sync.replayAll { assertEquals(listOf(session), it.tankSessions) }
        assertTrue(q.list().isEmpty())
        assertEquals(1, patches)
        assertEquals(1, readbacks)
        assertEquals(raw, retainedBytes)
        assertEquals(listOf(session), server.tankSessions)
    }
    @Test(timeout = 10000) fun matchingSessionIdWithChangedTimestampsIsNotAcknowledged() = runBlocking {
        val session = TankSession(sessionId, 1, startTime = "2026-11-02T01:00:00Z", endTime = "2026-11-02T01:10:00Z")
        val expected = Trip(current, vineyard, tankSessions = listOf(session))
        assertFalse(TankDependencyVerification.patchVerified(expected.copy(tankSessions = listOf(session.copy(endTime = null))), current, vineyard, listOf(session), setOf(sessionId)))
        assertTrue(TankDependencyVerification.patchVerified(expected, current, vineyard, listOf(session), setOf(sessionId)))
    }
}
