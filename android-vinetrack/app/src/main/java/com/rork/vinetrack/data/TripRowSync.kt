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
 * Offline replay coordinator for trip ROW-COVERAGE progress only (Tier-A Stage
 * D-1), for an existing active server trip: the operator-driven Mark complete /
 * Skip / Undo actions that move `completed_paths`, `skipped_paths` and
 * `sequence_index`.
 *
 * Like the Stage C-1 GPS marker, the outbox row is NOT the source of the
 * coverage data: a burst of row taps would bloat the outbox if one row were
 * queued per action. Instead a single coalesced [PendingEntityType.TRIP_ROW] /
 * UPDATE MARKER per trip ([PendingWrite.clientId] = tripId) records only that
 * the trip has unsynced coverage progress. The coverage state itself is read
 * from the Stage A active-trip snapshot ([ActiveTripStore]) at replay time.
 *
 * Discriminator: TRIP_ROW / UPDATE so it never collides with the Stage B-1
 * scalar metadata queue ([PendingEntityType.TRIP_METADATA]), the Stage C-1 GPS
 * marker ([PendingEntityType.TRIP_GPS]), the broad [PendingEntityType.TRIP]
 * reserved for later trip start/end work, or any future tank-session stream.
 *
 * Merge strategy (conservative, deterministic, never destructive): the live
 * server trip is fetched, the local snapshot coverage is read, and the two are
 * UNION-merged. Completed and skipped path sets are unioned; if a path appears
 * in both, completed wins (it is dropped from the merged skipped set). A server
 * completed path is never removed; a server skipped path is removed only when it
 * is also in the merged completed set. `sequence_index` is never moved backwards
 * versus the server (the chosen index is the max of server vs local), and
 * current/next row are re-derived from the chosen index against the server's
 * planned `row_sequence`. When the merge adds nothing over the server state, the
 * marker is removed without a PATCH. The coverage PATCH touches only
 * `completed_paths`, `skipped_paths`, `sequence_index`, the derived
 * current/next row and the sync stamp — never path points, distance, metadata,
 * row-plan setup, tank sessions, engine hours, or trip start/end/delete fields.
 *
 * Conflict / safety: a missing / soft-deleted / no-longer-active server trip is
 * blocked; a missing or mismatched local snapshot means there is no local work
 * to replay, so the marker is safely removed; transient failures retry up to a
 * cap; permanent failures and corrupt payloads block.
 */
