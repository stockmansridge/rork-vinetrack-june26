package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingWriteStatus
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import kotlinx.serialization.json.Json
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.serializer

class VineyardWriteAuthorityTest {
    private val expired = VineyardOperationalAccess(true, false, "trial_expired")
    private val paid = VineyardOperationalAccess(true, true)
    private var owner: String? = "owner"
    private var disk = emptyMap<String, String>()
    private fun authority() = VineyardWriteAuthority({ owner }, { disk }, { disk = it.toMap() })
    @After fun detach() { OperationalWrites.authority = null }

    @Test fun unknownOldServerRemainsCompatible() {
        assertTrue(authority().canWrite("A"))
    }
    @Test fun explicitTrialCapabilityKeepsEntryButDeniesCommands() {
        val gate = authority()
        gate.verified("A", expired, false)
        assertTrue(expired.canEnter)
        assertFalse(gate.admit("A"))
        assertEquals("A", gate.deniedVineyardId)
        try { gate.requireWrite("A"); fail("Write admitted") } catch (e: VineyardWriteAuthority.Restricted) {
            assertEquals(VineyardWriteAuthority.TRIAL_HOLD, e.reason)
        }
    }
    @Test fun missingCacheCannotReleaseDurableHold() {
        authority().verified("A", expired, false)
        assertFalse(authority().canWrite("A"))
    }
    @Test fun legacyWritableDefaultDoesNotReleaseKnownHold() {
        val gate = authority()
        gate.verified("A", expired, false)
        gate.verified("A", paid, false)
        assertFalse(gate.canWrite("A"))
    }
    @Test fun explicitVerifiedWriteRestoresScope() {
        val gate = authority()
        gate.verified("A", expired, false)
        gate.verified("A", paid, true)
        assertTrue(gate.canWrite("A"))
    }
    @Test fun entryDenialCannotReleaseHeldWork() {
        val gate = authority()
        gate.verified("A", expired, false)
        gate.verified("A", VineyardOperationalAccess(false, true), true)
        assertFalse(gate.canWrite("A"))
    }
    @Test fun paidVineyardIsIndependentOfExpiredVineyard() {
        val gate = authority()
        gate.verified("A", expired, false)
        assertTrue(gate.canWrite("B"))
        assertFalse(gate.canWrite("a"))
    }
    @Test fun accountSwitchNeitherLeaksNorErasesHold() {
        val gate = authority()
        gate.verified("A", expired, false)
        owner = "other"
        assertTrue(gate.canWrite("A"))
        owner = "owner"
        assertFalse(gate.canWrite("A"))
    }
    @Test fun exactServerCodeHoldsWithoutInferringTrial() {
        val gate = authority()
        assertFalse(gate.handleServerCode("401", "A"))
        assertTrue(gate.handleServerCode("VT_READ_ONLY", "A"))
        assertEquals("VT_READ_ONLY", gate.heldReason("A"))
        assertFalse(gate.canWrite("A"))
    }
    @Test fun serverRejectionKeepsConfirmedTrialReason() {
        val gate = authority()
        gate.verified("A", expired, false)
        assertTrue(gate.handleServerCode("VT_READ_ONLY", "A"))
        assertEquals(VineyardWriteAuthority.TRIAL_HOLD, gate.heldReason("A"))
    }
    @Test fun fileBackedHoldSurvivesAuthorityRecreationOffline() {
        val file = Files.createTempFile("entitlement-hold", ".json").toFile()
        val serializer = MapSerializer(serializer<String>(), serializer<String>())
        file.writeText("{}")
        try {
            fun fresh() = VineyardWriteAuthority({ owner }, { Json.decodeFromString(serializer, file.readText()) },
                { file.writeText(Json.encodeToString(serializer, it)) })
            fresh().verified("A", expired, false)
            assertFalse(fresh().canWrite("A"))
            fresh().verified("A", paid, false)
            assertFalse(fresh().canWrite("A"))
        } finally { file.delete() }
    }
    @Test fun blockedEnqueueCreatesNoNewOutboxItem() {
        val gate = authority()
        OperationalWrites.authority = gate
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        gate.verified("A", expired, false)
        try { queue.enqueue("trip", "create", "{\"vineyardId\":\"A\"}"); fail("Enqueued") }
        catch (_: VineyardWriteAuthority.Restricted) { }
        assertTrue(queue.list().isEmpty())
    }
    @Test fun retainedOriginalQueueIsNotClaimedOrRewrittenWhileHeld() {
        val gate = authority()
        OperationalWrites.authority = gate
        val store = InMemoryPendingWriteStore()
        val queue = PendingWriteRepository(store)
        val original = queue.enqueue("trip_gps", "update", "{\"vineyardId\":\"A\",\"points\":[1,2,3]}")
        gate.verified("A", expired, false)
        assertNull(queue.claimReplay(original))
        assertEquals(listOf(original), queue.list())
        val restarted = PendingWriteRepository(store)
        assertNull(restarted.claimReplay(original))
        assertEquals(listOf(original), restarted.list())
    }
    @Test fun verifiedRestorationClaimsSameOriginalOperation() {
        val gate = authority()
        OperationalWrites.authority = gate
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val original = queue.enqueue("spray_record", "create", "{\"vineyard_id\":\"A\",\"evidence\":\"original\"}")
        gate.verified("A", expired, false)
        assertNull(queue.claimReplay(original))
        gate.verified("A", paid, true)
        val resumed = requireNotNull(queue.claimReplay(original))
        assertEquals(original.id, resumed.id)
        assertEquals(original.payloadJson, resumed.payloadJson)
        assertEquals(original.createdAt, resumed.createdAt)
        assertEquals(original.attemptCount, resumed.attemptCount)
    }
    @Test fun serverRejectionHoldsClaimWithoutBurningRetryBudget() {
        OperationalWrites.authority = authority()
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val original = queue.enqueue("pin", "create", "{\"vineyardId\":\"A\"}")
        val claim = requireNotNull(queue.claimReplay(original))
        assertTrue(queue.retryIfCurrent(claim, "{\"code\":\"VT_READ_ONLY\"}", 1))
        val held = queue.list().single()
        assertEquals(original.attemptCount, held.attemptCount)
        assertEquals(original.payloadJson, held.payloadJson)
        assertEquals(original.id, held.id)
        assertEquals(PendingWriteStatus.PENDING, held.status)
        assertNull(queue.claimReplay(held))
    }
}
