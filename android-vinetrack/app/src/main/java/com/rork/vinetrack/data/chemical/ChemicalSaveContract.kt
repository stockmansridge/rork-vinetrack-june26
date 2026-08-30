package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical

/**
 * The resistance classification state of an active, or of a product.
 *
 * Three conditions that a blank cannot tell apart, and that the Resistance
 * Planner must never conflate:
 *
 * ```text
 * CLASSIFIED      FRAC 3 / IRAC 4A / HRAC G — a code the Planner can rotate on
 * NOT_APPLICABLE  the product HAS no resistance group by design
 * UNRESOLVED      nobody has established it yet, or the lookup failed
 * ```
 *
 * The wire values match `sql/210`'s CHECK constraint, and the iOS
 * `ChemicalResistanceState`, exactly.
 */
enum class ChemicalResistanceState(val raw: String, val label: String) {
    CLASSIFIED("classified", "Classified"),
    NOT_APPLICABLE("not_applicable", "Not applicable"),
    UNRESOLVED("unresolved", "Not established"),
    ;

    companion object {
        /**
         * The state of ONE active ingredient.
         *
         * A missing group is [UNRESOLVED], never [NOT_APPLICABLE]. Absence is
         * not an assertion: an unclassified fungicide silently marked
         * group-free would be excluded from every resistance warning it should
         * raise. Only an explicit `NOT_APPLICABLE` scheme — something somebody
         * or an authoritative pass actually stated — produces that answer.
         */
        fun of(active: ChemicalActiveIngredient): ChemicalResistanceState {
            val group = active.activityGroup ?: return UNRESOLVED
            if (group.scheme == ChemicalActivityGroupScheme.NOT_APPLICABLE) return NOT_APPLICABLE
            // A scheme with no code is half a record, not knowledge.
            return if (group.code.isEmpty()) UNRESOLVED else CLASSIFIED
        }

        /**
         * The product-level rollup, mirroring the `sql/210` backfill exactly.
         *
         * * No actives at all → [UNRESOLVED]. Every pre-sql/194 record is here.
         * * Any active still unknown → [UNRESOLVED]. A half-classified mixture
         *   must not report as classified: that would tell the Planner it knows
         *   the whole chemistry when it knows half of it.
         * * Every active explicitly group-free → [NOT_APPLICABLE].
         * * Otherwise → [CLASSIFIED]. A classified fungicide plus an explicitly
         *   group-free wetter is classified; the wetter has nothing to add.
         */
        fun rollup(actives: List<ChemicalActiveIngredient>): ChemicalResistanceState {
            if (actives.isEmpty()) return UNRESOLVED
            val states = actives.map { of(it) }
            if (states.contains(UNRESOLVED)) return UNRESOLVED
            if (states.all { it == NOT_APPLICABLE }) return NOT_APPLICABLE
            return CLASSIFIED
        }
    }
}

/** Every way a chemical can fail the mandatory save contract. */
enum class ChemicalSaveViolationCode(val raw: String) {
    PRODUCT_NAME_MISSING("product_name_missing"),
    PRODUCT_CATEGORY_MISSING("product_category_missing"),
    ACTIVE_INGREDIENT_NAME_MISSING("active_ingredient_name_missing"),
    GRAPEVINE_USE_MISSING("grapevine_use_missing"),
    USABLE_RATE_MISSING("usable_rate_missing"),
    RATE_UNIT_MISSING("rate_unit_missing"),
    RATE_BASIS_UNRECOGNISED("rate_basis_unrecognised"),
    RATE_VALUE_INVALID("rate_value_invalid"),
    RATE_RANGE_INVERTED("rate_range_inverted"),
    RESISTANCE_STATE_MISSING("resistance_state_missing"),
    REGISTRATION_IDENTITY_MISSING("registration_identity_missing"),
    OFFICIAL_LABEL_MISSING("official_label_missing"),
}

/** One unmet requirement, phrased as the next action. */
data class ChemicalSaveViolation(
    val code: ChemicalSaveViolationCode,
    /** Operator-facing sentence. Says what to DO, not what is wrong. */
    val message: String,
    /** Which part of the form the operator must go to. */
    val field: String,
) {
    // `this.field` is deliberate: inside a property accessor a bare `field` is
    // the backing-field keyword, not this class's `field` property.
    val id: String get() = "${code.raw}|${this.field}"
}

/** How complete the record has to be. */
enum class ChemicalSaveIntent(val raw: String) {
    /** Going into the Chemical Store for use in spray work. */
    SPRAY_READY("spray_ready"),

