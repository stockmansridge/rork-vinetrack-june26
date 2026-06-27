package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.sync.Mutex
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
 * blocked; a missing or mismatched local snapshot means there is no local work
 * to replay, so the marker is safely removed; transient failures retry up to a
 * cap; permanent failures and corrupt payloads block.
 */
class TripTankSync(
    private val tripRepo: TripRepository,
    private val pending: PendingWriteRepository,
    private val activeTripStore: ActiveTripStore,
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
     * trip: any earlier unresolved marker for the same trip is removed first so
     * only one marker per trip ever exists. The earliest known baseline values
     * from a still-pending earlier marker are preserved so repeated offline tank
     * actions never move the baseline forward. Returns the row.
     */
    fun enqueue(trip: Trip): PendingWrite {
        val tripId = trip.id
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.TRIP_TANK &&
                it.opType == PendingOpType.UPDATE &&
                it.clientId == tripId &&
                it.status != PendingWriteStatus.SYNCED
        }
        val decoded = existing
            .mapNotNull { runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull() }
        val firstPayload = decoded.firstOrNull()
        val preservedSessionCount = firstPayload?.baseSessionCount ?: trip.tankSessions.size
        val preservedActiveTank = firstPayload?.baseActiveTankNumber ?: trip.activeTankNumber
        val preservedStamp = decoded.firstNotNullOfOrNull { it.baseClientUpdatedAt }
            ?: trip.clientUpdatedAt
        existing.forEach { pending.remove(it.id) }
        val payload = json.encodeToString(
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
        return pending.enqueue(
            entityType = PendingEntityType.TRIP_TANK,
            opType = PendingOpType.UPDATE,
            payloadJson = payload,
            clientId = tripId,
        )
    }

    /**
     * Replay every retry-eligible tank/fill marker. No-ops (returns) if a replay
     * is already running. For each marker: mark in-progress, decode (block if
     * corrupt), read the local snapshot tank state, then resolve the outcome:
     *  - no matching local snapshot -> nothing to replay, remove the marker,
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
    suspend fun replayAll(onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.TRIP_TANK &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved tank progress.")
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
                // The captured tank state lives in the Stage A snapshot. No
                // matching snapshot means there is no local work to replay (e.g.
                // ended on this device, or a different trip is now active) —
                // remove the marker safely rather than invent tank data.
                val local = localTankStateFor(payload.tripId)
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
                    val merged = mergeTanks(server, local)
                    if (merged == null) {
                        // Merge could not be proven safe (would drop/regress
                        // server sessions) — block rather than overwrite.
                        pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "This trip's tanks were changed elsewhere. Open it to review.",
                        )
                        continue
                    }
                    if (!merged.addsSomething(server)) {
                        // Nothing new beyond the server tank state — don't PATCH.
                        pending.remove(write.id)
                        continue
                    }
                    val trip = tripRepo.updateTripTankSessions(
                        id = payload.tripId,
                        tankSessions = merged.sessions,
                        activeTankNumber = merged.activeTankNumber,
                        isFillingTank = merged.isFillingTank,
                        fillingTankNumber = merged.fillingTankNumber,
                    )
                    pending.remove(write.id)
                    onSynced(trip)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync tank progress.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The tank progress was rejected (${e.code}).",
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
     * The locally captured tank state for [tripId] from the Stage A active-trip
     * snapshot, or null when no snapshot matches this trip (so the caller knows
     * there is no local work to replay). Never invents tank data.
     */
    private fun localTankStateFor(tripId: String): Trip? {
        val snapshot = runCatching { activeTripStore.load() }.getOrNull() ?: return null
        if (snapshot.trip.id != tripId) return null
        return snapshot.trip
    }

    /** A deterministic, union-merged tank/fill result. */
    private data class MergedTanks(
        val sessions: List<TankSession>,
        val activeTankNumber: Int?,
        val isFillingTank: Boolean,
        val fillingTankNumber: Int?,
    ) {
        /**
         * True when this merge advances past the live server tank state in any
         * dimension (different sessions, or different live scalars). When false
         * the marker can be cleared without a PATCH.
         */
        fun addsSomething(server: Trip): Boolean {
            if (sessions != server.tankSessions) return true
            return activeTankNumber != server.activeTankNumber ||
                isFillingTank != server.isFillingTank ||
                fillingTankNumber != server.fillingTankNumber
        }
    }

    /**
     * Conservative union-by-id merge that never drops a server tank session.
     * Sessions are keyed by stable [TankSession.id]; a server-only session is
     * kept as-is, a local-only session is added, and a session present in both
     * resolves to the more-complete record ([moreComplete]). Server session
     * order is preserved, then any new local sessions are appended. Live scalars
     * are reconciled conservatively against the merged set so an ended tank is
     * never reopened. Returns null only when the merge cannot be proven
     * non-destructive (a defensive guard that should not trigger given the union
     * construction).
     */
    private fun mergeTanks(server: Trip, local: Trip): MergedTanks? {
        val serverSessions = server.tankSessions
        val localSessions = local.tankSessions
        val localById = localSessions.associateBy { it.id }
        val serverIds = serverSessions.map { it.id }.toSet()

        // Keep every server session (in order), upgrading to the more-complete
        // record when the local snapshot also has it.
        val merged = ArrayList<TankSession>(serverSessions.size + localSessions.size)
        for (s in serverSessions) {
            val l = localById[s.id]
            merged.add(if (l != null) moreComplete(s, l) else s)
        }
        // Append local-only sessions (new tanks started on this device offline).
        for (l in localSessions) {
            if (l.id !in serverIds) merged.add(l)
        }

        // Defensive non-destructive guard: every server session id must survive.
        val mergedIds = merged.map { it.id }.toSet()
        if (!mergedIds.containsAll(serverIds)) return null

        // Live scalars: only assert local active/filling state when a matching
        // still-open session survives in the merged set; otherwise keep the
        // server scalar so an ended/closed tank is never reopened.
        val mergedById = merged.associateBy { it.id }
        val activeTankNumber = reconcileActiveTank(server, local, mergedById)
        val (isFillingTank, fillingTankNumber) = reconcileFilling(server, local, merged)

        return MergedTanks(
            sessions = merged,
            activeTankNumber = activeTankNumber,
            isFillingTank = isFillingTank,
            fillingTankNumber = fillingTankNumber,
        )
    }

    /**
     * Pick the more-complete of two records for the same session id: a closed
     * `endTime` beats an open one, and a closed `fillEndTime` beats an open
     * fill. When neither is strictly more complete the local edit wins as the
     * freshest local work, but any close already recorded on the server is
     * preserved so the merge can never reopen a server-closed session/fill.
     */
    private fun moreComplete(server: TankSession, local: TankSession): TankSession {
        val endTime = local.endTime ?: server.endTime
        val endRow = local.endRow ?: server.endRow
        val fillEndTime = local.fillEndTime ?: server.fillEndTime
        val fillStartTime = local.fillStartTime ?: server.fillStartTime
        return local.copy(
            endTime = endTime,
            endRow = endRow,
            fillStartTime = fillStartTime,
            fillEndTime = fillEndTime,
        )
    }

    /**
     * Conservative active-tank reconcile: keep the local active tank only when a
     * matching session is still open in the merged set; never reopen an ended
     * tank. When the local active tank no longer maps to an open merged session,
     * fall back to the server's active tank (or null when the server's active
     * session is itself now closed).
     */
    private fun reconcileActiveTank(
        server: Trip,
        local: Trip,
        mergedById: Map<String, TankSession>,
    ): Int? {
        val localActive = local.activeTankNumber
        if (localActive != null) {
            val stillOpen = mergedById.values.any { it.tankNumber == localActive && it.isOpen }
            if (stillOpen) return localActive
        }
        val serverActive = server.activeTankNumber
        if (serverActive != null) {
            val stillOpen = mergedById.values.any { it.tankNumber == serverActive && it.isOpen }
            if (stillOpen) return serverActive
        }
        return null
    }

    /**
     * Conservative filling reconcile: assert local filling state only when a
     * matching session still has an open fill (a non-null `fillStartTime` with a
     * null `fillEndTime`) in the merged set; otherwise keep the server filling
     * state when its session is still filling, else clear it. Never reopens a
     * completed fill.
     */
    private fun reconcileFilling(
        server: Trip,
        local: Trip,
        merged: List<TankSession>,
    ): Pair<Boolean, Int?> {
        fun openFillFor(number: Int?): TankSession? =
            number?.let { n -> merged.firstOrNull { it.tankNumber == n && it.fillStartTime != null && it.fillEndTime == null } }

        if (local.isFillingTank) {
            val open = openFillFor(local.fillingTankNumber)
            if (open != null) return true to open.tankNumber
        }
        if (server.isFillingTank) {
            val open = openFillFor(server.fillingTankNumber)
            if (open != null) return true to open.tankNumber
        }
        return false to null
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
