package com.rork.vinetrack.data.mapalignment

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Single decision point for "may the calibration wizard be left right now?".
 *
 * Reference points cost real walking, so every exit path has to ask the same
 * question. Before this existed the wizard's own Cancel/Discard actions were
 * confirmed, but the host's toolbar Back called the navigation callback
 * directly and system Back was not intercepted at all — two ways to silently
 * throw away a session's evidence.
 *
 * This is deliberately a tiny piece of shared state rather than a navigation
 * framework: the host owns it, the wizard keeps [hasReferencePoints] current,
 * and all three exit routes call [requestExit].
 *
 * It holds no draft, performs no navigation of its own and persists nothing —
 * it only decides whether an exit happens now or after confirmation.
 */
@Stable
class MapAlignmentExitGuard {

    /** True when leaving would discard collected evidence. */
    var hasReferencePoints: Boolean by mutableStateOf(false)
        private set

    private var pendingExit: (() -> Unit)? by mutableStateOf(null)

    /** True while the "Discard calibration?" confirmation is showing. */
    val isConfirmingDiscard: Boolean get() = pendingExit != null

    /** Keep the guard in step with the wizard's session draft. */
    fun onDraftChanged(draft: MapAlignmentDraft?) {
        hasReferencePoints = draft != null && draft.referencePoints.isNotEmpty()
    }

    /**
     * Ask to leave.
     *
     * With no evidence the exit runs immediately. Otherwise [exit] is held
     * until the operator confirms via [discard], and [keepCalibrating]
     * abandons it.
     *
     * @return true when [exit] already ran.
     */
    fun requestExit(exit: () -> Unit): Boolean {
        if (!hasReferencePoints) {
            exit()
            return true
        }
        pendingExit = exit
        return false
    }

    /** Dismiss the confirmation and stay in the wizard. */
    fun keepCalibrating() {
        pendingExit = null
    }

    /** Confirm the discard and run the held exit. */
    fun discard() {
        val exit = pendingExit
        pendingExit = null
        exit?.invoke()
    }
}
