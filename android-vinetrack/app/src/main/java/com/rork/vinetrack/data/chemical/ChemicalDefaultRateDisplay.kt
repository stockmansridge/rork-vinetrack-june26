package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.model.SavedChemical

/**
 * What the Chemical Store shows as a product's OPERATIONAL rate.
 *
 * # Why this is not `ratePerHaDisplay`
 *
 * The list used to render [SavedChemical.ratePerHaDisplay] and
 * [SavedChemical.ratePer100LDisplay]. Both read the legacy `rates` array and
 * fall back to the legacy `rate_per_ha` column, and neither can tell an
 * operator-confirmed decision from a number that was projected, imported or
 * typed years ago. So a product whose rate nobody had confirmed still showed a
 * confident "2 L/ha", and the operator had no way to see that VineTrack was
 * quoting them a number rather than their own decision.
 *
 * `default_rates` is the authority, and the ONLY thing that may be presented as
 * this vineyard's confirmed rate. A structured product with no confirmed
 * default says so plainly instead of borrowing a legacy figure.
 *
 * # Units come from the slot, never from the product
 *
 * [SavedChemical.unit] is the INVENTORY unit — how the product is bought and
 * stocked. A product bought in kilograms is routinely dosed in grams per
 * hectare, and printing "560 Kg/ha" for a 560 g/ha default is a thousandfold
 * error in the direction that empties a shed. Each slot carries the label
 * rate's own unit and that is what is displayed.
 */
object ChemicalDefaultRateDisplay {

    /**
     * Shown for a structured product whose operational rate nobody has
     * confirmed. Deliberately an instruction rather than a blank or a dash: it
     * names an action the operator can take, and it never implies the label
     * has no rates — that question is answered by `registered_uses` alone.
     */
    const val CONFIRMATION_REQUIRED: String = "Rate confirmation required"

    /** The suffix each basis is written with: `2 L/ha`, `150 g/100 L`. */
    fun basisSuffix(basis: ChemicalDefaultRateBasis): String = when (basis) {
        ChemicalDefaultRateBasis.PER_HECTARE -> "/ha"
        ChemicalDefaultRateBasis.PER_100_LITRES -> "/100 L"
    }

    /**
     * Whether this record carries structured chemical intelligence.
     *
     * A product with registered uses, or with a recorded default, is governed
     * by the structured contract. Everything else is a legacy or manual record
     * that predates it and keeps its own behaviour — the migration rule is
     * "never strand an existing record", not "retro-fit every old one".
     */
    fun isStructured(chemical: SavedChemical): Boolean =
        !chemical.registeredUses.isNullOrEmpty() || chemical.defaultRates != null

    /**
     * One rendered slot, e.g. `"2 L/ha"`, or null when this basis records no
     * usable confirmed amount.
     *
     * A slot still holding a legacy range with no scalar returns null: an
     * unnarrowed band is a decision that was never finished, and rendering its
     * bounds here would present a permitted span as a confirmed dose.
     *
     * The whole persisted shape is validated through
     * [ChemicalDefaultRateValidity] — the same gate the spray handoff uses, so
     * a row this store shows as confirmed is exactly a row a spray line may
     * start from.
     */
    fun slotDisplay(
        defaults: StoredChemicalDefaultRates?,
        basis: ChemicalDefaultRateBasis,
    ): String? {
        val valid = ChemicalDefaultRateValidity.confirmedScalar(defaults, basis) ?: return null
        val amount = valid.scalar ?: return null
        return "${formatChemicalNumber(amount)} ${valid.unit}${basisSuffix(basis)}"
    }

    /** Every confirmed slot, per-hectare first, in the order an operator reads. */
    fun slotDisplays(defaults: StoredChemicalDefaultRates?): List<String> =
        listOfNotNull(
            slotDisplay(defaults, ChemicalDefaultRateBasis.PER_HECTARE),
            slotDisplay(defaults, ChemicalDefaultRateBasis.PER_100_LITRES),
        )

    /**
     * The distinct USABLE registered grapevine rates, one line each, in label
     * order:
     *
     * ```text
     * "Registered label range: 560–700 g/ha"
     * "Registered label rate: 2 L/ha"
     * ```
     *
     * A band is always NAMED as a band so it can never be read as a dose
     * somebody chose. Usability is [ChemicalSaveContract.isUsable] — the same
     * rule that admitted the record to the store — so this line exists exactly
     * when the save contract's rate requirement was met from `registered_uses`.
     * Purely a projection for display: nothing here writes `default_rates`,
     * mints an `option_key`, `rate_id` or `direction_id`, or alters the stored
     * uses in any way.
     */
    fun registeredRateSummaries(uses: List<ChemicalRegisteredUse>?): List<String> {
        val lines = LinkedHashSet<String>()
        uses.orEmpty().viticultural()
            .flatMap { it.rates }
            .filter { ChemicalSaveContract.isUsable(it) }
            .forEach { rate ->
                val isRange = rate.minValue != null && rate.maxValue != null
                lines.add(
                    if (isRange) {
                        "Registered label range: ${rate.displayRate}"
                    } else {
                        "Registered label rate: ${rate.displayRate}"
                    },
                )
            }
        return lines.toList()
    }

