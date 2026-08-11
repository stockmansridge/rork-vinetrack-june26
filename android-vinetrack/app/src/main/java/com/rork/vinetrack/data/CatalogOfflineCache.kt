package com.rork.vinetrack.data

import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json

/**
 * Pure helpers behind the clone/rootstock catalogue offline cache (audit #10).
 *
 * Supabase remains the single source of truth for the shared catalogues
 * (sql/182). This object only implements the local fallback contract used by
 * [DomainCacheStore] / AppViewModel:
 *
 *  * a successful server read is ALWAYS authoritative — including an empty
 *    result — and is written through to the cache;
 *  * when the server is unreachable, the current in-memory copy is kept
 *    (mid-session offline drop never blanks a picker);
 *  * on an offline cold restart (no in-memory copy yet), the last
 *    successfully cached snapshot hydrates the pickers instead of leaving
 *    them empty.
 *
 * Kept pure (no Android dependencies) so the restart/offline/refresh contract
 * is unit-testable on the JVM.
 */
object CatalogOfflineCache {

    /** Outcome of one catalogue list resolution, with provenance flags. */
    data class Resolution<T>(
        val entries: List<T>,
        val fromServer: Boolean,
        val fromCache: Boolean,
    )

    /**
     * Resolve one catalogue list through the ladder
     * `server → in-memory state → persisted cache → empty`.
     *
     * [server] is null when the fetch failed (offline / error) — an EMPTY
     * server list is a valid authoritative read and wins. [cached] is null
     * when no snapshot was ever persisted (or it belongs to another user).
     */
    fun <T> resolve(server: List<T>?, inMemory: List<T>, cached: List<T>?): Resolution<T> = when {
        server != null -> Resolution(server, fromServer = true, fromCache = false)
        inMemory.isNotEmpty() -> Resolution(inMemory, fromServer = false, fromCache = false)
        else -> Resolution(cached ?: emptyList(), fromServer = false, fromCache = cached != null)
    }

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Encode a catalogue list for persistence (same config the domain cache uses). */
    fun <T> encode(serializer: KSerializer<List<T>>, entries: List<T>): String =
        json.encodeToString(serializer, entries)

    /**
     * Decode a persisted catalogue payload. Null (never written) and corrupt
     * payloads both come back as an empty list — the cache must never crash
     * a cold start.
     */
    fun <T> decode(serializer: KSerializer<List<T>>, raw: String?): List<T> {
        if (raw == null) return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    }
}
