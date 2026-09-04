package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip

/** Local-first activation contract for an already-downloaded Not Started trip. */
object SavedTripActivation {
    /** Returns a fresh active snapshot, or null when this is not an unstarted placeholder. */
    fun activate(trip: Trip, operationalStart: String): Trip? {
        val isUnstarted = !trip.isActive &&
            trip.endTime == null &&
            trip.pathPoints.orEmpty().isEmpty() &&
            (trip.totalDistance ?: 0.0) == 0.0 &&
            trip.completedPaths.orEmpty().isEmpty() &&
            trip.skippedPaths.orEmpty().isEmpty() &&
            trip.tankSessions.isEmpty()
        if (!isUnstarted) return null
        return trip.copy(
            startTime = operationalStart,
            endTime = null,
            isActive = true,
            isPaused = false,
            totalDistance = 0.0,
            pathPoints = emptyList(),
            completedPaths = emptyList(),
            skippedPaths = emptyList(),
            pauseTimestamps = emptyList(),
            resumeTimestamps = emptyList(),
            tankSessions = emptyList(),
            activeTankNumber = null,
            isFillingTank = false,
            fillingTankNumber = null,
            clientUpdatedAt = operationalStart,
        )
    }
}
