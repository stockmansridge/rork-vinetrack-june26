package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The canonical BASE seasonal yield estimate contract
 * (`get_season_yield_base_overview`, sql/221), mirroring the iOS
 * `BackendSeasonYieldOverview`.
 *
 * Every figure here is UNDAMAGED. The RPC deliberately takes no `apply_damage`
 * argument — damage is applied on top by `SeasonYieldDamage` using the damage
 * records this client loaded for the SAME vineyard and vintage.
 *
 * Two totals, and they are not interchangeable:
 *  * [totalBaseEstimateTonnes] — CANONICAL. `null` whenever any applicable row
 *    is still unconfigured OR any active block has no estimate rows. The only
 *    figure Grape Allocation may allocate from, and a `null` must render as
 *    "—", never `0 t`.
 *  * [knownBaseEstimateTonnes] — DIAGNOSTIC "known so far". Safe to show as
 *    partial progress, never safe to allocate from.
 */
@Serializable
data class SeasonYieldOverview(
    @SerialName("vineyard_id") val vineyardId: String,
    val vintage: Int,
    /** Canonical crop total. null = not knowable yet — show "—". */
    @SerialName("total_base_estimate_tonnes") val totalBaseEstimateTonnes: Double? = null,
    /** What is configured so far. Never use for allocation. */
    @SerialName("known_base_estimate_tonnes") val knownBaseEstimateTonnes: Double = 0.0,
    @SerialName("is_estimate_complete") val isEstimateComplete: Boolean = false,
    /** Count of ACTIVE blocks — the completeness denominator. */
    @SerialName("blocks_total") val blocksTotal: Int = 0,
    @SerialName("blocks_available") val blocksAvailable: Int = 0,
    @SerialName("blocks_unavailable") val blocksUnavailable: Int = 0,
    @SerialName("blocks_with_estimates") val blocksWithEstimates: Int = 0,
    @SerialName("blocks_missing_estimates") val blocksMissingEstimates: Int = 0,
    /** `pruning`, `bunch_count`, `manual` or `none`. */
    @SerialName("estimate_source") val estimateSource: String = "none",
    @SerialName("calculated_at") val calculatedAt: String? = null,
    val varieties: List<SeasonYieldVariety> = emptyList(),
    val blocks: List<SeasonYieldBlock> = emptyList(),
    @SerialName("setup_warnings") val setupWarnings: List<SeasonYieldWarning> = emptyList(),
)

/** One canonical variety line for the vintage. */
@Serializable
data class SeasonYieldVariety(
    /** Stable identity: the variety key when known, else the planting group key. */
    @SerialName("variety_identity") val varietyIdentity: String,
    @SerialName("variety_key") val varietyKey: String? = null,
    @SerialName("variety_name") val varietyName: String? = null,
    @SerialName("is_unallocated") val isUnallocated: Boolean = false,
    @SerialName("is_estimate_available") val isEstimateAvailable: Boolean = false,
    /**
     * Only true when the WHOLE vineyard is covered — an uncovered block may be
     * planted to this same variety, which would understate it.
     */
    @SerialName("is_estimate_complete") val isEstimateComplete: Boolean = false,
    @SerialName("known_base_estimate_tonnes") val knownBaseEstimateTonnes: Double = 0.0,
    @SerialName("base_estimate_tonnes") val baseEstimateTonnes: Double? = null,
    @SerialName("paddock_ids") val paddockIds: List<String> = emptyList(),
    @SerialName("planting_group_keys") val plantingGroupKeys: List<String> = emptyList(),
) {
    val displayName: String
        get() = varietyName?.trim().takeUnless { it.isNullOrEmpty() } ?: "Unallocated variety"
}

/**
 * One active block. Blocks with NO estimate rows are still listed, with
 * [hasEstimates] false and a null base — never an invented `0 t`.
 */
