package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.AuthRetentionGuard
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * P0 3.1.9: occurrence-restore tank conflict is a durable, fail-closed hold.
 *
 * Integration level: the real journal, gate, active-Trip store, pending-write
 * repository, TRIP_TANK replay, actual upload and Start Tank coordinator are
 * wired exactly as AppViewModel wires them (gate predicate reading the Trip's
 * occurrence journal), over shared in-memory bytes so "restart" is new
 * instances over the same persisted state. The ViewModel's private restore
 * method itself is not executed on the JVM (no Robolectric); its gate call is
 * the [OccurrenceTankConflictGate.onRestore] exercised here.
 */
class OccurrenceTankConflictHoldTest {
    private val owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val vineyard = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val tripId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private val scope = TripOccurrenceJournal.Scope(owner, vineyard, tripId)
    private val a = "11111111-1111-4111-8111-111111111111"

    private class Memory : TripOccurrenceJournal.Storage {
        var value: String? = null
        override fun read() = value
        override fun commit(value: String): Boolean { this.value = value; return true }
    }
    private class MemorySnapshot : ActiveTripSnapshotStorage {
        var bytes: String? = null
        override fun read(): String? = bytes
        override fun write(value: String) { bytes = value }
        override fun remove() { bytes = null }
    }
    private class JournalStore : StartTankJournalStorage {
        var journal: StartTankCommitCoordinator.Journal? = null
        override fun read() = journal
        override fun write(journal: StartTankCommitCoordinator.Journal): Boolean { this.journal = journal; return true }
        override fun clear(): Boolean { journal = null; return true }
    }

    private fun coverage(): JsonObject = Json.parseToJsonElement("""
        {"contract":"vinetrack.planned-occurrence","schemaVersion":1,"planId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","revision":0,"planRevision":1,
        "items":[{"occurrenceId":"$a","blockId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","blockNameSnapshot":"Block X","pathNumber":38.5,"passOrdinal":1,"physicalPathRef":{"pathId":"ffffffff-ffff-4fff-8fff-ffffffffffff","rowIds":[],"geometryRevision":"unresolved"}}],
        "activeOrder":["$a"],"retired":[],"states":{"$a":{"status":"incomplete","source":null,"lastOperationId":null,"tankSessionIds":[]}},"plannedCursorId":"$a","selectedOccurrenceId":null,"extension":{"retain":true}}
        """).jsonObject

    private val tank1 = TankSession("99999999-9999-4999-8999-999999999991", 1, startTime = "2026-11-01T01:00:00Z")
    private val saved = Trip(id = tripId, vineyardId = vineyard, isActive = true,
        tankSessions = listOf(tank1), activeTankNumber = 1)
    private val conflictingServer = saved.copy(tankSessions = listOf(tank1.copy(tankNumber = 2)), activeTankNumber = null)
    private val actual = SprayTankActual("actual-1", vineyard, "spray-1", tripId, tank1.id, 1,
        waterVolumeL = 487.5, chemicals = emptyList(), confirmedAt = "2026-11-01T01:00:00Z", confirmedBy = owner)

    /** The production predicate: AppViewModel.tankConflictHeld over the Trip's journal. */
    private fun heldOver(memory: Memory): (String, String, String) -> Boolean = { o, v, t ->
        OccurrenceTankConflictGate.isHeld(TripOccurrenceJournal(memory, TripOccurrenceJournal.Scope(o, v, t)))
    }

    private fun newJournal(memory: Memory) = TripOccurrenceJournal(memory, scope).also {
        if (it.load() == null) it.initialize(coverage())
    }

