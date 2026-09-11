package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin

enum class PinCategoryFilter { REPAIRS, GROWTH, MANUAL_ISSUES }
enum class PinCompletionFilter { NOT_DONE, DONE, BOTH }

data class PinQueryFilter(
    val categories: Set<PinCategoryFilter> = PinCategoryFilter.entries.toSet(),
    val includesElStages: Boolean = false,
    val selectedElStageCodes: Set<String> = emptySet(),
    val completion: PinCompletionFilter = PinCompletionFilter.NOT_DONE,
)

object PinQueryPolicy {
    fun categoriesFor(selection: PinCategoryFilter?): Set<PinCategoryFilter> =
        selection?.let(::setOf) ?: PinCategoryFilter.entries.toSet()

    fun normalizedElCode(value: String?): String? {
        val code = value?.trim()?.uppercase()?.takeIf { it.isNotEmpty() } ?: return null
        return code.takeIf { candidate -> com.rork.vinetrack.data.model.GrowthStage.allStages.any { it.code == candidate } }
    }

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
