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

/**
 * Immutable, vineyard-scoped evidence captured before cache replacement or replay.
 *
 * Durability rule: `SharedPreferences` publishes a value to its in-memory map
 * BEFORE the disk write completes, so a `commit()` that returns false can still
 * leave a readable value behind. Reading that value back through the same
 * preferences object therefore proves nothing. Only a `commit()` that returns
 * true is treated as durable; a failed write is remembered for the life of the
 * process so its visible-but-unproven value can never later be mistaken for a
 * preserved snapshot.
 */
class RecoverySnapshotStore internal constructor(
    private val readRaw: (String) -> String?,
    private val writeRawIfAbsent: (String, String) -> Boolean,
    private val rewriteUnprovenRaw: (String, String) -> Boolean = { _, _ -> false },
    private val unprovenWrites: MutableMap<String, String> = processUnprovenWrites,
) {
    constructor(context: Context) : this(
        readRaw = { key -> context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(key, null) },
        writeRawIfAbsent = { key, value ->
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            synchronized(prefs) {
                if (prefs.contains(key)) false else prefs.edit().putString(key, value).commit()
            }
        },
        rewriteUnprovenRaw = { key, value ->
            // Only ever reached for a key whose own durable write failed in this
            // process, so this can never overwrite a valid or unreadable original.
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            synchronized(prefs) { prefs.edit().putString(key, value).commit() }
        },
    )

    @Serializable
    data class SourceStatus(val source: String, val status: String, val itemCount: Int)

    @Serializable
    data class ExcludedEvidence(val source: String, val itemId: String?, val reason: String)

    @Serializable
    data class Snapshot(
        val formatVersion: Int = 3,
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
        val coordinateAssessmentWarning: String = COORDINATE_WARNING,
    )

    @Serializable
    data class CurrentEvidence(
        val collectedAt: String,
        val provenance: String = "current_local_stores_at_export_time_not_part_of_original_snapshot",
        val pendingWrites: List<PendingWrite>,
        val captureEvidence: List<PinCaptureEvidenceStore.Evidence>,
        val cachedPins: List<Pin>,
        val cachedTrips: List<Trip>,
        val activeTrip: Trip?,
        val sourceStatuses: List<SourceStatus>,
        val excludedOrUnreadable: List<ExcludedEvidence>,
        val coordinateAssessmentWarning: String = COORDINATE_WARNING,
    )

    @Serializable
    data class ExportBundle(
        val formatVersion: Int = 1,
        val originalPreMutationSnapshot: Snapshot,
        val currentEvidence: CurrentEvidence,
        val separationWarning: String = "Current evidence was collected later and must not be interpreted as evidence that existed before refresh or replay.",
    )

    internal data class ReplayScope(
        val vineyardIds: Set<String>,
        val unresolvedWriteIds: Set<String>,
    )

    sealed interface LoadResult {
        data object Missing : LoadResult
        data class Valid(val snapshot: Snapshot) : LoadResult
        data class Unreadable(val originalBytes: String) : LoadResult
    }

    sealed interface SaveResult {
        val isPreserved: Boolean

        data class Existing(val snapshot: Snapshot) : SaveResult { override val isPreserved: Boolean = true }
        data class Persisted(val snapshot: Snapshot) : SaveResult { override val isPreserved: Boolean = true }
        data object Failed : SaveResult { override val isPreserved: Boolean = false }
        data class ExistingUnreadable(val originalBytes: String) : SaveResult { override val isPreserved: Boolean = false }
    }

    fun loadResult(vineyardId: String): LoadResult {
        val raw = readRaw(key(vineyardId)) ?: return LoadResult.Missing
        val snapshot = runCatching { json.decodeFromString(Snapshot.serializer(), raw) }.getOrNull()
        return if (snapshot == null) LoadResult.Unreadable(raw) else LoadResult.Valid(snapshot)
    }

    fun load(vineyardId: String): Snapshot? = (loadResult(vineyardId) as? LoadResult.Valid)?.snapshot

    /**
     * True when a durable write for this vineyard already failed in this process,
     * so any currently readable value is unproven in-memory state.
     */
    fun hasUnprovenWrite(vineyardId: String): Boolean = unprovenWrites.containsKey(key(vineyardId))

    /**
     * Never overwrites an existing valid snapshot or the bytes of an unreadable
     * original. A write is only reported as preserved when the durable commit
     * itself succeeded — never on a read-back of possibly in-memory-only data.
     */
    fun saveIfAbsent(snapshot: Snapshot): SaveResult {
        val storeKey = key(snapshot.vineyardId)
        unprovenWrites[storeKey]?.let { retained -> return retryUnprovenWrite(storeKey, retained) }
        when (val existing = loadResult(snapshot.vineyardId)) {
            is LoadResult.Valid -> return SaveResult.Existing(existing.snapshot)
            is LoadResult.Unreadable -> return SaveResult.ExistingUnreadable(existing.originalBytes)
            LoadResult.Missing -> Unit
        }
        val encoded = json.encodeToString(Snapshot.serializer(), snapshot)
        if (!writeRawIfAbsent(storeKey, encoded)) {
            return when (val restored = loadResult(snapshot.vineyardId)) {
                // Readable and identical to what this failed write published means
                // in-memory-only data, not a durable snapshot.
                is LoadResult.Valid ->
                    if (readRaw(storeKey) == encoded) {
                        unprovenWrites[storeKey] = encoded
                        SaveResult.Failed
                    } else {
                        SaveResult.Existing(restored.snapshot)
                    }
                is LoadResult.Unreadable -> SaveResult.ExistingUnreadable(restored.originalBytes)
                LoadResult.Missing -> {
                    unprovenWrites[storeKey] = encoded
                    SaveResult.Failed
                }
            }
        }
        return when (val restored = loadResult(snapshot.vineyardId)) {
            is LoadResult.Valid -> SaveResult.Persisted(restored.snapshot)
            is LoadResult.Unreadable -> SaveResult.ExistingUnreadable(restored.originalBytes)
            LoadResult.Missing -> {
                unprovenWrites[storeKey] = encoded
                SaveResult.Failed
            }
        }
    }

    /**
     * Genuine durable retry of a write that previously failed in this process.
     * The originally captured bytes are retained and rewritten verbatim, so the
     * first pre-mutation evidence is what eventually lands on disk.
     */
    private fun retryUnprovenWrite(storeKey: String, retained: String): SaveResult {
        if (!rewriteUnprovenRaw(storeKey, retained)) return SaveResult.Failed
        unprovenWrites.remove(storeKey)
        val snapshot = runCatching { json.decodeFromString(Snapshot.serializer(), retained) }.getOrNull()
        return if (snapshot == null) SaveResult.ExistingUnreadable(retained) else SaveResult.Persisted(snapshot)
    }

    companion object {
        private const val PREFS = "vinetrack_recovery_snapshots_v2"

        /** Keys whose durable write failed in this process; their visible value is unproven. */
        private val processUnprovenWrites: MutableMap<String, String> =
            java.util.Collections.synchronizedMap(mutableMapOf())
        private const val COORDINATE_WARNING = "Coordinates are evidence candidates only. Exact IDs do not prove a coordinate is genuine; compare capture provenance and reject copied stale fixes."
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }
        private fun key(vineyardId: String): String = "snapshot_$vineyardId"

        private val tripEvidenceTypes: Set<String> = setOf(
            PendingEntityType.TRIP,
            PendingEntityType.TRIP_START,
            PendingEntityType.TRIP_METADATA,
            PendingEntityType.TRIP_SEEDING,
            PendingEntityType.TRIP_GPS,
            PendingEntityType.TRIP_ROW,
            PendingEntityType.TRIP_TANK,
            PendingEntityType.TRIP_END,
        )

        /** Captures current local stores once and reports whether durable preservation succeeded. */
        fun captureBeforeMutation(context: Context, vineyardId: String): SaveResult {
            val store = RecoverySnapshotStore(context)
            if (!store.hasUnprovenWrite(vineyardId)) {
                when (val existing = store.loadResult(vineyardId)) {
                    is LoadResult.Valid -> return SaveResult.Existing(existing.snapshot)
                    is LoadResult.Unreadable -> return SaveResult.ExistingUnreadable(existing.originalBytes)
                    LoadResult.Missing -> Unit
                }
            }
            return store.saveIfAbsent(collectSnapshot(context, vineyardId))
        }

        fun collectCurrentEvidence(context: Context, vineyardId: String): CurrentEvidence {
            val snapshot = collectSnapshot(context, vineyardId)
            return CurrentEvidence(
                collectedAt = Instant.now().toString(),
                pendingWrites = snapshot.pendingWrites,
                captureEvidence = snapshot.captureEvidence,
                cachedPins = snapshot.cachedPins,
                cachedTrips = snapshot.cachedTrips,
                activeTrip = snapshot.activeTrip,
                sourceStatuses = snapshot.sourceStatuses,
                excludedOrUnreadable = snapshot.excludedOrUnreadable,
            )
        }

        fun exportBundle(original: Snapshot, current: CurrentEvidence): ExportBundle =
            ExportBundle(originalPreMutationSnapshot = original, currentEvidence = current)

        /**
         * Resolves all queued pin/trip ownership before any replay is allowed to
         * mutate evidence.
         *
         * Legacy pin payloads carry only a pin id — pin completion is
         * `{pinId,isCompleted}` and pin delete is `{pinId}` — so their vineyard
         * is resolved by EXACT pin id through authoritative local pin/cache
         * information, exactly as trip work is resolved through known trip ids.
         * [fallbackVineyardId] only adds the currently loaded vineyard to the
         * preservation set; it is never used to guess an unidentified write's
         * owner.
         */
        internal fun resolveReplayScope(
            pendingWrites: List<PendingWrite>,
            tripOwners: Map<String, String>,
            pinOwners: Map<String, String> = emptyMap(),
            fallbackVineyardId: String? = null,
        ): ReplayScope {
            val vineyardIds = mutableSetOf<String>()
            val unresolvedWriteIds = mutableSetOf<String>()
            fallbackVineyardId?.let(vineyardIds::add)
            pendingWrites.forEach { write ->
                val isPinWrite = write.entityType == PendingEntityType.PIN
                if (!isPinWrite && write.entityType !in tripEvidenceTypes) return@forEach
                val owner = payloadVineyardId(write.payloadJson)
                    ?: if (isPinWrite) pinOwners[pinIdOf(write)] else tripOwners[write.clientId]
                if (owner == null) unresolvedWriteIds += write.id else vineyardIds += owner
            }
            return ReplayScope(vineyardIds, unresolvedWriteIds)
        }

        internal fun affectedVineyardIds(
            pendingWrites: List<PendingWrite>,
            tripOwners: Map<String, String>,
            pinOwners: Map<String, String> = emptyMap(),
            fallbackVineyardId: String? = null,
        ): Set<String> = resolveReplayScope(pendingWrites, tripOwners, pinOwners, fallbackVineyardId).vineyardIds

        /** Exact pin identity for a queued pin write: payload pin id, else the idempotency key. */
        internal fun pinIdOf(write: PendingWrite): String =
            payloadPinId(write.payloadJson) ?: write.clientId

        internal fun selectPendingEvidence(
            vineyardId: String,
            pendingWrites: List<PendingWrite>,
            knownTripIds: Set<String>,
            knownPinIds: Set<String> = emptySet(),
        ): Pair<List<PendingWrite>, List<ExcludedEvidence>> {
            val excluded = mutableListOf<ExcludedEvidence>()
            val included = pendingWrites.filter { write ->
                val payloadVineyard = payloadVineyardId(write.payloadJson)
                val isPinWrite = write.entityType == PendingEntityType.PIN
                val isRelevantType = isPinWrite || write.entityType in tripEvidenceTypes
                val isKnownTripEvidence = write.entityType in tripEvidenceTypes && write.clientId in knownTripIds
                val isKnownPinEvidence = isPinWrite && pinIdOf(write) in knownPinIds
                val belongs = payloadVineyard == vineyardId || isKnownTripEvidence || isKnownPinEvidence
                if (!belongs && isRelevantType) {
                    excluded += ExcludedEvidence(
                        source = "pending_writes",
                        itemId = write.id,
                        reason = if (payloadVineyard == null) {
                            "Vineyard could not be read and the write could not be linked to a known trip or pin for this vineyard."
                        } else {
                            "Belongs to another vineyard."
                        },
                    )
                }
                belongs
            }
            return included to excluded
        }

        private fun collectSnapshot(context: Context, vineyardId: String): Snapshot {
            val cache = DomainCacheStore(context)
            val pinRead = cache.loadPinsForRecovery(vineyardId)
            val tripRead = cache.loadTripsForRecovery(vineyardId)
            val pendingRead = PendingWriteStore(context).loadForRecovery()
            val activeTrip = ActiveTripStore(context).load()?.takeIf { it.vineyardId == vineyardId }?.trip
            val captureEvidence = PinCaptureEvidenceStore(context).load().filter { it.vineyardId == vineyardId }
            val knownTripIds = tripRead.items.mapTo(mutableSetOf()) { it.id }.apply { activeTrip?.id?.let(::add) }
            val knownPinIds = pinRead.items.mapTo(mutableSetOf()) { it.id }
                .apply { captureEvidence.forEach { add(it.pinId) } }
            val (pendingWrites, pendingExcluded) =
                selectPendingEvidence(vineyardId, pendingRead.items, knownTripIds, knownPinIds)
            val excluded = pendingExcluded.toMutableList()
            pinRead.issue?.let { excluded += ExcludedEvidence("cached_pins", null, it) }
            tripRead.issue?.let { excluded += ExcludedEvidence("cached_trips", null, it) }
            pendingRead.issue?.let { excluded += ExcludedEvidence("pending_writes", null, it) }
            return Snapshot(
                vineyardId = vineyardId,
                appVersion = BuildConfig.VERSION_NAME,
                buildVersion = BuildConfig.VERSION_CODE.toLong(),
                snapshotAt = Instant.now().toString(),
                source = "before_vineyard_load_refresh_or_replay",
                pendingWrites = pendingWrites,
                captureEvidence = captureEvidence,
                cachedPins = pinRead.items,
                cachedTrips = tripRead.items,
                activeTrip = activeTrip,
                sourceStatuses = listOf(
                    SourceStatus("pending_writes", if (pendingRead.issue == null) "read" else "unreadable", pendingWrites.size),
                    SourceStatus("pin_capture_evidence", "read", captureEvidence.size),
                    SourceStatus("cached_pins", if (pinRead.issue == null) "read" else "unreadable", pinRead.items.size),
                    SourceStatus("cached_trips", if (tripRead.issue == null) "read" else "unreadable", tripRead.items.size),
                    SourceStatus("active_trip", "read", if (activeTrip == null) 0 else 1),
                ),
                excludedOrUnreadable = excluded,
            )
        }

        private fun payloadVineyardId(payload: String): String? = runCatching {
            val objectValue = json.parseToJsonElement(payload).jsonObject
            objectValue["vineyard_id"]?.jsonPrimitive?.content
                ?: objectValue["vineyardId"]?.jsonPrimitive?.content
        }.getOrNull()

        private fun payloadPinId(payload: String): String? = runCatching {
            val objectValue = json.parseToJsonElement(payload).jsonObject
            objectValue["pinId"]?.jsonPrimitive?.content
                ?: objectValue["pin_id"]?.jsonPrimitive?.content
                ?: objectValue["id"]?.jsonPrimitive?.content
        }.getOrNull()
    }
}
