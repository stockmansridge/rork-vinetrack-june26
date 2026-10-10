package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

/** Synthetic host-only decode investigation, not physical startup or heap profiling. */
class CacheHydrationSizingTest {
    @Test fun sequentialFiveDatasetDecodeWithHistoricalRoutes() {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val pins = (0 until 5000).map { Pin(id = "pin-$it", vineyardId = "A", notes = "x".repeat(512)) }
        val route = (0 until 2000).map { CoordinatePoint(-34.0 + it * 0.000001, 138.0) }
        val trips = (0 until 200).map { Trip(id = "trip-$it", vineyardId = "A", pathPoints = route, isActive = false) }
        val sprays = (0 until 1000).map { SprayRecord(id = "spray-$it", vineyardId = "A", notes = "x".repeat(512)) }
        val tasks = (0 until 2000).map { WorkTask(id = "task-$it", vineyardId = "A", notes = "x".repeat(512)) }
        val growth = (0 until 5000).map { GrowthStageRecord(id = "growth-$it", vineyardId = "A", notes = "x".repeat(512)) }
        val rawPins = json.encodeToString(ListSerializer(Pin.serializer()), pins)
        val rawTrips = json.encodeToString(ListSerializer(Trip.serializer()), trips)
        val rawSprays = json.encodeToString(ListSerializer(SprayRecord.serializer()), sprays)
        val rawTasks = json.encodeToString(ListSerializer(WorkTask.serializer()), tasks)
        val rawGrowth = json.encodeToString(ListSerializer(GrowthStageRecord.serializer()), growth)
        val bytes = listOf(rawPins, rawTrips, rawSprays, rawTasks, rawGrowth).sumOf { it.toByteArray().size }
        repeat(3) { run ->
            val start = System.nanoTime()
            assertEquals(5000, json.decodeFromString(ListSerializer(Pin.serializer()), rawPins).size)
            assertEquals(200, json.decodeFromString(ListSerializer(Trip.serializer()), rawTrips).size)
            assertEquals(1000, json.decodeFromString(ListSerializer(SprayRecord.serializer()), rawSprays).size)
            assertEquals(2000, json.decodeFromString(ListSerializer(WorkTask.serializer()), rawTasks).size)
            assertEquals(5000, json.decodeFromString(ListSerializer(GrowthStageRecord.serializer()), rawGrowth).size)
            println("SYNTHETIC_HYDRATION run=$run records=13200 routePoints=400000 bytes=$bytes elapsedMs=${(System.nanoTime() - start) / 1_000_000.0} hostOnly=true diskAndOverlayExcluded=true")
        }
    }
}