@Serializable
data class SeasonYieldBlock(
    @SerialName("paddock_id") val paddockId: String,
    @SerialName("block_name") val blockName: String? = null,
    @SerialName("area_hectares") val areaHectares: Double = 0.0,
    @SerialName("estimate_source") val estimateSource: String = "none",
    @SerialName("is_estimate_available") val isEstimateAvailable: Boolean = false,
    @SerialName("is_estimate_complete") val isEstimateComplete: Boolean = false,
    /** false = active block with no estimate rows for the vintage yet. */
    @SerialName("has_estimates") val hasEstimates: Boolean = false,
    @SerialName("known_base_estimate_tonnes") val knownBaseEstimateTonnes: Double = 0.0,
    @SerialName("base_estimate_tonnes") val baseEstimateTonnes: Double? = null,
    @SerialName("calculated_at") val calculatedAt: String? = null,
    @SerialName("source_inputs") val sourceInputs: SeasonYieldSourceInputs? = null,
    @SerialName("setup_warnings") val setupWarnings: List<String> = emptyList(),
    val groups: List<SeasonYieldGroup> = emptyList(),
) {
    val displayName: String
        get() = blockName?.trim().takeUnless { it.isNullOrEmpty() } ?: "Block"
}

/** One planting group (variety + clone + rootstock) within a block. */
@Serializable
data class SeasonYieldGroup(
    @SerialName("estimate_id") val estimateId: String? = null,
    @SerialName("planting_group_key") val plantingGroupKey: String,
    @SerialName("variety_key") val varietyKey: String? = null,
    @SerialName("variety_name") val varietyName: String? = null,
    val clone: String? = null,
    val rootstock: String? = null,
    @SerialName("variety_allocation_ids") val varietyAllocationIds: List<String> = emptyList(),
    /** The group's share of the block, already reconciled to sum to 100%. */
    @SerialName("allocation_percent") val allocationPercent: Double = 0.0,
    @SerialName("is_unallocated") val isUnallocated: Boolean = false,
    @SerialName("estimate_source") val estimateSource: String = "none",
    @SerialName("base_estimate_tonnes") val baseEstimateTonnes: Double? = null,
    @SerialName("is_estimate_available") val isEstimateAvailable: Boolean = false,
    @SerialName("calculated_at") val calculatedAt: String? = null,
    @SerialName("source_session_id") val sourceSessionId: String? = null,
    @SerialName("setup_warnings") val setupWarnings: List<String> = emptyList(),
) {
    /** Variety + clone + rootstock, e.g. "Shiraz · MV6 · 101-14". */
    val displayName: String
        get() = buildList {
            add(varietyName?.trim().takeUnless { it.isNullOrEmpty() } ?: "Unallocated variety")
            clone?.trim()?.takeIf { it.isNotEmpty() }?.let { add(it) }
            rootstock?.trim()?.takeIf { it.isNotEmpty() }?.let { add(it) }
        }.joinToString(" · ")
}

/**
 * The pruning inputs the DB actually used for a block, recorded for audit and
 * surfaced by the block info button.
 */
@Serializable
data class SeasonYieldSourceInputs(
    @SerialName("has_pruning_settings") val hasPruningSettings: Boolean? = null,
    @SerialName("prune_method") val pruneMethod: String? = null,
    @SerialName("bunches_per_bud") val bunchesPerBud: Double? = null,
    @SerialName("buds_per_spur") val budsPerSpur: Double? = null,
    @SerialName("spurs_per_vine") val spursPerVine: Double? = null,
    @SerialName("buds_per_cane") val budsPerCane: Double? = null,
    @SerialName("canes_per_vine") val canesPerVine: Double? = null,
    @SerialName("vines_per_ha") val vinesPerHa: Double? = null,
    @SerialName("bunch_weight_grams") val bunchWeightGrams: Double? = null,
    @SerialName("buds_per_vine") val budsPerVine: Double? = null,
    @SerialName("vine_count") val vineCount: Double? = null,
    /** `block_vine_count_override` or `block_area_x_vines_per_ha`. */
    @SerialName("vine_count_basis") val vineCountBasis: String? = null,
    @SerialName("vine_count_override") val vineCountOverride: Double? = null,
    @SerialName("area_hectares") val areaHectares: Double? = null,
    @SerialName("block_base_tonnes") val blockBaseTonnes: Double? = null,
    @SerialName("allocation_percent_total_original") val allocationPercentTotalOriginal: Double? = null,
    @SerialName("allocation_percent_total_final") val allocationPercentTotalFinal: Double? = null,
    @SerialName("allocation_percent_normalized") val allocationPercentNormalized: Boolean? = null,
    @SerialName("allocation_group_count") val allocationGroupCount: Int? = null,
    val formula: String? = null,
)

