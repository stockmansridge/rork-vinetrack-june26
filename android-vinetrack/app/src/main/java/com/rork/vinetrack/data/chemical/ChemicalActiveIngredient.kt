package com.rork.vinetrack.data.chemical

import java.math.BigDecimal
import java.math.MathContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Formats a number exactly the way the iOS side's `%.4g` does: four significant
 * digits with trailing zeros stripped.
 *
 * Java's `%g` keeps trailing zeros where C's strips them, so `String.format`
 * cannot be used directly — it would render a 1.5 L/ha label rate as "1.500 L/ha"
 * on Android and "1.5 L/ha" on iOS. A rate must never read differently depending
 * on which phone is in the operator's hand.
 */
internal fun formatChemicalNumber(value: Double): String {
    if (value == Math.rint(value) && Math.abs(value) < 1_000_000) return value.toInt().toString()
    return BigDecimal(value).round(MathContext(4)).stripTrailingZeros().toPlainString()
}

/** The unit a label states an active's concentration in. */
@Serializable
enum class ChemicalConcentrationUnit(val raw: String) {
    /** Grams of active per litre of product — liquid formulations. */
    @SerialName("g/L")
    GRAMS_PER_LITRE("g/L"),

    /** Grams of active per kilogram of product — solid formulations. */
    @SerialName("g/kg")
    GRAMS_PER_KILOGRAM("g/kg"),

    @SerialName("% w/w")
    PERCENT_WEIGHT_PER_WEIGHT("% w/w"),

    @SerialName("% w/v")
    PERCENT_WEIGHT_PER_VOLUME("% w/v"),

    /** Colony-forming units per gram — biological products. */
    @SerialName("CFU/g")
    COLONY_FORMING_UNITS_PER_GRAM("CFU/g"),
    ;

    val label: String get() = raw

    companion object {
        /** Tolerant reading of how labels and AI actually write these. */
        fun parse(raw: String?): ChemicalConcentrationUnit? {
            val v = raw?.trim()?.lowercase()?.replace(" ", "")?.takeIf { it.isNotEmpty() }
                ?: return null
            entries.firstOrNull { it.raw.lowercase().replace(" ", "") == v }?.let { return it }
            return when (v) {
                "gl", "gpl", "gramsperlitre", "grams/litre" -> GRAMS_PER_LITRE
                "gkg", "gramsperkilogram", "grams/kg" -> GRAMS_PER_KILOGRAM
                "%ww", "percentw/w", "w/w", "%", "percent" -> PERCENT_WEIGHT_PER_WEIGHT
                "%wv", "percentw/v", "w/v" -> PERCENT_WEIGHT_PER_VOLUME
                "cfug" -> COLONY_FORMING_UNITS_PER_GRAM
                else -> null
            }
        }
    }
}

/**
 * One active constituent of a registered product.
 *
 * This is the unit that carries an activity group. A product does NOT have a
 * group; each of its actives does. A two-active mixture therefore genuinely
 * belongs to two groups at once, which is exactly what resistance management
 * needs to know.
 *
 * Mirrors the iOS `ChemicalActiveIngredient` JSON keys exactly so the value
 * round-trips across platforms.
 */
@Serializable
data class ChemicalActiveIngredient(
    /** The active's common (ISO) name, e.g. `"Tebuconazole"`. */
    val name: String = "",
    /**
     * Concentration value as stated on the label, e.g. `200`. Null when it has
     * not been established — never guessed, because a wrong concentration
     * silently mis-doses.
     */
    val concentration: Double? = null,
    @SerialName("concentration_unit") val concentrationUnit: ChemicalConcentrationUnit? = null,
    /** Null = unknown, which is a legitimate and visible state. */
    @SerialName("activity_group") val activityGroup: ChemicalActivityGroup? = null,
    /**
     * Where the activity group specifically came from. Held per-active because
     * a mixture can have one active confirmed against FRAC and another still
     * only AI-suggested.
     */
    @SerialName("group_source") val groupSource: ChemicalDataSourceKind? = null,
    @SerialName("identity_source") val identitySource: ChemicalDataSourceKind? = null,
) {
    val id: String get() = name.lowercase()

    /** `"Tebuconazole 200 g/L"`, or just the name when no concentration is known. */
    val displayLabel: String
        get() {
            val c = concentration
            val u = concentrationUnit
            return if (c != null && u != null) "$name ${formatConcentration(c)} ${u.label}" else name
        }

    /** `"Tebuconazole 200 g/L — FRAC 3"`. */
    val displayLabelWithGroup: String
        get() {
            val g = activityGroup
            return if (g != null && g.isResistanceRelevant) "$displayLabel — ${g.displayLabel}"
            else displayLabel
        }

    /** Whether this active is fully described for resistance purposes. */
    val isResistanceComplete: Boolean
        get() = name.isNotEmpty() && (activityGroup?.isResistanceRelevant == true)

    /** Whether the group came from a source strong enough to be called verified. */
    val hasAuthoritativeGroup: Boolean
        get() = groupSource?.isAuthoritative == true && activityGroup?.isResistanceRelevant == true

    val hasConcentration: Boolean get() = concentration != null && concentrationUnit != null

    companion object {
        fun formatConcentration(value: Double): String = formatChemicalNumber(value)
    }
}

/**
 * Every activity group this product belongs to, de-duplicated and ordered.
 *
 * A Tebuconazole + Azoxystrobin product returns FRAC 3 AND FRAC 11 — the mixture
 * counts as both, independently, which is precisely what `"3 + 11"` as a single
 * string could never express.
 */
fun List<ChemicalActiveIngredient>.activityGroups(): List<ChemicalActivityGroup> =
    mapNotNull { it.activityGroup }.canonicalised()

/** Actives whose group is unknown. Non-empty here means the product can never be Verified. */
fun List<ChemicalActiveIngredient>.missingGroups(): List<ChemicalActiveIngredient> =
    filter { it.activityGroup?.isResistanceRelevant != true }

/** Actives whose group came only from a non-authoritative source. */
fun List<ChemicalActiveIngredient>.unconfirmedGroups(): List<ChemicalActiveIngredient> =
    filter { it.activityGroup?.isResistanceRelevant == true && !it.hasAuthoritativeGroup }

/**
 * `"Tebuconazole 200 g/L + Azoxystrobin 120 g/L"` — the legacy
 * `active_ingredient` display projection. Output only; nothing may parse it back.
 */
fun List<ChemicalActiveIngredient>.legacyActiveIngredientProjection(): String =
    joinToString(" + ") { it.displayLabel }
