package com.rork.vinetrack.data.model

/** Explicit planning basis; absent saved values remain legacy snapshots. */
object FertiliserVineCounts {
    const val ACTUAL = "actual"
    const val ASSUMED_FULL = "assumed_full"
    const val MANUAL = "manual"

    fun label(basis: String?): String = when (basis) {
        ACTUAL -> "Actual"
        ASSUMED_FULL -> "Assumed full"
        MANUAL -> "Manual"
        else -> "Legacy (basis not recorded)"
    }

    /** Never substitutes a geometry-only estimate for an unavailable actual count. */
    fun count(block: Paddock, basis: String): Int? = when (basis) {
        ACTUAL -> block.vineCountOverride?.takeIf { it > 0 } ?: actualRows(block)
        ASSUMED_FULL -> {
            val spacing = block.vineSpacing
            val length = block.effectiveTotalRowLength
            val completeGeometry = block.rowLengthOverride != null || (block.rows.orEmpty().isNotEmpty() && block.rows.orEmpty().all { block.rowLengthMetres(it).let { value -> value.isFinite() && value > 0 } })
            if (!completeGeometry || spacing == null || !spacing.isFinite() || spacing <= 0 || !length.isFinite() || length <= 0) null
            else (length / spacing).takeIf { it.isFinite() && it >= 1 && it < Int.MAX_VALUE.toDouble() }?.toInt()
        }
        else -> null
    }

    private fun actualRows(block: Paddock): Int? {
        val rows = block.rows.orEmpty()
        if (rows.none { PaddockRowVineCount.sanitiseOverride(it.vineCountOverride) != null }) return null
        var total = 0L
        for (row in rows) {
            total += block.effectiveVineCount(row) ?: return null
            if (total > Int.MAX_VALUE) return null
        }
        return total.toInt().takeIf { it > 0 }
    }

    /** All selected blocks must resolve; no partial totals or overflow. */
    fun total(blocks: List<Paddock>, basis: String): Int? {
        if (blocks.isEmpty()) return null
        var total = 0L
        for (block in blocks) {
            total += count(block, basis) ?: return null
            if (total > Int.MAX_VALUE) return null
        }
        return total.toInt().takeIf { it > 0 }
    }

    /** Last allocation absorbs floating-point residuals without rounding stored quantities. */
    fun shares(total: Double, weights: List<Double>): List<Double> {
        val sum = weights.sum()
        if (!sum.isFinite() || sum <= 0 || weights.any { !it.isFinite() || it < 0 }) return emptyList()
        var allocated = 0.0
        return weights.mapIndexed { index, weight ->
            val value = if (index == weights.lastIndex) total - allocated else total * weight / sum
            allocated += value
            value
        }
    }
}
