package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoverySnapshotStoreTest {
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
    fun `failed persistence is not reported as preserved and mutation does not run`() {
        val store = RecoverySnapshotStore(readRaw = { null }, writeRawIfAbsent = { _, _ -> false })
        val result = store.saveIfAbsent(snapshot("vineyard", "2026-09-10T00:00:00Z"))
        var replayed = false
        val scope = RecoverySnapshotStore.ReplayScope(setOf("vineyard"), emptySet())

        val allowed = RecoveryReplayGate.run(
            scope = scope,
            preserve = { result.isPreserved },
            replay = { replayed = true },
        )

        assertSame(RecoverySnapshotStore.SaveResult.Failed, result)
        assertFalse(allowed)
        assertFalse(replayed)
    }

    @Test
    fun `existing unreadable bytes are preserved and block mutation`() {
        val original = "{not-valid-json"
        var writeAttempted = false
        val store = RecoverySnapshotStore(
            readRaw = { original },
            writeRawIfAbsent = { _, _ -> writeAttempted = true; true },
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

        val allowed = RecoveryReplayGate.run(
            scope = scope,
            preserve = { vineyardId -> preserved += vineyardId; true },
            replay = { queue.clear() },
        )

        assertTrue(allowed)
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

    private fun memoryStore(bytes: MutableMap<String, String>): RecoverySnapshotStore = RecoverySnapshotStore(
        readRaw = { bytes[it] },
        writeRawIfAbsent = { key, value -> if (bytes.containsKey(key)) false else { bytes[key] = value; true } },
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
    ): PendingWrite = PendingWrite(
        id = id,
        entityType = entityType,
        opType = PendingOpType.UPDATE,
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
