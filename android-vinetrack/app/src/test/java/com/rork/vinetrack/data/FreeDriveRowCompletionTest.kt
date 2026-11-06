package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos

/** iOS parity: Free Drive auto row completion (TripTrackingService Free Drive rules). */
class FreeDriveRowCompletionTest {
    private val baseLat = -34.0
    private val baseLon = 138.0
    private fun lat(northM: Double) = baseLat + northM / 111_320.0
    private fun lon(eastM: Double) = baseLon + eastM / (111_320.0 * cos(Math.toRadians(baseLat)))

    /** Rows run north, 2.5 m apart; row n sits at east = (n-1)*2.5. */
    private fun rows(lengthM: Double, count: Int = 3) = (1..count).map { n ->
        val east = (n - 1) * 2.5
        PaddockRow(number = n, startPoint = CoordinatePoint(lat(0.0), lon(east)), endPoint = CoordinatePoint(lat(lengthM), lon(east)))
    }

    /** Drive the aisle between rows 1 and 2 (path 1.5) north at 2 m/s; returns the north metre where it completed. */
    private fun drive(
        tracker: FreeDriveRowCompletion, rows: List<PaddockRow>, toNorthM: Double,
        path: Double = 1.5, offset: Int = 0, inCorridor: Boolean = true, done: Set<Double> = emptySet(),
    ): Double? {
        var north = 2.0
        var t = 0L
        while (north <= toNorthM) {
            val result = tracker.observe(path, inCorridor, 1.0, 2.5, lat(north), lon(1.25), t, rows, offset, done)
            if (result != null) { assertEquals(path, result, 0.0); return north }
            north += 2.0; t += 1_000
        }
        return null
    }

    @Test fun longRowCompletesNearTheEndNotMidRow() {
        val at = drive(FreeDriveRowCompletion(), rows(100.0), 100.0)
        // Within 12 m of the 100 m row end with >= 60 m driven — never mid-row.
        assertTrue("completed at $at", at != null && at >= 88.0 && at <= 90.0)
    }

    @Test fun shortRowCompletesAtHalfItsLengthOrNearTheEnd() {
        val at = drive(FreeDriveRowCompletion(), rows(30.0), 30.0)
        assertTrue("completed at $at", at != null && at <= 26.0)
    }

    @Test fun outsideTheCorridorNothingAccumulatesOrCompletes() {
        val tracker = FreeDriveRowCompletion()
        assertNull(drive(tracker, rows(100.0), 100.0, inCorridor = false))
        assertEquals(0.0, tracker.accumulated(1.5), 0.0)
        assertNull(tracker.stablePath)
    }

    @Test fun anAlreadyCompletedOrSkippedPathIsNeverCompletedAgain() =
        assertNull(drive(FreeDriveRowCompletion(), rows(100.0), 100.0, done = setOf(1.5)))

    @Test fun noRowGeometryFallsBackToTenMetres() {
        val at = drive(FreeDriveRowCompletion(), emptyList(), 60.0)
        assertTrue("completed at $at", at != null && at <= 14.0)
    }

    @Test fun multiBlockPathsMeasureTheBlocksOwnRows() {
        // Global path 11.5 in a block whose local rows start at 1 (offset 10): uses local rows 1-2 (100 m).
        val at = drive(FreeDriveRowCompletion(), rows(100.0), 100.0, path = 11.5, offset = 10)
        assertTrue("completed at $at", at != null && at >= 88.0)
    }

    @Test fun aSingleFixNeverClaimsARowAndSwitchingNeedsDwell() {
        val tracker = FreeDriveRowCompletion()
        val r = rows(100.0)
        tracker.observe(1.5, true, 1.0, 2.5, lat(2.0), lon(1.25), 0, r, 0, emptySet())
        assertNull("one sample is not a lock", tracker.stablePath)
        tracker.observe(1.5, true, 1.0, 2.5, lat(4.0), lon(1.25), 1_000, r, 0, emptySet())
        assertEquals(1.5, tracker.stablePath!!, 0.0)
        // A brief excursion to the next aisle doesn't switch until it dominates and dwells.
        tracker.observe(2.5, true, 1.0, 2.5, lat(6.0), lon(3.75), 2_000, r, 0, emptySet())
        assertEquals(1.5, tracker.stablePath!!, 0.0)
        listOf(3_000L, 4_000L, 5_000L).forEachIndexed { i, t ->
            tracker.observe(2.5, true, 1.0, 2.5, lat(8.0 + 2 * i), lon(3.75), t, r, 0, emptySet())
        }
        assertEquals(2.5, tracker.stablePath!!, 0.0)
    }

    @Test fun gpsJumpsAreNotCountedAsDistance() {
        val tracker = FreeDriveRowCompletion()
        val r = rows(100.0)
        tracker.observe(1.5, true, 1.0, 2.5, lat(2.0), lon(1.25), 0, r, 0, emptySet())
        tracker.observe(1.5, true, 1.0, 2.5, lat(4.0), lon(1.25), 1_000, r, 0, emptySet())
        tracker.observe(1.5, true, 1.0, 2.5, lat(80.0), lon(1.25), 2_000, r, 0, emptySet())
        assertEquals("only the 2 m step counts; the 76 m jump is rejected", 2.0, tracker.accumulated(1.5), 0.05)
    }

    // --- Spray trip driven without a running tank ---

    private val spray = Trip(id = "t", vineyardId = "v", isActive = true, tripFunction = "spraying", totalTanks = 2)

    @Test fun warnsAfterTwentySecondsOfRowDrivingWithNoTank() {
        var r = SprayNoTankWarning.evaluate(spray, drivingRow = true, nowMs = 0, since = null)
        assertFalse(r.show)
        r = SprayNoTankWarning.evaluate(spray, drivingRow = false, nowMs = 10_000, since = r.since)
        assertFalse("a stop keeps the clock but doesn't warn early", r.show)
        r = SprayNoTankWarning.evaluate(spray, drivingRow = true, nowMs = 20_000, since = r.since)
        assertTrue(r.show)
    }

    @Test fun noWarningWithARunningTankOrOnNonSprayTrips() {
        val running = spray.copy(activeTankNumber = 1)
        assertFalse(SprayNoTankWarning.evaluate(running, true, 60_000, 0).show)
        assertNull(SprayNoTankWarning.evaluate(running, true, 60_000, 0).since)
        assertTrue("filling is not spraying",
            SprayNoTankWarning.evaluate(running.copy(isFillingTank = true), true, 60_000, 0).show)
        assertFalse(SprayNoTankWarning.evaluate(spray.copy(tripFunction = "mowing", totalTanks = null), true, 60_000, 0).show)
        assertFalse(SprayNoTankWarning.evaluate(spray.copy(isPaused = true), true, 60_000, 0).show)
    }
}
