package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TripPathDisplayProcessorTest {
    private val displayCap = 500

    @Test
    fun generatedRoutesFollowCompleteRouteDisplayContract() {
        listOf(100, 2_000, 5_000, 20_000).forEach { count ->
            val source = makeRoute(count)
            val original = source.toList()
            val displayed = TripPathDisplayProcessor.displayPoints(source, displayCap)
            println("route-display full=$count displayed=${displayed.size}")

            if (count <= displayCap) {
                assertEquals("Routes below the cap must remain complete", source, displayed)
            } else {
                assertTrue(displayed.size <= displayCap)
            }
            assertEquals(source.first(), displayed.first())
            assertEquals(source.last(), displayed.last())
            assertTrue(containsProgress(0.25, displayed))
            assertTrue(containsProgress(0.50, displayed))
            assertTrue(containsProgress(0.75, displayed))
            assertEquals(source.minOf { it.latitude }, displayed.minOf { it.latitude }, 0.0)
            assertEquals(source.maxOf { it.latitude }, displayed.maxOf { it.latitude }, 0.0)
            assertEquals(source.minOf { it.longitude }, displayed.minOf { it.longitude }, 0.0)
            assertEquals(source.maxOf { it.longitude }, displayed.maxOf { it.longitude }, 0.0)
            assertEquals("Display processing must not mutate persisted path points", original, source)
        }
    }

    @Test
    fun twentyThousandPointRouteRepresentsBeginningMiddleAndEnd() {
        val source = makeRoute(20_000)
        val displayed = TripPathDisplayProcessor.displayPoints(source, displayCap)

        assertEquals(source.first(), displayed.first())
        assertTrue(displayed.any { it.longitude < 149.02 })
        assertTrue(displayed.any { it.longitude > 149.09 && it.longitude < 149.11 })
        assertTrue(displayed.any { it.longitude > 149.18 })
    }

    private fun makeRoute(count: Int): List<CoordinatePoint> = List(count) { index ->
        val progress = index.toDouble() / (count - 1).toDouble()
        var latitude = -33.0 + sin(progress * PI * 8.0) * 0.01
        if (index == count / 3) latitude = -33.03
        if (index == count * 2 / 3) latitude = -32.97
        CoordinatePoint(
            latitude = latitude,
            longitude = 149.0 + progress * 0.2,
        )
    }

    private fun containsProgress(progress: Double, points: List<CoordinatePoint>): Boolean {
        val expectedLongitude = 149.0 + progress * 0.2
        return points.any { abs(it.longitude - expectedLongitude) < 0.01 }
    }
}
