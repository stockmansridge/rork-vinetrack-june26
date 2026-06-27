package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for the trip-END summary only (Tier-A Stage
 * B-2-1), for an existing active server trip: the operator finished the trip
 * offline (or a transient online end failed) and the server row is still
 * active. Exactly one coalesced [PendingEntityType.TRIP_END] / UPDATE MARKER
 * per trip ([PendingWrite.clientId] = tripId) records the end summary scalars
 * (completion notes, end engine hours, requested end time). The marker never
 * carries path points, row coverage, tank sessions, metadata or fuel logs.
 *
 * DEPENDENCY GATE (mandatory): a TRIP_END marker is only finalised once every
 * unresolved same-trip dependency marker has cleared — [PendingEntityType.TRIP_START]
 * (the server row must exist first), [PendingEntityType.TRIP_GPS],
 * [PendingEntityType.TRIP_ROW], [PendingEntityType.TRIP_TANK] and the relevant
 * [PendingEntityType.TRIP_METADATA]. While any of those still exists (pending,
 * in-progress, failed or blocked) the end marker is deferred (left retry-eligible
 * without consuming an attempt), so the trip is never ended with stale GPS / row
 * / tank / metadata state frozen in. The GPS marker in particular lands the full
 * captured path BEFORE the end derives its final state.
 *
 * Final-state derivation (never stale): once dependencies are clear the live
 * server trip is fetched and `path_points` / `total_distance` for the end PATCH
 * are taken from that LIVE server row (the GPS marker has already pushed the
 * latest path), not from a stale local array. The end PATCH carries only the
 * existing end fields (`is_active=false`, `is_paused=false`, `end_time`,
 * `total_distance`, `path_points`, `completion_notes`, `end_engine_hours` and
 * the sync stamp) — never row coverage or tank arrays.
 *
 * Conflict / safety: a missing / soft-deleted server trip is blocked; an
 * already-ended server trip means the work is done, so the marker is removed
 * safely; transient failures retry up to a cap; permanent failures and corrupt
 * payloads block.
 */
class TripEndSync(
    private val tripRepo: TripRepository,
    private val pending: PendingWriteRepository,
    private val activeTripStore: ActiveTripStore,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Lightweight trip-end marker. Carries only the end summary scalars and a
     * baseline stamp — never the path, coverage or tank arrays (those land via
     * their own dependency markers / the live server row). [baseClientUpdatedAt]
     * captures the trip's sync stamp when the marker was first queued; it is
     * informational and preserved across coalescing.
     */
    @Serializable
    data class Payload(
        val tripId: String,
        val completionNotes: String? = null,
        val endEngineHours: Double? = null,
        val requestedEndTime: String,
        val baseClientUpdatedAt: String? = null,
        val clientUpdatedAt: String,
        val savedAt: Long,
    )

    /** Same-trip markers that must clear before an end marker may finalise. */
    private val dependencyTypes = setOf(
        PendingEntityType.TRIP_START,
        PendingEntityType.TRIP_GPS,
        PendingEntityType.TRIP_ROW,
        PendingEntityType.TRIP_TANK,
        PendingEntityType.TRIP_METADATA,
    )

    /**
     * Queue (or refresh) the single trip-end marker for [trip]. Coalesces by
     * trip: any earlier unresolved marker for the same trip is removed first so
     * only one marker per trip ever exists. The earliest known baseline stamp
     * from a still-pending earlier marker is preserved. The latest end summary
     * scalars (notes / engine hours / requested end time) win. Returns the row.
     */
    fun enqueue(
        trip: Trip,
        completionNotes: String?,
        endEngineHours: Double?,
        requestedEndTime: String,
    ): PendingWrite {
        val tripId = trip.id
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.TRIP_END &&
                it.opType == PendingOpType.UPDATE &&
                it.clientId == tripId &&
                it.status != PendingWriteStatus.SYNCED
        }
        val decoded = existing
            .mapNotNull { runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull() }
        val preservedStamp = decoded.firstNotNullOfOrNull { it.baseClientUpdatedAt }
            ?: trip.clientUpdatedAt
        existing.forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
            Payload.serializer(),
            Payload(
                tripId = tripId,
                completionNotes = completionNotes,
                endEngineHours = endEngineHours,
                requestedEndTime = requestedEndTime,
                baseClientUpdatedAt = preservedStamp,
                clientUpdatedAt = java.time.Instant.now().toString(),
                savedAt = System.currentTimeMillis(),
            ),
        )
        return pending.enqueue(
            entityType = PendingEntityType.TRIP_END,
            opType = PendingOpType.UPDATE,
            payloadJson = payload,
            clientId = tripId,
        )
    }

    /**
     * Replay every retry-eligible trip-end marker. No-ops (returns) if a replay
     * is already running. For each marker: mark in-progress, decode (block if
     * corrupt), then resolve the outcome:
     *  - unresolved same-trip dependency markers still exist -> DEFER (leave
     *    retry-eligible, no attempt consumed), never finalise,
     *  - server trip missing/deleted -> blocked,
     *  - server trip already ended -> work done, remove the marker,
     *  - otherwise PATCH the end using the LIVE server path/distance plus the
     *    marker summary; on success remove the marker and fire [onSynced],
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_END &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved trip end.")
                    continue
                }
                // Mandatory dependency gate: never finalise while same-trip GPS,
                // row, tank or metadata work is still unresolved — otherwise the
                // end would freeze stale state. Defer without consuming a retry
                // attempt so a legitimately-waiting end can't exhaust its cap.
                if (hasUnresolvedDependencies(payload.tripId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this trip's other changes to sync first.",
                    )
                    continue
                }
                try {
                    val server = tripRepo.fetchTrip(payload.tripId)
                    if (server == null) {
                        pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "This trip no longer exists.")
                        continue
                    }
                    if (!server.isActive) {
                        // Already ended elsewhere (or a prior replay landed) —
                        // the end work is done, drop the marker safely.
                        pending.remove(write.id)
                        continue
                    }
                    // Final path/distance come from the LIVE server row (the GPS
                    // dependency marker has already landed the latest path), never
                    // from a stale local array.
                    val trip = tripRepo.endTrip(
                        id = payload.tripId,
                        pathPoints = server.pathPoints.orEmpty(),
                        totalDistance = server.totalDistance ?: 0.0,
                        completionNotes = payload.completionNotes,
                        endEngineHours = payload.endEngineHours,
                        endTime = payload.requestedEndTime,
                    )
                    pending.remove(write.id)
                    onSynced(trip)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to finish the trip.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The trip end was rejected (${e.code}).",
                        )
                    }
                } catch (e: Exception) {
                    retryOrBlock(write, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    /**
     * True when any same-trip dependency marker (GPS / row / tank / metadata) is
     * still unresolved (pending, in-progress, failed or blocked). A blocked
     * dependency also counts — the end must wait for the operator to resolve it
     * rather than finalise with unsynced progress.
     */
    private fun hasUnresolvedDependencies(tripId: String): Boolean =
        pending.list().any {
            it.clientId == tripId &&
                it.entityType in dependencyTypes &&
                it.status in PendingWriteStatus.unresolved
        }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        /** Cap retries so a persistently-failing marker can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
