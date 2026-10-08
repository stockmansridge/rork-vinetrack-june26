package com.rork.vinetrack.data.model

/** Draft-only calculations; replay sends confirmed snapshots without repricing. */
object WorkTaskMachineCosting {
    data class Result(val fuelLitres: Double?, val fuelCost: Double?, val machineCharge: Double?)
    fun equipment(vineyardId: String?, source: String?, equipmentId: String?, machines: List<VineyardMachine>): VineyardMachine? {
        if (vineyardId == null || equipmentId == null || source !in listOf(null, "tractor", "vineyard_machine")) return null
        return machines.firstOrNull { it.vineyardId == vineyardId && it.deletedAt == null && (if (source == "tractor") it.legacyTractorId == equipmentId else it.id == equipmentId) }
    }
    fun fuelPrice(vineyardId: String?, purchases: List<FuelPurchase>): Double? {
        if (vineyardId == null) return null
        val scoped = purchases.filter { it.vineyardId == vineyardId && it.deletedAt == null && it.volumeLitres.isFinite() && it.volumeLitres > 0 && it.totalCost.isFinite() && it.totalCost >= 0 }
        return valid(weightedFuelCostPerLitre(scoped))?.takeIf { it > 0 }
    }
    fun valid(value: Double?): Double? = value?.takeIf { it.isFinite() && it >= 0 }
    fun product(lhs: Double?, rhs: Double?): Double? {
        val left = valid(lhs) ?: return null
        val right = valid(rhs) ?: return null
        return valid(left * right)
    }
    fun resolve(duration: Double?, engineHours: Double?, fuelRate: Double?, fuelPrice: Double?, hourlyRate: Double?, fuelOverride: Double?, fuelCostOverride: Double?, machineOverride: Double?): Result {
        val rate = valid(fuelRate)?.takeIf { it > 0 }
        val price = valid(fuelPrice)?.takeIf { it > 0 }
        val fuel = fuelOverride ?: product(engineHours ?: duration, rate)
        return Result(fuel, fuelCostOverride ?: product(fuel, price), machineOverride ?: product(duration, hourlyRate))
    }
}
