package com.rork.vinetrack.data.mapalignment

/**
 * The calibration-only settling window for ONE sampling attempt.
 *
 * ## The field failure this exists to prevent
 *
 * Points 1 and 2 captured normally. The operator then walked ~200 m to the next
 * corner and started Point 3, standing still. Point 3 reported 7 samples over
 * 14 s, a representative accuracy of ±6.6 m, a worst reading of ±7.8 m — and a
 * spread of **203 m**, almost exactly the distance just walked.
 *
 * That was never an accuracy problem. Every reading was individually valid.
 * [com.rork.vinetrack.data.PinLocationFixValidator] legitimately admits a
 * production fix up to about five seconds old, so the very first callbacks of a
 * new subscription can deliver a still-fresh observation that was *generated*
 * while the operator was at, or walking from, the previous corner. Calibration
 * accepted it, because it passed production and was under 8 m. Once accepted it
 * stayed in the group, and [MapAlignmentGpsSampling.stabilityRadiusMetres]
 * measures the furthest sample from the representative position — so one
 * perfectly accurate reading of the WRONG PLACE poisoned the point permanently,
 * and Point 3 could never reach Stable without Retry.
 *
 * ## The rule
 *
 * Let the receiver establish the new stationary location first, then measure it.
 * For the first [MapAlignmentGpsRules.SETTLING_MILLIS] of each attempt,
 * observations are ignored for evidence — not because they are inaccurate, but
 * because they sit too close to the transition from the previous physical
 * location to belong to this one.
 *
 * ## Why observation time, not arrival time
 *
 * Simply waiting five seconds and then accepting whatever arrives would not fix
 * it: Android can deliver a batched or delayed observation whose callback lands
 * after the boundary but which was *generated* before it — the previous corner
 * again, through a different door. The boundary is therefore compared against
 * `QualifiedLocationFix.fixElapsedRealtimeNanos`, the time the platform stamped
 * onto the location itself.
 *
 * Both times come from the same monotonic clock family
 * (`SystemClock.elapsedRealtime*`), which is the only correct choice here: a
 * wall-clock change or NTP correction mid-attempt must not be able to move the
 * boundary or make a stale observation look eligible.
 *
 * ## Deliberately not a distance rule
 *
 * This never compares a fix against the previous reference coordinate. Large
 * movement between calibration points is expected and legitimate — the whole
 * task is to spread references across a vineyard. The only question asked is
 * *when this stationary attempt began* versus *when the observation was
 * generated*.
 *
 * Calibration-only and pure: no production threshold, message or code path is
 * involved, `PinLocationFixValidator.MAX_AGE_MS` is untouched, and nothing here
 * is persisted or reachable from pin capture, trips or row placement.
 */
data class MapAlignmentSettlingWindow(
    /** Monotonic time this attempt began, from `SystemClock.elapsedRealtimeNanos()`. */
    val attemptStartedElapsedRealtimeNanos: Long,
    /** Length of the window, in millis. Overridable for tests only. */
    val settlingMillis: Long = MapAlignmentGpsRules.SETTLING_MILLIS,
) {

    /**
     * The admission boundary on the monotonic observation clock. An observation
     * may contribute evidence only if it was generated at or after this.
     */
    val eligibleAfterElapsedRealtimeNanos: Long
        get() = attemptStartedElapsedRealtimeNanos + settlingMillis * NANOS_PER_MILLI

    /** True when the observation was generated at or after the boundary. */
    fun admits(fixElapsedRealtimeNanos: Long): Boolean =
        fixElapsedRealtimeNanos >= eligibleAfterElapsedRealtimeNanos

    /**
     * True when the observation predates the attempt itself — it cannot
     * describe this reference point under any interpretation.
     */
    fun precedesAttempt(fixElapsedRealtimeNanos: Long): Boolean =
        fixElapsedRealtimeNanos < attemptStartedElapsedRealtimeNanos

    /** True once the window has closed and normal collection may begin. */
    fun hasExpired(nowElapsedRealtimeNanos: Long): Boolean =
        nowElapsedRealtimeNanos >= eligibleAfterElapsedRealtimeNanos

    /** Millis left in the window, never negative. Display only. */
    fun remainingMillis(nowElapsedRealtimeNanos: Long): Long =
        ((eligibleAfterElapsedRealtimeNanos - nowElapsedRealtimeNanos) / NANOS_PER_MILLI)
            .coerceAtLeast(0L)

    /** Whole seconds left, rounded up, so a countdown never displays "0 s". */
    fun remainingSeconds(nowElapsedRealtimeNanos: Long): Int {
        val remaining = remainingMillis(nowElapsedRealtimeNanos)
        return ((remaining + 999L) / 1_000L).toInt()
    }

    companion object {
        private const val NANOS_PER_MILLI: Long = 1_000_000L

        /** A fresh window for an attempt starting now. */
        fun startingAt(nowElapsedRealtimeNanos: Long): MapAlignmentSettlingWindow =
            MapAlignmentSettlingWindow(attemptStartedElapsedRealtimeNanos = nowElapsedRealtimeNanos)
    }
}
