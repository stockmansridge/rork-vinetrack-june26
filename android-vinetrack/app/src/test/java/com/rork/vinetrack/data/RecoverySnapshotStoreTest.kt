package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoverySnapshotStoreTest {
    private val payloadJson = Json { encodeDefaults = true }

    @Test
    fun `first pre-replay snapshot remains byte-identical after later replacement attempt`() {
        val bytes = mutableMapOf<String, String>()
        val store = memoryStore(bytes)
        val before = snapshot("vineyard", "2026-09-10T00:00:00Z")
        val after = before.copy(snapshotAt = "2026-09-10T00:01:00Z", sourceStatuses = emptyList())

        assertTrue(store.saveIfAbsent(before) is RecoverySnapshotStore.SaveResult.Persisted)
        assertTrue(store.saveIfAbsent(after) is RecoverySnapshotStore.SaveResult.Existing)

        assertEquals(before, store.load("vineyard"))
    }

    @Test
    fun `trip gps without vineyard payload is retained through known trip ownership`() {
        val write = pending(
            id = "gps-write",
            entityType = PendingEntityType.TRIP_GPS,
            clientId = "trip-a",
            payload = """{"tripId":"trip-a","savedAt":1}""",
        )

        val (included, excluded) = RecoverySnapshotStore.selectPendingEvidence(
            vineyardId = "vineyard-a",
            pendingWrites = listOf(write),
            knownTripIds = setOf("trip-a"),
        )

        assertEquals(listOf(write), included)
        assertTrue(excluded.isEmpty())
    }

    @Test
    fun `trip gps omission is explicitly reported when ownership is unknown`() {
        val write = pending(
            id = "gps-write",
            entityType = PendingEntityType.TRIP_GPS,
            clientId = "unknown-trip",
            payload = """{"tripId":"unknown-trip"}""",
        )

        val (included, excluded) = RecoverySnapshotStore.selectPendingEvidence(
            vineyardId = "vineyard-a",
            pendingWrites = listOf(write),
            knownTripIds = emptySet(),
        )

        assertTrue(included.isEmpty())
        assertEquals("gps-write", excluded.single().itemId)
    }

    @Test
    fun `real pin completion and delete payloads are retained through known pin ownership`() {
        val completion = pending(
            id = "completion-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-1",
            payload = completionPayload("pin-1", true),
            opType = PendingOpType.UPDATE,
        )
        val delete = pending(
            id = "delete-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-2",
            payload = deletePayload("pin-2"),
            opType = PendingOpType.DELETE,
        )

        val (included, excluded) = RecoverySnapshotStore.selectPendingEvidence(
            vineyardId = "vineyard-a",
            pendingWrites = listOf(completion, delete),
            knownTripIds = emptySet(),
            knownPinIds = setOf("pin-1", "pin-2"),
        )

        assertEquals(listOf(completion, delete), included)
        assertTrue(excluded.isEmpty())
    }

    @Test
    fun `failed persistence is not reported as preserved and mutation does not run`() {
        val store = RecoverySnapshotStore(
            readRaw = { null },
            writeRawIfAbsent = { _, _ -> false },
            unprovenWrites = mutableMapOf(),
        )
        val result = store.saveIfAbsent(snapshot("vineyard", "2026-09-10T00:00:00Z"))
        var replayed = false
        val scope = RecoverySnapshotStore.ReplayScope(setOf("vineyard"), emptySet())

        val outcome = RecoveryReplayGate.run(
            scope = scope,
            preserve = { result.isPreserved },
            replay = { replayed = true },
        )

        assertSame(RecoverySnapshotStore.SaveResult.Failed, result)
        assertFalse(outcome.didRun)
        assertTrue(outcome is RecoveryReplayGate.Outcome.PreservationFailed)
        assertFalse(replayed)
    }

    @Test
    fun `write visible in memory but not committed stays failed until a durable retry succeeds`() {
        // SharedPreferences publishes to its in-memory map before the disk write
        // finishes, so a failed commit() can still read back as valid data.
        val memory = mutableMapOf<String, String>()
        val disk = mutableMapOf<String, String>()
        var commitSucceeds = false
        val unproven = mutableMapOf<String, String>()
        var replayed = false
        val store = RecoverySnapshotStore(
            readRaw = { key -> memory[key] },
            writeRawIfAbsent = { key, value ->
                if (memory.containsKey(key)) {
                    false
                } else {
                    memory[key] = value
                    if (commitSucceeds) disk[key] = value
                    commitSucceeds
                }
            },
            rewriteUnprovenRaw = { key, value ->
                memory[key] = value
                if (commitSucceeds) disk[key] = value
                commitSucceeds
            },
            unprovenWrites = unproven,
        )
        val captured = snapshot("vineyard", "2026-09-10T00:00:00Z")

        val first = store.saveIfAbsent(captured)

        assertSame(RecoverySnapshotStore.SaveResult.Failed, first)
        assertFalse(first.isPreserved)
        // The value IS readable, but it is in-memory only — not durable.
        assertNotNull(store.load("vineyard"))
        assertTrue(disk.isEmpty())

        // A later call in the same process must not upgrade it to preserved.
        val second = store.saveIfAbsent(snapshot("vineyard", "2026-09-10T00:05:00Z"))
        assertSame(RecoverySnapshotStore.SaveResult.Failed, second)
        assertTrue(store.hasUnprovenWrite("vineyard"))

        val blocked = RecoveryReplayGate.run(
            scope = RecoverySnapshotStore.ReplayScope(setOf("vineyard"), emptySet()),
            preserve = { second.isPreserved },
            replay = { replayed = true },
        )
        assertFalse(blocked.didRun)
        assertFalse(replayed)

        // Genuine durable retry: the originally captured evidence is retained and
        // written through to persisted storage, then reads restore it.
        commitSucceeds = true
        val retried = store.saveIfAbsent(snapshot("vineyard", "2026-09-10T00:09:00Z"))

        assertTrue(retried is RecoverySnapshotStore.SaveResult.Persisted)
        assertTrue(retried.isPreserved)
        assertFalse(store.hasUnprovenWrite("vineyard"))
        assertEquals(captured, (retried as RecoverySnapshotStore.SaveResult.Persisted).snapshot)

        val restored = RecoverySnapshotStore(
            readRaw = { key -> disk[key] },
            writeRawIfAbsent = { _, _ -> false },
            unprovenWrites = mutableMapOf(),
        )
        assertEquals(captured, restored.load("vineyard"))

        val allowed = RecoveryReplayGate.run(
            scope = RecoverySnapshotStore.ReplayScope(setOf("vineyard"), emptySet()),
            preserve = { retried.isPreserved },
            replay = { replayed = true },
        )
        assertTrue(allowed.didRun)
        assertTrue(replayed)
    }

    @Test
    fun `failed write never overwrites an existing valid original snapshot`() {
        val bytes = mutableMapOf("snapshot_vineyard" to originalBytes())
        val store = memoryStore(bytes)

        val result = store.saveIfAbsent(snapshot("vineyard", "2026-09-10T02:00:00Z"))

        assertTrue(result is RecoverySnapshotStore.SaveResult.Existing)
        assertEquals(originalBytes(), bytes["snapshot_vineyard"])
    }

    @Test
    fun `existing unreadable bytes are preserved and block mutation`() {
        val original = "{not-valid-json"
        var writeAttempted = false
        val store = RecoverySnapshotStore(
            readRaw = { original },
            writeRawIfAbsent = { _, _ -> writeAttempted = true; true },
            unprovenWrites = mutableMapOf(),
        )

        val result = store.saveIfAbsent(snapshot("vineyard", "2026-09-10T00:00:00Z"))

        assertTrue(result is RecoverySnapshotStore.SaveResult.ExistingUnreadable)
        assertEquals(original, (result as RecoverySnapshotStore.SaveResult.ExistingUnreadable).originalBytes)
        assertFalse(result.isPreserved)
        assertFalse(writeAttempted)
    }

    @Test
    fun `selected vineyard A preserves queued vineyard B before B queue drains`() {
        val queue = mutableListOf(
            pending("pin-a", PendingEntityType.PIN, "pin-a", """{"vineyard_id":"A"}"""),
            pending("pin-b", PendingEntityType.PIN, "pin-b", """{"vineyard_id":"B"}"""),
        )
        val scope = RecoverySnapshotStore.resolveReplayScope(queue, emptyMap(), fallbackVineyardId = "A")
        val preserved = mutableListOf<String>()

        val outcome = RecoveryReplayGate.run(
            scope = scope,
            preserve = { vineyardId -> preserved += vineyardId; true },
            replay = { queue.clear() },
        )

        assertTrue(outcome.didRun)
        assertEquals(setOf("A", "B"), preserved.toSet())
        assertTrue(queue.isEmpty())
    }

    @Test
    fun `startup without selected vineyard resolves queued trip gps through known trip`() {
        val write = pending(
            id = "gps-b",
            entityType = PendingEntityType.TRIP_GPS,
            clientId = "trip-b",
            payload = """{"tripId":"trip-b"}""",
        )

        val scope = RecoverySnapshotStore.resolveReplayScope(
            pendingWrites = listOf(write),
            tripOwners = mapOf("trip-b" to "B"),
            fallbackVineyardId = null,
        )

        assertEquals(setOf("B"), scope.vineyardIds)
        assertTrue(scope.unresolvedWriteIds.isEmpty())
    }

    @Test
    fun `production retry preserves and syncs a queued completion and deletion with no selected vineyard`() {
        val completion = pending(
            id = "completion-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-1",
            payload = completionPayload("pin-1", true),
            opType = PendingOpType.UPDATE,
        )
        val delete = pending(
            id = "delete-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-2",
            payload = deletePayload("pin-2"),
            opType = PendingOpType.DELETE,
        )
        val preserved = mutableListOf<String>()
        var replayed = false

        val result = RecoveryPreservation.preserveBeforeReplay(
            pendingWrites = listOf(completion, delete),
            tripOwners = emptyMap(),
            pinOwners = mapOf("pin-1" to "A", "pin-2" to "B"),
            fallbackVineyardId = null,
            preserve = { vineyardId -> preserved += vineyardId; true },
            quarantine = { it.isEmpty() },
            replay = { replayed = true },
        )

        assertTrue(result.didRun)
        assertTrue(replayed)
        assertEquals(setOf("A", "B"), preserved.toSet())
        assertTrue(result.quarantinedWriteIds.isEmpty())
        assertEquals(null, result.message)
    }

    @Test
    fun `unidentifiable item is held back explicitly without blocking resolved offline pin work`() {
        val resolved = pending(
            id = "completion-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-1",
            payload = completionPayload("pin-1", false),
            opType = PendingOpType.UPDATE,
        )
        val orphan = pending(
            id = "orphan-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-unknown",
            payload = deletePayload("pin-unknown"),
            opType = PendingOpType.DELETE,
        )
        val queue = mutableListOf(resolved, orphan)
        var replayed = false

        val result = RecoveryPreservation.preserveBeforeReplay(
            pendingWrites = queue.toList(),
            tripOwners = emptyMap(),
            pinOwners = mapOf("pin-1" to "A"),
            fallbackVineyardId = "A",
            preserve = { true },
            quarantine = { ids ->
                RecoveryPreservation.quarantine(
                    writeIds = ids,
                    hold = { id, message ->
                        val index = queue.indexOfFirst { it.id == id }
                        queue[index] = queue[index].copy(
                            status = PendingWriteStatus.BLOCKED,
                            lastError = message,
                        )
                    },
                    readBack = { queue.toList() },
                )
            },
            replay = { replayed = true },
        )

        assertTrue(result.didRun)
        assertTrue(replayed)
        assertEquals(setOf("orphan-write"), result.quarantinedWriteIds)
        assertEquals(PendingWriteStatus.PENDING, queue.first { it.id == "completion-write" }.status)
        val held = queue.first { it.id == "orphan-write" }
        assertEquals(PendingWriteStatus.BLOCKED, held.status)
        assertTrue(held.lastError!!.contains("couldn't be linked to a vineyard"))
    }

    @Test
    fun `ownership and storage failures produce different operator messages`() {
        val orphan = pending(
            id = "orphan-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-unknown",
            payload = deletePayload("pin-unknown"),
            opType = PendingOpType.DELETE,
        )
        val resolved = pending(
            id = "completion-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-1",
            payload = completionPayload("pin-1", true),
            opType = PendingOpType.UPDATE,
        )

        val quarantineFailure = RecoveryPreservation.preserveBeforeReplay(
            pendingWrites = listOf(orphan),
            tripOwners = emptyMap(),
            pinOwners = emptyMap(),
            fallbackVineyardId = null,
            preserve = { true },
            quarantine = { false },
        )
        val storageFailure = RecoveryPreservation.preserveBeforeReplay(
            pendingWrites = listOf(resolved),
            tripOwners = emptyMap(),
            pinOwners = mapOf("pin-1" to "A"),
            fallbackVineyardId = null,
            preserve = { false },
            quarantine = { it.isEmpty() },
        )

        assertFalse(quarantineFailure.didRun)
        assertFalse(storageFailure.didRun)
        assertTrue(quarantineFailure.message!!.contains("couldn't be linked to a vineyard"))
        assertFalse(quarantineFailure.message!!.contains("storage"))
        assertTrue(storageFailure.message!!.contains("storage"))
        assertFalse(storageFailure.message!!.contains("linked to a vineyard"))
    }

    @Test
    fun `selected vineyard is never used as the owner of an unidentified pin write`() {
        val orphan = pending(
            id = "orphan-write",
            entityType = PendingEntityType.PIN,
            clientId = "pin-unknown",
            payload = deletePayload("pin-unknown"),
            opType = PendingOpType.DELETE,
        )

        val scope = RecoverySnapshotStore.resolveReplayScope(
            pendingWrites = listOf(orphan),
            tripOwners = emptyMap(),
            pinOwners = mapOf("pin-1" to "A"),
            fallbackVineyardId = "A",
        )

        assertEquals(setOf("orphan-write"), scope.unresolvedWriteIds)
        assertEquals(setOf("A"), scope.vineyardIds)
    }

    @Test
    fun `export keeps original snapshot unchanged and labels later qualified evidence as current`() {
        val original = snapshot("vineyard", "2026-09-10T00:00:00Z")
        val newEvidence = evidence("new-pin")
        val current = RecoverySnapshotStore.CurrentEvidence(
            collectedAt = "2026-09-10T01:00:00Z",
            pendingWrites = emptyList(),
            captureEvidence = listOf(newEvidence),
            cachedPins = emptyList(),
            cachedTrips = emptyList(),
            activeTrip = null,
            sourceStatuses = emptyList(),
            excludedOrUnreadable = emptyList(),
        )

        val export = RecoverySnapshotStore.exportBundle(original, current)

        assertSame(original, export.originalPreMutationSnapshot)
        assertTrue(export.originalPreMutationSnapshot.captureEvidence.isEmpty())
        assertEquals("new-pin", export.currentEvidence.captureEvidence.single().pinId)
        assertTrue(export.currentEvidence.provenance.contains("not_part_of_original_snapshot"))
    }

    private fun completionPayload(pinId: String, isCompleted: Boolean): String =
        payloadJson.encodeToString(
            PinCompletionSync.Payload.serializer(),
            PinCompletionSync.Payload(pinId, isCompleted),
        )

    private fun deletePayload(pinId: String): String =
        payloadJson.encodeToString(PinDeleteSync.Payload.serializer(), PinDeleteSync.Payload(pinId))

    private fun originalBytes(): String = Json { encodeDefaults = true; prettyPrint = true }
        .encodeToString(
            RecoverySnapshotStore.Snapshot.serializer(),
            snapshot("vineyard", "2026-09-10T00:00:00Z"),
        )

    private fun memoryStore(bytes: MutableMap<String, String>): RecoverySnapshotStore = RecoverySnapshotStore(
        readRaw = { bytes[it] },
        writeRawIfAbsent = { key, value -> if (bytes.containsKey(key)) false else { bytes[key] = value; true } },
        unprovenWrites = mutableMapOf(),
    )

    private fun snapshot(vineyardId: String, at: String): RecoverySnapshotStore.Snapshot =
        RecoverySnapshotStore.Snapshot(
            vineyardId = vineyardId,
            appVersion = "3.0.3",
            buildVersion = 8,
            snapshotAt = at,
            source = "before_vineyard_load_refresh_or_replay",
            pendingWrites = emptyList(),
            captureEvidence = emptyList(),
            cachedPins = emptyList(),
            cachedTrips = emptyList(),
            activeTrip = null,
            sourceStatuses = listOf(RecoverySnapshotStore.SourceStatus("cached_pins", "read", 175)),
            excludedOrUnreadable = emptyList(),
        )

    private fun pending(
        id: String,
        entityType: String,
        clientId: String,
        payload: String,
        opType: String = PendingOpType.UPDATE,
    ): PendingWrite = PendingWrite(
        id = id,
        entityType = entityType,
        opType = opType,
        payloadJson = payload,
        clientId = clientId,
        createdAt = 1,
        updatedAt = 1,
    )

    private fun evidence(pinId: String): PinCaptureEvidenceStore.Evidence =
        PinCaptureEvidenceStore.Evidence(
            pinId = pinId,
            vineyardId = "vineyard",
            tripId = null,
            buttonName = "Pest",
            mode = "gps",
            side = "none",
            latitude = -32.0,
            longitude = 148.0,
            fixTimeEpochMs = 1,
            accuracyMetres = 4.0,
            observationTimeIso = "2026-09-10T00:30:00Z",
            headingDegrees = null,
            paddockId = null,
            pinRowNumber = null,
            pinSide = null,
            snappedLatitude = null,
            snappedLongitude = null,
            alongRowDistanceMetres = null,
            snappedToRow = false,
        )
}
