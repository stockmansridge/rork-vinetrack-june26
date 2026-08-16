package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical

/**
 * Re-verifying an already-structured chemical against the register.
 *
 * This is a different act from Match & Verify. Match & Verify answers "which
 * registered product IS this?" for a record that has never been identified.
 * Re-verification starts from an identity VineTrack already holds and asks "has
 * the official information moved since we last looked?" — so it must never throw
 * that identity away and start over with a brand-name search, and it must never
 * write anything until the operator has seen what changed.
 *
 * Mirrors iOS `ChemicalReverification`.
 */
object ChemicalReverification {

    /**
     * How strongly VineTrack can identify the product before it asks the register
     * anything. Higher is better; the flow always uses the strongest available.
     */
    enum class IdentityStrength(val rank: Int, val label: String, val detail: String) {
        /** A country-scoped registration key, e.g. `"AU:apvma:62764"`. Exact. */
        REGISTRATION_IDENTITY(
            4, "Registration number",
            "Re-checking the exact registration VineTrack already holds.",
        ),

        /**
         * A structured registration (country + scheme, or a bare number) without
         * a full authoritative identity key.
         */
        STRUCTURED_IDENTITY(
            3, "Registration details",
            "Re-checking using this product's registration details.",
        ),

        /** Product name + registrant + country. Strong, but not an identifier. */
        PRODUCT_REGISTRANT_COUNTRY(
            2, "Product, registrant and country",
            "Re-checking using the product name, registrant and country.",
        ),

        /** Product name alone. Ambiguous across manufacturers and countries. */
        PRODUCT_NAME_ONLY(
            1, "Product name",
            "Only the product name is known, so the result must be confirmed against your label.",
        ),

        /** Not even a usable name. */
        NONE(0, "No usable identity", "This product cannot be re-verified yet."),
    }

    /** Everything the lookup needs, plus how confident the starting identity is. */
    data class Plan(
        val productName: String,
        val countryCode: String,
        val registrationNumber: String? = null,
        val scheme: ChemicalRegistrationScheme? = null,
        val registrant: String? = null,
        /** `"AU:apvma:62764"` when known. */
        val identityKey: String? = null,
        val strength: IdentityStrength = IdentityStrength.NONE,
    ) {
        /** Whether Re-verify should be offered at all. */
        val isSupported: Boolean get() = strength != IdentityStrength.NONE

        /**
         * The term the structured lookup is keyed on.
         *
         * A held registration number goes in verbatim rather than being discarded
         * in favour of the brand name — starting a fresh name search when the
         * exact APVMA number is already known is how a re-check ends up on a
         * different product's label.
         */
        val lookupQuery: String
            get() {
                val number = registrationNumber?.takeIf { it.isNotEmpty() }
                if (number != null) {
                    val s = scheme
                    return if (s != null && s != ChemicalRegistrationScheme.OTHER) {
                        "${s.label} $number $productName".trim()
                    } else {
                        "$number $productName".trim()
                    }
                }
                val r = registrant?.takeIf { it.isNotEmpty() }
                if (r != null && strength == IdentityStrength.PRODUCT_REGISTRANT_COUNTRY) {
                    return "$productName $r".trim()
                }
                return productName
            }
    }

    // MARK: Phase 1/2 — is it offered, and on what identity

    /**
     * Build the re-verification plan for a stored chemical.
     *
     * [fallbackCountry] is the vineyard's country, used only when the record
     * itself carries none. Country is part of product identity, so a lookup with
     * no country at all is refused rather than guessed at.
     */
    fun plan(chemical: SavedChemical, fallbackCountry: String = ""): Plan {
        val intel = chemical.resolvedIntelligence
        val registration = intel.registration
        val name = (registration?.registeredProductName ?: chemical.name).trim()
        val country = ChemicalRegistration.normaliseCountry(
            registration?.countryCode?.takeIf { it.isNotEmpty() } ?: fallbackCountry,
        )
        val number = registration?.registrationNumber?.trim()?.takeIf { it.isNotEmpty() }
        val registrant = (registration?.registrant ?: chemical.manufacturer)
            .trim().takeIf { it.isNotEmpty() }

        val strength = when {
            name.isEmpty() -> IdentityStrength.NONE
            registration?.isAuthoritativeIdentity == true && registration.identityKey != null ->
                IdentityStrength.REGISTRATION_IDENTITY
            number != null -> IdentityStrength.STRUCTURED_IDENTITY
            registrant != null && country.isNotEmpty() -> IdentityStrength.PRODUCT_REGISTRANT_COUNTRY
            else -> IdentityStrength.PRODUCT_NAME_ONLY
        }

        return Plan(
            productName = name,
            countryCode = country,
            registrationNumber = number,
            scheme = registration?.scheme,
            registrant = registrant,
            identityKey = registration?.identityKey,
            strength = strength,
        )
    }

