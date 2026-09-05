package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
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

    /** Training systems from the iOS `CanopyType` model. */
    enum class CanopyType(val label: String) {
        VSP("VSP"),
        SPRAWL("Sprawl"),
    }

    /** Canopy sizes and system-specific dimensions from iOS. */
    enum class CanopySize(val label: String) {
        SMALL("Small"),
        MEDIUM("Medium"),
        LARGE("Large"),
        FULL("Full"),
        ;

        fun description(type: CanopyType): String = when (type to this) {
            CanopyType.VSP to SMALL -> "up to 0.5m × 0.5m"
            CanopyType.VSP to MEDIUM -> "up to 1m × 1m"
            CanopyType.VSP to LARGE -> "Wires Up - 1.5m × 0.5m"
            CanopyType.VSP to FULL -> "Wires Up - 2m × 0.5m"
            CanopyType.SPRAWL to SMALL -> "up to 0.5m × 0.5m"
            CanopyType.SPRAWL to MEDIUM -> "up to 1m × 1m"
            CanopyType.SPRAWL to LARGE -> "approx. 1.5m × 1.5m"
            CanopyType.SPRAWL to FULL -> "approx. 2m × 2m and above"
            else -> error("Unsupported canopy type and size")
        }
    }

    /** Canopy density options — Low and High select the range endpoints. */
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
        litresPer100m(rates, CanopyType.VSP, size, density)

    /** One shared VSP/Sprawl table for both carrier bases. */
    fun litresPer100m(
        rates: CanopyWaterRates,
        type: CanopyType,
        size: CanopySize,
        density: CanopyDensity,
    ): Double = when (Triple(type, size, density)) {
        Triple(CanopyType.VSP, CanopySize.SMALL, CanopyDensity.LOW) -> rates.smallLow
        Triple(CanopyType.VSP, CanopySize.SMALL, CanopyDensity.HIGH) -> rates.smallHigh
        Triple(CanopyType.VSP, CanopySize.MEDIUM, CanopyDensity.LOW) -> rates.mediumLow
        Triple(CanopyType.VSP, CanopySize.MEDIUM, CanopyDensity.HIGH) -> rates.mediumHigh
        Triple(CanopyType.VSP, CanopySize.LARGE, CanopyDensity.LOW) -> rates.largeLow
        Triple(CanopyType.VSP, CanopySize.LARGE, CanopyDensity.HIGH) -> rates.largeHigh
        Triple(CanopyType.VSP, CanopySize.FULL, CanopyDensity.LOW) -> rates.fullLow
        Triple(CanopyType.VSP, CanopySize.FULL, CanopyDensity.HIGH) -> rates.fullHigh
        Triple(CanopyType.SPRAWL, CanopySize.SMALL, CanopyDensity.LOW) -> rates.sprawlSmallLow
        Triple(CanopyType.SPRAWL, CanopySize.SMALL, CanopyDensity.HIGH) -> rates.sprawlSmallHigh
        Triple(CanopyType.SPRAWL, CanopySize.MEDIUM, CanopyDensity.LOW) -> rates.sprawlMediumLow
        Triple(CanopyType.SPRAWL, CanopySize.MEDIUM, CanopyDensity.HIGH) -> rates.sprawlMediumHigh
        Triple(CanopyType.SPRAWL, CanopySize.LARGE, CanopyDensity.LOW) -> rates.sprawlLargeLow
        Triple(CanopyType.SPRAWL, CanopySize.LARGE, CanopyDensity.HIGH) -> rates.sprawlLargeHigh
        Triple(CanopyType.SPRAWL, CanopySize.FULL, CanopyDensity.LOW) -> rates.sprawlFullLow
        else -> rates.sprawlFullHigh
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
        /**
         * The area basis the operator chose for each product line, keyed by
         * saved-chemical id.
         *
         * Only area-rated lines appear here; a per-100 L label is per-100 L
         * wherever it is used. A line that is absent falls back to whole block -
         * the legacy `per_hectare` meaning - so historical behaviour is never
         * restated. On a banded pass the guided flow will not let the spray be
         * saved until the choice has actually been made.
         */
        rateBases: Map<String, com.rork.vinetrack.data.spray.SprayProductRateBasis> = emptyMap(),
        /**
         * The Chemical Intelligence to FREEZE onto each product line, keyed by
         * saved-chemical id (sql/194).
         *
         * Captured by the caller from the Chemical Store at save time, because
         * the calculator is pure and must not read the store itself. A line whose
         * product has no structured intelligence is absent here and stays
         * honestly null rather than carrying invented chemistry.
         */
        snapshots: Map<String, ChemicalLineSnapshot> = emptyMap(),
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
                    // Snapshot the basis this line was actually calculated on.
                    // Without it a banded treated-band quantity would reload as a
                    // whole-block one and silently restate itself.
                    rateBasis = if (cr.basis == RateBasis.PER_100L) {
                        com.rork.vinetrack.data.spray.SprayProductRateBasis.PER_100_LITRES.raw
                    } else {
                        (
                            cr.savedChemicalId?.let { rateBases[it] }
                                ?: com.rork.vinetrack.data.spray.SprayProductRateBasis.WHOLE_BLOCK_AREA
                            ).raw
                    },
                    savedChemicalId = cr.savedChemicalId,
                    // Freeze today's chemistry onto the line. Re-classifying the
                    // product later must never restate what was applied here.
                    chemicalSnapshot = cr.savedChemicalId?.let { snapshots[it] },
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
