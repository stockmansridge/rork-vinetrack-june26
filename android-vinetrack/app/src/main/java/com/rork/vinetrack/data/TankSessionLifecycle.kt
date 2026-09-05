package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip

/** Deterministic production transitions for operator-driven tank spraying. */
object TankSessionLifecycle {
    fun start(
        trip: Trip,
        timestamp: String,
        currentRow: Double?,
        makeId: () -> String = { java.util.UUID.randomUUID().toString() },
    ): Trip {
        if (trip.activeTankNumber != null) return trip

        val sessions = trip.tankSessions.toMutableList()
        val fillIndex = reusableFillOnlySessionIndex(trip)
        val activeTankNumber: Int
        if (fillIndex >= 0) {
            val existing = sessions[fillIndex]
            sessions[fillIndex] = existing.copy(
                startTime = timestamp,
                startRow = currentRow,
                endTime = null,
                endRow = null,
                fillEndTime = existing.fillEndTime ?: timestamp,
            )
            activeTankNumber = existing.tankNumber
        } else {
            activeTankNumber = (sessions.maxOfOrNull { it.tankNumber } ?: 0) + 1
            sessions.add(
                TankSession(
                    id = makeId(),
                    tankNumber = activeTankNumber,
                    startTime = timestamp,
                    startRow = currentRow,
                ),
            )
        }
        return trip.copy(
            tankSessions = sessions,
            activeTankNumber = activeTankNumber,
            isFillingTank = false,
            fillingTankNumber = null,
        )
    }

    fun end(trip: Trip, timestamp: String, currentRow: Double?): Trip {
        val activeTankNumber = trip.activeTankNumber ?: return trip
        val sessionIndex = trip.tankSessions.indexOfLast {
            it.tankNumber == activeTankNumber && it.endTime == null && it.startRow != null
        }
        if (sessionIndex < 0) return trip

        val sessions = trip.tankSessions.toMutableList()
        sessions[sessionIndex] = sessions[sessionIndex].copy(endTime = timestamp, endRow = currentRow)
        return trip.copy(tankSessions = sessions, activeTankNumber = null)
    }

    private fun reusableFillOnlySessionIndex(trip: Trip): Int {
        fun TankSession.isFillOnly(): Boolean = fillStartTime != null && endTime == null && startRow == null
        val fillingNumber = trip.fillingTankNumber
        if (fillingNumber != null) {
            val matching = trip.tankSessions.indexOfLast { it.tankNumber == fillingNumber && it.isFillOnly() }
            if (matching >= 0) return matching
        }
        return trip.tankSessions.indexOfLast { it.isFillOnly() }
    }
}
