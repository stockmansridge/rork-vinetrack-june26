package com.rork.vinetrack.data.chemical

import java.util.Locale

/**
 * The two bases a grower can actually hold a default rate on.
 *
 * Deliberately NOT [ChemicalLabelRateBasis]: that enum distinguishes a single
 * value from a range, which is a fact about the LABEL's wording. A default is
 * a decision about how this vineyard doses, and `2 L/100 L` and
 * `1.5–2 L/100 L` are two answers to the same question. `basis: OTHER` has no
 * case here at all — verbatim wording is a faithful record and not a rate a
 * calculation may run on, so it can never become a default.
 *
 * Mirrors the iOS `ChemicalDefaultRateBasis`.
 */
enum class ChemicalDefaultRateBasis(val raw: String, val label: String) {
    PER_100_LITRES("per_100_litres", "Per 100 L"),
    PER_HECTARE("per_hectare", "Per hectare"),
    ;

    /**
     * The wording shown when the label registers no rate on this basis.
     *
     * Exact, and deliberately about THIS LABEL rather than about VineTrack.
     * "No rate found" reads as a lookup failure the operator might retry; the
     * truth is that the document states none, and inventing one by converting
     * from the other basis would need a carrier volume the label never gave.
     */
    val noRegisteredRateStatement: String
        get() = when (this) {
            PER_100_LITRES -> "No registered per-100 L rate on this label"
            PER_HECTARE -> "No registered per-hectare rate on this label"
        }

    companion object {
        /**
         * The decision basis a label basis belongs to, or null when it is not
         * a rate a default can be held on.
         */
        fun of(basis: ChemicalLabelRateBasis): ChemicalDefaultRateBasis? = when (basis) {
            ChemicalLabelRateBasis.PER_100_LITRES,
            ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            -> PER_100_LITRES

            ChemicalLabelRateBasis.PER_HECTARE,
            ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            -> PER_HECTARE

            ChemicalLabelRateBasis.OTHER -> null
        }
    }
}

/**
 * One use+rate pairing that a default option was built from.
 *
 * Kept so an option can always say WHICH registered uses stand behind it.
 * Collapsing several conditions into one option is only defensible while the
 * conditions themselves remain inspectable.
 */
data class ChemicalDefaultRateCondition(
    /** The crop the use registers, e.g. `"GRAPEVINES"`. */
    val crop: String,
    /** The target as the label words it, e.g. `"Grapevine scale"`. */
    val targetRaw: String,
    /**
     * The condition the label attaches to this rate — on an Australian label
     * this is usually the STATE column, e.g. `"NSW, Vic, SA"`.
     */
    val conditionText: String,
    /** The verbatim label wording the rate was read from, where supplied. */
    val rawText: String?,
    /** Jurisdictions named by the condition. EMPTY means unrestricted. */
    val jurisdictions: List<ChemicalRateJurisdiction>,
) {
    val id: String
        get() = listOf(crop, targetRaw, conditionText, rawText ?: "-").joinToString("|")

    /** A single readable line: `"Grapevine scale — NSW, Vic, Qld, SA, WA"`. */
    val summary: String
        get() {
            val target = targetRaw.trim()
            val condition = conditionText.trim()
            return when {
                target.isNotEmpty() && condition.isNotEmpty() -> "$target — $condition"
                target.isNotEmpty() -> target
                condition.isNotEmpty() -> condition
                else -> crop.ifEmpty { "Registered use" }
            }
        }

    /**
     * Whether this condition permits use in the given jurisdiction.
     *
     * A condition naming no state permits every state: it is not restricted,
     * and treating silence as exclusion would hide most of a label.
     */
    fun appliesIn(jurisdiction: ChemicalRateJurisdiction?): Boolean {
        if (jurisdictions.isEmpty()) return true
        if (jurisdiction == null) return true
        return jurisdictions.contains(jurisdiction)
    }
}

