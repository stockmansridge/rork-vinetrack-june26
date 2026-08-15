package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.model.SavedChemical

/**
 * The decisions the Search → Match → Verify → Confirm wizard makes when it lands
 * a product in the Chemical Store.
 *
 * These live in the data layer rather than inside the Compose sheet because they
 * are the rules that protect the store from corruption — duplicate registrations
 * and accidentally-blanked fields — and rules that matter that much need to be
 * tested directly rather than inferred from a screenshot of a bottom sheet.
 *
 * Mirrors the iOS `ChemicalMatchFlowView` confirm-step behaviour.
 */
object ChemicalStoreMatching {

    /**
     * Find an existing chemical that is THE SAME REGISTERED PRODUCT as [registration].
     *
     * Identity is the country-scoped registration key (e.g. `AU:apvma:62764`) and
     * nothing else. Name similarity is deliberately not consulted: two genuinely
     * different registrations can carry near-identical marketing names, and the
     * same registration is the same product no matter how the operator typed it.
     * Fuzzy matching here would silently merge two chemicals, which in a
     * resistance context means silently merging two chemistries.
     *
     * Returns null when the candidate has no registration identity at all — an
     * unregistered entry cannot be proven to duplicate anything, so the operator
     * is left in control rather than being blocked by a guess.
     *
     * @param excludingId the record being updated in place, which must never
     *   count as a duplicate of itself.
     */
    fun findByRegistrationIdentity(
        chemicals: List<SavedChemical>,
        registration: ChemicalRegistration?,
        excludingId: String? = null,
    ): SavedChemical? {
        val key = registration?.identityKey ?: return null
        return chemicals.firstOrNull { chem ->
            chem.id != excludingId &&
                chem.resolvedIntelligence.registration?.identityKey == key
        }
    }

    /**
     * Build the write payload for a confirmed product.
     *
     * Structured [intel] is the authority. The legacy `active_ingredient` and
     * `chemical_group` scalars are written as DERIVED mirrors so older clients
     * still render something familiar, but nothing reads them back to make a
     * resistance decision.
     *
     * Every non-chemistry field on [existing] is carried through untouched. That
     * is the whole point when verifying a legacy record: matching a chemical must
     * upgrade its chemistry, not quietly discard the pack size, price and
     * inventory the grower has been maintaining for years.
     */
    fun inputFor(
        existing: SavedChemical?,
        productName: String,
        intel: ChemicalIntelligence,
    ): SavedChemicalRepository.ChemicalInput {
        val groupProjection = intel.legacyChemicalGroup
        val activeProjection = intel.legacyActiveIngredient
        return SavedChemicalRepository.ChemicalInput(
            name = productName.trim().ifBlank { existing?.name.orEmpty() },
            unit = existing?.unit ?: "Litres",
            ratePerHa = existing?.ratePerHa ?: 0.0,
            rates = existing?.rates ?: emptyList(),
            activeIngredient = activeProjection.ifBlank { existing?.activeIngredient },
            chemicalGroup = groupProjection.ifBlank { existing?.chemicalGroup },
            use = existing?.use,
            problem = existing?.problem,
            manufacturer = intel.registration?.registrant?.takeIf { it.isNotBlank() }
                ?: existing?.manufacturer,
            notes = existing?.notes,
            modeOfAction = existing?.modeOfAction,
            labelUrl = intel.registration?.labelReference?.takeIf { it.isNotBlank() }
                ?: existing?.labelUrl,
            productUrl = existing?.productUrl,
            purchase = existing?.purchase,
            productCategory = intel.productCategory.ifBlank { existing?.productCategory.orEmpty() },
            productForm = existing?.productForm.orEmpty(),
            packSize = existing?.packSize,
            packUnit = existing?.packUnit.orEmpty(),
            pricePerPack = existing?.pricePerPack,
            density = existing?.density,
            nitrogenPercent = existing?.nitrogenPercent,
            phosphorusPercent = existing?.phosphorusPercent,
            potassiumPercent = existing?.potassiumPercent,
            analysisBasis = existing?.analysisBasis ?: "elemental",
            organicCertified = existing?.organicCertified ?: false,
            inventoryQuantity = existing?.inventoryQuantity,
            inventoryUnit = existing?.inventoryUnit.orEmpty(),
            applicationNotes = existing?.applicationNotes.orEmpty(),
            intelligence = intel,
        )
    }
}