    /**
     * Whether the Re-verify Chemical action belongs on this record.
     *
     * Offered for every status INCLUDING needs-match, but for needs-match only
     * when a registration number is actually held. A true legacy product with
     * nothing but a typed name has no identity to re-check — sending it through
     * re-verification would silently become a fresh brand-name search wearing the
     * wrong label, and Match & Verify is the honest action for it.
     */
    fun isOffered(chemical: SavedChemical, fallbackCountry: String = ""): Boolean {
        val plan = plan(chemical, fallbackCountry)
        if (!plan.isSupported) return false
        if (plan.countryCode.isEmpty()) return false
        if (chemical.verificationStatus == ChemicalVerificationStatus.NEEDS_MATCH) {
            return plan.strength.rank >= IdentityStrength.STRUCTURED_IDENTITY.rank
        }
        return true
    }

    /** Why Re-verify is unavailable, for the action's disabled footnote. */
    fun unavailableReason(chemical: SavedChemical, fallbackCountry: String = ""): String? {
        val plan = plan(chemical, fallbackCountry)
        if (plan.productName.isEmpty()) {
            return "Give this product a name before re-verifying it."
        }
        if (plan.countryCode.isEmpty()) {
            return "Set your vineyard's country so this product can be checked " +
                "against the right national register."
        }
        if (chemical.verificationStatus == ChemicalVerificationStatus.NEEDS_MATCH &&
            plan.strength.rank < IdentityStrength.STRUCTURED_IDENTITY.rank
        ) {
            return "This product has no registration details yet. " +
                "Use Match & Verify to identify it first."
        }
        return null
    }

    // MARK: Phase 6 — nothing changed

    /**
     * Whether the lookup found nothing worth showing the operator.
     *
     * Evidence-only differences count as "current": a new retrieval timestamp or
     * a re-cited source is not a change to the product, and reporting it as one
     * would teach operators to click through update screens without reading.
     */
    fun isNoChangeResult(diff: ChemicalIntelligenceDiff): Boolean =
        diff.isEmpty || diff.isEvidenceOnly

    /**
     * Record a successful re-check that found no changes.
     *
     * The product's VALUES are left exactly as they are — nothing about the
     * chemistry moved, so nothing about the chemistry is rewritten. What updates
     * is the evidence: the sources consulted, and when. The stored status claim is
     * only ever adopted from the candidate when the candidate cited an
     * authoritative source; `resolvedVerificationStatus` still has the final say
     * on what is displayed and frozen into future sprays.
     */
    fun confirmingCurrent(
        current: ChemicalIntelligence,
        candidate: ChemicalIntelligence,
        at: String? = null,
    ): ChemicalIntelligence {
        val candidateIsAuthoritative = candidate.verification.sources.containsAuthoritative()
        var verification = current.verification.copy(
            sources = mergedSources(current.verification.sources, candidate.verification.sources),
            // Conflicts come from the fresh evidence: a disagreement resolved
            // upstream must be allowed to clear, and a new one must land.
            conflicts = candidate.verification.conflicts,
            unresolvedFields = candidate.verification.unresolvedFields,
        )
        if (candidateIsAuthoritative) {
            verification = verification.copy(
                status = candidate.verification.status,
                verifiedAt = at ?: candidate.verification.verifiedAt,
            )
        }

        // Keep the label pointer fresh even on a no-change result: it is
        // provenance, not chemistry.
        val registration = current.registration?.let { existing ->
            val fresh = candidate.registration
            existing.copy(
                labelReference = fresh?.labelReference ?: existing.labelReference,
                labelVersion = fresh?.labelVersion ?: existing.labelVersion,
            )
        }

        return current.copy(verification = verification, registration = registration)
    }

    // MARK: Phase 7/9 — accept the candidate

