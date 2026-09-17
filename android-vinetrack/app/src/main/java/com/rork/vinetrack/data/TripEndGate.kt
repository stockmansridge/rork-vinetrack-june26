package com.rork.vinetrack.data

/**
 * Why a manual End Trip request cannot proceed yet.
 *
 * Every case is a real product prerequisite the operator can clear
 * themselves, and each carries the exact action required. There is
 * deliberately no case for planned-path state — see [TripEndGate].
 */
sealed interface TripEndBlocker {
    /** A spray tank is still open and must be closed to record its end. */
    data class ActiveTank(val tankNumber: Int) : TripEndBlocker

    /** A fill timer is still running and would be left without an end time. */
    data class FillingTank(val tankNumber: Int?) : TripEndBlocker

    /** Operator-facing explanation of what is holding the trip open. */
    val reason: String
        get() = when (this) {
            is ActiveTank -> "Tank $tankNumber is still running."
            is FillingTank -> tankNumber
                ?.let { "The fill timer for Tank $it is still running." }
                ?: "A tank fill timer is still running."
        }

    /** The exact action required to clear this blocker. */
    val requiredAction: String
        get() = when (this) {
            is ActiveTank -> "Tap End Tank to close it, then end the trip."
            is FillingTank -> "Tap Stop Fill to finish the fill, then end the trip."
        }

    /** Single message for a dialog: never just "can't end trip". */
    val message: String get() = "$reason $requiredAction"
}

/** The result of asking whether a trip may be ended right now. */
sealed interface TripEndDecision {
    data object Allowed : TripEndDecision
    data class Blocked(val blocker: TripEndBlocker) : TripEndDecision

    val isAllowed: Boolean get() = this is Allowed
}

/**
 * The single authority on whether a manual End Trip may proceed.
 *
 * ## Why this exists
 *
 * Free Drive trips intentionally carry no planned path: the planned path is
 * null, the row sequence is empty, the sequence index is 0/0, planned
 * progress is 0% and the accumulated planned-path distance stays at 0 m
 * because there is no planned row to accumulate *against*. Those zeroes
 * describe the absent plan, not the trip — a Free Drive trip with 6,655
 * recorded GPS points and 29 completed paths reports every one of them.
 *
 * This gate therefore takes **no** planned-path input at all. Planned path,
 * row sequence, sequence index, path length, planned progress, accumulated
 * planned distance, current row, row lock, corridor status, GPS accuracy and
 * speed are all absent from [evaluate] by design, so no future edit can
 * reintroduce a planned-path or movement precondition on manual termination
 * without deleting a test. Ending a trip is an act of operator intent; it is
 * not a reward for completing a route.
 *
 * The only things that may hold a trip open are unfinished *records* that
 * ending would corrupt — an open tank session or a running fill timer — and
 * both are clearable by the operator from the tank controls.
 */
object TripEndGate {

    /**
     * Decide whether a manual End Trip may proceed.
     *
     * @param activeTankNumber the currently open spray tank, if any.
     * @param isFillingTank whether a fill timer is currently running.
     * @param fillingTankNumber the tank the fill timer belongs to, if known.
     */
    fun evaluate(
        activeTankNumber: Int?,
        isFillingTank: Boolean,
        fillingTankNumber: Int?,
    ): TripEndDecision {
        if (activeTankNumber != null) {
            return TripEndDecision.Blocked(TripEndBlocker.ActiveTank(activeTankNumber))
        }
        if (isFillingTank) {
            return TripEndDecision.Blocked(TripEndBlocker.FillingTank(fillingTankNumber))
        }
        return TripEndDecision.Allowed
    }
}
