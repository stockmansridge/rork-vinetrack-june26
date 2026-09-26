package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical
import java.net.URI

/** Customer-visible field coverage, independent of evidence verification and resistance safety. */
data class ChemicalDetailsCompleteness(val missing: List<String>, val hasConflict: Boolean) {
    val title: String get() = if (hasConflict) "Review required" else if (missing.isEmpty()) "Complete details" else "Basic details"
    val missingText: String? get() = missing.takeIf { it.isNotEmpty() }?.joinToString(", ", prefix = "Missing: ")

    companion object {
        fun assess(
            name: String, category: String, form: String, intelligence: ChemicalIntelligence,
            labelUrl: String, hasDefaultRate: Boolean, hasLabelRate: Boolean,
        ): ChemicalDetailsCompleteness {
            val missing = mutableListOf<String>()
            if (name.isBlank()) missing += "product name"
            val kind = category.trim().lowercase()
            if (kind.isEmpty()) missing += "product category"
            if (ChemicalStoreMatching.formDescription(form).isEmpty()) missing += "product form"
            val tokens = kind.split(Regex("[^a-z0-9]+")).filter { it.isNotEmpty() }
            val categoryWords = (tokens + tokens.joinToString("")).toSet()
            val protectionCategories = setOf("fungicide", "herbicide", "insecticide", "miticide", "acaricide", "nematicide")
            val isRegulator = "pgr" in categoryWords || "growthregulator" in categoryWords ||
                ("growth" in categoryWords && "regulator" in categoryWords)
            val canonicalCategory = protectionCategories.firstOrNull { it in categoryWords }
                ?: if (isRegulator) "growthregulator" else kind
            val protection = canonicalCategory in protectionCategories || isRegulator
            if (protection) {
                val actives = intelligence.activeIngredients.filter { it.name.isNotBlank() }
                if (actives.isEmpty()) missing += "active ingredients"
                if (actives.isNotEmpty() && actives.any { !it.hasConcentration }) missing += "active concentration"
                val scheme = ChemicalActivityGroupScheme.impliedByProductCategory(canonicalCategory)
                if (scheme != null && scheme != ChemicalActivityGroupScheme.NOT_APPLICABLE &&
                    (actives.isEmpty() || actives.any { it.activityGroup?.scheme != scheme || it.activityGroup?.isResistanceRelevant != true })) {
                    missing += "${scheme.label} group"
                }
                if (!hasLabelRate) missing += "label rate"
            }
            if (!hasDefaultRate) missing += "operational default rate"
            val links = listOfNotNull(labelUrl, intelligence.registration?.manufacturerLabelUrl,
                intelligence.registration?.regulatorLabelUrl, intelligence.registration?.labelReference)
            if (links.none { url -> runCatching { URI(url).let { it.scheme in listOf("http", "https") && it.host != null } }.getOrDefault(false) }) {
                missing += "product label link"
            }
            return ChemicalDetailsCompleteness(missing,
                ChemicalConflictReconciliation.customerVisible(intelligence.verification.conflicts).isNotEmpty())
        }

        fun assess(chemical: SavedChemical): ChemicalDetailsCompleteness {
            val intel = chemical.resolvedIntelligence
            val details = assess(chemical.name, chemical.productCategory, chemical.productForm, intel,
                chemical.labelUrl, ChemicalDefaultRateBasis.entries.any {
                    ChemicalDefaultRateValidity.validSlot(chemical.defaultRates, it) != null
                },
                intel.registeredUses.filter { it.isViticultural }.flatMap { it.rates }.any(ChemicalSaveContract::isUsable))
            return details.copy(hasConflict = details.hasConflict ||
                ChemicalConflictReconciliation.customerVisible(chemical.verificationConflicts.orEmpty()).isNotEmpty())
        }
    }
}
