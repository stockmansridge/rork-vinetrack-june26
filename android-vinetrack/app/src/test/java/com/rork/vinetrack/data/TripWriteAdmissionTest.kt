package com.rork.vinetrack.data

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Transport-boundary fixtures, not an authenticated server or history-screen test. */
class TripWriteAdmissionTest {
    private var owner = "account-one"
    private var current = true
    private var holds = emptyMap<String, String>()
    private val expired = VineyardOperationalAccess(true, false, "trial_expired")
    private val writable = VineyardOperationalAccess(true, true)
    private fun install(): VineyardWriteAuthority = VineyardWriteAuthority({ owner }, { holds }, { holds = it.toMap() })
        .also { OperationalWrites.authority = it }
    private fun gate(rows: List<String>) = TripWriteAdmission({ current }, { rows })
    @After fun detach() { OperationalWrites.authority = null }

    @Test fun idOnlyHistoricalMutationResolvesActualVineyardNotWritableSelection() = runBlocking {
        install().verified("A", expired, false)
        var writes = 0
        try { val vineyard = gate(listOf("A")).owningVineyard("completed-trip"); gate(listOf("B")).send(vineyard) { writes++ }; fail("Sent") }
        catch (_: VineyardWriteAuthority.Restricted) { }
        assertEquals(0, writes)
        assertTrue(OperationalWrites.canWrite("B"))
    }
    @Test fun unknownOrAmbiguousParentNeverSends() = runBlocking {
        install()
        for (rows in listOf(emptyList(), listOf(""), listOf("A", "A"), listOf("A", "B"))) {
            var writes = 0
            try { val vineyard = gate(rows).owningVineyard("trip"); gate(rows).send(vineyard) { writes++ }; fail("Unresolved scope sent") }
            catch (_: IllegalStateException) { }
            assertEquals(0, writes)
        }
    }
    @Test fun expiryDuringOwnershipReadBlocksBeforeTransport() = runBlocking {
        val authority = install()
        val admission = TripWriteAdmission({ current }, { authority.verified("A", expired, false); listOf("A") })
        try { admission.owningVineyard("trip"); fail("Admitted") } catch (_: VineyardWriteAuthority.Restricted) { }
    }
    @Test fun accountChangeDuringOwnershipReadBlocks() = runBlocking {
        install()
        val admission = TripWriteAdmission({ current }, { current = false; listOf("A") })
        try { admission.owningVineyard("trip"); fail("Admitted") } catch (_: BackendError.Unauthorized) { }
    }
    @Test fun expiryAfterReadBlocksNextIndependentSend() = runBlocking {
        val authority = install(); val admission = gate(listOf("A"))
        val vineyard = admission.owningVineyard("trip")
        var writes = 0
        admission.send(vineyard) { writes++ }
        authority.verified("A", expired, false)
        try { admission.send(vineyard) { writes++ }; fail("Second send admitted") } catch (_: VineyardWriteAuthority.Restricted) { }
        assertEquals(1, writes)
    }
    @Test fun structuredReadOnlyIsHeldNotAuthOrRetryFailure() = runBlocking {
        install(); val admission = gate(listOf("A"))
        try { admission.send("A") { throw BackendError.Server(403, "{\"code\":\"VT_READ_ONLY\"}") }; fail("No hold") }
        catch (_: VineyardWriteAuthority.Restricted) { }
        assertFalse(OperationalWrites.canWrite("A")); assertTrue(OperationalWrites.canWrite("B"))
    }
    @Test fun ordinaryForbiddenDoesNotEstablishEntitlementHold() = runBlocking {
        install()
        try { gate(listOf("A")).send("A") { throw BackendError.Server(403, "{\"code\":\"42501\"}") }; fail("No rejection") }
        catch (error: BackendError.Server) { assertEquals(403, error.code) }
        assertTrue(OperationalWrites.canWrite("A"))
    }
    @Test fun staleServerRejectionCannotHoldNewAccount() = runBlocking {
        install()
        try { gate(listOf("A")).send("A") { owner = "account-two"; current = false; throw BackendError.Server(403, "{\"code\":\"VT_READ_ONLY\"}") }; fail("No rejection") }
        catch (_: BackendError.Unauthorized) { }
        assertTrue(OperationalWrites.canWrite("A")); assertTrue(holds.isEmpty())
    }
    @Test fun successfulReceiptIsNotDiscardedIfExpiryArrivesInFlight() = runBlocking {
        val authority = install()
        val receipt = gate(listOf("A")).send("A") { authority.verified("A", expired, false); "original-receipt" }
        assertEquals("original-receipt", receipt)
        assertFalse(OperationalWrites.canWrite("A"))
    }
    @Test fun offlineRestartKeepsExactOriginalUntilSameAccountAndVineyardExplicitlyWritable() = runBlocking {
        var authority = install()
        val store = InMemoryPendingWriteStore()
        var queue = PendingWriteRepository(store)
        val payload = "{\"vineyardId\":\"A\",\"tripId\":\"original-trip\",\"attachment\":\"original-file\",\"receipt\":\"original-receipt\",\"timestamp\":\"2026-10-01T12:00:00Z\"}"
        val original = queue.enqueue("trip_end", "update", payload)
        authority.verified("A", expired, false)
        authority = install(); queue = PendingWriteRepository(store)
        assertNull(queue.claimReplay(original)); assertEquals(listOf(original), queue.list())
        authority.verified("A", expired, false)
        assertNull(queue.claimReplay(original)); assertEquals(listOf(original), queue.list())
        authority.verified("B", writable, true)
        assertNull(queue.claimReplay(original)); assertEquals(listOf(original), queue.list())
        owner = "account-two"; authority.verified("A", writable, true); owner = "account-one"
        assertNull(queue.claimReplay(original)); assertEquals(listOf(original), queue.list())
        authority.verified("A", writable, false)
        assertNull(queue.claimReplay(original))
        authority.verified("A", writable, true)
        val claim = requireNotNull(queue.claimReplay(original))
        var writes = 0
        gate(listOf("A")).send("A") { writes++; assertEquals(payload, claim.payloadJson) }
        assertTrue(queue.removeIfCurrent(claim))
        assertNull(queue.claimReplay(original)); assertTrue(queue.list().isEmpty()); assertEquals(1, writes)
        assertEquals(original.createdAt, claim.createdAt); assertEquals(original.attemptCount, claim.attemptCount)
    }
}
