package com.rork.vinetrack.ui

import com.rork.vinetrack.data.HomeReadKnowledge
import com.rork.vinetrack.data.model.*
import org.junit.Assert.*
import org.junit.Test

class HomeSyncStatusTest {
    private fun fresh(v: String = "A") = AppUiState(selectedVineyardId = v,
        blocksKnowledge = HomeReadKnowledge.Fresh, pinsKnowledge = HomeReadKnowledge.Fresh,
        machinesKnowledge = HomeReadKnowledge.Fresh, sprayEquipmentKnowledge = HomeReadKnowledge.Fresh,
        spraysKnowledge = HomeReadKnowledge.Fresh)
    private fun item(status: String, display: PendingSyncDisplayState = PendingSyncDisplayState.Pending) =
        PendingSyncItem("one", "Saved change", display.label, status = status)
    private fun status(s: AppUiState = fresh(), items: List<PendingSyncItem> = emptyList(), photos: List<String> = emptyList()) =
        homeSyncStatus(s, items, photos)

    @Test fun freshIsGreenButUnknownAndCachedNeverClaimSynced() {
        assertEquals(HomeSyncStatus("Synced", HomeSyncTone.Synced), status())
        assertEquals("Not synced", status(AppUiState()).label)
        assertEquals("Not synced", status(fresh().copy(machinesKnowledge = HomeReadKnowledge.Unknown)).label)
        assertEquals("Sync error", status(fresh().copy(sprayEquipmentKnowledge = HomeReadKnowledge.Cached)).label)
        assertEquals("Sync error", status(fresh().copy(isUsingCachedFieldData = true, cachedFieldDataLastSyncedAt = 42)).label)
    }
    @Test fun offlineWinsOverCachedLoadingRetryAndErrors() {
        val s = fresh().copy(isOnline = false, isUsingCachedFieldData = true,
            isLoadingVineyardData = true, isRetryingSync = true)
        assertEquals(HomeSyncStatus("Offline", HomeSyncTone.Offline), status(s, listOf(item("blocked"))))
    }
    @Test fun onlineRefreshIncludingCachedAndActiveReplayIsBlue() {
        assertEquals(HomeSyncTone.Syncing, status(fresh().copy(isLoadingVineyardData = true, isUsingCachedFieldData = true)).tone)
        assertEquals("Syncing", status(items = listOf(item("in_progress"))).label)
        assertEquals("Syncing", status(photos = listOf("in_progress")).label)
        assertEquals("Syncing", status(fresh().copy(isRetryingSync = true)).label)
    }
    @Test fun pendingPhotosAreCountedAndDependencyFailuresAreHeldNotErrors() {
        assertEquals("3 waiting", status(items = listOf(item("pending")), photos = listOf("pending", "pending")).label)
        val held = item("failed", PendingSyncDisplayState.WaitingForTripStart)
        assertEquals(HomeSyncStatus("2 held", HomeSyncTone.Waiting), status(items = listOf(held, held)))
        assertEquals("2 held", homeSyncStatus(fresh(), listOf(item("pending")), listOf("pending"), writesHeld = true).label)
    }
    @Test fun actualFailuresAndBlockedEvidenceAreRed() {
        assertEquals("Sync error", status(items = listOf(item("failed", PendingSyncDisplayState.Retrying))).label)
        assertEquals("Sync error", status(photos = listOf("failed")).label)
        assertEquals(HomeSyncTone.Attention, status(items = listOf(item("blocked"))).tone)
        assertEquals("Needs attention", status(photos = listOf("blocked")).label)
        assertEquals("Needs attention", homeSyncStatus(fresh(), emptyList(), emptyList(), evidenceNeedsAttention = true).label)
    }
    @Test fun scopedQueuesFollowStockmansJHStockmansWithoutBorrowedOwners() {
        fun write(id: String, v: String?, status: String = "pending") = PendingWrite(id, "pin", "create",
            if (v == null) "{}" else "{\"vineyard_id\":\"$v\"}", id, 1, 1, status = status)
        val writes = listOf(write("a", "A"), write("b", "B", "blocked"), write("unknown", null))
        for ((v, expected) in listOf("A" to "a", "B" to "b", "A" to "a")) {
            assertEquals(setOf(expected), homeSyncWriteIds(fresh(v), writes))
        }
        assertTrue(homeSyncWriteIds(AppUiState(), writes).isEmpty())
        val idOnly = write("known", null)
        assertEquals(setOf("known"), homeSyncWriteIds(fresh().copy(pins = listOf(Pin("known", "A"))), listOf(idOnly)))
        assertTrue(homeSyncWriteIds(fresh().copy(pins = listOf(Pin("b", "A"))), listOf(writes[1])).isEmpty())
        assertEquals("a", writes.first().id)
        assertEquals("blocked", writes[1].status)
    }
    @Test fun reconnectAndVineyardCacheTimestampsHaveNoRememberedPresentation() {
        val a = fresh().copy(isOnline = false, isUsingCachedFieldData = true, cachedFieldDataLastSyncedAt = 12)
        assertEquals("Offline", status(a).label)
        assertEquals("Syncing", status(a.copy(isOnline = true, isLoadingVineyardData = true)).label)
        assertEquals("Synced", status(fresh("B")).label)
        assertEquals("Offline", status(a).label)
        assertEquals("Synced", status(fresh()).label)
        assertEquals(12L, a.cachedFieldDataLastSyncedAt)
    }
}
