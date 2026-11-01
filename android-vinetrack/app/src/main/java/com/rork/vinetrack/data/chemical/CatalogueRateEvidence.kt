package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.model.ChemicalRate
import kotlinx.serialization.json.*

/** Object-shaped catalogue evidence shares the legacy list boundary, but is never a legacy rate.
 * Keeping the original JSON also preserves unrecognized fields through offline cache round trips.
 */
class CatalogueRateEvidence(val original: JsonObject) : AbstractList<ChemicalRate>() {
    override val size: Int get() = 0
    override fun get(index: Int): ChemicalRate = throw IndexOutOfBoundsException("Catalogue evidence is not a legacy rate array")

    fun selectableRates(): List<SpraySelectableRate> = listOf("per_hectare", "per_100_litres").flatMap { key ->
        (original[key] as? JsonArray).orEmpty().mapNotNull { element ->
            val option = element as? JsonObject ?: return@mapNotNull null
            fun text(name: String) = (option[name] as? JsonPrimitive)?.contentOrNull
            fun number(name: String) = (option[name] as? JsonPrimitive)?.doubleOrNull
            if (text("basis") !in setOf(key, "range_$key") || (option["needs_review"] as? JsonPrimitive)?.booleanOrNull == true) return@mapNotNull null
            val unit = ChemicalDefaultRateValidity.canonicalUnit(text("unit").orEmpty().substringBefore('/')) ?: return@mapNotNull null
            val scalar = number("value")
            // Production fixed-rate rows explicitly encode absent range bounds as JSON null.
            // A supplied non-null malformed bound must still refuse, never fall back to scalar.
            val fields = listOf("value", "min_value", "max_value")
            if (fields.any { option[it] != null && option[it] != JsonNull && number(it) == null }) return@mapNotNull null
            val minimum = number("min_value")
            val maximum = number("max_value")
            if (scalar != null && (minimum != null || maximum != null || text("basis") == "range_$key")) return@mapNotNull null
            val low = minimum ?: scalar ?: return@mapNotNull null
            val high = maximum ?: scalar ?: return@mapNotNull null
            if (!low.isFinite() || !high.isFinite() || low <= 0 || high < low) return@mapNotNull null
            val basis = if (key == "per_100_litres") SprayCalculator.RateBasis.PER_100L else SprayCalculator.RateBasis.PER_HECTARE
            val suffix = if (key == "per_100_litres") "/100 L" else "/ha"
            val range = if (high > low) low..high else null
            val amount = range?.let { SprayRateAmount.Range(low, high) } ?: SprayRateAmount.Fixed(low)
            val display = if (range == null) "${formatChemicalNumber(low)} $unit$suffix" else "${formatChemicalNumber(low)}–${formatChemicalNumber(high)} $unit$suffix"
            val evidence = Json { ignoreUnknownKeys = true }.decodeFromJsonElement(ChemicalLabelRate.serializer(), option)
            SpraySelectableRate(
                id = text("option_id") ?: java.util.UUID.nameUUIDFromBytes("$key|$element".toByteArray()).toString(),
                origin = SprayRateOrigin.REGISTERED_USE, registeredUseId = null, crop = null, targetRaw = null,
                label = "Product label rate", condition = text("condition"), registeredRate = evidence, basis = basis, amount = amount,
                unit = unit, displayText = display, labelRange = range, labelRangeText = if (range != null) display else null,
            )
        }
    }
}
