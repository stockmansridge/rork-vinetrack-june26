package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical
import java.util.UUID

/**
 * One active ingredient as the operator is typing it.
 *
 * Text rather than parsed numbers, because a half-typed `"20"` on the way to
 * `"200"` must not momentarily become a stored concentration. Parsing happens
 * once, in [ChemicalManualEntry], when the draft becomes structured intelligence.
 */
data class ChemicalManualActiveDraft(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val concentrationText: String = "",
    val concentrationUnit: ChemicalConcentrationUnit? = null,
    /**
     * Null means the operator has not said which classification system applies.
     * That is a real state — "I don't know" — and is not the same as
     * [ChemicalActivityGroupScheme.NOT_APPLICABLE], which asserts the product HAS
     * no resistance group.
     */
    val scheme: ChemicalActivityGroupScheme? = null,
    val groupCode: String = "",
)

/** One label rate as the operator is typing it. */
data class ChemicalManualRateDraft(
    val id: String = UUID.randomUUID().toString(),
    /** What the label calls this rate, e.g. `"High disease pressure"`. */
    val label: String = "",
    val basis: ChemicalLabelRateBasis = ChemicalLabelRateBasis.PER_HECTARE,
    /** Used by the single-value bases. */
    val valueText: String = "",
    /** Used by the range bases. */
    val minText: String = "",
    val maxText: String = "",
    /** The product unit the rate is quoted in: `"L"`, `"mL"`, `"kg"`, `"g"`. */
    val unit: String = "L",
    /** Verbatim label wording, for a basis VineTrack has no shape for. */
    val rawText: String = "",
)

/** One registered use as the operator is typing it. */
data class ChemicalManualUseDraft(
    val id: String = UUID.randomUUID().toString(),
    val crop: String = "Grapes",
    /**
     * The target as the label words it. Free text on purpose: VineTrack's six
     * spray targets assist entry, they do not bound what a label may register.
     */
    val targetRaw: String = "",
    val rates: List<ChemicalManualRateDraft> = emptyList(),
    val withholdingPeriodDaysText: String = "",
    val reEntryPeriodHoursText: String = "",
    val restrictions: String = "",
)

/**
 * Everything the structured manual editor collects, before it becomes a
 * [ChemicalIntelligence].
 *
 * Deliberately a plain value type with no behaviour: the rules live in
 * [ChemicalManualEntry] so they can be tested without a Compose sheet.
 */
data class ChemicalManualDraft(
    val productName: String = "",
    /**
     * ISO country code the product is registered/stocked in. Defaults from the
     * vineyard, but editable — a vineyard may stock an imported product.
     */
    val countryCode: String = "",
    /** Product category key from the existing `ProductCategories` vocabulary. */
    val productCategory: String = "",
    val registrant: String = "",
    val registrationScheme: ChemicalRegistrationScheme? = null,
    val registrationNumber: String = "",
    val actives: List<ChemicalManualActiveDraft> = emptyList(),
    /**
     * Label rates that apply to the product generally, rather than to one
     * specific registered use.
     */
    val productRates: List<ChemicalManualRateDraft> = emptyList(),
    val uses: List<ChemicalManualUseDraft> = emptyList(),
)

/**
 * Turns structured manual entry into [ChemicalIntelligence], and back again for
 * editing.
 *
 * This is the replacement for the legacy scalar chemistry boxes. The operator no
 * longer types `"Tebuconazole 200 g/L + Azoxystrobin 120 g/L"` into one field and
 * `"3 + 11"` into another — they add two actives, each with its own concentration
 * and its own resistance group, and the structured record holds two independent
 * active→group relationships. `"3 + 11"` survives only as a derived legacy
 * projection for old clients.
 *
 * Three rules are enforced here and nowhere else:
 *
 * 1. **Manual entry is manual evidence.** Every active is stored with
 *    `MANUAL_ENTRY` provenance, so `hasAuthoritativeGroup` is false and no amount
 *    of completeness can reach Verified.
 * 2. **Trust is computed.** The draft is put through
 *    [ChemicalEditReconciler.reconcile], which cross-checks each active against
 *    [AuthoritativeActivityGroups] and lets `resolvedStatus` reach its own
 *    conclusion. There is no manual status to set.
 * 3. **Operational data is untouched.** Price, pack, stock, supplier and notes
 *    never enter this file, so rebuilding the chemistry cannot disturb them.
 *
 * Mirrors the iOS `ChemicalManualEntry` decision for decision.
 */
