package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PickingRecord
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * Offline picking cache / pending-overlay contract (audit #2).
 *
 * Picking records participate in the persistent offline model: pulled rows
 * are cached per vineyard, queued offline creates/edits/deletes overlay the
 * pulled/cached baseline until replay succeeds, an online pull can never
 * visually revert a queued local edit, and replay reconciliation (marker
 * removal) hands authority back to the server row.
 */
class PickingRecordOfflineCacheTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val vintageMirror: (String) -> Int = { pickedAt ->
        // July season start (southern hemisphere) — same rule as
        // VintageResolver under the app's default settings.
        VintageResolver.vintageYear(LocalDate.parse(pickedAt), 7, 1)
    }

    private fun serverRecord(
        id: String = "R1",
        weightKg: Double = 2000.0,
        notes: String = "server",
    ): PickingRecord = PickingRecord(
        id = id,
        vineyardId = "VY1",
        pickedAt = "2027-02-10",
        vintage = 2027,
        paddockId = "P1",
        paddockName = "Stockman's Ridge",
        varietyName = "Pinot Noir",
        weightKg = weightKg,
        purpose = "Winery",
        notes = notes,
    )

    private fun createMarker(record: PickingRecord, status: String = PendingWriteStatus.PENDING): PendingWrite =
        PendingWrite(
            id = "W-create-${record.id}",
            entityType = PendingEntityType.PICKING_RECORD,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(
                PickingRecordCreateSync.Payload.serializer(),
                PickingRecordCreateSync.Payload(
                    id = record.id,
                    vineyardId = record.vineyardId,
                    pickedAt = record.pickedAt,
                    paddockId = record.paddockId,
                    paddockName = record.paddockName,
                    varietyName = record.varietyName,
                    weightKg = record.weightKg,
                    purpose = record.purpose,
                    notes = record.notes,
                    clientUpdatedAt = "2027-02-10T00:00:00Z",
                ),
            ),
            clientId = record.id,
            createdAt = 1L,
            updatedAt = 1L,
            status = status,
        )

    private fun updateMarker(record: PickingRecord, status: String = PendingWriteStatus.PENDING): PendingWrite =
        PendingWrite(
            id = "W-update-${record.id}",
            entityType = PendingEntityType.PICKING_RECORD,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(
                PickingRecordUpdateSync.Payload.serializer(),
                PickingRecordUpdateSync.Payload.from(record, "2027-02-11T00:00:00Z"),
            ),
            clientId = record.id,
            createdAt = 2L,
            updatedAt = 2L,
            status = status,
        )

    private fun deleteMarker(recordId: String): PendingWrite = PendingWrite(
        id = "W-delete-$recordId",
        entityType = PendingEntityType.PICKING_RECORD,
        opType = PendingOpType.DELETE,
        payloadJson = json.encodeToString(
            PickingRecordDeleteSync.Payload.serializer(),
            PickingRecordDeleteSync.Payload(recordId),
        ),
        clientId = recordId,
        createdAt = 3L,
        updatedAt = 3L,
    )

    @Test
    fun offlineCreateSurvivesColdRestartWithDerivedVintage() {
        // Cold restart offline: baseline is the (empty) cache, the create
        // marker is the only trace of the operator's work.
        val created = serverRecord(id = "NEW", notes = "picked offline")
        val overlaid = PendingWriteOverlay.overlayPicking(
            emptyList(), listOf(createMarker(created)), "VY1", vintageMirror,
        )
        assertEquals(1, overlaid.size)
        assertEquals("NEW", overlaid.single().id)
        assertEquals("picked offline", overlaid.single().notes)
        // Feb 2027 pick under a July season start = vintage 2027 mirror.
        assertEquals(2027, overlaid.single().vintage)
    }

    @Test
    fun onlinePullNeverRevertsAQueuedLocalEdit() {
        // Device edited offline (weight 2000 → 2500); a fresh pull still
        // returns the server's pre-edit row. The queued edit must keep
        // overlaying the pull until replay succeeds.
        val serverRow = serverRecord(weightKg = 2000.0)
        val edited = serverRow.copy(weightKg = 2500.0, notes = "edited offline")
        val overlaid = PendingWriteOverlay.overlayPicking(
            listOf(serverRow), listOf(updateMarker(edited)), "VY1", vintageMirror,
        )
        assertEquals(2500.0, overlaid.single().weightKg, 1e-9)
        assertEquals("edited offline", overlaid.single().notes)
        // Baseline vintage preserved (date unchanged by the edit).
        assertEquals(2027, overlaid.single().vintage)
    }

    @Test
    fun replayReconciliationRemovesThePendingOverlay() {
        // After a successful replay the marker is gone (removed/SYNCED) —
        // the authoritative server row shows unmodified.
        val serverRowAfterReplay = serverRecord(weightKg = 2500.0, notes = "edited offline")
        val syncedMarker = updateMarker(serverRowAfterReplay, status = PendingWriteStatus.SYNCED)
        val overlaid = PendingWriteOverlay.overlayPicking(
            listOf(serverRowAfterReplay), listOf(syncedMarker), "VY1", vintageMirror,
        )
        assertEquals(serverRowAfterReplay, overlaid.single())
    }

    @Test
    fun offlineDeleteHidesTheRowAcrossRestartAndPull() {
        val serverRow = serverRecord()
        val overlaid = PendingWriteOverlay.overlayPicking(
            listOf(serverRow), listOf(deleteMarker(serverRow.id)), "VY1", vintageMirror,
        )
        assertTrue(overlaid.isEmpty())
    }

    @Test
    fun createThenDeleteOfflineResolvesToNoVisibleRow() {
        val created = serverRecord(id = "TEMP")
        val overlaid = PendingWriteOverlay.overlayPicking(
            emptyList(),
            listOf(createMarker(created), deleteMarker("TEMP")),
            "VY1",
            vintageMirror,
        )
        assertTrue(overlaid.isEmpty())
    }

    @Test
    fun otherVineyardsMarkersNeverLeakIntoTheOverlay() {
        val foreign = serverRecord(id = "OTHER").copy(vineyardId = "VY2")
        val overlaid = PendingWriteOverlay.overlayPicking(
            emptyList(), listOf(createMarker(foreign)), "VY1", vintageMirror,
        )
        assertTrue(overlaid.isEmpty())
    }

    @Test
    fun dateMovingEditRederivesTheVintageMirror() {
        // Moving a pick from Feb 2027 to June 2027 keeps vintage 2027; moving
        // it to August crosses the July season start → vintage 2028.
        val serverRow = serverRecord()
        val moved = serverRow.copy(pickedAt = "2027-08-02")
        val overlaid = PendingWriteOverlay.overlayPicking(
            listOf(serverRow), listOf(updateMarker(moved)), "VY1", vintageMirror,
        )
        assertEquals(2028, overlaid.single().vintage)
    }
}
