package com.rork.vinetrack.data.resistance

/**
 * The outcome of one rule against one block's history for one disease.
 *
 * Deliberately never a Boolean. "Two Group 11 sprays already applied" and "this
 * would be the third consecutive Group 3" are different situations requiring
 * different operator decisions, and collapsing them to `false` throws away the
 * only information that makes the warning actionable.
 */
enum class ResistanceRuleStatus(val raw: String) {
    /** The rule's groups do not appear in this history at all. */
    NOT_TRIGGERED("not_triggered"),

    /** Present, comfortably inside the published limit. */
    WITHIN_LIMIT("within_limit"),

    /** One more application would reach the limit. */
    APPROACHING_LIMIT("approaching_limit"),

    /** History sits exactly ON the published maximum. Not a breach. */
    LIMIT_REACHED("limit_reached"),

    /** The candidate spray would land exactly on the maximum. */
    WOULD_REACH_LIMIT("would_reach_limit"),

    /** The candidate spray would go past the maximum. */
    WOULD_EXCEED_LIMIT("would_exceed_limit"),

    /** Existing history is already past the maximum. */
    LIMIT_EXCEEDED("limit_exceeded"),

    /** A non-numeric requirement (e.g. mixture) was definitively not met. */
    REQUIREMENT_NOT_MET("requirement_not_met"),

    /**
     * A requirement whose satisfaction cannot be established from the recorded
     * data. Explicitly not a pass.
     */
    REQUIREMENT_UNPROVEN("requirement_unproven"),

    /**
     * Missing or disputed chemistry could change this rule's answer, so no
     * answer is given.
     */
    UNABLE_TO_ASSESS("unable_to_assess"),

    /** Published advice carrying no threshold, surfaced for information. */
    GUIDANCE("guidance"),
    ;

    val isBreach: Boolean
        get() = this == LIMIT_EXCEEDED || this == WOULD_EXCEED_LIMIT || this == REQUIREMENT_NOT_MET

    val isAtLimit: Boolean
        get() = this == LIMIT_REACHED || this == WOULD_REACH_LIMIT
}

/**
 * How prominently a result should be surfaced.
 *
 * Kept separate from [ResistanceRuleStatus] so the domain never carries UI
 * colours, and so a future revision can re-tune emphasis without touching rule
 * logic.
 */
enum class ResistanceSeverity(val raw: String) {
    INFORMATIONAL("informational"),
    ADVISORY("advisory"),
    WARNING("warning"),
    CRITICAL("critical"),

    /** Cannot be judged — needs operator attention of a different kind. */
    INDETERMINATE("indeterminate"),
}

/**
 * How much the evidence behind a result can be relied on.
 *
 * A count derived from verified chemistry and the same count derived from an
 * operator's unverified typing are not the same claim, and presenting them
 * identically would misrepresent both.
 */
enum class ResistanceEvidenceQuality(val raw: String) {
    /** Every contributing application had verified chemistry. */
    HIGH("high"),

    /** Sound arithmetic over chemistry that is partially verified or unverified. */
    QUALIFIED("qualified"),

    /** Conflicting, missing or unattributable data affects this result. */
    INDETERMINATE("indeterminate"),
}

/**
 * Whether a required mixture can be shown to have been present.
 *
 * [SATISFIED] is reachable only when something independent establishes that a
 * partner from an alternative mode of action was applied at an effective rate.
 * Group codes alone cannot establish that, so the engine returns [UNKNOWN]
 * instead of a comfortable false pass.
 */
enum class ResistanceMixtureRequirement(val raw: String) {
    SATISFIED("satisfied"),

    /** No alternative mode of action was present at all — definitive. */
    NOT_SATISFIED("not_satisfied"),

    /** A partner was present, but its adequacy cannot be established. */
    UNKNOWN("unknown"),
}

/** The overall verdict for one disease, one block, one season. */
enum class ResistanceEvaluationStatus(val raw: String) {
    /** No published limit is reached. Qualify by evidence quality before display. */
    COMPLIANT("compliant"),

    APPROACHING_LIMIT("approaching_limit"),

    /** Sitting exactly on a published maximum — no headroom left. */
    LIMIT_REACHED("limit_reached"),

    /** At least one published limit is exceeded, or would be by the candidate. */
    STRATEGY_EXCEEDED("strategy_exceeded"),

    /**
     * Something the engine needs is missing, disputed or unattributable. NOT a
     * pass and NOT a breach.
     */
    UNABLE_TO_FULLY_ASSESS("unable_to_fully_assess"),