object ChemicalManualEntry {

    /**
     * Whether a [ChemicalRegisteredUse] carries product-level label rates rather
     * than a registered crop+target claim.
     *
     * The model attaches rates to uses, but an operator reading a label often
     * knows the rate before they know which of the registered uses it belongs to.
     * Rather than invent a crop and a target — which would tell the future
     * Resistance Engine the product is registered against a disease nobody stated
     * — the rates are held on a use with NO crop and NO target. It contributes to
     * `labelRateBases` (which is rate information) and is excluded from
     * `viticultural`/`viticulturalTargets` (which are use claims).
     */
    fun isProductRateCarrier(use: ChemicalRegisteredUse): Boolean =
        use.crop.isEmpty() && use.targetRaw.isEmpty()

    // ---- Draft → structured ----

    /**
     * Build the intelligence the draft PROPOSES, without reconciling it.
     *
     * Use [outcome] to store a draft. This function exists so the proposal can be
     * inspected and diffed separately from the trust decision made about it.
     */
    fun proposedIntelligence(
        draft: ChemicalManualDraft,
        existing: ChemicalIntelligence?,
    ): ChemicalIntelligence {
        val country = ChemicalRegistration.normaliseCountry(draft.countryCode)
        val registrant = draft.registrant.trim()
        val number = draft.registrationNumber.trim()

        // A registration is only built when the operator actually stated
        // something about identity. An empty block stays null rather than being
        // materialised as an empty shell that later looks like a failed lookup.
        val registration = if (country.isEmpty() && registrant.isEmpty() && number.isEmpty()) {
            null
        } else {
            ChemicalRegistration.of(
                countryCode = country,
                scheme = draft.registrationScheme,
                registrationNumber = number,
                registrant = registrant,
                // The registered product name is the REGISTER's name for the
                // product. Only a lookup can establish that, so a manually typed
                // display name is never promoted into it.
                registeredProductName = existing?.registration?.registeredProductName,
                labelReference = existing?.registration?.labelReference,
                labelVersion = existing?.registration?.labelVersion,
            )
        }

        val uses = buildList {
            if (draft.productRates.isNotEmpty()) {
                add(
                    ChemicalRegisteredUse(
                        crop = "",
                        targetRaw = "",
                        rates = labelRates(draft.productRates),
                    ),
                )
            }
            addAll(draft.uses.mapNotNull { registeredUse(it) })
        }

        return ChemicalIntelligence(
            activeIngredients = draft.actives.mapNotNull { activeIngredient(it) },
            registration = registration,
            // The claim carried in is the record's own; `reconcile` decides what
            // it becomes. A brand-new manual product starts from `manual()`,
            // whose single cited source is the operator's own entry.
            verification = existing?.verification ?: ChemicalVerification.manual(),
            registeredUses = uses,
            productCategory = draft.productCategory.trim(),
            activityGroupTableVersion = AuthoritativeActivityGroups.TABLE_VERSION,
            schemaVersion = ChemicalIntelligence.CURRENT_SCHEMA_VERSION,
        )
    }

    /**
     * Reconcile a manual draft against what the record already held.
     *
     * Everything that makes manual entry safe happens inside
     * [ChemicalEditReconciler.reconcile] with `MANUAL_ENTRY` as the source:
     * authoritative citations for values the operator changed are withdrawn, each
     * active's group is cross-checked against the reference table, and the status
     * is re-derived. A hand-typed FRAC 3 on Azoxystrobin therefore surfaces as a
     * conflict instead of being quietly accepted, and the operator's own value is
     * still what gets stored.
     */
    fun outcome(
        draft: ChemicalManualDraft,
        existing: ChemicalIntelligence?,
        editedAt: String? = null,
    ): ChemicalEditOutcome {
        // A record with no structured data yet has nothing to reconcile against.
        // Passing its legacy SEED as `existing` would make the seed look like
        // established prior evidence, so null is passed instead.
        val prior = existing?.takeIf { !it.isEmpty }
        return ChemicalEditReconciler.reconcile(
            existing = prior,
            proposed = proposedIntelligence(draft, prior),
            editSource = ChemicalDataSourceKind.MANUAL_ENTRY,
            editedAt = editedAt,
        )
    }

