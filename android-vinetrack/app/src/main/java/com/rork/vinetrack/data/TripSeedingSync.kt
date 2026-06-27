package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SeedingDetails
import com.rork.vinetrack.data.model.Trip
import java.time.OffsetDateTime
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for structured trip seeding-details edits only
 * (Android Stage S): the `trips.seeding_details` JSONB payload (mix lines + box
 * settings) for an existing active server trip.
 *
 * Mirrors [TripMetadataSync] one-for-one, but writes a single column via
 * [TripRepository.updateSeedingDetails] and nothing else — path points, total
 * distance, row coverage, row-plan, tank sessions, scalar metadata and trip
 * start/end/delete all stay on their own discriminators and are never touched.
 *
 * Discriminator: [PendingEntityType.TRIP_SEEDING] / UPDATE so it never collides
 * with [PendingEntityType.TRIP_METADATA] (scalar metadata) or the broad
 * [PendingEntityType.TRIP].
 *
 * Idempotency / coalescing: keyed on the trip id ([PendingWrite.clientId] =
 * tripId); only one unresolved seeding write is kept per trip — [enqueue] drops
 * earlier unresolved writes for the same trip so the latest seeding snapshot
 * wins, while preserving the original [Payload.baseClientUpdatedAt] so the
 * stale-guard still compares against the server state the user first edited from.
 *
 * Conflict strategy: stale-guard + block, identical to [TripMetadataSync]. Before
 * each replay the live server trip is read; a missing / soft-deleted /
 * no-longer-active trip, or a server `client_updated_at` newer than the queued
 * base, BLOCKS the edit (Needs attention) rather than overwriting newer data.
 */
class TripSeedingSync(
    private val tripRepo: TripRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Seeding-only replay payload. Carries the trip's seeding details (null
     * clears the column), the last-write-wins [clientUpdatedAt] stamp, and the
     * [baseClientUpdatedAt] the edit was made from for the stale-guard.
     */
    @Serializable
    data class Payload(
        val tripId: String,
        val seedingDetails: SeedingDetails? = null,
        val clientUpdatedAt: String,
        val baseClientUpdatedAt: String? = null,
    )

    /**
     * Queue (or replace) a seeding-details edit for [trip]. Coalesces by trip:
     * any earlier unresolved seeding write for the same trip is removed first so
     * only the latest snapshot is ever replayed (latest edit wins). The earliest
     * known [baseClientUpdatedAt] from a still-pending earlier write is preserved
     * so coalescing repeated offline edits never moves the conflict baseline
     * forward past where the user started. Returns the row.
     */
    fun enqueue(trip: Trip): PendingWrite {
        val tripId = trip.id
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.TRIP_SEEDING &&
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
                seedingDetails = trip.seedingDetails,
                clientUpdatedAt = java.time.Instant.now().toString(),
                baseClientUpdatedAt = preservedBase,
            ),
        )
        return pending.enqueue(
            entityType = PendingEntityType.TRIP_SEEDING,
            opType = PendingOpType.UPDATE,
            payloadJson = payload,
            clientId = tripId,
        )
    }

    /**
     * Replay every retry-eligible queued seeding edit. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, read the live
     * server trip, then resolve the outcome:
     *  - server trip missing/deleted -> blocked,
     *  - server trip no longer active -> blocked,
     *  - server `client_updated_at` newer than the queued base -> blocked,
     *  - otherwise PATCH the `seeding_details` column with the queued stamp; on
     *    success the row is removed and [onSynced] fires with the server trip,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden / corrupt payload) or attempt cap hit
     *    -> blocked so it never loops forever.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_SEEDING &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved seeding details.")
                    continue
                }
                // Never write to a trip whose server row hasn't been created yet
                // (offline start). Defer without consuming a retry attempt until
                // its TRIP_START marker clears.
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
                    val trip = tripRepo.updateSeedingDetails(
                        id = payload.tripId,
                        details = payload.seedingDetails,
                        clientUpdatedAt = payload.clientUpdatedAt,
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
                            "The seeding details were rejected (${e.code}).",
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
