package com.rork.vinetrack.data.chemical

/**
 * Whether a label's crop wording means GRAPEVINES.
 *
 * Device mirror of the canonical server predicate `isGrapevineCrop` in
 * `supabase/functions/chemical-info-lookup/grapevine_label.ts`, and of the iOS
 * `ChemicalGrapevineCrop`. All three must agree exactly: the server decides
 * which directions land in `grapevine_uses`, and a client that partitions the
 * same label differently would show, save or dose off a use the server never
 * classified as viticultural.
 *
 * # Why this is not a substring test
 *
 * `"GRAPEFRUIT"` contains `"grape"`. A naive `contains("grape")` therefore
 * classifies a citrus as a grapevine, which puts a citrus rate on a vineyard
 * spray record — a wrong dose wearing a plausible name, which is worse than a
 * visible gap. Matching is whole-token and adjacent-pair only.
 */
object ChemicalGrapevineCrop {

    /** Crop wording that means grapevines, as WHOLE tokens. */
    private val TOKENS: Set<String> = setOf(
        "grape",
        "grapes",
        "grapevine",
        "grapevines",
        "vine",
        "vines",
        "vineyard",
        "vineyards",
        "winegrape",
        "winegrapes",
        "tablegrape",
        "tablegrapes",
    )

    /**
     * Multi-word crop wordings that mean grapevines.
     *
     * Checked as adjacent token PAIRS, so `"WINE GRAPES"`, `"TABLE GRAPES"` and
     * `"DRIED GRAPES"` resolve without letting a bare `"wine"` or `"dried"`
     * through on its own.
     */
    private val PHRASES: Set<String> = setOf(
        "wine grape",
        "wine grapes",
        "table grape",
        "table grapes",
        "dried grape",
        "dried grapes",
        "grape vine",
        "grape vines",
    )

    /** VineTrack's single normalised crop class for everything above. */
    const val CROP_CLASS: String = "Grapevines"

    private val SEPARATOR = Regex("[^a-z0-9]+")

    /** Split crop wording into lowercase alphanumeric tokens. */
    fun cropTokens(crop: String?): List<String> =
        crop.orEmpty().lowercase().split(SEPARATOR).filter { it.isNotEmpty() }

    /**
     * Whether this crop wording means grapevines.
     *
     * `GRAPEFRUIT` must never match: it is a citrus, and a citrus rate on a
     * vineyard record is a wrong dose with a plausible name.
     */
    fun matches(crop: String?): Boolean {
        val tokens = cropTokens(crop)
        if (tokens.isEmpty()) return false
        if (tokens.any { it in TOKENS }) return true
        for (i in 0 until tokens.size - 1) {
            if ("${tokens[i]} ${tokens[i + 1]}" in PHRASES) return true
        }
        return false
    }
}
