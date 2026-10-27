package com.rork.vinetrack.data

/**
 * Bounded speculative decode reuse, never a storage or durability authority.
 * Callers must reread storage on EVERY load and supply its exact current bytes.
 * Failed decodes are not retained. Decoding happens outside the short map lock.
 */
internal class ExactBytesDecodeMemo<T : Any>(
    private val maxSourceBytes: Long = 24L * 1024 * 1024,
    private val maxEntries: Int = 4,
) {
    private val entries = LinkedHashMap<String, T>(4, 0.75f, true)
    private var sourceBytes = 0L

    fun decode(raw: String, canRetain: (T) -> Boolean = { true }, decoder: (String) -> T): T {
        synchronized(entries) { entries[raw]?.let { return it } }
        val value = decoder(raw)
        val cost = raw.length.toLong() * 2
        if (cost > maxSourceBytes || maxEntries <= 0 || !canRetain(value)) return value
        synchronized(entries) {
            entries[raw]?.let { return it }
            while (entries.isNotEmpty() && (sourceBytes + cost > maxSourceBytes || entries.size >= maxEntries)) {
                val oldest = entries.entries.iterator()
                sourceBytes -= oldest.next().key.length.toLong() * 2
                oldest.remove()
            }
            entries[raw] = value
            sourceBytes += cost
        }
        return value
    }
}
