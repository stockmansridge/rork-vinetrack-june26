package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * GPS-only replay with exact observation verification and completed-trip read-only recovery.
 * New markers retain scoped path evidence; legacy markers require an owned snapshot.
 * Missing evidence is held, never acknowledged from point count or trip status alone.
 * Active writes require a local superset and a conditional still-active server row.
 * Completed trips are never patched. Verified markers retain their payload as SYNCED.
 */
class TripGpsSync private constructor(
    private val pending: PendingWriteRepository,
    private val activeTripStore: ActiveTripStore,
    private val fetch: suspend (String, () -> Boolean) -> Trip?,
    private val save: suspend (Trip, List<CoordinatePoint>, Double, Boolean, () -> Boolean) -> Trip,
) {
    constructor(tripRepo: TripRepository, pending: PendingWriteRepository, activeTripStore: ActiveTripStore) :
        this(pending, activeTripStore, { id, admitted -> tripRepo.fetchGpsTrip(id, admitted) },
            { expected, path, distance, paused, admitted -> tripRepo.saveGpsProgress(expected, path, distance, paused, admitted) })

    /** Synthetic transport seam; production always uses the captured-account repository above. */
    internal constructor(pending: PendingWriteRepository, activeTripStore: ActiveTripStore,
        fetch: suspend (String) -> Trip?, save: suspend (Trip, List<CoordinatePoint>, Double, Boolean) -> Trip) :
        this(pending, activeTripStore, { id, _ -> fetch(id) },
            { expected, path, distance, paused, _ -> save(expected, path, distance, paused) })
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Frozen scoped GPS evidence and original baseline. Missing new fields decode
     * old markers without inventing ownership or points. */
    @Serializable
    data class Payload(
        val tripId: String,
        val baseServerPointCount: Int = 0,
        val baseClientUpdatedAt: String? = null,
        val clientUpdatedAt: String,
        val savedAt: Long,
        val ownerUserId: String? = null,
        val vineyardId: String? = null,
        val pathEvidence: List<CoordinatePoint>? = null,
        val originalPayloadJson: String? = null,
    )

    /**
     * Queue (or refresh) the single GPS-progress marker for [trip]. Coalesces by
     * trip: any earlier unresolved marker for the same trip is removed first so
     * only one marker per trip ever exists. The earliest known baseline values
     * from a still-pending earlier marker are preserved so repeated offline
     * autosaves never move the baseline forward. Returns the row.
     */
    fun enqueue(trip: Trip): PendingWrite {
        val tripId = trip.id
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.TRIP_GPS &&
                it.opType == PendingOpType.UPDATE &&
                it.clientId == tripId &&
                it.status != PendingWriteStatus.SYNCED
        }
        val decoded = existing
            .mapNotNull { runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull() }
        check(decoded.size == existing.size && existing.none { it.status == PendingWriteStatus.BLOCKED }) {
            "Retained GPS marker needs review before it can be replaced."
        }
        val preservedBaseCount = decoded.firstOrNull()?.baseServerPointCount
            ?: (trip.pathPoints?.size ?: 0)
        val preservedBaseStamp = decoded.firstNotNullOfOrNull { it.baseClientUpdatedAt }
            ?: trip.clientUpdatedAt
        val scope = pending.currentReplayScope()
        val snapshot = activeTripStore.load()
        check(scope != null && snapshot?.ownerUserId == scope.userId &&
            snapshot.vineyardId == trip.vineyardId && snapshot.trip.id == tripId) {
            "GPS evidence requires the original account and retained trip snapshot."
        }
        check(decoded.all { it.tripId == tripId && (it.ownerUserId == null || it.ownerUserId == scope.userId) &&
            (it.vineyardId == null || it.vineyardId == trip.vineyardId) }) {
            "Original GPS marker belongs to another scope. Its evidence was not replaced."
        }
        val path = trip.pathPoints ?: error("Missing GPS evidence; original markers retained.")
        check(decoded.all { old -> old.pathEvidence == null || containsEvidence(path, old.pathEvidence) }) {
            "New GPS snapshot does not contain the retained evidence. Review sync before continuing."
        }
        val payload = json.encodeToString(
            Payload.serializer(),
            Payload(
                tripId = tripId,
                baseServerPointCount = preservedBaseCount,
                baseClientUpdatedAt = preservedBaseStamp,
                clientUpdatedAt = java.time.Instant.now().toString(),
                savedAt = System.currentTimeMillis(),
                ownerUserId = scope.userId,
                vineyardId = trip.vineyardId,
                pathEvidence = path,
                originalPayloadJson = decoded.firstNotNullOfOrNull { it.originalPayloadJson },
            ),
        )
        return pending.upsertCoalesced(PendingEntityType.TRIP_GPS, tripId, payload)
    }

    /** Replay retry-eligible markers under exact queue-version/account fences.
     * Read-only reconciliation of a completed trip can acknowledge only exact evidence
     * inclusion; missing, foreign, diverging or unreadable evidence remains reviewable. */
    suspend fun replayAll(permittedWrites: Map<String, PendingWrite>? = null, onSynced: (Trip) -> Unit) {
        val caller = kotlinx.coroutines.currentCoroutineContext()
        val scope = pending.currentReplayScope()
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            replayRetained(permittedWrites) { trip ->
                kotlinx.coroutines.withContext(caller) {
                    if (pending.currentReplayScope() == scope) onSynced(trip)
                }
            }
        }
    }

    private suspend fun replayRetained(permittedWrites: Map<String, PendingWrite>?, onSynced: suspend (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_GPS &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED) &&
                    (permittedWrites == null || permittedWrites[it.id] == it)
            }
            for (candidate in candidates) {
                var write = pending.claimReplay(candidate, permittedWrites) ?: continue
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "Couldn't read the saved trip progress.")
                    continue
                }
                // Stage B-3-1 gate: never write to a trip whose server row
                // hasn't been created yet (offline start). Defer without
                // consuming a retry attempt until its TRIP_START marker clears.
                if (TripStartSync.Dependency.hasUnresolvedStart(pending, payload.tripId)) {
                    pending.updateStatusIfCurrent(
                        write,
                        PendingWriteStatus.FAILED,
                        "Waiting for this trip to finish starting.",
                    )
                    continue
                }
                // Old markers require their original owned snapshot. New markers carry
                // frozen evidence so replacing the active snapshot cannot erase it.
                val scope = pending.currentReplayScope()
                val snapshot = runCatching { activeTripStore.load() }.getOrNull()
                val ownedSnapshot = snapshot?.takeIf { it.ownerUserId == scope?.userId &&
                    it.vineyardId == it.trip.vineyardId && it.trip.id == payload.tripId }
                val frozenPath = payload.pathEvidence
                val snapshotPath = ownedSnapshot?.trip?.pathPoints
                val localPath = if (frozenPath != null && snapshotPath != null) {
                    if (!containsEvidence(snapshotPath, frozenPath)) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED,
                            "Retained GPS routes diverge. Both local sources are preserved; contact support before replacing this trip.")
                        continue
                    }
                    snapshotPath
                } else frozenPath ?: snapshotPath
                val vineyard = payload.vineyardId ?: ownedSnapshot?.vineyardId
                val owner = payload.ownerUserId ?: ownedSnapshot?.ownerUserId
                if (scope == null || scope.userId != owner || vineyard == null || localPath == null ||
                    localPath.isEmpty() || write.clientId != payload.tripId) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED,
                        "GPS evidence or original ownership is unavailable. Keep this installation; open the saved trip and contact support to recover GPS. Nothing was discarded.")
                    continue
                }
                if (payload.pathEvidence != localPath || payload.ownerUserId == null || payload.vineyardId == null) {
                    val frozen = payload.copy(ownerUserId = owner, vineyardId = vineyard, pathEvidence = localPath,
                        originalPayloadJson = payload.originalPayloadJson ?: write.payloadJson)
                    write = pending.retainGpsPayloadIfCurrent(write, json.encodeToString(Payload.serializer(), frozen)) ?: continue
                }
                try {
                    if (!pending.isCurrent(write)) continue
                    val server = fetch(payload.tripId) { pending.isCurrent(write) && pending.currentReplayScope() == scope }
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (!pending.isCurrent(write)) continue
                    if (server == null) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "This trip no longer exists.")
                        continue
                    }
                    if (server.id != payload.tripId || server.vineyardId != vineyard || server.deletedAt != null ||
                        pending.currentReplayScope() != scope) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED,
                            "GPS scope or retained evidence changed during verification. Original marker retained for review.")
                        continue
                    }
                    if (ownedSnapshot != null && activeTripStore.load() != snapshot) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED,
                            "GPS snapshot changed during verification. Retry to reconcile the newest retained evidence.")
                        continue
                    }
                    val serverPath = server.pathPoints.orEmpty()
                    if (containsEvidence(serverPath, localPath)) {
                        // Keep the original payload as durable acknowledged evidence, not a queue deletion.
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.SYNCED,
                            "Verified: every retained GPS observation is present in the server trip. No trip status was changed.")
                        continue
                    }
                    if (!server.isActive || server.endTime != null) {
                        pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "Completed trip GPS differs from this device. Retained local evidence needs support review; no completed history was changed.",
                        )
                        continue
                    }
                    if (!containsEvidence(localPath, serverPath)) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED,
                            "GPS routes diverge. Original evidence retained; review before merging.")
                        continue
                    }
                    if (server.updatedAt == null) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED,
                            "Server GPS revision is unavailable. Original evidence retained; contact support before merging.")
                        continue
                    }
                    val trip = save(server, localPath, pathLength(localPath), server.isPaused) {
                        pending.isCurrent(write) && pending.currentReplayScope() == scope
                    }
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (trip.id != payload.tripId || trip.vineyardId != vineyard || !containsEvidence(trip.pathPoints.orEmpty(), localPath)) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "GPS acknowledgement is incomplete. Original evidence retained for review.")
                        continue
                    }
                    if (ownedSnapshot != null && activeTripStore.load() != snapshot) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED,
                            "More GPS evidence was saved during upload. Retry to verify the newest retained route.")
                        continue
                    }
                    if (pending.updateStatusIfCurrent(write, PendingWriteStatus.SYNCED)) onSynced(trip)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync trip progress.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "The trip progress was rejected (${e.code}).",
                        )
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED, "Trip sync was interrupted. Ready to retry.")
                    throw e
                } catch (e: Exception) {
                    retryOrBlock(write, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    /** Great-circle length of [pts] in metres, recomputed from scratch. */
    private fun pathLength(pts: List<CoordinatePoint>): Double {
        if (pts.size < 2) return 0.0
        var total = 0.0
        for (i in 1 until pts.size) total += haversine(pts[i - 1], pts[i])
        return total
    }

    private fun haversine(a: CoordinatePoint, b: CoordinatePoint): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(b.latitude - a.latitude)
        val dLon = Math.toRadians(b.longitude - a.longitude)
        val lat1 = Math.toRadians(a.latitude)
        val lat2 = Math.toRadians(b.latitude)
        val h = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(h), sqrt(1 - h))
    }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.retryIfCurrent(write, error, MAX_ATTEMPTS)
    }

    companion object {
        /** Ordered exact observation inclusion, including optional evidence when locally present.
         * Point counts, rounded coordinates and distance totals never establish inclusion. */
        internal fun containsEvidence(server: List<CoordinatePoint>, local: List<CoordinatePoint>): Boolean {
            var cursor = 0
            for (point in local) {
                if (!point.latitude.isFinite() || !point.longitude.isFinite()) return false
                while (cursor < server.size && !sameObservation(server[cursor], point)) cursor++
                if (cursor == server.size) return false
                cursor++
            }
            return true
        }

        private fun sameObservation(remote: CoordinatePoint, local: CoordinatePoint): Boolean =
            remote.latitude == local.latitude && remote.longitude == local.longitude &&
                (local.bearing == null || remote.bearing == local.bearing) &&
                (local.speed == null || remote.speed == local.speed) &&
                (local.accuracy == null || remote.accuracy == local.accuracy)

        /** Cap retries so a persistently-failing marker can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8


    }
}
