package com.rork.vinetrack.data.chemical

/**
 * A resistance-critical fact about a chemical.
 *
 * These are the fields whose value a resistance decision actually depends on. If
 * one of them is changed by hand, the evidence that previously stood behind the
 * record no longer stands behind the NEW value, and the verification claim has
 * to be re-derived rather than carried over.
 *
 * Deliberately an explicit, closed list. Everything NOT named here — purchase
 * price, pack size, stock on hand, supplier, operator notes, the grower's own
 * preferred application rate, label/product URLs — is operational metadata. An
 * edit confined to those fields must leave verification exactly as it was, or
 * growers learn that touching anything destroys trust and stop maintaining
 * their store.
 */
enum class ChemicalResistanceField(val raw: String, val label: String) {
    COUNTRY("country", "Country"),
    REGISTRATION_SCHEME("registration_scheme", "Registration scheme"),
    REGISTRATION_IDENTIFIER("registration_identifier", "Registration number"),
    PRODUCT_IDENTITY("product_identity", "Product identity"),
    ACTIVE_INGREDIENTS("active_ingredients", "Active ingredients"),
    ACTIVE_CONCENTRATION("active_concentration", "Active concentrations"),
    ACTIVITY_GROUP_SCHEME("activity_group_scheme", "Activity group scheme"),
    ACTIVITY_GROUP_CODE("activity_group_code", "Activity group"),
    LABEL_RATES("label_rates", "Label rates"),
    REGISTERED_USES("registered_uses", "Registered uses"),
    ;

    companion object {
        /**
         * The fields that, on their own, invalidate a group-level verification
         * claim. Used for the operator-facing warning copy.
         */
        val chemistryCritical: Set<ChemicalResistanceField> = setOf(
            ACTIVE_INGREDIENTS,
            ACTIVE_CONCENTRATION,
            ACTIVITY_GROUP_SCHEME,
            ACTIVITY_GROUP_CODE,
        )
    }
}

/**
 * The result of putting a proposed edit through the evidence model.
 *
 * Carries the reconciled intelligence plus WHY its trust level moved, so the UI
 * can explain the consequence instead of silently changing a badge.
 */
data class ChemicalEditOutcome(
    val intelligence: ChemicalIntelligence,
    val changedFields: List<ChemicalResistanceField>,
    val previousStatus: ChemicalVerificationStatus,
) {
    /** The status the reconciled evidence supports. Never asserted by the UI. */
    val resolvedStatus: ChemicalVerificationStatus get() = intelligence.resolvedVerificationStatus

    val hasResistanceCriticalChange: Boolean get() = changedFields.isNotEmpty()

    /** Whether trust actually fell as a result of this edit. */
    val isDowngrade: Boolean get() = resolvedStatus.confidenceRank < previousStatus.confidenceRank

    /**
     * Concise operator-facing consequence, or null when verification is
     * unaffected. Deliberately states the outcome rather than asking permission:
     * a correction must never be blocked, only explained.
     */
    val warning: String?
        get() {
            if (!hasResistanceCriticalChange || !isDowngrade) return null
            val subject = when {
                changedFields.any { it in ChemicalResistanceField.chemistryCritical } ->
                    "Changing active ingredients or activity groups"
                else -> "Changing this product's registered identity"
            }
            return "$subject means this product can no longer keep its " +
                "${previousStatus.label.lowercase()} status unless the new information is " +
                "supported by verification evidence. It will be recorded as " +
                "${resolvedStatus.label.lowercase()}."
        }
}

/**
 * Re-derives a chemical's verification from its evidence after a manual edit.
 *
 * This closes the trust hole where a record could keep a stored `verified`
 * status after a human changed the very value that was verified. The rule is not
 * "an edit unverifies a product" — that would be a UI rule bolted on top of the
 * model. The rule is that evidence belongs to a VALUE: when the value changes by
 * hand, the authoritative citation that supported the old value is withdrawn,
 * the operator's own entry is recorded in its place, and
 * [ChemicalVerification.resolvedStatus] is left to reach whatever conclusion the
 * remaining evidence actually supports.
 *
 * That is why a group edit on a two-active product can legitimately land on
 * `PARTIALLY_VERIFIED` (the other active is still authoritatively classified) or
 * on `CONFLICT` (the reference table positively disagrees with what was typed) —
 * the outcome is computed, never assigned.
 */
object ChemicalEditReconciler {

