package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Durable, coalesced active-route change. The payload contains only row-plan fields. */
class TripRowPlanSync private constructor(
    private val fetchTrip: suspend (String) -> Trip?,
    private val updatePlan: suspend (String, Plan) -> Trip,
    private val pending: PendingWriteRepository,
) {
    constructor(repo: TripRepository, pending: PendingWriteRepository) : this(
        repo::fetchTrip,
        { id, plan -> repo.updateTripRowPlan(id, plan.pattern ?: "sequential", plan.sequence,
            plan.index, plan.current, plan.next) }, pending,
    )

    internal constructor(pending: PendingWriteRepository, fetchTrip: suspend (String) -> Trip?,
        updatePlan: suspend (String, Plan) -> Trip) : this(fetchTrip, updatePlan, pending)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val replayLock = Mutex()

    @Serializable
    data class Plan(
        val pattern: String?, val sequence: List<Double>, val index: Int,
        val current: Double?, val next: Double?,
    ) {
        companion object {
            fun from(trip: Trip) = Plan(trip.trackingPattern, trip.rowSequence, trip.sequenceIndex,
                trip.currentRowNumber, trip.nextRowNumber)
        }
    }

    @Serializable
    data class Payload(val tripId: String, val baseline: Plan, val target: Plan,
        val earlierLocalTargets: List<Plan> = emptyList())

    /** Keep the first server baseline while replacing the last locally requested route. */
    fun enqueue(before: Trip, after: Trip) {
        require(before.id == after.id)
        val previous = pending.list().firstOrNull { it.clientId == before.id &&
            it.entityType == PendingEntityType.TRIP_ROW_PLAN && it.status in PendingWriteStatus.unresolved }
        val old = previous?.let {
            runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull()
        }
        val baseline = old?.baseline ?: Plan.from(before)
        val payload = json.encodeToString(Payload.serializer(), Payload(before.id, baseline, Plan.from(after),
            old?.let { (it.earlierLocalTargets + it.target).distinct() } ?: emptyList()))
        pending.upsertCoalesced(PendingEntityType.TRIP_ROW_PLAN, before.id, payload)
    }

    suspend fun replayAll(permittedWrites: Map<String, com.rork.vinetrack.data.model.PendingWrite>? = null, onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter { it.entityType == PendingEntityType.TRIP_ROW_PLAN &&
                it.status in setOf(PendingWriteStatus.PENDING, PendingWriteStatus.FAILED) &&
                (permittedWrites == null || permittedWrites[it.id] == it) }
            for (candidate in candidates) {
                val write = pending.claimReplay(candidate, permittedWrites) ?: continue
                val payload = runCatching { json.decodeFromString(Payload.serializer(), write.payloadJson) }.getOrNull()
                if (payload == null || payload.tripId != write.clientId) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "Couldn't read the changed route.")
                    continue
                }
                if (TripStartSync.hasUnresolvedStart(pending, payload.tripId)) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED, "Waiting for this trip to start syncing.")
                    continue
                }
                try {
                    val server = fetchTrip(payload.tripId)
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (!pending.isCurrent(write)) continue
                    if (server == null || !server.isActive) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "This trip is no longer active on the server.")
                        continue
                    }
                    val serverPlan = Plan.from(server)
                    // A different server plan is never overwritten. An already-landed target is idempotent.
                    if (!isCompatible(serverPlan, payload)) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED,
                            "This trip's route was changed elsewhere. Open it to review.")
                        continue
                    }
                    if (TripStartSync.hasUnresolvedStart(pending, payload.tripId)) {
                        pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED, "Waiting for this trip to start syncing.")
                        continue
                    }
                    val result = if (serverPlan == payload.target) server else updatePlan(payload.tripId, payload.target)
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (pending.removeIfCurrent(write)) onSynced(result)
                } catch (e: BackendError.Server) {
                    if (e.code in 500..599) retry(write, "Server unavailable. Retry syncing the route.")
                    else pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "Route save was rejected (${e.code}).")
                } catch (e: kotlinx.coroutines.CancellationException) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED, "Route sync was interrupted. Ready to retry.")
                    throw e
                } catch (e: Exception) {
                    retry(write, "Couldn't sync the route. Retry when connected.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    companion object {
        /** Coverage can advance the index without changing the route; another pattern/sequence cannot. */
        fun isCompatible(server: Plan, payload: Payload): Boolean =
            (listOf(payload.baseline, payload.target) + payload.earlierLocalTargets).any {
                it.pattern == server.pattern && it.sequence == server.sequence
            }
    }

    private fun retry(write: com.rork.vinetrack.data.model.PendingWrite, message: String) {
        pending.retryIfCurrent(write, message)
    }
}
