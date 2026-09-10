package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.BuildConfig
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.Trip
import java.time.Instant
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Decode result that distinguishes an empty store from unreadable persisted evidence. */
data class LocalEvidenceRead<T>(val items: List<T>, val issue: String? = null)

/** Immutable, vineyard-scoped evidence captured before cache replacement or replay. */
class RecoverySnapshotStore internal constructor(
    private val readRaw: (String) -> String?,
    private val writeRawIfAbsent: (String, String) -> Boolean,
) {
    constructor(context: Context) : this(
        readRaw = { key -> context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(key, null) },
        writeRawIfAbsent = { key, value ->
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            synchronized(prefs) {
                if (prefs.contains(key)) false else prefs.edit().putString(key, value).commit()
            }
        },
    )

    @Serializable
    data class SourceStatus(val source: String, val status: String, val itemCount: Int)

    @Serializable
    data class ExcludedEvidence(val source: String, val itemId: String?, val reason: String)

    @Serializable
    data class Snapshot(
        val formatVersion: Int = 2,
        val vineyardId: String,
        val appVersion: String,
        val buildVersion: Long,
        val snapshotAt: String,
        val source: String,
        val pendingWrites: List<PendingWrite>,
        val captureEvidence: List<PinCaptureEvidenceStore.Evidence>,
        val cachedPins: List<Pin>,
        val cachedTrips: List<Trip>,
        val activeTrip: Trip?,
        val sourceStatuses: List<SourceStatus>,
        val excludedOrUnreadable: List<ExcludedEvidence>,
        val coordinateAssessmentWarning: String = "Coordinates are evidence candidates only. Exact IDs do not prove a coordinate is genuine; compare capture provenance and reject copied stale fixes.",
    )

    fun load(vineyardId: String): Snapshot? = readRaw(key(vineyardId))?.let { raw ->
        runCatching { json.decodeFromString(Snapshot.serializer(), raw) }.getOrNull()
    }

    fun saveIfAbsent(snapshot: Snapshot): Snapshot {
        val encoded = json.encodeToString(Snapshot.serializer(), snapshot)
        writeRawIfAbsent(key(snapshot.vineyardId), encoded)
        return load(snapshot.vineyardId) ?: snapshot
    }

    companion object {
        private const val PREFS = "vinetrack_recovery_snapshots_v2"
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }
        private fun key(vineyardId: String): String = "snapshot_$vineyardId"

        /** Captures current local stores once; all later calls return the original bytes. */
        fun captureBeforeMutation(context: Context, vineyardId: String): Snapshot {
            val store = RecoverySnapshotStore(context)
            store.load(vineyardId)?.let { return it }
            val cache = DomainCacheStore(context)
            val pinRead = cache.loadPinsForRecovery(vineyardId)
            val tripRead = cache.loadTripsForRecovery(vineyardId)
            val pendingRead = PendingWriteStore(context).loadForRecovery()
            val cachedPins = pinRead.items
            val cachedTrips = tripRead.items
            val activeTrip = ActiveTripStore(context).load()?.takeIf { it.vineyardId == vineyardId }?.trip
            val captureEvidence = PinCaptureEvidenceStore(context).load().filter { it.vineyardId == vineyardId }
            val tripIds = cachedTrips.mapTo(mutableSetOf()) { it.id }.apply { activeTrip?.id?.let(::add) }
            val excluded = mutableListOf<ExcludedEvidence>()
            pinRead.issue?.let { excluded += ExcludedEvidence("cached_pins", null, it) }
            tripRead.issue?.let { excluded += ExcludedEvidence("cached_trips", null, it) }
            pendingRead.issue?.let { excluded += ExcludedEvidence("pending_writes", null, it) }
            val pendingWrites = pendingRead.items.filter { write ->
                val payloadVineyard = payloadVineyardId(write.payloadJson)
                val isTripEvidence = write.entityType.startsWith("TRIP") && write.clientId in tripIds
                val include = payloadVineyard == vineyardId || isTripEvidence
                if (!include && (write.entityType == PendingEntityType.PIN || write.entityType.startsWith("TRIP"))) {
                    excluded += ExcludedEvidence(
                        source = "pending_writes",
                        itemId = write.id,
                        reason = if (payloadVineyard == null) "Vineyard could not be read and the write could not be linked to a cached trip." else "Belongs to another vineyard.",
                    )
                }
                include
            }
            val snapshot = Snapshot(
                vineyardId = vineyardId,
                appVersion = BuildConfig.VERSION_NAME,
                buildVersion = BuildConfig.VERSION_CODE.toLong(),
                snapshotAt = Instant.now().toString(),
                source = "before_vineyard_load_refresh_or_replay",
                pendingWrites = pendingWrites,
                captureEvidence = captureEvidence,
                cachedPins = cachedPins,
                cachedTrips = cachedTrips,
                activeTrip = activeTrip,
                sourceStatuses = listOf(
                    SourceStatus("pending_writes", if (pendingRead.issue == null) "read" else "unreadable", pendingWrites.size),
                    SourceStatus("pin_capture_evidence", "read", captureEvidence.size),
                    SourceStatus("cached_pins", if (pinRead.issue == null) "read" else "unreadable", cachedPins.size),
                    SourceStatus("cached_trips", if (tripRead.issue == null) "read" else "unreadable", cachedTrips.size),
                    SourceStatus("active_trip", "read", if (activeTrip == null) 0 else 1),
                ),
                excludedOrUnreadable = excluded,
            )
            return store.saveIfAbsent(snapshot)
        }

        private fun payloadVineyardId(payload: String): String? = runCatching {
            json.parseToJsonElement(payload).jsonObject["vineyard_id"]?.jsonPrimitive?.content
        }.getOrNull()
    }
}
