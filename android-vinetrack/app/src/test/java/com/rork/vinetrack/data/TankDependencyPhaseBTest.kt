package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.AuthRetentionGuard
import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** P0 3.1.9 Phase B: TRIP_TANK marker and Tank actual dependency verification. */
class TankDependencyPhaseBTest {
    private val server = Trip("trip", "vineyard-A", isActive = true)
    private val session = TankSession("session-1", 1, startTime = "2026-11-02T00:00:00Z")
    private val local = server.copy(tankSessions = listOf(session), activeTankNumber = 1)
    private val chem = SprayTankActualChemical("c1", name = "Copper", actualAmountBase = 2.5, unit = "Kg")
    private val actual = SprayTankActual("actual", "vineyard-A", "spray", "trip", "session-1", 1,
        waterVolumeL = 400.0, chemicals = listOf(chem), confirmedAt = "2026-11-02T00:00:00Z", confirmedBy = "A")

    private fun activeStore(trip: Trip): ActiveTripStore {
        var snapshot: String? = null
        val store = ActiveTripStore(object : ActiveTripSnapshotStorage {
            override fun read() = snapshot
            override fun write(value: String) { snapshot = value }
            override fun remove() { snapshot = null }
        })
        store.save("A", "vineyard-A", trip)
        return store
    }

    private fun queue() = PendingWriteRepository(InMemoryPendingWriteStore()).also {
        it.configureReplayScope { PendingWriteRepository.ReplayScope("A", 1) }
    }

    @Test(timeout = 10000) fun markerHeldWhenRequiredSessionExistsNowhere() = runBlocking {
        // Incident shape: server ACTIVE with no sessions; local snapshot lost its session; actual references it.
        val lost = server.copy(activeTankNumber = null)
        val q = queue()
        val sync = TripTankSync(null, q, activeStore(lost), { server }, { _, _, _, _, _ -> fail("Patched"); server },
            requiredSessionIds = { setOf("session-1") })
        val original = sync.enqueue(lost)
        sync.replayAll { fail("Acknowledged") }
        val held = q.list().single()
        assertEquals(original.id, held.id)
        assertEquals(PendingWriteStatus.BLOCKED, held.status)
        assertTrue(held.lastError!!.startsWith(TankDependencyVerification.REQUIRED_SESSION_MISSING))
        assertEquals(0, held.attemptCount)
    }

    @Test(timeout = 10000) fun unreadableRequiredSessionsHoldMarkerWithoutNetwork() = runBlocking {
        val q = queue()
        var probes = 0
        val sync = TripTankSync(null, q, activeStore(local), { probes++; server }, { _, _, _, _, _ -> fail("Patched"); local },
            requiredSessionIds = { null })
        sync.enqueue(local)
        sync.replayAll { fail("Acknowledged") }
        val held = q.list().single()
        assertEquals(PendingWriteStatus.FAILED, held.status)
        assertTrue(held.lastError!!.startsWith(TankDependencyVerification.REQUIRED_SESSIONS_UNREADABLE))
    }

    @Test(timeout = 10000) fun patchResponseMissingSessionKeepsMarker() = runBlocking {
        val q = queue()
        val sync = TripTankSync(null, q, activeStore(local), { server }, { _, _, _, _, _ -> server },
            requiredSessionIds = { setOf("session-1") })
        sync.enqueue(local)
        sync.replayAll { fail("Acknowledged without readback") }
        val held = q.list().single()
        assertEquals(PendingWriteStatus.FAILED, held.status)
        assertTrue(held.lastError!!.startsWith(TankDependencyVerification.PATCH_READBACK_MISMATCH))
    }

    @Test(timeout = 10000) fun verifiedPatchRemovesMarker() = runBlocking {
        val q = queue()
        var published = 0
        TripTankSync(null, q, activeStore(local), { server }, { _, sessions, _, _, _ -> server.copy(tankSessions = sessions) },
            requiredSessionIds = { setOf("session-1") }).also { it.enqueue(local) }.replayAll { published++ }
        assertEquals(1, published)
        assertTrue(q.list().isEmpty())
    }

    @Test(timeout = 10000) fun noChangeMarkerAcknowledgedOnlyWhenServerHasSession() = runBlocking {
        val q = queue()
        TripTankSync(null, q, activeStore(local), { local }, { _, _, _, _, _ -> fail("Patched"); local },
            requiredSessionIds = { setOf("session-1") }).also { it.enqueue(local) }.replayAll { }
        assertTrue(q.list().isEmpty())
    }

