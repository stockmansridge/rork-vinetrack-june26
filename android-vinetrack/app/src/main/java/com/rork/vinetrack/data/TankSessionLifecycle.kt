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
    /** Fill timestamps alone never admit the first recording start. Existing started/ended sessions stay compatible. */
    fun requiresFirstReview(trip: Trip): Boolean =
        (trip.tripFunction == "spraying" || (trip.totalTanks ?: 0) > 0) && trip.activeTankNumber == null &&
            trip.tankSessions.none { it.endTime != null || (it.startTime != null && isOpenSpray(it)) }

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
        if (!trip.isActive || trip.endTime != null || trip.activeTankNumber != null ||
            trip.tankSessions.any(::isOpenSpray)) return null
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
        if (!trip.isActive || trip.endTime != null) return trip
        val activeTankNumber = trip.activeTankNumber ?: return trip
        val session = trip.tankSessions.filter(::isOpenSpray).singleOrNull()
            ?.takeIf { it.tankNumber == activeTankNumber } ?: return trip
        if (trip.tankSessions.count { it.id == session.id || it.tankNumber == activeTankNumber } != 1) return trip
        val sessionIndex = trip.tankSessions.indexOfFirst { it.id == session.id }

        val sessions = trip.tankSessions.toMutableList()
        sessions[sessionIndex] = sessions[sessionIndex].copy(endTime = timestamp, endRow = currentRow)
        val hasOpenFill = sessions.any { it.fillStartTime != null && it.fillEndTime == null }
        return trip.copy(
            tankSessions = sessions, activeTankNumber = null,
            isFillingTank = if (hasOpenFill) trip.isFillingTank else false,
            fillingTankNumber = if (hasOpenFill) trip.fillingTankNumber else null,
        )
    }

    /** Repair only an ended active tank with no other open spray or fill; preserve every session. */
    fun reconciled(trip: Trip): Trip {
        val number = trip.activeTankNumber ?: return trip
        if (trip.tankSessions.none { it.tankNumber == number && it.endTime != null } ||
            trip.tankSessions.any { isOpenSpray(it) || (it.fillStartTime != null && it.fillEndTime == null) }) return trip
        return trip.copy(activeTankNumber = null, isFillingTank = false, fillingTankNumber = null)
    }

    /**
     * True for a tank that was (or is being) sprayed, as opposed to one that was
     * only filled. Same rule [isOpenSpray] uses for running tanks (iOS parity).
     */
    fun wasSprayed(session: TankSession): Boolean {
        if (session.fillStartTime == null || session.startRow != null || session.startTime == null) return true
        val fillEnd = session.fillEndEpochMs ?: return false
        return (session.startEpochMs ?: Long.MIN_VALUE) >= fillEnd
    }

    /**
     * End Trip closure for tanks that were filled but never sprayed (iOS parity,
     * `closingFillOnlySessionsBeforeTripEnd`). Such a session has a start time and
     * no end time, which the server and Portal treat as an unfinished tank. It is
     * closed at its own recorded fill end (never a new time), so the fill
     * duration is kept and it stays visibly fill-only (no start row). A running
     * fill is never closed here. Call only once the End gate has passed.
     */
    fun closingFillOnlySessionsBeforeTripEnd(trip: Trip): Trip {
        if (!trip.isActive || !trip.endTime.isNullOrBlank() || trip.isFillingTank) return trip
        var changed = false
        val sessions = trip.tankSessions.map { session ->
            val fillEnd = session.fillEndEpochMs
            val start = session.startEpochMs
            if (session.endTime == null && !wasSprayed(session) &&
                fillEnd != null && start != null && fillEnd >= start) {
                changed = true
                session.copy(endTime = session.fillEndTime)
            } else session
        }
        return if (changed) trip.copy(tankSessions = sessions) else trip
    }

    /**
     * True when ending now would save a spray Trip with planned tanks but no
     * sprayed tank. The server's `admin_end_trip_after_tanks` refuses that, so
     * the UI asks the operator to confirm instead of ending silently.
     */
    fun endWouldRecordNoSprayedTank(trip: Trip): Boolean =
        trip.tripFunction == "spraying" && (trip.totalTanks ?: 0) > 0 &&
            trip.tankSessions.none(::wasSprayed)

    fun isOpenSpray(session: TankSession): Boolean {
        if (session.endTime != null) return false
        if (session.fillStartTime == null || session.startRow != null || session.startTime == null) return true
        val fillEnd = session.fillEndEpochMs ?: return false
        return (session.startEpochMs ?: Long.MIN_VALUE) >= fillEnd
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
