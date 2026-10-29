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
    val registeredRate: ChemicalLabelRate? = null,
    val registeredUse: ChemicalRegisteredUse? = null,
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

    /** Display-only detail projection; never merges registered uses or mutates their evidence. */
    val selectionDetails: List<String>
        get() = buildList {
            add(groupTitle)
            add(label)
            condition?.let { add(it) }
            preset?.let { add(it.qualifier) }
            registeredUse?.restrictions?.let { add(it) }
            registeredUse?.reEntryStatement?.let { add(it) }
            registeredUse?.withholdingStatement?.let { add(it) }
            registeredUse?.withholdingPeriodDays?.let { add("Withholding period: $it days") }
            registeredUse?.reEntryPeriodHours?.let { add("Re-entry interval: $it hours") }
            (registeredUse?.unknownFields?.get("method") as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { add(it) }
        }.map { it.trim() }.filter { it.isNotEmpty() && it != displayText }.distinct()

    val menuText: String
        get() {
            val caption = listOfNotNull(label.trim().takeIf { it.isNotEmpty() }, condition?.trim()?.takeIf { it.isNotEmpty() }).distinct().joinToString(" — ")
            return preset?.let {
            val choice = "$displayText (${it.qualifier})"
            if (caption.isBlank()) choice else "$caption: $choice"
        }
            ?: caption.takeIf { it.isNotEmpty() }?.let { "$it: $displayText" }
            ?: displayText
        }
}

/** Pure Kotlin port of iOS `SprayRegisteredUseRates`. */
object SprayRegisteredUseRates {
    private const val TOLERANCE: Double = 0.000_001

    /** Structured rates are authoritative if any registered-use row carries a rate. */
    fun hasStructuredRates(chemical: SavedChemical): Boolean =
        hasCatalogueEvidence(chemical) || chemical.registeredUses.orEmpty().any { it.rates.isNotEmpty() }

    /** Vineyard rates only, plus legitimate product-level rates; legacy only when structured rates are absent. */
    fun hasCatalogueEvidence(chemical: SavedChemical): Boolean =
        chemical.rates is CatalogueRateEvidence || chemical.chemicalV3RevisionId != null

    fun vineyardRates(chemical: SavedChemical): List<SpraySelectableRate> {
        if (hasCatalogueEvidence(chemical)) {
            if (chemical.chemicalV3ReviewStatusSnapshot != "approved" || chemical.chemicalV3RevisionId == null) return emptyList()
            val entries = (chemical.rates as? CatalogueRateEvidence)?.selectableRates().orEmpty()
                .filter { compatibleUnit(it.unit, chemical.unit) }
            return entries.flatMap { entry ->
                val range = entry.amount as? SprayRateAmount.Range
                if (range == null || entries.count { it.basis == entry.basis } != 1) listOf(entry)
                else listOf(entry) + presetPoints(range.minimum, range.maximum).map { (preset, value) ->
                    entry.copy(id = stableId("${entry.id}|${preset.raw}"), amount = SprayRateAmount.Fixed(value),
                        displayText = "$value ${entry.unit}${basisSuffix(entry.basis)}", preset = preset)
                }
            }
        }
        return if (hasStructuredRates(chemical)) structuredVineyardRates(chemical) else legacyRates(chemical)
    }

    fun selectableVineyardRates(chemical: SavedChemical): List<SpraySelectableRate> =
        vineyardRates(chemical).filter { it.isSelectable }

    /** Unsupported active concentration units remain reference evidence, separate from application rates. */
    fun concentrationUnitReviewMessage(chemical: SavedChemical): String? {
        val units = chemical.activeIngredients.orEmpty().mapNotNull { it.unresolvedConcentrationUnit }.distinct().sorted()
        if (units.isEmpty()) return null
        return "Stored active concentration units ${units.joinToString(", ")} require independent review. No concentration basis inferred."
    }

    /** Dimensional disagreements remain intact and require independent review, not conversion. */
    fun productUnitReviewMessage(chemical: SavedChemical): String? {
        val units = chemical.registeredUses.orEmpty()
            .filter { ChemicalManualEntry.isProductRateCarrier(it) || it.isViticultural }
            .flatMap { it.rates }.mapNotNull(ChemicalLabelRateNormalizer::normalize)
            .filter { it.basis != ChemicalLabelRateBasis.OTHER }.map { it.unit }.distinct().sorted()
        if (units.none { !compatibleUnit(it, chemical.unit) }) return null
        return "Product unit ${chemical.unit} conflicts with registered rate units ${units.joinToString(", ")}. Independent review required; no conversion applied."
    }

    private fun compatibleUnit(rateUnit: String, productUnit: String): Boolean {
        val product = ChemicalDefaultRateValidity.canonicalUnit(productUnit) ?: return false
        val rate = ChemicalDefaultRateValidity.canonicalUnit(rateUnit) ?: return false
        return (rate in setOf("L", "mL")) == (product in setOf("L", "mL"))
    }

