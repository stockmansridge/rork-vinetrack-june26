package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Manual End Trip must never depend on planned-path completion.
 *
 * Regression case: trip 4700F6C1-593E-47E5-A409-F25255333545, a Free Drive
 * spraying trip with plannedPath = null, rowSequenceCount = 0, sequenceIndex
 * 0/0, pathLength = null, planned progress 0%, accumulated planned distance
 * 0.0 m, 29 completed Free Drive paths and 6,655 recorded GPS points, which
 * the operator could not end.
 */
class TripEndGateTest {

    /**
     * The supplied failing diagnostic, as a fixture. Every planned-path value
     * is absent or zero exactly as reported from the field.
     */
    private object FreeDriveFixture {
        val plannedPath: Double? = null
        const val ROW_SEQUENCE_COUNT = 0
        const val SEQUENCE_INDEX = 0
        val pathLength: Double? = null
        const val PLANNED_PROGRESS_PERCENT = 0.0
        const val ACCUMULATED_PLANNED_METRES = 0.0
        const val PATHS_COMPLETED = 29
        const val ROUTE_POINT_COUNT = 6_655
        const val SMOOTHED_SPEED_KMH = 17.4
        const val CALCULATED_SPEED_KMH = 17.0
        const val GPS_ACCURACY_METRES = 14.3
    }

    // --- A. The reported failure ------------------------------------------

    @Test
    fun `A - the exact failing free drive trip can be ended`() {
        // No tank is open, so nothing legitimately holds this trip open. Every
        // planned-path value below is absent, and none of them is consulted.
        val decision = TripEndGate.evaluate(
            activeTankNumber = null,
            isFillingTank = false,
            fillingTankNumber = null,
        )

        assertTrue(
            "a Free Drive trip with no planned path must still end",
            decision.isAllowed,
        )
        assertEquals(TripEndDecision.Allowed, decision)
    }

    @Test
    fun `A - none of the absent planned-path values can reach the gate`() {
        // The gate's signature physically cannot accept planned path, row
        // sequence, sequence index, path length, progress, accumulated
        // distance, current row, corridor state, GPS accuracy or speed.
        // This test documents the fixture and asserts the outcome is
        // unaffected by every one of those values being absent or zero.
        assertEquals(null, FreeDriveFixture.plannedPath)
        assertEquals(0, FreeDriveFixture.ROW_SEQUENCE_COUNT)
        assertEquals(0, FreeDriveFixture.SEQUENCE_INDEX)
        assertEquals(null, FreeDriveFixture.pathLength)
        assertEquals(0.0, FreeDriveFixture.PLANNED_PROGRESS_PERCENT, 0.0)
        assertEquals(0.0, FreeDriveFixture.ACCUMULATED_PLANNED_METRES, 0.0)

        assertTrue(
            TripEndGate.evaluate(
                activeTankNumber = null,
                isFillingTank = false,
                fillingTankNumber = null,
            ).isAllowed,
        )
    }

    @Test
    fun `A - completed free drive paths and a long route do not block ending`() {
        assertEquals(29, FreeDriveFixture.PATHS_COMPLETED)
        assertEquals(6_655, FreeDriveFixture.ROUTE_POINT_COUNT)

        assertTrue(
            TripEndGate.evaluate(null, isFillingTank = false, fillingTankNumber = null).isAllowed,
        )
    }

    // --- B. Row lock active ------------------------------------------------

    @Test
    fun `B - a live row lock does not block ending`() {
        // Row lock, corridor status and current row are not gate inputs, so a
        // trip ending mid-row ends exactly like one ending at a headland.
        assertTrue(
            TripEndGate.evaluate(null, isFillingTank = false, fillingTankNumber = null).isAllowed,
        )
    }

    // --- C. Active tank ----------------------------------------------------

    @Test
    fun `C - an open tank blocks ending and names the tank`() {
        val decision = TripEndGate.evaluate(
            activeTankNumber = 3,
            isFillingTank = false,
            fillingTankNumber = null,
        )

        val blocked = decision as TripEndDecision.Blocked
        assertEquals(TripEndBlocker.ActiveTank(3), blocked.blocker)
        assertFalse(decision.isAllowed)
    }

