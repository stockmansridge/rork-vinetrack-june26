package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.Trip
import java.time.OffsetDateTime
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for SAFE SCALAR trip-detail edits only
 * (Tier-A Stage B-1): trip metadata, pause/resume, and an optional start
 * engine-hour reading, for an existing active server trip.
 *
 * This is the first trip write path wired into the pending-write outbox. It
 * replays the narrow scalar write shape ([TripRepository.updateTripMetadataFields])
 * and deliberately nothing else — path points, total distance, row coverage
 * arrays, row-plan, tank sessions, and trip start/end/delete stay online-only
 * and untouched. Those higher-frequency / ordered / whole-array streams are
 * parked for later Tier-A stages (C–F).
 *
 * Discriminator: these writes use [PendingEntityType.TRIP_METADATA] / UPDATE so
 * they never collide with the broad [PendingEntityType.TRIP] reserved for the
 * later trip-start/end/event work — mirroring the PIN vs PIN_EDIT split.
 *
 * Idempotency / coalescing: the outbox row is keyed on the trip id
 * ([PendingWrite.clientId] = tripId) and only one unresolved scalar write is
 * ever kept per trip — [enqueue] drops earlier unresolved writes for the same
 * trip so the latest scalar snapshot wins, while preserving the original
 * [Payload.baseClientUpdatedAt] so the stale-guard still compares against the
 * server state the user first edited from.
 *
 * Conflict strategy: stale-guard + block. Before each replay the live server
 * trip is read; if its `client_updated_at` is newer than the queued
 * [Payload.baseClientUpdatedAt], the server changed while we were offline and
 * the edit is BLOCKED (Needs attention) rather than blindly overwritten. A
 * missing / soft-deleted / no-longer-active trip is also blocked. With no
 * conflict it PATCHes the scalar fields with the queued [Payload.clientUpdatedAt].
 */
class TripMetadataSync(
    private val tripRepo: TripRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Scalar-only replay payload. Carries the trip's safe scalar fields, the
     * last-write-wins [clientUpdatedAt] stamp, and the [baseClientUpdatedAt]
     * the edit was made from for the stale-guard. No path points, coverage,
     * tank sessions, or trip start/end fields.
     */
    @Serializable
    data class Payload(
        val tripId: String,
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
        val isPaused: Boolean = false,
        val startEngineHours: Double? = null,
        val clientUpdatedAt: String,
        val baseClientUpdatedAt: String? = null,
    )

    /**
     * Queue (or replace) a scalar trip-detail edit for [trip]. Coalesces by
     * trip: any earlier unresolved scalar write for the same trip is removed
     * first so only the latest snapshot is ever replayed (latest edit wins).
     * The earliest known [baseClientUpdatedAt] from a still-pending earlier
     * write is preserved, so coalescing repeated offline edits never moves the
     * conflict baseline forward past where the user started. Returns the row.
     */
    fun enqueue(trip: Trip): PendingWrite {
        val tripId = trip.id
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.TRIP_METADATA &&
                it.opType == PendingOpType.UPDATE &&
                it.clientId == tripId &&
                it.status != PendingWriteStatus.SYNCED
        }
        val preservedBase = existing
            .mapNotNull { runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull() }
            .firstNotNullOfOrNull { it.baseClientUpdatedAt }
            ?: trip.clientUpdatedAt
        existing.forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
            Payload.serializer(),
            Payload(
                tripId = tripId,
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
                isPaused = trip.isPaused,
                startEngineHours = trip.startEngineHours,
                clientUpdatedAt = java.time.Instant.now().toString(),
                baseClientUpdatedAt = preservedBase,
            ),
        )
        return pending.enqueue(
            entityType = PendingEntityType.TRIP_METADATA,
            opType = PendingOpType.UPDATE,
            payloadJson = payload,
            clientId = tripId,
        )
    }

    /**
     * Replay every retry-eligible queued scalar edit. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, read the live
     * server trip, then resolve the outcome:
     *  - server trip missing/deleted -> blocked (can't edit a vanished trip),
     *  - server trip no longer active -> blocked (ended elsewhere; scalar edits
     *    only apply to an in-progress trip in this slice),
     *  - server `client_updated_at` newer than the queued base -> blocked
     *    (Needs attention) so a stale edit never overwrites newer data,
     *  - otherwise PATCH the scalar fields; on success the row is removed and
     *    [onSynced] fires with the server trip so the caller reconciles,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden / corrupt payload) or attempt cap
     *    hit -> blocked so it never loops forever.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_METADATA &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved trip details.")
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
                    if (isServerNewer(server.clientUpdatedAt, payload.baseClientUpdatedAt)) {
                        pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "This trip was changed elsewhere. Open it to review.",
                        )
                        continue
                    }
                    val trip = tripRepo.updateTripMetadataFields(
                        id = payload.tripId,
                        paddockId = payload.paddockId,
                        paddockName = payload.paddockName,
                        personName = payload.personName,
                        tripFunction = payload.tripFunction,
                        tripTitle = payload.tripTitle,
                        machineId = payload.machineId,
                        workTaskId = payload.workTaskId,
                        operatorUserId = payload.operatorUserId,
                        operatorCategoryId = payload.operatorCategoryId,
                        isPaused = payload.isPaused,
                        startEngineHours = payload.startEngineHours,
                        clientUpdatedAt = payload.clientUpdatedAt,
                        paddockIds = payload.paddockIds,
                    )
                    pending.remove(write.id)
                    onSynced(trip)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync these details.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The trip details were rejected (${e.code}).",
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
     * True when the server's last client edit stamp is strictly newer than the
     * base the queued edit was made from. A null on either side can't prove a
     * conflict, so the edit is allowed through (last-write-wins for an
     * un-stamped trip).
     */
    private fun isServerNewer(serverClientUpdatedAt: String?, base: String?): Boolean {
        val server = parseInstant(serverClientUpdatedAt) ?: return false
        val baseInstant = parseInstant(base) ?: return false
        return server.isAfter(baseInstant)
    }

    /** Tolerant ISO-8601 parse for both `...Z` and `...+00:00` timestamp shapes. */
    private fun parseInstant(value: String?): java.time.Instant? {
        if (value.isNullOrBlank()) return null
        return runCatching { OffsetDateTime.parse(value).toInstant() }
            .recoverCatching { java.time.Instant.parse(value) }
            .getOrNull()
    }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        /** Cap retries so a persistently-failing edit can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