    @Test(timeout = 20000) fun conflictCreatesDurableHoldThatBlocksTankSyncActualsCommitsAndSurvivesRestart() = runBlocking {
        val journalBytes = Memory()
        val journal = newJournal(journalBytes)
        val outbox = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(outbox)
        pending.configureReplayScope { PendingWriteRepository.ReplayScope(owner, 1) }
        val snapshots = MemorySnapshot()
        val active = ActiveTripStore(snapshots)
        assertTrue(active.claimIfAvailable(owner, vineyard, saved))
        // The device's own pre-existing replay marker (committed by Start Tank).
        var fetches = 0; var patches = 0
        val tankSync = TripTankSync(tripRepo = null, pending = pending, activeTripStore = active,
            fetchTrip = { fetches++; conflictingServer },
            saveTankSessions = { _, _, _, _, _ -> patches++; error("held") },
            isTankHeld = heldOver(journalBytes))
        val marker = tankSync.enqueue(saved)

        // Restore merge reports the conflict; the gate records the durable hold.
        val result = OccurrenceRestoreLocalProgress.apply(conflictingServer, conflictingServer, saved)
        assertTrue(result.tankConflict)
        assertEquals(listOf(tank1), result.trip.tankSessions) // local evidence unchanged
        val outcome = OccurrenceTankConflictGate.onRestore(journal, result, freshServerRow = true)
        assertEquals(OccurrenceTankConflictGate.Outcome.HELD, outcome)
        assertFalse(OccurrenceTankConflictGate.replayAllowed(result, outcome))
        assertTrue(journal.load()!!.heldReason!!.contains(TripOccurrenceJournal.TANK_CONFLICT_CODE))
        assertFalse(journal.canOperate(journal.load()!!))

        // Restart: brand-new instances over the same persisted bytes.
        val reopened = TripOccurrenceJournal(journalBytes, scope)
        assertTrue(OccurrenceTankConflictGate.isHeld(reopened))
        assertEquals(OccurrenceTankConflictGate.Outcome.ALREADY_HELD,
            OccurrenceTankConflictGate.onRestore(reopened, result, freshServerRow = true))
        val restartedPending = PendingWriteRepository(outbox)
        restartedPending.configureReplayScope { PendingWriteRepository.ReplayScope(owner, 1) }
        val restartedSync = TripTankSync(tripRepo = null, pending = restartedPending, activeTripStore = ActiveTripStore(snapshots),
            fetchTrip = { fetches++; conflictingServer },
            saveTankSessions = { _, _, _, _, _ -> patches++; error("held") },
            isTankHeld = heldOver(journalBytes))
        restartedSync.replayAll { fail("Held tank marker must not replay") }

        // TRIP_TANK marker: not claimed, not sent, unchanged.
        assertEquals(0, fetches); assertEquals(0, patches)
        val retained = PendingWriteRepository(outbox).list().single()
        assertEquals(marker.id, retained.id)
        assertEquals(PendingEntityType.TRIP_TANK, retained.entityType)
        assertEquals(PendingWriteStatus.PENDING, retained.status)
        assertEquals(0, retained.attemptCount)
        assertEquals(listOf(tank1), ActiveTripStore(snapshots).load()?.trip?.tankSessions)

        // Actual upload: skipped while held; exact actual retained pending.
        var actualBytes: String? = null
        val actuals = SprayTankActualStore({ actualBytes }, { actualBytes = it; true })
        val guard = AuthRetentionGuard({ false }, { true })
        val access = requireNotNull(guard.captureAccount(owner))
        actuals.configureAccountAccess { access }
        assertTrue(actuals.save(actual))
        val held = heldOver(journalBytes)
        ScopedTankActualSync(actuals, { o, action -> guard.withAccount(o, { owner }, action) },
            { _, _ -> fail("Held actual must not upload") }, { _, _ -> emptyList() },
            isTankHeld = { x, acc -> held(acc.userId, x.vineyardId, x.tripId) },
        ).replay(access, null, { false }, { true })
        assertEquals(listOf(actual), actuals.pending())
        assertEquals(487.5, actuals.pending().single().waterVolumeL!!, 0.0)

        // Start Tank commit refused; nothing written.
        val startJournals = JournalStore()
        var actualSaves = 0; var tripSaves = 0; var markerSaves = 0
        val coordinator = StartTankCommitCoordinator(
            journalStorage = startJournals,
            saveActual = { actualSaves++; true }, hasActual = { false },
            loadTrip = { _, _, _ -> saved }, saveTrip = { _, _, _ -> tripSaves++; true },
            ensureTankMarker = { markerSaves++; true }, hasTankMarker = { false },
            isTankHeld = heldOver(journalBytes),
        )
        val tank2 = TankSession("99999999-9999-4999-8999-999999999992", 2, startTime = "2026-11-01T02:00:00Z")
        val next = saved.copy(tankSessions = listOf(tank1.copy(endTime = "2026-11-01T01:50:00Z"), tank2), activeTankNumber = 2)
        assertFalse(coordinator.commit(owner, vineyard, saved, next, actual.copy(id = "actual-2", tankSessionId = tank2.id, tankNumber = 2)))
        assertNull(startJournals.journal)
        assertEquals(0, actualSaves); assertEquals(0, tripSaves); assertEquals(0, markerSaves)

        // Other journal holds overwrite heldReason but cannot drop the tank hold.
        reopened.hold("OCCURRENCE_REJECTED")
        assertTrue(OccurrenceTankConflictGate.isHeld(TripOccurrenceJournal(journalBytes, scope)))
        assertTrue(reopened.load()!!.heldReason!!.contains("OCCURRENCE_REJECTED"))
    }

