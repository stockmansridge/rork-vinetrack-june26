package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.chemicalUnitToBase
import com.rork.vinetrack.data.SprayCalculator

/**
 * The rate, unit and basis a new spray line may safely start from.
 *
 * The three travel TOGETHER and are never separated. A rate without its own
 * unit is the bug this type exists to make impossible: the Spray Calculator
 * used to carry an amount and then read [SavedChemical.unit] beside it, so a
 * 560 g/ha default on a product stocked in kilograms displayed and calculated
 * as 560 Kg/ha.
 */
data class ChemicalSprayPrefill(
    /** The confirmed amount, in [unit]. Never converted. */
    val rate: Double,
    /** The LABEL rate's own unit — `L`, `mL`, `kg` or `g`. Never the pack unit. */
    val unit: String,
    val basis: SprayCalculator.RateBasis,
)

/**
 * Decides whether a saved chemical can safely prefill a spray line.
 *
 * The Android equivalent of the Portal's `confirmedSprayPrefill()`, and pure so
 * the decision can be asserted on directly rather than inferred from a screen.
 *
 * # What may be read
 *
 * `default_rates` and nothing else. Deliberately NOT `rates.first()`, NOT
 * `rate_per_ha`, and NOT the first registered use's rate. Each of those was a
 * previous fallback in the calculator, and each could put a number in the tank
 * that no operator had confirmed — the first row of `rates` is an ordering
 * accident, and `rate_per_ha` is a legacy column with no link back to a
 * registered direction.
 *
 * # Silence is a valid, deliberate answer
 *
 * Returning null means "the operator must choose", and every ambiguous case
 * resolves that way rather than to a guess. An unresolved line costs one tap; a
 * wrongly-prefilled line is a mixing error that reaches the vineyard.
 */
object ChemicalSprayDefaultHandoff {

    /**
     * Canonical spelling of a rate unit, or null when it is not one a line may
     * carry.
     *
     * Delegates to [ChemicalDefaultRateValidity] so the store display and the
     * spray line agree on what a usable unit is. Two readers with two unit
     * lists is how a rate becomes displayable but not sprayable.
     */
    fun canonicalUnit(raw: String?): String? = ChemicalDefaultRateValidity.canonicalUnit(raw)

    /** The calculator basis a stored slot belongs to. */
    private fun basisOf(basis: ChemicalDefaultRateBasis): SprayCalculator.RateBasis = when (basis) {
        ChemicalDefaultRateBasis.PER_HECTARE -> SprayCalculator.RateBasis.PER_HECTARE
        ChemicalDefaultRateBasis.PER_100_LITRES -> SprayCalculator.RateBasis.PER_100L
    }

    /**
     * One slot as a usable prefill, or null when it cannot safely become one.
     *
     * The whole persisted shape is validated, not merely the number: a row
     * whose basis, identity, unit, provenance or amount shape is malformed is
     * not a confirmed rate expressed oddly, it is a row whose meaning cannot
     * be established. Only the scalar shape prefills — a band is what the
     * label permits rather than what this vineyard pours.
     */
    fun prefillFor(
        defaults: StoredChemicalDefaultRates?,
        basis: ChemicalDefaultRateBasis,
    ): ChemicalSprayPrefill? {
        val valid = ChemicalDefaultRateValidity.confirmedScalar(defaults, basis) ?: return null
        val amount = valid.scalar ?: return null
        return ChemicalSprayPrefill(rate = amount, unit = valid.unit, basis = basisOf(basis))
    }

    /**
     * Every confirmed rate this product may offer a spray line, per-hectare
     * first.
     *
     * The ONE source the visible Rate picker builds its options from. It used
     * to build them from [SavedChemical.rates], which quietly reinstated every
     * fallback this type exists to remove: `rates` is the legacy array, its
     * amounts are stored in the PACK unit, and a product stocked in kilograms
     * therefore offered a confirmed 560 g/ha default as "560 Kg/ha". A picker
     * that can offer an unconfirmed number makes the prefill rule decorative,
     * because the operator can simply select past it.
     *
     * ```text
     * one confirmed slot  -> one choice (also the prefill)
     * two confirmed slots -> two choices, and NO automatic selection
     * none                -> empty, and the line stays unresolved
     * ```
     */
    fun choicesFor(chemical: SavedChemical): List<ChemicalSprayPrefill> =
        ChemicalDefaultRateValidity.confirmedScalars(chemical.defaultRates)
            .mapNotNull { valid ->
                val amount = valid.scalar ?: return@mapNotNull null
                ChemicalSprayPrefill(
                    rate = amount,
                    unit = valid.unit,
                    basis = basisOf(valid.basis),
                )
            }

    /**
     * The prefill for a saved chemical, or null when the operator must choose.
     *
     * ```text
     * exactly one confirmed scalar slot -> prefill it
     * two confirmed slots               -> null (which basis is an operating
     *                                      decision, not a default)
     * range shape with no scalar        -> null
     * missing/malformed contract        -> null
     * unsupported unit                  -> null
     * ```
     *
     * Two confirmed bases produce NO automatic answer deliberately. Per-hectare
     * and per-100 L are different ways of dosing the same spray, and picking
     * one for the operator would silently decide how the mix is built.
     */
    fun prefillFor(chemical: SavedChemical): ChemicalSprayPrefill? =
        choicesFor(chemical).singleOrNull()

    /**
     * Whether this product must keep the pre-structured `rates`/`rate_per_ha`
     * behaviour.
     *
     * True ONLY for a genuinely legacy record: no confirmed default AND no
     * structured registered uses. A structured product must never fall back to
     * those columns, however empty its `default_rates` happens to be — an
     * unconfirmed structured product is unresolved, not legacy.
     */
    fun isLegacyRateRecord(chemical: SavedChemical): Boolean =
        chemical.defaultRates == null && chemical.registeredUses.isNullOrEmpty()

    /** `"liquid"` / `"solid"` for a unit token, or null when unrecognised. */
    private fun unitFamily(unit: String): String? = when (unit.trim().lowercase()) {
        "l", "litre", "litres", "liter", "liters", "ml", "millilitre", "millilitres" -> "liquid"
        "kg", "kilogram", "kilograms", "g", "gram", "grams" -> "solid"
        else -> null
    }

    /**
     * The product's cost per APPLICATION-RATE unit, or null when unknowable.
     *
     * [SavedChemical.costPerUnit] is priced in the INVENTORY unit. When a line
     * doses in a different unit of the same family the price is converted
     * exactly - $20/kg becomes $0.02/g - using the app's own factors.
     *
     * Returns null rather than inventing a conversion when the families differ
     * or either unit is unrecognised. A missing line cost is visibly missing; a
     * fabricated one silently misprices the job, and multiplying a gram amount
     * by a per-kilogram price overstates cost a thousandfold.
     */
    fun costPerRateUnit(chemical: SavedChemical, rateUnit: String): Double? {
        val cost = chemical.costPerUnit ?: return null
        val inventoryUnit = chemical.unit
        if (inventoryUnit.trim().equals(rateUnit.trim(), ignoreCase = true)) return cost
        val from = unitFamily(inventoryUnit) ?: return null
        val to = unitFamily(rateUnit) ?: return null
        if (from != to) return null
        val basePerInventoryUnit = chemicalUnitToBase(inventoryUnit, 1.0)
        if (basePerInventoryUnit <= 0) return null
        return cost / basePerInventoryUnit * chemicalUnitToBase(rateUnit, 1.0)
    }
}
