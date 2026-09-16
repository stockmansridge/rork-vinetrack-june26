package com.rork.vinetrack.data.insights

/**
 * The stable vocabulary shared by Scout and Vintage Notes.
 *
 * Everything here is a CODE plus a LABEL, and the two are not interchangeable.
 * The code is what is stored, indexed, synced and reported on; the label is
 * what a person reads. A vineyard's scouting history outlives the wording used
 * to collect it, so a later decision to rename "Needs attention" must not
 * silently rewrite what was observed in a past season.
 *
 * This file is mirrored EXACTLY by the iOS `VineyardInsightsCatalog.swift`.
 * Codes, labels and ordering must stay byte-identical across the two
 * platforms: the same vineyard is scouted from both, and a report that merges
 * their rows cannot be trusted if one platform stored `very_dry` where the
 * other stored `soil_very_dry`. The parity tests on both platforms assert the
 * exact lists below, so a divergence fails a build rather than a vintage.
 */

/** A selectable option for one assessment item. */
data class ScoutOption(
    /** Stored value. Never a display string, never an ordinal. */
    val code: String,
    /** Exact user-facing wording. Snapshotted onto each saved observation. */
    val label: String,
    /**
     * True when this selection describes something the operator would want to
     * act on. Drives the Scout review's "needs attention" count ONLY.
     *
     * Round 1 deliberately stops there: this flag creates no Repair Pin and no
     * Work Task. An automatic action raised from a dropdown nobody reviewed is
     * how a vineyard ends up with a task list it does not trust, so the
     * linkage fields exist in storage and stay null until that workflow is
     * designed.
     */
    val needsAttention: Boolean = false,
)

/**
 * The assessment items captured per block, in display order.
 *
 * [GROWTH_STAGE] is present as a first-class item because it is scouted like
 * the others, but it is emphatically NOT stored like the others: it writes
 * through the existing canonical Growth Stage pipeline. See
 * [ScoutGrowthStageLink].
 */
enum class ScoutItem(
    /** Stored `scout_observations.item_kind` value. */
    val code: String,
    /** Section heading in the block assessment form. */
    val label: String,
) {
    GROWTH_STAGE("growth_stage", "E-L Growth Stage"),
    WEEDS("weeds", "Weeds"),
    VINE_VIGOUR("vine_vigour", "Vine vigour"),
    SOIL_MOISTURE("soil_moisture", "Soil moisture"),
    POWDERY_MILDEW("powdery_mildew", "Powdery mildew"),
    DOWNY_MILDEW("downy_mildew", "Downy mildew"),
    OTHER_ISSUE("other_issue", "Other issues"),
    GENERAL_RECOMMENDATION("general_recommendation", "General recommendation"),
    ;

    /**
     * Free-text items carry notes and photos but no dropdown, so they are
     * never counted as "not assessed" and never contribute an attention flag.
     */
    val isFreeText: Boolean
        get() = this == OTHER_ISSUE || this == GENERAL_RECOMMENDATION

    companion object {
        fun byCode(code: String?): ScoutItem? = entries.firstOrNull { it.code == code }
    }
}

object VineyardInsightsCatalog {

    /** The stable Operational Tool id. Shared with iOS and SQL 236. */
    const val TOOL_ID: String = "vineyard_insights"
    const val TOOL_TITLE: String = "Vineyard Insights"
    const val TOOL_SUBTITLE: String = "Scouting, vintage notes & reports"
    const val PREVIEW_BADGE: String = "System Admin Preview"

    /**
     * The shared "no answer" code.
     *
     * Every dropdown defaults here and it is a real, stored answer meaning the
     * operator did not assess this item — deliberately distinct from a null,
     * which would be indistinguishable from a row that was never written. A
     * report must be able to say "soil moisture was not assessed in Block 4"
     * rather than quietly omitting the block.
     */
    const val NOT_ASSESSED_CODE: String = "not_assessed"
    const val NOT_ASSESSED_LABEL: String = "Not assessed"

    private val notAssessed = ScoutOption(NOT_ASSESSED_CODE, NOT_ASSESSED_LABEL)

    val weeds: List<ScoutOption> = listOf(
        notAssessed,
        ScoutOption("under_control", "Under control"),
        ScoutOption("needs_attention", "Needs attention", needsAttention = true),
        ScoutOption("inhibiting_growth", "Inhibiting growth", needsAttention = true),
    )

    val vineVigour: List<ScoutOption> = listOf(
        notAssessed,
        ScoutOption("lacks_growth", "Lacks growth", needsAttention = true),
        ScoutOption("good_shoot_length", "Good shoot length"),
        ScoutOption("consider_trimming", "Consider trimming", needsAttention = true),
    )

    val soilMoisture: List<ScoutOption> = listOf(
        notAssessed,
        ScoutOption("adequate", "Adequate"),
        ScoutOption("low_soil_moisture", "Low soil moisture", needsAttention = true),
        ScoutOption("soil_very_dry", "Soil very dry", needsAttention = true),
        ScoutOption("vines_showing_stress", "Vines showing stress", needsAttention = true),
    )

    val powderyMildew: List<ScoutOption> = listOf(
        notAssessed,
        ScoutOption("no_sign", "No sign"),
        ScoutOption("growth_on_leaves", "Growth on leaves", needsAttention = true),
        ScoutOption("found_in_bunches", "Found in bunches", needsAttention = true),
    )

    val downyMildew: List<ScoutOption> = listOf(
        notAssessed,
        ScoutOption("no_sign", "No sign"),
        ScoutOption("primary_infection", "Primary infection", needsAttention = true),
        ScoutOption("on_leaves", "On leaves", needsAttention = true),
        ScoutOption("secondary_infection", "Secondary infection", needsAttention = true),
        ScoutOption("in_bunches", "In bunches", needsAttention = true),
    )

    /** Options for a dropdown item; free-text items have none. */
    fun options(item: ScoutItem): List<ScoutOption> = when (item) {
        ScoutItem.WEEDS -> weeds
        ScoutItem.VINE_VIGOUR -> vineVigour
        ScoutItem.SOIL_MOISTURE -> soilMoisture
        ScoutItem.POWDERY_MILDEW -> powderyMildew
        ScoutItem.DOWNY_MILDEW -> downyMildew
        ScoutItem.GROWTH_STAGE, ScoutItem.OTHER_ISSUE, ScoutItem.GENERAL_RECOMMENDATION -> emptyList()
    }

    fun option(item: ScoutItem, code: String?): ScoutOption? =
        options(item).firstOrNull { it.code == code }

    /**
     * Label for a stored code, for display of a row saved by any platform or
     * client version.
     *
     * A code this build does not recognise returns null rather than an
     * invented label — showing the raw stored code is honest, whereas guessing
     * a label puts words in the operator's mouth.
     */
    fun label(item: ScoutItem, code: String?): String? = option(item, code)?.label

    fun needsAttention(item: ScoutItem, code: String?): Boolean =
        option(item, code)?.needsAttention == true

    fun isAssessed(item: ScoutItem, code: String?): Boolean =
        code != null && code != NOT_ASSESSED_CODE && option(item, code) != null
}
