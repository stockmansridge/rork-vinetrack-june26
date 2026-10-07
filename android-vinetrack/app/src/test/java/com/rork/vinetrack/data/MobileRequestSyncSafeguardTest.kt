package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class MobileRequestSyncSafeguardTest {
    @Test fun workerDeletionAndPickingFinancialRequestsAreOwnerManagerOnly() = runBlocking {
        for (role in listOf("owner", "manager", "supervisor", "operator", "admin", null)) {
            var deleteCalls = 0
            var financialCalls = 0
            val money = OwnerManagerRequestGate.financials(role) { financialCalls++; listOf(125.0) }
            try {
                OwnerManagerRequestGate.deleteWorkerType(role) { deleteCalls++ }
                assertTrue(role == "owner" || role == "manager")
            } catch (error: BackendError.Server) { assertEquals(403, error.code) }
            val allowed = role == "owner" || role == "manager"
            assertEquals(if (allowed) 1 else 0, deleteCalls)
            assertEquals(if (allowed) 1 else 0, financialCalls)
            assertEquals(if (allowed) listOf(125.0) else emptyList<Double>(), money)
        }
    }

    @Test fun roleCannotBeBorrowedFromAnotherVineyardOrUnknownScope() {
        val members = listOf(VineyardMember(vineyardId = "other", userId = "user", role = "owner"),
            VineyardMember(vineyardId = null, userId = "user", role = "manager"),
            VineyardMember(vineyardId = "current", userId = "user", role = "operator"))
        assertEquals("operator", OwnerManagerRequestGate.role(members, "current", "user"))
        assertNull(OwnerManagerRequestGate.role(members, "missing", "user"))
        assertNull(OwnerManagerRequestGate.role(members, "current", null))
    }

    @Test fun workerDeleteAbsentResultsConvergeButPermissionAndNetworkAreNotSuccess() {
        assertTrue(OwnerManagerRequestGate.isConvergedDelete(404, "Worker type not found"))
        assertTrue(OwnerManagerRequestGate.isConvergedDelete(400, "already deleted"))
        assertFalse(OwnerManagerRequestGate.isConvergedDelete(403, "Owner or manager role required"))
        assertFalse(OwnerManagerRequestGate.isConvergedDelete(503, "unavailable"))
    }

    @Test fun growthWaitsForPendingInflightFailedAndBlockedPinWithoutConsumingAttempts() = runBlocking {
        for (status in PendingWriteStatus.unresolved) {
            val pending = PendingWriteRepository(InMemoryPendingWriteStore())
            val parent = pending.enqueue(PendingEntityType.PIN, PendingOpType.CREATE, "{}", "pin")
            pending.updateStatus(parent.id, status)
            var posts = 0
            val sync = GrowthRecordCreateSync(pending, { posts++; GrowthStageRecord(it.id, it.vineyardId, pinId = it.pinId) }, { _, _ -> true })
            val child = sync.enqueue(GrowthStageRecord("record", "vineyard", pinId = "pin", stageCode = "EL-4"), "2026-10-07T00:00:00Z")
            repeat(10) { sync.replayAll {} }
            assertEquals(0, posts)
            assertEquals(0, pending.list().first { it.id == child.id }.attemptCount)
            assertEquals(child.payloadJson, pending.list().first { it.id == child.id }.payloadJson)
        }
    }

    @Test fun parentOutboxRemovalAloneIsNotAcknowledgementAndRestartPreservesExactLink() = runBlocking {
        val disk = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(disk)
        var acknowledged = false
        val posted = mutableListOf<GrowthRecordCreateSync.Payload>()
        val sync = GrowthRecordCreateSync(pending, { posted += it; GrowthStageRecord(it.id, it.vineyardId, pinId = it.pinId) }, { pin, vineyard ->
            assertEquals("pin", pin); assertEquals("vineyard", vineyard); acknowledged
        })
        val child = sync.enqueue(GrowthStageRecord("record", "vineyard", pinId = "pin", stageCode = "EL-4"), "2026-10-07T00:00:00Z")
        sync.replayAll {}
        assertTrue(posted.isEmpty())
        assertEquals(0, pending.list().single().attemptCount)
        val restarted = PendingWriteRepository(disk)
        assertEquals(child.payloadJson, restarted.list().single().payloadJson)
        acknowledged = true
        GrowthRecordCreateSync(restarted, { posted += it; GrowthStageRecord(it.id, it.vineyardId, pinId = it.pinId) }, { _, _ -> acknowledged }).replayAll {}
        assertEquals("pin", posted.single().pinId)
        assertEquals("record", posted.single().id)
        assertTrue(restarted.list().isEmpty())
    }

    @Test fun unlinkedLegacyGrowthProceedsWithoutPinRead() = runBlocking {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        var posts = 0
        val sync = GrowthRecordCreateSync(pending, { posts++; GrowthStageRecord(it.id, it.vineyardId) }, { _, _ -> error("Legacy record looked up a Pin") })
        sync.enqueue(GrowthStageRecord("legacy", "vineyard", stageCode = "EL-9"), "2026-10-07T00:00:00Z")
        sync.replayAll {}
        assertEquals(1, posts)
        assertTrue(pending.list().isEmpty())
    }

    @Test fun failedPinAcknowledgementReadLeavesGrowthRetryableAndUnchanged() = runBlocking {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        val sync = GrowthRecordCreateSync(pending, { error("Unexpected Growth POST") }, { _, _ -> throw java.io.IOException("offline") })
        val child = sync.enqueue(GrowthStageRecord("record", "vineyard", pinId = "pin"), "2026-10-07T00:00:00Z")
        sync.replayAll {}
        assertEquals(child.payloadJson, pending.list().single().payloadJson)
        assertEquals(PendingWriteStatus.PENDING, pending.list().single().status)
        assertEquals(0, pending.list().single().attemptCount)
    }
}
