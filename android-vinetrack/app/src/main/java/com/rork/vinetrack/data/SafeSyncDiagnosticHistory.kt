package com.rork.vinetrack.data

import java.time.Instant

/**
 * Fixed-code in-memory sync event timeline. No raw messages, body data, IDs,
 * auth data, coordinates, URLs or chemical records are ever accepted.
 * This is observation-only, not a server ACK ledger.
 */
internal object SafeSyncDiagnosticHistory {
    private const val MAX_EVENTS = 250
    private data class Event(val at: String, val code: String, val count: Int)
    private val entries = ArrayDeque<Event>()
    private val allowed = setOf(
        "PHASE5_ENTRY", "PHASE5_EXIT", "PHASE5_LEGACY",
        "PHASE5_FREEZE", "MANUAL_REFRESH", "RETRY_REQUESTED",
        "QUEUE_OBSERVED", "VINEYARD_REFRESH"
    )

    @Synchronized fun record(code: String, count: Int = 0) {
        if (code !in allowed) return
        if (entries.size >= MAX_EVENTS) entries.removeFirst()
        entries.addLast(Event(Instant.now().toString(), code, count.coerceAtLeast(0)))
    }

    @Synchronized fun snapshot(): List<Map<String, String>> =
        entries.map { mapOf("timestamp" to it.at, "code" to it.code, "count" to it.count.toString()) }

    @Synchronized fun clear() { entries.clear() }
}