/**
 * One rate the operator may adopt as their default.
 *
 * # What is and is not merged
 *
 * Two registered rows quoting the SAME number on the SAME basis in the SAME
 * unit are one choice, however many conditions produced them. What is NEVER
 * merged is two DIFFERENT numbers: `2 L/100 L` and `3 L/100 L` stay two
 * options, and they are not flattened into `2–3 L/100 L` — a range is
 * something a label states, not something a client derives.
 */
data class ChemicalDefaultRateOption(
    /**
     * Content-addressed: basis, unit and the value(s). Deliberately excludes
     * the condition, because the condition is what this type merges on.
     */
    val id: String,
    /**
     * The rate itself, exactly as the label states it — value OR an ordered
     * min/max pair, never both, never converted.
     */
    val rate: ChemicalLabelRate,
    /** Every registered use+condition that states this rate. */
    val conditions: List<ChemicalDefaultRateCondition>,
) {
    /** `"3 L/100 L"`, or `"100–200 mL/100 L"` for a true label range. */
    val displayRate: String get() = rate.displayRate

    /** True when the label itself states this rate as a band. */
    val isLabelRange: Boolean get() = rate.minValue != null && rate.maxValue != null

    /**
     * The inclusive bounds this option authorises, in the rate's own unit.
     *
     * A single-value rate authorises exactly one number, so its bounds are
     * that number twice. A label range authorises everything between its
     * printed ends. Null when the rate states no usable number at all.
     */
    val authorisedBounds: Pair<Double, Double>?
        get() {
            val min = rate.minValue
            val max = rate.maxValue
            if (min != null && max != null) {
                return if (min <= max) min to max else max to min
            }
            rate.value?.let { return it to it }
            return null
        }

    /**
     * Whether [value] is a dose this registered rate actually authorises.
     *
     * Inclusive of both ends: a label printing `100–200 g/100 L` registers
     * 100 and 200 as much as it registers 150. The comparison carries a small
     * tolerance so a number the operator typed back in — and that made a
     * round trip through text — still matches its own bound.
     */
    fun authorises(value: Double): Boolean {
        val bounds = authorisedBounds ?: return false
        val tolerance = 0.000_001
        return value >= bounds.first - tolerance && value <= bounds.second + tolerance
    }

    /**
     * The dose this option starts from when the operator has named none.
     *
     * A range starts at its LOWER bound: defaulting to the top of a band
     * would over-apply every product whose operator never opened the row.
     */
    val startingValue: Double? get() = rate.value ?: rate.minValue

    /** Every jurisdiction any of this option's conditions names. */
    val jurisdictions: List<ChemicalRateJurisdiction>
        get() {
            val seen = mutableSetOf<ChemicalRateJurisdiction>()
            for (condition in conditions) seen.addAll(condition.jurisdictions)
            return ChemicalRateJurisdiction.entries.filter(seen::contains)
        }

    /** True when no condition restricts this rate to a state. */
    val isUnrestricted: Boolean
        get() = conditions.isEmpty() || conditions.any { it.jurisdictions.isEmpty() }

    /** Whether this option is registered for use in the given jurisdiction. */
    fun appliesIn(jurisdiction: ChemicalRateJurisdiction?): Boolean {
        if (jurisdiction == null) return true
        if (conditions.isEmpty()) return true
        return conditions.any { it.appliesIn(jurisdiction) }
    }
}

/** Why an option is being recommended — or why none is. */
sealed interface ChemicalDefaultRateRecommendation {
    /** The label registers no rate at all on this basis. */
    data object NoRegisteredRate : ChemicalDefaultRateRecommendation

    /** Exactly one distinct rate applies in the vineyard's own jurisdiction. */
    data class Jurisdiction(
        val jurisdiction: ChemicalRateJurisdiction,
    ) : ChemicalDefaultRateRecommendation

    /** Exactly one distinct rate exists on this basis, full stop. */
    data object OnlyRegisteredRate : ChemicalDefaultRateRecommendation

    /** Several apply and only the operator can choose between them. */
    data object OperatorMustChoose : ChemicalDefaultRateRecommendation

