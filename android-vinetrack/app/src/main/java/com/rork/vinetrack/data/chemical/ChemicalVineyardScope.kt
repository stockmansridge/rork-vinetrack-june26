package com.rork.vinetrack.data.chemical

/**
 * The vineyard-only scoping rule for a saved chemical's OPERATIONAL data.
 *
 * # Why this exists
 *
 * The VineTrack Chemical Store describes products as a vineyard uses them. A
 * real APVMA label, however, routinely registers the same product on macadamias,
 * cereals, citrus, pasture and vegetables alongside grapevines. The resolver
 * returns all of it, and until this type existed the whole label was persisted
 * into `registered_uses` — the same collection that feeds default-rate options,
 * `viticulturalTargets`, the Spray Tool's rate projection and the compliance
 * display.
 *
 * That is not a cosmetic problem. A macadamia rate sitting in the operational
 * use set is a number a spray calculation can reach. A cereal withholding period
 * is a legal figure attached to the wrong crop. Hiding those rows in the UI
 * while still saving them as ordinary uses would leave the defect intact and
 * merely invisible, which is why the partition happens at the WRITE boundary.
 *
 * # What is kept
 *
 * ```text
 * grapevine stated uses     KEPT   — the vineyard's operational registrations
 * product-level rate carriers KEPT — rates the label states for the PRODUCT,
 *                                    belonging to no crop at all
 * every other crop          DROPPED from the operational set
 * ```
 *
 * A product-level rate carrier ([ChemicalManualEntry.isProductRateCarrier]) has
 * no crop and no target by construction, so it is not "another crop" — it is the
 * product's own rate, recorded without inventing a registration claim. Dropping
 * it would discard real label content and would break every product whose label
 * quotes one rate for the whole drum.
 *
 * # What is NOT dropped
 *
 * Provenance survives untouched: `verification.sources`, `field_provenance`,
 * conflicts and the registration block are evidence about the RESEARCH, not
 * operational crop claims, and nothing here rewrites them. The lookup response
 * also keeps its own `other_crop_uses`, so a review screen can still show
 * "other crops on this label" from the live research before the record is saved.
 *
 * Mirrors the iOS `ChemicalVineyardScope`, and the server's own
 * `grapevine_uses` / `other_crop_uses` partition in
 * `supabase/functions/chemical-info-lookup/grapevine_label.ts`. All three read
 * grapevine membership through the same whole-token predicate
 * ([ChemicalGrapevineCrop]), so `GRAPEFRUIT` can never be scoped in as a vine.
 */
object ChemicalVineyardScope {

    /**
     * Whether this use belongs in the vineyard's OPERATIONAL set.
     *
     * True for a grapevine registration, and for a product-level rate carrier
     * that claims no crop at all. False for every other crop on the label.
     */
    fun isOperational(use: ChemicalRegisteredUse): Boolean =
        ChemicalManualEntry.isProductRateCarrier(use) || use.isViticultural

    /** The operational partition: grapevine claims plus product-level rates. */
    fun operationalUses(uses: List<ChemicalRegisteredUse>): List<ChemicalRegisteredUse> =
        uses.filter { isOperational(it) }

    /**
     * The uses this scoping removes — every stated registration on a crop that
     * is not grapevines.
     *
     * Exposed so a screen can say honestly HOW MUCH of the label it is not
     * showing, rather than silently presenting a partial document as the whole.
     */
    fun excludedUses(uses: List<ChemicalRegisteredUse>): List<ChemicalRegisteredUse> =
        uses.filterNot { isOperational(it) }

    /**
     * Distinct crop wordings that were excluded, in label order.
     *
     * The label's own wording is preserved verbatim (`"MACADAMIAS"`), because
     * re-titling a regulator's crop name is its own small falsification.
     */
    fun excludedCrops(uses: List<ChemicalRegisteredUse>): List<String> {
        val seen = LinkedHashSet<String>()
        for (use in excludedUses(uses)) {
            val crop = use.crop.trim()
            if (crop.isNotEmpty()) seen.add(crop)
        }
        return seen.toList()
    }

    /** True when the label carries registrations for crops other than grapes. */
    fun hasExcludedUses(uses: List<ChemicalRegisteredUse>): Boolean =
        uses.any { !isOperational(it) }

    /**
     * Scope an intelligence payload to the vineyard before it is persisted.
     *
     * The ONE place `registered_uses` is narrowed. Everything else on the
     * payload — actives, registration, verification, provenance, category — is
     * carried through byte for byte, because none of it is a crop claim.
     *
     * Idempotent: scoping an already-scoped record changes nothing, so a
     * re-save, a re-verification or an edit can never compound the filter.
     */
    fun scoped(intelligence: ChemicalIntelligence): ChemicalIntelligence {
        val operational = operationalUses(intelligence.registeredUses)
        if (operational.size == intelligence.registeredUses.size) return intelligence
        return intelligence.copy(registeredUses = operational)
    }

    /**
     * The sentence shown when a label's other crops were left out.
     *
     * Deliberately states the RULE and the evidence, not an apology: the
     * operator should know the document says more than the record does, and
     * why. Null when nothing was excluded — an empty notice is noise.
     */
    fun exclusionNotice(uses: List<ChemicalRegisteredUse>): String? {
        val crops = excludedCrops(uses)
        if (crops.isEmpty()) return null
        val listed = when {
            crops.size == 1 -> crops[0]
            crops.size == 2 -> "${crops[0]} and ${crops[1]}"
            else -> crops.dropLast(1).joinToString(", ") + " and " + crops.last()
        }
        return "This label also registers $listed. VineTrack is a vineyard record, " +
            "so only the grapevine directions are saved and used for rates and " +
            "spray calculations."
    }
}