    /** Reconcile a manual draft for a saved chemical. */
    fun outcome(
        draft: ChemicalManualDraft,
        chemical: SavedChemical?,
        editedAt: String? = null,
    ): ChemicalEditOutcome = outcome(draft, chemical?.storedIntelligence, editedAt)

    // ---- Structured → draft ----

    /**
     * Repopulate the editor from a stored record.
     *
     * Every active, every concentration, every scheme and code, every label rate,
     * every use, the withholding and re-entry periods, the identity and the
     * country all come back. A record read into a draft and written straight back
     * out is unchanged, which is what makes "add another active" safe on a product
     * that already has two.
     *
     * A legacy record with no structured data is read through its
     * `resolvedIntelligence` SEED, so the operator starts from what the old
     * free-text fields implied rather than from an empty form — but the seed's
     * `LEGACY_RECORD` provenance is dropped, because saving the draft is the
     * operator asserting these values themselves.
     */
    fun draft(chemical: SavedChemical?, fallbackCountry: String): ChemicalManualDraft {
        if (chemical == null) {
            return ChemicalManualDraft(
                countryCode = ChemicalRegistration.normaliseCountry(fallbackCountry),
                actives = listOf(ChemicalManualActiveDraft()),
            )
        }
        val intel = chemical.resolvedIntelligence
        val country = intel.registration?.countryCode?.takeIf { it.isNotEmpty() }
            ?: ChemicalRegistration.normaliseCountry(fallbackCountry)

        val actives = intel.activeIngredients.map { active ->
            ChemicalManualActiveDraft(
                name = active.name,
                concentrationText = active.concentration
                    ?.let { formatChemicalNumber(it) } ?: "",
                concentrationUnit = active.concentrationUnit,
                scheme = active.activityGroup?.scheme,
                groupCode = active.activityGroup?.code ?: "",
            )
        }

        val carriers = intel.registeredUses.filter { isProductRateCarrier(it) }
        val stated = intel.registeredUses.filterNot { isProductRateCarrier(it) }

        return ChemicalManualDraft(
            productName = chemical.name,
            countryCode = country,
            productCategory = intel.productCategory.ifBlank { chemical.productCategory },
            registrant = intel.registration?.registrant ?: chemical.manufacturer,
            registrationScheme = intel.registration?.scheme,
            registrationNumber = intel.registration?.registrationNumber ?: "",
            // An empty editor is not useful, so a product with no actives on
            // record opens with one blank row to fill in.
            actives = actives.ifEmpty { listOf(ChemicalManualActiveDraft()) },
            productRates = carriers.flatMap { use -> use.rates.map { rateDraft(it) } },
            uses = stated.map { useDraft(it) },
        )
    }

    // ---- Display ----

    /**
     * `"FRAC 3 + 11"` — a product-level summary DERIVED from the per-active
     * groups, for display only.
     *
     * This is the string the old editor made the operator type. It is now an
     * output: the record holds Tebuconazole→FRAC 3 and Azoxystrobin→FRAC 11 as
     * separate facts, and nothing parses this back.
     */
    fun groupSummary(draft: ChemicalManualDraft): String {
        val groups = draft.actives.mapNotNull { activityGroup(it) }
            .canonicalised()
            .filter { it.isResistanceRelevant }
        if (groups.isEmpty()) return ""
        val schemes = groups.map { it.scheme }.distinct()
        // Mixed schemes must stay qualified: "FRAC 3 + IRAC 3" collapsed to
        // "3 + 3" would read as one chemistry used twice.
        if (schemes.size != 1) return groups.joinToString(" + ") { it.displayLabel }
        return "${schemes.first().label} ${groups.joinToString(" + ") { it.code }}"
    }

    /** `"Tebuconazole + Azoxystrobin"` — names only, for compact rows. */
    fun activesSummary(draft: ChemicalManualDraft): String =
        draft.actives.map { it.name.trim() }.filter { it.isNotEmpty() }.joinToString(" + ")

    // ---- Validation ----

