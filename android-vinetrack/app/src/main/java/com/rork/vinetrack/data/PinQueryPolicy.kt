package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin

enum class PinCategoryFilter { REPAIRS, GROWTH, MANUAL_ISSUES }
enum class PinCompletionFilter { NOT_DONE, DONE, BOTH }

/** The single mutually exclusive type selection shared by Pins map, list and stats. */
enum class PinTypeFilter {
    ALL,
    REPAIRS,
    GROWTH,
    CURRENT_EL_STAGE,
    EL_STAGES,
    MANUAL_ISSUES;

    val ordinaryCategory: PinCategoryFilter?
        get() = when (this) {
            REPAIRS -> PinCategoryFilter.REPAIRS
            GROWTH -> PinCategoryFilter.GROWTH
            MANUAL_ISSUES -> PinCategoryFilter.MANUAL_ISSUES
            ALL, CURRENT_EL_STAGE, EL_STAGES -> null
        }

    val includesElStages: Boolean
        get() = this == CURRENT_EL_STAGE || this == EL_STAGES

    val isCurrentElStage: Boolean
        get() = this == CURRENT_EL_STAGE

    /** EL chips toggle back to All; every other tap selects its requested type. */
    fun selectionAfterTapping(requested: PinTypeFilter): PinTypeFilter =
        if (requested.includesElStages && this == requested) ALL else requested

    companion object {
        fun fromLegacyMode(mode: String?): PinTypeFilter = when (mode) {
            "Repairs" -> REPAIRS
            "Growth" -> GROWTH
            "ManualIssue" -> MANUAL_ISSUES
            else -> ALL
        }
    }
}

data class PinQueryFilter(
    val categories: Set<PinCategoryFilter> = PinCategoryFilter.entries.toSet(),
    val includesElStages: Boolean = false,
    val selectedElStageCodes: Set<String> = emptySet(),
    val completion: PinCompletionFilter = PinCompletionFilter.NOT_DONE,
)

object PinQueryPolicy {
    fun categoriesFor(selection: PinCategoryFilter?): Set<PinCategoryFilter> =
        selection?.let(::setOf) ?: PinCategoryFilter.entries.toSet()

    /** E-L modes defensively carry no ordinary categories. */
    fun filterFor(
        type: PinTypeFilter,
        selectedElStageCodes: Set<String> = emptySet(),
        completion: PinCompletionFilter = PinCompletionFilter.NOT_DONE,
    ): PinQueryFilter {
        val categories = when (type) {
            PinTypeFilter.ALL -> PinCategoryFilter.entries.toSet()
            PinTypeFilter.REPAIRS, PinTypeFilter.GROWTH, PinTypeFilter.MANUAL_ISSUES ->
                type.ordinaryCategory?.let(::setOf).orEmpty()
            PinTypeFilter.CURRENT_EL_STAGE, PinTypeFilter.EL_STAGES -> emptySet()
        }
        return PinQueryFilter(
            categories = categories,
            includesElStages = type.includesElStages,
            selectedElStageCodes = if (type.isCurrentElStage) emptySet() else selectedElStageCodes,
            completion = completion,
        )
    }

    fun normalizedElCode(value: String?): String? {
        val code = value?.trim()?.uppercase()?.takeIf { it.isNotEmpty() } ?: return null
        return code.takeIf { candidate -> com.rork.vinetrack.data.model.GrowthStage.allStages.any { it.code == candidate } }
    }

    /** Numeric E-L value from the canonical `EL<number>` storage shape. */
    fun elStageNumber(value: String?): Int? {
        val code = value?.trim()?.uppercase() ?: return null
        if (!code.matches(Regex("EL[0-9]+"))) return null
        return code.removePrefix("EL").toIntOrNull()
    }

    data class CurrentElSelection(
        val pins: List<Pin>,
        val stageByBlockId: Map<String, Int>,
    )

    /**
     * Retain every pin tied at the highest numeric E-L stage in each
     * authoritatively linked block. Input order remains deterministic.
     */
    fun currentElSelection(
        pins: List<Pin>,
        authoritativeElPinIds: Set<String>,
        authoritativeStageCodeByPinId: Map<String, String> = emptyMap(),
        authoritativeBlockIdByPinId: Map<String, String> = emptyMap(),
        seasonWindow: SeasonWindow? = null,
        seasonZone: java.time.ZoneId? = null,
    ): CurrentElSelection {
        data class Candidate(val pin: Pin, val blockId: String, val stage: Int)

        val valid = pins.mapNotNull { pin ->
            if (seasonWindow != null && (seasonZone == null || !seasonWindow.containsIsoDate(pin.createdAt, seasonZone))) {
                return@mapNotNull null
            }
            if (pin.deletedAt != null || !pin.mode.equals("Growth", ignoreCase = true) ||
                (pin.growthStageCode == null && pin.id !in authoritativeElPinIds)
            ) {
                return@mapNotNull null
            }
            val blockId = authoritativeBlockIdByPinId[pin.id] ?: pin.paddockId ?: return@mapNotNull null
            val stageCode = authoritativeStageCodeByPinId[pin.id] ?: pin.growthStageCode
            val stage = elStageNumber(stageCode) ?: return@mapNotNull null
            Candidate(pin.copy(paddockId = blockId, growthStageCode = stageCode), blockId, stage)
        }
        val stageByBlockId = valid.groupingBy { it.blockId }
            .fold(Int.MIN_VALUE) { maximum, candidate -> maxOf(maximum, candidate.stage) }
        return CurrentElSelection(
            pins = valid.filter { stageByBlockId[it.blockId] == it.stage }.map { it.pin },
            stageByBlockId = stageByBlockId,
        )
    }

