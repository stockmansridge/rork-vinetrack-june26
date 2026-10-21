package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import org.junit.Assert.*
import org.junit.Test

class PinTravelDirectionTest {
    private fun fix(i: Int, latitude: Double = -33.0 + i * 0.00003,
                    bearing: Double? = 0.0, speed: Double? = 2.0, accuracy: Double = 0.4) = QualifiedLocationFix(
        latitude = latitude, longitude = 149.00002, accuracyMetres = accuracy,
        fixTimeEpochMs = 1_000L + i * 1_000L,
        fixElapsedRealtimeNanos = 1_000_000_000L + i * 1_000_000_000L,
        bearingDegrees = bearing, speedMetresPerSecond = speed,
    )

    @Test fun forwardMovementUsesTravelNotPhoneOrientation() {
        val path = (0..3).map { fix(it) }
        val travel = PinTravelDirection.fromObservations(path.last(), path.dropLast(1))!!
        assertEquals(0.0, travel.degrees, 0.01)
        // Opposite diagnostic compass is not an input to qualification or row selection.
        val context = PinCaptureContext("pin", "vineyard", "trip", "2026-10-21T00:00:00Z",
            headingDegrees = travel.degrees, compassDegrees = 180.0)
        assertEquals(180.0, context.compassDegrees!!, 0.0)
        assertEquals(0.0, context.headingDegrees!!, 0.01)
        assertEquals(path.last().fixTimeEpochMs, travel.observedAtEpochMs)
    }

    @Test fun stationaryOrCrawlingNeverInventsDirection() {
        val still = (0..3).map { fix(it, latitude = -33.0) }
        assertNull(PinTravelDirection.fromObservations(still.last(), still.dropLast(1)))
        val slow = (0..3).map { fix(it, speed = 0.2) }
        assertNull(PinTravelDirection.fromObservations(slow.last(), slow.dropLast(1)))
        val short = (0..2).map { fix(it, latitude = -33.0 + it * 0.00001) }
        assertNull(PinTravelDirection.fromObservations(short.last(), short))
    }

    @Test fun reversalContradictoryDisplacementAndWideAccuracyAreRejected() {
        val reversal = listOf(fix(0), fix(1), fix(2, bearing = 180.0), fix(3))
        assertNull(PinTravelDirection.fromObservations(reversal.last(), reversal.dropLast(1)))
        val poor = (0..3).map { fix(it, accuracy = 8.0) }
        assertNull(PinTravelDirection.fromObservations(poor.last(), poor.dropLast(1)))
        val backwards = (0..3).map { fix(it, latitude = -33.0 - it * 0.00003) }
        assertNull(PinTravelDirection.fromObservations(backwards.last(), backwards))
    }

    @Test fun duplicateStaleMissingAndFutureSamplesAreRejected() {
        val last = fix(3)
        assertNull(PinTravelDirection.fromObservations(last, listOf(last, last)))
        assertNull(PinTravelDirection.fromObservations(last, listOf(fix(-50), fix(-49))))
        val path = (0..3).map { fix(it) }
        assertNull(PinTravelDirection.fromObservations(last, path, last.fixElapsedRealtimeNanos + 6_000_000_000L))
        assertNull(PinTravelDirection.fromObservations(last, listOf(fix(5), fix(6))))
        // The 15-second history window is measured at the tap, not the provider fix.
        val delayed = listOf(fix(0), fix(1), fix(15))
        assertNull(PinTravelDirection.fromObservations(delayed.last(), delayed,
            delayed.last().fixElapsedRealtimeNanos + 5_000_000_000L))
        val noCourse = path.map { it.copy(bearingDegrees = null) }
        assertNull(PinTravelDirection.fromObservations(noCourse.last(), noCourse))
        val repeatedWallTime = path.map { it.copy(fixTimeEpochMs = last.fixTimeEpochMs) }
        assertNull(PinTravelDirection.fromObservations(repeatedWallTime.last(), repeatedWallTime))
    }

    @Test fun northAndSouthTravelSwapPhysicalRowsForBothExplicitSides() {
        val block = Paddock(id = "block", vineyardId = "vineyard", name = "Rows",
            polygonPoints = listOf(CoordinatePoint(-33.001, 148.9998), CoordinatePoint(-33.001, 149.0006),
                CoordinatePoint(-32.999, 149.0006), CoordinatePoint(-32.999, 148.9998)),
            rows = (31..34).map { number ->
                val longitude = 149.0 + (number - 32) * 0.00004
                PaddockRow(number = number, startPoint = CoordinatePoint(-33.001, longitude),
                    endPoint = CoordinatePoint(-32.999, longitude))
            })
        for ((course, sign) in listOf(0.0 to 1.0, 180.0 to -1.0)) {
            val path = (0..3).map { fix(it, latitude = -33.0 + sign * (it - 3) * 0.00003, bearing = course) }
            val travel = PinTravelDirection.fromObservations(path.last(), path)!!
            for (side in listOf("Left", "Right")) {
                val placement = PinPlacement.resolveAutomatic(paddocks = listOf(block), selectedPaddockId = null,
                    latitude = path.last().latitude, longitude = path.last().longitude, side = side,
                    headingDegrees = travel.degrees, accuracyMetres = 0.4)
                val expected = if ((course == 0.0) == (side == "Left")) 32.0 else 33.0
                assertEquals(expected, placement.pinRowNumber!!, 0.0)
                assertEquals(32.5, placement.drivingRowNumber!!, 0.0)
                assertTrue(placement.snappedToRow)
                assertEquals(149.0 + (expected - 32) * 0.00004, placement.snappedLongitude!!, 1e-9)
                assertEquals(path.last().latitude, placement.latitude!!, 0.0)
                assertEquals(path.last().longitude, placement.longitude!!, 0.0)
            }
        }
    }
}
