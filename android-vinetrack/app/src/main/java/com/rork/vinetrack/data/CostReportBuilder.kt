package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine

/**
 * Pure, read-only Cost Reports aggregator mirroring the iOS `CostReportsView`
 * data model. Where iOS reads pre-computed `tripCostAllocations` synced from the
 * backend, Android has no allocation table, so this rebuilds equivalent rows on
 * the fly from completed trips using the existing [TripCostEstimator] (the same
 * pure costing used on Trip detail and exports).
 *
 * One [CostAllocationRow] is produced per (trip × variety): a trip's cost and
 * treated area are split across its block's variety allocations by percentage,
 * matching the iOS "Season × Block × Variety" breakdown. Yield is intentionally
 * NOT carried per trip (that would over-count when a block has many trips);
 * callers resolve season-block yield once via [seasonBlockYieldTonnes].
 *
 * Owners/managers only — callers must gate on the costing role before building.
 */
object CostReportBuilder {

    data class CostAllocationRow(
        val tripId: String,
        val seasonYear: Int,
        val paddockId: String?,
        val paddockName: String,
        /** Variety display name, or "Unassigned variety" when none resolves. */
        val variety: String,
        /** Fraction (0–1) of the block this variety occupies, for yield splitting. */
        val varietyFraction: Double,
        val tripFunction: String?,
        val areaHa: Double,
        val labourCost: Double,
        val fuelCost: Double,
        val chemicalCost: Double,
        val totalCost: Double,
        val tripDateEpochMs: Long?,
        val warnings: List<String>,
    )

    const val UNASSIGNED_VARIETY: String = "Unassigned variety"

    /**
     * Build allocation rows for every completed (ended, non-deleted) trip in the
     * supplied data set. Active/aborted trips and trips without a start date are
     * skipped so the report only reflects finished work.
     */
    fun build(
        trips: List<Trip>,
        sprayRecords: List<SprayRecord>,
        operatorCategories: List<OperatorCategory>,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        paddocks: List<Paddock>,
        seasonStartMonth: Int = 7,
        seasonStartDay: Int = 1,
    ): List<CostAllocationRow> {
        val rows = mutableListOf<CostAllocationRow>()

        for (trip in trips) {
            if (trip.deletedAt != null) continue
            if (trip.isActive) continue
            val start = trip.startEpochMs ?: continue
            // A trip counts toward costs once it has finished.
            if (trip.endEpochMs == null) continue

            // Costing groups by production VINTAGE (sql/119) — resolved from
            // the trip date + the vineyard's shared season-start setting, NOT
            // the calendar year. July 2026 work under a 1 July start → Vintage 2027.
            val season = VintageResolver.vintageYearForEpochMs(start, seasonStartMonth, seasonStartDay)

            val sprayRecord = sprayRecords.firstOrNull { it.tripId == trip.id && it.deletedAt == null }
            val est = TripCostEstimator.estimate(
                trip = trip,
                sprayRecord = sprayRecord,
                operatorCategories = operatorCategories,
                machines = machines,
                fuelPurchases = fuelPurchases,
                paddocks = paddocks,
            )

            val paddock = trip.paddockId?.let { id -> paddocks.firstOrNull { it.id == id } }
            val treatedArea = est.treatedAreaHa ?: paddock?.areaHectares ?: 0.0
            val paddockName = paddock?.name
                ?: trip.paddockName?.takeIf { it.isNotBlank() }
                ?: "Unassigned block"

            val total = est.totalCost
            val labour = est.labour.cost
            val fuel = est.fuel.fuelCost ?: 0.0
            val chemical = est.chemical?.cost ?: 0.0

            val allocations = paddock?.varietyAllocations.orEmpty()
            if (allocations.isEmpty()) {
                rows.add(
                    CostAllocationRow(
                        tripId = trip.id,
                        seasonYear = season,
                        paddockId = trip.paddockId,
                        paddockName = paddockName,
                        variety = UNASSIGNED_VARIETY,
                        varietyFraction = 1.0,
                        tripFunction = trip.tripFunction,
                        areaHa = treatedArea,
                        labourCost = labour,
                        fuelCost = fuel,
                        chemicalCost = chemical,
                        totalCost = total,
                        tripDateEpochMs = start,
                        warnings = est.warnings,
                    )
                )
            } else {
                // Normalise percentages so a trip's cost is fully distributed
                // even when allocation percents don't sum to 100.
                val totalPct = allocations.sumOf { (it.displayPercent ?: 0.0).coerceAtLeast(0.0) }
                allocations.forEach { alloc ->
                    val pct = (alloc.displayPercent ?: 0.0).coerceAtLeast(0.0)
                    val frac = when {
                        totalPct > 0 -> pct / totalPct
                        else -> 1.0 / allocations.size
                    }
                    val name = alloc.displayName?.takeIf { it.isNotBlank() } ?: UNASSIGNED_VARIETY
                    rows.add(
                        CostAllocationRow(
                            tripId = trip.id,
                            seasonYear = season,
                            paddockId = trip.paddockId,
                            paddockName = paddockName,
                            variety = name,
                            varietyFraction = frac,
                            tripFunction = trip.tripFunction,
                            areaHa = treatedArea * frac,
                            labourCost = labour * frac,
                            fuelCost = fuel * frac,
                            chemicalCost = chemical * frac,
                            totalCost = total * frac,
                            tripDateEpochMs = start,
                            warnings = est.warnings,
                        )
                    )
                }
            }
        }

        return rows
    }

    /**
     * Season yield for a single block, in tonnes. Prefers recorded actuals over
     * estimates. Counted once per (season, block) — never per trip — so cost per
     * tonne stays accurate regardless of how many trips treated the block.
     */
    fun seasonBlockYieldTonnes(
        yieldRecords: List<HistoricalYieldRecord>,
        seasonYear: Int,
        paddockId: String?,
    ): Double {
        if (paddockId == null) return 0.0
        return yieldRecords
            .filter { it.deletedAt == null && it.year == seasonYear }
            .flatMap { it.blocks }
            .filter { it.paddockId == paddockId }
            .sumOf { it.actualYieldTonnes ?: it.yieldTonnes }
    }
}
