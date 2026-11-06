package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS parity: ended Trips meet the server's tank completion rules (main 4ad437c). */
class TripEndTankClosureTest {
    private val fillStart = "2026-11-06T00:10:00Z"
    private val fillEnd = "2026-11-06T00:20:00Z"

    /** Shape of a Start/Stop Fill session that was never sprayed. */
    private val fillOnly = TankSession(id = "t1", tankNumber = 1, startTime = fillStart,
        fillStartTime = fillStart, fillEndTime = fillEnd)
    private val sprayed = TankSession(id = "t2", tankNumber = 2, startTime = "2026-11-06T00:25:00Z",
        startRow = 4.0, fillStartTime = fillStart, fillEndTime = fillEnd)

    private fun trip(vararg sessions: TankSession, fn: String? = "spraying", tanks: Int? = 2, filling: Boolean = false) =
        Trip(id = "trip", vineyardId = "v", isActive = true, tripFunction = fn, totalTanks = tanks,
            tankSessions = sessions.toList(), isFillingTank = filling)

    @Test fun filledButNeverSprayedTankIsClosedAtItsOwnFillEnd() {
        val closed = TankSessionLifecycle.closingFillOnlySessionsBeforeTripEnd(trip(fillOnly)).tankSessions.single()
        assertEquals("server and Portal treat no end time as an unfinished tank", fillEnd, closed.endTime)
        assertNull("still recognisable as a fill that was never sprayed", closed.startRow)
        assertEquals(fillEnd, closed.fillEndTime)
        assertFalse(TankSessionLifecycle.wasSprayed(closed))
    }

    @Test fun sprayedAndAlreadyEndedTanksAreUntouched() {
        val ended = fillOnly.copy(id = "t3", endTime = "2026-11-06T00:21:00Z")
        val input = trip(sprayed, ended)
        assertSame(input, TankSessionLifecycle.closingFillOnlySessionsBeforeTripEnd(input))
    }

    @Test fun aRunningFillIsNeverClosed() {
        val running = fillOnly.copy(fillEndTime = null)
        val input = trip(running, filling = true)
        assertSame(input, TankSessionLifecycle.closingFillOnlySessionsBeforeTripEnd(input))
        assertNull(TankSessionLifecycle.closingFillOnlySessionsBeforeTripEnd(trip(running)).tankSessions.single().endTime)
    }

    @Test fun anEndedTripIsNotRewritten() {
        val input = trip(fillOnly).copy(isActive = false, endTime = "2026-11-06T01:00:00Z")
        assertSame(input, TankSessionLifecycle.closingFillOnlySessionsBeforeTripEnd(input))
    }

    @Test fun sprayWithPlannedTanksButNoneSprayedAsksBeforeEnding() {
        assertTrue(TankSessionLifecycle.endWouldRecordNoSprayedTank(trip()))
        assertTrue("a fill alone is not a sprayed tank", TankSessionLifecycle.endWouldRecordNoSprayedTank(trip(fillOnly)))
    }

    @Test fun sprayWithASprayedTankEndsWithoutThePrompt() =
        assertFalse(TankSessionLifecycle.endWouldRecordNoSprayedTank(trip(fillOnly, sprayed)))

    @Test fun nonSprayOrUnplannedTripsNeverPrompt() {
        assertFalse(TankSessionLifecycle.endWouldRecordNoSprayedTank(trip(fn = "mowing")))
        assertFalse(TankSessionLifecycle.endWouldRecordNoSprayedTank(trip(tanks = 0)))
        assertFalse(TankSessionLifecycle.endWouldRecordNoSprayedTank(trip(tanks = null)))
    }
}
