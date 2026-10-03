package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_HECTARE
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L

/** Store classification only; mirrors iOS. Never repairs data or changes calculation eligibility. */
data class ChemicalStoreAssessment(
    val details: ChemicalDetailsCompleteness,
    val attentionReasons: List<String>,
    val isActive: Boolean,
) {
    sealed interface RevisionResolution {
        data object Loading : RevisionResolution
        data object Unavailable : RevisionResolution
        data class Resolved(val row: CatalogueRow) : RevisionResolution
        val revision: CatalogueRow? get() = (this as? Resolved)?.row
    }

    val title: String get() = if (attentionReasons.isEmpty()) details.title else "Review required"
    val needsAttention: Boolean get() = isActive && attentionReasons.isNotEmpty()

    companion object {
        fun assess(chemical: SavedChemical, resolution: RevisionResolution = RevisionResolution.Loading): ChemicalStoreAssessment {
            val compatibilityDetails = ChemicalDetailsCompleteness.assess(chemical)
            val reasons = mutableListOf<String>()
            val explicitConflict = chemical.verificationStatusRaw == "conflict" && chemical.verificationConflicts.orEmpty().isEmpty()
            if (compatibilityDetails.hasConflict || explicitConflict) reasons += "Review conflicting chemical information."
            val active = chemical.isActive && chemical.deletedAt == null
            chemical.chemicalV3RevisionId?.let { revisionId ->
                val missing = mutableListOf<String>()
                when (resolution) {
                    RevisionResolution.Loading -> missing += "catalogue information is loading"
                    RevisionResolution.Unavailable -> reasons += "Catalogue information unavailable. Retry loading the linked revision."
                    is RevisionResolution.Resolved -> {
                        val revision = resolution.row
                        if (!revision.id.equals(revisionId, ignoreCase = true)) {
                            reasons += "Catalogue information unavailable. Retry loading the linked revision."
                        } else {
                            if (revision.text("product_name").isNullOrBlank()) reasons += "The linked catalogue revision has no product name."
                            // Pending VineTrack review is not an operator task; superseded
                            // revisions remain exact historical facts, never replaced by latest.
                            if (revision.text("review_status") in listOf("needs_attention", "rejected")) {
                                reasons += "The linked catalogue revision requires review."
                            }
                        }
                    }
                }
                // NOT_APPLICABLE, structured groups, and absent compatibility enrichment
                // never create invented operational requirements.
                return ChemicalStoreAssessment(ChemicalDetailsCompleteness(missing, reasons.isNotEmpty()), reasons, active)
            }
            val slots = ChemicalDefaultRateBasis.entries.mapNotNull { ChemicalDefaultRateValidity.validSlot(chemical.defaultRates, it) }
            // Provenance alone cannot distinguish older manually entered legacy records.
            val manual = ChemicalStorePresentation.editorKind(chemical) == ChemicalStorePresentation.EditorKind.MANUAL
            if (manual) {
                val rates = slots.map { slot ->
                    ChemicalLabelRate(
                        basis = if (slot.basis == ChemicalDefaultRateBasis.PER_HECTARE) {
                            if (slot.range == null) ChemicalLabelRateBasis.PER_HECTARE else ChemicalLabelRateBasis.RANGE_PER_HECTARE
                        } else {
                            if (slot.range == null) ChemicalLabelRateBasis.PER_100_LITRES else ChemicalLabelRateBasis.RANGE_PER_100_LITRES
                        },
                        value = slot.scalar, minValue = slot.range?.min, maxValue = slot.range?.max, unit = slot.unit,
                    )
                }
                reasons += ChemicalSaveContract.evaluateMinimumOperational(chemical.name, chemical.unit, rates).violations.map { it.message }
                val storedCount = listOfNotNull(chemical.defaultRates?.perHectare, chemical.defaultRates?.per100Litres).size
                if (storedCount > slots.size) reasons += "Review the unusable operational rate."
            } else {
                // Existing legacy rates remain usable without new default/enrichment demands.
                val hasLegacyRate = chemical.rates.any {
                    it.value.isFinite() && it.value > 0 && it.basis in listOf(CHEMICAL_RATE_PER_HECTARE, CHEMICAL_RATE_PER_100L)
                } || chemical.ratePerHa?.let { it.isFinite() && it > 0 } == true
                val hasLabelRate = chemical.resolvedIntelligence.registeredUses.flatMap { it.rates }.any(ChemicalSaveContract::isUsable)
                if (chemical.name.isBlank()) reasons += "Enter the chemical / product name."
                if (chemical.unit.isBlank()) reasons += "Choose the product unit."
                if (slots.isEmpty() && !(chemical.defaultRates == null && (hasLegacyRate || hasLabelRate))) {
                    reasons += "Review the missing or unusable operational rate."
                }
            }
            return ChemicalStoreAssessment(compatibilityDetails, reasons, active)
        }

        fun activeAssessments(chemicals: List<SavedChemical>, resolutions: Map<String, RevisionResolution>): Map<String, ChemicalStoreAssessment> =
            ChemicalStorePresentation.active(chemicals).associate { chemical ->
                chemical.id to assess(chemical, chemical.chemicalV3RevisionId?.let { resolutions[it] } ?: RevisionResolution.Loading)
            }
    }
}
