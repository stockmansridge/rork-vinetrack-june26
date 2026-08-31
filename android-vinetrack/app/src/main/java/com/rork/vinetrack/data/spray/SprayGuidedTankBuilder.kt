package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayTank
import java.util.UUID

/**
 * Builds the persisted `spray_records.tanks` payload from a
 * [SprayApplicationPlan] — the Kotlin twin of the iOS `buildSprayTanks`.
 *
 * ## Why this exists
 *
 * The guided flow's plan is the ONLY calculation authority for a banded pass:
 * it is what the Products step previews, what Review displays, and what the
 * snapshot (sql/191 + sql/192) is projected from. The legacy
 * [SprayCalculator.calculate] path multiplies every area rate by GROSS
 * hectares, so a treated-band product persisted through it would carry a
 * whole-block quantity stamped `treated_area` — a false compliance record.
 * Building the tanks off the SAME plan closes that gap: the quantity the
 * operator reviewed and the quantity persisted are one number.
 *
 * ## Contract (mirrors iOS `buildSprayTanks` exactly)
 *
 * - One [SprayTank] per full/partial tank from [SprayApplicationPlan.tankSplit].
 * - Per-tank chemical amounts come from [SprayProductLineResult.quantityPerFullTank]
 *   and [SprayProductLineResult.quantityInLastTank] — never re-derived here.
 * - A line the plan could not resolve is SKIPPED: it has no amount to put in
 *   ANY tank and must not contribute a silent zero as though it had been
 *   calculated and come out empty. (The flow refuses to save with an
 *   unresolved line, so this is defence in depth.)
 * - Each line persists the basis it was ACTUALLY calculated on
 *   ([SprayProductLineResult.basis]) — `treated_area` is stamped only onto a
 *   quantity the plan really multiplied by treated hectares.
 * - When there are no tanks (no water), a single empty tank is returned so the
 *   record still captures the rate/CF, matching both existing builders.
 */
object SprayGuidedTankBuilder {

    fun build(
        plan: SprayApplicationPlan,
        chosenSprayRate: Double,
        /**
         * Chemical Intelligence to FREEZE onto each line, keyed by
         * saved-chemical id (sql/194). Captured by the caller at save time —
         * this builder is pure and never reads the Chemical Store.
         */
        snapshots: Map<String, ChemicalLineSnapshot> = emptyMap(),
    ): List<SprayTank> {
        val split = plan.tankSplit
        val totalTanks = split.totalTanks
        if (totalTanks <= 0) {
            return listOf(
                SprayTank(
                    id = UUID.randomUUID().toString(),
                    tankNumber = 1,
                    waterVolume = 0.0,
                    sprayRatePerHa = chosenSprayRate,
                    concentrationFactor = plan.concentrationFactor,
                    chemicals = emptyList(),
                ),
            )
        }
        return (0 until totalTanks).map { i ->
            val isLast = i == totalTanks - 1
            val waterVolume = if (isLast && split.lastTankLitres > 0) {
                split.lastTankLitres
            } else {
                split.tankCapacityLitres
            }
            val chemicals = plan.productLines.mapNotNull { line ->
                val perFullTank = line.quantityPerFullTank ?: return@mapNotNull null
                val inLastTank = line.quantityInLastTank ?: return@mapNotNull null
                SprayChemical(
                    id = UUID.randomUUID().toString(),
                    name = line.name,
                    volumePerTank = if (isLast) inLastTank else perFullTank,
                    // The rate columns keep their legacy meaning: an area rate
                    // (whole-block OR treated-band) lives in ratePerHa, a
                    // per-100 L rate in ratePer100L. Which area it multiplied
                    // is carried by rateBasis, never by inflating the rate.
                    ratePerHa = if (line.basis.isAreaBased) line.rate else 0.0,
                    ratePer100L = if (line.basis == SprayProductRateBasis.PER_100_LITRES) {
                        line.rate
                    } else {
                        0.0
                    },
                    costPerUnit = line.costPerUnit ?: 0.0,
                    unit = line.unit,
                    // THE basis this quantity was computed on. `treated_area`
                    // can only appear here when the plan multiplied by treated
                    // hectares, because the plan is the only thing that set it.
                    rateBasis = line.basis.raw,
                    savedChemicalId = line.productId,
                    chemicalSnapshot = snapshots[line.productId],
                )
            }
            SprayTank(
                id = UUID.randomUUID().toString(),
                tankNumber = i + 1,
                waterVolume = waterVolume,
                sprayRatePerHa = chosenSprayRate,
                concentrationFactor = plan.concentrationFactor,
                chemicals = chemicals,
            )
        }
    }

    /**
     * Projects the plan into the legacy [SprayCalculator.Result] shape the
     * Spray Tank Mixing review screen renders.
     *
     * A PROJECTION, not a calculation: every figure is copied off the plan, so
     * the review, the Products-step preview, and the persisted tanks read the
     * same numbers by construction. Unresolved lines are omitted — the flow
     * refuses to reach the review while any line is unresolved.
     *
     * The legacy two-value basis cannot express Whole Block vs Treated Band;
     * both project to [SprayCalculator.RateBasis.PER_HECTARE] for display. The
     * persisted record keeps the real basis via [build].
     */
    fun reviewResult(plan: SprayApplicationPlan): SprayCalculator.Result =
        SprayCalculator.Result(
            totalAreaHectares = plan.grossAreaHectares,
            totalWaterLitres = plan.totalCarrierLitres,
            tankCapacityLitres = plan.tankSplit.tankCapacityLitres,
            fullTankCount = plan.tankSplit.fullTankCount,
            lastTankLitres = plan.tankSplit.lastTankLitres,
            concentrationFactor = plan.concentrationFactor,
            chemicalResults = plan.productLines.mapNotNull { line ->
                val total = line.totalQuantity ?: return@mapNotNull null
                SprayCalculator.ChemicalResult(
                    savedChemicalId = line.productId,
                    name = line.name,
                    unit = line.unit,
                    basis = if (line.basis == SprayProductRateBasis.PER_100_LITRES) {
                        SprayCalculator.RateBasis.PER_100L
                    } else {
                        SprayCalculator.RateBasis.PER_HECTARE
                    },
                    rate = line.rate,
                    totalAmount = total,
                    amountPerFullTank = line.quantityPerFullTank ?: 0.0,
                    amountInLastTank = line.quantityInLastTank ?: 0.0,
                    costPerUnit = line.costPerUnit,
                )
            },
        )
}
