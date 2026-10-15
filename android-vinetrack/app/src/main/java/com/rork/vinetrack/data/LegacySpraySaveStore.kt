package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.FieldStoreAccess
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*

/** Separate legacy creation containment. Unknown REST outcomes are never an operation receipt. */
class LegacySpraySaveStore(context: Context) {
    @Serializable data class TripIntent(
        val id: String, val vineyardId: String, val paddockId: String?, val paddockIds: List<String>,
        val paddockName: String?, val personName: String?, val startTime: String, val tractorId: String?,
        val actorId: String, val trackingPattern: String, val rowSequence: List<Double>,
        val totalTanks: Int?, val createdAt: String,
    )
    @Serializable enum class Stage { PREPARED, TRIP_UNKNOWN, TRIP_CONFIRMED, RECORD_UNKNOWN, COMPLETE }
    @Serializable data class Attempt(
        val actorId: String, val identityEpoch: Long, val trip: TripIntent,
        val recordId: String, val input: SprayRecordRepository.SprayInput,
        val stage: Stage = Stage.PREPARED,
    )
    private val access = FieldStoreAccess(context)
    private val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = false }
    private fun read(): List<Attempt> {
        val items = prefs.getString("attempts", null)?.let { json.decodeFromString<List<Attempt>>(it) } ?: emptyList()
        check(items.map { it.recordId }.distinct().size == items.size && items.map { it.trip.id }.distinct().size == items.size)
        items.forEach(::validate)
        return items
    }
    private fun validate(item: Attempt) {
        listOf(item.actorId, item.trip.vineyardId, item.trip.id, item.recordId).forEach { java.util.UUID.fromString(it) }
        check(item.actorId == item.trip.actorId && item.input.tripId == item.trip.id && item.trip.rowSequence.isEmpty() &&
            item.identityEpoch >= 0 && item.input.operationalBlocker() == null)
    }
    private fun write(items: List<Attempt>) {
        val value = json.encodeToString(items)
        check(prefs.edit().putString("attempts", value).commit() && prefs.getString("attempts", null) == value) { "Legacy save could not be durably retained." }
    }
    fun prepare(item: Attempt) = access.admittedForOwner(item.actorId) { synchronized(this) {
        validate(item)
        check(item.identityEpoch == access.identityEpoch)
        val items = read()
        val previous = items.firstOrNull { it.recordId == item.recordId || it.trip.id == item.trip.id }
        if (previous != null) check(previous.copy(stage = Stage.PREPARED) == item)
        else {
            check(items.none { it.actorId == item.actorId && it.trip.vineyardId == item.trip.vineyardId && it.stage != Stage.COMPLETE }) { MESSAGE }
            write(items + item)
        }
    } }
    fun mark(item: Attempt, stage: Stage) = access.admittedForOwner(item.actorId) { synchronized(this) {
        check(item.identityEpoch == access.identityEpoch)
        val items = read()
        val index = items.indexOfFirst { it.recordId == item.recordId }
        check(index >= 0 && items[index].copy(stage = Stage.PREPARED) == item.copy(stage = Stage.PREPARED))
        val before = items[index].stage
        check((before == Stage.PREPARED && stage == Stage.TRIP_UNKNOWN) ||
            (before == Stage.TRIP_UNKNOWN && stage == Stage.TRIP_CONFIRMED) ||
            (before == Stage.TRIP_CONFIRMED && stage == Stage.RECORD_UNKNOWN) ||
            (before == Stage.RECORD_UNKNOWN && stage == Stage.COMPLETE))
        write(items.mapIndexed { i, value -> if (i == index) value.copy(stage = stage) else value })
    } }
    /** Only PREPARED is provably unsent: every transport call follows a checked UNKNOWN commit.
     * Once claimed, even a cancellation immediately before HTTP stays uncertain, never reset to PREPARED.
     */
    suspend fun sendPrepared(
        item: Attempt,
        isAuthorityCurrent: () -> Boolean,
        sendTrip: suspend (TripIntent) -> com.rork.vinetrack.data.model.Trip,
        sendRecord: suspend (Attempt) -> com.rork.vinetrack.data.model.SprayRecord,
    ): Pair<com.rork.vinetrack.data.model.Trip, com.rork.vinetrack.data.model.SprayRecord> {
        check(isAuthorityCurrent())
        // This atomic transition also prevents concurrent reconnect/save paths from double sending.
        mark(item, Stage.TRIP_UNKNOWN)
        check(isAuthorityCurrent())
        val trip = sendTrip(item.trip)
        check(isAuthorityCurrent())
        check(trip.id == item.trip.id && trip.vineyardId == item.trip.vineyardId && !trip.isActive && trip.endTime == null)
        mark(item, Stage.TRIP_CONFIRMED)
        mark(item, Stage.RECORD_UNKNOWN)
        check(isAuthorityCurrent())
        val record = sendRecord(item)
        check(isAuthorityCurrent())
        check(record.id == item.recordId && record.tripId == item.trip.id && record.vineyardId == item.trip.vineyardId)
        mark(item, Stage.COMPLETE)
        return trip to record
    }

    /** Uncertain REST outcomes remain contained until immutable acceptance can be verified. */
    fun pending(vineyardId: String): List<Attempt> = access.admitted { synchronized(this) {
        read().filter { it.actorId == access.ownerUserId && it.trip.vineyardId == vineyardId && it.stage != Stage.COMPLETE }
    } }
    fun blocks(tripId: String): Boolean = access.admitted { synchronized(this) {
        read().any { it.trip.id == tripId && it.stage != Stage.COMPLETE }
    } }
    companion object {
        /** Successful initial REST responses must echo all submitted fields; a recovery read is NOT this proof. */
        fun requireEcho(expected: JsonObject, actual: JsonObject) {
            fun same(a: JsonElement, b: JsonElement): Boolean {
                if (a is JsonObject && b is JsonObject) return a.keys.all { key -> b[key]?.let { same(a.getValue(key), it) } == true }
                if (a is JsonArray && b is JsonArray) return a.size == b.size && a.indices.all { same(a[it], b[it]) }
                if (a is JsonPrimitive && b is JsonPrimitive && a != JsonNull && b != JsonNull) {
                    if (!a.isString && !b.isString) {
                        val x = a.content.toBigDecimalOrNull(); val y = b.content.toBigDecimalOrNull()
                        if (x != null && y != null) return x.compareTo(y) == 0
                    }
                    if (a.isString && b.isString) {
                        val x = runCatching { java.time.Instant.parse(a.content) }.getOrNull()
                        val y = runCatching { java.time.Instant.parse(b.content) }.getOrNull()
                        if (x != null && y != null) return x == y
                    }
                }
                return a == b
            }
            check(same(expected, actual)) { MESSAGE }
        }
        const val PREFERENCES = "vinetrack_legacy_spray_saves_v1"
        const val UNSENT_MESSAGE = "Spray job saved on this device — not sent yet. The original job will send when online with the same authorised account. Start is unavailable until both original writes are confirmed."
        fun status(items: List<Attempt>, currentEpoch: Long? = null): String? = when {
            items.isEmpty() -> null
            currentEpoch != null && items.any { it.identityEpoch != currentEpoch } ->
                "Retained spray work belongs to an earlier account session. It is protected and was not reassigned or sent; account recovery is required."
            items.any { it.stage != Stage.PREPARED } -> MESSAGE
            else -> UNSENT_MESSAGE
        }
        const val MESSAGE = "A legacy Save for Later attempt is retained for review. No duplicate or rollback was attempted. Verified paired-create recovery is required before retry or dependent sync."
    }
}