    /**
     * Problems that would make the draft unstorable or misleading.
     *
     * Deliberately short. The editor's job is to record what the label says,
     * including the parts the operator does not know yet — an incomplete product
     * is Unverified, which is an honest state, not an error. Only genuine
     * contradictions and unusable values are reported.
     */
    fun problems(draft: ChemicalManualDraft): List<String> {
        val out = mutableListOf<String>()
        if (draft.productName.isBlank()) out.add("Product name is required.")

        val seen = mutableSetOf<String>()
        for (active in draft.actives) {
            val name = active.name.trim()
            if (name.isEmpty()) continue
            if (!seen.add(name.lowercase())) {
                out.add("$name is listed twice. Each active ingredient should appear once.")
            }
            if (active.concentrationText.isNotBlank() &&
                parseDouble(active.concentrationText) == null
            ) {
                out.add("$name: concentration is not a number.")
            }
            val code = ChemicalActivityGroup.normaliseCode(active.groupCode)
            if (code.isNotEmpty() && active.scheme == null) {
                out.add("$name: choose which resistance group system $code belongs to.")
            }
        }

        for (rate in draft.productRates + draft.uses.flatMap { it.rates }) {
            rateProblem(rate)?.let { out.add(it) }
        }
        return out
    }

    private fun rateProblem(rate: ChemicalManualRateDraft): String? = when (rate.basis) {
        ChemicalLabelRateBasis.PER_HECTARE, ChemicalLabelRateBasis.PER_100_LITRES -> {
            val text = rate.valueText.trim()
            if (text.isNotEmpty() && parseDouble(text) == null) {
                "Label rate \"$text\" is not a number."
            } else {
                null
            }
        }

        ChemicalLabelRateBasis.RANGE_PER_HECTARE,
        ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
        -> {
            val low = parseDouble(rate.minText)
            val high = parseDouble(rate.maxText)
            if (low != null && high != null && low > high) {
                "Label rate range ${formatChemicalNumber(low)}–" +
                    "${formatChemicalNumber(high)} is back to front."
            } else {
                null
            }
        }

        ChemicalLabelRateBasis.OTHER -> null
    }

    // ---- Element mapping ----

    private fun activeIngredient(
        draft: ChemicalManualActiveDraft,
    ): ChemicalActiveIngredient? {
        val name = draft.name.trim()
        val group = activityGroup(draft)
        // A row the operator started and abandoned carries no information.
        if (name.isEmpty() && group == null) return null
        val concentration = parseDouble(draft.concentrationText)
        return ChemicalActiveIngredient(
            name = name,
            concentration = concentration,
            // A bare number with no unit is not a concentration, and guessing
            // g/L would silently mis-state a solid product's loading.
            concentrationUnit = if (concentration == null) null else draft.concentrationUnit,
            activityGroup = group,
            // Left unset on purpose so [ChemicalEditReconciler] assigns provenance
            // per value: MANUAL_ENTRY for anything new or changed, and the prior
            // citation preserved for a value that did not move.
            //
            // Stamping MANUAL_ENTRY here instead would mean merely OPENING this
            // editor and pressing Done stripped a verified product's authoritative
            // classification — a silent downgrade for doing nothing. A brand-new
            // manual product has no prior anything, so every active still lands on
            // MANUAL_ENTRY, which is what keeps it Unverified.
            groupSource = null,
            identitySource = null,
        )
    }

    private fun activityGroup(draft: ChemicalManualActiveDraft): ChemicalActivityGroup? {
        val scheme = draft.scheme ?: return null
        val code = ChemicalActivityGroup.normaliseCode(draft.groupCode)
        // "Not applicable" is an assertion in its own right — the product has no
        // resistance classification — so it is recorded without a code.
        if (scheme == ChemicalActivityGroupScheme.NOT_APPLICABLE) {
            return ChemicalActivityGroup.of(ChemicalActivityGroupScheme.NOT_APPLICABLE, "")
        }
        if (code.isEmpty()) return null
        return ChemicalActivityGroup.of(scheme, code)
    }

    private fun labelRates(drafts: List<ChemicalManualRateDraft>): List<ChemicalLabelRate> =
        drafts.mapNotNull { labelRate(it) }