    /**
     * Apply an accepted candidate to the stored record.
     *
     * Runs through [ChemicalEditReconciler] rather than assigning the candidate
     * wholesale, for two reasons. Provenance is reconciled per value, so an
     * authoritative lookup that confirms one active's group does not silently
     * endorse another value it never mentioned. And the resulting trust level is
     * COMPUTED from the merged evidence — there is deliberately no code path here
     * that can set VERIFIED, which is what makes a lookup returning an unresolved
     * conflict incapable of producing a Verified record.
     */
    fun apply(
        candidate: ChemicalIntelligence,
        current: ChemicalIntelligence?,
        at: String? = null,
    ): ChemicalEditOutcome {
        // The lookup's own strongest citation decides whether this edit carries
        // authority. An AI-only answer reconciles as a non-authoritative edit and
        // therefore cannot raise trust, however complete it looks.
        val editSource = candidate.verification.sources.strongest()?.kind
            ?: ChemicalDataSourceKind.AI_INTERPRETATION
        val outcome = ChemicalEditReconciler.reconcile(
            existing = current,
            proposed = candidate,
            editSource = editSource,
            editedAt = at,
        )
        return outcome.carryingLookupConflicts(candidate)
    }

    /**
     * Carry a lookup's own unresolved conflicts into the reconciled outcome.
     *
     * [ChemicalEditReconciler] recomputes activity-group conflicts from the
     * reference table and otherwise preserves the EXISTING record's conflicts,
     * because it was built for a manual edit where the proposal carries no
     * evidence of its own. A re-verification candidate does carry evidence: the
     * lookup can report a disagreement it could not resolve, and silently
     * dropping that would let a conflicted lookup present itself as Verified.
     *
     * Activity-group conflicts are deliberately NOT carried over. The reference
     * table is the authority there, and re-adding a stale one would resurrect a
     * conflict the table says no longer exists.
     */
    private fun ChemicalEditOutcome.carryingLookupConflicts(
        candidate: ChemicalIntelligence,
    ): ChemicalEditOutcome {
        val lookupConflicts = candidate.verification.conflicts
            .filter { it.field != "activity_group" }
        if (lookupConflicts.isEmpty()) return this
        val merged = (intelligence.verification.conflicts + lookupConflicts)
            .distinctBy { it.id }
        return copy(
            intelligence = intelligence.copy(
                verification = intelligence.verification.copy(conflicts = merged),
            ),
        )
    }

    /**
     * Write an accepted outcome onto the saved chemical's flattened sql/194
     * columns, keeping the legacy scalar mirrors in step.
     *
     * Only the current record is touched. No spray record is read, rewritten or
     * even loaded here — a completed application's frozen snapshot is not this
     * function's business, and that is exactly why re-verification cannot rewrite
     * history.
     */
    fun updated(chemical: SavedChemical, outcome: ChemicalEditOutcome): SavedChemical {
        val intel = outcome.intelligence
        val registration = intel.registration
        val updated = chemical.copy(
            manufacturer = registration?.registrant?.takeIf { it.isNotBlank() }
                ?: chemical.manufacturer,
            productCategory = intel.productCategory.ifBlank { chemical.productCategory },
            activeIngredients = intel.activeIngredients,
            activityGroups = intel.activityGroupCodes,
            activityGroupScheme = intel.activityGroups.firstOrNull()?.scheme?.raw
                ?: chemical.activityGroupScheme,
            registrationCountry = registration?.countryCode?.takeIf { it.isNotEmpty() }
                ?: chemical.registrationCountry,
            registrationScheme = registration?.scheme?.raw ?: chemical.registrationScheme,
            registrationNumber = registration?.registrationNumber ?: chemical.registrationNumber,
            registrant = registration?.registrant ?: chemical.registrant,
            registeredProductName = registration?.registeredProductName
                ?: chemical.registeredProductName,
            labelReference = registration?.labelReference ?: chemical.labelReference,
            labelVersion = registration?.labelVersion ?: chemical.labelVersion,
            // The STORED claim, which `resolvedVerificationStatus` re-derives on
            // every read. Never the resolved value: persisting a computed
            // conclusion as though it were evidence is how a stale status
            // outlives the evidence that produced it.
            verificationStatusRaw = intel.verification.status.raw,
            verificationSources = intel.verification.sources,
            verificationConflicts = intel.verification.conflicts,
            verificationUnresolvedFields = intel.verification.unresolvedFields,
            verifiedAt = intel.verification.verifiedAt,
            registeredUses = intel.registeredUses,
            labelRateBases = intel.labelRateBases.map { it.raw },
            activityGroupTableVersion = intel.activityGroupTableVersion,
            intelligenceSchemaVersion = intel.schemaVersion,
        )
        val (activeIngredient, chemicalGroup) = updated.legacyProjection
        return updated.copy(activeIngredient = activeIngredient, chemicalGroup = chemicalGroup)
    }

    // MARK: Helpers

    /** Union of cited sources, candidate first, de-duplicated by identity. */
    private fun mergedSources(
        current: List<ChemicalDataSource>,
        candidate: List<ChemicalDataSource>,
    ): List<ChemicalDataSource> = (candidate + current).distinctBy { it.id }
}
