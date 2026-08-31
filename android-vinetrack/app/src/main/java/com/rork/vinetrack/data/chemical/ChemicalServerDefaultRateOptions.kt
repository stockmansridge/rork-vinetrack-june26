package com.rork.vinetrack.data.chemical

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The canonical default-rate options AS THE SERVER BUILT THEM.
 *
 * # Why this type has to exist
 *
 * The edge function already groups the label's grapevine rates into operator
 * choices and mints a stable `option_key` for each, citing the `rate_id` of
 * every printed direction behind it. Android ignored that block entirely: it
 * re-grouped `registered_uses` on device and minted its own key with a local
 * mirror of the server's hashing.
 *
 * A deterministic mirror is not the same guarantee as a shared value. The two
 * implementations agree only for as long as nobody changes either of them, and
 * the failure is silent and total — a key that drifts by one character stops
 * matching the Portal's and the server's, so the same confirmed choice reads as
 * two different options across clients, and every "is this default still
 * current?" check quietly answers no.
 *
 * So the identity now travels one way: the server issues it, this type carries
 * it verbatim, and the device never computes one.
 *
 * # Validation, never repair
 *
 * Every rule below answers yes or no about a whole option. A malformed option
 * is dropped, not mended: a "fixed" option would be a canonical-looking
 * identity for a choice the register never issued, which is precisely what
 * minting on device did wrong.
 */
