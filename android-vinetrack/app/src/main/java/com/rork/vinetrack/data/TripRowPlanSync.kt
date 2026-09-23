package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.Trip
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Durable, coalesced active-route change. The payload contains only row-plan fields. */
class TripRowPlanSync(
    private val repo: TripRepository,
    private val pending: PendingWriteRepository,
) {
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

    suspend fun replayAll(onSynced: (Trip) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter { it.entityType == PendingEntityType.TRIP_ROW_PLAN &&
                it.status in setOf(PendingWriteStatus.PENDING, PendingWriteStatus.FAILED) }
            for (write in candidates) {
                // Another route change may have superseded this candidate before its turn.
                val current = pending.list().firstOrNull { it.id == write.id }
                if (current?.payloadJson != write.payloadJson) continue
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching { json.decodeFromString(Payload.serializer(), write.payloadJson) }.getOrNull()
                if (payload == null || payload.tripId != write.clientId) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the changed route.")
                    continue
                }
                if (TripStartSync.hasUnresolvedStart(pending, payload.tripId)) {
                    pending.updateStatus(write.id, PendingWriteStatus.FAILED, "Waiting for this trip to start syncing.")
                    continue
                }
                try {
                    val server = repo.fetchTrip(payload.tripId)
                    if (server == null || !server.isActive) {
                        pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "This trip is no longer active on the server.")
                        continue
                    }
                    val serverPlan = Plan.from(server)
                    // A different server plan is never overwritten. An already-landed target is idempotent.
                    if (!isCompatible(serverPlan, payload)) {
                        pending.updateStatus(write.id, PendingWriteStatus.BLOCKED,
                            "This trip's route was changed elsewhere. Open it to review.")
                        continue
                    }
                    val result = if (serverPlan == payload.target) server else repo.updateTripRowPlan(
                        id = payload.tripId,
                        trackingPattern = payload.target.pattern ?: "sequential",
                        rowSequence = payload.target.sequence,
                        sequenceIndex = payload.target.index,
                        currentRowNumber = payload.target.current,
                        nextRowNumber = payload.target.next,
                    )
                    if (pending.list().firstOrNull { it.id == write.id }?.payloadJson == write.payloadJson) {
                        pending.remove(write.id)
                        onSynced(result)
                    }
                } catch (e: BackendError.Server) {
                    if (e.code in 500..599) retry(write, "Server unavailable. Retry syncing the route.")
                    else pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Route save was rejected (${e.code}).")
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
        pending.incrementAttempt(write.id)
        pending.updateStatus(write.id, if (write.attemptCount + 1 >= 8) PendingWriteStatus.BLOCKED
            else PendingWriteStatus.FAILED, message)
    }
}
