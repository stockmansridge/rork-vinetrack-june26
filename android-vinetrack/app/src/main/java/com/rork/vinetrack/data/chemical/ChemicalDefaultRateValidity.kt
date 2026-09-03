package com.rork.vinetrack.data.chemical

/**
 * Whether a PERSISTED `default_rates` slot may be believed.
 *
 * # Why a validator exists at all
 *
 * `default_rates` is written by three clients and read by four screens. Until
 * this object existed each reader made its own decision about what counted as
 * usable, and the loosest one won: Android accepted any positive `value`, so a
 * row that the Portal and the edge function both rejected as malformed still
 * prefilled a spray line here. A rate that one client refuses to display must
 * never be a rate another client puts in the tank, so the shape test lives in
 * ONE place and both the store display and the spray handoff ask it.
 *
 * Mirrors `isUsableStoredDefault` in
 * `supabase/functions/chemical-info-lookup/default_rates.ts`, rule for rule.
 *
 * # Nothing here repairs anything
 *
 * Every rule below answers yes or no. None of them mends a value, infers a
 * missing bound, re-mints an identity or substitutes a replacement rate. A
 * malformed default means the operator has not got a usable confirmed rate,
 * which is a true and recoverable state — they confirm one again. Quietly
 * "fixing" the row would manufacture a decision nobody made, and it would do
 * so at the exact point where the number is about to be poured.
 */
object ChemicalDefaultRateValidity {

    /** Every option key the identity minter produces carries this prefix. */
    const val OPTION_KEY_PREFIX: String = "${ChemicalDefaultRateIdentity.OPTION_ID_VERSION}_"

    /**
     * Gate D1 rate identities. A UUID here means the row cites a row-id rather
     * than a printed direction, which is precisely the untraceable provenance
     * the structured contract replaced.
     */
    const val RATE_ID_PREFIX: String = "rate_v1_"

    /**
     * The units a stored default may be expressed in.
     *
     * Closed on purpose, and the single source for both readers: a unit
     * nothing recognises cannot be displayed, costed or compared safely.
     */
    private val supportedUnits: Map<String, String> = mapOf(
        "l" to "L",
        "litre" to "L",
        "litres" to "L",
        "liter" to "L",
        "liters" to "L",
        "ml" to "mL",
        "millilitre" to "mL",
        "millilitres" to "mL",
        "kg" to "kg",
        "kilogram" to "kg",
        "kilograms" to "kg",
        "g" to "g",
        "gram" to "g",
        "grams" to "g",
    )

    /**
     * Canonical spelling of a rate unit, or null when it is not one a stored
     * default may carry.
     *
     * Normalises SPELLING AND CASE ONLY. It never converts: `g` stays `g` and
     * is never restated as `0.001 kg`, because the confirmed amount and its
     * unit are the operator's decision exactly as they made it.
     */
    fun canonicalUnit(raw: String?): String? =
        supportedUnits[raw?.trim()?.lowercase().orEmpty()]

    /** The two amount shapes a slot may hold — never both (shared shape D3). */
    sealed interface Amount {
        /** A confirmed dose. The only shape that may prefill a spray line. */
        data class Scalar(val value: Double) : Amount

        /** What the label permits. NOT a decision, and never a prefill. */
        data class Range(val min: Double, val max: Double) : Amount
    }

    private fun isUsableNumber(value: Double?): Boolean =
        value != null && value.isFinite() && value > 0.0

    /**
     * The amount a slot records, or null when its shape is not one of the two
     * the contract allows.
     *
     * A scalar carrying bounds is rejected rather than read as its scalar: the
     * row asserts both "exactly 620" and "anywhere in 560-700", and a reader
     * that picks one is guessing which half of a contradiction was meant.
     */
    fun amountOf(slot: StoredChemicalDefaultRate): Amount? {
        val hasScalar = slot.value != null
        val hasMin = slot.minValue != null
        val hasMax = slot.maxValue != null
        return when {
            hasScalar && !hasMin && !hasMax ->
                if (isUsableNumber(slot.value)) Amount.Scalar(slot.value!!) else null
            !hasScalar && hasMin && hasMax -> {
                val min = slot.minValue!!
                val max = slot.maxValue!!
                // An inverted band is not a narrow band, it is a corrupt one.
                if (isUsableNumber(min) && isUsableNumber(max) && min <= max) {
                    Amount.Range(min, max)
                } else {
                    null
                }
            }
            // Everything else: a lone bound, an empty row, or both shapes at once.
            else -> null
        }
    }

    /** A stored slot that passed every rule, with its amount already resolved. */
    data class ValidSlot(
        val basis: ChemicalDefaultRateBasis,
        /** Canonical spelling of the LABEL rate's unit — never the pack unit. */
        val unit: String,
        val amount: Amount,
        val slot: StoredChemicalDefaultRate,
    ) {
        /** The confirmed dose, or null when this slot records an unnarrowed band. */
        val scalar: Double? get() = (amount as? Amount.Scalar)?.value

        /** The confirmed band, or null when this slot records a single dose. */
        val range: Amount.Range? get() = amount as? Amount.Range

        /**
         * True when the operator typed this amount rather than reading it off a
         * registered direction. Drives wording — "User-confirmed" rather than
         * "Verified official rate" — and never weakens validation.
         */
        val isManualEntry: Boolean get() = slot.isManualEntry

        /** True when a human settled on this amount, whatever its origin. */
        val isConfirmedByOperator: Boolean get() = slot.isConfirmedByOperator
    }