    /** Additionally claiming registered identity. */
    VERIFIED("verified"),
}

data class ChemicalSaveEvaluation(
    val violations: List<ChemicalSaveViolation>,
    /**
     * The state that will be persisted to `resistance_classification_state`
     * once sql/210 lands. Derived here so the value the form shows and the
     * value the record stores can never disagree.
     */
    val resistanceState: ChemicalResistanceState,
    /** True when at least one grapevine use carries a calculable rate. */
    val hasUsableViticulturalRate: Boolean,
    /**
     * True when every usable grapevine rate has an unproven condition, so a
     * calculation must ask the operator which one applies.
     */
    val requiresRateConditionChoice: Boolean,
) {
    val isSatisfied: Boolean get() = violations.isEmpty()

    /** The first thing the operator should fix, for a one-line summary. */
    val primaryMessage: String? get() = violations.firstOrNull()?.message
}

/**
 * The mandatory contract for saving a chemical into the Chemical Store.
 *
 * # Why this is not a button rule
 *
 * "Save is disabled" used to be `name.isNotEmpty()` on the Android form alone,
 * while iOS gated on the whole contract and the Portal had a third opinion. A
 * record one client refused another would happily write, and the store could
 * hold products that no spray calculation, compliance check or resistance
 * warning could use.
 *
 * The authoritative definition is the edge function's `save_contract.ts`. The
 * iOS `ChemicalSaveContract` is its mirror, and this is the same mirror for
 * Android — decision for decision, message for message, so the form can respond
 * as the operator types instead of waiting for a round trip. Any change must be
 * made in all three, and `ChemicalSaveContractTest` pins the shared cases
 * against the iOS `ChemicalSaveContractTests` fixtures.
 *
 * # What it deliberately does NOT require
 *
 * * **WHP / REI** — null when the label does not state them. Demanding a number
 *   the label never printed would manufacture regulatory information, which is
 *   the opposite of this feature's job.
 * * **Manufacturer URL** — supplementary, never a substitute for the regulator
 *   label, never mandatory.
 * * **A resistance CODE** — `NOT_APPLICABLE` and `UNRESOLVED` are both
 *   acceptable answers. Only silence is refused, because the Planner cannot
 *   tell a blank from "no concern".
 */
object ChemicalSaveContract {

    /** The bases a calculation can actually run on. */
    val calculableBases: Set<ChemicalLabelRateBasis> = setOf(
        ChemicalLabelRateBasis.PER_100_LITRES,
        ChemicalLabelRateBasis.PER_HECTARE,
        ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
        ChemicalLabelRateBasis.RANGE_PER_HECTARE,
    )

    /**
     * Whether a registered rate is one a calculation may use.
     *
     * Verbatim wording is deliberately excluded. "Apply as directed by an
     * agronomist" is worth storing and cannot produce a dose; treating
     * `rawText` as a rate is what let unusable chemicals into the store.
     */
    fun isUsable(rate: ChemicalLabelRate): Boolean {
        if (rate.basis !in calculableBases) return false
        if (rate.unit.trim().isEmpty()) return false
        return when (rate.basis) {
            ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            -> {
                val low = rate.minValue ?: return false
                val high = rate.maxValue ?: return false
                low.isFinite() && high.isFinite() && low > 0 && high > 0 && high >= low
            }

            ChemicalLabelRateBasis.PER_100_LITRES,
            ChemicalLabelRateBasis.PER_HECTARE,
            -> {
                val value = rate.value ?: return false
                value.isFinite() && value > 0
            }

            ChemicalLabelRateBasis.OTHER -> false
        }
    }

    /**
     * A rate a calculation may use WITHOUT asking the operator first.
     *
     * An ambiguous rate is usable but not automatic: the label states several
     * rates on one basis and nothing proved which condition governs which
     * number. Preserving them is right; silently applying the first is not.
     */
    fun isAutoApplicable(rate: ChemicalLabelRate): Boolean =
        isUsable(rate) && rate.conditionAmbiguous != true