    private fun actualStore(): Pair<SprayTankActualStore, AuthRetentionGuard.AccountAccess> {
        var bytes: String? = null
        val store = SprayTankActualStore({ bytes }, { bytes = it; true })
        val access = requireNotNull(AuthRetentionGuard({ false }, { true }).captureAccount("A"))
        store.configureAccountAccess { access }
        assertTrue(store.save(actual))
        return store to access
    }

    @Test(timeout = 10000) fun actualHeldWhileServerSessionMissing() = runBlocking {
        val (store, access) = actualStore()
        val guard = AuthRetentionGuard({ false }, { true })
        val sync = ScopedTankActualSync(store, { _, action -> action(); true }, { _, _ -> fail("Uploaded without session") },
            { _, _ -> emptyList() }, serverSessionIds = { _, _ -> emptySet() }, readBack = { _, _ -> actual })
        sync.replay(access, null, { false }, { true })
        assertEquals(listOf(actual), store.pending())
        assertEquals(TankDependencyVerification.ACTUAL_SESSION_NOT_ON_SERVER, sync.lastHoldCodes["actual"])
        assertNotNull(guard)
    }

    @Test(timeout = 10000) fun actualHeldWhenServerTripUnknown() = runBlocking {
        val (store, access) = actualStore()
        ScopedTankActualSync(store, { _, action -> action(); true }, { _, _ -> fail("Uploaded") },
            { _, _ -> emptyList() }, serverSessionIds = { _, _ -> null })
            .replay(access, null, { false }, { true })
        assertEquals(listOf(actual), store.pending())
    }

    @Test(timeout = 10000) fun actualNotSyncedWhenReadbackAbsentOrDifferent() = runBlocking {
        for (row in listOf(null, actual.copy(waterVolumeL = 399.0),
            actual.copy(chemicals = listOf(chem.copy(actualAmountBase = 2.0))),
            actual.copy(tankSessionId = "other"), actual.copy(chemicals = emptyList()))) {
            val (store, access) = actualStore()
            var uploads = 0
            val sync = ScopedTankActualSync(store, { _, action -> action(); true }, { _, _ -> uploads++ },
                { _, _ -> emptyList() }, serverSessionIds = { _, _ -> setOf("session-1") }, readBack = { _, _ -> row })
            sync.replay(access, null, { false }, { true })
            assertEquals(1, uploads)
            assertEquals(listOf(actual), store.pending())
            assertEquals(400.0, store.pending().single().waterVolumeL!!, 0.0)
            assertEquals(TankDependencyVerification.ACTUAL_READBACK_MISMATCH, sync.lastHoldCodes["actual"])
        }
    }

    @Test(timeout = 10000) fun actualSyncedAfterExactReadback() = runBlocking {
        val (store, access) = actualStore()
        ScopedTankActualSync(store, { _, action -> action(); true }, { _, _ -> },
            { _, _ -> emptyList() }, serverSessionIds = { _, _ -> setOf("session-1") }, readBack = { _, _ -> actual })
            .replay(access, null, { false }, { true })
        assertTrue(store.pending().isEmpty())
        assertEquals(listOf(actual), store.load())
    }

    @Test fun holdCodesCarryNoQuantities() {
        for (code in listOf(TankDependencyVerification.REQUIRED_SESSION_MISSING, TankDependencyVerification.ACTUAL_READBACK_MISMATCH)) {
            assertFalse(code.any { it.isDigit() })
        }
    }

    // Issue #43 RED: quantity-only equality is not an acknowledgement of original chemical identity.
    @Test fun issue43ActualAckRejectsSameAmountsWithDifferentLinkage() {
        val wrongServer = actual.copy(chemicals = listOf(chem.copy(
            plannedChemicalId = "wrong-planned-id",
            savedChemicalId = "wrong-saved-id",
            usageKind = "substitution",
        )))
        assertFalse("Matching amounts do not prove linkage", TankDependencyVerification.actualMatches(actual, wrongServer))
    }

    // Issue #43 RED: a changed evidence snapshot must not be acknowledged as exact readback.
    @Test fun issue43ActualAckRejectsSameAmountsWithDifferentProvenance() {
        val expected = actual.copy(chemicals = listOf(chem.copy(productCategory = "Herbicide", snapshotAt = "2026-11-02T01:00:00Z")))
        val serverRow = expected.copy(chemicals = listOf(expected.chemicals.single().copy(snapshotAt = "2026-11-02T02:00:00Z")))
        assertFalse("Snapshot provenance is part of acknowledged evidence", TankDependencyVerification.actualMatches(expected, serverRow))
    }


}
