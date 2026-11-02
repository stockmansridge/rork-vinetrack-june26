package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.SprayCompletionResponse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant

/** Explicit new End intents only. Never scans historical Trips or rewrites their journals. */
class TrackedSprayCompletionSync(private val pending: PendingWriteRepository) {
    @Serializable
    data class Intent(val ownerId: String, val vineyardId: String, val tripId: String, val endTime: String, val sprayRecordId: String)
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private val lock = Mutex()

    /** Retry a partially saved End with its first requested time, never a replacement End time. */
    fun endTimeForRetry(ownerId: String, trip: Trip, proposed: String): String {
        val original = pending.list().firstOrNull {
            it.entityType == PendingEntityType.TRIP_SPRAY_COMPLETION && it.clientId == trip.id
        } ?: return proposed
        val intent = json.decodeFromString<Intent>(original.payloadJson)
        check(intent.ownerId == ownerId && intent.vineyardId == trip.vineyardId && intent.tripId == trip.id) {
            "Original spray completion intent retained; review required."
        }
        Instant.parse(intent.endTime)
        return intent.endTime
    }

    fun enqueue(ownerId: String, trip: Trip, endTime: String, sprayRecordId: String?) {
        if (trip.tripFunction != "spraying" || trip.entrySource == "manual" || trip.manualEntryId != null) return
        require(!sprayRecordId.isNullOrBlank()) { "Original linked Spray identity required." }
        Instant.parse(endTime)
        val original = pending.list().firstOrNull { it.entityType == PendingEntityType.TRIP_SPRAY_COMPLETION && it.clientId == trip.id }
        if (original != null) {
            val intent = json.decodeFromString<Intent>(original.payloadJson)
            check(intent.ownerId == ownerId && intent.vineyardId == trip.vineyardId && intent.tripId == trip.id && intent.sprayRecordId == sprayRecordId && sameTime(intent.endTime, endTime)) {
                "Original spray completion intent retained; review required."
            }
            return
        }
        pending.enqueue(PendingEntityType.TRIP_SPRAY_COMPLETION, PendingOpType.UPDATE,
            json.encodeToString(Intent.serializer(), Intent(ownerId, trip.vineyardId, trip.id, endTime, sprayRecordId)), trip.id)
    }

    suspend fun replay(
        ownerId: String, vineyardId: String, versions: Map<String, PendingWrite>,
        isCurrent: () -> Boolean,
        fetchTrip: suspend (String) -> Trip?,
        fetchSprays: suspend (String) -> List<SprayRecord>,
        dependenciesReady: (Trip) -> Boolean,
        expectedSprayIds: (Trip) -> Set<String> = { emptySet() },
        complete: suspend (String) -> SprayCompletionResponse,
        onVerified: (SprayRecord) -> Unit,
    ) {
        if (!lock.tryLock()) return
        try {
            for (candidate in pending.list().filter { it.entityType == PendingEntityType.TRIP_SPRAY_COMPLETION &&
                    it.status in setOf(PendingWriteStatus.PENDING, PendingWriteStatus.FAILED) && versions[it.id] == it }) {
                val intent = runCatching { json.decodeFromString<Intent>(candidate.payloadJson) }.getOrNull() ?: continue
                if (intent.ownerId != ownerId || intent.vineyardId != vineyardId || intent.tripId != candidate.clientId || !isCurrent()) continue
                val write = pending.claimReplay(candidate, versions) ?: continue
                fun current() = isCurrent() && pending.isCurrent(write)
                try {
                    val trip = fetchTrip(intent.tripId)
                    check(current())
                    check(trip != null && trip.id == intent.tripId && trip.vineyardId == vineyardId &&
                        trip.tripFunction == "spraying" && trip.entrySource != "manual" && trip.manualEntryId == null &&
                        trip.deletedAt == null && !trip.isActive && sameTime(trip.endTime, intent.endTime)) { "Waiting for original Trip End acknowledgement." }
                    check(dependenciesReady(trip)) { "Waiting for Trip dependencies." }
                    val before = fetchSprays(trip.id)
                    check(current())
                    val spray = before.singleOrNull() ?: error("Linked Spray unavailable or ambiguous.")
                    check(spray.id == intent.sprayRecordId && eligible(trip, spray) && setOf(spray.id).containsAll(expectedSprayIds(trip))) { "Linked Spray needs review." }
                    if (spray.endTime == null) {
                        check(dependenciesReady(trip) && current())
                        val response = complete(spray.id)
                        check(current() && response.serverConfirmed && response.sprayRecordId == spray.id &&
                            response.completionSource in setOf("trip_end", "existing") && sameTime(response.endTime, intent.endTime)) {
                            "Spray completion response did not match original End."
                        }
                    }
                    val afterTrip = fetchTrip(trip.id)
                    val after = fetchSprays(trip.id).singleOrNull()
                    check(current() && afterTrip != null && !afterTrip.isActive && afterTrip.deletedAt == null &&
                        afterTrip.id == trip.id && afterTrip.vineyardId == vineyardId && afterTrip.tripFunction == "spraying" &&
                        afterTrip.entrySource != "manual" && afterTrip.manualEntryId == null && sameTime(afterTrip.endTime, intent.endTime) &&
                        after != null && after.id == spray.id && completionIssue(afterTrip, listOf(after), expectedSprayIds(afterTrip)) == null && dependenciesReady(afterTrip)) {
                        "Spray completion readback not verified."
                    }
                    if (pending.removeIfCurrent(write)) onVerified(after)
                } catch (cancelled: CancellationException) { throw cancelled
                } catch (_: Exception) {
                    if (current()) pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED,
                        "Trip End / linked Spray completion not yet verified. Original intent retained.")
                }
            }
        } finally { lock.unlock() }
    }

    companion object {
        fun sameTime(a: String?, b: String?): Boolean = a != null && b != null &&
            runCatching { Instant.parse(a) == Instant.parse(b) }.getOrDefault(false)
        private fun eligible(trip: Trip, spray: SprayRecord): Boolean = spray.tripId == trip.id &&
            spray.vineyardId == trip.vineyardId && !spray.isTemplate && spray.entrySource != "manual" &&
            spray.manualEntryId == null && spray.deletedAt == null

        /** Null means completion evidence matches; no local mutation or inferred completion. */
        fun completionIssue(trip: Trip, sprays: List<SprayRecord>, expectedIds: Set<String> = emptySet()): String? {
            if (trip.tripFunction != "spraying" || trip.entrySource == "manual" || trip.manualEntryId != null) return null
            val spray = sprays.singleOrNull() ?: return "LINKED_SPRAY_UNAVAILABLE_OR_AMBIGUOUS"
            if (!eligible(trip, spray) || !setOf(spray.id).containsAll(expectedIds)) return "LINKED_SPRAY_IDENTITY_UNVERIFIED"
            if (spray.endTime == null) return "LINKED_SPRAY_COMPLETION_PENDING"
            if (!sameTime(trip.endTime, spray.endTime)) return "LINKED_SPRAY_END_TIME_MISMATCH"
            return null
        }
    }
}
