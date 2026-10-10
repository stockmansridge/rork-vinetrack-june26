package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for trip TANK/FILL progress only (Tier-A Stage
 * E-1), for an existing active server trip: the operator-driven Start tank /
 * End tank / Start fill / Stop fill actions that move `tank_sessions`,
 * `active_tank_number`, `is_filling_tank` and `filling_tank_number`.
 *
 * Like the Stage C-1 GPS and Stage D-1 row markers, the outbox row is NOT the
 * source of the tank data: a burst of tank/fill taps would bloat the outbox if
 * one row were queued per action. Instead a single coalesced
 * [PendingEntityType.TRIP_TANK] / UPDATE MARKER per trip
 * ([PendingWrite.clientId] = tripId) records only that the trip has unsynced
 * tank/fill progress. The tank sessions and live tank scalars themselves are
 * read from the Stage A active-trip snapshot ([ActiveTripStore]) at replay time.
 *
 * Discriminator: TRIP_TANK / UPDATE so it never collides with the Stage B-1
 * scalar metadata queue ([PendingEntityType.TRIP_METADATA]) — which still owns
 * start-engine-hours — the Stage C-1 GPS marker
 * ([PendingEntityType.TRIP_GPS]), the Stage D-1 row marker
 * ([PendingEntityType.TRIP_ROW]), the broad [PendingEntityType.TRIP] reserved
 * for later trip start/end work, or the legacy unused [TANK_SESSION] placeholder.
 *
 * Merge strategy (conservative, deterministic, never destructive): the live
 * server trip is fetched, the local snapshot tank sessions are read, and the
 * two are UNION-merged by stable [TankSession.id]. A server session is never
 * dropped. For a session present in both, the more-complete record wins (a
 * closed `endTime` beats an open one, a closed `fillEndTime` beats an open
 * fill); otherwise the local edit wins as the freshest local work. Live tank
 * scalars (`active_tank_number`, `is_filling_tank`, `filling_tank_number`) are
 * reconciled conservatively: the local value is only asserted when a matching
 * still-open session survives in the merged set, otherwise the server scalar is
 * kept (an ended tank is never reopened). When the merge adds nothing over the
 * server state, the marker is removed without a PATCH. The tank PATCH touches
 * only `tank_sessions`, `active_tank_number`, `is_filling_tank`,
 * `filling_tank_number` and the sync stamp — never path points, distance,
 * coverage, row-plan, metadata, engine hours, or trip start/end/delete fields.
 *
 * Conflict / safety: a missing / soft-deleted / no-longer-active server trip is
 * blocked; missing, corrupt, foreign or mismatched local snapshots retain the
 * marker without a claim or probe; transient failures retry up to a
 * cap; permanent failures and corrupt payloads block.
 */
