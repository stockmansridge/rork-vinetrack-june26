package com.rork.vinetrack.data.spray

/**
 * What a product's label rate is measured AGAINST — the Kotlin twin of the Swift
 * `SprayProductRateBasis`.
 *
 * This belongs to each product line, NOT to the spray job: one tank mix can
 * legitimately contain a whole-block-area product, a treated-area product and a
 * per-100 L adjuvant at the same time.
 *
 * This is the PRODUCT LABEL RATE BASIS and is independent of
 * [SprayCarrierBasis] (how the grower enters carrier volume).
 */
enum class SprayProductRateBasis(val raw: String, val label: String) {
    /** Rate × GROSS block hectares. The legacy `per_hectare` meaning. */
    WHOLE_BLOCK_AREA("whole_block_area", "Per whole block ha"),

    /** Rate × ACTUAL TREATED hectares (banded/strip applications). */
    TREATED_AREA("treated_area", "Per treated ha"),

    /** Rate × carrier litres ÷ 100. */
    PER_100_LITRES("per_100_litres", "Per 100 L"),

    /** Rate × row metres ÷ 100 — distance-based label rates. */
    PER_100_METRES("per_100_metres", "Per 100 m"),
    ;

    /** Whether this basis measures against an area (used for reporting labels). */
    val isAreaBased: Boolean get() = this == WHOLE_BLOCK_AREA || this == TREATED_AREA

    /**
     * The stored value for a legacy reader that only understands `per_hectare` /
     * `per_100_litres`, so older clients and the portal keep working while the
     * new basis is rolled out.
     */
    val legacyCompatibleValue: String
        get() = if (this == PER_100_LITRES) "per_100_litres" else "per_hectare"

    companion object {
        /**
         * Deterministic mapping from the legacy stored strings.
         *
         * `per_hectare` maps to [WHOLE_BLOCK_AREA] because that is EXACTLY what
         * every existing record computed — including banded jobs, which
         * multiplied the rate by gross block hectares. Mapping it to
         * [TREATED_AREA] would silently restate historical quantities.
         */
        fun legacy(raw: String?): SprayProductRateBasis? {
            val value = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            entries.firstOrNull { it.raw == value }?.let { return it }
            return when (value) {
                "per_hectare", "perhectare", "per_ha", "l/ha", "per hectare" -> WHOLE_BLOCK_AREA
                "per_100_litres", "per100litres", "per_100l", "per 100l", "l/100l" -> PER_100_LITRES
                "per_100_metres", "per100metres", "per_100m", "l/100m" -> PER_100_METRES
                else -> null
            }
        }
    }
}

/** The measured application a product quantity is calculated against. */
data class SprayQuantityContext(
    val grossAreaHectares: Double,
    /** Actual treated hectares. Null when not a banded job or not calculable. */
    val treatedAreaHectares: Double? = null,
    /** Total ACTUAL carrier litres. */
    val carrierLitres: Double,
    /**
     * `dilute ÷ applied`. Per-100 L label rates are written against the DILUTE
     * volume, so concentrating must not reduce the product dose.
     */
    val concentrationFactor: Double = 1.0,
    val rowLengthMetres: Double? = null,
) {
    companion object {
        /**
         * Builds a context from canonical geometry + a resolved carrier volume,
         * so the treated area and the carrier volume provably share one row
         * length.
         */
        fun of(
            geometry: SprayApplicationGeometry,
            carrier: SprayCarrierVolume,
            treatedAreaHectares: Double? = null,
        ) = SprayQuantityContext(
            grossAreaHectares = geometry.grossAreaHectares,
            treatedAreaHectares = treatedAreaHectares,
            carrierLitres = carrier.totalLitres,
            concentrationFactor = carrier.concentrationFactor,
            rowLengthMetres = geometry.totalRowLengthMetres,
        )
    }
}

object SprayProductQuantityCalculator {

    /**
     * Total product required, expressed in the SAME unit as [rate].
     *
     * ```text
     * WHOLE_BLOCK_AREA → rate × grossAreaHectares
     * TREATED_AREA     → rate × treatedAreaHectares
     * PER_100_LITRES   → rate × carrierLitres ÷ 100 × concentrationFactor
     * PER_100_METRES   → rate × rowLengthMetres ÷ 100
     * ```
     *
     * Returns null when the input this basis depends on is unavailable — never
     * 0, which would understate a dose.
     */
    fun totalQuantity(
        rate: Double,
        basis: SprayProductRateBasis,
        context: SprayQuantityContext,
    ): Double? {
        if (!rate.isFinite() || rate < 0) return null
        return when (basis) {
            SprayProductRateBasis.WHOLE_BLOCK_AREA -> {
                val area = context.grossAreaHectares
                if (area.isFinite() && area > 0) rate * area else null
            }
            SprayProductRateBasis.TREATED_AREA -> {
                val treated = context.treatedAreaHectares
                if (treated != null && treated.isFinite() && treated > 0) rate * treated else null
            }
            SprayProductRateBasis.PER_100_LITRES -> {
                val litres = context.carrierLitres
                if (!litres.isFinite() || litres <= 0) {
                    null
                } else {
                    val factor = if (context.concentrationFactor.isFinite() &&
                        context.concentrationFactor > 0
                    ) {
                        context.concentrationFactor
                    } else {
                        1.0
                    }
                    rate * litres / 100.0 * factor
                }
            }
            SprayProductRateBasis.PER_100_METRES -> {
                val metres = context.rowLengthMetres
                if (metres != null && metres.isFinite() && metres > 0) rate * metres / 100.0 else null
            }
        }
    }
}
