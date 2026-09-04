package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ActiveTripStoreTest {
    @Test
    fun fiveThousandPointActiveTripSurvivesStoreRecreationWithoutDisplayMutation() {
        val storage = MemorySnapshotStorage()
        val source = makeRoute(5_000)
        val trip = Trip(
            id = "trip-5000",
            vineyardId = "vineyard-1",
            isActive = true,
            totalDistance = 42_750.25,
            pathPoints = source,
        )
        ActiveTripStore(storage).save("user-1", "vineyard-1", trip)

        val restored = ActiveTripStore(storage).load()
        assertNotNull(restored)
        val restoredTrip = requireNotNull(restored).trip
        assertEquals("trip-5000", restoredTrip.id)
        assertTrue(restoredTrip.isActive)
        assertEquals(42_750.25, requireNotNull(restoredTrip.totalDistance), 0.000_001)
        assertEquals(5_000, restoredTrip.pathPoints.orEmpty().size)
        assertEquals(source.first(), restoredTrip.pathPoints.orEmpty().first())
        assertEquals(source[2_500], restoredTrip.pathPoints.orEmpty()[2_500])
        assertEquals(source.last(), restoredTrip.pathPoints.orEmpty().last())

        val beforeDisplay = restoredTrip.pathPoints.orEmpty().toList()
        val displayed = TripPathDisplayProcessor.displayPoints(restoredTrip.pathPoints.orEmpty())
        assertTrue(displayed.size <= 500)
        assertEquals(beforeDisplay, restoredTrip.pathPoints)
        assertEquals(5_000, ActiveTripStore(storage).load()?.trip?.pathPoints.orEmpty().size)
    }

    private fun makeRoute(count: Int): List<CoordinatePoint> = List(count) { index ->
        CoordinatePoint(
            latitude = -33.0 + index * 0.000_001,
            longitude = 149.0 + index * 0.000_002,
        )
    }

    private class MemorySnapshotStorage : ActiveTripSnapshotStorage {
        private var value: String? = null

        override fun read(): String? = value

        override fun write(value: String) {
            this.value = value
        }

        override fun remove() {
            value = null
        }
    }
}