@Serializable
data class ChemicalServerDefaultRateOption(
    /** Server-minted. Never computed here. */
    @SerialName("option_key") val optionKey: String = "",
    /** Every printed direction supporting this amount. Never empty. */
    @SerialName("rate_ids") val rateIds: List<String> = emptyList(),
    /** `per_hectare` or `per_100_litres`. */
    val basis: String = "",
    /** The LABEL's own unit — never the product's stock unit. */
    val unit: String = "",
    val value: Double? = null,
    @SerialName("min_value") val minValue: Double? = null,
    @SerialName("max_value") val maxValue: Double? = null,

    // ---- display metadata: presentation only, never identity ----

    @SerialName("direction_ids") val directionIds: List<String> = emptyList(),
    val targets: List<String> = emptyList(),
    val conditions: List<String> = emptyList(),
    val crops: List<String> = emptyList(),
    /**
     * At least one supporting rate could not be tied to its condition by the
     * server's deterministic grammar. Carried so a screen can make the operator
     * choose deliberately rather than present an unproven association as
     * settled. It says nothing about whether the NUMBER is right.
     */
    @SerialName("condition_ambiguous") val conditionAmbiguous: Boolean = false,
) {

    /** The decision basis this option belongs to, or null when unrecognised. */
    val decisionBasis: ChemicalDefaultRateBasis?
        get() = ChemicalDefaultRateBasis.entries.firstOrNull { it.raw == basis.trim() }

    /** True when the label states this amount as a band. */
    val isRange: Boolean get() = minValue != null && maxValue != null

    /**
     * Whether this option may be believed.
     *
     * ```text
     * option_key   server-minted, `default_option_v1_` and not the bare prefix
     * rate_ids     non-empty, every entry a `rate_v1_` direction identity
     * basis        one of the two a default can be held on
     * unit         non-empty
     * amount       scalar XOR range (shared shape D3), finite and positive
     * ```
     *
     * The amount rule is the same one [ChemicalDefaultRateValidity] applies to
     * a PERSISTED slot, because an option that could not be stored must not be
     * offered either.
     */
    val isValid: Boolean
        get() {
            val key = optionKey.trim()
            if (!key.startsWith(ChemicalDefaultRateValidity.OPTION_KEY_PREFIX)) return false
            if (key.length <= ChemicalDefaultRateValidity.OPTION_KEY_PREFIX.length) return false

            val ids = rateIds.map { it.trim() }
            if (ids.isEmpty()) return false
            val ratePrefix = ChemicalDefaultRateValidity.RATE_ID_PREFIX
            if (ids.any { it.length <= ratePrefix.length || !it.startsWith(ratePrefix) }) return false

            if (decisionBasis == null) return false
            if (unit.trim().isEmpty()) return false

            fun usable(v: Double?) = v != null && v.isFinite() && v > 0.0
            val hasScalar = value != null
            val hasMin = minValue != null
            val hasMax = maxValue != null
            return when {
                hasScalar && !hasMin && !hasMax -> usable(value)
                !hasScalar && hasMin && hasMax ->
                    usable(minValue) && usable(maxValue) && minValue!! <= maxValue!!
                else -> false
            }
        }

    /**
     * The label basis this amount was printed on.
     *
     * Derived from the server's basis PLUS the amount shape, because the label
     * enum distinguishes a single figure from a band while the decision enum
     * deliberately does not.
     */
    val labelBasis: ChemicalLabelRateBasis
        get() = when (decisionBasis) {
            ChemicalDefaultRateBasis.PER_HECTARE ->
                if (isRange) ChemicalLabelRateBasis.RANGE_PER_HECTARE
                else ChemicalLabelRateBasis.PER_HECTARE
            ChemicalDefaultRateBasis.PER_100_LITRES ->
                if (isRange) ChemicalLabelRateBasis.RANGE_PER_100_LITRES
                else ChemicalLabelRateBasis.PER_100_LITRES
            null -> ChemicalLabelRateBasis.OTHER
        }

    /** The condition wording the supporting directions carried, as one line. */
    val conditionText: String get() = conditions.joinToString(", ") { it.trim() }.trim()

    /**
     * This option as the label rate it was read from.
     *
     * A straight copy of the server's own amount fields. Nothing is converted,
     * rounded or re-derived — the numbers reaching the operator are the numbers
     * the register printed.
     */
    fun toLabelRate(): ChemicalLabelRate = ChemicalLabelRate(
        label = conditionText,
        basis = labelBasis,
        value = value,
        minValue = minValue,
        maxValue = maxValue,
        unit = unit.trim(),
        // Deliberately null: this rate stands for a GROUP of directions, and
        // the group's citations live in `rateIds`. Naming one of them here
        // would imply the option rests on a single direction.
        rateId = null,
    )

    /**
     * The display conditions behind this option.
     *
     * Built from the server's own metadata, so the screen explains the option
     * using the directions the server actually grouped rather than a set the
     * device re-derived and might disagree about.
     */
    fun toConditions(): List<ChemicalDefaultRateCondition> {
        val crop = crops.firstOrNull()?.trim().orEmpty().ifEmpty { "GRAPEVINES" }
        val condition = conditionText
        val jurisdictions = ChemicalRateJurisdiction.mentioned(
            (conditions + targets).joinToString(" "),
        )
        if (targets.isEmpty()) {
            return listOf(
                ChemicalDefaultRateCondition(
                    crop = crop,
                    targetRaw = "",
                    conditionText = condition,
                    rawText = null,
                    jurisdictions = jurisdictions,
                ),
            )
        }
        return targets.map { target ->
            ChemicalDefaultRateCondition(
                crop = crop,
                targetRaw = target.trim(),
                conditionText = condition,
                rawText = null,
                jurisdictions = jurisdictions,
            )
        }
    }

    /**
     * This option as the domain option the picker renders.
     *
     * The `id` IS the server's `option_key`. Everything downstream — selection,
     * confirmation, persistence — therefore carries the server's identity by
     * construction rather than by a later lookup that could miss.
     */
    fun toDomainOption(): ChemicalDefaultRateOption = ChemicalDefaultRateOption(
        id = optionKey.trim(),
        rate = toLabelRate(),
        conditions = toConditions(),
        server = this,
    )
}

/** The server's options for a product, split by basis. The two are independent. */
@Serializable
data class ChemicalServerDefaultRateOptions(
    @SerialName("per_hectare") val perHectare: List<ChemicalServerDefaultRateOption> = emptyList(),
    @SerialName("per_100_litres")
    val per100Litres: List<ChemicalServerDefaultRateOption> = emptyList(),
) {
    /** Only the options that passed every rule, in the server's own order. */
    fun validOptions(basis: ChemicalDefaultRateBasis): List<ChemicalServerDefaultRateOption> {
        val raw = when (basis) {
            ChemicalDefaultRateBasis.PER_HECTARE -> perHectare
            ChemicalDefaultRateBasis.PER_100_LITRES -> per100Litres
        }
        // The containing list must agree with the option's own basis, exactly
        // as a persisted slot must agree with the slot it sits in: a per-100 L
        // option filed under per-hectare would be applied per hectare.
        return raw.filter { it.isValid && it.decisionBasis == basis }
    }

    /** True when the server supplied no usable option on either basis. */
    val isEmpty: Boolean
        get() = ChemicalDefaultRateBasis.entries.all { validOptions(it).isEmpty() }
}
