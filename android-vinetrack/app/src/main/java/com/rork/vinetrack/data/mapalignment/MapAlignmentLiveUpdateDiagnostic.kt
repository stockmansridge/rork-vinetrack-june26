package com.rork.vinetrack.data.mapalignment

/**
 * Tracks whether the calibration live GPS subscription is DELIVERING, for the
 * current sampling attempt only.
 *
 * Field motivation: when sampling sits at `0 of 5`, two very different things
 * look identical on screen — the receiver is delivering updates that are not
 * yet good enough, or Android is delivering nothing at all. The first is normal
 * and only needs patience; the second is a configuration or receiver problem.
 * This distinguishes them.
 *
 * It counts CALLBACK ARRIVAL, not accepted samples. A callback that is later
 * classified TooImprecise, Inaccurate, Stale, Invalid or Duplicate is still
 * proof the subscription is alive, so it counts here. Deriving this from
 * [MapAlignmentGpsSampling.sampleCount] would be wrong for exactly that reason.
 *
 * Times are Android monotonic elapsed-realtime millis (`SystemClock
 * .elapsedRealtime()`), supplied by the caller. Wall-clock is unusable: an NTP
 * correction mid-attempt could invent or erase a silent gap.
 *
 * This type is display state only. It is immutable and pure, it never touches
 * location, sampling or the subscription, and nothing reads it back into a
 * decision — no restart, no stop, no accept, no reject, no change to the
 * 45 s timeout or any sampling threshold.
 */
data class MapAlignmentLiveUpdateDiagnostic(
    /** Live callbacks received during this attempt, whatever their outcome. */
    val callbackCount: Int,
    /** Monotonic time the subscription for this attempt started. */
    val attemptStartedElapsedMillis: Long,
    /** Monotonic time of the most recent callback, or null if none has arrived. */
    val lastCallbackElapsedMillis: Long?,
) {

    /** True once the subscription has proven it can deliver at all. */
    val hasReceivedAnyUpdate: Boolean get() = callbackCount > 0

    /**
     * Record one live callback. Called for EVERY arrival, before any
     * calibration judgement, so rejected and duplicate fixes reset the timer.
     */
    fun onCallbackReceived(nowElapsedMillis: Long): MapAlignmentLiveUpdateDiagnostic = copy(
        callbackCount = callbackCount + 1,
        lastCallbackElapsedMillis = nowElapsedMillis,
    )

    /** Millis since the last callback, or since the attempt started if none. */
    fun silenceMillis(nowElapsedMillis: Long): Long {
        val since = lastCallbackElapsedMillis ?: attemptStartedElapsedMillis
        // A monotonic clock cannot go backwards, but never report a negative.
        return (nowElapsedMillis - since).coerceAtLeast(0L)
    }

    /**
     * The quiet diagnostic line, or null when updates are arriving normally.
     *
     * Deliberately unalarming, and never shown during the first
     * [QUIET_PERIOD_MILLIS] — a receiver taking a few seconds to produce its
     * first fix is ordinary. The count keeps rising while the silence lasts and
     * the line disappears as soon as any callback arrives.
     */
    fun message(nowElapsedMillis: Long): String? {
        val silence = silenceMillis(nowElapsedMillis)
        if (silence < QUIET_PERIOD_MILLIS) return null
        val seconds = silence / 1_000L
        return if (hasReceivedAnyUpdate) {
            "No new GPS update received for $seconds s. Waiting for Android location services…"
        } else {
            "No GPS updates received for $seconds s. Waiting for Android location services…"
        }
    }

    companion object {

        /** How long silence must last before the line appears, in millis. */
        const val QUIET_PERIOD_MILLIS: Long = 5_000L

        /** Start of a fresh attempt: no callbacks yet. */
        fun started(nowElapsedMillis: Long): MapAlignmentLiveUpdateDiagnostic =
            MapAlignmentLiveUpdateDiagnostic(
                callbackCount = 0,
                attemptStartedElapsedMillis = nowElapsedMillis,
                lastCallbackElapsedMillis = null,
            )
    }
}
