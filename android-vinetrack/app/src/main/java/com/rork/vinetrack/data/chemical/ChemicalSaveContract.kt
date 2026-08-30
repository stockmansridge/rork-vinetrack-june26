package com.rork.vinetrack.data.chemical

/**
 * The shared save-contract rules the wizard consults on device.
 *
 * Mirrors the iOS `ChemicalSaveContract` (which in turn mirrors the edge
 * function's `save_contract.ts`). Only the rate-usability gate is needed on
 * Android today; the full evaluation continues to run server-side and inside
 * the iOS editor.
 */
object ChemicalSaveContract {

    /** The bases a calculation can actually run on. */
    val calculableBases: Set<ChemicalLabelRateBasis> = setOf(
        ChemicalLabelRateBasis.PER_100_LITRES,
        ChemicalLabelRateBasis.PER_HECTARE,
        ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
        ChemicalLabelRateBasis.RANGE_PER_HECTARE,
    )

    /**
     * Whether a registered rate is one a calculation may use.
     *
     * Verbatim wording is deliberately excluded. "Apply as directed by an
     * agronomist" is worth storing and cannot produce a dose; treating
     * `rawText` as a rate is what let unusable chemicals into the store.
     */
    fun isUsable(rate: ChemicalLabelRate): Boolean {
        if (rate.basis !in calculableBases) return false
        if (rate.unit.trim().isEmpty()) return false
        return when (rate.basis) {
            ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            -> {
                val low = rate.minValue ?: return false
                val high = rate.maxValue ?: return false
                low.isFinite() && high.isFinite() && low > 0 && high > 0 && high >= low
            }

            ChemicalLabelRateBasis.PER_100_LITRES,
            ChemicalLabelRateBasis.PER_HECTARE,
            -> {
                val value = rate.value ?: return false
                value.isFinite() && value > 0
            }

            ChemicalLabelRateBasis.OTHER -> false
        }
    }
}
