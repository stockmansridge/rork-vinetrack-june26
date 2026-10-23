package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

/** Synthetic identities/payloads only. No production storage or server calls. */
class SyncCrashIsolationTest {
    private fun evidence(id: String) = PinCaptureEvidenceStore.Evidence(
        pinId = id, vineyardId = "vineyard", tripId = null, buttonName = "Repair", mode = "Repair",
        latitude = 0.0, longitude = 0.0, fixTimeEpochMs = 1, accuracyMetres = 1.0,
        observationTimeIso = "2026-10-14T00:00:00Z", headingDegrees = null, paddockId = null,
        pinRowNumber = null, pinSide = null, snappedLatitude = null, snappedLongitude = null,
        alongRowDistanceMetres = null, snappedToRow = false,
    )

    @Test fun interruptedPinCreateRestartsWithAccurateDiagnosticAndOriginalBytes() {
        val disk = InMemoryPendingWriteStore()
        val first = PendingWriteRepository(disk)
        val original = PinCreateSync(first).enqueue(PinRepository.PinInput(
            id = "e6f85a09-c6fe-4390-9740-018fac176d71", vineyardId = "vineyard", notes = "original"))
        first.claimReplay(original)
        val recovered = PendingWriteRepository(disk).list().single()
        assertEquals(original.id, recovered.id)
        assertEquals(original.payloadJson, recovered.payloadJson)
        assertEquals(original.clientId, recovered.clientId)
        assertEquals(0, recovered.attemptCount)
        assertEquals(PendingWriteStatus.FAILED, recovered.status)
        assertTrue(recovered.lastError!!.startsWith("Pin sync was interrupted"))
    }

    @Test fun failedEvidenceAcknowledgementCannotAbortIndependentEvidence() = runBlocking {
        val uploaded = mutableListOf<String>()
        val acknowledged = mutableListOf<String>()
        replayPinCaptureEvidence(listOf(evidence("first"), evidence("second")),
            { uploaded += it.pinId }, { id, _ ->
                if (id == "first") throw java.io.IOException("synthetic storage full")
                acknowledged += id; true
            })
        assertEquals(listOf("first", "second"), uploaded)
        assertEquals(listOf("second"), acknowledged)
    }

    @Test fun cancellationNeverUploadsTheNextEvidence() = runBlocking {
        val uploaded = mutableListOf<String>()
        var cancelled = false
        try {
            replayPinCaptureEvidence(listOf(evidence("first"), evidence("second")),
                { uploaded += it.pinId; throw CancellationException("synthetic interruption") }, { _, _ -> fail("acknowledged"); true })
        } catch (_: CancellationException) { cancelled = true }
        assertTrue(cancelled)
        assertEquals(listOf("first"), uploaded)
    }

    @Test fun thrownQueueAcknowledgementRetainsExactClaimWithoutEscaping() {
        var failSave = false
        val disk = object : PendingWriteStoring {
            var rows = emptyList<PendingWrite>()
            override fun load() = rows
            override fun save(writes: List<PendingWrite>): Boolean {
                if (failSave) throw java.io.IOException("synthetic storage full")
                rows = writes; return true
            }
            override fun clear(): Boolean = false
        }
        val queue = PendingWriteRepository(disk)
        val original = queue.enqueue(PendingEntityType.PIN, PendingOpType.CREATE, "original", "pin")
        val claim = requireNotNull(queue.claimReplay(original))
        failSave = true
        assertFalse(queue.removeIfCurrent(claim))
        assertEquals(listOf(claim), queue.list())
        assertEquals(listOf(claim), disk.rows)
    }

    @Test fun mismatchedCreateIdentityNeverReachesTransport() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val original = queue.enqueue(PendingEntityType.PIN, PendingOpType.CREATE,
            """{"id":"different","vineyard_id":"vineyard"}""", "original")
        var calls = 0
        PinCreateSync(queue) { input -> calls++; Pin(requireNotNull(input.id), input.vineyardId) }.replayAll {}
        assertEquals(0, calls)
        assertEquals(original.payloadJson, queue.list().single().payloadJson)
        assertEquals(PendingWriteStatus.BLOCKED, queue.list().single().status)
    }
}
