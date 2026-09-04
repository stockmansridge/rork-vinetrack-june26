package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip

/** Reconciles a start/activation response without rolling back live local work. */
object TripStartReconciliation {
    /**
     * Server metadata may be adopted, but every field owned by the live runtime
     * remains local. This is unconditional: equal GPS counts do not imply that
     * row, tank, pause, or completion state has remained unchanged.
     */
    fun reconcile(server: Trip, local: Trip): Trip {
        require(server.id == local.id) { "Trips must share an id." }
        return server.copy(
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
