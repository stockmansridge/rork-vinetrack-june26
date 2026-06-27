package com.rork.vinetrack.data

import kotlin.math.abs
import kotlin.math.min

/**
 * Active-trip row-lock stability state machine.
 *
 * Pure, backend-neutral port of the iOS `TripTrackingService.updatePathLock`
 * logic. Vines physically prevent a tractor from changing rows mid-pass, so we
 * hold the lock through brief out-of-corridor GPS blips and only switch after
 * sustained evidence the operator is genuinely in a new path.
 *
 * The caller resolves the live driving path (an X.5 number, e.g. 19.5) and
 * whether the fix is inside the row corridor from block geometry, then feeds
 * each fix here. We expose the currently locked path plus a 0.0\u20131.0 confidence
 * that saturates after ~10s of continuous lock \u2014 matching iOS so that the same
 * `confidence >= 0.6` "confident" threshold can gate any future write.
 *
 * This foundation only tracks state; it never writes `driving_row_number`.
 */
class RowLockTracker {

    private var lockedPath: Double? = null
    private var lockedPathSince: Long? = null
    private var lastInCorridorOnLockedAt: Long? = null
    private var candidatePath: Double? = null
    private var candidateSince: Long? = null

    /** Currently locked driving path (X.5), or null until the first solid lock. */
    var drivingPathNumber: Double? = null
        private set

    /** Lock confidence in [0.0, 1.0]; saturates after ~10s of continuous lock. */
    var confidence: Double = 0.0
        private set

    /** True when [confidence] meets the iOS "confident" threshold. */
    val isConfident: Boolean get() = confidence >= CONFIDENT_THRESHOLD

    /**
     * Feed one resolved GPS fix.
     *
     * @param livePath the X.5 driving path nearest the current fix.
     * @param inCorridor true when the fix is within ~half a row spacing of the
     *   path centreline (i.e. genuinely inside the row corridor).
     */
    fun update(livePath: Double, inCorridor: Boolean, nowMs: Long = System.currentTimeMillis()) {
        val locked = lockedPath
        when {
            locked == null -> {
                // No lock yet \u2014 first solid in-corridor sample claims it.
                if (inCorridor) {
                    lockedPath = livePath
                    lockedPathSince = nowMs
                    lastInCorridorOnLockedAt = nowMs
                    clearCandidate()
                }
            }

            abs(locked - livePath) < 0.01 -> {
                // Still on the locked path; refresh corridor timestamp.
                if (inCorridor) lastInCorridorOnLockedAt = nowMs
                clearCandidate()
            }

            inCorridor -> {
                // A different in-corridor path. Only switch after a sustained
                // grace period off the old corridor AND dwell on the new one.
                val releasedAgo = lastInCorridorOnLockedAt?.let { nowMs - it } ?: Long.MAX_VALUE
                val cand = candidatePath
                if (cand != null && abs(cand - livePath) < 0.01) {
                    // same candidate \u2014 keep its start time
                } else {
                    candidatePath = livePath
                    candidateSince = nowMs
                }
                val dwell = candidateSince?.let { nowMs - it } ?: 0L
                if (releasedAgo >= LOCK_RELEASE_GRACE_MS && dwell >= LOCK_SWITCH_DWELL_MS) {
                    lockedPath = livePath
                    lockedPathSince = nowMs
                    lastInCorridorOnLockedAt = nowMs
                    clearCandidate()
                }
            }
            // Else: out of corridor and not on the locked row \u2014 hold the lock.
        }

        drivingPathNumber = lockedPath
        val since = lockedPathSince
        confidence = if (since != null) {
            min(1.0, (nowMs - since) / LOCK_SATURATION_MS)
        } else {
            0.0
        }
    }

    /** Reset all lock state (call on trip start/end/delete). */
    fun reset() {
        lockedPath = null
        lockedPathSince = null
        lastInCorridorOnLockedAt = null
        clearCandidate()
        drivingPathNumber = null
        confidence = 0.0
    }

    private fun clearCandidate() {
        candidatePath = null
        candidateSince = null
    }

    companion object {
        /** iOS "confident" threshold for trusting the lock. */
        const val CONFIDENT_THRESHOLD = 0.6

        /** Dwell required on a new candidate path before switching (iOS: 4s). */
        private const val LOCK_SWITCH_DWELL_MS = 4_000L

        /** Grace off the old corridor before a switch is allowed (iOS: 3s). */
        private const val LOCK_RELEASE_GRACE_MS = 3_000L

        /** Continuous lock duration at which confidence hits 1.0 (iOS: 10s). */
        private const val LOCK_SATURATION_MS = 10_000.0
    }
}
