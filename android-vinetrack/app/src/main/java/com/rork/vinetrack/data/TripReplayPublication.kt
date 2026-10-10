package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip

/** Replay replies must not replace fields owned by other live/offline Trip operations. */
internal object TripReplayPublication {
    fun metadata(server: Trip, local: Trip): Trip = if (!sameOwner(server, local)) local else local.copy(
        paddockId = server.paddockId, paddockName = server.paddockName, paddockIds = server.paddockIds,
        personName = server.personName, tripFunction = server.tripFunction, tripTitle = server.tripTitle,
        machineId = server.machineId, workTaskId = server.workTaskId, operatorUserId = server.operatorUserId,
        operatorCategoryId = server.operatorCategoryId, isPaused = server.isPaused,
        startEngineHours = server.startEngineHours, pauseTimestamps = server.pauseTimestamps,
        resumeTimestamps = server.resumeTimestamps, clientUpdatedAt = server.clientUpdatedAt,
    )

    fun seeding(server: Trip, local: Trip): Trip = if (!sameOwner(server, local)) local else
        local.copy(seedingDetails = server.seedingDetails, clientUpdatedAt = server.clientUpdatedAt)

    fun gps(server: Trip, local: Trip): Trip = if (!sameOwner(server, local) ||
        server.pathPoints.orEmpty().size < local.pathPoints.orEmpty().size) local else
        local.copy(pathPoints = server.pathPoints, totalDistance = server.totalDistance)

    fun rows(server: Trip, local: Trip): Trip = if (!sameOwner(server, local)) local else local.copy(
        completedPaths = server.completedPaths, skippedPaths = server.skippedPaths,
        sequenceIndex = server.sequenceIndex, currentRowNumber = server.currentRowNumber,
        nextRowNumber = server.nextRowNumber,
    )

    fun tanks(server: Trip, local: Trip): Trip = if (!sameOwner(server, local) ||
        local.tankSessions != server.tankSessions || local.activeTankNumber != server.activeTankNumber ||
        local.isFillingTank != server.isFillingTank || local.fillingTankNumber != server.fillingTankNumber) local else
        local.copy(tankSessions = server.tankSessions, activeTankNumber = server.activeTankNumber,
            isFillingTank = server.isFillingTank, fillingTankNumber = server.fillingTankNumber)

    private fun sameOwner(server: Trip, local: Trip): Boolean = server.id == local.id && server.vineyardId == local.vineyardId
}
