package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.SeasonYieldGroup
import com.rork.vinetrack.data.model.SeasonYieldOverview
import com.rork.vinetrack.data.model.SeasonYieldSourceInputs
import com.rork.vinetrack.data.model.SeasonYieldWarning

/**
 * Joins the canonical BASE estimate contract (`get_season_yield_base_overview`,
 * sql/221) with the client-side area-weighted damage engine
 * ([SeasonYieldDamage]) to produce everything the yield surfaces display.
 *
 * Mirrors `SeasonYieldProjection.swift` on iOS.
 *
 * Two rules run through the whole file:
 *
 *  1. **Damage is applied per BLOCK, then aggregated.** A block's loss fraction
 *     is computed once from its own damage records and its own area, then
 *     applied to each of that block's planting groups. Variety and vineyard
 *     totals are sums of the already-adjusted block figures — a vineyard-wide
 *     loss fraction is never computed, and block fractions are never blended.
 *  2. **Incomplete means unknown, not zero.** Any canonical figure the DB
 *     withheld (`null`) stays `null` all the way to the UI, which renders "—".
 *     Only the `known…` figures describe partial progress, and they are never
 *     allocatable.
 */
object SeasonYieldProjection {

    data class GroupRow(
        val plantingGroupKey: String,
        /** Matches the contract's `variety_identity`. */
        val varietyIdentity: String,
        val displayName: String,
        val allocationPercent: Double,
        val isEstimateAvailable: Boolean,
        val baseTonnes: Double?,
        /** Base × the BLOCK's remaining-yield multiplier. null mirrors base. */
        val adjustedTonnes: Double?,
    )

    data class BlockRow(
        val paddockId: String,
        val name: String,
        val areaHectares: Double,
        /** false = active block with no estimate rows for the vintage yet. */
        val hasEstimates: Boolean,
        val isEstimateComplete: Boolean,
        val estimateSource: String,
        val calculatedAt: String?,
        /** Canonical block base. null = incomplete, show "—". */
        val baseTonnes: Double?,
        val knownBaseTonnes: Double,
        val adjustedTonnes: Double?,
        val knownAdjustedTonnes: Double,
        /**
         * Always computed, even when Apply Damage is off, so the info sheet can
         * show what damage WOULD do.
         */
        val damage: SeasonYieldDamage.BlockDamage,
        val warnings: List<String>,
        val groups: List<GroupRow>,
        val sourceInputs: SeasonYieldSourceInputs?,
    ) {
        /** Tonnes removed by damage, when both a base and damage exist. */
        val damageReductionTonnes: Double?
            get() = baseTonnes?.let { it - (adjustedTonnes ?: it) }
    }

    data class VarietyRow(
        val varietyIdentity: String,
        val varietyKey: String?,
        val displayName: String,
        val isUnallocated: Boolean,
        /** Only true when the WHOLE vineyard is covered. */
        val isEstimateComplete: Boolean,
        val baseTonnes: Double?,
        val knownBaseTonnes: Double,
        val adjustedTonnes: Double?,
        val knownAdjustedTonnes: Double,
        val paddockIds: List<String>,
    )

    data class Result(
        val vineyardId: String,
        val vintage: Int,
        val damageApplied: Boolean,
        val isEstimateComplete: Boolean,
        /** The ONLY allocatable crop total. null = show "—". */
        val totalBaseTonnes: Double?,
        val totalAdjustedTonnes: Double?,
        /** Diagnostic "known so far" — never allocate from these. */
        val knownBaseTonnes: Double,
        val knownAdjustedTonnes: Double,
        val estimateSource: String,
        val calculatedAt: String?,
        val blocksTotal: Int,
        val blocksAvailable: Int,
        val blocksUnavailable: Int,
        val blocksWithEstimates: Int,
        val blocksMissingEstimates: Int,
        val blocks: List<BlockRow>,
        val varieties: List<VarietyRow>,
        val warnings: List<SeasonYieldWarning>,
    ) {
        /**
         * The figure a surface should show as "the crop", honouring the Apply
         * Damage toggle. null = "—".
         */
        val displayTotalTonnes: Double?
            get() = if (damageApplied) totalAdjustedTonnes else totalBaseTonnes

        /** Names of active blocks with no estimate at all. */
        val blocksMissingEstimateNames: List<String>
            get() = warnings
                .filter { it.code == "estimate_missing_for_active_block" }
                .mapNotNull { it.blockName }
                .sortedBy { it.lowercase() }

        /** True when any block excluded a damage record for a bad polygon. */
        val hasExcludedDamageRecords: Boolean
            get() = blocks.any { it.damage.excludedRecordCount > 0 }
    }

    /**
     * Damage records for exactly one vineyard AND one vintage.
     *
     * The vintage comes from the server-resolved `damage_records.vintage`
     * whenever it is present; only an unsynced local record falls back to the
     * device season resolver. Filtering by anything else would let a frost from
     * last season quietly reduce this season's crop.
     */
    fun damageRecords(
        records: List<DamageRecord>,
        vineyardId: String,
        vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int,
    ): List<DamageRecord> = records.filter { record ->
        record.vineyardId.equals(vineyardId, ignoreCase = true) &&
            record.resolvedVintage(seasonStartMonth, seasonStartDay) == vintage
    }