    /**
     * The badge shown beside the recommended option, or null when there is
     * nothing to recommend.
     */
    val badge: String?
        get() = when (this) {
            is Jurisdiction -> "Recommended for ${jurisdiction.displayName}"
            is OnlyRegisteredRate -> "Recommended"
            is NoRegisteredRate, is OperatorMustChoose -> null
        }
}

/** The decision to be taken for ONE basis. */
data class ChemicalDefaultRateGroup(
    val basis: ChemicalDefaultRateBasis,
    /** Every distinct registered rate on this basis, in label order. */
    val options: List<ChemicalDefaultRateOption>,
    val recommendation: ChemicalDefaultRateRecommendation,
    /** The option the recommendation points at, when it points at one. */
    val recommendedOptionId: String?,
) {
    /** True when the operator must pick before this basis has a default. */
    val requiresChoice: Boolean
        get() = recommendation is ChemicalDefaultRateRecommendation.OperatorMustChoose

    /** True when the label states nothing on this basis. */
    val isEmpty: Boolean get() = options.isEmpty()

    /** The wording to show when there is nothing to choose from. */
    val emptyStatement: String get() = basis.noRegisteredRateStatement

    val recommendedOption: ChemicalDefaultRateOption?
        get() = recommendedOptionId?.let { id -> options.firstOrNull { it.id == id } }
}

/** The whole default-rate decision for a product, per basis. */
data class ChemicalDefaultRatePlan(
    val per100Litres: ChemicalDefaultRateGroup,
    val perHectare: ChemicalDefaultRateGroup,
    /** The jurisdiction the recommendation was computed against, if any. */
    val jurisdiction: ChemicalRateJurisdiction?,
) {
    val groups: List<ChemicalDefaultRateGroup> get() = listOf(per100Litres, perHectare)

    fun group(basis: ChemicalDefaultRateBasis): ChemicalDefaultRateGroup = when (basis) {
        ChemicalDefaultRateBasis.PER_100_LITRES -> per100Litres
        ChemicalDefaultRateBasis.PER_HECTARE -> perHectare
    }

    /** True when at least one basis still needs the operator to decide. */
    val requiresChoice: Boolean get() = groups.any { it.requiresChoice }
}

/**
 * Builds the default-rate decision from authoritative grapevine rates.
 *
 * # The rule
 *
 * ```text
 * 1. vineyard jurisdiction known AND exactly one distinct rate applies there
 *        → recommend it, badged with the state
 * 2. otherwise exactly one distinct grapevine rate on this basis
 *        → recommend it
 * 3. otherwise
 *        → no automatic default; the operator chooses
 * ```
 *
 * # What it will never do
 *
 * * Convert between bases. A `/100 L`-only label has no hectare rate, and
 *   the hectare group says exactly that.
 * * Split a label's own range into two defaults. `100–200 mL/100 L` is ONE
 *   registered rate with both bounds preserved.
 * * Recommend a rate outside the vineyard's jurisdiction, at any step.
 * * Read a non-grapevine rate. Other crops are retained on the record and are
 *   never candidates for a vineyard's default.
 *
 * Mirrors the iOS `ChemicalDefaultRate` exactly.
 */
object ChemicalDefaultRate {

    /**
     * Build the plan from GRAPEVINE uses only.
     *
     * Callers must pass the grapevine partition; passing the whole label would
     * offer a pome-fruit rate as a vineyard default. A null [jurisdiction]
     * skips step 1 — which is a weaker answer, never a wrong one.
     */
    fun plan(
        grapevineUses: List<ChemicalRegisteredUse>,
        jurisdiction: ChemicalRateJurisdiction? = null,
    ): ChemicalDefaultRatePlan = ChemicalDefaultRatePlan(
        per100Litres = group(ChemicalDefaultRateBasis.PER_100_LITRES, grapevineUses, jurisdiction),
        perHectare = group(ChemicalDefaultRateBasis.PER_HECTARE, grapevineUses, jurisdiction),
        jurisdiction = jurisdiction,
    )

