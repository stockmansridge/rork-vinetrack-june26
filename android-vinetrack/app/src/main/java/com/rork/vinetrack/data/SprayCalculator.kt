package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayTank
import java.util.UUID
import kotlin.math.ceil

/**
 * Pure spray-calculation engine, mirroring the iOS `SprayCalculator.calculate`.
 *
 * Given a set of selected blocks (paddocks), a chosen water rate (L/ha), a tank
 * capacity, and a list of chemical lines, it derives the total area, total water
 * volume, the number/size of tanks, and the per-chemical amounts (total, per
 * full tank, in the last tank) plus an optional costing breakdown.
 *
 * Unlike iOS — which normalises everything into chemical base units — Android
 * works consistently in each chemical's own display unit (L/mL/Kg/g), matching
 * the rest of the Android spray form where `ratePerHa`, `volumePerTank` and
 * `costPerUnit` are all expressed in the display unit. The formulas otherwise
 * match iOS exactly.
 */
object SprayCalculator {

    /**
     * Canopy size options — labels, descriptions, and reference images all match
     * the iOS `CanopySize` enum so growers see identical guidance on both
     * platforms. The reference images are the canonical shared R2 assets iOS
     * loads, rendered here via Coil.
     */
    enum class CanopySize(val label: String, val description: String, val referenceImageUrl: String) {
        SMALL("Small", "up to 0.5m × 0.5m", "https://r2-pub.rork.com/attachments/n9g6j5bjz0l47bkxhd42r.png"),
        MEDIUM("Medium", "up to 1m × 1m", "https://pub-e001eb4506b145aa938b5d3badbff6a5.r2.dev/attachments/5dye3l0veago38uvra0ec.png"),
        LARGE("Large", "Wires Up - 1.5m × 0.5m", "https://pub-e001eb4506b145aa938b5d3badbff6a5.r2.dev/attachments/00p3rr1b6qpdaht5ihsdh.png"),
        FULL("Full", "Wires Up - 2m × 0.5m", "https://pub-e001eb4506b145aa938b5d3badbff6a5.r2.dev/attachments/iducbl7zsx0yk8ftvuntf.png"),
    }

    /** Canopy density options — raw values match the iOS `CanopyDensity` enum. */
    enum class CanopyDensity(val label: String, val description: String) {
        LOW("Low", "Open canopy — light passes through, gaps between shoots."),
        HIGH("High", "Dense canopy — full leaf wall, little light through."),
    }

    /** Chemical rate basis — matches the iOS `RateBasis`/`ChemicalRateBasis`. */
    enum class RateBasis(val label: String) {
        PER_HECTARE("Per hectare"),
        PER_100L("Per 100L"),
    }

    /**
     * Look up the indicative litres-per-100m for a canopy size × density from a
     * [CanopyWaterRates] preference set.
     */
    fun litresPer100m(rates: CanopyWaterRates, size: CanopySize, density: CanopyDensity): Double =
        when (size to density) {
            CanopySize.SMALL to CanopyDensity.LOW -> rates.smallLow
            CanopySize.SMALL to CanopyDensity.HIGH -> rates.smallHigh
            CanopySize.MEDIUM to CanopyDensity.LOW -> rates.mediumLow
            CanopySize.MEDIUM to CanopyDensity.HIGH -> rates.mediumHigh
            CanopySize.LARGE to CanopyDensity.LOW -> rates.largeLow
            CanopySize.LARGE to CanopyDensity.HIGH -> rates.largeHigh
            CanopySize.FULL to CanopyDensity.LOW -> rates.fullLow
            else -> rates.fullHigh
        }

    /** Whether an operation type uses the per-100L concentration factor (foliar only). */
    fun usesConcentrationFactor(operationType: String): Boolean =
        operationType == "Foliar Spray"

    /** A single chemical line fed into the calculator. */
    data class Line(
        val savedChemicalId: String,
        val name: String,
        val unit: String,
        val basis: RateBasis,
        /** Rate in the chemical's display unit per the selected basis. */
        val rate: Double,
        /** Cost per display unit ($/L, $/Kg, …); null when unknown. */
        val costPerUnit: Double?,
    )

    /** Per-chemical calculated amounts (display unit). */
    data class ChemicalResult(
        val savedChemicalId: String,
        val name: String,
        val unit: String,
        val basis: RateBasis,
        val rate: Double,
        val totalAmount: Double,
        val amountPerFullTank: Double,
        val amountInLastTank: Double,
        val costPerUnit: Double?,
    ) {
        /** Total cost across the whole job, when a per-unit cost is known. */
        val totalCost: Double? get() = costPerUnit?.takeIf { it > 0 }?.let { totalAmount * it }
    }

