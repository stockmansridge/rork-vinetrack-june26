package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import java.security.MessageDigest
import java.util.UUID

/** Where an operational Spray Calculator rate came from. */
enum class SprayRateOrigin(val raw: String) {
    REGISTERED_USE("registered_use"),
    LEGACY("legacy"),
}

/** Neutral provenance for a deterministic point generated from one plain label range. */
enum class SprayRatePreset(val raw: String, val qualifier: String) {
    MINIMUM("minimum", "label minimum"),
    MIDPOINT("midpoint", "mid-range"),
    MAXIMUM("maximum", "label maximum"),
}

/** The amount shape carried by one selectable label-rate row. */
sealed interface SprayRateAmount {
    data class Fixed(val value: Double) : SprayRateAmount
    data class Range(val minimum: Double, val maximum: Double) : SprayRateAmount
    data object ReferenceOnly : SprayRateAmount
    data object Unresolved : SprayRateAmount
}

/** One rate row offered by the vineyard Spray Calculator, retaining its label context. */
data class SpraySelectableRate(
    val id: String,
    val origin: SprayRateOrigin,
    val registeredUseId: String?,
    val crop: String?,
    val targetRaw: String?,
    val label: String,
    val condition: String?,
    val basis: SprayCalculator.RateBasis?,
    val amount: SprayRateAmount,
    val unit: String,
    val displayText: String,
    val labelRange: ClosedFloatingPointRange<Double>? = null,
    val labelRangeText: String? = null,
    val preset: SprayRatePreset? = null,
) {
    val isSelectable: Boolean
        get() = basis != null && (amount is SprayRateAmount.Fixed || amount is SprayRateAmount.Range)

    val appliedValue: Double? get() = (amount as? SprayRateAmount.Fixed)?.value

    val requiresManualRate: Boolean get() = amount is SprayRateAmount.Range

    val groupTitle: String
        get() = when {
            !crop.isNullOrBlank() && !targetRaw.isNullOrBlank() -> "${crop.trim()} · ${targetRaw.trim()}"
            !crop.isNullOrBlank() -> crop.trim()
            !targetRaw.isNullOrBlank() -> targetRaw.trim()
            origin == SprayRateOrigin.REGISTERED_USE -> "Product label rate"
            else -> "Saved rates"
        }

    val menuText: String
        get() = preset?.let { "$displayText (${it.qualifier})" }
            ?: label.trim().takeIf { it.isNotEmpty() }?.let { "$it: $displayText" }
            ?: displayText
}

/** Pure Kotlin port of iOS `SprayRegisteredUseRates`. */
object SprayRegisteredUseRates {
    private const val TOLERANCE: Double = 0.000_001

    /** Structured rates are authoritative if any registered-use row carries a rate. */
    fun hasStructuredRates(chemical: SavedChemical): Boolean =
        chemical.registeredUses.orEmpty().any { it.rates.isNotEmpty() }

    /** Vineyard rates only, plus legitimate product-level rates; legacy only when structured rates are absent. */
    fun vineyardRates(chemical: SavedChemical): List<SpraySelectableRate> =
        if (hasStructuredRates(chemical)) structuredVineyardRates(chemical) else legacyRates(chemical)

    fun selectableVineyardRates(chemical: SavedChemical): List<SpraySelectableRate> =
        vineyardRates(chemical).filter { it.isSelectable }

    fun availableBases(chemical: SavedChemical): List<SprayCalculator.RateBasis> =
        selectableVineyardRates(chemical).mapNotNull { it.basis }.distinct()

    fun rate(chemical: SavedChemical, id: String?): SpraySelectableRate? =
        id?.let { wanted -> vineyardRates(chemical).firstOrNull { it.id == wanted } }

    /** Finds the offered row represented by a confirmed Chemical Store default without converting it. */
    fun confirmedSelection(chemical: SavedChemical): SpraySelectableRate? {
        val slots = ChemicalDefaultRateValidity.validSlots(chemical.defaultRates)
        if (slots.size != 1) return null
        val slot = slots.single()
        val basis = lineBasis(slot.basis)
        return selectableVineyardRates(chemical).firstOrNull { rate ->
            if (rate.basis != basis || canonicalUnit(rate.unit) != slot.unit || rate.preset != null) return@firstOrNull false
            when (val amount = rate.amount) {
                is SprayRateAmount.Fixed -> slot.scalar?.let { kotlin.math.abs(it - amount.value) < TOLERANCE } == true
                is SprayRateAmount.Range -> slot.range?.let {
                    kotlin.math.abs(it.min - amount.minimum) < TOLERANCE &&
                        kotlin.math.abs(it.max - amount.maximum) < TOLERANCE
                } == true
                else -> false
            }
        }
    }

    /** First actual offered row on a basis; ranges remain unresolved until the operator chooses a value. */
    fun firstOffered(chemical: SavedChemical, basis: SprayCalculator.RateBasis): SpraySelectableRate? =
        selectableVineyardRates(chemical).firstOrNull { it.basis == basis && it.preset == null }
            ?: selectableVineyardRates(chemical).firstOrNull { it.basis == basis }

    /** Validates a manual value against the selected label range in the label's own unit. */
    fun validateManual(text: String, rate: SpraySelectableRate?): Double? {
        val range = rate?.labelRange ?: return null
        val value = text.trim().replace(',', '.').toDoubleOrNull() ?: return null
        return value.takeIf { it.isFinite() && it > 0.0 && it in range }
    }