class TripRowSync(
    private val tripRepo: TripRepository,
    private val pending: PendingWriteRepository,
    private val activeTripStore: ActiveTripStore,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Lightweight row-coverage marker. Carries only the trip id and baseline
     * bookkeeping — never the completed/skipped arrays themselves (those live in
     * the Stage A snapshot). [baseCompletedCount] / [baseSkippedCount] /
     * [baseSequenceIndex] / [baseClientUpdatedAt] capture the progress baseline
     * when the marker was first queued; they are informational and preserved
     * across coalescing.
     */
    @Serializable
    data class Payload(
        val tripId: String,
        val baseCompletedCount: Int = 0,
        val baseSkippedCount: Int = 0,
        val baseSequenceIndex: Int = 0,
        val baseClientUpdatedAt: String? = null,
        val clientUpdatedAt: String,
        val savedAt: Long,
    )

    /**
     * Queue (or refresh) the single row-coverage marker for [trip]. Coalesces by
     * trip: any earlier unresolved marker for the same trip is removed first so
     * only one marker per trip ever exists. The earliest known baseline values
     * from a still-pending earlier marker are preserved so repeated offline row
     * actions never move the baseline forward. Returns the row.
     */
    fun enqueue(trip: Trip): PendingWrite {
        val tripId = trip.id
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.TRIP_ROW &&
                it.opType == PendingOpType.UPDATE &&
                it.clientId == tripId &&
                it.status != PendingWriteStatus.SYNCED
        }
        val decoded = existing
            .mapNotNull { runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull() }
        val firstPayload = decoded.firstOrNull()
        val preservedCompleted = firstPayload?.baseCompletedCount ?: (trip.completedPaths?.size ?: 0)
        val preservedSkipped = firstPayload?.baseSkippedCount ?: (trip.skippedPaths?.size ?: 0)
        val preservedIndex = firstPayload?.baseSequenceIndex ?: trip.sequenceIndex
        val preservedStamp = decoded.firstNotNullOfOrNull { it.baseClientUpdatedAt }
            ?: trip.clientUpdatedAt
        existing.forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
            Payload.serializer(),
            Payload(
                tripId = tripId,
                baseCompletedCount = preservedCompleted,
                baseSkippedCount = preservedSkipped,
                baseSequenceIndex = preservedIndex,
                baseClientUpdatedAt = preservedStamp,
                clientUpdatedAt = java.time.Instant.now().toString(),
                savedAt = System.currentTimeMillis(),
            ),
        )
        return pending.enqueue(
            entityType = PendingEntityType.TRIP_ROW,
            opType = PendingOpType.UPDATE,
            payloadJson = payload,
            clientId = tripId,
        )
    }

    /**
     * Replay every retry-eligible row-coverage marker. No-ops (returns) if a
     * replay is already running. For each marker: mark in-progress, decode (block
     * if corrupt), read the local snapshot coverage, then resolve the outcome:
     *  - no matching local snapshot -> nothing to replay, remove the marker,
     *  - server trip missing/deleted -> blocked,
     *  - server trip no longer active -> blocked,
     *  - merged coverage adds nothing over the server -> remove the marker,
     *  - otherwise PATCH the merged coverage; on success remove the marker and
     *    fire [onSynced],
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_ROW &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved row coverage.")
                    continue
                }
                // Stage B-3-1 gate: never write to a trip whose server row
                // hasn't been created yet (offline start). Defer without
                // consuming a retry attempt until its TRIP_START marker clears.
                if (TripStartSync.Dependency.hasUnresolvedStart(pending, payload.tripId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this trip to finish starting.",
                    )
                    continue
                }
                // The captured coverage lives in the Stage A snapshot. No matching
                // snapshot means there is no local work to replay (e.g. ended on
                // this device, or a different trip is now active) — remove the
                // marker safely rather than invent coverage data.
                val local = localCoverageFor(payload.tripId)
                if (local == null) {
                    pending.remove(write.id)
                    continue
                }
                try {
                    val server = tripRepo.fetchTrip(payload.tripId)
                    if (server == null) {
                        pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "This trip no longer exists.")
                        continue
                    }
                    if (!server.isActive) {
                        pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "This trip was finished elsewhere. Open it to review.",
                        )
                        continue
                    }
                    val merged = mergeCoverage(server, local)
                    if (merged == null) {
                        // Merge could not be proven safe (would shrink server
                        // progress) — block rather than overwrite.
                        pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "This trip's rows were changed elsewhere. Open it to review.",
                        )
                        continue
                    }
                    if (!merged.addsSomething(server)) {
                        // Nothing new beyond the server coverage — don't PATCH.
                        pending.remove(write.id)
                        continue
                    }
                    val trip = tripRepo.updateTripCoverage(
                        id = payload.tripId,
                        completedPaths = merged.completed,
                        skippedPaths = merged.skipped,
                        sequenceIndex = merged.index,
                        currentRowNumber = merged.current,
                        nextRowNumber = merged.next,
                    )
                    pending.remove(write.id)
                    onSynced(trip)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync row coverage.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The row coverage was rejected (${e.code}).",
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
     * The locally captured coverage for [tripId] from the Stage A active-trip
     * snapshot, or null when no snapshot matches this trip (so the caller knows
     * there is no local work to replay). Never invents coverage data.
     */
    private fun localCoverageFor(tripId: String): Trip? {
        val snapshot = runCatching { activeTripStore.load() }.getOrNull() ?: return null
        if (snapshot.trip.id != tripId) return null
        return snapshot.trip
    }

    /** A deterministic, union-merged coverage result. */
    private data class MergedCoverage(
        val completed: List<Double>,
        val skipped: List<Double>,
        val index: Int,
        val current: Double?,
        val next: Double?,
    ) {
        /**
         * True when this merge advances past the live server coverage in any
         * dimension (more completed, more skipped, or a forward index). When
         * false the marker can be cleared without a PATCH.
         */
        fun addsSomething(server: Trip): Boolean {
            val serverCompleted = server.completedPaths.orEmpty().toSet()
            val serverSkipped = server.skippedPaths.orEmpty().toSet()
            return completed.toSet() != serverCompleted ||
                skipped.toSet() != serverSkipped ||
                index != server.sequenceIndex
        }
    }

    /**
     * Conservative union-merge that never shrinks server progress. Completed and
     * skipped sets are unioned; completed wins over skipped for the same path; a
     * server completed/skipped path is never dropped (a server skipped path only
     * disappears when it became completed). The chosen index never moves
     * backwards versus the server, and current/next are re-derived from the
     * server's planned row sequence. Returns null only when the merge cannot be
     * proven non-destructive (a defensive guard that should not trigger given the
     * union construction).
     */
    private fun mergeCoverage(server: Trip, local: Trip): MergedCoverage? {
        val serverCompleted = server.completedPaths.orEmpty()
        val serverSkipped = server.skippedPaths.orEmpty()
        val localCompleted = local.completedPaths.orEmpty()
        val localSkipped = local.skippedPaths.orEmpty()

        val mergedCompleted = (serverCompleted + localCompleted).distinct()
        val mergedCompletedSet = mergedCompleted.toSet()
        // Completed wins: a path that is completed is never also skipped.
        val mergedSkipped = (serverSkipped + localSkipped).distinct()
            .filter { it !in mergedCompletedSet }
        val mergedSkippedSet = mergedSkipped.toSet()

        // Defensive non-destructive guard: every server completed path must
        // survive, and every server skipped path must survive unless it is now
        // completed. Union construction guarantees this, but block rather than
        // risk a destructive PATCH if it ever doesn't hold.
        if (!mergedCompletedSet.containsAll(serverCompleted)) return null
        if (serverSkipped.any { it !in mergedSkippedSet && it !in mergedCompletedSet }) return null

        // Never move the index backwards versus the server.
        val chosenIndex = maxOf(server.sequenceIndex, local.sequenceIndex)
        val sequence = server.rowSequence
        val current = sequence.getOrNull(chosenIndex)
        val next = sequence.getOrNull(chosenIndex + 1)

        return MergedCoverage(
            completed = mergedCompleted,
            skipped = mergedSkipped,
            index = chosenIndex,
            current = current,
            next = next,
        )
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
