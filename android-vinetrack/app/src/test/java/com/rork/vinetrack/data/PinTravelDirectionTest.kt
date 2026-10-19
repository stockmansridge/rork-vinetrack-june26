package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

class PinTravelDirectionTest {
    private fun fix(
        i: Int, latitude: Double = -33.0 + i * 0.00003,
        bearing: Double? = 0.0, speed: Double? = 2.0, accuracy: Double = 2.0,
    ) = QualifiedLocationFix(
        latitude = latitude, longitude = 149.0,
        accuracyMetres = accuracy,
        fixTimeEpochMs = 1_000L + i * 1_000L,
        fixElapsedRealtimeNanos = 1_000_000_000L + i * 1_000_000_000L,
        bearingDegrees = bearing,
        speedMetresPerSecond = speed,
    )

    @Test fun forwardMovementUsesDirectionOfTravel() {
        val path = (0..3).map { fix(it) }
        val course = PinTravelDirection.fromObservations(path.last(), path.dropLast(1))
        assertNotNull(course)
        assertEquals(0.0, course!!.degrees, 0.01)
    }

    @Test fun stationaryOrCrawlingNeverInventsDirection() {
        val still = (0..3).map { fix(it, latitude = -33.0) }
        assertNull(PinTravelDirection.fromObservations(still.last(), still.dropLast(1)))
        val slow = (0..3).map { fix(it, speed = 0.2) }
        assertNull(PinTravelDirection.fromObservations(slow.last(), slow.dropLast(1)))
    }

    @Test fun reversalAndWideAccuracyAreRejected() {
        val reversal = listOf(fix(0), fix(1), fix(2, bearing = 180.0), fix(3))
        assertNull(PinTravelDirection.fromObservations(reversal.last(), reversal.dropLast(1)))
        val poor = (0..3).map { fix(it, accuracy = 8.0) }
        assertNull(PinTravelDirection.fromObservations(poor.last(), poor.dropLast(1)))
    }

    @Test fun duplicateOrStaleSamplesAreRejected() {
        val last = fix(3)
        assertNull(PinTravelDirection.fromObservations(last, listOf(last, last)))
        assertNull(PinTravelDirection.fromObservations(last, listOf(fix(-50),fix(-49))))
    }
}
