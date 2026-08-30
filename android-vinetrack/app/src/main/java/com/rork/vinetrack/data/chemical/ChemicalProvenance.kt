package com.rork.vinetrack.data.chemical

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.nullable
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Evidence tiers the server resolver records against stored values, and the
 * display rules for showing them. Mirrors the iOS `ChemicalProvenance.swift`
 * decision for decision.
 *
 * Everything here reads STORED provenance verbatim. Nothing derives a tier
 * from a value, upgrades an AI or operator value to label/register standing,
 * or invents provenance for records saved before the server published it —
 * absence always means "unknown", which displays as nothing at all.
 */

/**
 * An authoritative evidence tier, parsed from a raw stored string.
 *
 * `ai_interpretation`, `unresolved`, unknown strings and absent values all
 * deliberately have NO entry: they can never be presented as authority.
 */
enum class ChemicalProvenanceTier(val raw: String, val displayLabel: String) {
    OFFICIAL_REGISTER("official_register", "Official register"),
    MANUFACTURER_LABEL("manufacturer_label", "Official label"),
    AUTHORITATIVE_CLASSIFICATION("authoritative_classification", "Authoritative classification"),
    MASTER_CATALOGUE("master_catalogue", "Master catalogue"),
    ;

    companion object {
        /**
         * The authoritative tier a raw stored string proves, or null for
         * AI-supplied, unresolved, unknown or absent provenance. Fails closed:
         * a tier string this build does not recognise is NOT authority.
         */
        fun authoritative(raw: String?): ChemicalProvenanceTier? {
            if (raw == null) return null
            return entries.firstOrNull { it.raw == raw }
        }
    }
}

/**
 * The per-use facts that can carry provenance and appear in the UI.
 * Raw values are the exact wire keys of `registered_uses[].provenance`.
 */
enum class ChemicalUseProvenanceFact(val raw: String) {
    RATES("rates"),
    WITHHOLDING_PERIOD("withholding_period"),
    RE_ENTRY("re_entry"),
    RESTRICTIONS("restrictions"),
}

/**
 * A tag the UI may attach to a displayed fact: a proven tier, or an explicit
 * "Unresolved" for a value present without authoritative backing (the
 * contract treats AI-supplied values as present-but-unresolved).
 */
sealed interface ChemicalProvenanceBadge {
    data class Authoritative(val tier: ChemicalProvenanceTier) : ChemicalProvenanceBadge
    object Unresolved : ChemicalProvenanceBadge

    val text: String
        get() = when (this) {
            is Authoritative -> tier.displayLabel
            Unresolved -> "Unresolved"
        }
}

/**
 * Which provenance tags a registered-use card shows — chosen to stay
 * lightweight instead of stamping every row:
 *
 * - No stored provenance (legacy, manual, pre-provenance servers) → nothing.
 * - Every displayed fact proves the SAME authoritative tier → one compact
 *   badge for the whole card.
 * - Mixed trust (e.g. label-backed restrictions carrying an AI withholding
 *   period) → a badge per fact, with "Unresolved" on the unproven ones —
 *   the one case where per-row tags earn their space.
 * - Nothing authoritative at all → nothing; the verification banner already
 *   says the record is unverified, so repeating it per row is clutter.
 */
sealed interface ChemicalUseProvenancePlan {
    object Hidden : ChemicalUseProvenancePlan
    data class Uniform(val tier: ChemicalProvenanceTier) : ChemicalUseProvenancePlan
    data class Mixed(
        val badges: Map<ChemicalUseProvenanceFact, ChemicalProvenanceBadge>,
    ) : ChemicalUseProvenancePlan

    /** The single card-level badge, when every displayed fact shares a tier. */
    val headerBadge: ChemicalProvenanceBadge?
        get() = (this as? Uniform)?.let { ChemicalProvenanceBadge.Authoritative(it.tier) }

    /** The per-fact badge in the mixed-trust case, null otherwise. */
    fun badgeFor(fact: ChemicalUseProvenanceFact): ChemicalProvenanceBadge? =
        (this as? Mixed)?.badges?.get(fact)

    companion object {
        fun make(
            provenance: Map<String, String>?,
            displayedFacts: List<ChemicalUseProvenanceFact>,
        ): ChemicalUseProvenancePlan {
            if (provenance.isNullOrEmpty() || displayedFacts.isEmpty()) return Hidden
            val proven: Map<ChemicalUseProvenanceFact, ChemicalProvenanceTier> =
                displayedFacts.mapNotNull { fact ->
                    ChemicalProvenanceTier.authoritative(provenance[fact.raw])
                        ?.let { fact to it }
                }.toMap()
            if (proven.isEmpty()) return Hidden
            val distinct = proven.values.toSet()
            if (proven.size == displayedFacts.size && distinct.size == 1) {
                return Uniform(distinct.first())
            }
            return Mixed(
                displayedFacts.associateWith { fact ->
                    proven[fact]?.let { ChemicalProvenanceBadge.Authoritative(it) }
                        ?: ChemicalProvenanceBadge.Unresolved
                },
            )
        }
    }
}

/**
 * The provenance-bearing facts this use's card actually displays, in display
 * order. Rates are shown product-level, not per card — see [uniformRatesBadge].
 */
val ChemicalRegisteredUse.displayedProvenanceFacts: List<ChemicalUseProvenanceFact>
    get() = buildList {
        if (withholdingPeriodDays != null) add(ChemicalUseProvenanceFact.WITHHOLDING_PERIOD)
        if (reEntryPeriodHours != null) add(ChemicalUseProvenanceFact.RE_ENTRY)
        if (!restrictions.isNullOrEmpty()) add(ChemicalUseProvenanceFact.RESTRICTIONS)
    }