    /** Nothing in this block's history targets this disease. */
    NOT_APPLICABLE("not_applicable"),

    /** No VineTrack strategy exists for this jurisdiction/crop/disease. */
    UNSUPPORTED_RULESET("unsupported_ruleset"),
}

/**
 * A single explainable finding.
 *
 * Every field exists so the eventual Planner and Spray Calculator can justify a
 * warning down to the published sentence. There is deliberately no opaque score
 * anywhere in this engine: "Resistance Score 73" cannot be argued with, acted on,
 * or corrected, whereas "this would be a third consecutive Group 3 application,
 * CropLife Guideline 4 permits two" can be all three.
 */
data class ResistanceRuleResult(
    val ruleId: String,
    val rulesetId: String,
    val rulesetVersion: String,
    val disease: ResistanceDisease,
    val blockId: String,
    val status: ResistanceRuleStatus,
    val severity: ResistanceSeverity,
    /** The group codes this rule is about. */
    val groups: List<String>,
    /** The published ceiling, when the rule has one. */
    val threshold: Double?,
    val thresholdDescription: String,
    /** What the history actually shows. */
    val observedValue: Double?,
    val observedDescription: String,
    val explanation: String,
    val contributingApplicationIds: List<String>,
    val contributingDatesEpochMs: List<Long>,
    val evidenceQuality: ResistanceEvidenceQuality,
    val mixtureRequirement: ResistanceMixtureRequirement? = null,
    /** Published clause, e.g. `"Guideline 4"`. */
    val sourceReference: String,
    /** The published sentence, verbatim. */
    val sourceText: String,
)

/**
 * The complete evaluation for one disease against one block.
 *
 * Mirrors iOS `ResistanceEvaluation.swift`.
 */
data class ResistanceEvaluation(
    val status: ResistanceEvaluationStatus,
    val jurisdiction: ResistanceJurisdiction,
    val crop: ResistanceCrop,
    val disease: ResistanceDisease,
    val blockId: String,
    val seasonId: String,
    /** Null only for [ResistanceEvaluationStatus.UNSUPPORTED_RULESET]. */
    val rulesetId: String?,
    val rulesetVersion: String?,
    /** The date the governing strategy is valid as at, for auditability. */
    val rulesetValidFrom: String?,
    val ruleResults: List<ResistanceRuleResult>,
    /** Denominator for every percentage rule. */
    val totalDiseaseSpraysInSeason: Int,
    val consideredApplicationIds: List<String>,
    /**
     * Applications whose chemistry is disputed or missing. These stay in the
     * chronology and suppress a clean result.
     */
    val unassessableApplicationIds: List<String>,
    /**
     * Applications that could not be attributed to any disease because targets
     * were never recorded.
     *
     * These are the pre-sql/193 records. They cannot be counted against a
     * disease, and they must not be silently dropped either — a season half made
     * of unattributable sprays is a season nobody can account for.
     */
    val unattributedApplicationIds: List<String>,
    /**
     * Applications excluded because they are planned rather than applied.
     * Surfaced so the exclusion is visible rather than invisible.
     */
    val excludedPlannedApplicationIds: List<String>,
    val evidenceQuality: ResistanceEvidenceQuality,
    /** Operator-facing sentence, already qualified by evidence quality. */
    val summary: String,
    val candidateApplicationId: String? = null,
) {
    /** Findings worth showing, worst first. */
    val findings: List<ResistanceRuleResult>
        get() = ruleResults
            .filter { it.status != ResistanceRuleStatus.NOT_TRIGGERED && it.status != ResistanceRuleStatus.WITHIN_LIMIT }
            .sortedByDescending { severityRank(it.severity) }

    val breaches: List<ResistanceRuleResult>
        get() = ruleResults.filter { it.status.isBreach }

    val hasCandidate: Boolean get() = candidateApplicationId != null

    /**
     * Whether this result may be presented as a clean pass.
     *
     * False whenever chemistry is missing, disputed or unattributable, no matter
     * how empty the arithmetic came out.
     */
    val isCleanResult: Boolean
        get() = status == ResistanceEvaluationStatus.COMPLIANT &&
            evidenceQuality == ResistanceEvidenceQuality.HIGH

    private fun severityRank(severity: ResistanceSeverity): Int = when (severity) {
        ResistanceSeverity.CRITICAL -> 5
        ResistanceSeverity.WARNING -> 4
        ResistanceSeverity.INDETERMINATE -> 3
        ResistanceSeverity.ADVISORY -> 2
        ResistanceSeverity.INFORMATIONAL -> 1
    }
}