    /**
     * Reconcile a structured proposal (from the structured manual editor or the
     * re-verify flow) against what the record previously held.
     *
     * @param existing the record's current intelligence, or null for a new product.
     * @param proposed the values the operator wants to store.
     * @param editSource how the proposed values arrived. Manual entry by default;
     *   the re-verify flow passes its own authoritative sources through instead.
     */
    fun reconcile(
        existing: ChemicalIntelligence?,
        proposed: ChemicalIntelligence,
        editSource: ChemicalDataSourceKind = ChemicalDataSourceKind.MANUAL_ENTRY,
        editedAt: String? = null,
    ): ChemicalEditOutcome {
        val previousStatus = existing?.resolvedVerificationStatus
            ?: ChemicalVerificationStatus.UNVERIFIED
        val changed = linkedSetOf<ChemicalResistanceField>()

        val reconciledActives = reconcileActives(
            existing = existing?.activeIngredients ?: emptyList(),
            proposed = proposed.activeIngredients,
            editSource = editSource,
            changed = changed,
        )

        // Activity-group conflicts are recomputed from scratch for every active
        // on every reconcile, so correcting a bad value CLEARS the conflict it
        // caused. Conflicts about anything else are preserved untouched: this
        // function did not look at those fields and has no basis to dismiss them.
        val groupConflicts = reconciledActives.mapNotNull { active ->
            conflictFor(active, editSource)
        }
        val otherConflicts = (existing?.verification?.conflicts ?: emptyList())
            .filter { it.field != "activity_group" }

        val registration = reconcileRegistration(
            existing = existing?.registration,
            proposed = proposed.registration,
            changed = changed,
        )

        val existingUses: List<ChemicalRegisteredUse> = existing?.registeredUses ?: emptyList()
        if (proposed.registeredUses != existingUses) {
            changed += ChemicalResistanceField.REGISTERED_USES
            val existingRates: List<ChemicalLabelRate> = existingUses.flatMap { it.rates }
            if (proposed.registeredUses.flatMap { it.rates } != existingRates) {
                changed += ChemicalResistanceField.LABEL_RATES
            }
        }

        val verification = reconcileVerification(
            existing = existing?.verification,
            proposed = proposed.verification,
            changed = changed,
            conflicts = (groupConflicts + otherConflicts).distinctBy { it.id },
            editSource = editSource,
            editedAt = editedAt,
        )

        return ChemicalEditOutcome(
            intelligence = proposed.copy(
                activeIngredients = reconciledActives,
                registration = registration,
                verification = verification,
                activityGroupTableVersion = AuthoritativeActivityGroups.TABLE_VERSION,
            ),
            changedFields = changed.toList(),
            previousStatus = previousStatus,
        )
    }

    /**
     * Reconcile an edit made through the LEGACY scalar form, which offers only
     * free-text `active ingredient` and `chemical group` boxes.
     *
     * The comparison is made against the record's own legacy PROJECTIONS. If the
     * operator did not touch those boxes, the text still equals what the
     * structured data projects, nothing resistance-critical changed, and the
     * structured intelligence is returned untouched — an edit to price or notes
     * through this form must not disturb a verified product.
     *
     * If the text HAS changed, the operator has hand-authored chemistry. It is
     * taken seriously — their value is stored — but as [ChemicalDataSourceKind.MANUAL_ENTRY],
     * and cross-checked against the reference table so a positive disagreement
     * surfaces as a conflict rather than being quietly accepted.
     */
    fun reconcileLegacyEdit(
        existing: ChemicalIntelligence?,
        activeIngredientText: String,
        chemicalGroupText: String,
        modeOfActionText: String,
        productCategory: String,
        registrantText: String,
        editedAt: String? = null,
    ): ChemicalEditOutcome? {
        val current = existing?.takeIf { !it.isEmpty } ?: return null

        val activesChanged = !sameFreeText(
            activeIngredientText,
            current.legacyActiveIngredient,
        )
        val groupChanged = !sameFreeText(chemicalGroupText, current.legacyChemicalGroup)
        val registrantChanged = registrantText.isNotBlank() && !sameFreeText(
            registrantText,
            current.registration?.registrant.orEmpty(),
        )

        if (!activesChanged && !groupChanged && !registrantChanged) return null

        val proposedActives = if (activesChanged || groupChanged) {
            manualActivesFrom(
                activeIngredientText = activeIngredientText,
                chemicalGroupText = chemicalGroupText,
                modeOfActionText = modeOfActionText,
                productCategory = productCategory.ifBlank { current.productCategory },
                existing = current.activeIngredients,
            )
        } else {
            current.activeIngredients
        }

        val proposedRegistration = if (registrantChanged) {
            (current.registration ?: ChemicalRegistration()).copy(registrant = registrantText.trim())
        } else {
            current.registration
        }

        return reconcile(
            existing = current,
            proposed = current.copy(
                activeIngredients = proposedActives,
                registration = proposedRegistration,
                productCategory = productCategory.ifBlank { current.productCategory },
            ),
            editSource = ChemicalDataSourceKind.MANUAL_ENTRY,
            editedAt = editedAt,
        )
    }