    /** Full calculation output. */
    data class Result(
        val totalAreaHectares: Double,
        val totalWaterLitres: Double,
        val tankCapacityLitres: Double,
        val fullTankCount: Int,
        val lastTankLitres: Double,
        val concentrationFactor: Double,
        val chemicalResults: List<ChemicalResult>,
    ) {
        /** Total tanks needed (full + a partial last tank, if any). */
        val totalTanks: Int get() = fullTankCount + if (lastTankLitres > 0) 1 else 0

        /** Total chemical cost across all lines, when any costs are known. */
        val totalChemicalCost: Double? get() {
            val costs = chemicalResults.mapNotNull { it.totalCost }
            return if (costs.isEmpty()) null else costs.sum()
        }

        /** Chemical cost per hectare — only when area and a cost are both known. */
        val costPerHectare: Double? get() {
            val total = totalChemicalCost ?: return null
            return if (totalAreaHectares > 0) total / totalAreaHectares else null
        }

        val hasCostData: Boolean get() = chemicalResults.any { it.totalCost != null }
    }

    /**
     * Run the calculation. Mirrors iOS `SprayCalculator.calculate`.
     *
     * @param waterRateLitresPerHectare the chosen spray rate (L/ha)
     * @param tankCapacity equipment tank capacity (L)
     */
    fun calculate(
        selectedPaddocks: List<Paddock>,
        waterRateLitresPerHectare: Double,
        tankCapacity: Double,
        lines: List<Line>,
        concentrationFactor: Double = 1.0,
        operationType: String = "Foliar Spray",
    ): Result {
        val totalArea = selectedPaddocks.sumOf { it.areaHectares }
        val totalWater = totalArea * waterRateLitresPerHectare

        val numberOfTanks = if (totalWater > 0 && tankCapacity > 0) {
            ceil(totalWater / tankCapacity).toInt()
        } else 0
        val fullTankCount = if (totalWater > tankCapacity && tankCapacity > 0) numberOfTanks - 1 else 0
        val lastTankLitres = when {
            totalWater <= 0 -> 0.0
            totalWater <= tankCapacity -> totalWater
            else -> totalWater - (fullTankCount * tankCapacity)
        }

        val foliar = usesConcentrationFactor(operationType)

        val chemicalResults = lines.map { line ->
            val totalAmount = when {
                foliar && line.basis == RateBasis.PER_100L -> {
                    val units100 = totalWater / 100.0
                    units100 * line.rate * concentrationFactor
                }
                else -> line.rate * totalArea // per-hectare (and all banded/spreader)
            }
            val amountPerFullTank = if (numberOfTanks > 0 && totalWater > 0) {
                totalAmount * (tankCapacity / totalWater)
            } else 0.0
            val amountInLastTank = when {
                lastTankLitres > 0 && totalWater > 0 -> totalAmount * (lastTankLitres / totalWater)
                numberOfTanks == 1 -> totalAmount
                else -> 0.0
            }
            ChemicalResult(
                savedChemicalId = line.savedChemicalId,
                name = line.name,
                unit = line.unit,
                basis = line.basis,
                rate = line.rate,
                totalAmount = totalAmount,
                amountPerFullTank = amountPerFullTank,
                amountInLastTank = amountInLastTank,
                costPerUnit = line.costPerUnit,
            )
        }

        return Result(
            totalAreaHectares = totalArea,
            totalWaterLitres = totalWater,
            tankCapacityLitres = tankCapacity,
            fullTankCount = fullTankCount,
            lastTankLitres = lastTankLitres,
            concentrationFactor = concentrationFactor,
            chemicalResults = chemicalResults,
        )
    }

    /**
     * Build the canonical `spray_records.tanks` JSON for a result, mirroring the
     * iOS `buildSprayTanks`: one tank per full/partial tank, each carrying the
     * per-tank chemical amounts. When there are no tanks (no water), a single
     * empty tank is returned so the record still captures the rate/CF.
     */
    fun buildTanks(
        result: Result,
        chosenSprayRate: Double,
    ): List<SprayTank> {
        val totalTanks = result.totalTanks
        if (totalTanks <= 0) {
            return listOf(
                SprayTank(
                    id = UUID.randomUUID().toString(),
                    tankNumber = 1,
                    waterVolume = 0.0,
                    sprayRatePerHa = chosenSprayRate,
                    concentrationFactor = result.concentrationFactor,
                    chemicals = emptyList(),
                ),
            )
        }
        return (0 until totalTanks).map { i ->
            val isLast = i == totalTanks - 1
            val waterVolume = if (isLast && result.lastTankLitres > 0) {
                result.lastTankLitres
            } else {
                result.tankCapacityLitres
            }
            val chemicals = result.chemicalResults.map { cr ->
                val amount = if (isLast) cr.amountInLastTank else cr.amountPerFullTank
                SprayChemical(
                    id = UUID.randomUUID().toString(),
                    name = cr.name,
                    volumePerTank = amount,
                    ratePerHa = if (cr.basis == RateBasis.PER_HECTARE) cr.rate else 0.0,
                    ratePer100L = if (cr.basis == RateBasis.PER_100L) cr.rate else 0.0,
                    costPerUnit = cr.costPerUnit ?: 0.0,
                    unit = cr.unit,
                    savedChemicalId = cr.savedChemicalId,
                )
            }
            SprayTank(
                id = UUID.randomUUID().toString(),
                tankNumber = i + 1,
                waterVolume = waterVolume,
                sprayRatePerHa = chosenSprayRate,
                concentrationFactor = result.concentrationFactor,
                chemicals = chemicals,
            )
        }
    }
}
