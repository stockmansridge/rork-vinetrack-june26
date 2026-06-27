package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Offline replay coordinator for trip GPS/path progress only (Tier-A Stage
 * C-1), for an existing active server trip.
 *
 * Unlike the other replay paths, the outbox row is NOT the source of the path
 * data: high-frequency GPS fixes would bloat the outbox if one row were queued
 * per fix. Instead a single coalesced [PendingEntityType.TRIP_GPS] / UPDATE
 * MARKER per trip ([PendingWrite.clientId] = tripId) records only that the trip
 * has unsynced captured path progress. The captured path itself is read from
 * the Stage A active-trip snapshot ([ActiveTripStore]) at replay time.
 *
 * Discriminator: TRIP_GPS / UPDATE so it never collides with the Stage B-1
 * scalar metadata queue ([PendingEntityType.TRIP_METADATA]), the broad
 * [PendingEntityType.TRIP] reserved for later trip start/end work, or any
 * future row-coverage / tank-session streams.
 *
 * Merge strategy (conservative, deterministic, never destructive): the live
 * server trip is fetched, the local snapshot path is read, and a merged path is
 * produced that is NEVER shorter than the server path. The local snapshot is
 * seeded from the live trip path at capture start and only ever appended to, so
 * it is the authoritative superset of this device's progress; the merge takes
 * the local path when it has more points than the server, de-dupes
 * near-identical consecutive coordinates, and recomputes `total_distance` from
 * scratch (no additive drift). When local adds nothing over the server, the
 * marker is removed without a PATCH. The progress PATCH preserves the live
 * server `is_paused` flag and never touches metadata, coverage, tank sessions,
 * row-plan, engine hours, or trip start/end/delete fields.
 *
 * Conflict / safety: a missing / soft-deleted / no-longer-active server trip is
 * blocked; a missing or mismatched local snapshot means there is no local work
 * to replay, so the marker is safely removed; transient failures retry up to a
 * cap; permanent failures and corrupt payloads block.
 */
class TripGpsSync(
    private val tripRepo: TripRepository,
    private val pending: PendingWriteRepository,
    private val activeTripStore: ActiveTripStore,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Lightweight GPS-progress marker. Carries only the trip id and baseline
     * bookkeeping — never the path points themselves (those live in the Stage A
     * snapshot). [baseServerPointCount] / [baseClientUpdatedAt] capture the
     * progress baseline when the marker was first queued; they are informational
     * and preserved across coalescing.
     */
    @Serializable
    data class Payload(
        val tripId: String,
        val baseServerPointCount: Int = 0,
        val baseClientUpdatedAt: String? = null,
        val clientUpdatedAt: String,
        val savedAt: Long,
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
        val preservedBaseCount = decoded.firstOrNull()?.baseServerPointCount
            ?: (trip.pathPoints?.size ?: 0)
        val preservedBaseStamp = decoded.firstNotNullOfOrNull { it.baseClientUpdatedAt }
            ?: trip.clientUpdatedAt
        existing.forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
            Payload.serializer(),
            Payload(
                tripId = tripId,
                baseServerPointCount = preservedBaseCount,
                baseClientUpdatedAt = preservedBaseStamp,
                clientUpdatedAt = java.time.Instant.now().toString(),
                savedAt = System.currentTimeMillis(),
            ),
        )
        return pending.enqueue(
            entityType = PendingEntityType.TRIP_GPS,
            opType = PendingOpType.UPDATE,
            payloadJson = payload,
            clientId = tripId,
        )
    }

    /**
     * Replay every retry-eligible GPS marker. No-ops (returns) if a replay is
     * already running. For each marker: mark in-progress, decode (block if
     * corrupt), read the local snapshot path, then resolve the outcome:
     *  - no matching local snapshot -> nothing to replay, remove the marker,
     *  - server trip missing/deleted -> blocked,
     *  - server trip no longer active -> blocked,
     *  - merged path adds nothing over the server -> remove the marker (synced),
     *  - otherwise PATCH the merged path + recomputed distance, preserving the
     *    server pause flag; on success remove the marker and fire [onSynced],
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_GPS &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved trip progress.")
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
                // The captured path lives in the Stage A snapshot. No matching
                // snapshot means there is no local work to replay (e.g. ended on
                // this device, or a different trip is now active) — remove the
                // marker safely rather than invent path data.
                val localPath = localPathFor(payload.tripId)
                if (localPath == null) {
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
                    val serverPath = server.pathPoints ?: emptyList()
                    val merged = mergePaths(serverPath, localPath)
                    // Nothing new beyond the server path — don't PATCH, just clear.
                    if (merged.size <= serverPath.size) {
                        pending.remove(write.id)
                        continue
                    }
                    val trip = tripRepo.saveProgress(
                        id = payload.tripId,
                        pathPoints = merged,
                        totalDistance = pathLength(merged),
                        isPaused = server.isPaused,
                    )
                    pending.remove(write.id)
                    onSynced(trip)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync trip progress.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The trip progress was rejected (${e.code}).",
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
     * The locally captured path for [tripId] from the Stage A active-trip
     * snapshot, or null when no snapshot matches this trip (so the caller knows
     * there is no local work to replay). Never invents path data.
     */
    private fun localPathFor(tripId: String): List<CoordinatePoint>? {
        val snapshot = runCatching { activeTripStore.load() }.getOrNull() ?: return null
        if (snapshot.trip.id != tripId) return null
        return snapshot.trip.pathPoints ?: emptyList()
    }

    /**
     * Conservative, deterministic merge that is never shorter than [server].
     * The local snapshot is seeded from the live trip path at capture start and
     * only appended to, so it is the authoritative superset; take it when it has
     * strictly more points than the server, otherwise keep the server path. The
     * chosen path is then de-duped of near-identical consecutive coordinates.
     */
    private fun mergePaths(
        server: List<CoordinatePoint>,
        local: List<CoordinatePoint>,
    ): List<CoordinatePoint> {
        val base = if (local.size > server.size) local else server
        return dedupeConsecutive(base)
    }

    /** Drop consecutive points closer than [MIN_STEP_METRES] (GPS jitter). */
    private fun dedupeConsecutive(points: List<CoordinatePoint>): List<CoordinatePoint> {
        if (points.size < 2) return points
        val out = ArrayList<CoordinatePoint>(points.size)
        out.add(points.first())
        for (i in 1 until points.size) {
            val prev = out.last()
            val cur = points[i]
            if (haversine(prev, cur) >= MIN_STEP_METRES) out.add(cur)
        }
        return out
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
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        /** Cap retries so a persistently-failing marker can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8

        /** Consecutive points closer than this are treated as the same fix. */
        const val MIN_STEP_METRES = 1.0
    }
}
