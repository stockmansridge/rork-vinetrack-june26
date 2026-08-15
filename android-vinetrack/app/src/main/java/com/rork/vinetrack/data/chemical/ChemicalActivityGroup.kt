package com.rork.vinetrack.data.chemical

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Which resistance-classification scheme an activity group code belongs to.
 *
 * A bare code like `"3"` is ambiguous on its own — FRAC 3 (DMI fungicides) and
 * IRAC 3 (sodium channel modulators) are unrelated chemistries. The scheme
 * travels with the code so the future Resistance Engine can never compare a
 * fungicide group against an insecticide group.
 *
 * Mirrors the iOS `ChemicalActivityGroupScheme` raw values exactly.
 */
@Serializable
enum class ChemicalActivityGroupScheme(val raw: String, val label: String) {
    /** Fungicide Resistance Action Committee. */
    @SerialName("frac")
    FRAC("frac", "FRAC"),

    /** Herbicide Resistance Action Committee. */
    @SerialName("hrac")
    HRAC("hrac", "HRAC"),

    /** Insecticide Resistance Action Committee. */
    @SerialName("irac")
    IRAC("irac", "IRAC"),

    /**
     * The product has no resistance classification by design — adjuvants,
     * surfactants, straight fertilisers, biostimulants. Distinct from "we don't
     * know yet", which is simply the absence of a group.
     */
    @SerialName("not_applicable")
    NOT_APPLICABLE("not_applicable", "Not applicable"),
    ;

    companion object {
        fun from(raw: String?): ChemicalActivityGroupScheme? {
            val v = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            return entries.firstOrNull { it.raw == v }
        }

        /**
         * The scheme implied by a product category, used only as a hint when an
         * authoritative source states a bare code without naming its scheme.
         */
        fun impliedByProductCategory(category: String): ChemicalActivityGroupScheme? =
            when (category.lowercase()) {
                "fungicide" -> FRAC
                "herbicide" -> HRAC
                "insecticide", "miticide", "acaricide", "nematicide" -> IRAC
                "adjuvant", "surfactant", "wetter", "foliarnutrient",
                "granularfertiliser", "liquidfertiliser", "fertigation",
                "seaweed", "humicfulvic", "biostimulant" -> NOT_APPLICABLE
                else -> null
            }
    }
}

/**
 * A single resistance/activity group: a scheme plus its code.
 *
 * This is the machine-readable unit the Resistance Engine will consume. It
 * deliberately has no free-text field — a display string like
 * `"11 (QoI / Strobilurin)"` is built for the UI on demand and is never the
 * stored source of truth.
 */
