package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import org.junit.Assert.*
import org.junit.Test
import org.junit.Before
import org.junit.After

class MaintenanceForegroundQueueTest {
    private var previousAuthority: VineyardWriteAuthority? = null
    @Before fun isolateAuthority() { previousAuthority = OperationalWrites.authority; OperationalWrites.authority = null }
    @After fun restoreAuthority() { OperationalWrites.authority = previousAuthority }
    private val a = "11111111-1111-4111-8111-111111111111"
    private val b = "22222222-2222-4222-8222-222222222222"
    private fun original(status: String = PendingWriteStatus.PENDING, attempts: Int = 0) = PendingWrite(
        id = "original-operation", entityType = PendingEntityType.MAINTENANCE_LOG, opType = PendingOpType.CREATE,
        clientId = "original-log", payloadJson = "{\"vineyardId\":\"$a\",\"itemName\":\"Original\"}",
        createdAt = 12345, updatedAt = 23456, attemptCount = attempts, lastError = "Original error", status = status)

    @Test fun interruptedMaintenanceClaimRetainsOriginalIdentityAndPayloadAfterRecreation() {
        val original = original().copy(lastError = null)
        val disk = InMemoryPendingWriteStore(listOf(original))
        val queue = PendingWriteRepository(disk)
        val claim = requireNotNull(queue.claimReplay(original))
        assertNull(queue.claimReplay(original))
        assertEquals(claim, disk.load().single())
        val restored = PendingWriteRepository(disk).list().single()
        assertEquals(original.id, restored.id)
        assertEquals(original.clientId, restored.clientId)
        assertEquals(original.payloadJson, restored.payloadJson)
        assertEquals(original.createdAt, restored.createdAt)
        assertEquals(original.attemptCount, restored.attemptCount)
        assertEquals(PendingWriteStatus.FAILED, restored.status)
    }

    @Test fun staleAcknowledgementCannotRemoveAnExplicitNewerEdit() {
        val original = original().copy(opType = PendingOpType.UPDATE)
        val queue = PendingWriteRepository(InMemoryPendingWriteStore(listOf(original)))
        val claim = requireNotNull(queue.claimReplay(original))
        assertTrue(queue.restoreClaimIfCurrent(claim))
        val newer = queue.coalesceMaintenanceIntent(original.clientId, PendingOpType.UPDATE, a,
            "{\"vineyardId\":\"$a\",\"itemName\":\"Newer explicit edit\"}") { }
        assertFalse(queue.removeIfCurrent(claim))
        assertEquals(listOf(newer), queue.list())
    }

    @Test fun failedNewIntentCommitCannotBeClaimedForTransport() {
        val disk = object : PendingWriteStoring {
            override fun load() = emptyList<PendingWrite>()
            override fun save(writes: List<PendingWrite>) = false
            override fun clear() = false
        }
        val queue = PendingWriteRepository(disk)
        assertThrows(IllegalStateException::class.java) {
            queue.coalesceMaintenanceIntent("original-log", PendingOpType.CREATE, a, "{\"vineyardId\":\"$a\"}") { }
        }
        assertTrue(queue.list().isEmpty())
        assertTrue(PendingWriteRepository(disk).list().isEmpty())
    }

    @Test fun failedReplacementCommitPublishesNothingAndRetainsOriginalOnRecreation() {
        val original = original(PendingWriteStatus.FAILED, 2)
        val disk = object : PendingWriteStoring {
            override fun load() = listOf(original)
            override fun save(writes: List<PendingWrite>) = false
            override fun clear() = false
        }
        val pending = PendingWriteRepository(disk)
        assertThrows(IllegalStateException::class.java) {
            pending.coalesceMaintenanceIntent("original-log", PendingOpType.CREATE, a,
                "{\"vineyardId\":\"$a\",\"itemName\":\"Edit\"}") { }
        }
        assertEquals(listOf(original), pending.list())
        assertEquals(listOf(original), PendingWriteRepository(disk).list())
    }

    @Test fun failedCancellationCommitRetainsEveryOriginal() {
        val original = original().copy(lastError = null)
        val disk = object : PendingWriteStoring {
            override fun load() = listOf(original)
            override fun save(writes: List<PendingWrite>) = false
            override fun clear() = false
        }
        val pending = PendingWriteRepository(disk)
        assertThrows(IllegalStateException::class.java) { pending.cancelUnsentMaintenanceCreate("original-log") { } }
        assertEquals(listOf(original), pending.list())
        assertEquals(listOf(original), PendingWriteRepository(disk).list())
    }

    @Test fun blockedOrAttemptedCreateCannotBeCancelledAsNeverSent() {
        for (original in listOf(original(PendingWriteStatus.BLOCKED), original(PendingWriteStatus.FAILED, 1), original(attempts = 1))) {
            val pending = PendingWriteRepository(InMemoryPendingWriteStore(listOf(original)))
            assertThrows(VineyardWriteAuthority.Restricted::class.java) { pending.cancelUnsentMaintenanceCreate("original-log") { } }
            assertEquals(listOf(original), pending.list())
        }
    }

    @Test fun owningVineyardMismatchAndAmbiguousOriginalCannotCoalesce() {
        for (rows in listOf(listOf(original()), listOf(original(), original().copy(id = "duplicate")))) {
            val pending = PendingWriteRepository(InMemoryPendingWriteStore(rows))
            assertThrows(VineyardWriteAuthority.Restricted::class.java) {
                pending.coalesceMaintenanceIntent("original-log", PendingOpType.CREATE, b, "{\"vineyardId\":\"$b\"}") { }
            }
            assertEquals(rows, pending.list())
        }
    }

    @Test fun explicitAdmittedEditPreservesIdentityBaselineAndAttempts() {
        val original = original(PendingWriteStatus.FAILED, 2)
        val disk = InMemoryPendingWriteStore(listOf(original))
        val pending = PendingWriteRepository(disk)
        val edit = "{\"vineyardId\":\"$a\",\"itemName\":\"Original explicit edit\"}"
        val next = pending.coalesceMaintenanceIntent("original-log", PendingOpType.CREATE, a, edit) { assertEquals(a, it) }
        assertEquals(original.id, next.id)
        assertEquals(original.createdAt, next.createdAt)
        assertEquals(original.attemptCount, next.attemptCount)
        assertEquals(edit, next.payloadJson)
        assertEquals(listOf(next), PendingWriteRepository(disk).list())
    }
}
