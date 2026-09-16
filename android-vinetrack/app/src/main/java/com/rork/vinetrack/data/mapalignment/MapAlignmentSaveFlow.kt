package com.rork.vinetrack.data.mapalignment

/**
 * The rules for turning a reviewed candidate into a SAVED field-test
 * calibration, and for replacing one that already exists.
 *
 * ## Why this is a separate, pure object
 *
 * Saving is the one genuinely destructive moment in the whole feature: it can
 * replace a calibration the operator already walked a vineyard to produce. The
 * decisions involved — does a calibration already exist for this exact scope,
 * must the quality warning be shown, what replaces what — are therefore kept
 * out of the Composable and out of [MapAlignmentLocalStore], where they could
 * only be verified by driving a screen. Here they are ordinary functions over
 * ordinary values, so the dangerous cases can be tested directly.
 *
 * ## Still local, still not applied to production maps
 *
 * Saving writes to this Android installation only, through
 * [MapAlignmentLocalStore]. No SQL, Supabase table, RPC, API endpoint, sync
 * entity, outbox, Portal record or iOS file is involved, and no production map
 * consults the result — see [MapAlignmentResolver], which is not fed from
 * storage in this phase.
 */
object MapAlignmentSaveFlow {

    /** Primary action wording, used by every save entry point. */
    const val SAVE_ACTION_LABEL: String = "Save field-test calibration"

    /**
     * The calibration currently saved for exactly [scope], if any.
     *
     * Scope equality is exact — installation, vineyard AND block. A vineyard
     * calibration and a block override for the same vineyard are different
     * calibrations answering different questions, so neither may ever replace
     * the other.
     */
    fun existingFor(
        saved: List<MapAlignmentSavedCalibration>,
        scope: MapAlignmentScope,
    ): MapAlignmentSavedCalibration? = saved.firstOrNull { it.alignment.scope == scope }

    /**
     * The stored list after [incoming] is saved.
     *
     * One current calibration per exact scope: an earlier calibration for the
     * same scope is replaced rather than accumulated, because two "current"
     * calibrations for one vineyard would leave the operator — and any later
     * code — with no way to say which one is the answer. Other scopes are
     * untouched, so saving a block override never disturbs the vineyard
     * calibration beneath it.
     */
    fun merge(
        existing: List<MapAlignmentSavedCalibration>,
        incoming: MapAlignmentSavedCalibration,
    ): List<MapAlignmentSavedCalibration> =
        existing.filterNot {
            it.alignment.scope == incoming.alignment.scope ||
                it.alignment.id == incoming.alignment.id
        } + incoming

    /**
     * Build the record to save from a reviewed draft.
     *
     * Takes the whole [MapAlignmentSolver.Solution], so every reference point
     * and its complete GPS evidence is carried across. Derived review values —
     * residuals, RMS, maximum, quality — are deliberately NOT stored: they are
     * recomputed from the evidence on load, so a saved calibration can never
     * display a quality figure its own points no longer support.
     */
    fun savedFrom(
        draft: MapAlignmentDraft,
        solution: MapAlignmentSolver.Solution,
        nowEpochMillis: Long,
    ): MapAlignmentSavedCalibration = MapAlignmentSavedCalibration(
        calibration = solution.calibration,
        vineyardName = draft.vineyardName,
        blockName = draft.blockName,
        savedAtEpochMillis = nowEpochMillis,
    )

    /**
     * Whether the overall quality warning must be shown before saving.
     *
     * This is the OVERALL fit rule ([MapAlignmentSolver.Quality]), and it is
     * deliberately not the per-point outlier rule in [MapAlignmentOutliers].
     * The two answer different questions and must not be collapsed: a
     * calibration can be uniformly mediocre with no odd point at all, and it
     * can contain one clear outlier while still fitting well enough overall.
     * Either one alone is a reason to pause before saving.
     */
    fun needsQualityConfirmation(solution: MapAlignmentSolver.Solution): Boolean =
        solution.quality != MapAlignmentSolver.Quality.Good

    /** Body text for "Save calibration with warnings?". States both figures. */
    fun qualityWarningMessage(solution: MapAlignmentSolver.Solution): String =
        "This calibration is outside the recommended alignment quality limits.\n\n" +
            "You can save it for field testing and review, but it will not be applied to " +
            "VineTrack's normal maps.\n\n" +
            "RMS residual: ${formatMetres(solution.rmsResidualMetres)} m " +
            "(recommended ${formatMetres(MapAlignmentSolver.GOOD_RMS_RESIDUAL_METRES)} m or less)\n" +
            "Maximum residual: ${formatMetres(solution.maxResidualMetres)} m " +
            "(recommended ${formatMetres(MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES)} m or less)"

    /** Body text for "Replace saved calibration?". Names what is being replaced. */
    fun replaceMessage(existing: MapAlignmentSavedCalibration): String {
        val where = if (existing.isBlockOverride) {
            "${existing.vineyardName} — ${existing.blockName ?: existing.alignment.scope.blockId}"
        } else {
            existing.vineyardName
        }
        return "A field-test calibration is already saved for this vineyard/block on this " +
            "Android device.\n\nReplace it with the calibration you have just completed?\n\n" +
            "Currently saved: $where, ${existing.pointCount} reference " +
            "${if (existing.pointCount == 1) "point" else "points"}."
    }

    /**
     * Wording for a failed save.
     *
     * The draft is deliberately still present when this is shown — see the
     * ordering rule below — so the operator is told the field work is safe
     * rather than left guessing.
     */
    const val SAVE_FAILED_MESSAGE: String =
        "The calibration could not be saved to this device. Your calibration draft has been " +
            "kept, so nothing has been lost. Try saving again."

    /**
     * Whether the draft may be removed now that a save has been attempted.
     *
     * Save-then-delete, never delete-then-save. If local persistence fails, the
     * draft is the only remaining copy of a walk around a vineyard, so it must
     * survive a failed save. This makes that ordering an explicit, testable
     * rule rather than a comment in the UI.
     */
    fun mayRemoveDraft(saveSucceeded: Boolean): Boolean = saveSucceeded

    private fun formatMetres(value: Double): String =
        if (value >= 10.0) {
            value.toInt().toString()
        } else {
            String.format(java.util.Locale.US, "%.1f", value)
        }
}
