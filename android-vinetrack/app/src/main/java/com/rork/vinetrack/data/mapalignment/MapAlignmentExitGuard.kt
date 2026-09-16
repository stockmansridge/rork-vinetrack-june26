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
 * ## Reassurance has to be earned
 *
 * The one thing that makes a non-destructive exit safe is that the draft is
 * genuinely on disk. So this guard tracks whether the LATEST autosave actually
 * succeeded ([MapAlignmentDraftPersistence]) and refuses to offer the
 * reassuring leave path while it did not. A dialog that says "your progress has
 * been saved" when the write failed is worse than no dialog: it converts a
 * recoverable problem into a confidently lost vineyard walk. In that state the
 * operator is told the truth and offered a retry instead of a way out.
 *
 * ## What it does not do
 *
 * It holds no draft, performs no navigation, and writes nothing itself. It only
 * decides whether an exit happens immediately, after an informational
 * confirmation, or not yet — and reports which wording that confirmation
 * should carry. The retry it offers calls back into the caller's own persist
 * operation; the guard never touches storage.
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

    /**
     * True when the operator has a checkpointed GPS-complete reference whose
     * image point still needs marking.
     */
    var hasPendingCheckpoint: Boolean by mutableStateOf(false)
        private set

    /**
     * Whether the LATEST draft change is confirmed on disk.
     *
     * The in-memory draft and the stored draft are deliberately distinct ideas
     * here. Holding four reference points in memory proves nothing about what
     * survives the app being killed, and this feature exists precisely because
     * an operator lost work they believed was safe.
     */
    var persistence: MapAlignmentDraftPersistence by mutableStateOf(
        MapAlignmentDraftPersistence.Saved,
    )
        private set

    private var pendingExit: (() -> Unit)? by mutableStateOf(null)

    /** True while either exit confirmation is showing. */
    val isConfirmingExit: Boolean get() = pendingExit != null

    /**
     * Which confirmation to show, or null when none is pending.
     *
     * The failed-save variant deliberately has no "leave" action at all — see
     * [MapAlignmentExitConfirmation].
     */
    val confirmation: MapAlignmentExitConfirmation?
        get() = when {
            pendingExit == null -> null
            persistence == MapAlignmentDraftPersistence.Saved ->
                MapAlignmentExitConfirmation.Leave
            else -> MapAlignmentExitConfirmation.SaveFailed
        }

    /** Keep the guard in step with the wizard's current draft. */
    fun onDraftChanged(draft: MapAlignmentDraft?, hasPendingReference: Boolean = false) {
        hasReferencePoints =
            (draft != null && draft.referencePoints.isNotEmpty()) || hasPendingReference
        hasPendingCheckpoint = hasPendingReference
    }

    /**
     * Record the result of an autosave.
     *
     * Called with the Boolean the local store ACTUALLY returned, not with an
     * assumption. A false result is what stops the reassuring exit path being
     * offered.
     */
    fun onPersistResult(succeeded: Boolean) {
        persistence = if (succeeded) {
            MapAlignmentDraftPersistence.Saved
        } else {
            MapAlignmentDraftPersistence.SaveFailed
        }
    }

    /** Mark the in-memory draft as changed but not yet written. */
    fun onUnsavedChange() {
        if (persistence == MapAlignmentDraftPersistence.Saved) {
            persistence = MapAlignmentDraftPersistence.UnsavedChanges
        }
    }

    /**
     * Retry the failed autosave, using the caller's own persist operation.
     *
     * On success the guard returns to its normal saved state and the held exit
     * becomes available through the ordinary leave confirmation. On failure the
     * operator stays exactly where they are, with the evidence still in memory
     * and the retry still available.
     *
     * @return whether the retry succeeded.
     */
    fun retrySave(persist: () -> Boolean): Boolean {
        val succeeded = runCatching(persist).getOrDefault(false)
        onPersistResult(succeeded)
        return succeeded
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

    /** Title for whichever confirmation is showing. */
    fun confirmationTitle(): String = when (confirmation) {
        MapAlignmentExitConfirmation.SaveFailed -> SAVE_FAILED_TITLE
        else -> LEAVE_TITLE
    }

    /**
     * Body text for the confirmation, matching what is actually true.
     *
     * Every branch here is a statement of fact about disk, which is why the
     * failed case gets its own wording rather than a softened version of the
     * reassuring one.
     */
    fun exitMessage(): String {
        if (persistence != MapAlignmentDraftPersistence.Saved) return saveFailedMessage()
        if (hasUnfinishedSampling) {
            return "Completed reference points have been saved. The current unfinished GPS " +
                "reading will restart when you resume.\n\n" +
                "You can continue from this point later."
        }
        return "Your completed calibration progress has been saved on this Android device.\n\n" +
            "You can continue from this point later."
    }

    /**
     * Body text when the latest autosave did not reach disk.
     *
     * Deliberately says the LATEST progress could not be saved, not that
     * nothing is saved: an earlier draft usually is on disk, and telling an
     * operator their whole calibration is gone when three points are safely
     * stored would send them off to re-walk work they still have.
     */
    fun saveFailedMessage(): String =
        "VineTrack could not save your latest calibration progress on this Android device." +
            "\n\nStay in the calibration and try again before leaving so your completed " +
            "reference points are not lost."

    companion object {
        const val LEAVE_TITLE: String = "Leave calibration?"
        const val SAVE_FAILED_TITLE: String = "Progress could not be saved"
        const val RETRY_ACTION_LABEL: String = "Try saving again"
        const val KEEP_ACTION_LABEL: String = "Keep calibrating"
        const val LEAVE_ACTION_LABEL: String = "Leave and continue later"
    }
}

/**
 * Whether the current in-memory draft is confirmed on disk.
 *
 * Exists so the UI can never accidentally conflate "I am holding this draft in
 * memory" with "this draft would survive the app being killed". Only the local
 * store's own return value moves this to [Saved].
 */
enum class MapAlignmentDraftPersistence {
    /** The latest change is confirmed written to this installation. */
    Saved,

    /** Changed in memory, not yet written. */
    UnsavedChanges,

    /** A write was attempted and genuinely failed. */
    SaveFailed,
}

/** Which exit confirmation the guard is asking for. */
enum class MapAlignmentExitConfirmation {
    /** Progress is on disk. Offers "Leave and continue later". */
    Leave,

    /**
     * The latest autosave failed. Offers only a retry and staying put.
     *
     * There is deliberately no leave action: while the newest evidence is
     * unconfirmed on disk, an exit is the one irreversible thing the operator
     * could do, and no wording makes that a fair choice to offer.
     */
    SaveFailed,
}