/** Tag plan for this use's card. */
val ChemicalRegisteredUse.provenancePlan: ChemicalUseProvenancePlan
    get() = ChemicalUseProvenancePlan.make(provenance, displayedProvenanceFacts)

/**
 * One aggregate badge for the product-level label-rates section, shown only
 * when EVERY rate-owning use proves the SAME authoritative tier for its
 * rates. Anything less — any use without stored provenance, any AI-carried
 * rate, any disagreement — renders nothing: silence, never a guess.
 */
fun List<ChemicalRegisteredUse>.uniformRatesBadge(): ChemicalProvenanceBadge? {
    val owners = filter { it.rates.isNotEmpty() }
    if (owners.isEmpty()) return null
    val tiers = mutableSetOf<ChemicalProvenanceTier>()
    for (use in owners) {
        val tier = ChemicalProvenanceTier.authoritative(
            use.provenance?.get(ChemicalUseProvenanceFact.RATES.raw),
        ) ?: return null
        tiers.add(tier)
    }
    val single = tiers.singleOrNull() ?: return null
    return ChemicalProvenanceBadge.Authoritative(single)
}

/**
 * Display rule for a registered use's withholding period line.
 *
 * The resolver only ever parses a label's "NOT REQUIRED WHEN USED AS
 * DIRECTED" statement to 0 days — it never derives 0 from anything else
 * (`chemical-info-lookup` contract). So a zero is shown with that label
 * wording ONLY when the evidence says the label was actually consulted:
 * either the use's own verbatim statements carry the phrase, or the payload
 * cites the manufacturer's approved label as a source. An operator-typed or
 * AI-only zero has no such wording behind it and stays a plain "0 days"; a
 * missing value stays missing. Nothing here fabricates or upgrades evidence
 * — it only chooses wording for evidence already present. Mirrors the iOS
 * `ChemicalWithholdingDisplay` exactly.
 */
object ChemicalWithholdingDisplay {
    /** The exact label phrase that authorises the friendly wording. */
    const val NOT_REQUIRED_PHRASE: String = "not required when used as directed"

    /**
     * Wording when a value is genuinely unresolved. Rows are still DRAWN with
     * it: a hidden row reads as "no restriction"; "Not stated" reads as "go
     * and check". Mirrors the iOS `ChemicalWithholdingDisplay.notStated`.
     */
    const val NOT_STATED: String = "Not stated"

    /**
     * Human wording for a use's withholding period, or null when none is
     * stated (an unresolved withholding period is never invented).
     */
    fun text(days: Int?, restrictions: String?, hasManufacturerLabelSource: Boolean): String? {
        if (days == null) return null
        if (days == 0) {
            val wordingPresent = restrictions?.lowercase()?.contains(NOT_REQUIRED_PHRASE) == true
            if (wordingPresent || hasManufacturerLabelSource) {
                return "Not required when used as directed"
            }
        }
        return "$days days"
    }

    /** [text], with an unresolved value reading as [NOT_STATED]. */
    fun display(days: Int?, restrictions: String?, hasManufacturerLabelSource: Boolean): String =
        text(days, restrictions, hasManufacturerLabelSource) ?: NOT_STATED

    /**
     * Re-entry wording when the label stated no rule of any kind. Mirrors
     * the iOS `ChemicalReEntryDisplay.notStated` summary exactly.
     */
    const val RE_ENTRY_NOT_STATED: String = "Not stated on label"

    /**
     * Human wording for a use's re-entry line. Re-entry has three real
     * answers: a countable period, the label's own verbatim condition (e.g.
     * "until the spray has dried"), or silence — and silence reads as
     * [RE_ENTRY_NOT_STATED], never as "no restriction". Nothing is ever
     * inferred or defaulted. Mirrors the iOS `ChemicalReEntryDisplay.summary`.
     */
    fun reEntrySummary(hours: Int?, statement: String?): String {
        if (hours != null) return if (hours == 1) "1 hour" else "$hours hours"
        statement?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        return RE_ENTRY_NOT_STATED
    }

    /** Whether the label stated a re-entry rule of any kind. */
    fun reEntryIsStated(hours: Int?, statement: String?): Boolean =
        hours != null || !statement?.trim().isNullOrEmpty()
}

/**
 * Tolerant serializer for stored provenance maps, mirroring the iOS
 * `try? decodeIfPresent([String: String].self, ...)` behaviour: a malformed
 * or missing map reads as null so the record itself always loads, and the
 * value is never guessed. Unknown tier STRINGS round-trip verbatim — only a
 * structurally invalid map (non-object, or any non-string value) degrades.
 * Null is omitted from writes by `explicitNulls = false`, so records without
 * provenance never gain fabricated keys on re-save.
 */
@OptIn(ExperimentalSerializationApi::class)
object ChemicalProvenanceMapSerializer : KSerializer<Map<String, String>?> {
    private val delegate = MapSerializer(String.serializer(), String.serializer())

    override val descriptor: SerialDescriptor = SerialDescriptor(
        "com.rork.vinetrack.data.chemical.ChemicalProvenanceMap",
        delegate.descriptor,
    ).nullable

    override fun deserialize(decoder: Decoder): Map<String, String>? {
        val input = decoder as? JsonDecoder ?: return delegate.deserialize(decoder)
        val element = input.decodeJsonElement()
        if (element !is JsonObject) return null
        val out = LinkedHashMap<String, String>(element.size)
        for ((key, value) in element) {
            val primitive = value as? JsonPrimitive ?: return null
            if (!primitive.isString) return null
            out[key] = primitive.content
        }
        return out
    }

    override fun serialize(encoder: Encoder, value: Map<String, String>?) {
        if (value == null) {
            encoder.encodeNull()
        } else {
            encoder.encodeSerializableValue(delegate, value)
        }
    }
}
