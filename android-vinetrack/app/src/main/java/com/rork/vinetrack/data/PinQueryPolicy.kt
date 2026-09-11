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
    fun normalizedElCode(value: String?): String? {
        val code = value?.trim()?.uppercase()?.takeIf { it.isNotEmpty() } ?: return null
        return code.takeIf { candidate -> com.rork.vinetrack.data.model.GrowthStage.allStages.any { it.code == candidate } }
    }

    fun matches(pin: Pin, filter: PinQueryFilter): Boolean {
        val stageCode = normalizedElCode(pin.growthStageCode)
        if (stageCode != null) {
            if (!filter.includesElStages) return false
            if (filter.selectedElStageCodes.isNotEmpty() && stageCode !in filter.selectedElStageCodes) return false
        } else {
            val category = when (pin.mode?.trim()?.lowercase()) {
                "repairs" -> PinCategoryFilter.REPAIRS
                "growth" -> PinCategoryFilter.GROWTH
                else -> PinCategoryFilter.MANUAL_ISSUES
            }
            if (category !in filter.categories) return false
        }
        return when (filter.completion) {
            PinCompletionFilter.NOT_DONE -> !pin.isCompleted
            PinCompletionFilter.DONE -> pin.isCompleted
            PinCompletionFilter.BOTH -> true
        }
    }

    fun usableRow(pin: Pin): Double? = pin.pinRowNumber
        ?: pin.rowSegments?.minOfOrNull { it.rowNumber }?.toDouble()

    data class TravelContext(val row: Double, val heading: Double?)

    fun qualifiedTravelContext(
        row: Double?,
        isRowQualified: Boolean,
        heading: Double?,
        isHeadingQualified: Boolean,
    ): TravelContext? {
        if (!isRowQualified || row == null || !row.isFinite()) return null
        val validHeading = heading?.takeIf { isHeadingQualified && it.isFinite() && it >= 0.0 && it < 360.0 }
        return TravelContext(row, validHeading)
    }

    fun nearestRowOrdered(pins: List<Pin>, currentRow: Double): List<Pin> =
        pins.withIndex().sortedWith(
            compareBy<IndexedValue<Pin>>(
                { usableRow(it.value) == null },
                { usableRow(it.value)?.let { row -> kotlin.math.abs(row - currentRow) } ?: Double.MAX_VALUE },
                { it.index },
            ),
        ).map { it.value }

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
