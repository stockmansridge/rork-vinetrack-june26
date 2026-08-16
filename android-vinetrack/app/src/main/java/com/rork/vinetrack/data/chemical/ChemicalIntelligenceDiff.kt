package com.rork.vinetrack.data.chemical

/**
 * Presentation grouping for the re-verification review screen.
 *
 * [displayOrder] puts chemistry first: a new FRAC code is the reason an operator
 * opened this screen, and registry housekeeping should never be what they read
 * first.
 */
enum class ChemicalIntelligenceDiffSection(val raw: String, val label: String, val displayOrder: Int) {
    ACTIVITY_GROUPS("activity_groups", "Activity groups", 0),
    ACTIVES("actives", "Active ingredients", 1),
    IDENTITY("identity", "Product identity", 2),
    LABEL_RATES("label_rates", "Label rates", 3),
    REGISTERED_USES("registered_uses", "Registered uses", 4),
    EVIDENCE("evidence", "Evidence and versions", 5),
}

/** Which part of a chemical record a change concerns. */
enum class ChemicalIntelligenceDiffField(
    val raw: String,
    val label: String,
    val section: ChemicalIntelligenceDiffSection,
    /**
     * Whether this field alone can change what the future Resistance Engine
     * concludes. Drives the emphasis on the review screen.
     */
    val isResistanceCritical: Boolean,
) {
    // Identity
    PRODUCT_NAME("product_name", "Product name", ChemicalIntelligenceDiffSection.IDENTITY, false),
    REGISTRANT("registrant", "Registrant", ChemicalIntelligenceDiffSection.IDENTITY, false),
    REGISTRATION_IDENTIFIER(
        "registration_identifier", "Registration number",
        ChemicalIntelligenceDiffSection.IDENTITY, true,
    ),
    COUNTRY("country", "Country", ChemicalIntelligenceDiffSection.IDENTITY, true),
    REGISTRATION_SCHEME(
        "registration_scheme", "Registration scheme",
        ChemicalIntelligenceDiffSection.IDENTITY, true,
    ),

    // Actives
    ACTIVE_INGREDIENT(
        "active_ingredient", "Active ingredient",
        ChemicalIntelligenceDiffSection.ACTIVES, true,
    ),
    ACTIVE_CONCENTRATION(
        "active_concentration", "Concentration",
        ChemicalIntelligenceDiffSection.ACTIVES, true,
    ),
    CONCENTRATION_UNIT(
        "concentration_unit", "Concentration unit",
        ChemicalIntelligenceDiffSection.ACTIVES, true,
    ),

    // Activity groups
    ACTIVITY_GROUP_CODE(
        "activity_group_code", "Activity group",
        ChemicalIntelligenceDiffSection.ACTIVITY_GROUPS, true,
    ),
    ACTIVITY_GROUP_SCHEME(
        "activity_group_scheme", "Activity group scheme",
        ChemicalIntelligenceDiffSection.ACTIVITY_GROUPS, true,
    ),

    // Label rates
    LABEL_RATE("label_rate", "Label rate", ChemicalIntelligenceDiffSection.LABEL_RATES, false),

    // Registered uses
    REGISTERED_USE(
        "registered_use", "Registered use",
        ChemicalIntelligenceDiffSection.REGISTERED_USES, false,
    ),
    REGISTERED_USE_RATE(
        "registered_use_rate", "Registered use rate",
        ChemicalIntelligenceDiffSection.REGISTERED_USES, false,
    ),
    WITHHOLDING_PERIOD(
        "withholding_period", "Withholding period",
        ChemicalIntelligenceDiffSection.REGISTERED_USES, false,
    ),
    RE_ENTRY_PERIOD(
        "re_entry_period", "Re-entry period",
        ChemicalIntelligenceDiffSection.REGISTERED_USES, false,
    ),

    // Evidence / versions
    SOURCE("source", "Source", ChemicalIntelligenceDiffSection.EVIDENCE, false),
    LABEL_VERSION("label_version", "Label version", ChemicalIntelligenceDiffSection.EVIDENCE, false),
    ACTIVITY_GROUP_TABLE_VERSION(
        "activity_group_table_version", "Activity group table",
        ChemicalIntelligenceDiffSection.EVIDENCE, false,
    ),
}

enum class ChemicalIntelligenceChangeKind(val raw: String, val label: String) {
    ADDED("added", "Added"),
    REMOVED("removed", "Removed"),
    CHANGED("changed", "Changed"),
}

