package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.serialization.json.Json

/** Reconciles a start/activation response without rolling back live local work. */
object TripStartReconciliation {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Adopt server metadata except title/hours covered by an unresolved scalar
     * edit at publication time. This preserves intent, not server-write authority:
     * metadata replay still applies its original stale-server conflict checks.
     * All existing live runtime fields remain local regardless of GPS counts.
     */
    fun reconcile(server: Trip, local: Trip, pendingWrites: List<PendingWrite> = emptyList()): Trip {
        require(server.id == local.id) { "Trips must share an id." }
        if (server.vineyardId != local.vineyardId) return local
        val marker = pendingWrites.lastOrNull {
            it.clientId == local.id && it.entityType == PendingEntityType.TRIP_METADATA &&
                it.opType == PendingOpType.UPDATE && it.status in PendingWriteStatus.unresolved
        }
        val metadata = marker?.let {
            runCatching { json.decodeFromString(TripMetadataSync.Payload.serializer(), it.payloadJson) }
                .getOrNull()?.takeIf { payload -> payload.tripId == local.id }
        }
        // Unreadable pending intent must not become permission to roll back saved scalars.
        return server.copy(
            tripTitle = if (marker == null) server.tripTitle else
                if (metadata != null) metadata.tripTitle else local.tripTitle,
            startEngineHours = if (marker == null) server.startEngineHours else
                if (metadata != null) metadata.startEngineHours else local.startEngineHours,
            startTime = local.startTime,
            endTime = local.endTime,
            isActive = local.isActive,
            isPaused = local.isPaused,
            totalDistance = local.totalDistance,
            pathPoints = local.pathPoints,
            completedPaths = local.completedPaths,
            skippedPaths = local.skippedPaths,
            sequenceIndex = local.sequenceIndex,
            currentRowNumber = local.currentRowNumber,
            nextRowNumber = local.nextRowNumber,
            trackingPattern = local.trackingPattern,
            rowSequence = local.rowSequence,
            manualCorrectionEvents = (server.manualCorrectionEvents.orEmpty() + local.manualCorrectionEvents.orEmpty()).distinct(),
            tankSessions = local.tankSessions,
            activeTankNumber = local.activeTankNumber,
            isFillingTank = local.isFillingTank,
            fillingTankNumber = local.fillingTankNumber,
            pauseTimestamps = local.pauseTimestamps,
            resumeTimestamps = local.resumeTimestamps,
            completionNotes = local.completionNotes,
            endEngineHours = local.endEngineHours,
            clientUpdatedAt = local.clientUpdatedAt,
        )
    }
}
