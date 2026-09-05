package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.SprayTankActualChemical
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StartTankCommitCoordinatorTest {
    private class JournalStore : StartTankJournalStorage {
        var journal: StartTankCommitCoordinator.Journal? = null
        var failWrites = false
        var failClear = false
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
        var trip: Trip? = null,
        var markerTripId: String? = null,
        var failActual: Boolean = false,
        var failTrip: Boolean = false,
        var failMarker: Boolean = false,
        var actualSaveCount: Int = 0,
        var tripSaveCount: Int = 0,
        var markerSaveCount: Int = 0,
    ) {
        fun coordinator() = StartTankCommitCoordinator(
            journalStorage = journals,
            saveActual = { value -> actualSaveCount++; if (failActual) false else { actual = value; true } },
            hasActual = { value -> actual?.id == value.id && actual?.tankSessionId == value.tankSessionId },
            saveTrip = { _, _, value -> tripSaveCount++; if (failTrip) false else { trip = value; true } },
            hasTrip = { value -> trip == value },
            ensureTankMarker = { value -> markerSaveCount++; if (failMarker) false else { markerTripId = value.id; true } },
            hasTankMarker = { id -> markerTripId == id },
        )
    }

    private val trip = Trip(
        id = "trip", vineyardId = "vineyard", paddockName = "Block",
        startTime = "2026-09-05T00:00:00Z", isActive = true,
        tankSessions = listOf(TankSession("session", 1, "2026-09-05T01:00:00Z")),
        activeTankNumber = 1,
    )
    private val actual = SprayTankActual(
        id = "actual", vineyardId = "vineyard", sprayRecordId = "spray", tripId = "trip",
        tankSessionId = "session", tankNumber = 1, waterVolumeL = 500.0,
        chemicals = listOf(SprayTankActualChemical("line", "planned", null, "Product", 0.0, "mL")),
        confirmedAt = "2026-09-05T01:00:00Z", confirmedBy = "user",
    )

    @Test fun failedJournalWriteMutatesNothing() {
        val h = Harness().also { it.journals.failWrites = true }
        assertFalse(h.coordinator().commit("user", "vineyard", trip, actual))
        assertNull(h.actual); assertNull(h.trip); assertNull(h.markerTripId)
    }

    @Test fun recoveryAfterActualSaveCompletesSameStableIds() {
        val h = Harness(failTrip = true)
        assertFalse(h.coordinator().commit("user", "vineyard", trip, actual))
        assertEquals("actual", h.actual?.id); assertNull(h.trip)
        h.failTrip = false
        assertEquals("actual", h.coordinator().recover()?.actualRecordId)
        assertEquals("session", h.trip?.tankSessions?.single()?.id)
        assertNull(h.journals.journal)
    }

    @Test fun recoveryAfterTripSaveCompletesMarker() {
        val h = Harness(failMarker = true)
        assertFalse(h.coordinator().commit("user", "vineyard", trip, actual))
        assertEquals(trip, h.trip); assertNull(h.markerTripId)
        h.failMarker = false
        assertEquals("session", h.coordinator().recover()?.tankSessionId)
        assertEquals("trip", h.markerTripId)
    }

    @Test fun crashBeforeJournalClearIsRecoveredIdempotently() {
        val h = Harness().also { it.journals.failClear = true }
        assertFalse(h.coordinator().commit("user", "vineyard", trip, actual))
        val writes = Triple(h.actualSaveCount, h.tripSaveCount, h.markerSaveCount)
        h.journals.failClear = false
        assertTrue(h.coordinator().recover() != null)
        assertNull(h.coordinator().recover())
        assertEquals(writes, Triple(h.actualSaveCount, h.tripSaveCount, h.markerSaveCount))
    }

    @Test fun repeatedRecoveryFromEachIncompleteStoreStateNeverDuplicates() {
        listOf("actual", "trip", "marker").forEach { failed ->
            val h = Harness(
                failActual = failed == "actual",
                failTrip = failed == "trip",
                failMarker = failed == "marker",
            )
            assertFalse(h.coordinator().commit("user", "vineyard", trip, actual))
            h.failActual = false; h.failTrip = false; h.failMarker = false
            assertTrue(h.coordinator().recover() != null)
            assertNull(h.coordinator().recover())
            assertEquals("actual", h.actual?.id)
            assertEquals("session", h.actual?.tankSessionId)
            assertEquals(1, h.trip?.tankSessions?.count { it.id == "session" })
        }
    }
}
