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
        val rpc: LegacySprayPairReceipt.Request? = null,
        val rpcClaimed: Boolean = false,
        val candidate: LegacySprayPairReceipt.Receipt? = null,
        val verified: LegacySprayPairReceipt.Receipt? = null,
        val receiptBlocker: String? = null,
        val startRequested: Boolean = false,
        val startEngineHours: Double? = null,
        val startCompleted: Boolean = false,
    ) {
        val isHeld: Boolean get() = rpc == null || verified?.status != "accepted"

        /** Calculator previews mint temporary line IDs. Matching never replaces the frozen request IDs. */
        fun matchesStartInput(proposed: SprayRecordRepository.SprayInput): Boolean {
            if (proposed.tripId != null && proposed.tripId != trip.id) return false
            if (proposed.tanks.size != input.tanks.size) return false
            val tanks = proposed.tanks.zip(input.tanks).map { (candidate, original) ->
                if (candidate.chemicals.size != original.chemicals.size) return false
                candidate.copy(id = original.id, chemicals = candidate.chemicals.zip(original.chemicals).map { (chemical, frozen) ->
                    val snapshot = chemical.chemicalSnapshot
                    val originalSnapshot = frozen.chemicalSnapshot
                    // Only the save-time clock generated with this application is incidental.
                    // Snapshot presence and every identity/classification/rate/provenance fact still compare exactly.
                    val comparableSnapshot = if (snapshot != null && originalSnapshot != null &&
                        snapshot.capturedAt == proposed.startTime && originalSnapshot.capturedAt == input.startTime) {
                        snapshot.copy(capturedAt = originalSnapshot.capturedAt)
                    } else snapshot
                    chemical.copy(id = frozen.id, chemicalSnapshot = comparableSnapshot)
                })
            }
            return input == proposed.copy(tripId = trip.id, date = input.date, startTime = input.startTime, tanks = tanks)
        }
    }
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
        check(item.startEngineHours == null || item.startEngineHours.isFinite() && item.startEngineHours >= 0)
        check(!item.startCompleted || item.startRequested && item.verified?.status == "accepted")
        item.rpc?.let { request ->
            java.util.UUID.fromString(request.operation)
            check(request.trip.keys.all { it in LegacySprayPairReceipt.tripKeys } && request.record.keys.all { it in LegacySprayPairReceipt.recordKeys })
            check(request.trip["id"]?.jsonPrimitive?.content == item.trip.id && request.record["id"]?.jsonPrimitive?.content == item.recordId &&
                request.trip["vineyard_id"]?.jsonPrimitive?.content == item.trip.vineyardId && request.record["vineyard_id"]?.jsonPrimitive?.content == item.trip.vineyardId &&
                request.record["trip_id"]?.jsonPrimitive?.content == item.trip.id && request.trip["created_by"]?.jsonPrimitive?.content == item.actorId &&
                request.record["created_by"]?.jsonPrimitive?.content == item.actorId)
            check(item.stage == Stage.PREPARED || item.stage == Stage.COMPLETE && item.verified?.status == "accepted")
            item.candidate?.validate(item); item.verified?.validate(item)
        }
    }
    private fun write(items: List<Attempt>) {
        val value = json.encodeToString(items)
        check(prefs.edit().putString("attempts", value).commit() && prefs.getString("attempts", null) == value) { "Legacy save could not be durably retained." }
    }
    fun prepare(item: Attempt) = access.admittedForOwner(item.actorId) { synchronized(this) {
        OperationalWrites.requireWrite(item.trip.vineyardId)
        validate(item)
        check(item.identityEpoch == access.identityEpoch)
        val items = read()
        val previous = items.firstOrNull { it.recordId == item.recordId || it.trip.id == item.trip.id }
        if (previous != null) check(previous.copy(stage = Stage.PREPARED) == item)
        else {
            check(items.none { it.actorId == item.actorId && it.trip.vineyardId == item.trip.vineyardId && (it.isHeld || it.startRequested && !it.startCompleted) }) { MESSAGE }
            write(items + item)
        }
    } }
    fun mark(item: Attempt, stage: Stage) = access.admittedForOwner(item.actorId) { synchronized(this) {
        check(item.rpc == null) { "RPC attempts require immutable receipt transitions." }
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
    /** Retired REST transport seam retained for historical containment regressions only.
     * No production caller uses this method. Even COMPLETE stays held without an immutable RPC receipt.
     */
    internal suspend fun sendPrepared(
        item: Attempt,
        isAuthorityCurrent: () -> Boolean,
        sendTrip: suspend (TripIntent) -> com.rork.vinetrack.data.model.Trip,
        sendRecord: suspend (Attempt) -> com.rork.vinetrack.data.model.SprayRecord,
    ): Pair<com.rork.vinetrack.data.model.Trip, com.rork.vinetrack.data.model.SprayRecord> {
        check(item.rpc == null) { "RPC attempts cannot use the old REST writer." }
        check(isAuthorityCurrent())
        OperationalWrites.requireWrite(item.trip.vineyardId)
        // This atomic transition also prevents concurrent reconnect/save paths from double sending.
        mark(item, Stage.TRIP_UNKNOWN)
        check(isAuthorityCurrent())
        val trip = sendTrip(item.trip)
        check(isAuthorityCurrent())
        check(trip.id == item.trip.id && trip.vineyardId == item.trip.vineyardId && !trip.isActive && trip.endTime == null)
        mark(item, Stage.TRIP_CONFIRMED)
        OperationalWrites.requireWrite(item.trip.vineyardId)
        mark(item, Stage.RECORD_UNKNOWN)
        check(isAuthorityCurrent())
        val record = sendRecord(item)
        check(isAuthorityCurrent())
        check(record.id == item.recordId && record.tripId == item.trip.id && record.vineyardId == item.trip.vineyardId)
        mark(item, Stage.COMPLETE)
        return trip to record
    }

    /** RPC attempts never enter the legacy REST transition chain. UNKNOWN recovery cannot authorize create. */
    suspend fun sendReceipt(item: Attempt, isAuthorityCurrent: () -> Boolean,
        transport: suspend (String, LegacySprayPairReceipt.Request) -> LegacySprayPairReceipt.Receipt): Boolean {
        check(isAuthorityCurrent())
        var current = access.admittedForOwner(item.actorId) { synchronized(this) {
            check(item.identityEpoch == access.identityEpoch)
            read().single { it.recordId == item.recordId }.also {
                check(it.rpc == item.rpc && it.trip == item.trip && it.input == item.input && it.verified == null && it.stage == Stage.PREPARED)
            }
        } }
        val request = current.rpc ?: error(MESSAGE) // Old REST attempts are never adopted.
        if (!current.rpcClaimed) {
            OperationalWrites.requireWrite(current.trip.vineyardId)
            val unclaimed = current
            current = current.copy(rpcClaimed = true)
            replaceReceipt(item, current)
            check(isAuthorityCurrent())
            val candidate = try { transport("save_legacy_spray_pair_v1", request) }
            catch (held: VineyardWriteAuthority.Restricted) {
                // Typed rejection confirms no write; preserve the original unclaimed journal.
                replaceReceipt(current, unclaimed)
                throw held
            }
            check(isAuthorityCurrent()); candidate.validate(current)
            val next = current.copy(candidate = candidate)
            replaceReceipt(current, next); current = next
        }
        check(isAuthorityCurrent())
        val receipt = transport("recover_legacy_spray_pair_v1", request)
        check(isAuthorityCurrent()); receipt.validate(current)
        check(current.candidate == null || current.candidate == receipt)
        val next = current.copy(verified = receipt, stage = if (receipt.status == "accepted") Stage.COMPLETE else Stage.PREPARED,
            receiptBlocker = if (receipt.status == "rejected") "Original spray save rejected: ${receipt.code}. Evidence retained; Start is blocked." else null)
        replaceReceipt(current, next)
        return receipt.status == "accepted"
    }
    private fun replaceReceipt(before: Attempt, after: Attempt) = access.admittedForOwner(before.actorId) { synchronized(this) {
        check(before.identityEpoch == access.identityEpoch)
        val items = read(); val index = items.indexOfFirst { it.recordId == before.recordId }
        check(index >= 0 && items[index] == before)
        write(items.mapIndexed { i, value -> if (i == index) after else value })
    } }

    /** Includes accepted pairs whose foreground Start has not finished; acceptance is not activation. */
    fun retainedStart(vineyardId: String): Attempt? = access.admitted { synchronized(this) {
        val starts = read().filter { it.actorId == access.ownerUserId && it.trip.vineyardId == vineyardId && it.startRequested && !it.startCompleted }
        check(starts.size <= 1) { MESSAGE }
        starts.singleOrNull()?.also { check(it.identityEpoch == access.identityEpoch) { MESSAGE } }
    } }

    /** Identity is evidence for inspection, never permission to activate an older unflagged attempt.
     * Recipe/day matches are ambiguous candidates, not job identity. Return ALL candidates rather than pick one.
     * A separate job remains available through explicit Save for Later -> inspect/start the chosen saved UUID.
     */
    fun olderAcceptedMatch(
        vineyardId: String, input: SprayRecordRepository.SprayInput, blocks: List<String>, pattern: String,
        vineyardTimezone: String? = null,
    ): List<Attempt> = access.admitted { synchronized(this) {
        val zone = vineyardTimezone?.let { runCatching { java.time.ZoneId.of(it) }.getOrNull() }
        fun day(value: String): java.time.LocalDate? =
            runCatching { java.time.LocalDate.parse(value) }.getOrNull()
                ?: zone?.let { runCatching { java.time.OffsetDateTime.parse(value).atZoneSameInstant(it).toLocalDate() }.getOrNull() }
        val proposedDay = day(input.date)
        read().filter { attempt ->
            if (attempt.actorId != access.ownerUserId || attempt.trip.vineyardId != vineyardId || attempt.startRequested ||
                attempt.verified?.status != "accepted") return@filter false
            // Explicit parent identity survives any clock/day/recipe change; it must be inspected as that original.
            if (input.tripId != null) return@filter input.tripId == attempt.trip.id
            val originalDay = day(attempt.input.date)
            val couldBeSameDay = originalDay == null || proposedDay == null || originalDay == proposedDay
            couldBeSameDay && attempt.trip.paddockIds == blocks && attempt.trip.trackingPattern == pattern &&
                attempt.matchesStartInput(input)
        }.also { candidates ->
            check(candidates.all { it.identityEpoch == access.identityEpoch }) { MESSAGE }
        }
    } }

    /** Mark only after the original trip has a durable owned active snapshot and activation marker. */
    fun completeStart(item: Attempt) = access.admittedForOwner(item.actorId) { synchronized(this) {
        val items = read()
        val current = items.single { it.recordId == item.recordId }
        check(current.identityEpoch == access.identityEpoch && current.startRequested && current.verified?.status == "accepted")
        write(items.map { if (it.recordId == item.recordId) current.copy(startCompleted = true) else it })
    } }

    /** Uncertain REST outcomes remain contained until immutable acceptance can be verified. */
    fun pending(vineyardId: String): List<Attempt> = access.admitted { synchronized(this) {
        read().filter { it.actorId == access.ownerUserId && it.trip.vineyardId == vineyardId && it.isHeld }
    } }
    fun blocks(tripId: String): Boolean = access.admitted { synchronized(this) {
        read().any { it.trip.id == tripId && it.isHeld }
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
        const val UNSENT_MESSAGE = "Spray job saved on this device — not sent yet. The original job will send when online with the same authorised account. Start is unavailable until the original pair has a verified acceptance receipt."
        fun status(items: List<Attempt>, currentEpoch: Long? = null): String? = when {
            items.isEmpty() -> null
            currentEpoch != null && items.any { it.identityEpoch != currentEpoch } ->
                "Retained spray work belongs to an earlier account session. It is protected and was not reassigned or sent; account recovery is required."
            items.any { it.verified?.status == "rejected" } -> items.first { it.verified?.status == "rejected" }.receiptBlocker
            items.any { it.receiptBlocker != null } -> items.first { it.receiptBlocker != null }.receiptBlocker
            items.any { it.stage != Stage.PREPARED || it.rpcClaimed || it.rpc == null } -> MESSAGE
            else -> UNSENT_MESSAGE
        }
        const val MESSAGE = "A legacy Save for Later attempt is retained for review. No duplicate or rollback was attempted. Verified paired-create recovery is required before retry or dependent sync."
    }
}
