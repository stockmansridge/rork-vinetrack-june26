package com.rork.vinetrack.data.mapalignment

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Single decision point for "may the calibration wizard be left right now?".
 *
 * Reference points cost real walking, so every exit path has to ask the same
 * question. The host's toolbar Back, Android system Back and the wizard's own
 * Cancel actions all route through here, so no route can behave differently
 * from the others.
 *
 * ## Why this is no longer a discard guard
 *
 * It was written when the draft was memory-only: leaving genuinely destroyed
 * the evidence, so the only safe design was to block the exit behind a
 * "Discard calibration?" confirmation. Now that drafts are autosaved to this
 * installation ([MapAlignmentLocalStore]), that wording is not merely
 * unnecessary — it is **false**. Telling an operator their work is about to be
 * discarded when it is already on disk trains them to fear the Back button, and
 * the field report was exactly that: an accidental exit felt like losing three
 * points that were, in fact, safe.
 *
 * So leaving is now non-destructive by construction. The confirmation still
 * appears when there is progress, but it exists to *inform and reassure*, not
 * to protect: it tells the operator their completed points are saved and they
 * can continue later. Neither action on it deletes anything.
 *
 * Actual destruction requires an explicit, separately confirmed **Delete
 * draft** or **Start over** — never an exit.
 *
 * ## What it does not do
 *
 * It holds no draft, performs no navigation, and writes nothing. It only
 * decides whether an exit happens immediately or after an informational
 * confirmation, and reports which wording that confirmation should carry.
 */
@Stable
class MapAlignmentExitGuard {

    /** True when there is autosaved progress worth mentioning on the way out. */
    var hasReferencePoints: Boolean by mutableStateOf(false)
        private set

    /**
     * True when the operator is part-way through a GPS sampling attempt that
     * cannot be resumed exactly.
     *
     * A partial sample group is deliberately never persisted — see
     * [MapAlignmentPendingReference] — so this one unfinished reading will
     * restart on resume. The operator is told that plainly rather than
     * discovering it later.
     */
    var hasUnfinishedSampling: Boolean by mutableStateOf(false)
        private set

    private var pendingExit: (() -> Unit)? by mutableStateOf(null)

    /** True while the "Leave calibration?" confirmation is showing. */
    val isConfirmingExit: Boolean get() = pendingExit != null

    /** Keep the guard in step with the wizard's current draft. */
    fun onDraftChanged(draft: MapAlignmentDraft?, hasPendingReference: Boolean = false) {
        hasReferencePoints =
            (draft != null && draft.referencePoints.isNotEmpty()) || hasPendingReference
    }

    /**
     * Record whether an incomplete GPS sample group is currently running, so
     * the confirmation can be explicit about the one thing that will restart.
     */
    fun onSamplingChanged(isSampling: Boolean) {
        hasUnfinishedSampling = isSampling
    }

    /**
     * Ask to leave.
     *
     * With nothing collected the exit runs immediately — there is nothing to
     * reassure the operator about. Otherwise [exit] is held until they choose
     * [leaveAndContinueLater], and [keepCalibrating] abandons it.
     *
     * Either way the draft stays on disk: this returns the operator to the
     * previous screen, it never deletes.
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

    /**
     * Leave, keeping the autosaved draft for later.
     *
     * Named for what it does. There is deliberately no `discard()` on this
     * type any more, so no exit route can be wired to destruction by mistake.
     */
    fun leaveAndContinueLater() {
        val exit = pendingExit
        pendingExit = null
        exit?.invoke()
    }

    /** Body text for the confirmation, matching what is actually true. */
    fun exitMessage(): String {
        val saved = "Your completed calibration progress has been saved on this Android device.\n\n" +
            "You can continue from this point later."
        if (!hasUnfinishedSampling) return saved
        return "Completed reference points have been saved. The current unfinished GPS " +
            "reading will restart when you resume.\n\n" +
            "You can continue from this point later."
    }
}
