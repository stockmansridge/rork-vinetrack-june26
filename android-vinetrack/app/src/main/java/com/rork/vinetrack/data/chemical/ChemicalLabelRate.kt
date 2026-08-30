package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayTarget
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The basis a registered LABEL quotes a product rate against.
 *
 * This is emphatically NOT the spray carrier volume basis. An NZ vineyard
 * measuring carrier in L/100 m still applies a product whose label says
 * "1.5 L/ha" — the label basis belongs to the product, the carrier basis belongs
 * to the pass. Conflating them would silently re-rate the product.
 */
@Serializable
enum class ChemicalLabelRateBasis(val raw: String, val label: String) {
    @SerialName("per_100_litres")
    PER_100_LITRES("per_100_litres", "Per 100 L"),

    @SerialName("per_hectare")
    PER_HECTARE("per_hectare", "Per hectare"),

    @SerialName("range_per_100_litres")
    RANGE_PER_100_LITRES("range_per_100_litres", "Range per 100 L"),

    @SerialName("range_per_hectare")
    RANGE_PER_HECTARE("range_per_hectare", "Range per hectare"),

    /**
     * Anything the label expresses differently (per vine, per metre of row, per
     * tonne). Captured verbatim rather than forced into a shape it does not fit.
     */
    @SerialName("other")
    OTHER("other", "Other"),
    ;

    val suffix: String
        get() = when (this) {
            PER_100_LITRES, RANGE_PER_100_LITRES -> "/100 L"
            PER_HECTARE, RANGE_PER_HECTARE -> "/ha"
            OTHER -> ""
        }

    val isVolumeBased: Boolean get() = this == PER_100_LITRES || this == RANGE_PER_100_LITRES
    val isAreaBased: Boolean get() = this == PER_HECTARE || this == RANGE_PER_HECTARE

    /**
     * The spray-workflow product bases this label basis can legitimately be
     * applied through.
     *
     * This is the hand-off to the Guided Spray workflow: Chemical Intelligence
     * says which choices to OFFER, so the operator picks from what the label
     * actually supports instead of guessing.
     *
     * A per-100 L label maps to exactly one option, so the workflow shows no
     * picker at all. An area label maps to whole-block or treated-area, which is
     * precisely the ambiguity the banded-spray picker exists to resolve.
     */
    val compatibleProductRateBases: List<SprayProductRateBasis>
        get() = when (this) {
            PER_100_LITRES, RANGE_PER_100_LITRES -> listOf(SprayProductRateBasis.PER_100_LITRES)
            PER_HECTARE, RANGE_PER_HECTARE -> listOf(
                SprayProductRateBasis.WHOLE_BLOCK_AREA,
                SprayProductRateBasis.TREATED_AREA,
            )
            OTHER -> emptyList()
        }

    companion object {
        fun from(raw: String?): ChemicalLabelRateBasis {
            val v = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return OTHER
            return entries.firstOrNull { it.raw == v } ?: OTHER
        }
    }
}

