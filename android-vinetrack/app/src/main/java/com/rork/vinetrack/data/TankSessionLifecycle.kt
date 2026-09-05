package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip

data class TankStartResult(
    val trip: Trip,
    val tankNumber: Int,
    val tankSessionId: String,
    val operationTimestamp: String,
)

/** Deterministic production transitions for operator-driven tank spraying. */
object TankSessionLifecycle {
    fun start(
        trip: Trip,
        timestamp: String,
        currentRow: Double?,
        plannedTankNumbers: List<Int>? = null,
        makeId: () -> String = { java.util.UUID.randomUUID().toString() },
    ): Trip = startResult(trip, timestamp, currentRow, plannedTankNumbers, makeId)?.trip ?: trip

    /** Returns the production-selected tank/session identity; callers must not recalculate either value. */
    fun startResult(
        trip: Trip,
        timestamp: String,
        currentRow: Double?,
        plannedTankNumbers: List<Int>? = null,
        makeId: () -> String = { java.util.UUID.randomUUID().toString() },
    ): TankStartResult? {
        if (trip.activeTankNumber != null) return null
        val target = startTarget(trip, plannedTankNumbers) ?: return null

        val sessions = trip.tankSessions.toMutableList()
        val sessionId: String
        if (target.fillSessionIndex >= 0) {
            val existing = sessions[target.fillSessionIndex]
            sessionId = existing.id
            sessions[target.fillSessionIndex] = existing.copy(
                startTime = timestamp,
                startRow = currentRow,
                endTime = null,
                endRow = null,
                fillEndTime = existing.fillEndTime ?: timestamp,
            )
        } else {
            sessionId = makeId()
            sessions.add(
                TankSession(
                    id = sessionId,
                    tankNumber = target.tankNumber,
                    startTime = timestamp,
                    startRow = currentRow,
                ),
            )
        }
        val updated = trip.copy(
            tankSessions = sessions,
            activeTankNumber = target.tankNumber,
            isFillingTank = false,
            fillingTankNumber = null,
        )
        return TankStartResult(updated, target.tankNumber, sessionId, timestamp)
    }

    fun end(trip: Trip, timestamp: String, currentRow: Double?): Trip {
        val activeTankNumber = trip.activeTankNumber ?: return trip
        val sessionIndex = trip.tankSessions.indexOfLast {
            it.tankNumber == activeTankNumber && it.endTime == null
        }
        if (sessionIndex < 0) return trip

        val sessions = trip.tankSessions.toMutableList()
        sessions[sessionIndex] = sessions[sessionIndex].copy(endTime = timestamp, endRow = currentRow)
        return trip.copy(tankSessions = sessions, activeTankNumber = null)
    }

    private fun startTarget(trip: Trip, plannedTankNumbers: List<Int>?): StartTarget? {
        if (plannedTankNumbers == null) {
            val fillIndex = reusableFillOnlySessionIndex(trip)
            val tankNumber = if (fillIndex >= 0) {
                trip.tankSessions[fillIndex].tankNumber
            } else {
                (trip.tankSessions.maxOfOrNull { it.tankNumber } ?: 0) + 1
            }
            return StartTarget(tankNumber, fillIndex)
        }

        val planned = plannedTankNumbers.filter { it >= 1 }.distinct().sorted()
        val completed = trip.tankSessions.filter { it.endTime != null }.mapTo(mutableSetOf()) { it.tankNumber }
        val incomplete = planned.filterNot { it in completed }
        if (incomplete.isEmpty()) return null

        val fillingNumber = trip.fillingTankNumber
        if (fillingNumber != null && fillingNumber in incomplete) {
            val fillIndex = trip.tankSessions.indexOfLast {
                it.tankNumber == fillingNumber && it.isFillOnly()
            }
            if (fillIndex >= 0) return StartTarget(fillingNumber, fillIndex)
        }
        incomplete.forEach { tankNumber ->
            val fillIndex = trip.tankSessions.indexOfLast {
                it.tankNumber == tankNumber && it.isFillOnly()
            }
            if (fillIndex >= 0) return StartTarget(tankNumber, fillIndex)
        }
        return StartTarget(incomplete.first(), -1)
    }

    private fun reusableFillOnlySessionIndex(trip: Trip): Int {
        val fillingNumber = trip.fillingTankNumber
        if (fillingNumber != null) {
            val matching = trip.tankSessions.indexOfLast { it.tankNumber == fillingNumber && it.isFillOnly() }
            if (matching >= 0) return matching
        }
        return trip.tankSessions.indexOfLast { it.isFillOnly() }
    }

    private fun TankSession.isFillOnly(): Boolean =
        fillStartTime != null && endTime == null && startRow == null

    private data class StartTarget(val tankNumber: Int, val fillSessionIndex: Int)
}
