package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ActiveTripReconciliationTest {
    @Test
    fun longerFiveThousandPointLocalPathWinsOverStaleTwoThousandPointServerPath() {
        val localPath = makeRoute(5_000)
        val serverPath = localPath.take(2_000)
        val local = activeTrip(path = localPath, distance = 42_750.25)
        val server = activeTrip(path = serverPath, distance = 17_100.10)

        val reconciled = ActiveTripReconciliation.mergeProgress(server, local)

        assertEquals(local.id, reconciled.id)
        assertTrue(reconciled.isActive)
        assertEquals(localPath, reconciled.pathPoints)
        assertEquals(5_000, reconciled.pathPoints.orEmpty().size)
        assertEquals(local.totalDistance, reconciled.totalDistance)
    }

    @Test
    fun longerSixThousandPointServerPathIsNotTruncatedByLocalSnapshot() {
        val localPath = makeRoute(5_000)
        val serverPath = makeRoute(6_000)
        val local = activeTrip(path = localPath, distance = 42_750.25)
        val server = activeTrip(path = serverPath, distance = 51_300.30)

        val reconciled = ActiveTripReconciliation.mergeProgress(server, local)

        assertEquals(serverPath, reconciled.pathPoints)
        assertEquals(6_000, reconciled.pathPoints.orEmpty().size)
        assertEquals(server.totalDistance, reconciled.totalDistance)
    }

    private fun activeTrip(path: List<CoordinatePoint>, distance: Double): Trip = Trip(
        id = "active-trip",
        vineyardId = "vineyard-1",
        isActive = true,
        totalDistance = distance,
        pathPoints = path,
    )

    private fun makeRoute(count: Int): List<CoordinatePoint> = List(count) { index ->
        CoordinatePoint(
            latitude = -33.0 + index * 0.000_001,
            longitude = 149.0 + index * 0.000_002,
        )
    }
}
