package com.rork.vinetrack.data

/**
 * Decides which vineyard the user should be working in.
 *
 * The **active** vineyard (what the user opened and is working in right now)
 * is a different thing from their profile **Default Vineyard** (where a brand
 * new session starts). Conflating the two is what made Android snap back to
 * default vineyard A after a screen lock while the user was in vineyard B.
 *
 * Pure and dependency-free so the whole contract is unit-testable.
 */
object ActiveVineyardResolver {

    /**
     * Resolution inputs.
     *
     * @param memberIds vineyards the user is currently known to belong to.
     *   Built from the server list when online, or the local cache offline —
     *   never empty-by-default, because an empty set would look like "lost
     *   access to everything".
     * @param persistedActiveId the last active vineyard persisted for this user.
     * @param defaultId the profile Default Vineyard, if any.
     * @param firstAvailableId fallback when nothing else resolves.
     * @param liveSelectionId the vineyard currently shown in the UI. Used only
     *   when [isStale] — i.e. the user switched while this resolution was in
     *   flight.
     * @param isStale true when the user made an explicit vineyard choice after
     *   this resolution started.
     */
    data class Input(
        val memberIds: Set<String>,
        val persistedActiveId: String?,
        val defaultId: String?,
        val firstAvailableId: String?,
        val liveSelectionId: String? = null,
        val isStale: Boolean = false,
    )

    /**
     * Apply the active-vineyard contract:
     *
     * 1. A newer explicit user choice always wins — a late profile/default
     *    response can never drag the user out of the vineyard they just opened.
     * 2. Otherwise the persisted active vineyard, when still locally valid.
     * 3. Otherwise the profile Default Vineyard (first login, or the previous
     *    active vineyard is no longer accessible).
     * 4. Otherwise the first vineyard available.
     *
     * Connectivity is deliberately absent: being offline is never a reason to
     * invalidate the cached active vineyard. Callers pass a [Input.memberIds]
     * built from cached data when offline.
     */
    fun resolve(input: Input): String? {
        if (input.isStale) {
            val live = input.liveSelectionId
            if (live != null && live in input.memberIds) return live
        }
        input.persistedActiveId?.let { persisted ->
            if (persisted in input.memberIds) return persisted
        }
        input.defaultId?.let { default ->
            if (default in input.memberIds) return default
        }
        return input.firstAvailableId
    }
}
