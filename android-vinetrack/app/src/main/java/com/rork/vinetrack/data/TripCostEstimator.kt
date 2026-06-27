package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SavedInput
import com.rork.vinetrack.data.model.SeedingMixLine
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.resolveTripOperatorCategory
import java.util.Calendar
import java.util.TimeZone

/**
 * Pure, read-only total-cost estimator for a single trip (Stage 3F-3b-i),
 * mirroring the labour/fuel/chemical portion of the iOS
 * `TripCostService.estimate(...)`. Produces a labour + fuel + chemical + total
 * breakdown with completeness state and human-friendly warnings.
 *
 * Adds single-paddock cost/ha (Stage 3F-3b-ii): treated area is resolved from
 * `trip.paddockId → Paddock.areaHectares` only. Multi-block area summing and
 * cost/tonne remain out of scope. No persistence, no UI — callers must gate
 * display to owner/manager. Fuel is delegated to [TripFuelEstimator].
 */
object TripCostEstimator {

    /** Overall confidence in the rollup, mirroring iOS `CostingCompleteness`. */
    enum class Completeness {
        Complete,
        Partial,
        Unavailable,
    }

    data class LabourBreakdown(
        val categoryName: String?,
        val costPerHour: Double?,
        val hours: Double,
        val cost: Double,
        val warning: String?,
    )

    /**
     * Chemical cost for a linked spray record. Null when no spray record is
     * linked (chemical cost is then not applicable rather than $0).
     */
    data class ChemicalBreakdown(
        val cost: Double,
        val warning: String?,
    )

    /**
     * Seed/input cost for a seeding/spreading/fertilising trip carrying
     * [com.rork.vinetrack.data.model.SeedingDetails]. Null when the trip has no
     * seeding mix lines (input cost is then not applicable rather than $0).
     */
    data class SeedingBreakdown(
        val cost: Double,
        val missingCount: Int,
        val warning: String?,
    )

    data class Estimate(
        val activeHours: Double,
        val labour: LabourBreakdown,
        val fuel: TripFuelEstimator.Estimate,
        val chemical: ChemicalBreakdown?,
        /** Seed/input cost; null when the trip carries no seeding mix lines. */
        val seeding: SeedingBreakdown?,
        val totalCost: Double,
        /** Single-paddock treated area in hectares; null when unavailable. */
        val treatedAreaHa: Double?,
        /** totalCost / treatedAreaHa when both are usable, else null. */
        val costPerHa: Double?,
        /** Explains why cost/ha is missing; null when area is usable. */
        val areaWarning: String?,
        /**
         * Recorded actual yield tonnes for the linked paddock, sourced from
         * [HistoricalYieldRecord.blockResults]. Null when no reliable match
         * exists — we never guess (mirrors iOS `TripCostService`).
         */
        val yieldTonnes: Double?,
        /** totalCost / yieldTonnes when both are usable, else null. */
        val costPerTonne: Double?,
        /** Explains why cost/tonne is missing; null when yield is usable. */
        val yieldWarning: String?,
        val completeness: Completeness,
        val warnings: List<String>,
    )