    fun hasInvalidStructuredRates(chemical: SavedChemical): Boolean =
        productUnitReviewMessage(chemical) != null || chemical.registeredUses.orEmpty()
            .filter { ChemicalManualEntry.isProductRateCarrier(it) || it.isViticultural }
            .flatMap { it.rates }
            .any { ChemicalLabelRateNormalizer.normalize(it) == null }

    fun availableBases(chemical: SavedChemical): List<SprayCalculator.RateBasis> =
        selectableVineyardRates(chemical).mapNotNull { it.basis }.distinct()

    fun rate(chemical: SavedChemical, id: String?): SpraySelectableRate? =
        id?.let { wanted -> vineyardRates(chemical).firstOrNull { it.id == wanted } }

    /** Finds the offered row represented by a confirmed Chemical Store default without converting it. */
    fun confirmedSelection(chemical: SavedChemical): SpraySelectableRate? {
        if (hasCatalogueEvidence(chemical)) return null
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

    /** Basis selection cannot choose between distinct registered application conditions. */
    fun firstOffered(chemical: SavedChemical, basis: SprayCalculator.RateBasis): SpraySelectableRate? {
        val offered = selectableVineyardRates(chemical).filter { it.basis == basis && it.preset == null }
        return if (hasStructuredRates(chemical)) offered.singleOrNull() else offered.firstOrNull()
    }

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
                    selectable(labelRate, use)?.let { entry ->
                        if (compatibleUnit(entry.unit, chemical.unit)) entry
                        else entry.copy(amount = SprayRateAmount.Unresolved, labelRange = null, labelRangeText = null)
                    }?.takeIf { seen.add(it.id) }
                }
                addAll(entries)
                for (only in entries.filter { it.isSelectable }) {
                    if (entries.count { it.isSelectable && it.basis == only.basis } != 1) continue
                    if (use.rates.any { it.conditionAmbiguous == true && selectable(it, use)?.id == only.id }) continue
                    val range = only.amount as? SprayRateAmount.Range ?: continue
                    for ((preset, value) in presetPoints(range.minimum, range.maximum)) {
                        val id = stableId(
                            "preset|${only.id}|${use.crop}|${use.targetRaw}|${only.basis}|${only.unit}|" +
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
        val normalized = ChemicalLabelRateNormalizer.normalize(rate) ?: return SpraySelectableRate(
            id = rate.rateId ?: stableId("invalid|${use.id}|${rate.id}"),
            origin = SprayRateOrigin.REGISTERED_USE,
            registeredUseId = use.directionId ?: use.id,
            crop = use.crop,
            targetRaw = use.targetRaw,
            label = rate.label,
            condition = null,
            basis = null,
            amount = SprayRateAmount.Unresolved,
            unit = "",
            displayText = "Invalid stored rate",
        )
        val basis = when {
            normalized.basis.isVolumeBased -> SprayCalculator.RateBasis.PER_100L
            normalized.basis.isAreaBased -> SprayCalculator.RateBasis.PER_HECTARE
            else -> null
        }
        val amount: SprayRateAmount = when {
            basis == null -> SprayRateAmount.ReferenceOnly
            normalized.minValue != null && normalized.maxValue != null ->
                SprayRateAmount.Range(normalized.minValue, normalized.maxValue)
            normalized.minValue != null || normalized.maxValue != null -> SprayRateAmount.Unresolved
            normalized.value != null -> SprayRateAmount.Fixed(normalized.value)
            else -> SprayRateAmount.Unresolved
        }
        val id = rate.rateId?.trim()?.takeIf { it.isNotEmpty() } ?: stableId(listOf("use", use.directionId.orEmpty(),
            rate.applicationCondition.orEmpty(), use.restrictions.orEmpty(),
            use.withholdingStatement.orEmpty(), use.reEntryStatement.orEmpty(),
            use.withholdingPeriodDays?.toString().orEmpty(), use.reEntryPeriodHours?.toString().orEmpty(),
            use.crop, use.targetRaw, rate.label, rate.basis.raw, rate.unit,
            rate.value?.toString().orEmpty(), rate.minValue?.toString().orEmpty(), rate.maxValue?.toString().orEmpty()
        ).joinToString("|"))
        val range = (amount as? SprayRateAmount.Range)?.let { it.minimum..it.maximum }
        return SpraySelectableRate(
            id = id,
            origin = SprayRateOrigin.REGISTERED_USE,
            registeredUseId = use.directionId ?: use.id,
            crop = use.crop,
            targetRaw = use.targetRaw,
            label = rate.label,
            condition = rate.applicationCondition,
            registeredRate = rate,
            registeredUse = use,
            basis = basis,
            amount = amount,
            unit = normalized.unit,
            displayText = normalized.displayRate,
            labelRange = range,
            labelRangeText = range?.let { normalized.displayRate },
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
