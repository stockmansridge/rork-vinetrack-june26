package com.rork.vinetrack.data

import java.time.Instant

/**
 * Bounded in-memory fixed-code sync observations. Owner/vineyard identifiers
 * are retained only for filtering; they never appear in exported events.
 * There are no arbitrary strings, payloads, HTTP bodies, or auth secrets.
 * This is not a persistent server ACK audit trail.
 */
internal object SafeSyncDiagnosticHistory {
    private const val MAX_EVENTS = 250
    private data class Event(
        val at: String, val code: String, val ownerId: String,
        val vineyardId: String
    )
    private val entries = ArrayDeque<Event>()
    private val allowed = setOf(
        "PHASE5_ENTRY", "PHASE5_EXIT", "PHASE5_LEGACY",
        "PHASE5_FREEZE", "MANUAL_REFRESH", "RETRY_REQUESTED",
        "QUEUE_OBSERVED", "VINEYARD_REFRESH"
    )

    @Synchronized fun record(code: String, ownerId: String?, vineyardId: String?) {
        if (code !in allowed || ownerId.isNullOrBlank() || vineyardId.isNullOrBlank()) return
        if (entries.size >= MAX_EVENTS) entries.removeFirst()
        entries.addLast(Event(Instant.now().toString(), code, ownerId, vineyardId))
    }

    @Synchronized fun snapshot(ownerId: String, vineyardId: String): List<Map<String, String>> =
        entries.filter { it.ownerId == ownerId && it.vineyardId == vineyardId }
            .map { mapOf("timestamp" to it.at, "code" to it.code) }

    @Synchronized fun clear() { entries.clear() }
}