    /**
     * Estimate labour + fuel + chemical + total cost for [trip].
     *
     * @param trip the trip being costed.
     * @param sprayRecord the linked spray record (`spray_records.trip_id == trip.id`)
     *   when one exists. Drives chemical cost; null when no spray is linked.
     * @param operatorCategories all vineyard operator categories, used to resolve
     *   the trip's labour rate.
     * @param machines all vineyard machines, forwarded to [TripFuelEstimator].
     * @param fuelPurchases all vineyard fuel purchases, forwarded to
     *   [TripFuelEstimator] for the weighted cost-per-litre.
     * @param paddocks all vineyard paddocks, used to resolve the single-paddock
     *   treated area for cost/ha via `trip.paddockId`.
     */
    fun estimate(
        trip: Trip,
        sprayRecord: SprayRecord?,
        operatorCategories: List<OperatorCategory>,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
        paddocks: List<Paddock> = emptyList(),
        yieldRecords: List<HistoricalYieldRecord> = emptyList(),
        savedInputs: List<SavedInput> = emptyList(),
    ): Estimate {
        val hours = (trip.activeDurationSeconds ?: 0L).coerceAtLeast(0L) / 3600.0

        // ---- Labour --------------------------------------------------------
        val category = resolveTripOperatorCategory(trip, operatorCategories)
        val rate = category?.costPerHour ?: 0.0
        val labour: LabourBreakdown = when {
            category != null && rate > 0 && hours > 0 -> LabourBreakdown(
                categoryName = category.displayName,
                costPerHour = rate,
                hours = hours,
                cost = rate * hours,
                warning = null,
            )
            category != null && rate <= 0 -> LabourBreakdown(
                categoryName = category.displayName,
                costPerHour = 0.0,
                hours = hours,
                cost = 0.0,
                warning = "Operator category has no hourly rate.",
            )
            trip.operatorUserId == null && trip.operatorCategoryId == null -> LabourBreakdown(
                categoryName = null,
                costPerHour = null,
                hours = hours,
                cost = 0.0,
                warning = "No operator assigned to this trip.",
            )
            else -> LabourBreakdown(
                categoryName = null,
                costPerHour = null,
                hours = hours,
                cost = 0.0,
                warning = "Operator has no category assigned. Set one in Team & Access.",
            )
        }

        // ---- Fuel ----------------------------------------------------------
        val fuel = TripFuelEstimator.estimate(trip, machines, fuelPurchases)

        // ---- Chemical ------------------------------------------------------
        // Only applicable for a linked spray record. Uses the record's already
        // priced per-tank chemical total; surfaces a warning when chemicals are
        // present but unpriced (mirroring iOS chemical-cost messaging).
        val chemical: ChemicalBreakdown? = sprayRecord?.let { record ->
            val tanks = record.tanks.orEmpty()
            val anyPriced = tanks.any { it.hasCost }
            val anyMissing = tanks.any { tank ->
                tank.chemicals.any { it.volumePerTank > 0 && !it.hasCost }
            }
            val warning = when {
                !anyPriced && anyMissing -> "Chemical cost unavailable — costs per unit not set on chemicals."
                anyMissing -> "Some chemicals are missing a cost per unit."
                else -> null
            }
            ChemicalBreakdown(cost = record.totalChemicalCost, warning = warning)
        }

        // ---- Treated area (multi-block) -----------------------------------
        // Sum the recorded area of every linked block (iOS
        // `Trip.paddockIds` parity). Falls back to the single `paddockId`.
        // When some — but not all — blocks are missing an area the partial
        // sum is still used with a warning, matching iOS exactly. A fully
        // missing/empty set yields a null area + the "treated area missing"
        // warning.
        val tripPaddockIds = trip.effectivePaddockIds
        val areaResolution = resolveTreatedArea(tripPaddockIds, paddocks)
        val treatedAreaHa: Double? = areaResolution.areaHa
        val areaWarning: String? = areaResolution.warning

        // ---- Seed / input --------------------------------------------------
        // Only applicable when the trip carries seeding mix lines. The summed
        // treated area is used as the kg/ha fallback for amount used. Mirrors
        // iOS `TripCostService.estimateSeedingCost`.
        val seedingTreatedHa: Double? = treatedAreaHa?.takeIf { it > 0 }
        val seeding: SeedingBreakdown? = trip.seedingDetails?.mixLines
            ?.takeIf { it.isNotEmpty() }
            ?.let { lines -> estimateSeedingCost(lines, savedInputs, seedingTreatedHa) }

        // ---- Total & completeness -----------------------------------------
        val total = labour.cost + (fuel.fuelCost ?: 0.0) + (chemical?.cost ?: 0.0) +
            (seeding?.cost ?: 0.0)

        val warnings = buildList {
            labour.warning?.let { add(it) }
            fuel.warning?.let { add(it) }
            chemical?.warning?.let { add(it) }
            seeding?.warning?.let { add(it) }
        }

        // ---- Cost per hectare ---------------------------------------------
        // Uses the multi-block treated area resolved above.
        val costPerHa: Double? = treatedAreaHa
            ?.let { area -> if (area > 0 && total > 0) total / area else null }

        // ---- Yield tonnes & cost per tonne --------------------------------
        // Only `actualYieldTonnes` is used — never an estimate. Matching mirrors
        // iOS `TripCostService.resolveYieldTonnes`: prefer the record whose year
        // matches the trip year, else the most recent record <= trip year, else
        // the most recent overall. Summed across every linked block; if ANY
        // block can't be matched the whole result is reported unavailable
        // rather than a misleading partial total.
        val yieldResolution = resolveYieldTonnes(
            vineyardId = trip.vineyardId,
            tripStartEpochMs = trip.startEpochMs,
            paddockIds = tripPaddockIds,
            yieldRecords = yieldRecords,
        )
        val yieldTonnes: Double? = yieldResolution.tonnes
        val yieldWarning: String? = yieldResolution.warning
        val costPerTonne: Double? = yieldTonnes
            ?.let { y -> if (y > 0 && total > 0) total / y else null }

        val labourOk = labour.warning == null
        val fuelOk = fuel.warning == null
        val chemicalOk = chemical?.warning == null
        val seedingOk = seeding?.warning == null
        val completeness = when {
            labourOk && fuelOk && chemicalOk && seedingOk -> Completeness.Complete
            total > 0 || labourOk || fuelOk || (chemical?.cost ?: 0.0) > 0 ||
                (seeding?.cost ?: 0.0) > 0 -> Completeness.Partial
            else -> Completeness.Unavailable
        }

        return Estimate(
            activeHours = hours,
            labour = labour,
            fuel = fuel,
            chemical = chemical,
            seeding = seeding,
            totalCost = total,
            treatedAreaHa = treatedAreaHa,
            costPerHa = costPerHa,
            areaWarning = areaWarning,
            yieldTonnes = yieldTonnes,
            costPerTonne = costPerTonne,
            yieldWarning = yieldWarning,
            completeness = completeness,
            warnings = warnings,
        )
    }

