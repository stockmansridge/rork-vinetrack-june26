package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.spray.SprayProductRateBasis

/**
 * Wires the Chemical Rate Contract ([ChemicalSprayDefaultHandoff]) into the
 * Spray Program's product lines — production seeding, the confirmed-range gate
 * and spray-record provenance — kept out of the Compose file so the exact code
 * the screen runs can be exercised by tests. Mirrors iOS
 * `SprayConfirmedRateSeeding`.
 */
object SprayConfirmedRateSeeding {

    /** What a new line starts with, from the product's CONFIRMED rate. */
    data class Seed(
        val basis: SprayCalculator.RateBasis,
        /** Null for a confirmed band: the dose is the operator's to enter. */
        val rateAmount: Double?,
        val rateUnit: String,
        val range: ChemicalSprayRangeSelection?,
    )

    /**
     * ```text
     * one confirmed scalar  -> that basis, that amount, that unit
     * one confirmed range   -> that basis, that unit, NO amount
     * two confirmed bases   -> null (basis is an operating decision)
     * nothing confirmed     -> null
     * ```
     */
    fun seedFor(chemical: SavedChemical): Seed? =
        when (val resolution = ChemicalSprayDefaultHandoff.resolutionFor(chemical.defaultRates)) {
            is ChemicalSprayRateResolution.Prefilled -> Seed(
                basis = resolution.prefill.basis,
                rateAmount = resolution.prefill.rate,
                rateUnit = resolution.prefill.unit,
                range = null,
            )
            is ChemicalSprayRateResolution.RequiresSelection -> Seed(
                basis = resolution.selection.basis,
                rateAmount = null,
                rateUnit = resolution.selection.unit,
                range = resolution.selection,
            )
            null -> null
        }

    /** The confirmed band governing a line on [basis], if any. */
    fun rangeFor(chemical: SavedChemical, basis: SprayCalculator.RateBasis): ChemicalSprayRangeSelection? =
        ChemicalSprayDefaultHandoff.resolutions(chemical.defaultRates)
            .firstOrNull { it.basis == basis }
            ?.selectionOrNull

    /** The confirmed scalar governing a line on [basis], if any. */
    fun prefillFor(chemical: SavedChemical, basis: SprayCalculator.RateBasis): ChemicalSprayPrefill? =
        ChemicalSprayDefaultHandoff.resolutions(chemical.defaultRates)
            .firstOrNull { it.basis == basis }
            ?.prefillOrNull

    /**
     * The rate a line calculates from once a confirmed band governs it.
     *
     * The typed dose when the band authorises it, otherwise NULL — the line
     * has no rate, the planner reports it unresolved and the guided flow
     * blocks the spray from being saved off the confirmed range. Nothing here
     * selects an endpoint or the midpoint.
     */
    fun gatedRate(range: ChemicalSprayRangeSelection, overrideText: String): Double? =
        ChemicalSprayDefaultHandoff
            .validateApplicationRate(parse(overrideText), range)
            .acceptedValue

    /**
     * The rate handed to the planner for a gated line: the accepted dose, or
     * NaN — which the planner treats as "no usable rate" (unresolved), unlike
     * zero, which it would calculate as a resolved empty tank.
     */
    fun plannerRate(range: ChemicalSprayRangeSelection, overrideText: String): Double =
        gatedRate(range, overrideText) ?: Double.NaN

    /** Why a typed dose was refused against the confirmed band, or null. */
    fun rejection(range: ChemicalSprayRangeSelection, overrideText: String): String? {
        if (overrideText.isBlank()) return null
        val band = "${formatChemicalNumber(range.min)}–${formatChemicalNumber(range.max)} " +
            "${range.unit}${suffix(range.basis)}"
        return when (ChemicalSprayDefaultHandoff.validateApplicationRate(parse(overrideText), range)) {
            is ChemicalApplicationRateOutcome.Accepted -> null
            is ChemicalApplicationRateOutcome.BelowMinimum,
            is ChemicalApplicationRateOutcome.AboveMaximum,
            -> "The confirmed rate range is $band. Enter a rate within it."
            ChemicalApplicationRateOutcome.NotANumber -> "Enter the rate you are applying, within $band."
        }
    }

    /** `"2–3 L/100L (user-confirmed)"`. */
    fun rangeDisplay(range: ChemicalSprayRangeSelection): String {
        val band = "${formatChemicalNumber(range.min)}–${formatChemicalNumber(range.max)} " +
            "${range.unit}${suffix(range.basis)}"
        return if (range.isUserEntered) "$band (user-confirmed)" else "$band (from label)"
    }

    // ---- Spray-record provenance ----

    /**
     * Freeze the applied dose and its provenance onto [base] for a saved line.
     *
     * [appliedRate] is the number the Review step displayed, in [unit] — the
     * line's own rate unit. The entry method is the confirmed slot's on the
     * line's basis; a dose typed for this spray with no confirmed slot behind
     * it is `manual`. A confirmed band travels with the dose chosen inside it,
     * and the Chemical Store's band is never touched.
     */
    fun snapshotWithProvenance(
        base: ChemicalLineSnapshot?,
        chemical: SavedChemical,
        basis: SprayProductRateBasis,
        appliedRate: Double,
        unit: String,
        isOverride: Boolean,
        capturedAt: String,
    ): ChemicalLineSnapshot? {
        if (!appliedRate.isFinite() || appliedRate <= 0.0) return base
        val contractBasis = if (basis == SprayProductRateBasis.PER_100_LITRES) {
            ChemicalDefaultRateBasis.PER_100_LITRES
        } else {
            ChemicalDefaultRateBasis.PER_HECTARE
        }
        val slot = ChemicalDefaultRateValidity.confirmedSlots(chemical.defaultRates)
            .firstOrNull { it.basis == contractBasis }
        val range = slot?.range
        val entryMethod = when {
            slot == null -> if (isOverride) StoredChemicalDefaultRate.ENTRY_MANUAL else StoredChemicalDefaultRate.ENTRY_CANONICAL
            range == null && isOverride -> StoredChemicalDefaultRate.ENTRY_MANUAL
            slot.isManualEntry -> StoredChemicalDefaultRate.ENTRY_MANUAL
            else -> StoredChemicalDefaultRate.ENTRY_CANONICAL
        }
        val start = base ?: ChemicalLineSnapshot(
            savedChemicalId = chemical.id,
            productName = chemical.displayName,
            capturedAt = capturedAt,
        )
        return start.recordingApplied(
            rate = appliedRate,
            unit = unit,
            basis = contractBasis,
            entryMethod = entryMethod,
            confirmedRange = range,
        )
    }

    private fun parse(text: String): Double? = text.trim().replace(',', '.').toDoubleOrNull()

    private fun suffix(basis: SprayCalculator.RateBasis): String =
        if (basis == SprayCalculator.RateBasis.PER_100L) "/100L" else "/ha"
}
