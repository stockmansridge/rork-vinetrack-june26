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
 * Offline replay coordinator for trip START only (Tier-A Stage B-3-1): a NEW
 * trip the operator began offline (or whose online create failed transiently).
 * The client generates the final trip UUID up front, builds a local provisional
 * active trip, and queues exactly one coalesced
 * [PendingEntityType.TRIP_START] / CREATE MARKER per trip
 * ([PendingWrite.clientId] = tripId). The same id is reused as the eventual
 * server row id, so no id remapping is ever needed: every dependent same-trip
 * marker (TRIP_METADATA / TRIP_GPS / TRIP_ROW / TRIP_TANK / TRIP_END) attaches
 * to it, and it doubles as the idempotency key on replay.
 *
 * Discriminator: TRIP_START / CREATE so it never collides with the Stage B-1
 * scalar metadata queue ([PendingEntityType.TRIP_METADATA]), the Stage C-1 GPS
 * marker, the Stage D-1 row marker, the Stage E-1 tank marker, the Stage B-2-1
 * end marker, or the broad [PendingEntityType.TRIP].
 *
 * Marker payload: only the scalar insert fields (vineyard/paddock/job/operator
 * identity, start time, start engine hours) plus the sync stamp. NEVER path
 * points, distance, row coverage, row-plan, tank sessions, completion/end
 * fields, delete fields or fuel logs — those land via their own markers / the
 * live server row.
 *
 * Replay ordering (mandatory): this coordinator runs FIRST, before
 * metadata/GPS/row/tank/end, because the server row must exist before any
 * dependent marker can write to it. Every dependent coordinator in turn
 * dependency-gates on an unresolved same-trip TRIP_START.
 *
 * Idempotency / safety: before inserting, [fetchTrip] probes for an existing
 * server row with the queued id (a prior insert may have succeeded but its
 * response was lost). When the row already exists the work is done, so the
 * marker is removed and the row reconciled. Otherwise the server trip is
 * created with the queued id. Transient failures retry up to a cap; permanent
 * failures (validation / forbidden) and corrupt payloads block.
 */
class TripStartSync(
    private val tripRepo: TripRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Scalar-only trip-start create payload. Carries the new trip's insert
     * scalars plus a sync stamp — never path points, distance, coverage,
     * row-plan, tank sessions or end/delete fields (those land via their own
     * markers / the live server row).
     */
    @Serializable
    data class Payload(
        val tripId: String,
        val vineyardId: String,
        val paddockId: String? = null,
        val paddockName: String? = null,
        val paddockIds: List<String> = emptyList(),
        val personName: String? = null,
        val tripFunction: String? = null,
        val tripTitle: String? = null,
        val machineId: String? = null,
        val workTaskId: String? = null,
        val operatorUserId: String? = null,
        val operatorCategoryId: String? = null,
        val startTime: String,
        val startEngineHours: Double? = null,
        val clientUpdatedAt: String,
        val savedAt: Long,
    )

    /**
     * Queue (or refresh) the single trip-start marker for [trip]. Coalesces by
     * trip: any earlier unresolved marker for the same trip is removed first so
     * only one marker per trip ever exists. The latest scalar snapshot wins.
     * Returns the row.
     */
    fun enqueue(trip: Trip): PendingWrite {
        val tripId = trip.id
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.TRIP_START &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == tripId &&
                it.status != PendingWriteStatus.SYNCED
        }
        existing.forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
            Payload.serializer(),
            Payload(
                tripId = tripId,
                vineyardId = trip.vineyardId,
                paddockId = trip.paddockId,
                paddockName = trip.paddockName,
                paddockIds = trip.paddockIds,
                personName = trip.personName,
                tripFunction = trip.tripFunction,
                tripTitle = trip.tripTitle,
                machineId = trip.machineId,
                workTaskId = trip.workTaskId,
                operatorUserId = trip.operatorUserId,
                operatorCategoryId = trip.operatorCategoryId,
                startTime = trip.startTime ?: java.time.Instant.now().toString(),
                startEngineHours = trip.startEngineHours,
                clientUpdatedAt = java.time.Instant.now().toString(),
                savedAt = System.currentTimeMillis(),
            ),
        )
        return pending.enqueue(
            entityType = PendingEntityType.TRIP_START,
            opType = PendingOpType.CREATE,
            payloadJson = payload,
            clientId = tripId,
        )
    }

    /**
     * Replay every retry-eligible trip-start marker. No-ops (returns) if a
     * replay is already running. For each marker: mark in-progress, decode
     * (block if corrupt), then resolve the outcome:
     *  - server row with the queued id already exists -> work done (a prior
     *    insert landed), remove the marker and reconcile the existing row,
     *  - otherwise create the server trip with the queued id; on success remove
     *    the marker and fire [onSynced],
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists, and
     * BEFORE the dependent metadata/GPS/row/tank/end replays so the server row
     * exists when they run.
     */
    suspend fun replayAll(onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_START &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved trip start.")
                    continue
                }
                try {
                    // Idempotency probe: a prior insert may have succeeded but
                    // its response was lost. Reuse the existing row rather than
                    // create a duplicate (the primary key is the client UUID).
                    val existingServer = tripRepo.fetchTrip(payload.tripId)
                    if (existingServer != null) {
                        pending.remove(write.id)
                        onSynced(existingServer)
                        continue
                    }
                    val created = tripRepo.createTrip(
                        vineyardId = payload.vineyardId,
                        paddockId = payload.paddockId,
                        paddockName = payload.paddockName,
                        personName = payload.personName,
                        tripFunction = payload.tripFunction,
                        tripTitle = payload.tripTitle,
                        machineId = payload.machineId,
                        workTaskId = payload.workTaskId,
                        operatorUserId = payload.operatorUserId,
                        operatorCategoryId = payload.operatorCategoryId,
                        startEngineHours = payload.startEngineHours,
                        paddockIds = payload.paddockIds,
                        id = payload.tripId,
                        startTime = payload.startTime,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to start the trip.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        // A 409 conflict means the row already exists — treat as
                        // success and let the next pass reconcile via the probe.
                        e.code == 409 -> retryOrBlock(write, "Trip already exists; will reconcile.")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The trip start was rejected (${e.code}).",
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

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    companion object Dependency {
        /** Cap retries so a persistently-failing marker can't loop indefinitely. */
        private const val MAX_ATTEMPTS = 8

        /**
         * True when an unresolved same-trip TRIP_START create marker exists for
         * [tripId] (pending, in-progress, failed or blocked). Dependent
         * coordinators (metadata / GPS / row / tank / end) call this to DEFER
         * their own replay until the server trip row has been created — writing
         * to a not-yet-created trip would 404/conflict. A blocked TRIP_START
         * also counts, so dependents wait rather than write to a trip that may
         * never exist server-side.
         */
        fun hasUnresolvedStart(pending: PendingWriteRepository, tripId: String): Boolean =
            pending.list().any {
                it.clientId == tripId &&
                    it.entityType == PendingEntityType.TRIP_START &&
                    it.status in PendingWriteStatus.unresolved
            }
    }
}
