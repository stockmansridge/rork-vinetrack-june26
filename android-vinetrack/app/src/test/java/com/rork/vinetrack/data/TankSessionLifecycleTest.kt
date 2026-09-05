package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.ui.screens.TankControlInteractionState
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TankSessionLifecycleTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val fillStart = "2026-09-05T00:00:00Z"
    private val fillEnd = "2026-09-05T00:01:00Z"
    private val sprayStart = "2026-09-05T00:02:00Z"
    private val sprayEnd = "2026-09-05T00:10:00Z"

    private fun trip(
        sessions: List<TankSession> = emptyList(),
        activeTankNumber: Int? = null,
        isFilling: Boolean = false,
        fillingTankNumber: Int? = null,
    ) = Trip(
        id = "trip",
        vineyardId = "vineyard",
        paddockName = "Lifecycle block",
        startTime = "2026-09-04T23:00:00Z",
        isActive = true,
        currentRowNumber = 4.5,
        tankSessions = sessions,
        activeTankNumber = activeTankNumber,
        totalTanks = 2,
        isFillingTank = isFilling,
        fillingTankNumber = fillingTankNumber,
    )

    private fun fillOnly(completed: Boolean) = TankSession(
        id = "tank-session-1",
        tankNumber = 1,
        startTime = fillStart,
        fillStartTime = fillStart,
        fillEndTime = if (completed) fillEnd else null,
    )

    @Test
    fun `start without fill creates Tank 1 exactly once`() {
        val started = TankSessionLifecycle.start(trip(), sprayStart, 4.5) { "tank-session-1" }
        assertEquals(1, started.tankSessions.size)
        assertEquals("tank-session-1", started.tankSessions.single().id)
        assertEquals(1, started.tankSessions.single().tankNumber)
        assertEquals(sprayStart, started.tankSessions.single().startTime)
        assertEquals(4.5, started.tankSessions.single().startRow)
        assertEquals(1, started.activeTankNumber)
        assertFalse(started.isFillingTank)
        assertNull(started.fillingTankNumber)

        val repeated = TankSessionLifecycle.start(started, sprayEnd, 5.5) { "must-not-exist" }
        assertEquals(started, repeated)
    }

    @Test
    fun `completed fill-only Tank 1 is reused without creating Tank 2`() {
        val started = TankSessionLifecycle.start(trip(listOf(fillOnly(true))), sprayStart, 6.5)
        assertEquals(1, started.tankSessions.size)
        val session = started.tankSessions.single()
        assertEquals("tank-session-1", session.id)
        assertEquals(1, session.tankNumber)
        assertEquals(sprayStart, session.startTime)
        assertEquals(6.5, session.startRow)
        assertEquals(fillStart, session.fillStartTime)
        assertEquals(fillEnd, session.fillEndTime)
        assertEquals(1, started.activeTankNumber)
        assertFalse(started.isFillingTank)
        assertNull(started.fillingTankNumber)
        assertFalse(started.tankSessions.any { it.tankNumber == 2 })
    }

    @Test
    fun `running fill-only Tank 1 is stopped and reused`() {
        val started = TankSessionLifecycle.start(
            trip(listOf(fillOnly(false)), isFilling = true, fillingTankNumber = 1),
            sprayStart,
            7.5,
        )
        assertEquals(1, started.tankSessions.size)
        val session = started.tankSessions.single()
        assertEquals("tank-session-1", session.id)
        assertEquals(1, session.tankNumber)
        assertEquals(fillStart, session.fillStartTime)
        assertEquals(sprayStart, session.fillEndTime)
        assertEquals(120L, session.fillDurationSeconds)
        assertEquals(sprayStart, session.startTime)
        assertFalse(started.isFillingTank)
        assertNull(started.fillingTankNumber)
        assertFalse(started.tankSessions.any { it.tankNumber == 2 })
    }

    @Test
    fun `end targets active Tank 1 and cancellation and double confirmation are safe`() {
        val unrelatedFill = TankSession(
            id = "tank-session-2",
            tankNumber = 2,
            startTime = fillStart,
            fillStartTime = fillStart,
            fillEndTime = fillEnd,
        )
        val activeTankOne = TankSessionLifecycle.start(trip(listOf(fillOnly(true))), sprayStart, 8.5)
        var current = activeTankOne.copy(tankSessions = activeTankOne.tankSessions + unrelatedFill)
        val beforeCancellation = current
        var controls = TankControlInteractionState().tapEnd().cancelEnd()
        assertEquals(beforeCancellation, current)

        controls = controls.tapEnd().confirmEnd {
            current = TankSessionLifecycle.end(current, sprayEnd, 12.5)
        }
        assertEquals(sprayEnd, current.tankSessions[0].endTime)
        assertEquals(12.5, current.tankSessions[0].endRow)
        assertNull(current.activeTankNumber)
        assertNull(current.tankSessions[1].endTime)

        val afterFirstConfirmation = current
        controls.confirmEnd {
            current = TankSessionLifecycle.end(current, "2026-09-05T00:11:00Z", 13.5)
        }
        assertEquals(afterFirstConfirmation, current)
    }

    @Test
    fun `relaunch offline payload and canonical contract preserve reused closed session`() {
        val closed = TankSessionLifecycle.end(
            TankSessionLifecycle.start(trip(listOf(fillOnly(true))), sprayStart, 9.5),
            sprayEnd,
            14.5,
        )
        val storage = MemoryActiveTripStorage()
        ActiveTripStore(storage).save("owner", "vineyard", closed)
        val relaunched = ActiveTripStore(storage).load()!!.trip
        assertEquals(closed, relaunched)

        val replayPayload = json.encodeToString(Trip.serializer(), relaunched)
        val replayed = json.decodeFromString(Trip.serializer(), replayPayload)
        val session = replayed.tankSessions.single()
        assertEquals("tank-session-1", session.id)
        assertEquals(1, session.tankNumber)
        assertEquals(fillStart, session.fillStartTime)
        assertEquals(fillEnd, session.fillEndTime)
        assertEquals(sprayStart, session.startTime)
        assertEquals(sprayEnd, session.endTime)
        assertEquals(14.5, session.endRow)
        assertNull(replayed.activeTankNumber)
        assertFalse(replayed.isFillingTank)
        assertNull(replayed.fillingTankNumber)

        assertTrue(replayPayload.contains("\"tank_number\":1"))
        assertTrue(replayPayload.contains("\"active_tank_number\":null"))
        assertTrue(replayPayload.contains("\"is_filling_tank\":false"))
        assertTrue(replayPayload.contains("\"filling_tank_number\":null"))

        val serverBeforeReplay = trip(sessions = listOf(fillOnly(true)))
        val merged = requireNotNull(TankSessionReplayMerge.merge(serverBeforeReplay, replayed))
        val replayedSession = merged.sessions.single()
        assertEquals("tank-session-1", replayedSession.id)
        assertEquals(1, replayedSession.tankNumber)
        assertEquals(fillStart, replayedSession.fillStartTime)
        assertEquals(fillEnd, replayedSession.fillEndTime)
        assertEquals(sprayStart, replayedSession.startTime)
        assertEquals(sprayEnd, replayedSession.endTime)
        assertEquals(14.5, replayedSession.endRow)
        assertNull(merged.activeTankNumber)
        assertFalse(merged.isFillingTank)
        assertNull(merged.fillingTankNumber)
    }

    private class MemoryActiveTripStorage : ActiveTripSnapshotStorage {
        private var value: String? = null
        override fun read(): String? = value
        override fun write(value: String) { this.value = value }
        override fun remove() { value = null }
    }
}
