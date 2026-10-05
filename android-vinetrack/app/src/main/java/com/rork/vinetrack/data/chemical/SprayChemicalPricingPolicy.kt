package com.rork.vinetrack.data.chemical

/** Compatibility only: never author a price for a new or deliberately changed spray line. */
object SprayChemicalPricingPolicy {
    fun roundTripLegacyCost(historicalCost: Double, isNewApplication: Boolean, productUnchanged: Boolean, quantitiesUnchanged: Boolean): Double =
        if (!isNewApplication && productUnchanged && quantitiesUnchanged) historicalCost else 0.0
}
