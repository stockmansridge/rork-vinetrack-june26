package com.rork.vinetrack.data.mapalignment

import com.rork.vinetrack.data.PinLocationResult

/**
 * Owns the ONE live location subscription used by a calibration sampling attempt.
 *
 * ## Why this exists
 *
 * The first field test stalled at `Collecting GPS samples… 1 of 5` with
 * individually acceptable accuracy (±6.1 m, ±7.7 m). The thresholds were not
 * the problem. The sampler was polling a one-shot, pin-style location API,
 * which correctly returns its cached fix while that fix is still fresh — so the
 * same observation arrived again and again, and the dedupe rule correctly
 * refused to count it five times. Worse, a new asynchronous request was issued
 * roughly every second without awaiting the previous one, so requests
 * overlapped.
 *
 * The fix is to subscribe once to live high-accuracy updates for the duration
 * of an attempt, which is what actually produces independent observations of a
 * stationary point.
 *
 * ## The lifecycle rule
 *
 * Exactly one subscription may be active. [begin] always tears down any
 * existing subscription before opening a new one, so Retry cannot leave two
 * running, and [end] is idempotent so cancel/timeout/dispose/exit may all call
 * it freely. A fix delivered by a subscription that has already ended is
 * dropped: it belongs to a superseded attempt.
 *
 * Deliberately pure — [start]/[stop] are injected, so every lifecycle
 * transition is unit-testable with no Android location provider, no Compose
 * harness and no device. Nothing here is persisted.
 *
 * @param start opens the live subscription. Backed in production by the
 *   EXISTING `LocationTracker.startPinFixUpdates`, whose fixes have already
 *   passed `PinLocationFixValidator`.
 * @param stop closes it, backed by the existing `LocationTracker.stopPinFixUpdates`.
 */
class MapAlignmentLiveGpsSession(
    private val start: (onFix: (PinLocationResult) -> Unit) -> Unit,
    private val stop: () -> Unit,
) {

    /** Identity of the current subscription. Incremented on every [begin]. */
    private var generation: Int = 0

    /** True while a subscription is open. */
    var isActive: Boolean = false
        private set

    /** Diagnostics: how many subscriptions this session has opened and closed. */
    var startCount: Int = 0
        private set
    var stopCount: Int = 0
        private set

    /**
     * Open a live subscription, replacing any existing one first.
     *
     * Fixes are delivered to [onFix] only while this particular subscription is
     * the current one.
     */
    fun begin(onFix: (PinLocationResult) -> Unit) {
        // Replace, never stack: a Retry must not leave the previous
        // subscription feeding the superseded sample group.
        end()
        generation += 1
        val mine = generation
        isActive = true
        startCount += 1
        start { production ->
            if (isActive && generation == mine) onFix(production)
        }
    }

    /** Close the subscription if one is open. Safe to call repeatedly. */
    fun end() {
        if (!isActive) return
        isActive = false
        stopCount += 1
        stop()
    }
}
