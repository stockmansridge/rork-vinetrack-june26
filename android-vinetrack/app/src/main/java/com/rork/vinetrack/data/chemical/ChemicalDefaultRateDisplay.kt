package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical

/**
 * What the Chemical Store shows as a product's OPERATIONAL rate.
 *
 * # Why this is not `ratePerHaDisplay`
 *
 * The list used to render [SavedChemical.ratePerHaDisplay] and
 * [SavedChemical.ratePer100LDisplay]. Both read the legacy `rates` array and
 * fall back to the legacy `rate_per_ha` column, and neither can tell an
 * operator-confirmed decision from a number that was projected, imported or
 * typed years ago. So a product whose rate nobody had confirmed still showed a
 * confident "2 L/ha", and the operator had no way to see that VineTrack was
 * quoting them a number rather than their own decision.
 *
 * `default_rates` is the authority, and the ONLY thing that may be presented as
 * this vineyard's confirmed rate. A structured product with no confirmed
 * default says so plainly instead of borrowing a legacy figure.
 *
 * # Units come from the slot, never from the product
 *
 * [SavedChemical.unit] is the INVENTORY unit — how the product is bought and
 * stocked. A product bought in kilograms is routinely dosed in grams per
 * hectare, and printing "560 Kg/ha" for a 560 g/ha default is a thousandfold
 * error in the direction that empties a shed. Each slot carries the label
 * rate's own unit and that is what is displayed.
 */
object ChemicalDefaultRateDisplay {

    /**
     * Shown for a structured product whose operational rate nobody has
     * confirmed. Deliberately an instruction rather than a blank or a dash: it
     * names an action the operator can take, and it never implies the label
     * has no rates — that question is answered by `registered_uses` alone.
     */
    const val CONFIRMATION_REQUIRED: String = "Rate confirmation required"

    /** The suffix each basis is written with: `2 L/ha`, `150 g/100 L`. */
    fun basisSuffix(basis: ChemicalDefaultRateBasis): String = when (basis) {
        ChemicalDefaultRateBasis.PER_HECTARE -> "/ha"
        ChemicalDefaultRateBasis.PER_100_LITRES -> "/100 L"
    }

    /**
     * Whether this record carries structured chemical intelligence.
     *
     * A product with registered uses, or with a recorded default, is governed
     * by the structured contract. Everything else is a legacy or manual record
     * that predates it and keeps its own behaviour — the migration rule is
     * "never strand an existing record", not "retro-fit every old one".
     */
    fun isStructured(chemical: SavedChemical): Boolean =
        !chemical.registeredUses.isNullOrEmpty() || chemical.defaultRates != null

    /**
     * One rendered slot, e.g. `"2 L/ha"`, or null when this basis records no
     * usable confirmed amount.
     *
     * A slot still holding a legacy range with no scalar returns null: an
     * unnarrowed band is a decision that was never finished, and rendering its
     * bounds here would present a permitted span as a confirmed dose.
     *
     * The whole persisted shape is validated through
     * [ChemicalDefaultRateValidity] — the same gate the spray handoff uses, so
     * a row this store shows as confirmed is exactly a row a spray line may
     * start from.
     */
    fun slotDisplay(
        defaults: StoredChemicalDefaultRates?,
        basis: ChemicalDefaultRateBasis,
    ): String? {
        val valid = ChemicalDefaultRateValidity.confirmedScalar(defaults, basis) ?: return null
        val amount = valid.scalar ?: return null
        return "${formatChemicalNumber(amount)} ${valid.unit}${basisSuffix(basis)}"
    }

    /** Every confirmed slot, per-hectare first, in the order an operator reads. */
    fun slotDisplays(defaults: StoredChemicalDefaultRates?): List<String> =
        listOfNotNull(
            slotDisplay(defaults, ChemicalDefaultRateBasis.PER_HECTARE),
            slotDisplay(defaults, ChemicalDefaultRateBasis.PER_100_LITRES),
        )

    /**
     * The operational rate line for a Chemical Store row.
     *
     * ```text
     * confirmed default(s)          -> "2 L/ha"  |  "2 L/ha · 150 g/100 L"
     * structured, nothing confirmed -> "Rate confirmation required"
     * legacy/manual record          -> null (the caller keeps its legacy line)
     * ```
     *
     * Never the first `rates` row, and never `rate_per_ha`: neither can be
     * shown to be a decision anybody made.
     */
    fun line(chemical: SavedChemical): String? {
        val confirmed = slotDisplays(chemical.defaultRates)
        if (confirmed.isNotEmpty()) return confirmed.joinToString(" · ")
        if (isStructured(chemical)) return CONFIRMATION_REQUIRED
        return null
    }

    /**
     * True when this product's operational rate still needs confirming.
     *
     * Drives the store's own prompt, and is deliberately false for a legacy
     * record: nothing about an old manual chemical is unfinished, it simply
     * predates the structured contract.
     */
    fun needsConfirmation(chemical: SavedChemical): Boolean =
        isStructured(chemical) && slotDisplays(chemical.defaultRates).isEmpty()
}