    /** Every distinct rate on one basis, with its conditions attached. */
    fun options(
        basis: ChemicalDefaultRateBasis,
        grapevineUses: List<ChemicalRegisteredUse>,
    ): List<ChemicalDefaultRateOption> {
        // Insertion-ordered accumulation: the label's own order is the order a
        // grower reads, and re-sorting by value would silently re-rank the
        // register's presentation.
        val order = mutableListOf<String>()
        val rates = mutableMapOf<String, ChemicalLabelRate>()
        val conditions = mutableMapOf<String, MutableList<ChemicalDefaultRateCondition>>()

        for (use in grapevineUses) {
            for (rate in use.rates) {
                if (ChemicalDefaultRateBasis.of(rate.basis) != basis) continue
                // Only a rate a calculation can run on may become a default.
                if (!ChemicalSaveContract.isUsable(rate)) continue

                val key = distinctnessKey(rate)
                if (rates[key] == null) {
                    order.add(key)
                    rates[key] = rate
                }
                val conditionText = conditionText(rate)
                val condition = ChemicalDefaultRateCondition(
                    crop = use.crop,
                    targetRaw = use.targetRaw,
                    conditionText = conditionText,
                    rawText = rate.rawText,
                    jurisdictions = ChemicalRateJurisdiction.mentioned(
                        listOf(conditionText, rate.rawText.orEmpty()).joinToString(" "),
                    ),
                )
                val bucket = conditions.getOrPut(key) { mutableListOf() }
                if (!bucket.contains(condition)) bucket.add(condition)
            }
        }

        return order.mapNotNull { key ->
            val rate = rates[key] ?: return@mapNotNull null
            ChemicalDefaultRateOption(
                id = key,
                rate = rate,
                conditions = conditions[key].orEmpty(),
            )
        }
    }

    private fun group(
        basis: ChemicalDefaultRateBasis,
        grapevineUses: List<ChemicalRegisteredUse>,
        jurisdiction: ChemicalRateJurisdiction?,
    ): ChemicalDefaultRateGroup {
        val all = options(basis, grapevineUses)

        if (all.isEmpty()) {
            return ChemicalDefaultRateGroup(
                basis = basis,
                options = emptyList(),
                recommendation = ChemicalDefaultRateRecommendation.NoRegisteredRate,
                recommendedOptionId = null,
            )
        }

        // Step 1 — the vineyard's own jurisdiction narrows the field.
        if (jurisdiction != null) {
            val applicable = all.filter { it.appliesIn(jurisdiction) }
            if (applicable.size == 1) {
                return ChemicalDefaultRateGroup(
                    basis = basis,
                    options = all,
                    recommendation = ChemicalDefaultRateRecommendation.Jurisdiction(jurisdiction),
                    recommendedOptionId = applicable.first().id,
                )
            }
            // Several apply here, or none does. Either way this vineyard has
            // no single answer, and step 2 must not resurrect one from rates
            // that are registered for somewhere else.
            return ChemicalDefaultRateGroup(
                basis = basis,
                options = all,
                recommendation = ChemicalDefaultRateRecommendation.OperatorMustChoose,
                recommendedOptionId = null,
            )
        }

        // Step 2 — one distinct rate on this basis, jurisdiction unknown.
        if (all.size == 1) {
            return ChemicalDefaultRateGroup(
                basis = basis,
                options = all,
                recommendation = ChemicalDefaultRateRecommendation.OnlyRegisteredRate,
                recommendedOptionId = all.first().id,
            )
        }

        // Step 3 — the operator decides.
        return ChemicalDefaultRateGroup(
            basis = basis,
            options = all,
            recommendation = ChemicalDefaultRateRecommendation.OperatorMustChoose,
            recommendedOptionId = null,
        )
    }

