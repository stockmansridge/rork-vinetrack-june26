package com.rork.vinetrack.ui

import com.rork.vinetrack.data.ActiveTripSnapshotStorage
import com.rork.vinetrack.data.ActiveTripStore
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceTripOwnershipTest {
    private val a = Trip(id = "A", vineyardId = "vineyard-1", isActive = true)
    private val b = Trip(id = "B", vineyardId = "vineyard-1", isActive = true)
    private val c = Trip(id = "C", vineyardId = "vineyard-1", isActive = true)

    @Test fun twoServerActiveTripsSelectOnlyStoredDeviceUUIDAfterRelaunch() {
        val storage = MemoryStorage()
        assertTrue(ActiveTripStore(storage).saveDurably("operator", "vineyard-1", b))
        val restored = ActiveTripStore(storage).load()!!
        val state = AppUiState(selectedVineyardId = "vineyard-1", trips = listOf(a, b),
            deviceActiveTripId = restored.trip.id)
        assertEquals("B", state.activeTrip?.id)
        assertTrue(state.trips.first { it.id == "A" }.isActive)
        assertEquals("B", state.activeTrip?.id) // GPS, Pin, row, route and End read this identity.
    }

    @Test fun syncAddsOtherActiveTripsWithoutChangingDeviceOwnership() {
        val state = AppUiState(selectedVineyardId = "vineyard-1", trips = listOf(a), deviceActiveTripId = "A")
        assertEquals("A", state.copy(trips = listOf(b, c, a)).activeTrip?.id)
        val ended = state.copy(trips = listOf(a, b, c), deviceActiveTripId = "B")
            .copy(trips = listOf(a, b.copy(isActive = false), c), deviceActiveTripId = null)
        assertNull(ended.activeTrip)
        assertTrue(ended.trips.first { it.id == "A" }.isActive)
        assertTrue(ended.trips.first { it.id == "C" }.isActive)
    }

    @Test fun remoteActiveDoesNotBecomeLocalAndVineyardSwitchKeepsOwnerSnapshot() {
        val storage = MemoryStorage()
        val device = ActiveTripStore(storage)
        val remoteOnly = AppUiState(selectedVineyardId = "vineyard-1", trips = listOf(a))
        assertNull(remoteOnly.activeTrip) // A does not block a new local Trip B.
        assertTrue(device.saveDurably("operator", "vineyard-1", b))
        val switched = AppUiState(selectedVineyardId = "vineyard-2", trips = listOf(
            Trip(id = "D", vineyardId = "vineyard-2", isActive = true)), deviceActiveTripId = "B")
        assertNull(switched.activeTrip)
        assertEquals("B", ActiveTripStore(storage).load()?.trip?.id)
        assertEquals("vineyard-1", ActiveTripStore(storage).load()?.vineyardId)
        assertFalse(switched.trips.any { it.id == "B" })
    }

    @Test fun secondSignedInUserCannotReplaceDeviceClaimAndOriginalOwnerCanRestoreIt() {
        val storage = MemoryStorage()
        val firstSession = ActiveTripStore(storage)
        assertTrue(firstSession.claimIfAvailable("operator-A", "vineyard-1", a))
        val secondSession = ActiveTripStore(storage)
        assertTrue(secondSession.hasActiveClaim())
        assertFalse(secondSession.claimIfAvailable("operator-B", "vineyard-2",
            Trip(id = "other", vineyardId = "vineyard-2", isActive = true)))
        assertEquals("A", secondSession.load()?.trip?.id)
        assertEquals("operator-A", secondSession.load()?.ownerUserId)
        val originalSession = ActiveTripStore(storage).load()!!
        assertEquals("operator-A", originalSession.ownerUserId)
        assertEquals("A", AppUiState(selectedVineyardId = "vineyard-1", trips = listOf(originalSession.trip),
            deviceActiveTripId = originalSession.trip.id).activeTrip?.id)
    }

    @Test fun vineyardSwitchAndUnrelatedEndedTripDoNotReleaseDeviceClaim() {
        val storage = MemoryStorage()
        val store = ActiveTripStore(storage)
        assertTrue(store.claimIfAvailable("operator-A", "vineyard-1", a))
        val switched = AppUiState(selectedVineyardId = "vineyard-2",
            trips = listOf(b.copy(isActive = false)), deviceActiveTripId = "A")
        assertNull(switched.activeTrip)
        assertEquals("A", switched.deviceActiveTripId)
        assertTrue(store.hasActiveClaim())
        assertEquals("A", ActiveTripStore(storage).load()?.trip?.id)
    }

    private class MemoryStorage : ActiveTripSnapshotStorage {
        private var value: String? = null
        override fun read(): String? = value
        override fun write(value: String) { this.value = value }
        override fun remove() { value = null }
    }
}
