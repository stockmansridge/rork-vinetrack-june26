package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Exact vineyard operational preference; carries no registered label provenance. */
@Serializable
data class VineyardPreferredRate(
    val amount: Double,
    val unit: String,
    val basis: String,
    val note: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("updated_by") val updatedBy: String? = null,
) {
    val isValid: Boolean get() = amount.isFinite() && amount > 0 && unit in listOf("L", "mL", "kg", "g") && basis in listOf("per_hectare", "per_100_litres")
    val text: String get() = "${java.math.BigDecimal.valueOf(amount).stripTrailingZeros().toPlainString()} $unit${if (basis == "per_100_litres") "/100 L" else "/ha"}"
    val productUnit: String get() = when (unit) { "L" -> "Litres"; "kg" -> "Kg"; else -> unit }
}

/** The same explicit priority as iOS. Null preserves the existing registered-choice workflow. */
object OperationalRateResolver {
    enum class Source { PROGRAM_STEP, VINEYARD_PREFERRED, CONFIRMED_DEFAULT }
    data class Selection(val rate: VineyardPreferredRate, val source: Source) {
        fun sourceText(vineyard: String): String = when (source) {
            Source.PROGRAM_STEP -> "Program Step rate"
            Source.VINEYARD_PREFERRED -> "$vineyard preferred rate"
            Source.CONFIRMED_DEFAULT -> "Confirmed/default rate"
        }
    }
    fun rateFromProgram(product: com.rork.vinetrack.data.model.SprayChemical): VineyardPreferredRate? {
        val per100 = product.rateBasis == "per_100_litres" || product.ratePer100L > 0
        val base = if (per100) product.ratePer100L else product.ratePerHa
        val unit = ChemicalDefaultRateValidity.canonicalUnit(product.unit) ?: return null
        val displayUnit = VineyardPreferredRate(1.0, unit, "per_hectare").productUnit
        return VineyardPreferredRate(com.rork.vinetrack.data.model.chemicalUnitFromBase(displayUnit, base), unit, if (per100) "per_100_litres" else "per_hectare").takeIf { it.isValid }
    }
    fun warning(rate: VineyardPreferredRate, revision: CatalogueRow): String? {
        if (!rate.isValid) return null
        fun base(unit: String, amount: Double): Double = if (unit == "L" || unit == "kg") amount * 1000 else amount
        fun volume(unit: String): Boolean = unit == "L" || unit == "mL"
        val bounds = revision.rateRows(rate.basis).mapNotNull { row ->
            val unit = ChemicalDefaultRateValidity.canonicalUnit(row.text("unit")?.substringBefore('/')) ?: return@mapNotNull null
            if (unit !in listOf("L", "mL", "kg", "g") || volume(unit) != volume(rate.unit)) return@mapNotNull null
            val low = row.number("value") ?: row.number("min_value") ?: return@mapNotNull null
            val high = row.number("value") ?: row.number("max_value") ?: return@mapNotNull null
            if (!low.isFinite() || !high.isFinite() || low <= 0 || high < low) return@mapNotNull null
            base(unit, low)..base(unit, high)
        }
        if (bounds.isEmpty() || bounds.any { base(rate.unit, rate.amount) in it }) return null
        return "Outside the recorded registered grapevine rates on this basis. Check the applicable label directions. This operational rate has not been changed."
    }

    fun warning(rate: VineyardPreferredRate, chemical: SavedChemical): String? {
        if (!rate.isValid) return null
        fun base(unit: String, value: Double): Double = if (unit == "L" || unit == "kg") value * 1000 else value
        fun volume(unit: String): Boolean = unit == "L" || unit == "mL"
        val per100 = rate.basis == "per_100_litres"
        val options = SprayRegisteredUseRates.vineyardRates(chemical).filter {
            it.origin == SprayRateOrigin.REGISTERED_USE && it.basis == (if (per100) com.rork.vinetrack.data.SprayCalculator.RateBasis.PER_100L else com.rork.vinetrack.data.SprayCalculator.RateBasis.PER_HECTARE) &&
                it.unit in listOf("L", "mL", "kg", "g") && volume(it.unit) == volume(rate.unit)
        }
        val bounds = options.mapNotNull {
            when (val amount = it.amount) {
                is SprayRateAmount.Fixed -> base(it.unit, amount.value)..base(it.unit, amount.value)
                is SprayRateAmount.Range -> base(it.unit, amount.minimum)..base(it.unit, amount.maximum)
                else -> null
            }
        }
        if (bounds.isEmpty() || bounds.any { base(rate.unit, rate.amount) in it }) return null
        return "Outside the recorded registered grapevine rates on this basis. Check the applicable label directions. This operational rate has not been changed."
    }

    fun resolve(chemical: SavedChemical, program: VineyardPreferredRate? = null): Selection? {
        program?.takeIf { it.isValid }?.let { return Selection(it, Source.PROGRAM_STEP) }
        chemical.vineyardPreferredRate?.takeIf { it.isValid }?.let { return Selection(it, Source.VINEYARD_PREFERRED) }
        ChemicalSprayDefaultHandoff.resolutionFor(chemical.defaultRates)?.prefillOrNull?.let {
            val rate = VineyardPreferredRate(it.rate, it.unit, if (it.basis == com.rork.vinetrack.data.SprayCalculator.RateBasis.PER_100L) "per_100_litres" else "per_hectare")
            if (rate.isValid) return Selection(rate, Source.CONFIRMED_DEFAULT)
        }
        return null
    }
}
