package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.resolveTripMachineName
import com.rork.vinetrack.data.model.weightedFuelCostPerLitre

/**
 * Pure, read-only fuel estimator for a single trip (Stage 3F-3a), mirroring the
 * fuel portion of the iOS `TripCostService.estimate(...)`. Produces estimated
 * litres + fuel cost from engine-hour delta (preferred) or active trip duration
 * (fallback), the linked machine/tractor fuel rate, and a weighted average cost
 * per litre derived from the vineyard's `fuel_purchases`.
 *
 * No persistence and no UI — callers must gate display to owner/manager.
 */
object TripFuelEstimator {

    /** How the fuel hours were derived. */
    enum class FuelBasis(val label: String) {
        EngineHours("Engine hours"),
        Duration("Trip duration"),
    }

    /**
     * Fuel estimate result. When [litres] / [fuelCost] are null the relevant
     * [warning] explains why (no machine link, missing fuel rate, or no fuel
     * purchases). [costPerLitre] is null when no fuel purchases exist.
     */
    data class Estimate(
        val machineName: String?,
        val fuelUsageLPerHour: Double?,
        val costPerLitre: Double?,
        val litres: Double?,
        val fuelCost: Double?,
        val basis: FuelBasis,
        val fuelHours: Double,
        val warning: String?,
    )

    /**
     * Estimate fuel litres + cost for [trip].
     *
     * @param trip the trip being costed.
     * @param machines all vineyard machines, used to resolve the linked
     *   machine/legacy-tractor fuel rate.
     * @param fuelPurchases all fuel purchases for the vineyard (already
     *   vineyard-scoped by the caller is fine; this filters defensively).
     */
    fun estimate(
        trip: Trip,
        machines: List<VineyardMachine>,
        fuelPurchases: List<FuelPurchase>,
    ): Estimate {
        // Fuel hours: prefer engine-hour delta when valid, else active duration.
        val engineHourDelta: Double? = trip.engineHoursUsed?.takeIf { it > 0 }
        val basis = if (engineHourDelta != null) FuelBasis.EngineHours else FuelBasis.Duration
        val durationHours = (trip.activeDurationSeconds ?: 0L).coerceAtLeast(0L) / 3600.0
        val fuelHours = engineHourDelta ?: durationHours

        // Resolve the effective fuel source. Prefer the linked vineyard machine
        // when it has an approved (> 0) L/hr rate, else the legacy tractor link.
        val machine = trip.machineId?.let { mid -> machines.firstOrNull { it.id == mid } }
        val tractor = trip.tractorId?.let { tid ->
            machines.firstOrNull { it.legacyTractorId == tid && it.vineyardId == trip.vineyardId }
        }
        val machineRate = machine?.fuelUsageLPerHour ?: 0.0
        val tractorRate = tractor?.fuelUsageLPerHour ?: 0.0
        val effectiveRate = if (machineRate > 0) machineRate else tractorRate
        val hasMachineLink = trip.machineId != null
        val hasAnyLink = trip.machineId != null || trip.tractorId != null
        val machineName = resolveTripMachineName(trip, machines)

        val vineyardPurchases = fuelPurchases.filter { it.vineyardId == trip.vineyardId }
        val costPerLitre = weightedFuelCostPerLitre(vineyardPurchases)

        return when {
            effectiveRate > 0 && fuelHours > 0 && costPerLitre != null -> {
                val litres = effectiveRate * fuelHours
                Estimate(
                    machineName = machineName,
                    fuelUsageLPerHour = effectiveRate,
                    costPerLitre = costPerLitre,
                    litres = litres,
                    fuelCost = litres * costPerLitre,
                    basis = basis,
                    fuelHours = fuelHours,
                    warning = null,
                )
            }
            !hasAnyLink -> Estimate(
                machineName = null,
                fuelUsageLPerHour = null,
                costPerLitre = costPerLitre,
                litres = null,
                fuelCost = null,
                basis = basis,
                fuelHours = fuelHours,
                warning = "No machine linked to this trip.",
            )
            effectiveRate <= 0 -> Estimate(
                machineName = machineName,
                fuelUsageLPerHour = 0.0,
                costPerLitre = costPerLitre,
                litres = null,
                fuelCost = null,
                basis = basis,
                fuelHours = fuelHours,
                warning = if (hasMachineLink) {
                    "Fuel rate missing — set the machine's fuel usage (L/hr) in Equipment."
                } else {
                    "Fuel rate missing — set the tractor's fuel usage (L/hr) in Equipment."
                },
            )
            costPerLitre == null -> Estimate(
                machineName = machineName,
                fuelUsageLPerHour = effectiveRate,
                costPerLitre = null,
                litres = effectiveRate * fuelHours,
                fuelCost = null,
                basis = basis,
                fuelHours = fuelHours,
                warning = "No fuel purchases recorded — add one to enable fuel cost.",
            )
            else -> Estimate(
                machineName = machineName,
                fuelUsageLPerHour = effectiveRate,
                costPerLitre = costPerLitre,
                litres = null,
                fuelCost = null,
                basis = basis,
                fuelHours = fuelHours,
                warning = "Fuel cost unavailable.",
            )
        }
    }
}
