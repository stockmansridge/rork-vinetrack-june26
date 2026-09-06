package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TripEngineHourCaptureTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun trip(startHours: Double?, endHours: Double?): Trip = Trip(
        id = "trip",
        vineyardId = "vineyard",
        startTime = "2026-09-06T00:00:00Z",
        endTime = "2026-09-06T03:10:34Z",
        pauseTimestamps = listOf("2026-09-06T01:00:00Z"),
        resumeTimestamps = listOf("2026-09-06T01:10:00Z"),
        machineId = "machine",
        startEngineHours = startHours,
        endEngineHours = endHours,
    )

    private fun estimate(startHours: Double?, endHours: Double?): TripFuelEstimator.Estimate =
        TripFuelEstimator.estimate(
            trip(startHours, endHours),
            machines = listOf(VineyardMachine(id = "machine", vineyardId = "vineyard", name = "Spray tractor", fuelUsageLPerHour = 6.8)),
            fuelPurchases = listOf(FuelPurchase(id = "fuel", vineyardId = "vineyard", volumeLitres = 100.0, totalCost = 152.8)),
        )

    @Test
    fun `incomplete equal and reversed readings use pause-aware duration`() {
        listOf(null to 103.0, 100.0 to null, null to null, 100.0 to 100.0, 101.0 to 100.0).forEach { (start, end) ->
            val estimate = estimate(start, end)
            assertEquals(TripFuelEstimator.FuelBasis.Duration, estimate.basis)
            assertEquals(3.0094, estimate.fuelHours, 0.0002)
            assertEquals(20.465, estimate.litres ?: 0.0, 0.002)
            assertEquals(31.28, estimate.fuelCost ?: 0.0, 0.02)
        }
    }

    @Test
    fun `valid pair uses engine-hour delta`() {
        val estimate = estimate(100.0, 102.5)
        assertEquals(TripFuelEstimator.FuelBasis.EngineHours, estimate.basis)
        assertEquals(2.5, estimate.fuelHours, 0.0)
    }

    @Test
    fun `end field visibility follows start reading`() {
        assertFalse(trip(null, null).shouldCaptureEndEngineHours)
        assertTrue(trip(100.0, null).shouldCaptureEndEngineHours)
    }

    @Test
    fun `saved activation and offline replay retain start reading`() {
        val saved = trip(null, null).copy(isActive = false, endTime = null, pauseTimestamps = emptyList(), resumeTimestamps = emptyList())
        val activated = SavedTripActivation.activate(saved, "2026-09-06T12:00:00Z", 812.4)!!
        assertEquals(812.4, activated.startEngineHours ?: 0.0, 0.0)
        assertNull(activated.endEngineHours)
        assertNull(saved.startEngineHours)

        val store = InMemoryPendingWriteStore()
        TripStartSync(PendingWriteRepository(store)).enqueueActivation(activated)
        val payload = json.decodeFromString(TripStartSync.Payload.serializer(), PendingWriteRepository(store).list().single().payloadJson)
        assertEquals(812.4, payload.startEngineHours ?: 0.0, 0.0)
    }
}