    private fun structuredVineyardRates(chemical: SavedChemical): List<SpraySelectableRate> {
        val uses = chemical.registeredUses.orEmpty().filter {
            ChemicalManualEntry.isProductRateCarrier(it) || it.isViticultural
        }
        val seen = linkedSetOf<String>()
        return buildList {
            for (use in uses) {
                val entries = use.rates.mapNotNull { labelRate ->
                    selectable(labelRate, use)?.takeIf { seen.add(it.id) }
                }
                addAll(entries)
                val only = entries.singleOrNull { it.isSelectable }
                val range = only?.amount as? SprayRateAmount.Range
                if (only != null && range != null) {
                    for ((preset, value) in presetPoints(range.minimum, range.maximum)) {
                        val id = stableId(
                            "preset|${use.crop}|${use.targetRaw}|${only.basis}|${only.unit}|" +
                                "${range.minimum}|${range.maximum}|${preset.raw}",
                        )
                        if (!seen.add(id)) continue
                        add(
                            only.copy(
                                id = id,
                                amount = SprayRateAmount.Fixed(value),
                                displayText = "${formatChemicalNumber(value)} ${only.unit}${basisSuffix(only.basis)}".trim(),
                                preset = preset,
                            ),
                        )
                    }
                }
            }
        }
    }

    private fun selectable(rate: ChemicalLabelRate, use: ChemicalRegisteredUse): SpraySelectableRate? {
        val basis = when {
            rate.basis.isVolumeBased -> SprayCalculator.RateBasis.PER_100L
            rate.basis.isAreaBased -> SprayCalculator.RateBasis.PER_HECTARE
            else -> null
        }
        val amount: SprayRateAmount = when {
            basis == null -> SprayRateAmount.ReferenceOnly
            rate.minValue != null && rate.maxValue != null &&
                rate.minValue.isFinite() && rate.maxValue.isFinite() &&
                rate.minValue > 0.0 && rate.maxValue >= rate.minValue ->
                SprayRateAmount.Range(rate.minValue, rate.maxValue)
            rate.minValue != null || rate.maxValue != null -> SprayRateAmount.Unresolved
            rate.value != null && rate.value.isFinite() && rate.value > 0.0 -> SprayRateAmount.Fixed(rate.value)
            else -> SprayRateAmount.Unresolved
        }
        val id = rate.rateId?.trim()?.takeIf { it.isNotEmpty() } ?: stableId(
            "use|${use.crop}|${use.targetRaw}|${rate.label}|${rate.basis.raw}|${rate.unit}|" +
                "${rate.value ?: ""}|${rate.minValue ?: ""}|${rate.maxValue ?: ""}",
        )
        val range = (amount as? SprayRateAmount.Range)?.let { it.minimum..it.maximum }
        return SpraySelectableRate(
            id = id,
            origin = SprayRateOrigin.REGISTERED_USE,
            registeredUseId = use.directionId ?: use.id,
            crop = use.crop,
            targetRaw = use.targetRaw,
            label = rate.label,
            condition = rate.label.trim().takeIf { it.isNotEmpty() },
            basis = basis,
            amount = amount,
            unit = rate.unit,
            displayText = rate.displayRate,
            labelRange = range,
            labelRangeText = range?.let { rate.displayRate },
        )
    }

    private fun legacyRates(chemical: SavedChemical): List<SpraySelectableRate> = chemical.rates.map { rate ->
        val basis = if (rate.basis == "per_100_litres") {
            SprayCalculator.RateBasis.PER_100L
        } else {
            SprayCalculator.RateBasis.PER_HECTARE
        }
        val value = chemicalUnitFromBase(chemical.unit, rate.value)
        SpraySelectableRate(
            id = rate.id,
            origin = SprayRateOrigin.LEGACY,
            registeredUseId = null,
            crop = null,
            targetRaw = null,
            label = rate.label,
            condition = null,
            basis = basis,
            amount = if (value.isFinite() && value > 0.0) SprayRateAmount.Fixed(value) else SprayRateAmount.Unresolved,
            unit = chemical.unit,
            displayText = "${formatChemicalNumber(value)} ${chemical.unit}${basisSuffix(basis)}",
        )
    }

    private fun presetPoints(minimum: Double, maximum: Double): List<Pair<SprayRatePreset, Double>> {
        if (!minimum.isFinite() || !maximum.isFinite() || minimum <= 0.0 || maximum <= minimum) return emptyList()
        return listOf(
            SprayRatePreset.MINIMUM to minimum,
            SprayRatePreset.MIDPOINT to (minimum + maximum) / 2.0,
            SprayRatePreset.MAXIMUM to maximum,
        ).distinctBy { it.second }
    }

    private fun lineBasis(basis: ChemicalDefaultRateBasis): SprayCalculator.RateBasis =
        if (basis == ChemicalDefaultRateBasis.PER_100_LITRES) SprayCalculator.RateBasis.PER_100L
        else SprayCalculator.RateBasis.PER_HECTARE

    private fun canonicalUnit(unit: String): String? = ChemicalDefaultRateValidity.canonicalUnit(unit)

    private fun basisSuffix(basis: SprayCalculator.RateBasis?): String =
        if (basis == SprayCalculator.RateBasis.PER_100L) "/100 L" else if (basis == SprayCalculator.RateBasis.PER_HECTARE) "/ha" else ""

    private fun stableId(seed: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(seed.toByteArray()).copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = java.nio.ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long).toString()
    }
}
