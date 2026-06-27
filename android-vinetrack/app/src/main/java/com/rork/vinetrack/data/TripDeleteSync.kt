package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for trip soft-DELETE only (Tier-A Stage G-2), for
 * an ended / inactive server trip. The operator deleted a finished trip offline
 * (or a transient online delete failed) and the server row still exists. It
 * replays the soft-delete write shape ([TripRepository.softDeleteTrip]) and
 * nothing else: it never hard-deletes, never touches the active trip, never
 * cancels a locally-started unsynced trip, and never performs any destructive
 * local recovery.
 *
 * Discriminator: delete markers use [PendingEntityType.TRIP] / DELETE so they
 * are never picked up by the trip-start, metadata, GPS, row, tank or end queues
 * (each of those owns its own distinct entity type). Conversely this coordinator
 * only ever processes TRIP / DELETE rows.
 *
 * Dependency gate (mandatory): a delete is never finalised while same-trip
 * start / metadata / GPS / row / tank / end work is still unresolved — deleting
 * first would race those writes (e.g. a TRIP_START could re-create the row) or
 * orphan unsynced progress. Such a marker is deferred (kept FAILED,
 * retry-eligible, no attempt consumed) until the dependencies clear, mirroring
 * [TripEndSync]'s gate. The caller ([com.rork.vinetrack.ui.AppViewModel.deleteTrip])
 * additionally refuses to enqueue a delete while same-trip markers exist, so this
 * gate is a safety net for markers that appear after enqueue.
 *
 * Idempotency / coalescing: the outbox row is keyed on the trip id
 * ([PendingWrite.clientId] = tripId) and only one unresolved delete is ever kept
 * per trip. Re-deleting an already soft-deleted row is itself idempotent
 * server-side, and an already-deleted / not-found row is treated as success so a
 * delete can never loop forever.
 */
class TripDeleteSync(
    private val tripRepo: TripRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Soft-delete-only replay payload. Just the target trip id — nothing else. */
    @Serializable
    data class Payload(val tripId: String)

    /**
     * Queue (or replace) a soft-delete for [tripId]. Coalesces by trip: any
     * earlier unresolved delete write for the same trip is removed first so only
     * one is ever replayed. Returns the created outbox row. Callers must only
     * enqueue this for an ended / inactive trip the server already knows about,
     * with no unresolved same-trip markers — an active trip or a locally-started
     * unsynced trip is never queued for delete in Stage G-2.
     */
    fun enqueue(tripId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.TRIP &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == tripId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(tripId))
        return pending.enqueue(
            entityType = PendingEntityType.TRIP,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = tripId,
        )
    }

    /**
     * Replay every retry-eligible queued trip delete. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-trip start / metadata / GPS / row / tank / end still unresolved ->
     *    deferred (FAILED, retry-eligible, no attempt consumed), never deleted,
     *  - soft-delete succeeds (or the row is already gone / not found) -> removed
     *    from the outbox and [onDeleted] fires so the caller can keep the trip
     *    hidden,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onDeleted: (tripId: String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved trip delete.")
                    continue
                }
                // Dependency gate: never delete while same-trip start / metadata /
                // GPS / row / tank / end work is still unresolved. Defer without
                // consuming a retry attempt so a legitimately-waiting delete can't
                // exhaust its cap.
                if (hasUnresolvedDependencies(payload.tripId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this trip's other changes to sync first.",
                    )
                    continue
                }
                try {
                    tripRepo.softDeleteTrip(payload.tripId)
                    pending.remove(write.id)
                    onDeleted(payload.tripId)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to delete this trip.")
                } catch (e: BackendError.Server) {
                    when {
                        // Already deleted / never existed server-side — the delete
                        // intent is satisfied. Idempotent success.
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onDeleted(payload.tripId)
                        }
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The delete was rejected (${e.code}).",
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
     * True when any same-trip start / metadata / GPS / row / tank / end marker is
     * still unresolved (pending / in-progress / failed / blocked). A blocked
     * dependency also counts — the delete waits for the operator to resolve it
     * rather than racing or orphaning unsynced trip work.
     */
    private fun hasUnresolvedDependencies(tripId: String): Boolean =
        pending.list().any {
            it.clientId == tripId &&
                it.entityType in DEPENDENCY_TYPES &&
                it.status in PendingWriteStatus.unresolved
        }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    companion object {
        /** Cap retries so a persistently-failing delete can't loop indefinitely. */
        private const val MAX_ATTEMPTS = 8

        /**
         * Same-trip markers that must clear before a delete may be queued or
         * finalised. Shared with [com.rork.vinetrack.ui.AppViewModel.deleteTrip]
         * so the enqueue-time guard and the replay-time gate stay in lockstep.
         */
        val DEPENDENCY_TYPES: Set<String> = setOf(
            PendingEntityType.TRIP_START,
            PendingEntityType.TRIP_METADATA,
            PendingEntityType.TRIP_GPS,
            PendingEntityType.TRIP_ROW,
            PendingEntityType.TRIP_TANK,
            PendingEntityType.TRIP_END,
        )
    }
}