    /**
     * Build structured actives from the legacy free-text boxes.
     *
     * Positional pairing only when the counts line up exactly — the same rule
     * [ChemicalIntelligence.legacySeed] uses, for the same reason: guessing which
     * active in a mixture owns a single typed group would invent chemistry.
     * Concentrations already known for an active that was NOT renamed are
     * carried across, because the free-text box never held them.
     */
    private fun manualActivesFrom(
        activeIngredientText: String,
        chemicalGroupText: String,
        modeOfActionText: String,
        productCategory: String,
        existing: List<ChemicalActiveIngredient>,
    ): List<ChemicalActiveIngredient> {
        val scheme = ChemicalActivityGroupScheme.impliedByProductCategory(productCategory)
        var codes = ChemicalActivityGroup.parseLegacyText(chemicalGroupText, scheme)
        if (codes.isEmpty()) {
            codes = ChemicalActivityGroup.parseLegacyText(modeOfActionText, scheme)
        }
        val names = ChemicalIntelligence.splitActiveNames(activeIngredientText)
        if (names.isEmpty()) {
            return codes.map { group ->
                ChemicalActiveIngredient(
                    name = "",
                    activityGroup = group,
                    groupSource = ChemicalDataSourceKind.MANUAL_ENTRY,
                    identitySource = ChemicalDataSourceKind.MANUAL_ENTRY,
                )
            }
        }
        return names.mapIndexed { index, name ->
            val prior = existing.firstOrNull { it.name.equals(name, ignoreCase = true) }
            ChemicalActiveIngredient(
                name = name,
                concentration = prior?.concentration,
                concentrationUnit = prior?.concentrationUnit,
                activityGroup = if (names.size == codes.size) codes[index] else prior?.activityGroup,
                groupSource = ChemicalDataSourceKind.MANUAL_ENTRY,
                // The free-text box never held the concentration, so an active whose
                // name still matches has not had its IDENTITY restated — only its
                // group. Inheriting the prior identity provenance is what keeps a
                // looked-up product identified after a hand-edited group, instead of
                // the record forgetting a register ever confirmed which product it is.
                identitySource = prior?.identitySource ?: ChemicalDataSourceKind.MANUAL_ENTRY,
            )
        }
    }

    /**
     * Pair proposed actives with what the record already held and decide, per
     * active, whether the old provenance still applies.
     *
     * Provenance survives ONLY where the value is byte-for-byte the same. A
     * changed group, a changed concentration or a brand-new active all take the
     * edit's own source, which is what stops FRAC's classification of
     * Azoxystrobin-as-Group-11 from appearing to endorse a hand-typed Group 3.
     */
    private fun reconcileActives(
        existing: List<ChemicalActiveIngredient>,
        proposed: List<ChemicalActiveIngredient>,
        editSource: ChemicalDataSourceKind,
        changed: MutableSet<ChemicalResistanceField>,
    ): List<ChemicalActiveIngredient> {
        val existingByName = existing.associateBy { it.name.trim().lowercase() }
        if (existing.map { it.name.trim().lowercase() }.toSet() !=
            proposed.map { it.name.trim().lowercase() }.toSet()
        ) {
            changed += ChemicalResistanceField.ACTIVE_INGREDIENTS
        }

        return proposed.map { active ->
            val prior = existingByName[active.name.trim().lowercase()]
            if (prior == null) {
                // A newly named active carries no inherited authority.
                return@map active.copy(
                    groupSource = active.groupSource ?: editSource,
                    identitySource = active.identitySource ?: editSource,
                )
            }

            val groupMoved = prior.activityGroup != active.activityGroup
            if (groupMoved) {
                if (prior.activityGroup?.scheme != active.activityGroup?.scheme) {
                    changed += ChemicalResistanceField.ACTIVITY_GROUP_SCHEME
                }
                if (prior.activityGroup?.code != active.activityGroup?.code) {
                    changed += ChemicalResistanceField.ACTIVITY_GROUP_CODE
                }
            }
            val concentrationMoved = prior.concentration != active.concentration ||
                prior.concentrationUnit != active.concentrationUnit
            if (concentrationMoved) changed += ChemicalResistanceField.ACTIVE_CONCENTRATION

            active.copy(
                // Withdraw the old citation for a value it no longer describes.
                groupSource = if (groupMoved) editSource else (active.groupSource ?: prior.groupSource),
                identitySource = if (concentrationMoved) {
                    editSource
                } else {
                    active.identitySource ?: prior.identitySource
                },
            )
        }
    }

