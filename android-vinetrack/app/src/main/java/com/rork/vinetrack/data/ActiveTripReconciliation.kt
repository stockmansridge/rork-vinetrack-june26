package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip

/** Merges active local progress with the matching active server trip. */
object ActiveTripReconciliation {
    /**
     * The longer full-resolution route and its matching distance win. Runtime
     * progress remains local because server progress uploads are throttled.
     */
    fun mergeProgress(server: Trip, local: Trip): Trip {
        require(server.id == local.id) { "Trips must share an id." }
        val useLocalPath = local.pathPoints.orEmpty().size >= server.pathPoints.orEmpty().size
        return server.copy(
            pathPoints = if (useLocalPath) local.pathPoints else server.pathPoints,
            totalDistance = if (useLocalPath) local.totalDistance else server.totalDistance,
            isPaused = local.isPaused,
            pauseTimestamps = local.pauseTimestamps,
            resumeTimestamps = local.resumeTimestamps,
            completedPaths = local.completedPaths,
            skippedPaths = local.skippedPaths,
            trackingPattern = local.trackingPattern,
            rowSequence = local.rowSequence,
            sequenceIndex = local.sequenceIndex,
            currentRowNumber = local.currentRowNumber,
            nextRowNumber = local.nextRowNumber,
            tankSessions = local.tankSessions,
            activeTankNumber = local.activeTankNumber,
            isFillingTank = local.isFillingTank,
            fillingTankNumber = local.fillingTankNumber,
            startEngineHours = local.startEngineHours,
            endEngineHours = local.endEngineHours,
        )
    }
}
