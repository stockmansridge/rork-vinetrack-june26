package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Vineyard

/** Data and timestamp from the same owner-matched preference snapshot. */
class VineyardCacheHydration(val rows: List<Vineyard>, val syncedAt: Long, internal val sourceRaw: String?) {
    /** Reject speculative hydration after a cache clear, owner change or newer save. */
    fun matchesSource(expectedOwner: String?, currentOwner: String?, currentRaw: String?, currentTimestamp: Long?): Boolean =
        expectedOwner == currentOwner && sourceRaw == currentRaw && syncedAt == currentTimestamp
}
