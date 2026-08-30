package com.rork.vinetrack.data.chemical

/**
 * The one place VineTrack tells an operator how long a chemical search takes.
 *
 * # Why this is a contract and not a string in the sheet
 *
 * A first-time registered-product lookup queries the national register,
 * fetches the approved label PDF, extracts its Directions For Use table and
 * runs a web-research pass. That can take real time and it is the CORRECT
 * behaviour — but an operator watching a spinner with no stated duration
 * reasonably concludes the app has hung, backs out, and thereby abandons the
 * very request that would have populated the product.
 *
 * The strings are pinned here so tests can assert the SAME sentences reach
 * every entry point, and so Android and iOS stay word-for-word aligned
 * (mirrors the iOS `ChemicalLookupDurationNotice`).
 *
 * # Deliberately not a warning
 *
 * Nothing has gone wrong: the lookup is working. The advisory renders in
 * VineTrack green — never amber or red — because dressing "this is slow on
 * purpose" as a fault teaches operators to distrust a result that is about to
 * be correct. It never shows a fake percentage or a made-up completion time,
 * and a slow lookup is never auto-failed into manual entry.
 */
object ChemicalLookupAdvisory {

    /** Shown near the search control before/while no request is running. */
    const val IDLE_TEXT: String =
        "Chemical search can take a little time while VineTrack checks current " +
            "registration and label information."

    /** Shown while a search or product-detail lookup is actively running. */
    const val SEARCHING_TEXT: String =
        "Searching current registration and label information — this can take a " +
            "little time. Please keep this screen open."

    /** Secondary reassurance under the idle advisory. */
    const val REPEAT_HINT_TEXT: String =
        "Repeat lookups are usually faster once the product has been loaded."

    /** The advisory in force for the given activity state. */
    fun text(isSearching: Boolean): String = if (isSearching) SEARCHING_TEXT else IDLE_TEXT

    /**
     * Whether a new search may start.
     *
     * False while one is already running — duplicate Search taps must never
     * fire a second request — and false without a vineyard country, because
     * registration is country-scoped law and searching a guessed register
     * would verify the wrong label (fail closed, mirroring iOS).
     */
    fun canStartSearch(query: String, isSearching: Boolean, countryCode: String): Boolean =
        query.trim().isNotEmpty() && !isSearching && countryCode.isNotBlank()
}