    /**
     * Evaluate a record against the contract.
     *
     * Returns EVERY violation rather than the first, so the form can show the
     * whole remaining task instead of revealing it one field at a time.
     */
    fun evaluate(
        productName: String,
        productCategory: String,
        intelligence: ChemicalIntelligence,
        intent: ChemicalSaveIntent = ChemicalSaveIntent.SPRAY_READY,
        resistanceState: ChemicalResistanceState? = null,
    ): ChemicalSaveEvaluation {
        val violations = mutableListOf<ChemicalSaveViolation>()

        if (productName.trim().isEmpty()) {
            violations.add(
                ChemicalSaveViolation(
                    code = ChemicalSaveViolationCode.PRODUCT_NAME_MISSING,
                    message = "Enter the product name.",
                    field = "product_name",
                ),
            )
        }

        // The calculation model picks litres vs kilograms from the category, so
        // a product without one cannot be dosed.
        val category = productCategory.trim().ifEmpty { intelligence.productCategory.trim() }
        if (category.isEmpty()) {
            violations.add(
                ChemicalSaveViolation(
                    code = ChemicalSaveViolationCode.PRODUCT_CATEGORY_MISSING,
                    message = "Choose the product category so VineTrack knows how to measure it.",
                    field = "product_category",
                ),
            )
        }

        // "At least one active WHERE the product has one." A record with no
        // actives is a legitimate adjuvant or wetter, so absence is not a fault
        // — but a half-typed row with no name is.
        val actives = intelligence.activeIngredients
        if (actives.isNotEmpty() && actives.all { it.name.trim().isEmpty() }) {
            violations.add(
                ChemicalSaveViolation(
                    code = ChemicalSaveViolationCode.ACTIVE_INGREDIENT_NAME_MISSING,
                    message = "Enter the active ingredient name, or remove the empty row.",
                    field = "active_ingredients",
                ),
            )
        }

        // Product-level rate carriers are rate information, not use claims, so
        // the grapevine test reads STATED uses only.
        val viticultural = intelligence.registeredUses.statedUses().viticultural()
        if (viticultural.isEmpty()) {
            violations.add(
                ChemicalSaveViolation(
                    code = ChemicalSaveViolationCode.GRAPEVINE_USE_MISSING,
                    message = "Add the grapevine use this product is registered for.",
                    field = "registered_uses",
                ),
            )
        }

        val viticulturalRates = viticultural.flatMap { it.rates }
        val usable = viticulturalRates.filter { isUsable(it) }

        if (viticultural.isNotEmpty() && usable.isEmpty()) {
            // Research identified the product and the grapevine use but produced
            // no rate. This must not save as though ready.
            violations.add(
                ChemicalSaveViolation(
                    code = ChemicalSaveViolationCode.USABLE_RATE_MISSING,
                    message = "Rate not found — enter the rate from the label before saving.",
                    field = "rates",
                ),
            )
        }

        violations.addAll(rateViolations(viticulturalRates))

        // The shared contract also refuses a BLANK resistance state, because the
        // Planner cannot tell a blank from "no concern". That violation is
        // structurally unreachable here and deliberately so: on Android, as on
        // iOS, the state is a non-optional enum derived from the actives, so it
        // is always one of the three valid answers. The Portal sends a string
        // and can send an empty one, which is why `save_contract.ts` keeps the
        // check. Deriving it here rather than trusting a caller is what makes
        // the difference structural instead of merely likely.
        val resolvedState = resistanceState ?: ChemicalResistanceState.rollup(actives)

        if (intent == ChemicalSaveIntent.VERIFIED) {
            val registration = intelligence.registration
            val number = registration?.registrationNumber?.trim().orEmpty()
            val country = registration?.countryCode?.trim().orEmpty()
            if (number.isEmpty() || country.isEmpty()) {
                violations.add(
                    ChemicalSaveViolation(
                        code = ChemicalSaveViolationCode.REGISTRATION_IDENTITY_MISSING,
                        message = "A verified product needs its registration number and country.",
                        field = "registration",
                    ),
                )
            }
            val label = registration?.labelReference?.trim().orEmpty()
            if (label.isEmpty()) {
                violations.add(
                    ChemicalSaveViolation(
                        code = ChemicalSaveViolationCode.OFFICIAL_LABEL_MISSING,
                        message = "A verified product needs a link to the official regulator label.",
                        field = "label_reference",
                    ),
                )
            }
        }

        // Deduplicate: several malformed rates produce one actionable message,
        // not the same sentence three times.
        val seen = mutableSetOf<String>()
        val deduped = violations.filter { seen.add(it.id) }

        return ChemicalSaveEvaluation(
            violations = deduped,
            resistanceState = resolvedState,
            hasUsableViticulturalRate = usable.isNotEmpty(),
            requiresRateConditionChoice = usable.isNotEmpty() &&
                usable.all { it.conditionAmbiguous == true },
        )
    }

