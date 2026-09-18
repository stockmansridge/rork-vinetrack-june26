package com.rork.vinetrack.data.chemical

/** Canonicalises structured label rates without guessing across contradictory bases. */
object ChemicalLabelRateNormalizer {
    private val textPattern = Regex(
        "^\\s*([0-9]+(?:[.,][0-9]+)?)(?:\\s*[-–—]\\s*([0-9]+(?:[.,][0-9]+)?))?\\s*(mL|L|kg|g)\\s*/\\s*(100\\s*L|ha)\\s*$",
        RegexOption.IGNORE_CASE,
    )
    private val unitPattern = Regex("^\\s*(mL|L|kg|g)(?:\\s*/\\s*(100\\s*L|ha))?\\s*$", RegexOption.IGNORE_CASE)

    fun canonicalBareUnit(raw: String?): String? = when (raw?.trim()?.lowercase()) {
        "l" -> "L"
        "ml" -> "mL"
        "kg" -> "kg"
        "g" -> "g"
        else -> null
    }

    fun parse(text: String): ChemicalLabelRate? {
        val match = textPattern.matchEntire(text) ?: return null
        val low = match.groupValues[1].replace(',', '.').toDoubleOrNull() ?: return null
        val high = match.groupValues[2].takeIf { it.isNotEmpty() }?.replace(',', '.')?.toDoubleOrNull()
        if (!low.isFinite() || low <= 0.0 || high?.let { !it.isFinite() || it < low } == true) return null
        val unit = canonicalBareUnit(match.groupValues[3]) ?: return null
        val isPer100 = match.groupValues[4].replace(" ", "").equals("100L", true)
        val basis = when {
            high != null && isPer100 -> ChemicalLabelRateBasis.RANGE_PER_100_LITRES
            high != null -> ChemicalLabelRateBasis.RANGE_PER_HECTARE
            isPer100 -> ChemicalLabelRateBasis.PER_100_LITRES
            else -> ChemicalLabelRateBasis.PER_HECTARE
        }
        return ChemicalLabelRate(
            basis = basis,
            value = if (high == null) low else null,
            minValue = if (high != null) low else null,
            maxValue = high,
            unit = unit,
            rawText = text.trim(),
        )
    }

    fun normalize(rate: ChemicalLabelRate): ChemicalLabelRate? {
        if (rate.basis == ChemicalLabelRateBasis.OTHER) {
            val parsed = rate.rawText?.let(::parse) ?: return rate
            return parsed.copy(label = rate.label, rateId = rate.rateId, conditionAmbiguous = rate.conditionAmbiguous)
        }
        val unitMatch = unitPattern.matchEntire(rate.unit) ?: return null
        val unit = canonicalBareUnit(unitMatch.groupValues[1]) ?: return null
        val denominator = unitMatch.groupValues[2].replace(" ", "")
        if (denominator.isNotEmpty()) {
            val unitIsPer100 = denominator.equals("100L", true)
            if (unitIsPer100 != rate.basis.isVolumeBased) return null
        }
        val parsedText = rate.rawText?.let(::parse)
        if (parsedText != null) {
            if (parsedText.basis.isVolumeBased != rate.basis.isVolumeBased || parsedText.unit != unit) return null
            if (parsedText.minValue != null) {
                val agrees = (rate.minValue == null && rate.maxValue == null && rate.value == parsedText.minValue) ||
                    (rate.value == null && rate.minValue == parsedText.minValue && rate.maxValue == parsedText.maxValue)
                if (!agrees) return null
                return rate.copy(basis = parsedText.basis, value = null, minValue = parsedText.minValue, maxValue = parsedText.maxValue, unit = unit)
            }
            if (rate.basis == ChemicalLabelRateBasis.RANGE_PER_HECTARE ||
                rate.basis == ChemicalLabelRateBasis.RANGE_PER_100_LITRES || rate.value != parsedText.value
            ) return null
        }
        return when (rate.basis) {
            ChemicalLabelRateBasis.PER_HECTARE, ChemicalLabelRateBasis.PER_100_LITRES ->
                rate.takeIf { it.value?.let { value -> value.isFinite() && value > 0.0 } == true && it.minValue == null && it.maxValue == null }?.copy(unit = unit)
            ChemicalLabelRateBasis.RANGE_PER_HECTARE, ChemicalLabelRateBasis.RANGE_PER_100_LITRES ->
                rate.takeIf { it.value == null && it.minValue?.let { value -> value.isFinite() && value > 0.0 } == true && it.maxValue?.let { value -> value.isFinite() && value >= rate.minValue!! } == true }?.copy(unit = unit)
            ChemicalLabelRateBasis.OTHER -> rate
        }
    }

    fun normalize(intelligence: ChemicalIntelligence): ChemicalIntelligence? {
        val uses = intelligence.registeredUses.map { use ->
            val rates = use.rates.map { normalize(it) ?: return null }
            use.copy(rates = rates)
        }
        return intelligence.copy(registeredUses = uses)
    }
}
