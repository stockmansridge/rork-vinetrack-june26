package com.rork.vinetrack.data.model

import com.rork.vinetrack.data.SeasonYieldProjection

/** Read-only block attribution, intentionally independent of financial block splitting. */
object GrapeAllocationHierarchy {
    data class Estimate(val paddockId: String, val varietyName: String, val tonnes: Double?)
    data class BlockRow(
        val paddockId: String?,
        val name: String,
        val estimatedTonnes: Double?,
        val ownUseTonnes: Double = 0.0,
        val externalTonnes: Double = 0.0,
        val allocationIds: List<String> = emptyList(),
        val hasUnspecifiedQuantity: Boolean = false,
    ) {
        val key: String get() = paddockId ?: "no-block"
        val allocatedTonnes: Double get() = ownUseTonnes + externalTonnes
        val balanceTonnes: Double? get() = estimatedTonnes?.minus(allocatedTonnes)
    }

    fun estimates(projection: SeasonYieldProjection.Result?): List<Estimate> = projection?.blocks.orEmpty().flatMap { block ->
        block.groups.map { group ->
            Estimate(block.paddockId, group.displayName,
                if (!group.isEstimateAvailable) null else if (projection?.damageApplied == true) group.adjustedTonnes else group.baseTonnes)
        }
    }

    /** Duplicate links merge by UUID. Missing multi-block amounts never get an invented split.
     * A signed residual also reconciles legacy over-assigned records without mutating them. */
    fun rows(
        varietyKey: String, vineyardId: String, vintage: Int,
        allocations: List<GrapeAllocation>, estimates: List<Estimate>, blockNames: Map<String, String>,
    ): List<BlockRow> {
        val rows = linkedMapOf<String, BlockRow>()
        val names = blockNames.mapKeys { it.key.lowercase() }
        fun ensure(id: String?): String {
            val key = id?.lowercase() ?: "no-block"
            rows.getOrPut(key) { BlockRow(id?.lowercase(), if (id == null) "No block specified" else names[key] ?: "Unknown block", null) }
            return key
        }
        val seen = mutableSetOf<String>()
        estimates.filter { canonicalVarietyName(it.varietyName) == varietyKey }.forEach { estimate ->
            val key = ensure(estimate.paddockId)
            val row = rows.getValue(key)
            rows[key] = row.copy(estimatedTonnes = if (seen.add(key)) estimate.tonnes
                else if (row.estimatedTonnes != null && estimate.tonnes != null) row.estimatedTonnes + estimate.tonnes else null)
        }
        fun add(id: String?, allocation: GrapeAllocation, tonnes: Double, unspecified: Boolean = false) {
            val key = ensure(id)
            val row = rows.getValue(key)
            rows[key] = row.copy(
                ownUseTonnes = row.ownUseTonnes + if (allocation.isExternal) 0.0 else tonnes,
                externalTonnes = row.externalTonnes + if (allocation.isExternal) tonnes else 0.0,
                allocationIds = (row.allocationIds + allocation.id).distinct(),
                hasUnspecifiedQuantity = row.hasUnspecifiedQuantity || unspecified,
            )
        }
        allocations.filter { it.vineyardId.equals(vineyardId, true) && it.vintage == vintage && it.deletedAt == null && canonicalVarietyName(it.varietyName) == varietyKey }.forEach { allocation ->
            val links = allocation.blocks.filter { it.paddockId.isNotBlank() && it.vineyardId.equals(vineyardId, true) && it.allocationId.equals(allocation.id, true) }.groupBy { it.paddockId.lowercase() }
            var assigned = 0.0
            links.forEach { (id, details) ->
                val quantities = details.mapNotNull { it.quantityTonnes }.filter { it.isFinite() }
                val tonnes = if (quantities.isNotEmpty()) quantities.sum() else if (links.size == 1) allocation.quantityTonnes else null
                add(id, allocation, tonnes ?: 0.0, tonnes == null)
                assigned += tonnes ?: 0.0
            }
            val remainder = allocation.quantityTonnes - assigned
            if (remainder != 0.0 || links.isEmpty()) add(null, allocation, remainder)
        }
        return rows.values.sortedWith(compareBy<BlockRow> { it.paddockId == null }.thenBy { it.name.lowercase() }.thenBy { it.key })
    }
}
