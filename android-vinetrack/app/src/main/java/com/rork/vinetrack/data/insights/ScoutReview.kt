package com.rork.vinetrack.data.insights

/**
 * The pre-completion summary and the completion rule.
 *
 * Pure and platform-neutral so iOS can mirror it exactly, and so the rule that
 * decides whether a vineyard walk is finished is testable without a UI.
 */
data class ScoutReview(
    val blocksAssessed: Int,
    val blocksIncomplete: Int,
    val growthStageObservations: Int,
    val attentionItems: Int,
    val photoCount: Int,
    val otherIssues: Int,
    val generalRecommendations: Int,
    /** Paddock ids with no observation at all — what blocks completion. */
    val incompletePaddockIds: List<String>,
) {
    /**
     * Completion rule.
     *
     * Two things are deliberately NOT required:
     *
     *  * Every dropdown answered. Forcing six selections per block to record
     *    "nothing of note" teaches operators to click through defaults, which
     *    produces confident data nobody actually looked at.
     *  * A minimum photo or note count. Some blocks are genuinely unremarkable.
     *
     * What IS required is evidence that every selected block was actually
     * visited: at least one observation, issue or recommendation each. A block
     * added to the visit and then never opened is the one case where silence
     * is indistinguishable from an omission, so it blocks completion.
     */
    val canComplete: Boolean get() = blocksAssessed > 0 && blocksIncomplete == 0

    /** Operator-facing explanation when completion is blocked. */
    fun blockedReason(): String? = when {
        blocksAssessed == 0 && blocksIncomplete == 0 ->
            "Add at least one block to this Scout before completing it."
        blocksIncomplete == 1 ->
            "1 observation stop is unfinished. Open it and Save observation before finishing this Scout Trip."
        blocksIncomplete > 1 ->
            "$blocksIncomplete observation stops are unfinished. Save each before finishing this Scout Trip."
        else -> null
    }

    companion object {
        const val COMPLETION_HINT: String =
            "Every observation stop must be saved and contain at least one finding, note or photograph. Return to editing any unfinished stops before finishing the trip."

        fun of(visit: ScoutVisit): ScoutReview {
            val incomplete = visit.assessments.filterNot { it.isComplete }
            return ScoutReview(
                blocksAssessed = visit.assessments.filter { it.isComplete }.map { it.paddockId }.distinct().size,
                blocksIncomplete = incomplete.size,
                growthStageObservations = visit.assessments.count { assessment ->
                    assessment.observation(ScoutItem.GROWTH_STAGE)
                        ?.linkedGrowthStageRecordId != null
                },
                attentionItems = visit.assessments.sumOf { it.attentionItems.size },
                photoCount = visit.assessments.sumOf { it.photoCount },
                otherIssues = visit.assessments.count {
                    it.observation(ScoutItem.OTHER_ISSUE)?.hasContent == true
                },
                generalRecommendations = visit.assessments.count {
                    it.observation(ScoutItem.GENERAL_RECOMMENDATION)?.hasContent == true
                },
                incompletePaddockIds = incomplete.map { it.paddockId },
            )
        }
    }
}
