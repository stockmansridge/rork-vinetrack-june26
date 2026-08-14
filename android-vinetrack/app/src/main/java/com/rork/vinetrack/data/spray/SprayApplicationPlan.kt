package com.rork.vinetrack.data.spray

import kotlin.math.ceil

/** What kind of application this is — decides how treated area is resolved. */
enum class SprayApplicationMode(val raw: String) {
    /** Whole-canopy application: treated area equals gross area. */
    WHOLE_BLOCK("whole_block"),

    /** Banded/strip application: treated area comes from band width × row length. */
    BANDED("banded"),
}

/**
 * One product line fed into the plan.
 *
 * [rate] is expressed in the product's own unit (L, mL, kg, g) per its [basis].
 * The engine is unit-agnostic: quantities come back in the SAME unit as [rate].
 */
data class SprayProductLineInput(
    val productId: String,
    val name: String,
    val unit: String,
    val basis: SprayProductRateBasis,
    val rate: Double,
    val costPerUnit: Double? = null,
)

/** A calculated product line. */
data class SprayProductLineResult(
    val productId: String,
    val name: String,
    val unit: String,
    val basis: SprayProductRateBasis,
    val rate: Double,
    /**
     * Total product for the whole job, in [unit]. Null when the basis's input was
     * unavailable (e.g. a treated-area product with no band width).
     */
    val totalQuantity: Double?,
    val quantityPerFullTank: Double?,
    val quantityInLastTank: Double?,
    val costPerUnit: Double?,
) {
    val totalCost: Double?
        get() {
            val total = totalQuantity ?: return null
            val cost = costPerUnit ?: return null
            return if (cost > 0) total * cost else null
        }

    /**
     * True when this line could not be calculated and must be surfaced to the
     * operator rather than silently omitted from the mix.
     */
    val isUnresolved: Boolean get() = totalQuantity == null
}

/** How the carrier volume splits into tanks. */
data class SprayTankSplit(
    val tankCapacityLitres: Double,
    val fullTankCount: Int,
    val lastTankLitres: Double,
) {
    val totalTanks: Int get() = fullTankCount + if (lastTankLitres > 0) 1 else 0
}

/**
 * THE end-to-end spray calculation result — the Kotlin twin of the Swift
 * `SprayApplicationPlan`.
 *
 * Pipeline, in order, each stage feeding the next:
 *
 * ```text
 * Row geometry → Application geometry → Carrier volume → Product quantities → Tank splits
 * ```
 *
 * Gross and treated hectares are BOTH retained; treated area never replaces
 * gross. The banded treated-area calculation and the L/100 m carrier volume read
 * the SAME `geometry.totalRowLengthMetres`, so they cannot disagree.
 */
data class SprayApplicationPlan(
    val mode: SprayApplicationMode,
    val geometry: SprayApplicationGeometry,
    val treatedArea: SprayTreatedArea,
    val carrier: SprayCarrierVolume,
    val tankSplit: SprayTankSplit,
    val productLines: List<SprayProductLineResult>,
) {
    val grossAreaHectares: Double get() = treatedArea.grossAreaHectares
    val treatedAreaHectares: Double? get() = treatedArea.treatedAreaHectares
    val totalCarrierLitres: Double get() = carrier.totalLitres
    val concentrationFactor: Double get() = carrier.concentrationFactor

    /** Product lines that could not be calculated. */
    val unresolvedProductLines: List<SprayProductLineResult> get() = productLines.filter { it.isUnresolved }

    val totalProductCost: Double?
        get() {
            val costs = productLines.mapNotNull { it.totalCost }
            return if (costs.isEmpty()) null else costs.sum()
        }

    /** Cost per GROSS hectare — the basis every existing report uses. */
    val costPerGrossHectare: Double?
        get() {
            val total = totalProductCost ?: return null
            return if (grossAreaHectares > 0) total / grossAreaHectares else null
        }

    /** Cost per TREATED hectare — only meaningful for banded jobs. */
    val costPerTreatedHectare: Double?
        get() {
            val total = totalProductCost ?: return null
            val treated = treatedAreaHectares ?: return null
            return if (treated > 0) total / treated else null
        }
}