/** One rate option from a registered label. */
@Serializable
data class ChemicalLabelRate(
    /** What the label calls this rate, e.g. `"Low disease pressure"`. */
    val label: String = "",
    val basis: ChemicalLabelRateBasis = ChemicalLabelRateBasis.OTHER,
    /** A single rate value, for the non-range bases. */
    val value: Double? = null,
    @SerialName("min_value") val minValue: Double? = null,
    @SerialName("max_value") val maxValue: Double? = null,
    /** e.g. `"L"`, `"mL"`, `"kg"`, `"g"`. */
    val unit: String = "",
    /** Verbatim label text when [basis] is OTHER, so an unusual basis survives. */
    @SerialName("raw_text") val rawText: String? = null,
    /**
     * Stable, deterministic identity for this registered rate, minted by the
     * SERVER from the rate's meaning (locked product, crop, target, basis,
     * unit, values, condition).
     *
     * Backend-minted metadata. Android decodes it, preserves it and re-encodes
     * it unchanged; it must NEVER be invented, derived or repaired on device,
     * because an id computed against a product the record may turn out not to
     * be would then survive the register's correction.
     *
     * Null on records stored before the server minted identities, which must
     * keep decoding untouched. Mirrors iOS `ChemicalLabelRate.rateId`.
     */
    @SerialName("rate_id") val rateId: String? = null,
    /**
     * The label states SEVERAL rates on this basis and the server's
     * deterministic grammar could not prove which condition governs which
     * number.
     *
     * It never means the numbers are wrong — they are read verbatim from the
     * label. It means the ASSOCIATION between rate and condition is unproven,
     * so a client must make the operator choose rather than silently applying
     * the first one. Mirrors iOS `ChemicalLabelRate.conditionAmbiguous`.
     */
    @SerialName("condition_ambiguous") val conditionAmbiguous: Boolean? = null,
) {
    /**
     * Local list identity.
     *
     * Prefers the server-minted [rateId] so the same semantic rate keeps one
     * identity across re-extraction and array reordering, and falls back to the
     * legacy composed key for records minted before ids existed.
     */
    val id: String
        get() = rateId ?: "${basis.raw}|$label|${minValue ?: value ?: 0.0}"

    /** `"1.5 L/ha"` or `"1.0–2.0 L/ha"`. */
    val displayRate: String
        get() {
            val number = when {
                minValue != null && maxValue != null -> "${format(minValue)}–${format(maxValue)}"
                value != null -> format(value)
                rawText != null -> return rawText
                else -> return "Rate not established"
            }
            return "$number $unit${basis.suffix}".trim()
        }

    /**
     * The value a calculation should start from: a range proposes its LOW end,
     * never its high end, so an automatic suggestion can never inflate a dose on
     * the operator's behalf.
     */
    val proposedValue: Double? get() = value ?: minValue

    private fun format(v: Double): String = formatChemicalNumber(v)
}

/**
 * A registered use: which crop, which target, at which rates.
 *
 * Structured as crop + target + rate because "Group 11 therefore powdery" is not
 * a registered use — it is an assumption. The future Resistance Engine needs to
 * evaluate chemistry against the disease actually being targeted, and that
 * mapping only exists on the label.
 */
