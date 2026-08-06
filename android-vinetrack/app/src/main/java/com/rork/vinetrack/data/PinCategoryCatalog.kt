package com.rork.vinetrack.data

/**
 * Canonical pin-category colour contract, shared verbatim with iOS
 * (`PinCategoryCatalog.swift`). Pin colours are derived deterministically
 * from the pin's *stable category id* — never from the vineyard's editable
 * button configuration, a translated/display label comparison, or an
 * arbitrary colour token stored on the row. This guarantees two pins of the
 * same category always render identically on every device and platform.
 *
 * Stable ids and their canonical colour tokens:
 *  - `irrigation`  → blue
 *  - `broken_post` → brown
 *  - `vine_issue`  → green
 *  - `broken_wire` → orange
 *  - `other`       → gray
 *  - unknown / missing category → gray ("Unassigned")
 *
 * Historical rows store the category as free text (e.g. "Vine Issue"), so
 * [canonicalId] normalises the stored value structurally (case, whitespace,
 * punctuation) into the stable id. Unrecognised values resolve to `null`
 * (unknown) and render as the neutral unassigned gray — they never crash and
 * never inherit another category's colour.
 */
object PinCategoryCatalog {

    const val IRRIGATION = "irrigation"
    const val BROKEN_POST = "broken_post"
    const val VINE_ISSUE = "vine_issue"
    const val BROKEN_WIRE = "broken_wire"
    const val OTHER = "other"

    /** Neutral colour token used for unknown/unassigned categories. */
    const val UNASSIGNED_COLOR = "gray"

    /** Every stable id the catalogue recognises. */
    val allIds: Set<String> = setOf(IRRIGATION, BROKEN_POST, VINE_ISSUE, BROKEN_WIRE, OTHER)

    private val nonAlphanumeric = Regex("[^a-z0-9]+")

    /**
     * Normalise a stored category/button value into its stable canonical id.
     * Returns `null` for blank or unrecognised values (unknown category).
     * The normalisation is structural only (lowercase, punctuation/whitespace
     * folded to `_`) — it never compares translated display labels.
     */
    fun canonicalId(raw: String?): String? {
        val normalized = raw
            ?.trim()
            ?.lowercase()
            ?.replace(nonAlphanumeric, "_")
            ?.trim('_')
            ?.takeIf { it.isNotBlank() }
            ?: return null
        return normalized.takeIf { it in allIds }
    }

    /**
     * Canonical colour token for a stable category id. Unknown or missing ids
     * resolve to [UNASSIGNED_COLOR] so historical records without a category
     * always display as neutral gray, never a misleading category colour.
     */
    fun colorToken(canonicalId: String?): String = when (canonicalId) {
        IRRIGATION -> "blue"
        BROKEN_POST -> "brown"
        VINE_ISSUE -> "green"
        BROKEN_WIRE -> "orange"
        OTHER -> UNASSIGNED_COLOR
        else -> UNASSIGNED_COLOR
    }

    /** Convenience: raw stored value → canonical colour token in one step. */
    fun colorTokenForRaw(raw: String?): String = colorToken(canonicalId(raw))
}