/** A setup warning, naming the block it belongs to when it has one. */
@Serializable
data class SeasonYieldWarning(
    val code: String,
    @SerialName("paddock_id") val paddockId: String? = null,
    @SerialName("block_name") val blockName: String? = null,
)

/**
 * Result of `refresh_pruning_yield_estimates` — reported so a caller can tell
 * "nothing to do" from "wrote 12 rows".
 */
@Serializable
data class SeasonYieldRefreshResult(
    @SerialName("vineyard_id") val vineyardId: String? = null,
    val vintage: Int? = null,
    @SerialName("blocks_processed") val blocksProcessed: Int? = null,
    @SerialName("rows_written") val rowsWritten: Int? = null,
    @SerialName("rows_skipped_higher_priority") val rowsSkippedHigherPriority: Int? = null,
    @SerialName("rows_retired") val rowsRetired: Int? = null,
)

/** Plain-English copy for the setup warning codes, shared with iOS. */
object SeasonYieldWarningCopy {
    fun text(code: String): String = when (code) {
        "estimate_missing_for_active_block" ->
            "This block has no estimate for the vintage yet. Save its Pruning Yield Calculator settings to include it."
        "estimate_incomplete" ->
            "The crop total isn't usable yet — at least one block is still missing an estimate or an input."
        "no_estimates_for_vintage" ->
            "No blocks have been estimated for this vintage yet."
        "missing_pruning_settings" ->
            "No Pruning Yield Calculator settings saved for this block."
        "missing_canes_per_vine" -> "Canes per vine is missing."
        "missing_buds_per_cane" -> "Buds per cane is missing."
        "missing_spurs_per_vine" -> "Spurs per vine is missing."
        "missing_buds_per_spur" -> "Buds per spur is missing."
        "missing_bunches_per_bud" -> "Bunches per bud is missing."
        "missing_bunch_weight_grams" -> "Average bunch weight is missing."
        "missing_block_area" ->
            "This block has no mapped area, so its vine count can't be derived."
        "missing_vines_per_ha" -> "Vines per hectare is missing."
        "missing_vine_count" ->
            "The block's vine count can't be determined from the saved inputs."
        "allocation_percent_invalid" ->
            "A variety allocation has an unreadable percentage and was excluded."
        "allocation_percent_over_100" ->
            "A variety allocation is above 100% on its own."
        "allocation_missing_variety_identity" ->
            "A variety allocation has no identifiable variety and was folded into \"Unallocated variety\"."
        "block_has_no_variety_allocations" ->
            "This block has no variety allocations, so the whole block is treated as unallocated."
        "block_allocations_over_100_normalized" ->
            "Variety allocations added up to more than 100% and were scaled back proportionally."
        "block_allocations_under_100" ->
            "Variety allocations add up to less than 100%; the remainder is \"Unallocated variety\"."
        "damage_record_without_polygon" ->
            "A damage record has no valid mapped area and was excluded from the damage calculation."
        "block_area_unavailable" ->
            "This block has no mapped area, so recorded damage can't be applied to it."
        else -> code.replace('_', ' ').replaceFirstChar { it.uppercase() }
    }
}
