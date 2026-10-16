package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.TripOccurrenceCoverage

/** Prospective completion-time evidence, not inferred ranges, planned tanks or historical GPS. */
object TankPathAttribution {
    fun activeSession(trip: Trip): TankSession? {
        if (!trip.isActive || trip.endTime != null || trip.isPaused || trip.isFillingTank) return null
        val number = trip.activeTankNumber ?: return null
        val open = trip.tankSessions.filter { it.startTime != null && TankSessionLifecycle.isOpenSpray(it) }
        val session = open.singleOrNull()?.takeIf { it.tankNumber == number } ?: return null
        if (trip.tankSessions.count { it.id == session.id || it.tankNumber == number } != 1) return null
        return session
    }

    /** An append-only completion event link. Undoing guidance never erases recorded spraying evidence. */
    fun recordCompletion(trip: Trip, path: Double, atMillis: Long = System.currentTimeMillis()): Trip {
        if (trip.coverageBasis != TripOccurrenceCoverage.Basis.LEGACY || !path.isFinite() ||
            trip.paddockIds.size > 1 || trip.rowSequence.count { it == path } != 1) return trip
        val session = activeSession(trip) ?: return trip
        val start = session.startEpochMs ?: return trip
        if (atMillis < start || path in session.pathsCovered) return trip
        return trip.copy(tankSessions = trip.tankSessions.map {
            if (it.id == session.id) it.copy(pathsCovered = it.pathsCovered + path) else it
        })
    }
}