/** One structural difference between the stored record and a lookup candidate. */
data class ChemicalIntelligenceChange(
    val field: ChemicalIntelligenceDiffField,
    val kind: ChemicalIntelligenceChangeKind,
    /**
     * What the change is ABOUT when the field repeats — an active's name, or a
     * `"Grapes — Powdery mildew"` use. Null for record-level fields.
     */
    val subject: String? = null,
    /** Rendered current value. Null for an addition. */
    val currentValue: String? = null,
    /** Rendered candidate value. Null for a removal. */
    val candidateValue: String? = null,
) {
    // `this.field` throughout: inside a property accessor a bare `field` is the
    // backing-field keyword, not this class's `field` property.
    val id: String
        get() = "${this.field.raw}|${kind.raw}|${subject.orEmpty()}|" +
            "${currentValue.orEmpty()}|${candidateValue.orEmpty()}"

    val section: ChemicalIntelligenceDiffSection get() = this.field.section
    val isResistanceCritical: Boolean get() = this.field.isResistanceCritical

    /** `"Activity group — Azoxystrobin"`. */
    val title: String
        get() = subject?.takeIf { it.isNotEmpty() }
            ?.let { "${this.field.label} — $it" }
            ?: this.field.label
}

/**
 * The result of comparing a stored chemical against a lookup candidate.
 *
 * This is a comparison of MEANING, not of JSON. Two records that list the same
 * two actives in a different order, or cite the same sources in a different
 * order, are the same record — reporting that as "updated information found"
 * would train operators to accept updates without reading them, which is exactly
 * how a real FRAC change slips through unnoticed.
 */
data class ChemicalIntelligenceDiff(
    val changes: List<ChemicalIntelligenceChange> = emptyList(),
) {
    val isEmpty: Boolean get() = changes.isEmpty()
    val hasMeaningfulChanges: Boolean get() = changes.isNotEmpty()

    /** Whether anything changed that the Resistance Engine would read. */
    val hasResistanceCriticalChanges: Boolean get() = changes.any { it.isResistanceCritical }

    /**
     * Changes that are only evidence/version housekeeping. A record whose diff is
     * entirely this is "current, freshly confirmed" rather than "updated".
     */
    val isEvidenceOnly: Boolean
        get() = changes.isNotEmpty() &&
            changes.all { it.section == ChemicalIntelligenceDiffSection.EVIDENCE }

    fun changesIn(section: ChemicalIntelligenceDiffSection): List<ChemicalIntelligenceChange> =
        changes.filter { it.section == section }

    /** Sections that actually contain changes, chemistry first. */
    val populatedSections: List<ChemicalIntelligenceDiffSection>
        get() = changes.map { it.section }.distinct().sortedBy { it.displayOrder }
}

/**
 * Compares stored Chemical Intelligence against a lookup candidate.
 *
 * Mirrors iOS `ChemicalIntelligenceDiffer` decision for decision: both platforms
 * review the same re-verification and must reach the same list of changes, or a
 * grower on a Pixel and a grower on an iPhone would be shown different reasons to
 * accept the same update.
 */
object ChemicalIntelligenceDiffer {

    /**
     * @param current what the Chemical Store holds now. Null/empty is treated as
     *   "nothing known yet", so every populated candidate field is an addition.
     * @param candidate what the lookup proposes. Never written anywhere by this
     *   function — diffing is a read-only act.
     */
    fun diff(
        current: ChemicalIntelligence?,
        candidate: ChemicalIntelligence,
    ): ChemicalIntelligenceDiff {
        val changes = mutableListOf<ChemicalIntelligenceChange>()
        val existing = current ?: ChemicalIntelligence()

        diffIdentity(existing.registration, candidate.registration, changes)
        diffActives(existing.activeIngredients, candidate.activeIngredients, changes)
        diffGroups(existing, candidate, changes)
        diffUses(existing.registeredUses, candidate.registeredUses, changes)
        diffEvidence(existing, candidate, changes)

        return ChemicalIntelligenceDiff(changes)
    }

    // MARK: Identity