    /**
     * The slot stored on [basis], or null when there is none the contract can
     * believe.
     *
     * Checked in full, because each rule catches a different way a row stops
     * meaning what it says:
     *
     * ```text
     * root version          a document written to a contract this build cannot read
     * containing basis      a per-100 L rate filed under per-hectare, applied per hectare
     * option key identity   a key no minter produced, so no client can match it
     * rate ids present      a default citing nothing can never be shown to be current
     * rate id identity      a UUID cites a row, not a printed direction
     * supported unit        an amount nothing can display or cost
     * source vocabulary     provenance outside the closed set is unattributable
     * amount shape (D3)     scalar XOR range, both finite and positive
     * ```
     */
    fun validSlot(
        defaults: StoredChemicalDefaultRates?,
        basis: ChemicalDefaultRateBasis,
    ): ValidSlot? {
        if (defaults == null) return null
        if (defaults.version != StoredChemicalDefaultRates.DEFAULT_RATES_VERSION) return null
        val slot = defaults.slot(basis) ?: return null

        val optionKey = slot.optionKey.trim()
        val rateIds = slot.rateIds.map { it.trim() }

        if (slot.isManualEntry) {
            // A manual rate has no official identity, and that is the point.
            // Demanding one here is exactly what made a user-confirmed
            // 2–3 L/100 L read as "Rate confirmation required" forever.
            //
            // The absence is CHECKED rather than merely tolerated: a row
            // claiming to be manual while carrying a citation is not a manual
            // rate expressed oddly, it is a row whose provenance contradicts
            // itself, and believing either half would lend label authority to
            // something a human typed.
            if (optionKey.isNotEmpty()) return null
            if (rateIds.any { it.isNotEmpty() }) return null
        } else {
            if (!optionKey.startsWith(OPTION_KEY_PREFIX)) return null
            if (optionKey.length <= OPTION_KEY_PREFIX.length) return null

            // Trimmed rather than filtered: a blank entry in the citation list
            // is a malformed row, not a row with one fewer citation.
            if (rateIds.isEmpty()) return null
            if (rateIds.any { it.length <= RATE_ID_PREFIX.length || !it.startsWith(RATE_ID_PREFIX) }) {
                return null
            }
        }

        if (slot.basis.trim() != basis.raw) return null

        val unit = canonicalUnit(slot.unit) ?: return null

        val source = slot.source.trim()
        val knownSource = source == StoredChemicalDefaultRate.SOURCE_OPERATOR ||
            source == StoredChemicalDefaultRate.SOURCE_RECOMMENDED
        if (!knownSource) return null

        val amount = amountOf(slot) ?: return null
        return ValidSlot(basis = basis, unit = unit, amount = amount, slot = slot)
    }

    /**
     * The CONFIRMED dose stored on [basis], or null when there is none.
     *
     * The scalar shape is the only confirmed amount: a slot still holding a
     * band is a decision that was never finished, and its bounds are what the
     * label permits rather than what this vineyard pours.
     */
    fun confirmedScalar(
        defaults: StoredChemicalDefaultRates?,
        basis: ChemicalDefaultRateBasis,
    ): ValidSlot? = validSlot(defaults, basis)?.takeIf { it.scalar != null }

    /** Every basis carrying a confirmed dose, per-hectare first. */
    fun confirmedScalars(defaults: StoredChemicalDefaultRates?): List<ValidSlot> =
        listOfNotNull(
            confirmedScalar(defaults, ChemicalDefaultRateBasis.PER_HECTARE),
            confirmedScalar(defaults, ChemicalDefaultRateBasis.PER_100_LITRES),
        )

    /** Every basis carrying a believable slot, per-hectare first. */
    fun validSlots(defaults: StoredChemicalDefaultRates?): List<ValidSlot> =
        listOfNotNull(
            validSlot(defaults, ChemicalDefaultRateBasis.PER_HECTARE),
            validSlot(defaults, ChemicalDefaultRateBasis.PER_100_LITRES),
        )

    /**
     * Every basis carrying an operator-confirmed amount — scalar OR range.
     *
     * A confirmed range IS a real decision: the operator has said "this
     * product, this band, on this basis". What it does not settle is the dose
     * for one particular tank, and that is asked for when the spray is built
     * rather than guessed here.
     */
    fun confirmedSlots(defaults: StoredChemicalDefaultRates?): List<ValidSlot> =
        validSlots(defaults).filter { it.isConfirmedByOperator }

    /**
     * Whether [value] lies inside a confirmed band, inclusive of both ends.
     *
     * Inclusive because a label authorises its own bounds: 2 and 3 are both
     * legal doses of a `2–3 L/100 L` direction.
     */
    fun isWithinRange(value: Double, min: Double, max: Double): Boolean =
        value.isFinite() && min.isFinite() && max.isFinite() && value >= min && value <= max
}