    /**
     * What makes two registered rates the SAME choice.
     *
     * Basis, unit and the number(s). Never the condition — merging on the
     * condition is this type's whole purpose — and never the use, because a
     * grower pouring `3 L/100 L` pours the same thing whichever registered
     * pest they are treating.
     */
    fun distinctnessKey(rate: ChemicalLabelRate): String = listOf(
        ChemicalDefaultRateBasis.of(rate.basis)?.raw ?: "other",
        rate.unit.lowercase(),
        rate.value?.let(::number) ?: "-",
        rate.minValue?.let(::number) ?: "-",
        rate.maxValue?.let(::number) ?: "-",
    ).joinToString("|")

    /**
     * The condition wording for a rate: the label's own condition, falling
     * back to the verbatim row when the parser bound no separate condition.
     */
    fun conditionText(rate: ChemicalLabelRate): String {
        val label = rate.label.trim()
        if (label.isNotEmpty()) return label
        return rate.rawText.orEmpty().trim()
    }

    /**
     * Six-significant-digit key component, trailing zeros trimmed so the same
     * number always produces the same key (mirrors iOS `%.6g`).
     */
    private fun number(value: Double): String {
        val formatted = String.format(Locale.ROOT, "%.6g", value)
        return if (formatted.contains('.') && !formatted.contains('e') && !formatted.contains('E')) {
            formatted.trimEnd('0').trimEnd('.')
        } else {
            formatted
        }
    }
}

/**
 * The operator's in-flight default-rate decision, mirroring the fields the
 * iOS `ChemicalReviewSession` holds (`selectedDefaultRateIds` +
 * `defaultRateValues`).
 *
 * The registered label rates are authoritative and are never edited, narrowed
 * or deleted by anything here: this only records WHICH registered option the
 * vineyard doses by and, for a label band, the exact authorised figure.
 */
