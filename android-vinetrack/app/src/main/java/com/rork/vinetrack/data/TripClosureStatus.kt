package com.rork.vinetrack.data

/**
 * P0 3.1.9 Phase C: derives whether a Trip may be reported as CLOSED_SYNCED.
 *
 * A Trip is CLOSED_SYNCED only when the terminal server state is confirmed and every
 * required dependent (Trip/tank/GPS/end markers, occurrence operations, tank actuals,
 * the linked spray record and required tank sessions) is acknowledged. A Trip ended on
 * this device but not yet acknowledged is LOCAL_END_PENDING, never "synced". The result
 * is display/diagnostic only: it never acknowledges, clears or replays anything.
 */
object TripClosureStatus {
    enum class State(val code: String) {
        ACTIVE("ACTIVE"),
        LOCAL_END_PENDING("LOCAL_END_PENDING"),
        SERVER_STATE_UNCONFIRMED("SERVER_STATE_UNCONFIRMED"),
        DEPENDENTS_PENDING("ENDED_DEPENDENTS_PENDING"),
        DEPENDENTS_HELD("ENDED_DEPENDENTS_HELD"),
        CLOSED_SYNCED("CLOSED_SYNCED"),
    }

    /** Source of the terminal-state evidence. */
    enum class ServerEvidence(val code: String) {
        /** A fresh server read in this check returned the row. */
        FRESH_READ("fresh_server_read"),
        /** The local row was set ended only by an acknowledged End (no fresh read). */
        ACKED_LOCAL_ROW("acknowledged_local_row"),
        /** A fresh read was attempted and failed. */
        READ_FAILED("server_read_failed"),
        /** A fresh read returned no live row (absent or soft-deleted). */
        ABSENT("server_row_absent"),
    }

    data class Marker(val entityType: String, val status: String)

    data class Input(
        val tripId: String,
        val evidence: ServerEvidence,
        /** Terminal fields from the evidence source; ignored when evidence is READ_FAILED/ABSENT. */
        val serverIsActive: Boolean,
        val serverEndTime: String?,
        /** Session ids present on the evidence row; null when unreadable. */
        val serverSessionIds: Set<String>?,
        val locallyEnded: Boolean,
        /** Unresolved outbox markers for this Trip or its linked spray record. */
        val unresolvedMarkers: List<Marker>,
        /** Pending occurrence operations; null when the journal is unreadable. */
        val occurrencePending: Int?,
        val occurrenceHeldReason: String?,
        /** All local tank actuals for the Trip with their pending flag. */
        val actualSessionIds: Set<String>,
        val pendingActualIds: List<String>,
        val holdCodes: List<String>,
    )

    data class Result(val state: State, val reasons: List<String>) {
        val isClosedSynced: Boolean get() = state == State.CLOSED_SYNCED
    }

    private val blockingStatuses = setOf("failed", "blocked")

    fun normalized(id: String): String = id.trim().lowercase()

    fun evaluate(input: Input): Result {
        val reasons = mutableListOf<String>()
        val required = input.actualSessionIds.map(::normalized).toSet()
        val serverSessions = input.serverSessionIds?.map(::normalized)?.toSet()
        if (input.locallyEnded) reasons += "END_NOT_ACKNOWLEDGED"
        input.unresolvedMarkers.forEach { reasons += "MARKER_${it.entityType.uppercase()}_${it.status.uppercase()}" }
        when {
            input.occurrencePending == null -> reasons += "OCCURRENCE_JOURNAL_UNREADABLE"
            input.occurrencePending > 0 -> reasons += "OCCURRENCE_OPERATIONS_PENDING_${input.occurrencePending}"
        }
        input.occurrenceHeldReason?.let { reasons += "OCCURRENCE_HELD" }
        if (input.pendingActualIds.isNotEmpty()) reasons += "TANK_ACTUALS_PENDING_${input.pendingActualIds.size}"
        input.holdCodes.forEach { reasons += it }
        if (required.isNotEmpty()) when {
            serverSessions == null -> reasons += TankDependencyVerification.REQUIRED_SESSIONS_UNREADABLE
            !serverSessions.containsAll(required) -> reasons += TankDependencyVerification.REQUIRED_SESSION_MISSING
        }

        if (input.locallyEnded) return Result(State.LOCAL_END_PENDING, reasons)
        when (input.evidence) {
            ServerEvidence.READ_FAILED -> return Result(State.SERVER_STATE_UNCONFIRMED, reasons + "SERVER_READ_FAILED")
            ServerEvidence.ABSENT -> return Result(State.SERVER_STATE_UNCONFIRMED, reasons + "SERVER_ROW_ABSENT")
            else -> Unit
        }
        if (input.serverIsActive || input.serverEndTime.isNullOrBlank()) return Result(State.ACTIVE, reasons)
        val held = input.unresolvedMarkers.any { it.status.lowercase() in blockingStatuses } ||
            input.occurrencePending == null || input.occurrenceHeldReason != null || input.holdCodes.isNotEmpty() ||
            (required.isNotEmpty() && (serverSessions == null || !serverSessions.containsAll(required)))
        if (held) return Result(State.DEPENDENTS_HELD, reasons)
        if (reasons.isNotEmpty()) return Result(State.DEPENDENTS_PENDING, reasons)
        return Result(State.CLOSED_SYNCED, emptyList())
    }

    fun diagnosticLines(tripId: String, input: Input, result: Result): List<String> = listOf(
        "trip_closure: trip=$tripId state=${result.state.code} evidence=${input.evidence.code}",
        "  server_terminal: active=${input.serverIsActive}; end_time_set=${!input.serverEndTime.isNullOrBlank()}",
        "  locally_ended: ${input.locallyEnded}",
        "  unresolved_markers: ${input.unresolvedMarkers.size}",
        "  occurrence_pending: ${input.occurrencePending ?: "unreadable"}; held=${input.occurrenceHeldReason != null}",
        "  tank_actuals: total_sessions=${input.actualSessionIds.size}; pending=${input.pendingActualIds.size}",
        "  server_sessions: ${input.serverSessionIds?.size ?: "unreadable"}",
        "  reasons: ${result.reasons.ifEmpty { listOf("none") }.joinToString(",")}",
    )
}
