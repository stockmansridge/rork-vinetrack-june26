package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.chemical.SprayRegisteredUseRates
import com.rork.vinetrack.data.chemical.SprayRateOrigin

/** PDF evidence only: no doses, carrier volumes or calculated operational costs. */
data class ProgramPDFProduct(
    val name: String, val per100L: String = "", val perHa: String = "",
    val moa: String = "", val estimatedCost: String = "",
) {
    val unknownRate: Boolean get() = per100L.isEmpty() && perHa.isEmpty() && name.isNotEmpty()
    companion object {
        fun make(product: SprayChemical, step: SprayRecord, chemicals: List<SavedChemical>, targetLabels: Map<String, String>): ProgramPDFProduct {
            val chemical = chemicals.filter {
                if (product.savedChemicalId != null) it.id == product.savedChemicalId
                else SprayProgramProgression.normalizedName(it.name) == SprayProgramProgression.normalizedName(product.name)
            }.singleOrNull()
            // storedIntelligence, not the free-text-parsing legacy resolved seed.
            val codes = chemical?.activityGroups?.takeIf { it.isNotEmpty() }
                ?: chemical?.storedIntelligence?.activityGroupCodes.orEmpty()
            val result = ProgramPDFProduct(product.name, moa = codes.filter { it.isNotBlank() }.joinToString(" + "))
            val basis = SprayProductRateBasis.legacy(product.rateBasis)
                ?: if (product.ratePerHa <= 0 && product.ratePer100L > 0) SprayProductRateBasis.PER_100_LITRES else SprayProductRateBasis.WHOLE_BLOCK_AREA
            val value = if (basis == SprayProductRateBasis.PER_100_LITRES) product.ratePer100L else product.ratePerHa
            if (value.isFinite() && value > 0) {
                val text = SprayProgramReferenceDataset.rate(product, step, chemicals, targetLabels)
                return if (basis == SprayProductRateBasis.PER_100_LITRES) result.copy(per100L = text) else result.copy(perHa = text)
            }
            if (chemical == null) return result
            val targets = SprayTargetVocabulary.tags(step.targets.orEmpty(), null, targetLabels)
                .map { SprayProgramProgression.normalizedName(it.label) }.toSet()
            val applicable = SprayRegisteredUseRates.vineyardRates(chemical).filter { rate ->
                rate.origin == SprayRateOrigin.REGISTERED_USE && rate.preset == null && rate.isSelectable &&
                    chemical.registeredUses.orEmpty().any { use -> use.isViticultural && (use.directionId ?: use.id) == rate.registeredUseId } &&
                    SprayProgramProgression.normalizedName(rate.targetRaw.orEmpty()) in targets
            }
            fun text(basis: SprayCalculator.RateBasis): String = applicable.filter { it.basis == basis }.map {
                "${it.targetRaw.orEmpty()}${it.label.takeIf { label -> label.isNotBlank() }?.let { label -> " — $label" }.orEmpty()}: ${it.labelRangeText ?: it.displayText} (registered)"
            }.distinct().sorted().joinToString("\n")
            return result.copy(per100L = text(SprayCalculator.RateBasis.PER_100L), perHa = text(SprayCalculator.RateBasis.PER_HECTARE))
        }
    }
}
