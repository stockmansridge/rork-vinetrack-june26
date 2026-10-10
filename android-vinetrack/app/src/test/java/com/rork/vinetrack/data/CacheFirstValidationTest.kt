package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.coroutines.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** Investigation-only regression coverage; no production changes or live services. */
class CacheFirstValidationTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val old = Pin(id = "pin-a", vineyardId = "A", title = "old")
    private fun write(entity: String, op: String, payload: String, client: String = "pin-a") =
        PendingWrite("write-$entity-$op", entity, op, payload, client, 1, 1)
    private fun custom(vineyard: String) = write(PendingEntityType.CUSTOM_PIN, PendingOpType.CREATE,
        "{\"vineyard_id\":\"$vineyard\",\"id\":\"custom-b\"}", "custom-b")

    @Test fun ordinaryCreateEditCompletionAndDeletionRemainProtected() {
        val input = PinRepository.PinInput(id = "new", vineyardId = "A", latitude = -34.123456789,
            longitude = 138.123456789, drivingRowNumber = 19.5, createdAt = "2026-10-10T01:00:00.123Z")
        val create = write(PendingEntityType.PIN, PendingOpType.CREATE,
            json.encodeToString(PinRepository.PinInput.serializer(), input), "new")
        val edit = write(PendingEntityType.PIN_EDIT, PendingOpType.UPDATE,
            json.encodeToString(PinEditSync.Payload.serializer(), PinEditSync.Payload("pin-a", title = "offline", clientUpdatedAt = "2026-10-10T02:00:00Z")))
        val completion = write(PendingEntityType.PIN, PendingOpType.UPDATE,
            json.encodeToString(PinCompletionSync.Payload.serializer(), PinCompletionSync.Payload("pin-a", true)))
        val rows = requireNotNull(PendingPinReadOverlay.overlay(listOf(old), emptyList(), listOf(create, edit, completion), "A"))
        assertEquals("offline", rows.first { it.id == "pin-a" }.title)
        assertTrue(rows.first { it.id == "pin-a" }.isCompleted)
        assertEquals(input.latitude, rows.first { it.id == "new" }.latitude)
        assertEquals(19.5, rows.first { it.id == "new" }.drivingRowNumber)
        val deletion = write(PendingEntityType.PIN, PendingOpType.DELETE,
            json.encodeToString(PinDeleteSync.Payload.serializer(), PinDeleteSync.Payload("pin-a")))
        assertEquals(listOf("new"), PendingPinReadOverlay.overlay(rows, rows, listOf(create, edit, completion, deletion), "A")!!.map { it.id })
    }

    @Test fun unrelatedCustomWriteMustNotSuppressAuthoritativeUpdates() {
        val remote = old.copy(title = "remote update")
        assertEquals(listOf(remote), PendingPinReadOverlay.overlay(listOf(remote), listOf(old), listOf(custom("B")), "A"))
    }

    @Test fun unrelatedManualIssueMustNotSuppressAuthoritativeDeletions() {
        val other = write(PendingEntityType.MANUAL_ISSUE, PendingOpType.CREATE,
            "{\"vineyard_id\":\"B\",\"id\":\"manual-b\"}", "manual-b")
        assertEquals(emptyList<Pin>(), PendingPinReadOverlay.overlay(emptyList(), listOf(old), listOf(other), "A"))
    }

    @Test fun unknownLegacyOwnershipRemainsUnresolved() {
        assertNull(PendingPinReadOverlay.overlay(listOf(old), listOf(old),
            listOf(write(PendingEntityType.CUSTOM_PIN, PendingOpType.CREATE, "{}")), "A"))
    }

    @Test fun ordinaryOperationArrivingDuringSuspendedRefreshProtectsEdit() = runBlocking {
        val response = CompletableDeferred<List<Pin>>()
        val pending = mutableListOf<PendingWrite>()
        val read = async(start = CoroutineStart.UNDISPATCHED) {
            val server = response.await()
            PendingPinReadOverlay.overlay(server, listOf(old), pending.toList(), "A")
        }
        pending += write(PendingEntityType.PIN_EDIT, PendingOpType.UPDATE,
            json.encodeToString(PinEditSync.Payload.serializer(), PinEditSync.Payload("pin-a", title = "new offline edit", clientUpdatedAt = "2026-10-10T02:00:00Z")))
        response.complete(listOf(old.copy(title = "server")))
        assertEquals("new offline edit", read.await()!!.single().title)
    }

    @Test fun unrelatedOperationArrivingDuringRefreshMustNotWithholdRemoteDeletion() = runBlocking {
        val response = CompletableDeferred<List<Pin>>()
        val pending = mutableListOf<PendingWrite>()
        val read = async(start = CoroutineStart.UNDISPATCHED) {
            val server = response.await()
            PendingPinReadOverlay.overlay(server, listOf(old), pending.toList(), "A")
        }
        pending += custom("B")
        response.complete(emptyList())
        assertEquals(emptyList<Pin>(), read.await())
    }

    @Test fun repeatedUnidentifiedRecoveryRefusalLeavesValidWorkAndPhotosStranded() {
        val valid = write(PendingEntityType.PIN, PendingOpType.UPDATE, "{\"pinId\":\"pin-a\",\"isCompleted\":true}")
        val unknown = write(PendingEntityType.PIN, PendingOpType.DELETE, "{\"pinId\":\"unknown\"}", "unknown")
        val queue = listOf(valid, unknown)
        var replayCalls = 0
        repeat(3) {
            val result = RecoveryPreservation.preserveBeforeReplay(queue, emptyMap(), mapOf("pin-a" to "A"), null,
                additionalVineyardIds = setOf("photo-vineyard"), preserve = { true },
                quarantine = { it.isEmpty() }, replay = { replayCalls++ })
            assertFalse(result.didRun)
            assertTrue(result.permittedWriteIds.isEmpty())
            assertEquals(setOf(unknown.id), result.unresolvedWriteIds)
        }
        assertEquals(0, replayCalls)
        assertEquals(listOf(valid, unknown), queue)
    }

    @Test fun sharedReadOverlapCancellationFailureAndScope() = runBlocking {
        withTimeout(5000) {
            val flights = ScopedReadSingleFlight<Int>()
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Int>()
            var calls = 0
            val first = async { flights.read("A", "credential") { calls++; started.complete(Unit); release.await() } }
            started.await()
            val second = async(start = CoroutineStart.UNDISPATCHED) { flights.read("A", "credential") { error("must share") } }
            first.cancelAndJoin()
            release.complete(42)
            assertEquals(42, second.await())
            assertEquals(1, calls)
            assertEquals(7, flights.read("B", "credential") { 7 })
            try { flights.read("A", "credential") { throw IllegalStateException("fixture failure") }; fail("must throw") }
            catch (_: IllegalStateException) { }
            assertEquals(9, flights.read("A", "credential") { 9 })
        }
    }

    @Test fun syntheticPinCacheDecodeSizes() {
        val serializer = ListSerializer(Pin.serializer())
        for (count in listOf(1000, 5000, 10000)) {
            val rows = (0 until count).map { old.copy(id = "pin-$it", notes = "x".repeat(512), photoPath = "fixture-photo-$it") }
            val raw = json.encodeToString(serializer, rows)
            val measurements = (0 until 4).map {
                val start = System.nanoTime()
                val decoded = json.decodeFromString(serializer, raw)
                assertEquals(count, decoded.size)
                (System.nanoTime() - start) / 1_000_000.0
            }
            println("SYNTHETIC_PIN_DECODE records=$count bytes=${raw.toByteArray().size} coldMs=${measurements.first()} warmedMs=${measurements.drop(1)} hostOnly=true")
        }
    }
}
