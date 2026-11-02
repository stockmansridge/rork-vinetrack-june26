package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.SprayCompletionResponse
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class TrackedSprayCompletionSyncTest {
    private val end = "2026-11-02T08:08:00Z"
    private val trip = Trip("trip", "vineyard", tripFunction = "spraying", endTime = end)
    private val spray = SprayRecord("spray", "vineyard", tripId = "trip", notes = "Original planning retained")

    private class Fixture {
        val store = InMemoryPendingWriteStore()
        var pending = PendingWriteRepository(store)
        var sync = TrackedSprayCompletionSync(pending)
        var trip: Trip? = null
        var sprays = emptyList<SprayRecord>()
        var ready = true
        var current = true
        var calls = 0
        var verified = 0
        var loseResponse = false
        var wrongResponse = false
        var failReadback = false
        var switchAfterRpc = false
        var onRpc: (() -> Unit)? = null
        suspend fun replay(owner: String = "owner", vineyard: String = "vineyard") {
            sync.replay(owner, vineyard, pending.freezeReplayVersions(pending.list()), { current },
                { trip }, { if (failReadback && calls > 0) error("offline") else sprays }, { ready }, complete = {
                    calls++
                    sprays = sprays.map { it.copy(endTime = trip?.endTime) }
                    onRpc?.invoke()
                    if (switchAfterRpc) current = false
                    if (loseResponse) { loseResponse = false; error("response lost") }
                    SprayCompletionResponse(it, if (wrongResponse) "2026-11-03T00:00:00Z" else trip!!.endTime!!,
                        "trip_end", true, "2026-11-02T09:00:00Z", syncVersion = 3)
                }, onVerified = { verified++ })
        }
        fun reopen() { pending = PendingWriteRepository(store); sync = TrackedSprayCompletionSync(pending) }
    }
    private fun fixture(): Fixture = Fixture().also {
        it.trip = trip; it.sprays = listOf(spray); it.sync.enqueue("owner", trip.copy(isActive = true, endTime = null), end, spray.id)
    }

    @Test fun onlineCompletionUsesOriginalEndAndOnlyCompletionFields() = runTest {
        val f = fixture(); val original = f.sprays.single()
        f.replay()
        assertEquals(1, f.calls); assertEquals(1, f.verified); assertTrue(f.pending.list().isEmpty())
        assertEquals(original.copy(endTime = end), f.sprays.single())
        assertEquals(trip, f.trip)
    }
    @Test fun offlineIntentSurvivesReopenUntilTripEndAndDependenciesAcknowledged() = runTest {
        val f = fixture(); val original = f.pending.list().single()
        f.trip = trip.copy(isActive = true, endTime = null); f.reopen(); f.replay()
        assertEquals(0, f.calls); assertEquals(original.id, f.pending.list().single().id)
        assertEquals(original.payloadJson, f.pending.list().single().payloadJson)
        f.trip = trip; f.ready = false; f.replay(); assertEquals(0, f.calls)
        f.ready = true; f.replay(); assertEquals(1, f.verified)
    }
    @Test fun lostResponseRetryReadsExistingCompletionWithoutSecondRpc() = runTest {
        val f = fixture(); f.loseResponse = true; f.replay()
        assertEquals(0, f.verified); assertEquals(1, f.pending.list().size)
        f.reopen(); f.replay(); assertEquals(1, f.calls); assertEquals(1, f.verified)
    }
    @Test fun backgroundAcknowledgementClosesOnlyAfterReadback() = runTest {
        val f = fixture(); f.failReadback = true; f.replay()
        assertEquals(0, f.verified); assertFalse(f.pending.list().isEmpty())
        f.failReadback = false; f.replay(); assertEquals(1, f.verified); assertEquals(1, f.calls)
    }
    @Test fun reopeningVerifiedCompletionDoesNotReplayHistoricalRows() = runTest {
        val f = fixture(); f.replay(); f.reopen(); f.sprays = listOf(spray); f.replay()
        assertEquals(1, f.calls); assertNull(f.sprays.single().endTime)
    }
    @Test fun wrongAccountOrVineyardCannotClaimIntent() = runTest {
        val f = fixture(); val before = f.pending.list()
        f.replay(owner = "other"); f.replay(vineyard = "other")
        assertEquals(before, f.pending.list()); assertEquals(0, f.calls)
    }
    @Test fun accountSwitchDuringRpcCannotAcknowledge() = runTest {
        val f = fixture(); f.switchAfterRpc = true; f.replay()
        assertEquals(0, f.verified); assertEquals(1, f.pending.list().size)
        f.reopen(); f.current = true; f.replay(); assertEquals(1, f.verified)
    }
    @Test fun differentTripEndRetainsOriginalAndMakesNoCompletionWrite() = runTest {
        val f = fixture(); f.trip = trip.copy(endTime = "2026-11-02T09:08:00Z"); f.replay()
        assertEquals(0, f.calls); assertEquals(1, f.pending.list().size)
    }
    @Test fun manualTemplateDeletedForeignAndAmbiguousSpraysNeverAutoComplete() = runTest {
        for (rows in listOf(listOf(spray.copy(entrySource = "manual")), listOf(spray.copy(manualEntryId = "manual")),
            listOf(spray.copy(isTemplate = true)), listOf(spray.copy(deletedAt = end)),
            listOf(spray.copy(vineyardId = "other")), listOf(spray.copy(tripId = "other")),
            emptyList(), listOf(spray, spray.copy(id = "other")))) {
            val f = fixture(); f.sprays = rows; f.replay(); assertEquals(0, f.calls); assertEquals(1, f.pending.list().size)
        }
    }
    @Test fun manualAndNonSprayingTripsDoNotCreateIntent() {
        val f = Fixture()
        for (t in listOf(trip.copy(entrySource = "manual"), trip.copy(manualEntryId = "manual"), trip.copy(tripFunction = "seeding")))
            f.sync.enqueue("owner", t, end, null)
        assertTrue(f.pending.list().isEmpty())
    }
    @Test fun mismatchedExistingSprayEndIsHeldNeverOverwritten() = runTest {
        val f = fixture(); f.sprays = listOf(spray.copy(endTime = "2026-11-02T10:00:00Z")); f.replay()
        assertEquals(0, f.calls); assertEquals(0, f.verified); assertEquals(1, f.pending.list().size)
    }
    @Test fun unverifiedRpcResponseDoesNotClearIntent() = runTest {
        val f = fixture(); f.wrongResponse = true; f.replay()
        assertEquals(0, f.verified); assertEquals(1, f.pending.list().size)
    }
    @Test fun unrelatedRetainedOperationsRemainByteForByteUnchanged() = runTest {
        val f = fixture()
        val original = f.pending.enqueue(PendingEntityType.TRIP_END, PendingOpType.UPDATE, "{\"tripId\":\"protected\"}", "protected")
        f.replay(); assertEquals(listOf(original), f.pending.list())
    }
    @Test fun failedDurableEnqueueRefusesCompletionIntent() {
        val store = object : PendingWriteStoring {
            override fun load() = emptyList<PendingWrite>()
            override fun save(writes: List<PendingWrite>) = false
            override fun clear() = false
        }
        assertThrows(IllegalStateException::class.java) { TrackedSprayCompletionSync(PendingWriteRepository(store)).enqueue("owner", trip, end, spray.id) }
    }
    @Test fun replacedCanonicalSprayCannotRedirectOriginalCompletion() = runTest {
        val f = fixture(); f.sprays = listOf(spray.copy(id = "replacement")); f.replay()
        assertEquals(0, f.calls); assertEquals(0, f.verified); assertEquals(1, f.pending.list().size)
    }
    @Test fun missingOriginalIdentityRefusesNewIntent() {
        val f = Fixture()
        assertThrows(IllegalArgumentException::class.java) { f.sync.enqueue("owner", trip, end, null) }
        assertTrue(f.pending.list().isEmpty())
    }
    @Test fun repeatEndCannotReplaceOriginalIdentityOrTimestamp() {
        val f = fixture(); val original = f.pending.list()
        f.sync.enqueue("owner", trip, end, spray.id)
        assertThrows(IllegalStateException::class.java) { f.sync.enqueue("owner", trip, end, "replacement") }
        assertThrows(IllegalStateException::class.java) { f.sync.enqueue("owner", trip, "2026-11-02T09:00:00Z", spray.id) }
        assertEquals(original, f.pending.list())
    }
    @Test fun partialEndRetryAfterReopenUsesFirstRequestedTimeWithoutReplacingIntent() {
        val f = fixture(); val original = f.pending.list(); f.reopen()
        val retained = f.sync.endTimeForRetry("owner", trip, "2026-11-02T09:00:00Z")
        assertEquals(end, retained)
        f.sync.enqueue("owner", trip, retained, spray.id)
        assertEquals(original, f.pending.list())
        assertThrows(IllegalStateException::class.java) { f.sync.endTimeForRetry("other", trip, end) }
        assertEquals(original, f.pending.list())
    }
    @Test fun closureRequiresRealLinkedCompletionWithExactInstantAndIdentity() {
        assertEquals("LINKED_SPRAY_COMPLETION_PENDING", TrackedSprayCompletionSync.completionIssue(trip, listOf(spray)))
        assertNotNull(TrackedSprayCompletionSync.completionIssue(trip, emptyList()))
        assertNotNull(TrackedSprayCompletionSync.completionIssue(trip, listOf(spray.copy(endTime = end)), setOf("different")))
        assertNotNull(TrackedSprayCompletionSync.completionIssue(trip, listOf(spray.copy(endTime = "2026-11-02T09:08:00Z"))))
        assertNull(TrackedSprayCompletionSync.completionIssue(trip, listOf(spray.copy(endTime = "2026-11-02T19:08:00+11:00"))))
    }
}
