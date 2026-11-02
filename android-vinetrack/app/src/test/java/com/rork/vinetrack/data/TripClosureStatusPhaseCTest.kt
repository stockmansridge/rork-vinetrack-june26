package com.rork.vinetrack.data

import com.rork.vinetrack.data.TripClosureStatus.Input
import com.rork.vinetrack.data.TripClosureStatus.Marker
import com.rork.vinetrack.data.TripClosureStatus.ServerEvidence
import com.rork.vinetrack.data.TripClosureStatus.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TripClosureStatusPhaseCTest {
    private val session = "30259F0A-E2E2-41A2-8FBF-4569028A6F45"

    private fun closed(
        evidence: ServerEvidence = ServerEvidence.FRESH_READ,
        active: Boolean = false,
        end: String? = "2026-11-02T03:00:00Z",
        serverSessions: Set<String>? = setOf(session.lowercase()),
        locallyEnded: Boolean = false,
        markers: List<Marker> = emptyList(),
        occurrence: Int? = 0,
        occurrenceHeld: String? = null,
        actualSessions: Set<String> = setOf(session),
        pendingActuals: List<String> = emptyList(),
        holds: List<String> = emptyList(),
    ) = Input("3bfb7f81-2ae2-4f33-8fd8-6666b2b45393", evidence, active, end, serverSessions, locallyEnded,
        markers, occurrence, occurrenceHeld, actualSessions, pendingActuals, holds)

    @Test fun completedTripReadbackComparesTheSameInstantAcrossPostgresUtcFormats() {
        // Android's original End writes Z; PostgREST can read back +00:00.
        // Reusing the linked-Spray exact-instant matcher avoids false scope
        // failure without tolerating any changed End time.
        val original = "2026-11-02T23:12:06.123405Z"
        val postgres = "2026-11-02T23:12:06.123405+00:00"
        val changed = "2026-11-02T23:12:06.123406+00:00"

        assertTrue(TrackedSprayCompletionSync.sameTime(original, postgres))
        assertFalse(TrackedSprayCompletionSync.sameTime(original, changed))
        assertFalse(TrackedSprayCompletionSync.sameTime(original, null))
        assertFalse(TrackedSprayCompletionSync.sameTime(null, postgres))
    }

    @Test fun allAcknowledgedAndTerminalIsClosedSynced() {
        val r = TripClosureStatus.evaluate(closed())
        assertEquals(State.CLOSED_SYNCED, r.state)
        assertTrue(r.reasons.isEmpty())
    }

    @Test fun localEndPendingIsNeverSynced() {
        assertEquals(State.LOCAL_END_PENDING, TripClosureStatus.evaluate(closed(locallyEnded = true)).state)
    }

    @Test fun serverActiveIsNotClosed() {
        assertEquals(State.ACTIVE, TripClosureStatus.evaluate(closed(active = true, end = null)).state)
    }

    @Test fun pendingActualBlocksClosure() {
        val r = TripClosureStatus.evaluate(closed(pendingActuals = listOf("2b07a0ce")))
        assertEquals(State.DEPENDENTS_PENDING, r.state)
    }

    @Test fun pendingTankMarkerBlocksClosure() {
        val r = TripClosureStatus.evaluate(closed(markers = listOf(Marker("trip_tank", "pending"))))
        assertEquals(State.DEPENDENTS_PENDING, r.state)
    }

    @Test fun blockedMarkerIsHeld() {
        val r = TripClosureStatus.evaluate(closed(markers = listOf(Marker("trip_tank", "blocked"))))
        assertEquals(State.DEPENDENTS_HELD, r.state)
    }

    @Test fun missingRequiredSessionOnServerIsHeld() {
        val r = TripClosureStatus.evaluate(closed(serverSessions = emptySet()))
        assertEquals(State.DEPENDENTS_HELD, r.state)
        assertTrue(TankDependencyVerification.REQUIRED_SESSION_MISSING in r.reasons)
    }

    @Test fun pendingOccurrenceOperationBlocksClosure() {
        assertEquals(State.DEPENDENTS_PENDING, TripClosureStatus.evaluate(closed(occurrence = 1)).state)
        assertEquals(State.DEPENDENTS_HELD, TripClosureStatus.evaluate(closed(occurrence = null)).state)
        assertEquals(State.DEPENDENTS_HELD, TripClosureStatus.evaluate(closed(occurrenceHeld = "X")).state)
    }

    @Test fun failedOrAbsentServerReadIsUnconfirmed() {
        assertEquals(State.SERVER_STATE_UNCONFIRMED, TripClosureStatus.evaluate(closed(evidence = ServerEvidence.READ_FAILED)).state)
        assertEquals(State.SERVER_STATE_UNCONFIRMED, TripClosureStatus.evaluate(closed(evidence = ServerEvidence.ABSENT)).state)
    }

    @Test fun tankConflictHoldIsHeld() {
        assertEquals(State.DEPENDENTS_HELD, TripClosureStatus.evaluate(closed(holds = listOf("TRIP_TANK_CONFLICT"))).state)
    }

    @Test fun terminalTripWithNullSprayEndCannotBeClosedSynced() {
        val r = TripClosureStatus.evaluate(closed().copy(sprayCompletionIssue = "LINKED_SPRAY_COMPLETION_PENDING"))
        assertEquals(State.DEPENDENTS_PENDING, r.state)
        assertTrue("LINKED_SPRAY_COMPLETION_PENDING" in r.reasons)
    }

    @Test fun freshTripReadCannotMaskFailedSprayRead() {
        assertEquals(State.DEPENDENTS_PENDING, TripClosureStatus.evaluate(
            closed().copy(sprayCompletionIssue = "LINKED_SPRAY_READ_FAILED")).state)
    }

    @Test fun noActualsTripClosesWithoutSessions() {
        val r = TripClosureStatus.evaluate(closed(actualSessions = emptySet(), serverSessions = emptySet()))
        assertEquals(State.CLOSED_SYNCED, r.state)
    }
}