    /**
     * The registered-rate line a store card falls back to when no optional
     * default was confirmed. First usable registered grapevine rate, in label
     * order; null when the registration carries no usable rate.
     */
    fun registeredRateLine(chemical: SavedChemical): String? =
        registeredRateSummaries(chemical.registeredUses).firstOrNull()

    /**
     * The operational rate line for a Chemical Store row.
     *
     * ```text
     * confirmed default(s)             -> "2 L/ha"  |  "2 L/ha · 150 g/100 L"
     * usable registered rate or range  -> "Registered label range: 560–700 g/ha"
     * structured, no usable rate       -> "Rate confirmation required"
     * legacy/manual record             -> null (the caller keeps its legacy line)
     * ```
     *
     * A confirmed optional default always wins. Without one, a usable
     * registered grapevine rate is a complete, saveable record of what the
     * label permits (the same rule that enabled the save), so it is what the
     * card states — clearly named as the LABEL's figure, never presented as a
     * confirmed vineyard dose. "Rate confirmation required" survives only for
     * the genuinely unfinished case: structured intelligence with no usable
     * registered rate at all.
     *
     * Never the first `rates` row, and never `rate_per_ha`: neither can be
     * shown to be a decision anybody made.
     */
    fun line(chemical: SavedChemical): String? {
        val confirmed = slotDisplays(chemical.defaultRates)
        if (confirmed.isNotEmpty()) return confirmed.joinToString(" · ")
        registeredRateLine(chemical)?.let { return it }
        if (isStructured(chemical)) return CONFIRMATION_REQUIRED
        return null
    }

    /**
     * True when this product's operational rate still needs the operator's
     * attention.
     *
     * False for a confirmed default, false for a legacy record (nothing about
     * an old manual chemical is unfinished, it simply predates the structured
     * contract) — and false when the registration itself states a usable
     * grapevine rate or range. That record is complete as saved: the exact
     * dose is a spray-time decision, and painting the card amber for it told
     * the operator something was wrong when nothing was.
     */
    fun needsConfirmation(chemical: SavedChemical): Boolean =
        isStructured(chemical) &&
            slotDisplays(chemical.defaultRates).isEmpty() &&
            registeredRateLine(chemical) == null
}

/**
 * The compact registered-use review: crop once, target names only.
 *
 * The register publishes one printed label direction as one row per target, so
 * a single grapevine direction arrives as dozens of uses that differ only in
 * `target_raw`. The review used to render the full crop/rate/WHP/re-entry/
 * restrictions block for every one of them — pages of the same legal text —
 * which buried the rate the operator came to read. This projection is what the
 * compact review shows instead; the COMPLETE `registered_uses` data is stored
 * unchanged and remains one tap away where detail is needed.
 *
 * Pure selection logic, kept out of the composable so both review surfaces and
 * the tests consult one rule.
 */
object ChemicalRegisteredUseCompactDisplay {

    /** How many targets the collapsed review shows. */
    const val COLLAPSED_TARGET_COUNT: Int = 5

    /** The crop, stated ONCE above the target list. */
    const val CROP_LABEL: String = "Grapevine"

    const val SHOW_FEWER_LABEL: String = "Show fewer"

    /** Shown in place of a target the label left blank. */
    const val TARGET_NOT_STATED: String = "Target not stated"

    /**
     * Target names in label order, deduplicated case-insensitively — the
     * register routinely lists "Powdery mildew" and "Powdery Mildew" as
     * separate rows. The FIRST spelling wins so the list reads as the label
     * printed it.
     */
    fun dedupedTargets(uses: List<ChemicalRegisteredUse>): List<String> {
        val seen = mutableSetOf<String>()
        val out = mutableListOf<String>()
        for (use in uses) {
            val name = use.targetRaw.trim().ifEmpty { TARGET_NOT_STATED }
            if (seen.add(name.lowercase())) out.add(name)
        }
        return out
    }

    /** The collapsed selection: the first [COLLAPSED_TARGET_COUNT], in order. */
    fun collapsedTargets(targets: List<String>): List<String> =
        targets.take(COLLAPSED_TARGET_COUNT)

    fun heading(targetCount: Int): String = "Registered grapevine uses ($targetCount)"

    fun showAllLabel(targetCount: Int): String = "Show all $targetCount uses"
}
