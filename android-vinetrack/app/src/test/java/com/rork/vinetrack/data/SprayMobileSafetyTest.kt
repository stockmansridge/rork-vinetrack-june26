package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class SprayMobileSafetyTest {
    private fun retainedConflict(body: String, classification: SprayOperationalFailure.CreateConflict) = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val payload = SprayRecordCreateSync.Payload(id = "original-record", vineyardId = "original-vineyard",
            date = "2026-10-13", startTime = "original-start", notes = "exact original evidence", clientUpdatedAt = "original-revision")
        val bytes = Json.encodeToString(SprayRecordCreateSync.Payload.serializer(), payload)
        val original = queue.enqueue(PendingEntityType.SPRAY_RECORD, PendingOpType.CREATE, bytes, payload.id)
        queue.incrementAttempt(original.id)
        queue.incrementAttempt(original.id)
        val before = queue.list().single()
        var requests = 0
        var successes = 0
        val error = BackendError.Server(409, body)
        val sync = SprayRecordCreateSync(null, queue, createRemote = { requests++; throw error })
        sync.replayAll { successes++ }
        val retained = queue.list().single()
        assertEquals(classification, SprayOperationalFailure.createConflict(error))
        assertEquals(before.id, retained.id)
        assertEquals(before.clientId, retained.clientId)
        assertEquals(before.payloadJson, retained.payloadJson)
        assertEquals(before.createdAt, retained.createdAt)
        assertEquals(before.attemptCount, retained.attemptCount)
        assertEquals(PendingWriteStatus.BLOCKED, retained.status)
        assertEquals(0, successes)
        assertEquals(1, requests)
        sync.replayAll { successes++ }
        assertEquals(retained, queue.list().single())
        assertEquals(1, requests)
        assertEquals(0, successes)
    }

    @Test fun arbitrary409RetainsOriginalOperationWithoutAcknowledgement() = retainedConflict("",
        SprayOperationalFailure.CreateConflict.UNVERIFIED)
    @Test fun duplicatePrimaryKeyIsNotExactOperationVerification() = retainedConflict("""{"code":"23505","message":"duplicate key"}""",
        SprayOperationalFailure.CreateConflict.REVISION_OR_DATA_CONFLICT)
    @Test fun revisionConflictRetainsPayloadAndPriorAttempts() = retainedConflict("""{"code":"PT409","message":"REVISION_CONFLICT"}""",
        SprayOperationalFailure.CreateConflict.REVISION_OR_DATA_CONFLICT)
    @Test fun claimedReceiptWithoutReviewedContractNeverAcknowledges() = retainedConflict("""{"receipt":{"record_id":"original-record","accepted":true}}""",
        SprayOperationalFailure.CreateConflict.UNVERIFIED)
    @Test fun compliance409NeverAcknowledgesOrRetries() = retainedConflict("""{"code":"23514","message":"SPRAY_LABEL_CONCENTRATE_PROHIBITED"}""",
        SprayOperationalFailure.CreateConflict.COMPLIANCE_REJECTION)

    @Test fun permanentDenialNeverStartsOfflineEvenForNonSpray() {
        for (status in listOf(400, 403, 409, 422, 500)) {
            val error = BackendError.Server(status, """{"code":"23514","message":"SPRAY_LABEL_AUTHORITY_UNVERIFIED"}""")
            assertFalse(SprayOperationalFailure.canStartOffline("spraying", error))
            assertFalse(SprayOperationalFailure.canStartOffline("maintenance", error))
        }
    }
    @Test fun transientNetworkNeverAuthorisesSprayExecution() {
        for (error in listOf(IOException("offline"), BackendError.Network(IOException()), BackendError.Server(503, "temporary"))) {
            assertFalse(SprayOperationalFailure.canStartOffline("spraying", error))
            assertTrue(SprayOperationalFailure.canStartOffline("maintenance", error))
        }
    }
    @Test fun unknownAuthAndDataFailuresAreNotTransientPermission() {
        for (error in listOf(IllegalStateException("unknown"), BackendError.Unauthorized, BackendError.NotConfigured,
            BackendError.Server(409, "conflict"), BackendError.Server(403, "forbidden"))) {
            assertFalse(SprayOperationalFailure.canStartOffline("spraying", error))
            assertFalse(SprayOperationalFailure.canStartOffline("maintenance", error))
        }
    }
}
