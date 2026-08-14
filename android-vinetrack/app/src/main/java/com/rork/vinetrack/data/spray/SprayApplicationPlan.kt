package com.rork.vinetrack.data.spray

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.ceil

/** What kind of application this is — decides how treated area is resolved. */
@Serializable
enum class SprayApplicationMode(val raw: String) {
    /** Whole-canopy application: treated area equals gross area. */
    @SerialName("whole_block")
    WHOLE_BLOCK("whole_block"),

    /** Banded/strip application: treated area comes from band width × row length. */
    @SerialName("banded")
    BANDED("banded"),
    ;

    companion object {
        fun from(raw: String?): SprayApplicationMode? =
            entries.firstOrNull { it.raw == raw?.trim()?.lowercase() }
    }
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
    /**
     * Whether the operator has EXPLICITLY chosen this line's area basis.
     *
     * Only meaningful for area-rated lines on a banded pass, where whole-block
     * and treated-band hectares differ by several times. `false` means "the
     * screen is showing a default nobody has confirmed", which the flow blocks
     * on rather than freezing a guess into a compliance record.
     *
     * Defaults to `true` so every legacy caller — and every historical record
     * replayed through the engine — keeps its existing meaning untouched.
     */
    val isAreaBasisExplicit: Boolean = true,
) {
    /**
     * True when this line still needs the operator to answer the Whole Block vs
     * Treated Band question.
     *
     * A per-100 L line is never ambiguous: its basis comes from the product's own
     * label, not from how the block was covered.
     */
    val needsAreaBasisDecision: Boolean get() = basis.isAreaBased && !isAreaBasisExplicit
}

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
    /**
     * The MEASURED value this line's rate was multiplied against — gross
     * hectares, treated hectares, carrier litres or row metres, depending on
     * [basis].
     *
     * Carried out of the planner so the UI can explain a quantity
     * ("2 L/ha × 10.00 ha whole block") without recomputing anything. A screen
     * that reached for its own hectares here could show a sum that no longer
     * matches the persisted record. Null when the input was unavailable, which
     * is exactly when [totalQuantity] is null too.
     */
    val basisInput: Double? = null,
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

    /**
     * Why this line cannot be calculated, as the ONE input that is missing.
     *
     * Distinguishing these matters: a treated-area product needs band geometry,
     * while a per-100 L product needs the carrier step — telling an operator to
     * fix the wrong one wastes a spray window.
     */
    val unresolvedReason: SprayProductUnresolvedReason?
        get() = if (!isUnresolved) {
            null
        } else {
            when (basis) {
                SprayProductRateBasis.WHOLE_BLOCK_AREA ->
                    SprayProductUnresolvedReason.GROSS_AREA_UNAVAILABLE
                SprayProductRateBasis.TREATED_AREA ->
                    SprayProductUnresolvedReason.TREATED_AREA_UNAVAILABLE
                SprayProductRateBasis.PER_100_LITRES ->
                    SprayProductUnresolvedReason.CARRIER_UNAVAILABLE
                SprayProductRateBasis.PER_100_METRES ->
                    SprayProductUnresolvedReason.ROW_LENGTH_UNAVAILABLE
            }
        }
}

/** The single missing input behind an unresolved product line. */
enum class SprayProductUnresolvedReason(val title: String, val message: String) {
    GROSS_AREA_UNAVAILABLE(
        "Block area required",
        "Select blocks with an area before this product can be calculated.",
    ),
    TREATED_AREA_UNAVAILABLE(
        "Treated area unavailable",
        "Complete the band width and block geometry before this product can be calculated.",
    ),
    CARRIER_UNAVAILABLE(
        "Carrier volume required",
        "Complete the Carrier Volume step before this product quantity can be calculated.",
    ),
    ROW_LENGTH_UNAVAILABLE(
        "Row length unavailable",
        "Complete the block row geometry before this product can be calculated.",
    ),
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
            val basisInput = SprayProductQuantityCalculator.basisInput(line.basis, context)
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
                basisInput = basisInput,
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
