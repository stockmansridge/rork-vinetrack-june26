package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Vineyard
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Memoizes only the immutable, flat Vineyard model. Other domain models contain
 * nested lists and are deliberately excluded. Strings are checked exactly;
 * encoding never determines whether a preferences edit or timestamp is needed.
 */
class VineyardCacheCodec(
    private val onTiming: ((VineyardCacheTiming) -> Unit)? = null,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(Vineyard.serializer())
    private val maximumCharacters = 1024 * 1024
    private var decodedRaw: String? = null
    private var decodedRows: List<Vineyard>? = null
    private var encodedRows: List<Vineyard>? = null
    private var encodedRaw: String? = null

    @Synchronized
    fun decode(raw: String?): List<Vineyard> {
        val start = System.nanoTime()
        if (raw == null) {
            decodedRaw = null
            decodedRows = null
            return emptyList()
        }
        val reused = decodedRaw == raw && decodedRows != null
        val rows = if (reused) decodedRows.orEmpty() else {
            // Preserve the existing empty-list fallback on malformed JSON.
            runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
        }
        if (raw.length <= maximumCharacters) {
            decodedRaw = raw
            decodedRows = rows.toList()
        } else {
            decodedRaw = null
            decodedRows = null
        }
        val result = rows.toList()
        onTiming?.invoke(VineyardCacheTiming("decode", result.size, raw.toByteArray(Charsets.UTF_8).size,
            System.nanoTime() - start, reused))
        return result
    }

    @Synchronized
    fun encode(rows: List<Vineyard>, persistedRaw: String?): String {
        val start = System.nanoTime()
        // Kotlin data-class equality includes every constructor property;
        // Double.equals distinguishes signed zero and String.equals is exact.
        val reused = encodedRows == rows && encodedRaw != null
        val raw = if (reused) requireNotNull(encodedRaw) else json.encodeToString(serializer, rows)
        if (raw.length <= maximumCharacters) {
            encodedRows = rows.toList()
            encodedRaw = raw
        } else {
            encodedRows = null
            encodedRaw = null
        }
        onTiming?.invoke(VineyardCacheTiming("encode", rows.size, raw.toByteArray(Charsets.UTF_8).size,
            System.nanoTime() - start, reused, persistedRaw?.let { it != raw }))
        return raw
    }
}
