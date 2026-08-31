package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_HECTARE
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.model.chemicalUnitToBase
import java.util.UUID

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

    // ---- Pre-research duplicate decision (item 5) ----

    /**
     * Normalised form of a product name for SAME-PRODUCT comparison.
     *
     * Case, punctuation and run-together spacing are noise a grower should
     * never be punished for: `"Kocide Blue Xtra"`, `"KOCIDE BLUE XTRA"` and
     * `"Kocide-Blue Xtra"` are one product typed three ways. Pack-size and
     * volume suffixes are deliberately NOT stripped, because `"Product 5 L"`
     * and `"Product 20 L"` may be genuinely different registrations.
     */
    fun normalisedName(raw: String): String =
        raw.lowercase().replace(Regex("[^a-z0-9]+"), " ").trim()

    /**
     * Whether two product names denote the same saved product.
     *
     * EXACT equality after normalisation — never substring, prefix or
     * edit-distance. An earlier revision let a whole-token prefix match so
     * `"Kocide Blue"` would find `"Kocide Blue Xtra"`, but those are two
     * different registrations with different labels, and offering the wrong
     * one invites an operator to skip the register check for a product they
     * do not actually own. Asking twice is cheap; adopting the wrong record
     * is a spray-diary error.
     */
    fun namesMatch(a: String, b: String): Boolean {
        val left = normalisedName(a)
        val right = normalisedName(b)
        if (left.isEmpty() || right.isEmpty()) return false
        return left == right
    }

    /**
     * Existing chemicals whose name is the same or materially matching.
     *
     * Consulted BEFORE any remote lookup runs. The old order — research first,
     * detect the duplicate on the confirm screen — spent the expensive call
     * and the operator's wait before telling them they already owned the
     * product, and left a half-finished record on screen if they backed out.
     *
     * Only ACTIVE chemicals are considered: an archived product is one the
     * operator has deliberately retired, and resurrecting it as a duplicate
     * candidate would undo that decision without being asked.
     *
     * Every match is an exact name match, so the result needs no ranking.
     */
    fun findByProductName(
        chemicals: List<SavedChemical>,
        query: String,
        excludingId: String? = null,
    ): List<SavedChemical> {
        val normalisedQuery = normalisedName(query)
        if (normalisedQuery.isEmpty()) return emptyList()
        return chemicals.filter {
            it.isActive && it.id != excludingId && namesMatch(it.displayName, query)
        }
    }

    /**
     * The decision the operator is offered before research begins.
     *
     * # The question is about UPDATING, not about identity
     *
     * An earlier revision offered three answers: review the existing record,
     * create a different product, or go back. "This is a different product"
     * has been removed deliberately. A stored product with the SAME normalised
     * name is either the one the operator means or a record they need to look
     * at first; offering "different product" as a peer option let a second copy
     * of the same chemical be created in one tap, and a duplicated chemical in
     * a resistance context means a duplicated chemistry. If two genuinely
     * distinct registrations really do share a name, that is reached by
     * checking the stored one first — not by skipping past it.
     *
     * Modelled as data rather than as sheet state so the "declining costs
     * nothing" rule is testable: [Decision.KeepAsIs] means NO research call and
     * NO write of any kind.
     */
    sealed interface Decision {
        /** Nothing matched; go straight to the register search. */
        data object Proceed : Decision

        /**
         * "Yes, check for updates" — re-verify the record already stored.
         *
         * Never a second insert. The existing row is re-checked through its
         * own registration identity, and this add flow issues no lookup of its
         * own: it hands over to re-verification and closes.
         */
        data class CheckForUpdates(val chemical: SavedChemical) : Decision

        /**
         * "No, keep it as it is" — the operator is done.
         *
         * Must cost exactly nothing: no search, no structured lookup, no
         * insert, no update, and the stored row preserved byte for byte.
         */
        data object KeepAsIs : Decision
    }

    /**
     * Whether this decision permits a remote chemical lookup FROM THE ADD FLOW.
     *
     * The acceptance rule in one place: only [Decision.Proceed] may reach the
     * network here. [Decision.CheckForUpdates] is false because this flow hands
     * over to re-verification and stops — the identity-keyed lookup that
     * follows belongs to that screen, not to this one, and is a re-check of a
     * record the operator already owns rather than research for a new one.
     */
    fun permitsResearch(decision: Decision): Boolean = when (decision) {
        Decision.Proceed -> true
        is Decision.CheckForUpdates, Decision.KeepAsIs -> false
    }

    /**
     * Whether this decision permits any write to the Chemical Store.
     *
     * Separate from [permitsResearch] on purpose: "no network" and "no write"
     * are two distinct promises, and the acceptance test checks both.
     * [Decision.CheckForUpdates] writes nothing HERE — any update is made
     * later, by the operator, behind re-verification's own explicit Save.
     */
    fun permitsWrite(decision: Decision): Boolean = when (decision) {
        Decision.Proceed -> true
        is Decision.CheckForUpdates, Decision.KeepAsIs -> false
    }

    /**
     * The exact question the operator is asked about a same-name product.
     *
     * Pinned here rather than written inline in the sheet so the wording is one
     * fact both platforms and the tests can agree on.
     */
    fun sameNameQuestion(productName: String): String =
        "“${productName.trim()}” is already in your Chemical Store. " +
            "Check whether its information is up to date?"

    /** "No, keep it as it is" — dismisses the add flow, writes nothing. */
    const val KEEP_AS_IS_ACTION: String = "No, keep it as it is"

    /** "Yes, check for updates" — re-verifies the stored record. */
    const val CHECK_FOR_UPDATES_ACTION: String = "Yes, check for updates"

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
     *
     * [master] is the sql/199 catalogue reference when the lookup was served
     * from an APPROVED master row: the saved record then retains the master id
     * and the catalogue revision its chemistry was copied at. Null (an
     * AI-sourced match) leaves any stored link untouched — the write omits the
     * columns entirely — so provenance is never cleared or invented here.
     */
    fun inputFor(
        existing: SavedChemical?,
        productName: String,
        /**
         * The researched payload as the resolver returned it, WHOLE. It is
         * narrowed to the vineyard by [ChemicalVineyardScope] inside this
         * function so no caller can forget to, and so a review screen can
         * still show the full label while the store keeps only the vines.
         */
        researched: ChemicalIntelligence,
        master: ChemicalInfoService.ChemicalMasterMatch? = null,
        /**
         * The lookup's verbatim `form_type` (e.g. "Suspension concentrate").
         * Null on paths that carry none. The authoritative contract: an
         * explicit liquid formulation reads as Liquid, an explicit solid one
         * as Solid, and anything else stays UNKNOWN — never defaulted to
         * Liquid, and never inferred from concentration units.
         */
        formTypeRaw: String? = null,
        /**
         * The operator's vineyard default-rate decision from the wizard, or
         * null on paths without the chooser. When present, the legacy
         * operational rate columns are projected from it exactly like the iOS
         * `legacyProjection()` — the authoritative label rates inside [intel]
         * are never altered by it.
         */
        defaults: ChemicalDefaultRateSelection? = null,
    ): SavedChemicalRepository.ChemicalInput {
        // Vineyard scoping happens HERE, at the write boundary, before any
        // projection reads the uses. Macadamia, cereal and citrus directions on
        // the same label are real content but they are not this vineyard's
        // operational data, and a rate a spray calculation can reach must never
        // belong to a crop the operator does not grow.
        val intel = ChemicalVineyardScope.scoped(researched)
        val groupProjection = intel.legacyChemicalGroup
        val activeProjection = intel.legacyActiveIngredient
        val form = formDescription(formTypeRaw)
        // Physical form: the lookup's explicit statement wins; silence keeps
        // whatever the record already said; nothing ever writes "liquid" for
        // an unknown form.
        val productForm = form.ifEmpty { existing?.productForm.orEmpty() }
        // Inventory/application unit: an established form (or a registered
        // rate's own unit) decides it; otherwise the existing unit survives;
        // otherwise it is left UNSET for the operator — the old
        // `?: "Litres"` default is exactly the bug this replaces.
        val unit = productUnit(form, intel.registeredUses)
            ?: existing?.unit?.takeIf { it.isNotBlank() }
            ?: ""
        val projected = defaults?.let { projectedLegacyRates(existing, unit, intel, it) }
        return SavedChemicalRepository.ChemicalInput(
            name = productName.trim().ifBlank { existing?.name.orEmpty() },
            unit = unit,
            ratePerHa = projected?.ratePerHa ?: existing?.ratePerHa ?: 0.0,
            rates = projected?.rates ?: existing?.rates ?: emptyList(),
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
            // The manufacturer's PRODUCT page, projected into the legacy column
            // exactly as iOS projects `session.productURL`. The resolver
            // classifies this URL as marketing rather than a label, which is
            // why it stays out of `labelUrl` — but Android was discarding it
            // altogether, so a page the research found and classified never
            // reached the field that displays it.
            productUrl = intel.registration?.manufacturerProductUrl?.takeIf { it.isNotBlank() }
                ?: existing?.productUrl,
            purchase = existing?.purchase,
            productCategory = intel.productCategory.ifBlank { existing?.productCategory.orEmpty() },
            productForm = productForm,
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
            masterChemicalId = master?.masterChemicalId?.takeIf { it.isNotBlank() },
            masterSourceRevision = master?.takeIf { it.masterChemicalId.isNotBlank() }?.masterRevision,
            // The CONFIRMED operational default (sql/214), recorded separately
            // from the projected legacy rates above. Null when the operator
            // confirmed nothing — `explicitNulls = false` then omits the column,
            // so a default recorded on another device survives untouched.
            //
            // Built from the GRAPEVINE partition only: passing the whole label
            // would let a pome-fruit direction supply a `rate_id` for a
            // vineyard default.
            defaultRates = defaults?.storedDefaultRates(
                grapevineUses = intel.registeredUses.viticultural(),
                labelVersion = intel.registration?.labelVersion,
            ),
        )
    }

    /**
     * `"liquid"` / `"solid"` for a formulation the lookup described, else `""`.
     *
     * Mirrors the iOS `ChemicalReviewDraft.formDescription` exactly. An
     * unknown form stays `""` — it is NEVER read as liquid, and never
     * inferred from `g/kg`, `g/L`, rate units or carrier volumes.
     */
    fun formDescription(formType: String?): String {
        val form = formType.orEmpty().lowercase()
        if (form.isEmpty()) return ""
        if (form.contains("liquid") || form.contains("emulsifiable") ||
            form.contains("suspension") || form.contains("soluble concentrate")
        ) {
            return "liquid"
        }
        if (form.contains("solid") || form.contains("granul") || form.contains("powder") ||
            form.contains("wettable") || form.contains("wdg") || form.contains("wg") ||
            form.contains("pellet")
        ) {
            return "solid"
        }
        return ""
    }

    /**
     * The APPLICATION product unit, when something actually established one.
     *
     * Deliberately NOT inferred from active concentration: `750 g/kg` states
     * how much active is in the product; `kg/ha` states how much product goes
     * on the block. Only two things may establish it — an explicit
     * formulation, or the unit a registered rate is actually quoted in. When
     * neither does, this returns null and the field is left for the operator.
     * Mirrors the iOS `ChemicalReviewDraft.productUnit`.
     */
    fun productUnit(form: String, uses: List<ChemicalRegisteredUse>): String? {
        when (form) {
            "liquid" -> return "Litres"
            "solid" -> return "Kg"
        }
        for (rate in uses.flatMap { it.rates }) {
            labelRateUnit(rate.unit)?.let { return it }
        }
        return null
    }

    /** Canonical display unit for a label rate's unit token, or null. */
    fun labelRateUnit(token: String): String? = when (token.trim().lowercase()) {
        "l", "litre", "litres", "liter", "liters" -> "Litres"
        "ml", "millilitre", "millilitres" -> "mL"
        "kg", "kilogram", "kilograms" -> "Kg"
        "g", "gram", "grams" -> "g"
        else -> null
    }

    /** `"liquid"` / `"solid"` for a display unit, or null when unset/unknown. */
    private fun unitFormFamily(unit: String): String? = when (unit) {
        "Litres", "mL" -> "liquid"
        "Kg", "g" -> "solid"
        else -> null
    }

    /**
     * Convert a label rate into the product's own display unit.
     *
     * Returns null rather than guessing when the two are different states of
     * matter: litres and kilograms share a base scale here, so a blind
     * conversion would silently restate `2.5 L/ha` as `2.5 kg/ha`. A range
     * projects at its LOWER bound. [overrideValue] is the vineyard's own
     * dose, in the RATE's unit, supplied only after the selection proved the
     * label authorises it. Mirrors iOS `ChemicalReviewSession.displayValue`.
     */
    fun displayValue(
        rate: ChemicalLabelRate,
        productUnit: String,
        overrideValue: Double? = null,
    ): Double? {
        val rateUnit = labelRateUnit(rate.unit) ?: return null
        val family = unitFormFamily(rateUnit) ?: return null
        if (unitFormFamily(productUnit) != family) return null
        val value = overrideValue ?: rate.value ?: rate.minValue ?: return null
        return chemicalUnitFromBase(productUnit, chemicalUnitToBase(rateUnit, value))
    }

    /** The legacy operational-rate columns projected from a default decision. */
    data class ProjectedLegacyRates(
        val rates: List<ChemicalRate>,
        /** Display-unit per-hectare scalar; `0` means "no rate on record". */
        val ratePerHa: Double,
    )

    /**
     * Project the CONFIRMED vineyard defaults into the legacy `rates` rows old
     * clients read — one direction only, derived FROM the structured record,
     * mirroring the iOS `legacyProjection()`.
     *
     * # Only a confirmed decision may project
     *
     * Returns null when the operator has confirmed nothing, so the caller
     * leaves whatever the record already held untouched.
     *
     * Two fallbacks used to live here and both are gone. `resolvedOption()`
     * falls back to the RECOMMENDATION, and the `?:` chain below it fell back
     * to the FIRST convertible label rate. Either one could write a number
     * into `rates` / `rate_per_ha` that no human had ever agreed to — and
     * those legacy columns are exactly what an older client, and until this
     * release the Spray Calculator, would then dose from. A recommendation is
     * a suggestion; the compatibility columns are an instruction; the two must
     * never be the same value by default.
     *
     * `default_rates` remains authoritative. These rows exist ONLY so an
     * old-client build still renders something familiar.
     *
     * Row ids are kept stable against [existing] rows on the same basis so a
     * re-save updates the operational rate instead of duplicating it.
     */
    fun projectedLegacyRates(
        existing: SavedChemical?,
        unit: String,
        intel: ChemicalIntelligence,
        defaults: ChemicalDefaultRateSelection,
    ): ProjectedLegacyRates? {
        if (!defaults.hasConfirmedDefault) return null
        val rows = mutableListOf<ChemicalRate>()
        var perHaDisplay = 0.0
        for (basis in ChemicalDefaultRateBasis.entries) {
            // Confirmed only. A scalar confirms as its printed amount; a band
            // confirms only to the dose the operator typed inside it.
            val option = defaults.confirmedOption(basis) ?: continue
            val dose = defaults.confirmedDose(basis) ?: continue
            val display = displayValue(option.rate, unit, dose)
            if (display == null || display <= 0) continue
            val basisRaw = when (basis) {
                ChemicalDefaultRateBasis.PER_HECTARE -> CHEMICAL_RATE_PER_HECTARE
                ChemicalDefaultRateBasis.PER_100_LITRES -> CHEMICAL_RATE_PER_100L
            }
            val fallbackLabel = when (basis) {
                ChemicalDefaultRateBasis.PER_HECTARE -> "Per Ha"
                ChemicalDefaultRateBasis.PER_100_LITRES -> "Per 100L"
            }
            // The label's own CONDITION for the chosen default, so the stored
            // operational rate says which registered condition it came from.
            val label = ChemicalDefaultRate.conditionText(option.rate)
                .ifEmpty { fallbackLabel }
            rows.add(
                ChemicalRate(
                    id = existing?.rates?.firstOrNull { it.basis == basisRaw }?.id
                        ?: UUID.randomUUID().toString(),
                    label = label,
                    value = chemicalUnitToBase(unit, display),
                    basis = basisRaw,
                ),
            )
            if (basis == ChemicalDefaultRateBasis.PER_HECTARE) perHaDisplay = display
        }
        return ProjectedLegacyRates(rates = rows, ratePerHa = perHaDisplay)
    }
}
