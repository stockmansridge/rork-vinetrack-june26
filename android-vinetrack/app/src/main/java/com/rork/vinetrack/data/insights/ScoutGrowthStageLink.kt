package com.rork.vinetrack.data.insights

/**
 * How a Scout's E-L selection reaches the canonical Growth Stage records.
 *
 * ## The rule this type exists to enforce
 *
 * Scouting must not become a second authority for phenology. If a scout
 * selects E-L 23 in Block 4, that is the SAME observation the Growth Stage
 * workflow would create — it must produce one canonical pin and one
 * `growth_stage_records` row, appear in the existing Growth Stage list,
 * reports and the E-L heatmap, and be counted exactly once.
 *
 * The tempting shortcut is to store a `growth_stage` code on the scout
 * observation as well, "for convenience". That would create two rows that can
 * disagree, and the vineyard would eventually be told two different budburst
 * dates by two screens. So the scout observation stores a LINK
 * ([ScoutObservation.linkedGrowthStageRecordId]) and never a competing value.
 *
 * ## Idempotency
 *
 * The link is keyed by the scout observation's own client-generated id, so an
 * offline retry that replays the same capture resolves to the same canonical
 * record instead of minting a second one. [plan] is the decision function: it
 * is given what already exists and returns what should happen, so replay
 * safety is a testable property rather than a hope about network behaviour.
 *
 * ## Deletion asymmetry — deliberate
 *
 * Abandoning or deleting a Scout does NOT delete a canonical Growth Stage
 * record it already created. The observation was genuinely made in the
 * vineyard; the scout visit is just the paperwork that carried it. Silently
 * removing a phenology record — which feeds the heatmap, GDD work and
 * reporting — because someone tidied up a draft would be a destructive
 * surprise. The link is cleared; the record stays and remains editable in the
 * Growth Stage workflow where it belongs.
 */
sealed interface ScoutGrowthStageLink {

    /** No canonical record yet — create one through the normal pipeline. */
    data class Create(
        val observationId: String,
        val vineyardId: String,
        val paddockId: String,
        val stageCode: String,
    ) : ScoutGrowthStageLink

    /**
     * A canonical record already exists for this observation and the stage
     * changed — UPDATE it in place. Never create a second record for an edit.
     */
    data class Update(
        val observationId: String,
        val growthStageRecordId: String,
        val stageCode: String,
    ) : ScoutGrowthStageLink

    /**
     * The record already matches the selection. Nothing to write.
     *
     * This is the offline-replay case: a retry of an already-applied capture
     * must be a no-op, not a duplicate.
     */
    data class Unchanged(val growthStageRecordId: String) : ScoutGrowthStageLink

    /**
     * The scout cleared their E-L selection. The canonical record is NOT
     * deleted — only the scout's reference to it is dropped, for the same
     * reason abandoning a visit does not delete phenology.
     */
    data class Unlink(val growthStageRecordId: String) : ScoutGrowthStageLink

    /** Nothing selected and nothing linked. */
    data object None : ScoutGrowthStageLink

    companion object {
        /**
         * Decide what a given E-L selection should do to canonical storage.
         *
         * @param existingRecordId the canonical record this observation
         *   already created, if any.
         * @param existingStageCode that record's current stage, used to
         *   distinguish a real edit from a replay.
         * @param selectedStageCode the scout's current selection; null or
         *   blank means "no stage selected".
         */
        fun plan(
            observationId: String,
            vineyardId: String,
            paddockId: String,
            existingRecordId: String?,
            existingStageCode: String?,
            selectedStageCode: String?,
        ): ScoutGrowthStageLink {
            val selected = selectedStageCode?.takeIf { it.isNotBlank() }
            return when {
                selected == null && existingRecordId == null -> None
                selected == null -> Unlink(existingRecordId!!)
                existingRecordId == null -> Create(
                    observationId = observationId,
                    vineyardId = vineyardId,
                    paddockId = paddockId,
                    stageCode = selected,
                )
                existingStageCode == selected -> Unchanged(existingRecordId)
                else -> Update(
                    observationId = observationId,
                    growthStageRecordId = existingRecordId,
                    stageCode = selected,
                )
            }
        }

        /**
         * What happens to canonical records when a Scout is deleted or
         * abandoned: they are retained, always. Returned explicitly so the
         * caller cannot express "delete these too".
         */
        fun onScoutDeleted(visit: ScoutVisit): List<Unlink> =
            visit.assessments.mapNotNull { assessment ->
                assessment.observation(ScoutItem.GROWTH_STAGE)
                    ?.linkedGrowthStageRecordId
                    ?.let { Unlink(it) }
            }

        const val RETENTION_NOTICE: String =
            "Growth Stage records created during this Scout are kept. They remain " +
                "in Growth Stage Records and the E-L heatmap."
    }
}