    private fun diffIdentity(
        current: ChemicalRegistration?,
        candidate: ChemicalRegistration?,
        changes: MutableList<ChemicalIntelligenceChange>,
    ) {
        compare(
            ChemicalIntelligenceDiffField.PRODUCT_NAME,
            current?.registeredProductName, candidate?.registeredProductName, changes,
        )
        compare(
            ChemicalIntelligenceDiffField.REGISTRANT,
            current?.registrant, candidate?.registrant, changes,
        )
        compare(
            ChemicalIntelligenceDiffField.REGISTRATION_IDENTIFIER,
            current?.registrationNumber, candidate?.registrationNumber, changes,
        )
        compare(
            ChemicalIntelligenceDiffField.COUNTRY,
            current?.countryCode?.takeIf { it.isNotEmpty() },
            candidate?.countryCode?.takeIf { it.isNotEmpty() },
            changes,
        )
        compare(
            ChemicalIntelligenceDiffField.REGISTRATION_SCHEME,
            current?.scheme?.label, candidate?.scheme?.label, changes,
        )
    }

    // MARK: Actives

    /**
     * Actives are matched by normalised NAME, never by position, so reordering a
     * two-active mixture reports nothing.
     */
    private fun diffActives(
        current: List<ChemicalActiveIngredient>,
        candidate: List<ChemicalActiveIngredient>,
        changes: MutableList<ChemicalIntelligenceChange>,
    ) {
        val currentByName = current.filter { it.name.isNotEmpty() }.associateBy { key(it.name) }
        val candidateByName = candidate.filter { it.name.isNotEmpty() }.associateBy { key(it.name) }

        for (active in candidate.filter { it.name.isNotEmpty() }) {
            val prior = currentByName[key(active.name)]
            if (prior == null) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.ACTIVE_INGREDIENT,
                    kind = ChemicalIntelligenceChangeKind.ADDED,
                    subject = active.name,
                    candidateValue = active.displayLabelWithGroup,
                )
                continue
            }
            if (prior.concentration != active.concentration) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.ACTIVE_CONCENTRATION,
                    kind = ChemicalIntelligenceChangeKind.CHANGED,
                    subject = active.name,
                    currentValue = concentrationText(prior),
                    candidateValue = concentrationText(active),
                )
            }
            if (prior.concentrationUnit != active.concentrationUnit) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.CONCENTRATION_UNIT,
                    kind = ChemicalIntelligenceChangeKind.CHANGED,
                    subject = active.name,
                    currentValue = prior.concentrationUnit?.label,
                    candidateValue = active.concentrationUnit?.label,
                )
            }
        }

        for (active in current.filter { it.name.isNotEmpty() }) {
            if (candidateByName[key(active.name)] == null) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.ACTIVE_INGREDIENT,
                    kind = ChemicalIntelligenceChangeKind.REMOVED,
                    subject = active.name,
                    currentValue = active.displayLabelWithGroup,
                )
            }
        }
    }

    // MARK: Activity groups

    /**
     * Groups are diffed twice over, deliberately.
     *
     * Per active, because "Azoxystrobin moved from FRAC 11 to FRAC 3" is the
     * sentence an operator needs. And at product level, because a group can
     * appear or vanish through an active being added or removed, and the set of
     * groups the product belongs to is what resistance rotation is planned
     * against.
     */
    private fun diffGroups(
        current: ChemicalIntelligence,
        candidate: ChemicalIntelligence,
        changes: MutableList<ChemicalIntelligenceChange>,
    ) {
        val currentByName = current.activeIngredients
            .filter { it.name.isNotEmpty() }
            .associateBy { key(it.name) }

        for (active in candidate.activeIngredients.filter { it.name.isNotEmpty() }) {
            val prior = currentByName[key(active.name)] ?: continue
            val before = prior.activityGroup
            val after = active.activityGroup
            if (before?.scheme != after?.scheme) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.ACTIVITY_GROUP_SCHEME,
                    kind = kindOf(before == null, after == null),
                    subject = active.name,
                    currentValue = before?.scheme?.label,
                    candidateValue = after?.scheme?.label,
                )
            }
            if (before?.code != after?.code) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE,
                    kind = kindOf(before == null, after == null),
                    subject = active.name,
                    currentValue = before?.displayLabel,
                    candidateValue = after?.displayLabel,
                )
            }
        }

        // Product-level set comparison, order-insensitive by construction.
        val before = current.activityGroups.map { it.id }.toSet()
        val after = candidate.activityGroups.map { it.id }.toSet()
        for (group in candidate.activityGroups.filter { it.id !in before }) {
            // Only report at product level if no per-active change already said
            // it, so a single reclassification is not listed twice.
            val alreadySaid = changes.any {
                it.field == ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE &&
                    it.candidateValue == group.displayLabel
            }
            if (alreadySaid) continue
            changes += ChemicalIntelligenceChange(
                field = ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE,
                kind = ChemicalIntelligenceChangeKind.ADDED,
                candidateValue = group.displayLabel,
            )
        }
        for (group in current.activityGroups.filter { it.id !in after }) {
            val alreadySaid = changes.any {
                it.field == ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE &&
                    it.currentValue == group.displayLabel
            }
            if (alreadySaid) continue
            changes += ChemicalIntelligenceChange(
                field = ChemicalIntelligenceDiffField.ACTIVITY_GROUP_CODE,
                kind = ChemicalIntelligenceChangeKind.REMOVED,
                currentValue = group.displayLabel,
            )
        }
    }

    // MARK: Registered uses and label rates

    /**
     * Uses are keyed on crop + target so reordering the label's use table reports
     * nothing, and rate sets are compared as sets for the same reason.
     */
    private fun diffUses(
        current: List<ChemicalRegisteredUse>,
        candidate: List<ChemicalRegisteredUse>,
        changes: MutableList<ChemicalIntelligenceChange>,
    ) {
        val currentByKey = current.associateBy { useKey(it) }
        val candidateByKey = candidate.associateBy { useKey(it) }

        for (use in candidate) {
            val prior = currentByKey[useKey(use)]
            if (prior == null) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.REGISTERED_USE,
                    kind = ChemicalIntelligenceChangeKind.ADDED,
                    candidateValue = useLabel(use),
                )
                continue
            }
            diffRates(prior.rates, use.rates, useLabel(use), changes)
            if (prior.withholdingPeriodDays != use.withholdingPeriodDays) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.WITHHOLDING_PERIOD,
                    kind = kindOf(
                        prior.withholdingPeriodDays == null,
                        use.withholdingPeriodDays == null,
                    ),
                    subject = useLabel(use),
                    currentValue = prior.withholdingPeriodDays?.let { "$it days" },
                    candidateValue = use.withholdingPeriodDays?.let { "$it days" },
                )
            }
            if (prior.reEntryPeriodHours != use.reEntryPeriodHours) {
                changes += ChemicalIntelligenceChange(
                    field = ChemicalIntelligenceDiffField.RE_ENTRY_PERIOD,
                    kind = kindOf(
                        prior.reEntryPeriodHours == null,
                        use.reEntryPeriodHours == null,
                    ),
                    subject = useLabel(use),
                    currentValue = prior.reEntryPeriodHours?.let { "$it hours" },
                    candidateValue = use.reEntryPeriodHours?.let { "$it hours" },
                )
            }
        }

        for (use in current.filter { candidateByKey[useKey(it)] == null }) {
            changes += ChemicalIntelligenceChange(
                field = ChemicalIntelligenceDiffField.REGISTERED_USE,
                kind = ChemicalIntelligenceChangeKind.REMOVED,
                currentValue = useLabel(use),
            )
        }
    }

    /**
     * Rates within one use. A changed VALUE on the same basis is reported as a
     * change rather than an add + remove pair, because "100 → 80–100 mL/100 L" is
     * one decision for the operator, not two facts.
     */
    private fun diffRates(
        current: List<ChemicalLabelRate>,
        candidate: List<ChemicalLabelRate>,
        subject: String,
        changes: MutableList<ChemicalIntelligenceChange>,
    ) {
        val currentByBasis = current.associateBy { rateKey(it) }
        val candidateByBasis = candidate.associateBy { rateKey(it) }

        for (rate in candidate) {
            val prior = currentByBasis[rateKey(rate)]
            if (prior != null) {
                if (prior.displayRate != rate.displayRate) {
                    changes += ChemicalIntelligenceChange(
                        field = ChemicalIntelligenceDiffField.LABEL_RATE,
                        kind = ChemicalIntelligenceChangeKind.CHANGED,
                        subject = subject,
                        currentValue = prior.displayRate,
                        candidateValue = rate.displayRate,
                    )
                }
                continue
            }
            changes += ChemicalIntelligenceChange(
                field = ChemicalIntelligenceDiffField.LABEL_RATE,
                kind = ChemicalIntelligenceChangeKind.ADDED,
                subject = subject,
                candidateValue = rate.displayRate,
            )
        }
        for (rate in current.filter { candidateByBasis[rateKey(it)] == null }) {
            changes += ChemicalIntelligenceChange(
                field = ChemicalIntelligenceDiffField.LABEL_RATE,
                kind = ChemicalIntelligenceChangeKind.REMOVED,
                subject = subject,
                currentValue = rate.displayRate,
            )
        }
    }

    // MARK: Evidence and versions

    private fun diffEvidence(
        current: ChemicalIntelligence,
        candidate: ChemicalIntelligence,
        changes: MutableList<ChemicalIntelligenceChange>,
    ) {
        compare(
            ChemicalIntelligenceDiffField.LABEL_VERSION,
            current.registration?.labelVersion, candidate.registration?.labelVersion, changes,
        )

        if (current.activityGroupTableVersion != candidate.activityGroupTableVersion) {
            changes += ChemicalIntelligenceChange(
                field = ChemicalIntelligenceDiffField.ACTIVITY_GROUP_TABLE_VERSION,
                kind = ChemicalIntelligenceChangeKind.CHANGED,
                currentValue = "v${current.activityGroupTableVersion}",
                candidateValue = "v${candidate.activityGroupTableVersion}",
            )
        }

        // Sources compared as a SET of source identities: consulting the same
        // register twice in a different order is not new information.
        val before = current.verification.sources.map { it.id }.toSet()
        val after = candidate.verification.sources.map { it.id }.toSet()
        for (source in candidate.verification.sources.filter { it.id !in before }) {
            changes += ChemicalIntelligenceChange(
                field = ChemicalIntelligenceDiffField.SOURCE,
                kind = ChemicalIntelligenceChangeKind.ADDED,
                candidateValue = source.name.ifEmpty { source.kind.label },
            )
        }
        for (source in current.verification.sources.filter { it.id !in after }) {
            changes += ChemicalIntelligenceChange(
                field = ChemicalIntelligenceDiffField.SOURCE,
                kind = ChemicalIntelligenceChangeKind.REMOVED,
                currentValue = source.name.ifEmpty { source.kind.label },
            )
        }
    }

    // MARK: Helpers

    /**
     * Compares two nullable strings, treating null and "" as the same absence,
     * and whitespace/case-only differences as no change.
     */
    private fun compare(
        field: ChemicalIntelligenceDiffField,
        current: String?,
        candidate: String?,
        changes: MutableList<ChemicalIntelligenceChange>,
    ) {
        val a = current?.trim().orEmpty()
        val b = candidate?.trim().orEmpty()
        if (a.isEmpty() && b.isEmpty()) return
        if (a.equals(b, ignoreCase = true)) return
        // A lookup that simply did not return a field must not be read as the
        // regulator having REMOVED it. Silence is not evidence of absence.
        if (b.isEmpty()) return
        changes += ChemicalIntelligenceChange(
            field = field,
            kind = if (a.isEmpty()) ChemicalIntelligenceChangeKind.ADDED
            else ChemicalIntelligenceChangeKind.CHANGED,
            currentValue = a.takeIf { it.isNotEmpty() },
            candidateValue = b,
        )
    }

    private fun kindOf(currentAbsent: Boolean, candidateAbsent: Boolean): ChemicalIntelligenceChangeKind =
        when {
            currentAbsent -> ChemicalIntelligenceChangeKind.ADDED
            candidateAbsent -> ChemicalIntelligenceChangeKind.REMOVED
            else -> ChemicalIntelligenceChangeKind.CHANGED
        }

    private fun concentrationText(active: ChemicalActiveIngredient): String? {
        val value = active.concentration ?: return null
        val unit = active.concentrationUnit?.label.orEmpty()
        return "${ChemicalActiveIngredient.formatConcentration(value)} $unit".trim()
    }

    private fun key(raw: String): String = raw.trim().lowercase()

    private fun useKey(use: ChemicalRegisteredUse): String =
        "${key(use.crop)}|${key(use.targetRaw)}"

    private fun useLabel(use: ChemicalRegisteredUse): String {
        val crop = use.crop.ifEmpty { "Any crop" }
        return if (use.targetRaw.isEmpty()) crop else "$crop — ${use.targetRaw}"
    }

    /**
     * Rates are identified by basis + label, so "Low disease pressure" and "High
     * disease pressure" on the same basis stay distinct rates.
     */
    private fun rateKey(rate: ChemicalLabelRate): String =
        "${rate.basis.raw}|${key(rate.label)}|${key(rate.unit)}"
}