@Serializable
data class ChemicalRegisteredUse(
    /** e.g. `"Grapes"`. Kept as label text because registrations distinguish
     *  winegrapes from tablegrapes. */
    val crop: String = "",
    /** The target as the label words it, e.g. `"Powdery mildew"`. */
    @SerialName("target_raw") val targetRaw: String = "",
    /**
     * The target mapped onto VineTrack's typed spray vocabulary, when it maps
     * cleanly. Null means the label named something VineTrack has no target for
     * — recorded, not discarded, and never force-fitted.
     */
    val target: SprayTarget? = null,
    val rates: List<ChemicalLabelRate> = emptyList(),
    /**
     * The PRINTED LABEL DIRECTION this use came from, minted by the server.
     *
     * One printed direction routinely covers a crop, a rate and many targets;
     * the register publishes that as one row per target. This id is what lets a
     * client group those rows back into the single legal direction the label
     * actually prints, instead of showing the operator the same instruction
     * twenty-five times.
     *
     * Backend-minted metadata: decoded, preserved and re-encoded unchanged,
     * never invented on device. Null on records stored before the server minted
     * it. Mirrors iOS `ChemicalRegisteredUse.directionId`.
     */
    @SerialName("direction_id") val directionId: String? = null,
    @SerialName("withholding_period_days") val withholdingPeriodDays: Int? = null,
    /**
     * The label's VERBATIM withholding wording, whenever the label states one
     * ("14 weeks").
     *
     * A withholding period is a legal instruction and labels state it in the
     * units they mean it in; [withholdingPeriodDays] beside it is only the
     * projection scheduling needs. Showing the wording and calculating with the
     * number means neither has to be reconstructed from the other.
     *
     * Null means the label stated NO withholding period — a different answer
     * from zero, and it must never be rendered as one.
     */
    @SerialName("withholding_statement") val withholdingStatement: String? = null,
    @SerialName("re_entry_period_hours") val reEntryPeriodHours: Int? = null,
    /**
     * The label's verbatim re-entry condition when it states one without a
     * countable period (e.g. "Do not enter until the spray has dried"). The
     * resolver refuses to invent hours from such wording, so
     * [reEntryPeriodHours] stays null and the statement is carried VERBATIM
     * instead. Mirrors iOS `ChemicalRegisteredUse.reEntryStatement`.
     */
    @SerialName("re_entry_statement") val reEntryStatement: String? = null,
    val restrictions: String? = null,
    /**
     * Per-fact evidence tiers recorded by the server's label merge, keyed by
     * fact name (`claim`, `rates`, `withholding_period`, `re_entry`,
     * `restrictions`) with tier values such as `manufacturer_label` or
     * `ai_interpretation`. Stored VERBATIM: never derived from this record's
     * values, never rewritten on device, and null on records saved before the
     * server published provenance — absence means "unknown", never
     * "authoritative". Mirrors iOS `ChemicalRegisteredUse.provenance`.
     */
    @Serializable(with = ChemicalProvenanceMapSerializer::class)
    val provenance: Map<String, String>? = null,
) {
    val id: String get() = "$crop|$targetRaw"

    /**
     * How to group this use with the others printed under the SAME label
     * direction. Falls back to the crop when the server minted no id, which
     * groups nothing that was not already together.
     */
    val directionGroupKey: String get() = directionId ?: "$crop|$targetRaw"

    /**
     * Whether this use concerns grapevines.
     *
     * Delegates to the canonical whole-token predicate, which is the same rule
     * the server uses to build `grapevine_uses`. The previous substring test
     * (`contains("grape")`) classified GRAPEFRUIT — a citrus — as a grapevine,
     * which would offer a citrus rate as a vineyard default.
     */
    val isViticultural: Boolean
        get() = ChemicalGrapevineCrop.matches(crop)

    /** The target, mapping from the label wording when none was stored. */
    val resolvedTarget: SprayTarget? get() = target ?: mapTarget(targetRaw)

    companion object {
        /**
         * Conservative mapping from label wording onto VineTrack's typed targets.
         *
         * Only maps when the wording is unambiguous. Anything else stays null
         * rather than being guessed — a wrong target would tell the future
         * Resistance Engine the wrong disease was being managed.
         */
        fun mapTarget(raw: String): SprayTarget? {
            val v = raw.lowercase()
            return when {
                v.contains("powdery") || v.contains("uncinula") || v.contains("erysiphe") ->
                    SprayTarget.POWDERY_MILDEW
                v.contains("downy") || v.contains("plasmopara") -> SprayTarget.DOWNY_MILDEW
                v.contains("botrytis") || v.contains("bunch rot") -> SprayTarget.BOTRYTIS
                // P4 parity: iOS also reads "grass control" wording as weeds.
                // Without this branch an Android-written use stored target
                // null and resolved to null, while the SAME row opened on iOS
                // resolved to Weeds — the two platforms disagreed about what
                // the label said.
                v.contains("weed") || (v.contains("grass") && v.contains("control")) ->
                    SprayTarget.WEEDS
                else -> null
            }
        }
    }
}

/** Uses registered on grapevines. */
fun List<ChemicalRegisteredUse>.viticultural(): List<ChemicalRegisteredUse> =
    filter { it.isViticultural }

/** Every distinct label rate basis across all uses. */
fun List<ChemicalRegisteredUse>.rateBases(): List<ChemicalLabelRateBasis> =
    flatMap { use -> use.rates.map { it.basis } }.distinct()

/** Typed targets this product is actually registered against on grapes. */
fun List<ChemicalRegisteredUse>.viticulturalTargets(): List<SprayTarget> =
    viticultural().mapNotNull { it.resolvedTarget }.distinct()