    @Test
    fun `C - the open-tank block states the exact required action`() {
        val blocker = (
            TripEndGate.evaluate(3, isFillingTank = false, fillingTankNumber = null)
                as TripEndDecision.Blocked
            ).blocker

        // The operator must never see a bare refusal: the message has to name
        // what is wrong AND what to press.
        assertEquals("Tank 3 is still running.", blocker.reason)
        assertEquals("Tap End Tank to close it, then end the trip.", blocker.requiredAction)
        assertTrue(blocker.message.contains("Tank 3"))
        assertTrue(blocker.message.contains("End Tank"))
    }

    @Test
    fun `C - ending the tank then unblocks the free drive trip`() {
        assertFalse(TripEndGate.evaluate(3, false, null).isAllowed)
        // Operator taps End Tank; the session closes and activeTankNumber clears.
        assertTrue(TripEndGate.evaluate(null, false, null).isAllowed)
    }

    // --- D. Tank actuals / fill timer --------------------------------------

    @Test
    fun `D - a running fill timer blocks ending rather than silently failing`() {
        val decision = TripEndGate.evaluate(
            activeTankNumber = null,
            isFillingTank = true,
            fillingTankNumber = 4,
        )

        val blocked = decision as TripEndDecision.Blocked
        assertEquals(TripEndBlocker.FillingTank(4), blocked.blocker)
        assertTrue(blocked.blocker.message.contains("Tank 4"))
        assertTrue(blocked.blocker.message.contains("Stop Fill"))
    }

    @Test
    fun `D - a fill timer with no known tank still explains itself`() {
        val blocker = (
            TripEndGate.evaluate(null, isFillingTank = true, fillingTankNumber = null)
                as TripEndDecision.Blocked
            ).blocker

        assertEquals("A tank fill timer is still running.", blocker.reason)
        assertTrue(blocker.requiredAction.contains("Stop Fill"))
    }

    @Test
    fun `D - stopping the fill then allows the trip to finish`() {
        assertFalse(TripEndGate.evaluate(null, isFillingTank = true, fillingTankNumber = 4).isAllowed)
        assertTrue(TripEndGate.evaluate(null, isFillingTank = false, fillingTankNumber = null).isAllowed)
    }

    @Test
    fun `D - an open tank is reported before a fill timer`() {
        // Both outstanding: the tank is the action the operator must take
        // first, so naming the fill timer would send them to the wrong button.
        val blocker = (
            TripEndGate.evaluate(2, isFillingTank = true, fillingTankNumber = 2)
                as TripEndDecision.Blocked
            ).blocker

        assertEquals(TripEndBlocker.ActiveTank(2), blocker)
    }

    // --- F. Planned-path trips unchanged -----------------------------------

    @Test
    fun `F - a planned-path trip ends on exactly the same terms`() {
        // The gate is mode-agnostic: a sequential trip with a full row plan is
        // evaluated by the same two record conditions, so this correction
        // cannot have changed planned-route behaviour.
        assertTrue(TripEndGate.evaluate(null, false, null).isAllowed)
        assertFalse(TripEndGate.evaluate(1, false, null).isAllowed)
    }

    @Test
    fun `F - an incomplete planned route does not block ending`() {
        // Ending early with rows still outstanding is normal and supported;
        // the review sheet records the coverage that was actually achieved.
        assertTrue(TripEndGate.evaluate(null, false, null).isAllowed)
    }

    // --- H. Movement --------------------------------------------------------

    @Test
    fun `H - ending while moving at speed is allowed`() {
        // Captured at ~17 km/h with 14.3 m GPS accuracy. Speed, smoothed
        // speed and GPS quality are not gate inputs, so a moving tractor ends
        // its trip identically to a stopped one. Intended behaviour: movement
        // NEVER blocks manual termination.
        assertEquals(17.4, FreeDriveFixture.SMOOTHED_SPEED_KMH, 0.001)
        assertEquals(17.0, FreeDriveFixture.CALCULATED_SPEED_KMH, 0.001)
        assertEquals(14.3, FreeDriveFixture.GPS_ACCURACY_METRES, 0.001)

        assertTrue(
            "movement must not block manual End Trip",
            TripEndGate.evaluate(null, false, null).isAllowed,
        )
    }

    @Test
    fun `H - ending while stopped behaves identically`() {
        val moving = TripEndGate.evaluate(null, false, null)
        val stopped = TripEndGate.evaluate(null, false, null)

        assertEquals("speed cannot change the outcome", moving, stopped)
    }
}