@Serializable
data class ChemicalActivityGroup(
    val scheme: ChemicalActivityGroupScheme = ChemicalActivityGroupScheme.NOT_APPLICABLE,
    /** Normalised code, e.g. `"3"`, `"11"`, `"M5"`, `"4A"`, `"G"`. */
    val code: String = "",
    /** Display sugar only — never parsed, never compared. */
    @SerialName("common_name") val commonName: String? = null,
) : Comparable<ChemicalActivityGroup> {

    val id: String get() = "${scheme.raw}:$code"

    /** `"FRAC 11 (QoI / Strobilurin)"` — display only. */
    val displayLabel: String
        get() = when {
            scheme == ChemicalActivityGroupScheme.NOT_APPLICABLE -> "No resistance group"
            commonName != null -> "${scheme.label} $code ($commonName)"
            else -> "${scheme.label} $code"
        }

    /** `"11"` — the bare code, for compact chips. */
    val shortLabel: String get() = code

    /**
     * A group is usable by the Resistance Engine only when it names a real
     * scheme and carries a code.
     */
    val isResistanceRelevant: Boolean
        get() = scheme != ChemicalActivityGroupScheme.NOT_APPLICABLE && code.isNotEmpty()

    private val numericPrefix: Int?
        get() = code.takeWhile { it.isDigit() }.takeIf { it.isNotEmpty() }?.toIntOrNull()

    /**
     * Scheme first, then numeric prefix, then the full code. `3` sorts before
     * `11`, and `11` before `M5`, regardless of the order the operator entered
     * them — so two identical products never persist as two different-looking
     * histories.
     */
    override fun compareTo(other: ChemicalActivityGroup): Int {
        if (scheme != other.scheme) return scheme.raw.compareTo(other.scheme.raw)
        val l = numericPrefix ?: Int.MAX_VALUE
        val r = other.numericPrefix ?: Int.MAX_VALUE
        if (l != r) return l.compareTo(r)
        return code.compareTo(other.code)
    }

    companion object {
        fun of(
            scheme: ChemicalActivityGroupScheme,
            code: String,
            commonName: String? = null,
        ): ChemicalActivityGroup = ChemicalActivityGroup(
            scheme = scheme,
            code = normaliseCode(code),
            commonName = commonName?.trim()?.takeIf { it.isNotEmpty() },
        )

        /**
         * Strips the noise humans and AI put around a code so `"Group 3"`,
         * `"group3"`, `" 3 "` and `"3"` all become `"3"`.
         */
        fun normaliseCode(raw: String): String {
            var value = raw.trim().uppercase()
            for (prefix in listOf("GROUP ", "GROUP", "FRAC ", "HRAC ", "IRAC ", "MOA ", "CODE ")) {
                if (value.startsWith(prefix)) value = value.removePrefix(prefix).trim()
            }
            // Drop a trailing parenthetical name: "11 (QoI)" -> "11".
            val paren = value.indexOf('(')
            if (paren >= 0) value = value.substring(0, paren).trim()
            return value.replace(" ", "")
        }

        /**
         * Best-effort reading of a legacy free-text `chemical_group` value such
         * as `"3 + 11"`, `"11 (QoI / Strobilurin)"` or `"Group 3/11"`.
         *
         * The result is explicitly a CANDIDATE, never authoritative. A chemical
         * whose groups came only from this parser stays unverified — the whole
         * point of Chemical Intelligence is that resistance decisions never rest
         * on a string somebody typed.
         */
        fun parseLegacyText(
            raw: String,
            assumedScheme: ChemicalActivityGroupScheme?,
        ): List<ChemicalActivityGroup> {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return emptyList()
            val scheme = assumedScheme ?: return emptyList()
            if (scheme == ChemicalActivityGroupScheme.NOT_APPLICABLE) return emptyList()
            val seen = mutableSetOf<String>()
            val out = mutableListOf<ChemicalActivityGroup>()
            for (part in trimmed.split('+', '/', ',', '&', ';')) {
                val code = normaliseCode(part)
                if (!isPlausibleCode(code) || !seen.add(code)) continue
                out += of(scheme, code)
            }
            return out
        }

        /**
         * A code is plausible when it looks like a resistance code rather than a
         * chemistry name. `"3"`, `"11"`, `"M5"`, `"4A"` and `"G"` pass;
         * `"STROBILURIN"` does not, so a legacy value that only ever held a
         * chemistry name yields no false groups.
         */
        fun isPlausibleCode(code: String): Boolean {
            if (code.isEmpty() || code.length > 4) return false
            if (!code.all { it.isLetterOrDigit() }) return false
            if (code.all { it.isLetter() }) return code.length == 1
            return code.any { it.isDigit() }
        }
    }
}

/**
 * De-duplicated, deterministically ordered groups.
 *
 * This is the collection the Resistance Engine reads. A two-active mix of FRAC 3
 * and FRAC 11 always yields `["3", "11"]` in that order, whichever order the
 * actives were entered.
 */
fun List<ChemicalActivityGroup>.canonicalised(): List<ChemicalActivityGroup> =
    distinctBy { it.id }.sorted()

/**
 * Bare codes for storage in a queryable `text[]` column, e.g. `["3", "11"]`.
 *
 * NEVER `["3 + 11"]`. A mixture counts as every one of its groups independently.
 */
fun List<ChemicalActivityGroup>.codes(): List<String> =
    canonicalised().filter { it.isResistanceRelevant }.map { it.code }

/** Scheme-qualified identifiers, e.g. `["frac:3", "frac:11"]`. */
fun List<ChemicalActivityGroup>.qualifiedCodes(): List<String> =
    canonicalised().filter { it.isResistanceRelevant }.map { it.id }

/**
 * The legacy `chemical_group` display projection, e.g. `"3 + 11"`.
 *
 * Derived FROM the structured groups for backwards compatibility. It is an
 * output, never an input: nothing in VineTrack may calculate from this string.
 */
fun List<ChemicalActivityGroup>.legacyGroupProjection(): String =
    codes().joinToString(" + ")
