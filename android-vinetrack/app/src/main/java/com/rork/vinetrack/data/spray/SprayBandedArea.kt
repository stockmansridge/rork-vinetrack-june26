package com.rork.vinetrack.data.spray

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The sprayed band width per row for a banded/strip application — the Kotlin
 * twin of the Swift `SprayBandWidth`.
 *
 * The AUTHORITATIVE value for every calculation is [totalMetres] — the total
 * treated width per row. Left/right are carried for future nozzle-level setups
 * (e.g. an under-vine boom treating 0.5 m one side and 0.3 m the other) and are
 * never used directly by the arithmetic.
 */
data class SprayBandWidth(
    val leftMetres: Double? = null,
    val rightMetres: Double? = null,
    /** Total treated width per row, in metres. This is what the maths uses. */
    val totalMetres: Double,
) {
    val isValid: Boolean get() = totalMetres.isFinite() && totalMetres > 0

    companion object {
        /** A single total treated width per row. */
        fun total(metres: Double) = SprayBandWidth(totalMetres = metres)

        /** Separate left/right widths; the total is their sum. */
        fun leftRight(left: Double, right: Double) =
            SprayBandWidth(leftMetres = left, rightMetres = right, totalMetres = left + right)
    }
}

/** How a treated area was arrived at. */
@Serializable
enum class SprayTreatedAreaMethod(val raw: String) {
    /** `canonicalRowLengthMetres × totalBandWidth ÷ 10_000` — preferred. */
    @SerialName("canonical_row_length")
    CANONICAL_ROW_LENGTH("canonical_row_length"),

    /** `grossHa × totalBandWidth ÷ rowSpacing` — only when no canonical length. */
    @SerialName("area_and_spacing_fallback")
    AREA_AND_SPACING_FALLBACK("area_and_spacing_fallback"),

    /** Not a banded application: treated area IS the gross area. */
    @SerialName("whole_block")
    WHOLE_BLOCK("whole_block"),

    /** Could not be determined. */
    @SerialName("unavailable")
    UNAVAILABLE("unavailable"),
    ;

    companion object {
        fun from(raw: String?): SprayTreatedAreaMethod? =
            entries.firstOrNull { it.raw == raw?.trim()?.lowercase() }
    }
}

/**
 * Gross vs actual treated area for an application.
 *
 * Both figures are always retained. Treated area NEVER replaces gross area —
 * reporting, per-hectare costs and whole-block product rates still need gross.
 */
data class SprayTreatedArea(
    val grossAreaHectares: Double,
    /** Actual treated hectares. Null when it could not be calculated. */
    val treatedAreaHectares: Double?,
    val method: SprayTreatedAreaMethod,
    val bandWidth: SprayBandWidth?,
    val rowLengthMetres: Double?,
) {
    /** Treated ÷ gross, e.g. 0.25 for a 0.8 m band at 3.2 m spacing. */
    val treatedFraction: Double?
        get() {
            val treated = treatedAreaHectares ?: return null
            return if (grossAreaHectares > 0) treated / grossAreaHectares else null
        }
}

object SprayBandedAreaCalculator {

    const val SQUARE_METRES_PER_HECTARE: Double = 10_000.0

    private fun positive(value: Double?): Double? =
        if (value != null && value.isFinite() && value > 0) value else null

    /**
     * Treated area from canonical row length — the authoritative form.
     *
     * ```text
     * treatedAreaHa = canonicalRowLengthMetres × totalTreatedBandWidthMetres ÷ 10_000
     * ```
     *
     * Example: 31,250 m × 0.8 m ÷ 10,000 = 2.50 ha treated (from a 10 ha block).
     */
    fun treatedAreaFromRowLength(rowLengthMetres: Double, bandWidthMetres: Double): Double? {
        val metres = positive(rowLengthMetres) ?: return null
        val band = positive(bandWidthMetres) ?: return null
        return metres * band / SQUARE_METRES_PER_HECTARE
    }