    // ---- Baseline: "never make it worse" ----
    //
    // iOS carries these three on `ChemicalReviewSession`, which Android has no
    // equivalent of. They live here rather than inside the form so the screen,
    // any future flow and the tests all consult ONE rule — a second copy in a
    // Composable is exactly how the button and the contract drifted apart in
    // the first place.

    /**
     * The violations a stored record ALREADY had, measured as it opens.
     *
     * The mandatory contract must stop a NEW chemical entering the store
     * unusable. Applied flatly it would also strand every legacy record: a
     * pre-Chemical-Intelligence product has no structured grapevine use and no
     * structured rate, so an operator opening one to fix a typo would find Save
     * permanently disabled and would lose the edit. A record that cannot be
     * saved cannot be repaired.
     *
     * A brand-new chemical ([existing] null) has an EMPTY baseline, so the full
     * contract applies to it. Mirrors iOS
     * `ChemicalReviewSession.baselineViolationCodes` exactly.
     */
    fun baselineViolationCodes(
        existing: SavedChemical?,
        fallbackCountry: String,
    ): Set<ChemicalSaveViolationCode> {
        if (existing == null) return emptySet()
        val opened = ChemicalManualEntry.draft(existing, fallbackCountry)
        return evaluate(
            productName = existing.name,
            productCategory = opened.productCategory,
            intelligence = ChemicalManualEntry.proposedIntelligence(
                opened,
                existing.storedIntelligence,
            ),
        ).violations.map { it.code }.toSet()
    }

    /**
     * The violations THIS edit would add. Only these may block Save.
     *
     * A compliant chemical can never be edited into non-compliance, because a
     * fault it did not arrive with is not in the baseline.
     */
    fun blockingViolations(
        evaluation: ChemicalSaveEvaluation,
        baseline: Set<ChemicalSaveViolationCode>,
    ): List<ChemicalSaveViolation> = evaluation.violations.filterNot { it.code in baseline }

    /** The faults the record arrived with. Guidance, never a block. */
    fun carriedOverViolations(
        evaluation: ChemicalSaveEvaluation,
        baseline: Set<ChemicalSaveViolationCode>,
    ): List<ChemicalSaveViolation> = evaluation.violations.filter { it.code in baseline }

    /** Per-rate structural faults, so the operator can fix the value itself. */
    private fun rateViolations(rates: List<ChemicalLabelRate>): List<ChemicalSaveViolation> {
        val out = mutableListOf<ChemicalSaveViolation>()
        for (rate in rates) {
            // A verbatim entry is a legitimate record, not a malformed rate.
            if (rate.basis == ChemicalLabelRateBasis.OTHER) continue
            if (rate.unit.trim().isEmpty()) {
                out.add(
                    ChemicalSaveViolation(
                        code = ChemicalSaveViolationCode.RATE_UNIT_MISSING,
                        message = "Enter the unit for this rate (L, mL, kg or g).",
                        field = "rates",
                    ),
                )
            }
            when (rate.basis) {
                ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
                ChemicalLabelRateBasis.RANGE_PER_HECTARE,
                -> {
                    val low = rate.minValue
                    val high = rate.maxValue
                    if (low == null || high == null ||
                        !low.isFinite() || !high.isFinite() || low <= 0 || high <= 0
                    ) {
                        out.add(
                            ChemicalSaveViolation(
                                code = ChemicalSaveViolationCode.RATE_VALUE_INVALID,
                                message = "Enter both ends of this rate range from the label.",
                                field = "rates",
                            ),
                        )
                        continue
                    }
                    if (high < low) {
                        out.add(
                            ChemicalSaveViolation(
                                code = ChemicalSaveViolationCode.RATE_RANGE_INVERTED,
                                message =
                                "This rate range is back to front — the low value must come first.",
                                field = "rates",
                            ),
                        )
                    }
                }

                ChemicalLabelRateBasis.PER_100_LITRES,
                ChemicalLabelRateBasis.PER_HECTARE,
                -> {
                    val value = rate.value
                    if (value == null || !value.isFinite() || value <= 0) {
                        out.add(
                            ChemicalSaveViolation(
                                code = ChemicalSaveViolationCode.RATE_VALUE_INVALID,
                                message = "Enter the rate from the label.",
                                field = "rates",
                            ),
                        )
                    }
                }

                ChemicalLabelRateBasis.OTHER -> continue
            }
        }
        return out
    }
}
