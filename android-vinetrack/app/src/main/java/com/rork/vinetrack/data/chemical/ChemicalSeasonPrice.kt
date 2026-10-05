package com.rork.vinetrack.data.chemical

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Shared financial RPC provenance; no editor pricing or name-based identity lookup. */
@Serializable
data class ChemicalSeasonPrice(
    @SerialName("saved_chemical_id") val savedChemicalId: String,
    val vintage: Int,
    @SerialName("weighted_cost_per_base_unit") val weightedCostPerBaseUnit: Double? = null,
    @SerialName("base_unit") val baseUnit: String? = null,
    val currency: String? = null,
    @SerialName("purchase_count") val purchaseCount: Int = 0,
    @SerialName("total_quantity_base") val totalQuantityBase: Double? = null,
    @SerialName("total_purchase_cost") val totalPurchaseCost: Double? = null,
    @SerialName("pricing_basis") val pricingBasis: String,
    val warning: String? = null,
) {
    fun priceFor(unit: String): Double? {
        val expected = when (unit.trim().lowercase()) {
            "l", "ml", "litres", "liters", "millilitres", "milliliters" -> "mL"
            "kg", "g", "kilograms", "grams" -> "g"
            else -> return null
        }
        return weightedCostPerBaseUnit?.takeIf {
            pricingBasis == "season_weighted_purchase_average" && baseUnit == expected && it.isFinite() && it >= 0
        }
    }
}

data class ChemicalSeasonPriceBatch(val vineyardId: String, val vintage: Int, val prices: List<ChemicalSeasonPrice>)