    /**
     * Fallback when no canonical row length exists but gross hectares and row
     * spacing are both known and valid.
     *
     * ```text
     * treatedAreaHa = grossBlockHa × totalTreatedBandWidthMetres ÷ rowSpacingMetres
     * ```
     *
     * Example: 10 ha × 0.8 m ÷ 3.2 m = 2.50 ha treated — the same answer the
     * canonical form gives, because deriving a row length from area and spacing
     * and then applying the band is algebraically identical.
     *
     * This is NEVER a fixed fraction of block area: without a real row spacing it
     * returns null instead of guessing.
     */
    fun treatedAreaFromAreaAndSpacing(
        grossAreaHectares: Double,
        rowSpacingMetres: Double,
        bandWidthMetres: Double,
    ): Double? {
        val area = positive(grossAreaHectares) ?: return null
        val spacing = positive(rowSpacingMetres) ?: return null
        val band = positive(bandWidthMetres) ?: return null
        return area * band / spacing
    }

    /**
     * Resolves treated area for ONE block, preferring canonical row length and
     * falling back to area × spacing.
     */
    fun banded(block: SprayBlockGeometry, bandWidth: SprayBandWidth): SprayTreatedArea {
        if (!bandWidth.isValid) {
            return SprayTreatedArea(
                grossAreaHectares = block.grossAreaHectares,
                treatedAreaHectares = null,
                method = SprayTreatedAreaMethod.UNAVAILABLE,
                bandWidth = bandWidth,
                rowLengthMetres = block.rowLengthMetres,
            )
        }
        val metres = positive(block.rowLengthMetres)
        if (metres != null) {
            val treated = treatedAreaFromRowLength(metres, bandWidth.totalMetres)
            if (treated != null) {
                return SprayTreatedArea(
                    grossAreaHectares = block.grossAreaHectares,
                    treatedAreaHectares = treated,
                    method = SprayTreatedAreaMethod.CANONICAL_ROW_LENGTH,
                    bandWidth = bandWidth,
                    rowLengthMetres = metres,
                )
            }
        }
        val fallback = treatedAreaFromAreaAndSpacing(
            grossAreaHectares = block.grossAreaHectares,
            rowSpacingMetres = block.rowSpacingMetres ?: 0.0,
            bandWidthMetres = bandWidth.totalMetres,
        )
        if (fallback != null) {
            return SprayTreatedArea(
                grossAreaHectares = block.grossAreaHectares,
                treatedAreaHectares = fallback,
                method = SprayTreatedAreaMethod.AREA_AND_SPACING_FALLBACK,
                bandWidth = bandWidth,
                rowLengthMetres = null,
            )
        }
        return SprayTreatedArea(
            grossAreaHectares = block.grossAreaHectares,
            treatedAreaHectares = null,
            method = SprayTreatedAreaMethod.UNAVAILABLE,
            bandWidth = bandWidth,
            rowLengthMetres = null,
        )
    }

    /**
     * Resolves treated area across the whole selection.
     *
     * Calculated PER BLOCK and then summed, so a selection whose blocks have
     * different row spacings stays correct — an averaged spacing would be wrong
     * for every block in the set.
     *
     * If ANY block cannot be resolved, the treated total is null: a partial
     * treated area silently under-doses the mix.
     */
    fun banded(geometry: SprayApplicationGeometry, bandWidth: SprayBandWidth): SprayTreatedArea {
        val perBlock = geometry.blocks.map { banded(it, bandWidth) }
        val treated: Double? =
            if (perBlock.isNotEmpty() && perBlock.all { it.treatedAreaHectares != null }) {
                perBlock.sumOf { it.treatedAreaHectares ?: 0.0 }
            } else {
                null
            }
        val method = when {
            treated == null -> SprayTreatedAreaMethod.UNAVAILABLE
            else -> {
                val first = perBlock.firstOrNull()?.method
                when {
                    first == null -> SprayTreatedAreaMethod.UNAVAILABLE
                    perBlock.all { it.method == first } -> first
                    else -> SprayTreatedAreaMethod.AREA_AND_SPACING_FALLBACK
                }
            }
        }
        return SprayTreatedArea(
            grossAreaHectares = geometry.grossAreaHectares,
            treatedAreaHectares = treated,
            method = method,
            bandWidth = bandWidth,
            rowLengthMetres = geometry.totalRowLengthMetres,
        )
    }

    /**
     * A non-banded application: the treated area IS the gross area. Modelled
     * explicitly so callers never have to special-case foliar jobs.
     */
    fun wholeBlock(geometry: SprayApplicationGeometry) = SprayTreatedArea(
        grossAreaHectares = geometry.grossAreaHectares,
        treatedAreaHectares = geometry.grossAreaHectares,
        method = SprayTreatedAreaMethod.WHOLE_BLOCK,
        bandWidth = null,
        rowLengthMetres = geometry.totalRowLengthMetres,
    )
}
