package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip

/**
 * Warns when a spray trip is being driven down rows with no tank running.
 *
 * Without a running tank, rows aren't credited to a tank, and on planned routes
 * Android only auto-completes passes while a tank is running. Operators were left
 * ticking every row by hand with no explanation, so after [DELAY_MS] of confident
 * row driving the trip screen asks them to start the tank.
 */
object SprayNoTankWarning {
    const val DELAY_MS = 20_000L

    const val MESSAGE = "No tank running. Rows you spray now aren't recorded against a tank, " +
        "and planned rows won't tick off automatically. Tap Start Tank."

    data class Result(val show: Boolean, val since: Long?)

    fun isSprayTrip(trip: Trip): Boolean = trip.tripFunction == "spraying" || (trip.totalTanks ?: 0) > 0

    fun tankRunning(trip: Trip): Boolean = trip.activeTankNumber != null && !trip.isFillingTank

    /**
     * @param drivingRow the row lock is confident and the tractor is moving.
     * @param since when continuous no-tank row driving started, from the previous call.
     */
    fun evaluate(trip: Trip, drivingRow: Boolean, nowMs: Long, since: Long?): Result {
        if (!isSprayTrip(trip) || tankRunning(trip) || trip.isPaused || !trip.isActive) return Result(false, null)
        // Stopping (headland turn, refill stop) keeps the clock; only a running tank clears it.
        val start = since ?: if (drivingRow) nowMs else return Result(false, null)
        return Result(nowMs - start >= DELAY_MS, start)
    }
}