    /**
     * Country, scheme and registration number ARE the product's identity, so any
     * change to them means the record now claims to be a different registered
     * product and cannot inherit the previous registration's authority.
     *
     * A changed registrant NAME is treated as an identity change too, but a
     * changed product name is not: once a registration number is known, that
     * number is the identity and the display name is just a label the grower is
     * free to keep tidy ("Amistar 250 (old stock)").
     */
    private fun reconcileRegistration(
        existing: ChemicalRegistration?,
        proposed: ChemicalRegistration?,
        changed: MutableSet<ChemicalResistanceField>,
    ): ChemicalRegistration? {
        if (existing == null || proposed == null) {
            if (existing?.identityKey != proposed?.identityKey) {
                changed += ChemicalResistanceField.REGISTRATION_IDENTIFIER
            }
            return proposed
        }
        if (!existing.countryCode.equals(proposed.countryCode, ignoreCase = true)) {
            changed += ChemicalResistanceField.COUNTRY
        }
        if (existing.scheme != proposed.scheme) {
            changed += ChemicalResistanceField.REGISTRATION_SCHEME
        }
        if (existing.registrationNumber?.trim() != proposed.registrationNumber?.trim()) {
            changed += ChemicalResistanceField.REGISTRATION_IDENTIFIER
        }
        if (!sameFreeText(existing.registrant.orEmpty(), proposed.registrant.orEmpty())) {
            changed += ChemicalResistanceField.PRODUCT_IDENTITY
        }
        return proposed
    }

    /**
     * Rebuild the verification block around the reconciled values.
     *
     * When nothing resistance-critical moved the block is left completely alone.
     * When something did move, every authoritative citation is withdrawn — it was
     * evidence for the old value — the edit's own source is recorded, and the
     * stored claim is lowered so [ChemicalVerification.resolvedStatus] cannot
     * read a stale `verified` back out. Confidence is only ever reduced here.
     */
    private fun reconcileVerification(
        existing: ChemicalVerification?,
        proposed: ChemicalVerification,
        changed: Set<ChemicalResistanceField>,
        conflicts: List<ChemicalVerificationConflict>,
        editSource: ChemicalDataSourceKind,
        editedAt: String?,
    ): ChemicalVerification {
        val base = existing ?: proposed
        if (changed.isEmpty()) {
            return base.copy(conflicts = conflicts)
        }

        val citation = ChemicalDataSource(
            kind = editSource,
            name = when (editSource) {
                ChemicalDataSourceKind.MANUAL_ENTRY -> "Edited in VineTrack"
                else -> proposed.sources.strongest()?.name ?: "Chemical lookup"
            },
            retrievedAt = editedAt,
        )

        // An authoritative source cited for the PREVIOUS value must not be
        // carried forward as though it endorsed the new one.
        val retained = if (editSource.isAuthoritative) {
            proposed.sources
        } else {
            base.sources.filterNot { it.kind.isAuthoritative }
        }
        val sources = (retained + citation).distinctBy { it.id }

        val loweredStatus = when {
            conflicts.isNotEmpty() -> ChemicalVerificationStatus.CONFLICT
            editSource.isAuthoritative -> proposed.status
            // Never keep a verified/partially-verified CLAIM across a manual
            // change. resolvedStatus may still compute PARTIALLY_VERIFIED from
            // surviving evidence, which is a conclusion, not a retained claim.
            base.status == ChemicalVerificationStatus.NEEDS_MATCH ->
                ChemicalVerificationStatus.NEEDS_MATCH
            else -> ChemicalVerificationStatus.UNVERIFIED
        }

        return base.copy(
            status = loweredStatus,
            sources = sources,
            conflicts = conflicts,
            verifiedAt = if (editSource.isAuthoritative) proposed.verifiedAt else null,
            unresolvedFields = proposed.unresolvedFields,
        )
    }

    /** Cross-check one active's group against the reference table. */
    private fun conflictFor(
        active: ChemicalActiveIngredient,
        editSource: ChemicalDataSourceKind,
    ): ChemicalVerificationConflict? {
        if (active.name.isBlank()) return null
        val group = active.activityGroup?.takeIf { it.isResistanceRelevant } ?: return null
        return AuthoritativeActivityGroups.reconcile(
            activeName = active.name,
            extracted = group,
            extractedSource = active.groupSource ?: editSource,
        ).conflict
    }

    /** Case- and whitespace-insensitive comparison of two operator-typed strings. */
    private fun sameFreeText(a: String, b: String): Boolean =
        a.trim().replace(Regex("\\s+"), " ").equals(
            b.trim().replace(Regex("\\s+"), " "),
            ignoreCase = true,
        )
}