    /**
     * Estimate seed/input cost for a seeding trip's mix [lines], mirroring iOS
     * `TripCostService.estimateSeedingCost`. Cost-per-unit resolution per line:
     *   1. the line's own `costPerUnit` snapshot,
     *   2. the linked Saved Input by id,
     *   3. a case-insensitive Saved Input name match.
     * Missing costs are surfaced via `missingCount` / `warning` and never
     * silently treated as $0.
     */
    fun estimateSeedingCost(
        lines: List<SeedingMixLine>,
        savedInputs: List<SavedInput>,
        paddockHectares: Double?,
    ): SeedingBreakdown {
        if (lines.isEmpty()) {
            return SeedingBreakdown(
                cost = 0.0,
                missingCount = 0,
                warning = "Seed/input cost unavailable \u2014 cost per kg not configured.",
            )
        }
        var total = 0.0
        var anyPriced = false
        var missing = 0
        for (line in lines) {
            val amount = resolveLineAmount(line, paddockHectares)
            if (amount <= 0) continue
            val cpu = resolveSeedingCostPerUnit(line, savedInputs)
            if (cpu != null && cpu > 0) {
                total += cpu * amount
                anyPriced = true
            } else {
                missing++
            }
        }
        val warning = when {
            !anyPriced && missing > 0 -> "Seed/input cost unavailable \u2014 cost per unit not configured."
            missing > 0 -> "Some seed/input lines are missing a cost per unit."
            !anyPriced -> "Seed/input cost unavailable \u2014 cost per kg not configured."
            else -> null
        }
        return SeedingBreakdown(cost = total, missingCount = missing, warning = warning)
    }

    /**
     * Resolve the amount used on a mix line: prefer the explicit `amountUsed`
     * snapshot; fall back to `kgPerHa \u00d7 paddockHectares` when both known.
     */
    private fun resolveLineAmount(line: SeedingMixLine, paddockHectares: Double?): Double {
        line.amountUsed?.let { if (it > 0) return it }
        val kg = line.kgPerHa ?: return 0.0
        val ha = paddockHectares ?: return 0.0
        return if (kg > 0 && ha > 0) kg * ha else 0.0
    }

