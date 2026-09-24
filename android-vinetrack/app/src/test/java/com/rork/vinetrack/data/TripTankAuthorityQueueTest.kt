package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TripTankAuthorityQueueTest {
    private class MemorySnapshot : ActiveTripSnapshotStorage {
        var bytes: String? = null
        override fun read(): String? = bytes
        override fun write(value: String) { bytes = value }
        override fun remove() { bytes = null }
    }

    @Test
    fun completedServerBlocksOldTankReplayWithoutRetryAndDoesNotHoldNewTrip() = runBlocking {
        val outbox = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(outbox)
        val snapshots = MemorySnapshot()
        val active = ActiveTripStore(snapshots)
        val route = listOf(CoordinatePoint(latitude = -41.0, longitude = 174.0))
        val tank = TankSession(id = "tank-old", tankNumber = 1, startTime = "2026-09-23T10:00:00Z")
        val old = Trip(id = "trip-old", vineyardId = "vineyard", isActive = true,
            pathPoints = route, totalDistance = 100.0, paddockIds = listOf("block-a"),
            completedPaths = listOf(0.5), skippedPaths = listOf(1.5), tankSessions = listOf(tank))
        assertTrue(active.claimIfAvailable("user", "vineyard", old))
        var fetchedOld = 0
        val patches = mutableListOf<String>()
        val completed = old.copy(isActive = false, endTime = "2026-09-23T11:00:00Z")
        val server = mutableMapOf("trip-old" to completed)
        val coordinator = TripTankSync(
            tripRepo = null, pending = pending, activeTripStore = active,
            fetchTrip = { id -> if (id == old.id) fetchedOld++; server[id] },
            saveTankSessions = { id, sessions, number, filling, fillNumber ->
                patches += id
                server.getValue(id).copy(tankSessions = sessions, activeTankNumber = number,
                    isFillingTank = filling, fillingTankNumber = fillNumber).also { server[id] = it }
            },
        )
        val originalMarker = coordinator.enqueue(old)
        assertEquals(PendingWriteStatus.PENDING, pending.list().single().status)
        coordinator.replayAll { error("Completed trip must not receive tank callback") }
        val blocked = PendingWriteRepository(outbox).list().single()
        assertEquals(originalMarker.id, blocked.id)
        assertEquals(PendingWriteStatus.BLOCKED, blocked.status)
        assertEquals(0, blocked.attemptCount)
        assertEquals(0, pending.retryEligibleCount())
        assertEquals(0, pending.resetFailedForRetry())
        assertFalse(pending.resetFailedRowForRetry(blocked.id))
        assertEquals(1, pending.currentPendingCount()) // visible until a fresh completion pull removes it
        coordinator.replayAll { error("Blocked marker must not replay") }
        assertEquals(1, fetchedOld)
        assertTrue(patches.isEmpty())
        assertEquals(completed, server[old.id])

        // A fresh authoritative completion is applied by AppViewModel.restoreActiveTrip:
        // it persists the completed snapshot and removes same-trip trip_ markers.
        // Exercise the real persistence/queue stores here; the ViewModel's private
        // reconciliation branch is separately traced, not invoked by this JVM test.
        active.save("user", "vineyard", completed)
        pending.list().filter { it.clientId == old.id && it.entityType.startsWith("trip_") }
            .forEach { pending.remove(it.id) }
        assertNull(PendingWriteRepository(outbox).list().singleOrNull())
        assertEquals(0, pending.currentPendingCount())
        assertFalse(active.hasActiveClaim())
        assertEquals(route, active.load()?.trip?.pathPoints)
        assertEquals(old.tankSessions, active.load()?.trip?.tankSessions)
        assertEquals(old.totalDistance, active.load()?.trip?.totalDistance)
        assertEquals(old.completedPaths, active.load()?.trip?.completedPaths)
        assertEquals(old.skippedPaths, active.load()?.trip?.skippedPaths)
        assertEquals(old.paddockIds, active.load()?.trip?.paddockIds)

        val nextTank = TankSession(id = "tank-next", tankNumber = 1, startTime = "2026-09-24T10:00:00Z")
        val next = Trip(id = "trip-next", vineyardId = "vineyard", isActive = true,
            tankSessions = listOf(nextTank), activeTankNumber = 1)
        assertTrue(active.claimIfAvailable("user", "vineyard", next))
        server[next.id] = next.copy(tankSessions = emptyList(), activeTankNumber = null)
        coordinator.enqueue(next)
        val synced = mutableListOf<Trip>()
        coordinator.replayAll { synced += it }
        assertEquals(listOf(next.id), patches)
        assertEquals(listOf(next.id), synced.map { it.id })
        assertEquals(listOf(nextTank), server[next.id]?.tankSessions)
        assertTrue(PendingWriteRepository(outbox).list().isEmpty())
        coordinator.replayAll { error("No marker remains to replay") }
        assertEquals(listOf(next.id), patches)
        assertEquals(PendingEntityType.TRIP_TANK, originalMarker.entityType)
    }
}