object SprayApplicationPlanner {

    /**
     * Splits a carrier volume into tanks.
     *
     * Arithmetic preserved EXACTLY from the existing [com.rork.vinetrack.data.SprayCalculator]
     * so tank counts and per-tank volumes on current jobs cannot shift.
     */
    fun tankSplit(totalLitres: Double, tankCapacityLitres: Double): SprayTankSplit {
        if (totalLitres <= 0 || tankCapacityLitres <= 0) {
            return SprayTankSplit(tankCapacityLitres, fullTankCount = 0, lastTankLitres = 0.0)
        }
        val numberOfTanks = ceil(totalLitres / tankCapacityLitres).toInt()
        val fullTankCount = if (totalLitres > tankCapacityLitres) numberOfTanks - 1 else 0
        val lastTankLitres = if (totalLitres <= tankCapacityLitres) {
            totalLitres
        } else {
            totalLitres - (fullTankCount * tankCapacityLitres)
        }
        return SprayTankSplit(tankCapacityLitres, fullTankCount, lastTankLitres)
    }

    /**
     * Builds the full plan.
     *
     * @param blocks the selected blocks' raw geometry inputs.
     * @param mode whole-block or banded.
     * @param bandWidth required for [SprayApplicationMode.BANDED]; ignored otherwise.
     * @param carrier a resolved carrier volume (built via
     *   [SprayCarrierVolumeCalculator]). Passed in rather than derived so the
     *   caller controls whether L/ha or L/100 m applies.
     */
    fun plan(
        blocks: List<SprayBlockInput>,
        mode: SprayApplicationMode,
        bandWidth: SprayBandWidth? = null,
        carrier: SprayCarrierVolume,
        tankCapacityLitres: Double,
        productLines: List<SprayProductLineInput>,
    ): SprayApplicationPlan {
        val geometry = SprayGeometryResolver.resolve(blocks)

        val treated = when (mode) {
            SprayApplicationMode.WHOLE_BLOCK -> SprayBandedAreaCalculator.wholeBlock(geometry)
            SprayApplicationMode.BANDED -> if (bandWidth == null) {
                SprayTreatedArea(
                    grossAreaHectares = geometry.grossAreaHectares,
                    treatedAreaHectares = null,
                    method = SprayTreatedAreaMethod.UNAVAILABLE,
                    bandWidth = null,
                    rowLengthMetres = geometry.totalRowLengthMetres,
                )
            } else {
                SprayBandedAreaCalculator.banded(geometry, bandWidth)
            }
        }

        val context = SprayQuantityContext.of(geometry, carrier, treated.treatedAreaHectares)
        val split = tankSplit(carrier.totalLitres, tankCapacityLitres)

        val lines = productLines.map { line ->
            val total = SprayProductQuantityCalculator.totalQuantity(line.rate, line.basis, context)
            var perFullTank: Double? = if (total == null) null else 0.0
            var inLastTank: Double? = if (total == null) null else 0.0
            if (total != null && carrier.totalLitres > 0 && split.totalTanks > 0) {
                perFullTank = total * (split.tankCapacityLitres / carrier.totalLitres)
                inLastTank = if (split.lastTankLitres > 0) {
                    total * (split.lastTankLitres / carrier.totalLitres)
                } else if (split.totalTanks == 1) {
                    total
                } else {
                    0.0
                }
            }
            SprayProductLineResult(
                productId = line.productId,
                name = line.name,
                unit = line.unit,
                basis = line.basis,
                rate = line.rate,
                totalQuantity = total,
                quantityPerFullTank = perFullTank,
                quantityInLastTank = inLastTank,
                costPerUnit = line.costPerUnit,
            )
        }

        return SprayApplicationPlan(
            mode = mode,
            geometry = geometry,
            treatedArea = treated,
            carrier = carrier,
            tankSplit = split,
            productLines = lines,
        )
    }
}
