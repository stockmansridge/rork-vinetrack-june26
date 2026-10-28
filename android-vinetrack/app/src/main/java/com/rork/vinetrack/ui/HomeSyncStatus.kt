package com.rork.vinetrack.ui

import com.rork.vinetrack.data.HomeReadKnowledge
import com.rork.vinetrack.data.RecoverySnapshotStore
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus

/** Ephemeral presentation only. No persistence, scheduling, retries or freshness timestamps. */
internal enum class HomeSyncTone { Synced, Syncing, Offline, Waiting, Attention }
internal data class HomeSyncStatus(val label: String, val tone: HomeSyncTone)

/** Reuse recovery's ownership resolver without its preservation/quarantine side effects. */
internal fun homeSyncWriteIds(state: AppUiState, writes: List<PendingWrite>): Set<String> {
    val vineyard = state.selectedVineyardId ?: return emptySet()
    val trips = state.trips.associate { it.id to it.vineyardId }
    val pins = state.pins.associate { it.id to it.vineyardId }
    return writes.filter { it.status in PendingWriteStatus.unresolved }.filter { write ->
        val scope = RecoverySnapshotStore.resolveReplayScope(listOf(write), trips, pins,
            includeOtherPayloadOwners = true)
        scope.unresolvedWriteIds.isEmpty() && scope.vineyardIds == setOf(vineyard)
    }.mapTo(mutableSetOf()) { it.id }
}

internal fun homeSyncStatus(
    state: AppUiState,
    items: List<PendingSyncItem>,
    photoStatuses: List<String>,
    evidenceNeedsAttention: Boolean = false,
    writesHeld: Boolean = false,
): HomeSyncStatus {
    // Connectivity wins over a lingering load/retry flag on a cached offline launch.
    if (!state.isOnline) return HomeSyncStatus("Offline", HomeSyncTone.Offline)
    if (state.isLoadingVineyardData || state.isRetryingSync ||
        items.any { it.status == "in_progress" } || photoStatuses.any { it == "in_progress" })
        return HomeSyncStatus("Syncing", HomeSyncTone.Syncing)
    val dependencies = setOf(PendingSyncDisplayState.WaitingForTripStart.label,
        PendingSyncDisplayState.WaitingForTripChanges.label)
    if (evidenceNeedsAttention || photoStatuses.any { it == "blocked" } ||
        items.any { it.status == "blocked" })
        return HomeSyncStatus("Needs attention", HomeSyncTone.Attention)
    val held = if (writesHeld) items.size + photoStatuses.size
        else items.count { it.displayStatusLabel in dependencies }
    if (held > 0) return HomeSyncStatus("$held held", HomeSyncTone.Waiting)
    if (items.any { it.status == "failed" && it.displayStatusLabel !in dependencies } ||
        photoStatuses.any { it == "failed" })
        return HomeSyncStatus("Sync error", HomeSyncTone.Attention)
    val waiting = items.size + photoStatuses.size
    if (waiting > 0) return HomeSyncStatus("$waiting waiting", HomeSyncTone.Waiting)
    // A failed online read may have retained cached data, or no data at all.
    // Never turn that into a green success, and never use unscoped editor error strings.
    if (state.isUsingCachedFieldData) return HomeSyncStatus("Sync error", HomeSyncTone.Attention)
    val knowledge = listOf(state.blocksKnowledge, state.pinsKnowledge, state.machinesKnowledge,
        state.sprayEquipmentKnowledge, state.spraysKnowledge)
    if (knowledge.any { it == HomeReadKnowledge.Cached })
        return HomeSyncStatus("Sync error", HomeSyncTone.Attention)
    if (state.selectedVineyardId == null || knowledge.any { it == HomeReadKnowledge.Unknown })
        return HomeSyncStatus("Not synced", HomeSyncTone.Waiting)
    return HomeSyncStatus("Synced", HomeSyncTone.Synced)
}