class TripTankSync(
    private val tripRepo: TripRepository?,
    private val pending: PendingWriteRepository,
    private val activeTripStore: ActiveTripStore,
    private val fetchTrip: (suspend (String) -> Trip?)? = null,
    private val saveTankSessions: (suspend (String, List<TankSession>, Int?, Boolean, Int?) -> Trip)? = null,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Lightweight tank/fill marker. Carries only the trip id and baseline
     * bookkeeping — never the tank sessions themselves (those live in the Stage
     * A snapshot). [baseSessionCount] / [baseActiveTankNumber] /
     * [baseClientUpdatedAt] capture the progress baseline when the marker was
     * first queued; they are informational and preserved across coalescing.
     */
    @Serializable
    data class Payload(
        val tripId: String,
        val baseSessionCount: Int = 0,
        val baseActiveTankNumber: Int? = null,
        val baseClientUpdatedAt: String? = null,
        val clientUpdatedAt: String,
        val savedAt: Long,
    )

    /**
     * Queue (or refresh) the single tank/fill marker for [trip]. Coalesces by
     * trip: any earlier unresolved marker for the same trip is atomically replaced so
     * only one marker per trip ever exists. The earliest known baseline values
     * from a still-pending earlier marker are preserved so repeated offline tank
     * actions never move the baseline forward. Returns the row.
     */
    fun enqueue(trip: Trip): PendingWrite = pending.enqueueReplacingUnresolved(
        entityType = PendingEntityType.TRIP_TANK,
        opType = PendingOpType.UPDATE,
        clientId = trip.id,
    ) { existing ->
        val tripId = trip.id
        val decoded = existing
            .mapNotNull { runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull() }
        val firstPayload = decoded.firstOrNull()
        val preservedSessionCount = firstPayload?.baseSessionCount ?: trip.tankSessions.size
        val preservedActiveTank = firstPayload?.baseActiveTankNumber ?: trip.activeTankNumber
        val preservedStamp = decoded.firstNotNullOfOrNull { it.baseClientUpdatedAt }
            ?: trip.clientUpdatedAt
        json.encodeToString(
            Payload.serializer(),
            Payload(
                tripId = tripId,
                baseSessionCount = preservedSessionCount,
                baseActiveTankNumber = preservedActiveTank,
                baseClientUpdatedAt = preservedStamp,
                clientUpdatedAt = java.time.Instant.now().toString(),
                savedAt = System.currentTimeMillis(),
            ),
        )
    }

    /**
     * Replay every retry-eligible tank/fill marker. No-ops (returns) if a replay
     * is already running. For each marker: mark in-progress, decode (block if
     * corrupt), read the local snapshot tank state, then resolve the outcome:
     *  - no provably owned matching local snapshot -> hold the unchanged marker,
     *  - server trip missing/deleted -> blocked,
     *  - server trip no longer active -> blocked,
     *  - merged tank state adds nothing over the server -> remove the marker,
     *  - otherwise PATCH the merged tank state; on success remove the marker and
     *    fire [onSynced],
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(
        permittedWrites: Map<String, PendingWrite>? = null,
        accountAccess: com.rork.vinetrack.data.auth.AuthRetentionGuard.AccountAccess? = null,
        withAccountAccess: (() -> Unit) -> Boolean = { action -> action(); true },
        onSynced: (Trip) -> Unit,
    ) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_TANK &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED) &&
                    (permittedWrites == null || permittedWrites[it.id] == it)
            }
            val originalScope = pending.currentReplayScope() ?: return
            if (tripRepo != null && accountAccess == null) return
            if (accountAccess != null && accountAccess.userId != originalScope.userId) return
            for (candidate in candidates) {
                if (pending.currentReplayScope() != originalScope) return
                // Validate the exact owner-tagged source before claim or network IO. Missing,
                // corrupt, foreign or mismatched evidence is held, never acknowledged as empty.
                val candidatePayload = runCatching { json.decodeFromString(Payload.serializer(), candidate.payloadJson) }.getOrNull() ?: continue
                val snapshot = runCatching { activeTripStore.load() }.getOrNull() ?: continue
                if (snapshot.ownerUserId != originalScope.userId || snapshot.trip.id != candidatePayload.tripId ||
                    snapshot.vineyardId != snapshot.trip.vineyardId) continue
                val local = snapshot.trip
                val write = pending.claimReplay(candidate, permittedWrites) ?: continue
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "Couldn't read the saved tank progress.")
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
                // Only the owner-validated frozen snapshot supplies tank state. Unknown
                // evidence above never falls through to a fabricated empty snapshot.
                try {
                    val server = fetchTrip?.invoke(payload.tripId) ?: if (fetchTrip == null)
                        requireNotNull(tripRepo).fetchTrip(payload.tripId, accountAccess) else null
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (pending.currentReplayScope() != originalScope || !pending.isCurrent(write)) continue
                    if (server == null) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "This trip no longer exists.")
                        continue
                    }
                    if (server.vineyardId != snapshot.vineyardId) {
                        withAccountAccess {
                            pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED,
                                "The server trip belongs to a different vineyard. Local tank progress is retained for review.")
                        }
                        continue
                    }
                    if (!server.isActive) {
                        pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "This trip was finished elsewhere. Open it to review.",
                        )
                        continue
                    }
                    val merged = TankSessionReplayMerge.merge(server, local)
                    if (merged == null) {
                        // Merge could not be proven safe (would drop/regress
                        // server sessions) — block rather than overwrite.
                        pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "This trip's tanks were changed elsewhere. Open it to review.",
                        )
                        continue
                    }
                    if (!merged.addsSomething(server)) {
                        // Nothing new beyond the server tank state — don't PATCH.
                        withAccountAccess { pending.removeIfCurrent(write) }
                        continue
                    }
                    val trip = saveTankSessions?.invoke(
                        payload.tripId, merged.sessions, merged.activeTankNumber,
                        merged.isFillingTank, merged.fillingTankNumber,
                    ) ?: requireNotNull(tripRepo).updateTripTankSessions(
                        payload.tripId, merged.sessions, merged.activeTankNumber,
                        merged.isFillingTank, merged.fillingTankNumber, accountAccess,
                    )
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    withAccountAccess {
                        if (pending.currentReplayScope() == originalScope && pending.removeIfCurrent(write)) onSynced(trip)
                    }
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync tank progress.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "The tank progress was rejected (${e.code}).",
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

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.retryIfCurrent(write, error, MAX_ATTEMPTS)
    }

    private companion object {
        /** Cap retries so a persistently-failing marker can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