    /** Empty while inactive so normal block labels are restored without stale state. */
    fun currentElBlockLabels(selection: CurrentElSelection, isActive: Boolean): Map<String, String> =
        if (isActive) selection.stageByBlockId.mapValues { (_, stage) -> "EL $stage" } else emptyMap()

    fun matches(pin: Pin, filter: PinQueryFilter, isElRecord: Boolean = pin.growthStageCode != null): Boolean {
        if (isElRecord) {
            if (!filter.includesElStages) return false
            val stageCode = normalizedElCode(pin.growthStageCode)
            if (stageCode == null) return filter.selectedElStageCodes.isEmpty() && completionMatches(pin, filter)
            if (filter.selectedElStageCodes.isNotEmpty() && stageCode !in filter.selectedElStageCodes) return false
        } else {
            val category = when (pin.mode?.trim()?.lowercase()) {
                "repairs" -> PinCategoryFilter.REPAIRS
                "growth" -> PinCategoryFilter.GROWTH
                else -> PinCategoryFilter.MANUAL_ISSUES
            }
            if (category !in filter.categories) return false
        }
        return completionMatches(pin, filter)
    }

    private fun completionMatches(pin: Pin, filter: PinQueryFilter): Boolean = when (filter.completion) {
        PinCompletionFilter.NOT_DONE -> !pin.isCompleted
        PinCompletionFilter.DONE -> pin.isCompleted
        PinCompletionFilter.BOTH -> true
    }

    fun usableRow(pin: Pin): Double? = pin.pinRowNumber
        ?: pin.rowSegments?.minOfOrNull { it.rowNumber }?.toDouble()

    /** Issue/Growth names backed by ordinary records; E-L is excluded by identity. */
    fun ordinaryFilterNames(pins: List<Pin>, authoritativeElPinIds: Set<String>): List<String> =
        pins.asSequence()
            .filter { it.growthStageCode == null && it.id !in authoritativeElPinIds }
            .map { it.displayTitle.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .sorted()
            .toList()

    fun cleanedNameSelection(selection: Set<String>, availableNames: List<String>): Set<String> =
        selection.intersect(availableNames.toSet())

    data class TravelContext(
        val vineyardId: String,
        val blockId: String,
        val row: Double,
        val heading: Double?,
        val isEstimated: Boolean = false,
    )

    /** Fresh heading remains usable even when no mapped aisle can be qualified. */
    fun qualifiedHeading(heading: Double?, isQualified: Boolean): Double? =
        heading?.takeIf { isQualified && it.isFinite() && it >= 0.0 && it < 360.0 }

    fun qualifiedTravelContext(
        selectedVineyardId: String?,
        contextVineyardId: String?,
        blockId: String?,
        row: Double?,
        isRowQualified: Boolean,
        observedAtMs: Long?,
        heading: Double?,
        isHeadingQualified: Boolean,
        nowMs: Long,
        freshnessMs: Long = 10_000L,
    ): TravelContext? {
        if (selectedVineyardId == null || contextVineyardId != selectedVineyardId || blockId == null) return null
        if (!isRowQualified || row == null || !row.isFinite()) return null
        val age = observedAtMs?.let { nowMs - it } ?: return null
        if (age !in 0..freshnessMs) return null
        val validHeading = qualifiedHeading(heading, isHeadingQualified)
        return TravelContext(selectedVineyardId, blockId, row, validHeading)
    }

    fun nearestRowOrdered(
        pins: List<Pin>,
        currentRow: Double,
        currentVineyardId: String,
        currentBlockId: String,
        blockNames: Map<String, String>,
    ): List<Pin> {
        val indexed = pins.withIndex()
        val currentBlock = indexed.filter {
            it.value.vineyardId == currentVineyardId && it.value.paddockId == currentBlockId
        }.sortedWith(
            compareBy<IndexedValue<Pin>>(
                { usableRow(it.value) == null },
                { usableRow(it.value)?.let { row -> kotlin.math.abs(row - currentRow) } ?: Double.MAX_VALUE },
                { it.index },
            ),
        )
        val otherBlocks = indexed.filterNot {
            it.value.vineyardId == currentVineyardId && it.value.paddockId == currentBlockId
        }.sortedWith(
            compareBy<IndexedValue<Pin>>(
                { it.value.vineyardId },
                { blockNames[it.value.paddockId] == null },
                { blockNames[it.value.paddockId].orEmpty() },
                { usableRow(it.value) == null },
                { usableRow(it.value) ?: Double.MAX_VALUE },
                { it.index },
            ),
        )
        return (currentBlock + otherBlocks).map { it.value }
    }

    fun rowOrdered(pins: List<Pin>, blockNames: Map<String, String>): List<Pin> =
        pins.withIndex().sortedWith(
            compareBy<IndexedValue<Pin>>(
                { blockNames[it.value.paddockId] == null },
                { blockNames[it.value.paddockId].orEmpty() },
                { usableRow(it.value) == null },
                { usableRow(it.value) ?: Double.MAX_VALUE },
                { it.index },
            ),
        ).map { it.value }
}