    /** Snapshot on the line wins, then catalog by id, then catalog by name. */
    fun resolveSeedingCostPerUnit(line: SeedingMixLine, savedInputs: List<SavedInput>): Double? {
        line.costPerUnit?.let { if (it > 0) return it }
        line.savedInputId?.let { sid ->
            savedInputs.firstOrNull { it.id == sid }?.costPerUnit?.let { if (it > 0) return it }
        }
        val key = line.name?.trim()?.lowercase().orEmpty()
        if (key.isNotEmpty()) {
            savedInputs.firstOrNull { it.name.trim().lowercase() == key }
                ?.costPerUnit?.let { if (it > 0) return it }
        }
        return null
    }

    /** Result of resolving the summed treated area across a trip's blocks. */
    data class AreaResolution(val areaHa: Double?, val warning: String?)

    /**
     * Sum the recorded area of every linked block, mirroring iOS
     * `TripCostService`'s treated-area resolution:
     *  * all blocks have a positive area -> full sum, no warning,
     *  * some (but not all) missing -> partial sum + understated warning,
     *  * none have an area / empty set -> null + "treated area missing".
     */
    fun resolveTreatedArea(
        paddockIds: List<String>,
        paddocks: List<Paddock>,
    ): AreaResolution {
        val missing = AreaResolution(
            areaHa = null,
            warning = "Cost per ha unavailable \u2014 treated area missing.",
        )
        if (paddockIds.isEmpty()) return missing
        val byId = paddocks.associateBy { it.id }
        var sum = 0.0
        var missingCount = 0
        for (id in paddockIds) {
            val area = byId[id]?.areaHectares
            if (area != null && area > 0) sum += area else missingCount++
        }
        return when {
            sum > 0 && missingCount == 0 -> AreaResolution(areaHa = sum, warning = null)
            sum > 0 -> AreaResolution(
                areaHa = sum,
                warning = "Some blocks are missing an area \u2014 cost per ha may be understated.",
            )
            else -> missing
        }
    }

    /** Result of resolving recorded actual yield tonnes for a trip's paddocks. */
    data class YieldResolution(val tonnes: Double?, val warning: String?)

    /**
     * Resolve recorded actual yield tonnes for a trip's linked paddock,
     * mirroring iOS `TripCostService.resolveYieldTonnes`.
     *
     * Rules:
     *  * Only `actualYieldTonnes` is used — never an estimate.
     *  * Prefer the record whose `year` matches the trip year; otherwise the
     *    most recent record <= trip year; otherwise the most recent overall.
     *  * When the paddock can't be matched, report unavailable (no guessing).
     */
    fun resolveYieldTonnes(
        vineyardId: String,
        tripStartEpochMs: Long?,
        paddockIds: List<String>,
        yieldRecords: List<HistoricalYieldRecord>,
    ): YieldResolution {
        val unavailable = YieldResolution(
            tonnes = null,
            warning = "Cost per tonne unavailable \u2014 yield data missing.",
        )
        if (paddockIds.isEmpty()) return unavailable
        val records = yieldRecords.filter { it.vineyardId == vineyardId }
        if (records.isEmpty()) return unavailable
        val tripYear = tripStartEpochMs?.let {
            Calendar.getInstance(TimeZone.getDefault()).apply { timeInMillis = it }
                .get(Calendar.YEAR)
        } ?: Calendar.getInstance().get(Calendar.YEAR)

        data class Candidate(val year: Int, val tonnes: Double)
        var total = 0.0
        for (paddockId in paddockIds) {
            val candidates = records.flatMap { rec ->
                rec.blocks
                    .filter { it.paddockId == paddockId && it.actualYieldTonnes != null }
                    .map { Candidate(rec.year, it.actualYieldTonnes ?: 0.0) }
            }
            // If ANY linked block can't be matched, report unavailable rather
            // than a misleading partial total (iOS parity).
            if (candidates.isEmpty()) return unavailable
            val exact = candidates.firstOrNull { it.year == tripYear }
            val prior = candidates.filter { it.year <= tripYear }.maxByOrNull { it.year }
            val mostRecent = candidates.maxByOrNull { it.year }
            val picked = exact ?: prior ?: mostRecent
            total += picked?.tonnes ?: 0.0
        }
        return if (total > 0) YieldResolution(tonnes = total, warning = null) else unavailable
    }
}