data class ChemicalDefaultRateSelection(
    val plan: ChemicalDefaultRatePlan,
    /** Which registered option this vineyard doses by, per basis. */
    val selectedIds: Map<ChemicalDefaultRateBasis, String> = emptyMap(),
    /**
     * The exact dose, in the RATE's own unit, only when the option is a label
     * band and the figure is authorised. Never written into the label rates.
     */
    val values: Map<ChemicalDefaultRateBasis, Double> = emptyMap(),
) {
    /**
     * The default in force for a basis: the operator's choice if they made
     * one, otherwise the recommendation, otherwise nothing.
     *
     * Returning null is a real answer: when several conditional rates apply
     * and nobody has chosen, there IS no default, and manufacturing one would
     * dose off a condition never checked.
     */
    fun resolvedOption(basis: ChemicalDefaultRateBasis): ChemicalDefaultRateOption? {
        val group = plan.group(basis)
        selectedIds[basis]?.let { id ->
            group.options.firstOrNull { it.id == id }?.let { return it }
        }
        return group.recommendedOption
    }

    /**
     * The exact dose in force for a basis, in the RATE's own unit: the
     * operator's figure when they named one, otherwise the bottom of the band
     * — never the top, and never a number outside it.
     */
    fun resolvedValue(basis: ChemicalDefaultRateBasis): Double? {
        val option = resolvedOption(basis) ?: return null
        values[basis]?.takeIf(option::authorises)?.let { return it }
        return option.startingValue
    }

    /** Adopt a default rate for a basis. Never touches the registered rates. */
    fun selecting(
        option: ChemicalDefaultRateOption,
        basis: ChemicalDefaultRateBasis,
    ): ChemicalDefaultRateSelection = copy(
        selectedIds = selectedIds + (basis to option.id),
        // Switching to a different registered rate retires any exact dose
        // taken from the previous one: `150` chosen inside `100–200` is not a
        // dose the option beside it authorises.
        values = values - basis,
    )

    /**
     * Set this vineyard's exact dose inside the registered band.
     *
     * Returns null — and the caller keeps the old state — when the value is
     * not one the selected registered rate authorises. The label is the
     * authority on what may be applied; this only records which authorised
     * number gets poured.
     */
    fun settingValue(
        value: Double,
        basis: ChemicalDefaultRateBasis,
    ): ChemicalDefaultRateSelection? {
        val option = resolvedOption(basis) ?: return null
        if (!option.authorises(value)) return null
        // An option in force only by RECOMMENDATION becomes an explicit choice
        // the moment a dose is named against it.
        return copy(
            selectedIds = selectedIds + (basis to option.id),
            values = values + (basis to value),
        )
    }

    /** Clear this vineyard's exact dose, returning to the bottom of the band. */
    fun clearingValue(basis: ChemicalDefaultRateBasis): ChemicalDefaultRateSelection =
        copy(values = values - basis)

    /** Bases the operator still has to answer before a default exists. */
    val basesAwaitingChoice: List<ChemicalDefaultRateBasis>
        get() = ChemicalDefaultRateBasis.entries.filter { basis ->
            plan.group(basis).requiresChoice && selectedIds[basis] == null
        }

    // ---- Explicit confirmation (item 4) ----

    /**
     * Whether this basis needs a DELIBERATE choice before the record is saved.
     *
     * True whenever the label registers more than one distinct grapevine rate
     * on the basis. A recommendation is a suggestion, not a decision: with two
     * or more numbers on the label, treating the recommended one as the
     * operator's answer means a vineyard doses off a rate nobody ever read.
     *
     * A single registered rate does NOT require a tap — item 4 permits it to be
     * selected automatically — but it must still be visible before save, which
     * is the review screen's job rather than this predicate's.
     */
    fun requiresExplicitConfirmation(basis: ChemicalDefaultRateBasis): Boolean =
        plan.group(basis).options.size > 1

    /** Whether the operator has actually chosen for this basis themselves. */
    fun isExplicitlyConfirmed(basis: ChemicalDefaultRateBasis): Boolean =
        selectedIds[basis] != null

    /**
     * Bases that register several rates and have no operator decision yet.
     *
     * Empty means every multi-rate basis has been answered. A basis the label
     * states nothing on is never listed — there is nothing to confirm, and
     * demanding a choice between no options would be unanswerable.
     */
    val basesAwaitingConfirmation: List<ChemicalDefaultRateBasis>
        get() = ChemicalDefaultRateBasis.entries.filter { basis ->
            requiresExplicitConfirmation(basis) && !isExplicitlyConfirmed(basis)
        }

    /**
     * True when every basis that needs a deliberate choice has had one.
     *
     * Deliberately true for a product the label registers NO grapevine rate
     * on: that record is incomplete for other reasons the save contract
     * already states, and inventing a default-rate objection on top would tell
     * the operator to choose something that does not exist.
     */
    val isConfirmed: Boolean get() = basesAwaitingConfirmation.isEmpty()

    /** The rate in force per basis, for a review screen to show before save. */
    val resolvedSummary: List<Pair<ChemicalDefaultRateBasis, ChemicalDefaultRateOption?>>
        get() = ChemicalDefaultRateBasis.entries.map { it to resolvedOption(it) }
}

/**
 * Pinned operator-facing copy for the Default Rates section — word-for-word
 * the iOS `SprayPresetsView` footer, so a parity test can prove both
 * platforms say the same thing.
 */
object ChemicalDefaultRateCopy {
    const val FOOTER_BASE: String =
        "The rate VineTrack will start a spray calculation from. Chosen from the " +
            "registered grapevine rates above — the two bases are decided separately " +
            "and never converted into one another."

    /**
     * Appended when the label conditions rates by state and no vineyard
     * state/territory exists anywhere in the current backend contract.
     * Honest about WHY it is asking: with no state on record VineTrack
     * cannot narrow a state-conditioned label, and it will not guess — the
     * exact behaviour of iOS, which also has no state to read.
     */
    const val NO_STATE_FOOTNOTE: String =
        " This label conditions rates by state, and VineTrack has no state on " +
            "record for this vineyard, so it cannot narrow them for you."

    /** The section footer for a plan: the base line, plus the no-state honesty when it applies. */
    fun footer(plan: ChemicalDefaultRatePlan): String =
        if (plan.jurisdiction == null && plan.requiresChoice) FOOTER_BASE + NO_STATE_FOOTNOTE else FOOTER_BASE
}