    @Test fun holdReleasesOnlyOnFreshConflictFreeServerRowAndKeepsOtherHolds() = runBlocking {
        val journalBytes = Memory()
        val journal = newJournal(journalBytes)
        val conflict = OccurrenceRestoreLocalProgress.apply(conflictingServer, conflictingServer, saved)
        assertEquals(OccurrenceTankConflictGate.Outcome.HELD, OccurrenceTankConflictGate.onRestore(journal, conflict, true))
        journal.hold("OCCURRENCE_REJECTED")

        val reconciledServer = saved // server now holds Tank 1 exactly as recorded locally
        val clean = OccurrenceRestoreLocalProgress.apply(reconciledServer, reconciledServer, saved)
        assertFalse(clean.tankConflict)
        // Cached/offline rows never release.
        val unverified = OccurrenceTankConflictGate.onRestore(journal, clean, freshServerRow = false)
        assertEquals(OccurrenceTankConflictGate.Outcome.STILL_HELD_UNVERIFIED, unverified)
        assertFalse(OccurrenceTankConflictGate.replayAllowed(clean, unverified))
        assertTrue(OccurrenceTankConflictGate.isHeld(TripOccurrenceJournal(journalBytes, scope)))

        val released = OccurrenceTankConflictGate.onRestore(TripOccurrenceJournal(journalBytes, scope), clean, freshServerRow = true)
        assertEquals(OccurrenceTankConflictGate.Outcome.RELEASED, released)
        val after = TripOccurrenceJournal(journalBytes, scope).load()!!
        assertFalse(TripOccurrenceJournal.isTankConflictHeld(after))
        // The unrelated hold is not lifted by the tank release.
        assertNotNull(after.heldReason)
        assertTrue(after.heldReason!!.contains("OCCURRENCE_REJECTED"))
    }

    @Test fun normalTank1RecoveryIsUnchangedAndReplays() = runBlocking {
        val journalBytes = Memory()
        val journal = newJournal(journalBytes)
        val outbox = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(outbox)
        pending.configureReplayScope { PendingWriteRepository.ReplayScope(owner, 1) }
        val active = ActiveTripStore(MemorySnapshot())
        assertTrue(active.claimIfAvailable(owner, vineyard, saved))
        val server = mutableMapOf(tripId to saved.copy(tankSessions = emptyList(), activeTankNumber = null))
        val result = OccurrenceRestoreLocalProgress.apply(server.getValue(tripId), server.getValue(tripId), saved)
        assertTrue(result.tankReplayRequired)
        val outcome = OccurrenceTankConflictGate.onRestore(journal, result, freshServerRow = true)
        assertEquals(OccurrenceTankConflictGate.Outcome.NONE, outcome)
        assertTrue(OccurrenceTankConflictGate.replayAllowed(result, outcome))
        assertNull(journal.load()!!.heldReason)

        val sync = TripTankSync(tripRepo = null, pending = pending, activeTripStore = active,
            fetchTrip = { server[it] },
            saveTankSessions = { id, sessions, number, filling, fillNumber ->
                server.getValue(id).copy(tankSessions = sessions, activeTankNumber = number,
                    isFillingTank = filling, fillingTankNumber = fillNumber).also { server[id] = it }
            },
            isTankHeld = heldOver(journalBytes))
        sync.enqueue(result.trip)
        val synced = mutableListOf<Trip>()
        sync.replayAll { synced += it }
        assertEquals(listOf(tripId), synced.map { it.id })
        assertEquals(listOf(tank1), server.getValue(tripId).tankSessions)
        assertTrue(PendingWriteRepository(outbox).list().isEmpty())
    }
}
