package com.rork.vinetrack.data.chemical

import java.time.Instant

/**
 * The Chemical Store's production path for confirming a MANUALLY typed rate
 * as this vineyard's default (sql/222 contract).
 *
 * A rate the operator typed lives in `registered_uses` as label evidence the
 * operator authored. Until it is CONFIRMED it is not a default: Spray Program
 * reads `default_rates` alone, so a typed `2–3 L/100 L` left only in
 * `registered_uses` shows "Rate confirmation required" forever. This object is
 * the one place that turns such a typed rate into a `manual` default — through
 * [StoredChemicalDefaultRate.manual], the only factory, so no call site can
 * mint an `option_key`.
 *
 * What it will never do:
 *
 * * Treat a rate that carries a server `rate_id` as manual. That is label
 *   evidence and keeps the canonical confirmation path.
 * * Collapse a band. A typed range is confirmed as the range; the dose inside
 *   it is chosen when the spray is planned.
 * * Convert between units or bases.
 */
object ChemicalManualRateConfirmation {

    /** One typed rate the operator may confirm as a vineyard default. */
    data class Candidate(
        val basis: ChemicalDefaultRateBasis,
        /** Canonical unit spelling, e.g. `"L"`. */
        val unit: String,
        val value: Double? = null,
        val minValue: Double? = null,
        val maxValue: Double? = null,
    ) {
        val isRange: Boolean get() = minValue != null && maxValue != null

        /** `"2–3 L/100 L"` or `"2 L/ha"`. */
        val display: String
            get() {
                val amount = if (isRange) {
                    "${formatChemicalNumber(minValue!!)}–${formatChemicalNumber(maxValue!!)}"
                } else {
                    formatChemicalNumber(value ?: 0.0)
                }
                return "$amount $unit${ChemicalDefaultRateDisplay.basisSuffix(basis)}"
            }

        /** The persisted slot this candidate confirms to. */
        fun toManualSlot(selectedAt: String): StoredChemicalDefaultRate =
            StoredChemicalDefaultRate.manual(
                basis = basis,
                unit = unit,
                value = if (isRange) null else value,
                minValue = minValue,
                maxValue = maxValue,
                selectedAt = selectedAt,
            )
    }

    /**
     * Every typed, usable grapevine or product-level rate on the record, in
     * label order, de-duplicated by shape.
     *
     * A rate with a server-minted `rate_id` is excluded: it is label evidence
     * and must not be re-labelled as something the operator typed.
     */
    fun candidates(intelligence: ChemicalIntelligence?): List<Candidate> {
        val uses = intelligence?.registeredUses.orEmpty()
        val eligible = uses.filter { ChemicalManualEntry.isProductRateCarrier(it) || it.isViticultural }
        val out = LinkedHashSet<Candidate>()
        for (use in eligible) {
            for (rate in use.rates) {
                if (!rate.rateId.isNullOrBlank()) continue
                if (!ChemicalSaveContract.isUsable(rate)) continue
                val basis = when (rate.basis) {
                    ChemicalLabelRateBasis.PER_HECTARE,
                    ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                    -> ChemicalDefaultRateBasis.PER_HECTARE
                    ChemicalLabelRateBasis.PER_100_LITRES,
                    ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
                    -> ChemicalDefaultRateBasis.PER_100_LITRES
                    else -> continue
                }
                val unit = ChemicalDefaultRateValidity.canonicalUnit(rate.unit) ?: continue
                val min = rate.minValue
                val max = rate.maxValue
                if (min != null && max != null) {
                    out.add(Candidate(basis, unit, minValue = min, maxValue = max))
                } else {
                    val value = rate.value ?: continue
                    out.add(Candidate(basis, unit, value = value))
                }
            }
        }
        return out.toList()
    }

    /** Whether [defaults] already records exactly this candidate as a manual default. */
    fun isConfirmed(defaults: StoredChemicalDefaultRates?, candidate: Candidate): Boolean {
        val valid = ChemicalDefaultRateValidity.validSlot(defaults, candidate.basis) ?: return false
        if (!valid.isManualEntry || !valid.isConfirmedByOperator) return false
        if (valid.unit != candidate.unit) return false
        return when (val amount = valid.amount) {
            is ChemicalDefaultRateValidity.Amount.Scalar ->
                !candidate.isRange && candidate.value != null && near(amount.value, candidate.value)
            is ChemicalDefaultRateValidity.Amount.Range ->
                candidate.isRange && near(amount.min, candidate.minValue!!) && near(amount.max, candidate.maxValue!!)
        }
    }

    /**
     * Record [candidate] as the confirmed default on its basis, leaving the
     * other basis exactly as it was. An existing `selected_at` for the same
     * shape is carried forward so re-confirming rewrites what was there.
     */
    fun confirm(
        defaults: StoredChemicalDefaultRates?,
        candidate: Candidate,
        now: Instant = Instant.now(),
    ): StoredChemicalDefaultRates {
        val current = defaults ?: StoredChemicalDefaultRates()
        val selectedAt = if (isConfirmed(current, candidate)) {
            current.slot(candidate.basis)?.selectedAt ?: now.toString()
        } else {
            now.toString()
        }
        return current.withSlot(candidate.basis, candidate.toManualSlot(selectedAt))
    }

    /** Remove the confirmed default on [basis], leaving the other basis alone. */
    fun clear(
        defaults: StoredChemicalDefaultRates?,
        basis: ChemicalDefaultRateBasis,
    ): StoredChemicalDefaultRates = (defaults ?: StoredChemicalDefaultRates()).withSlot(basis, null)

    /**
     * Every confirmed slot rendered for the store — scalar OR range — in the
     * order an operator reads, tagged by entry method.
     *
     * ```text
     * "2 L/ha"                      canonical scalar
     * "2–3 L/100 L (user-confirmed)" manual range
     * ```
     */
    fun confirmedDisplays(defaults: StoredChemicalDefaultRates?): List<String> =
        ChemicalDefaultRateValidity.confirmedSlots(defaults).map { valid ->
            val amount = when (val a = valid.amount) {
                is ChemicalDefaultRateValidity.Amount.Scalar -> formatChemicalNumber(a.value)
                is ChemicalDefaultRateValidity.Amount.Range ->
                    "${formatChemicalNumber(a.min)}–${formatChemicalNumber(a.max)}"
            }
            val text = "$amount ${valid.unit}${ChemicalDefaultRateDisplay.basisSuffix(valid.basis)}"
            if (valid.isManualEntry) "$text (user-confirmed)" else text
        }

    private fun near(a: Double, b: Double): Boolean = kotlin.math.abs(a - b) < 0.000_001
}