    /**
     * Project the contract onto the display model.
     *
     * [damageRecords] must already be filtered to this vineyard AND vintage.
     * [applyDamage] is the user's toggle, OFF by default — when off, adjusted
     * figures equal base figures, but the per-block damage verdict is still
     * computed so the info sheet can show it.
     */
    fun make(
        overview: SeasonYieldOverview,
        damageRecords: List<DamageRecord>,
        applyDamage: Boolean,
    ): Result {
        val recordsByBlock = damageRecords.groupBy { it.paddockId.lowercase() }

        val blocks = mutableListOf<BlockRow>()
        // Adjusted tonnes accumulated per variety identity, built from the
        // per-block figures — never recomputed at variety level.
        val adjustedByVariety = mutableMapOf<String, Double>()
        val knownAdjustedByVariety = mutableMapOf<String, Double>()
        val varietyIncomplete = mutableSetOf<String>()

        for (block in overview.blocks) {
            val damage = SeasonYieldDamage.blockDamage(
                paddockId = block.paddockId,
                blockAreaHectares = block.areaHectares,
                records = recordsByBlock[block.paddockId.lowercase()].orEmpty(),
            )
            // A block whose area is unknown keeps its base figures: the engine
            // returns a zero loss fraction plus the block_area_unavailable
            // warning rather than guessing.
            val multiplier = if (applyDamage) damage.remainingYieldMultiplier else 1.0

            val groupRows = mutableListOf<GroupRow>()
            var knownAdjustedForBlock = 0.0

            for (group in block.groups) {
                val identity = varietyIdentity(group)
                val base = group.baseEstimateTonnes
                val adjusted = base?.times(multiplier)

                groupRows += GroupRow(
                    plantingGroupKey = group.plantingGroupKey,
                    varietyIdentity = identity,
                    displayName = group.displayName,
                    allocationPercent = group.allocationPercent,
                    isEstimateAvailable = group.isEstimateAvailable,
                    baseTonnes = base,
                    adjustedTonnes = adjusted,
                )

                if (group.isEstimateAvailable && adjusted != null) {
                    knownAdjustedForBlock += adjusted
                    knownAdjustedByVariety[identity] =
                        (knownAdjustedByVariety[identity] ?: 0.0) + adjusted
                    adjustedByVariety[identity] =
                        (adjustedByVariety[identity] ?: 0.0) + adjusted
                } else {
                    // An unavailable group makes its variety's canonical total
                    // unknowable, exactly as the DB does for the base figure.
                    varietyIncomplete += identity
                }
            }

            blocks += BlockRow(
                paddockId = block.paddockId,
                name = block.displayName,
                areaHectares = block.areaHectares,
                hasEstimates = block.hasEstimates,
                isEstimateComplete = block.isEstimateComplete,
                estimateSource = block.estimateSource,
                calculatedAt = block.calculatedAt,
                baseTonnes = block.baseEstimateTonnes,
                knownBaseTonnes = block.knownBaseEstimateTonnes,
                adjustedTonnes = block.baseEstimateTonnes?.times(multiplier),
                knownAdjustedTonnes = knownAdjustedForBlock,
                damage = damage,
                warnings = block.setupWarnings + damage.warnings,
                groups = groupRows,
                sourceInputs = block.sourceInputs,
            )
        }

        val isComplete = overview.isEstimateComplete
        val knownAdjustedTotal = blocks.sumOf { it.knownAdjustedTonnes }

        // The canonical adjusted total exists only when the canonical base
        // total does. Summing "what we happen to know" into the headline figure
        // is exactly the bug the DB contract exists to prevent.
        val totalAdjusted = if (isComplete && overview.totalBaseEstimateTonnes != null) {
            knownAdjustedTotal
        } else {
            null
        }

        val varieties = overview.varieties.map { variety ->
            val identity = variety.varietyIdentity
            val complete = variety.isEstimateComplete && identity !in varietyIncomplete
            VarietyRow(
                varietyIdentity = identity,
                varietyKey = variety.varietyKey,
                displayName = variety.displayName,
                isUnallocated = variety.isUnallocated,
                isEstimateComplete = complete,
                baseTonnes = variety.baseEstimateTonnes,
                knownBaseTonnes = variety.knownBaseEstimateTonnes,
                adjustedTonnes = if (complete && variety.baseEstimateTonnes != null) {
                    adjustedByVariety[identity] ?: 0.0
                } else {
                    null
                },
                knownAdjustedTonnes = knownAdjustedByVariety[identity] ?: 0.0,
                paddockIds = variety.paddockIds,
            )
        }

        return Result(
            vineyardId = overview.vineyardId,
            vintage = overview.vintage,
            damageApplied = applyDamage,
            isEstimateComplete = isComplete,
            totalBaseTonnes = overview.totalBaseEstimateTonnes,
            totalAdjustedTonnes = totalAdjusted,
            knownBaseTonnes = overview.knownBaseEstimateTonnes,
            knownAdjustedTonnes = knownAdjustedTotal,
            estimateSource = overview.estimateSource,
            calculatedAt = overview.calculatedAt,
            blocksTotal = overview.blocksTotal,
            blocksAvailable = overview.blocksAvailable,
            blocksUnavailable = overview.blocksUnavailable,
            blocksWithEstimates = overview.blocksWithEstimates,
            blocksMissingEstimates = overview.blocksMissingEstimates,
            blocks = blocks,
            varieties = varieties,
            warnings = overview.setupWarnings,
        )
    }

    /**
     * `coalesce(nullif(variety_key, ''), planting_group_key)` — identical to the
     * SQL contract's `variety_identity`.
     */
    fun varietyIdentity(group: SeasonYieldGroup): String {
        val key = group.varietyKey?.trim().orEmpty()
        return key.ifEmpty { group.plantingGroupKey }
    }
}
