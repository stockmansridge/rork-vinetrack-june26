package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.SprayTankActualChemical
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StartTankCommitCoordinatorTest {
    private class JournalStore : StartTankJournalStorage {
        var journal: StartTankCommitCoordinator.Journal? = null
        var failWrites: Boolean = false
        var failClear: Boolean = false
        override fun read(): StartTankCommitCoordinator.Journal? = journal
        override fun write(journal: StartTankCommitCoordinator.Journal): Boolean {
            if (failWrites) return false
            this.journal = journal
            return true
        }
        override fun clear(): Boolean {
            if (failClear) return false
            journal = null
            return true
        }
    }

    private data class Harness(
        val journals: JournalStore = JournalStore(),
        var actual: SprayTankActual? = null,
        var trip: Trip? = sourceTrip,
        var markerTripId: String? = null,
        var failActual: Boolean = false,
        var failTrip: Boolean = false,
        var failMarker: Boolean = false,
        var actualSaveCount: Int = 0,
        var tripSaveCount: Int = 0,
        var markerSaveCount: Int = 0,
    ) {
        fun coordinator(): StartTankCommitCoordinator = StartTankCommitCoordinator(
            journalStorage = journals,
            saveActual = { value -> actualSaveCount++; if (failActual) false else { actual = value; true } },
            hasActual = { value -> actual?.id == value.id && actual?.tankSessionId == value.tankSessionId },
            loadTrip = { owner, vineyard, id -> trip?.takeIf { owner == "user" && vineyard == it.vineyardId && id == it.id } },
            saveTrip = { _, _, value -> tripSaveCount++; if (failTrip) false else { trip = value; true } },
            ensureTankMarker = { value -> markerSaveCount++; if (failMarker) false else { markerTripId = value.id; true } },
            hasTankMarker = { id -> markerTripId == id },
        )
    }

    companion object {
        private val sourceTrip = Trip(
            id = "trip", vineyardId = "vineyard", paddockName = "Block",
            startTime = "2026-09-05T00:00:00Z", isActive = true,
        )
    }

    private val trip = sourceTrip.copy(
        tankSessions = listOf(TankSession("session", 1, "2026-09-05T01:00:00Z")),
        activeTankNumber = 1,
    )
    private val actual = SprayTankActual(
        id = "actual", vineyardId = "vineyard", sprayRecordId = "spray", tripId = "trip",
        tankSessionId = "session", tankNumber = 1, waterVolumeL = 500.0,
        chemicals = listOf(SprayTankActualChemical("line", "planned", null, "Product", 0.0, "mL")),
        confirmedAt = "2026-09-05T01:00:00Z", confirmedBy = "user",
    )

    @Test fun gpsProgressDuringConfirmationIsRetainedByTankOperationMerge() {
        val current = sourceTrip.copy(
            pathPoints = listOf(CoordinatePoint(-33.0, 149.0)),
            totalDistance = 42.0,
            completedPaths = listOf(4.5),
            startEngineHours = 123.4,
        )
        val merged = StartTankOperationMerge.apply(current, sourceTrip, trip, "session", 1)
        assertNotNull(merged)
        assertEquals(current.pathPoints, merged?.pathPoints)
        assertEquals(current.totalDistance, merged?.totalDistance)
        assertEquals(current.completedPaths, merged?.completedPaths)
        assertEquals(current.startEngineHours, merged?.startEngineHours)
        assertEquals("session", merged?.tankSessions?.single()?.id)
    }

    @Test fun endedOrTankConflictedTripRefusesOperation() {
        assertNull(StartTankOperationMerge.apply(sourceTrip.copy(isActive = false), sourceTrip, trip, "session", 1))
        assertNull(StartTankOperationMerge.apply(sourceTrip.copy(endTime = "2026-09-05T02:00:00Z"), sourceTrip, trip, "session", 1))
        val conflicting = sourceTrip.copy(
            tankSessions = listOf(TankSession("later", 2, "2026-09-05T01:30:00Z")),
            activeTankNumber = 2,
        )
        assertNull(StartTankOperationMerge.apply(conflicting, sourceTrip, trip, "session", 1))
    }

    @Test fun failedJournalWriteMutatesNothing() {
        val h = Harness().also { it.journals.failWrites = true }
        assertFalse(h.coordinator().commit("user", "vineyard", sourceTrip, trip, actual))
        assertNull(h.actual); assertEquals(sourceTrip, h.trip); assertNull(h.markerTripId)
    }

    @Test fun recoveryAfterActualSaveKeepsNewerRouteAndStableIds() {
        val h = Harness(failTrip = true)
        assertFalse(h.coordinator().commit("user", "vineyard", sourceTrip, trip, actual))
        assertEquals("actual", h.actual?.id)
        val newerRoute = sourceTrip.copy(
            pathPoints = listOf(CoordinatePoint(-33.0, 149.0), CoordinatePoint(-33.0001, 149.0001)),
            totalDistance = 77.0,
            completedPaths = listOf(8.5),
            endEngineHours = 130.0,
            completionNotes = "new metadata",
        )
        h.trip = newerRoute
        h.failTrip = false
        assertEquals("actual", h.coordinator().recover()?.actualRecordId)
        assertEquals(newerRoute.pathPoints, h.trip?.pathPoints)
        assertEquals(77.0, h.trip?.totalDistance)
        assertEquals(listOf(8.5), h.trip?.completedPaths)
        assertEquals(130.0, h.trip?.endEngineHours)
        assertEquals("new metadata", h.trip?.completionNotes)
        assertEquals(1, h.trip?.tankSessions?.count { it.id == "session" })
        assertEquals(1, h.actualSaveCount)
        assertNull(h.journals.journal)
    }

    @Test fun recoveryAfterTripSaveCompletesMarker() {
        val h = Harness(failMarker = true)
        assertFalse(h.coordinator().commit("user", "vineyard", sourceTrip, trip, actual))
        assertEquals(trip, h.trip); assertNull(h.markerTripId)
        h.failMarker = false
        assertEquals("session", h.coordinator().recover()?.tankSessionId)
        assertEquals("trip", h.markerTripId)
    }

    @Test fun crashBeforeJournalClearIsRecoveredIdempotently() {
        val h = Harness().also { it.journals.failClear = true }
        assertFalse(h.coordinator().commit("user", "vineyard", sourceTrip, trip, actual))
        val writes = Triple(h.actualSaveCount, h.tripSaveCount, h.markerSaveCount)
        h.journals.failClear = false
        assertTrue(h.coordinator().recover() != null)
        assertNull(h.coordinator().recover())
        assertEquals(writes, Triple(h.actualSaveCount, h.tripSaveCount, h.markerSaveCount))
    }

    @Test fun laterTankConflictIsPreservedAndUnresolvedJournalIsNotOverwritten() {
        val h = Harness(failTrip = true)
        assertFalse(h.coordinator().commit("user", "vineyard", sourceTrip, trip, actual))
        val originalJournalId = h.journals.journal?.actualRecordId
        val laterSession = TankSession("later", 2, "2026-09-05T02:00:00Z")
        h.trip = sourceTrip.copy(tankSessions = listOf(laterSession), activeTankNumber = 2)
        h.failTrip = false

        assertNull(h.coordinator().recover())
        assertEquals(listOf(laterSession), h.trip?.tankSessions)
        assertEquals(2, h.trip?.activeTankNumber)
        val anotherActual = actual.copy(id = "another", tankSessionId = "another-session", tankNumber = 3)
        assertFalse(h.coordinator().commit("user", "vineyard", sourceTrip, trip, anotherActual))
        assertEquals(originalJournalId, h.journals.journal?.actualRecordId)
    }

    @Test fun firstCommitMergesLiveRouteAheadOfStoredSnapshotAndRelaunchRetainsIt() {
        val stored = sourceTrip.copy(pathPoints = listOf(CoordinatePoint(-33.0, 149.0)))
        val live = sourceTrip.copy(pathPoints = stored.pathPoints + listOf(
            CoordinatePoint(-33.0001, 149.0001), CoordinatePoint(-33.0002, 149.0002),
        ), totalDistance = 88.0)
        val intended = live.copy(tankSessions = trip.tankSessions, activeTankNumber = 1)
        val h = Harness(trip = stored)
        assertTrue(h.coordinator().commit("user", "vineyard", live, intended, actual))
        assertEquals(live.pathPoints, h.trip?.pathPoints)
        assertEquals(88.0, h.trip?.totalDistance)
        assertEquals(live.pathPoints, h.coordinator().let { h.trip }?.pathPoints)
    }

    @Test fun sameScreenRetryResumesFrozenJournalWithoutReplacingValues() {
        val h = Harness(failMarker = true)
        assertFalse(h.coordinator().commit("user", "vineyard", sourceTrip, trip, actual))
        val frozen = h.journals.journal ?: error("journal missing")
        h.failMarker = false
        val resumed = h.coordinator().resume("user", "vineyard", sourceTrip, sourceTrip, 1)
        assertNotNull(resumed)
        assertEquals(frozen.actualRecordId, h.actual?.id)
        assertEquals(frozen.confirmationTimestamp, h.actual?.confirmedAt)
        assertEquals(frozen.tankSessionId, h.actual?.tankSessionId)
        assertNull(h.journals.journal)
    }

    @Test fun firstCommitRequiresAndVerifiesDurableTripWrite() {
        val h = Harness()
        assertTrue(h.coordinator().commit("user", "vineyard", sourceTrip, trip, actual))
        assertEquals(1, h.tripSaveCount)
        assertEquals(trip, h.trip)
        assertNull(h.journals.journal)
    }

    @Test fun fillOnlySessionIdentityIsTransitionedRatherThanMistakenForCompletedStart() {
        val fill = TankSession("session", 1, "2026-09-05T00:30:00Z", fillStartTime = "2026-09-05T00:30:00Z")
        val source = sourceTrip.copy(tankSessions = listOf(fill), isFillingTank = true, fillingTankNumber = 1)
        val intendedSession = fill.copy(startTime = actual.confirmedAt, startRow = 4.5, fillEndTime = actual.confirmedAt)
        val intended = source.copy(tankSessions = listOf(intendedSession), activeTankNumber = 1, isFillingTank = false, fillingTankNumber = null)
        val h = Harness(trip = source)
        assertTrue(h.coordinator().commit("user", "vineyard", source, intended, actual))
        assertEquals(actual.confirmedAt, h.trip?.tankSessions?.single()?.startTime)
        assertEquals(4.5, h.trip?.tankSessions?.single()?.startRow)
        assertEquals(actual.confirmedAt, h.trip?.tankSessions?.single()?.fillEndTime)
    }

    @Test fun repeatedRecoveryFromEachIncompleteStoreStateNeverDuplicates() {
        listOf("actual", "trip", "marker").forEach { failed ->
            val h = Harness(
                failActual = failed == "actual",
                failTrip = failed == "trip",
                failMarker = failed == "marker",
            )
            assertFalse(h.coordinator().commit("user", "vineyard", sourceTrip, trip, actual))
            h.failActual = false; h.failTrip = false; h.failMarker = false
            assertTrue(h.coordinator().recover() != null)
            assertNull(h.coordinator().recover())
            assertEquals("actual", h.actual?.id)
            assertEquals("session", h.actual?.tankSessionId)
            assertEquals(1, h.trip?.tankSessions?.count { it.id == "session" })
        }
    }
}
