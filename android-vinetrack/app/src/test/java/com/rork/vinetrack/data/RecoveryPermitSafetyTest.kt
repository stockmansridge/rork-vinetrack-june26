package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** Regression coverage for the two controlled permit/acknowledgement findings; not selective replay acceptance. */
class RecoveryPermitSafetyTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    @Test fun idOnlyPermitDoesNotFreezePayloadBeforeReplay() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val original = PinRepository.PinInput(id = "pin", vineyardId = "A", notes = "preserved")
        var consumed: PinRepository.PinInput? = null
        val sync = PinCreateSync(queue) { input ->
            consumed = input
            Pin(id = requireNotNull(input.id), vineyardId = input.vineyardId)
        }
        val frozen = sync.enqueue(original)
        val changed = original.copy(notes = "not in preservation snapshot")
        val replacement = queue.upsertCoalesced(PendingEntityType.PIN, "pin",
            json.encodeToString(PinRepository.PinInput.serializer(), changed), PendingOpType.CREATE)
        assertEquals(frozen.id, replacement.id)
        sync.replayAll(setOf(frozen.id), mapOf(frozen.id to frozen)) { }
        assertNull(consumed)
        assertEquals(listOf(replacement), queue.list())
        assertNotEquals(frozen.payloadJson, replacement.payloadJson)
    }

    @Test fun idOnlyAcknowledgementCanConsumeReplacementArrivingDuringRequest() = runBlocking {
        val queue = PendingWriteRepository(InMemoryPendingWriteStore())
        val started = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Pin>()
        val original = PinRepository.PinInput(id = "pin", vineyardId = "A", notes = "preserved")
        val sync = PinCreateSync(queue) { started.complete(Unit); response.await() }
        val frozen = sync.enqueue(original)
        val replay = async { sync.replayAll(setOf(frozen.id)) { } }
        started.await()
        val changed = original.copy(notes = "new intent")
        val replacement = queue.upsertCoalesced(PendingEntityType.PIN, "pin",
            json.encodeToString(PinRepository.PinInput.serializer(), changed), PendingOpType.CREATE)
        assertEquals(frozen.id, replacement.id)
        response.complete(Pin("pin", "A"))
        replay.await()
        // Even an ID-only caller cannot acknowledge a replacement with an earlier response.
        assertEquals(listOf(replacement), queue.list())
    }
}
