package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class PinConfirmationReplayTest {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val captured = Pin("pin", "vineyard", latitude = -33.0, longitude = 149.0,
        rowNumber = 33, drivingRowNumber = 32.5, pinRowNumber = 33.0, pinSide = "Right",
        snappedLatitude = -33.0001, snappedLongitude = 149.0001, snappedToRow = true,
        notes = "offline notes", photoPath = "pending.jpg")

    @Test fun rowOnlyServerConfirmationClearsOldSnapIncludingNullFields() {
        val server = Pin("pin", "vineyard", pinRowNumber = 34.0, snappedToRow = false,
            locationConfirmationRevision = 2, syncVersion = 9)
        val merged = PinReplayMerge.merge(server, captured)
        assertEquals(34.0, merged.pinRowNumber)
        assertNull(merged.drivingRowNumber)
        assertNull(merged.pinSide)
        assertNull(merged.snappedLatitude)
        assertNull(merged.snappedLongitude)
        assertFalse(merged.snappedToRow)
        assertEquals(2L, merged.locationConfirmationRevision)
        assertEquals(9L, merged.syncVersion)
        assertEquals(captured.latitude, merged.latitude)
        assertEquals(captured.notes, merged.notes)
        assertEquals(captured.photoPath, merged.photoPath)
    }

    @Test fun olderReplayCannotReplaceNewerConfirmedLocationAfterRestart() {
        val confirmed = captured.copy(pinRowNumber = 34.0, pinSide = "Left",
            drivingRowNumber = 34.5, syncVersion = 12, locationConfirmationRevision = 3)
        val restored = json.decodeFromString(Pin.serializer(), json.encodeToString(Pin.serializer(), confirmed))
        val old = captured.copy(pinRowNumber = 12.0, syncVersion = 4, locationConfirmationRevision = 1)
        val merged = PinReplayMerge.merge(old, restored)
        assertEquals(34.0, merged.pinRowNumber)
        assertEquals(34.5, merged.drivingRowNumber)
        assertEquals("Left", merged.pinSide)
        assertEquals(12L, merged.syncVersion)
        assertEquals(3L, merged.locationConfirmationRevision)
    }

    @Test fun pendingCreateOverlayCannotHideServerConfirmationOrRegressCache() {
        val server = captured.copy(pinRowNumber = 34.0, pinSide = "Left", syncVersion = 9,
            locationConfirmationRevision = 2, notes = "server notes")
        val pending = PendingWrite("create", PendingEntityType.PIN, PendingOpType.CREATE,
            json.encodeToString(Pin.serializer(), captured), captured.id, 1, 1)
        val result = PendingPinReadOverlay.reconcile(listOf(server), listOf(captured), listOf(pending), "vineyard")
        assertEquals(34.0, result.rows.single().pinRowNumber)
        assertEquals("Left", result.rows.single().pinSide)
        assertEquals(captured.notes, result.rows.single().notes)
        assertEquals(2L, result.rows.single().locationConfirmationRevision)
        assertEquals(9L, result.rows.single().syncVersion)
        assertEquals(server, result.cacheRows.single())
        assertTrue(result.unresolvedWriteIds.isEmpty())
        assertEquals(captured, json.decodeFromString(Pin.serializer(), pending.payloadJson))
    }

    @Test fun crossVineyardIdentityCannotBorrowLocation() {
        val server = Pin("pin", "other", locationConfirmationRevision = 1)
        assertEquals(server, PinReplayMerge.merge(server, captured))
    }
}