    private fun labelRate(draft: ChemicalManualRateDraft): ChemicalLabelRate? {
        val unit = draft.unit.trim()
        val label = draft.label.trim()
        val raw = draft.rawText.trim()
        return when (draft.basis) {
            ChemicalLabelRateBasis.PER_HECTARE, ChemicalLabelRateBasis.PER_100_LITRES -> {
                val value = parseDouble(draft.valueText) ?: return null
                ChemicalLabelRate(label = label, basis = draft.basis, value = value, unit = unit)
            }

            ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            -> {
                val low = parseDouble(draft.minText) ?: return null
                val high = parseDouble(draft.maxText) ?: return null
                // Stored low-to-high whichever way round it was typed, so
                // `proposedValue` cannot hand a calculation the top of the band.
                ChemicalLabelRate(
                    label = label,
                    basis = draft.basis,
                    minValue = minOf(low, high),
                    maxValue = maxOf(low, high),
                    unit = unit,
                )
            }

            ChemicalLabelRateBasis.OTHER -> {
                if (raw.isEmpty()) return null
                ChemicalLabelRate(
                    label = label,
                    basis = ChemicalLabelRateBasis.OTHER,
                    unit = unit,
                    rawText = raw,
                )
            }
        }
    }

    private fun registeredUse(draft: ChemicalManualUseDraft): ChemicalRegisteredUse? {
        val crop = draft.crop.trim()
        val target = draft.targetRaw.trim()
        // Both blank would be indistinguishable from the product-rate carrier.
        if (crop.isEmpty() && target.isEmpty()) return null
        return ChemicalRegisteredUse(
            crop = crop,
            targetRaw = target,
            // `target` is left to the model's own conservative mapping. Forcing
            // VineTrack's six targets onto label wording they do not match would
            // tell the Resistance Engine the wrong disease was managed.
            target = ChemicalRegisteredUse.mapTarget(target),
            rates = labelRates(draft.rates),
            withholdingPeriodDays = parseInt(draft.withholdingPeriodDaysText),
            reEntryPeriodHours = parseInt(draft.reEntryPeriodHoursText),
            restrictions = draft.restrictions.trim().takeIf { it.isNotEmpty() },
        )
    }

    private fun rateDraft(rate: ChemicalLabelRate): ChemicalManualRateDraft =
        ChemicalManualRateDraft(
            label = rate.label,
            basis = rate.basis,
            valueText = rate.value?.let { formatChemicalNumber(it) } ?: "",
            minText = rate.minValue?.let { formatChemicalNumber(it) } ?: "",
            maxText = rate.maxValue?.let { formatChemicalNumber(it) } ?: "",
            unit = rate.unit,
            rawText = rate.rawText ?: "",
        )

    private fun useDraft(use: ChemicalRegisteredUse): ChemicalManualUseDraft =
        ChemicalManualUseDraft(
            crop = use.crop,
            targetRaw = use.targetRaw,
            rates = use.rates.map { rateDraft(it) },
            withholdingPeriodDaysText = use.withholdingPeriodDays?.toString() ?: "",
            reEntryPeriodHoursText = use.reEntryPeriodHours?.toString() ?: "",
            restrictions = use.restrictions ?: "",
        )

    // ---- Parsing ----

    /**
     * Accepts both decimal separators, because a comma is what half the world
     * types and rejecting it silently would drop the value.
     */
    fun parseDouble(raw: String): Double? =
        raw.trim().replace(',', '.').takeIf { it.isNotEmpty() }?.toDoubleOrNull()

    fun parseInt(raw: String): Int? {
        val trimmed = raw.trim().takeIf { it.isNotEmpty() } ?: return null
        return trimmed.toIntOrNull() ?: parseDouble(trimmed)?.toInt()
    }
}

/**
 * Uses that state a real crop+target registration, excluding the carrier that
 * only holds product-level label rates.
 */
fun List<ChemicalRegisteredUse>.statedUses(): List<ChemicalRegisteredUse> =
    filterNot { ChemicalManualEntry.isProductRateCarrier(it) }

/** Label rates recorded against the product rather than a specific use. */
fun List<ChemicalRegisteredUse>.productLevelRates(): List<ChemicalLabelRate> =
    filter { ChemicalManualEntry.isProductRateCarrier(it) }.flatMap { it.rates }
