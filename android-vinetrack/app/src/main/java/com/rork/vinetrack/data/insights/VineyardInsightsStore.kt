package com.rork.vinetrack.data.insights

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Durable local storage for Scout visits, Vintage Notes and their pending
 * sync operations.
 *
 * ## Why local-first is not optional here
 *
 * Scouting happens in the rows, which is exactly where there is no signal. A
 * visit that only exists once the server acknowledges it is a visit that gets
 * lost. So every capture is written to disk FIRST and queued second; the
 * network is treated as an eventual reconciliation, never as the place the
 * data lives.
 *
 * ## Vineyard ownership travels with the queue
 *
 * Each queued operation carries its own `vineyardId`. Replay must never
 * consult "the currently selected vineyard" — an operator who captures in
 * Block 4, drives home, switches vineyards and reconnects would otherwise file
 * their morning's work against someone else's business. This is the same
 * lesson the pin outbox already learned.
 *
 * ## Sign-out
 *
 * [clearForSignOut] wipes everything. Preview data captured by one System
 * Admin must not be visible to the next person who signs in on the same
 * device.
 */
class VineyardInsightsStore(private val raw: InsightsKeyValueStore) {

    constructor(prefs: SharedPreferences) : this(SharedPreferencesKeyValueStore(prefs))

    constructor(context: Context) : this(
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE),
    )

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    // ---------------------------------------------------------------- DTOs

    @Serializable
    private data class StoredPhoto(
        val id: String,
        @SerialName("observation_id") val observationId: String,
        @SerialName("local_path") val localPath: String? = null,
        @SerialName("storage_path") val storagePath: String? = null,
        @SerialName("captured_at") val capturedAt: String,
        @SerialName("captured_by") val capturedBy: String? = null,
        val latitude: Double? = null,
        val longitude: Double? = null,
        val accuracy: Double? = null,
        @SerialName("location_status") val locationStatus: String,
    )

    @Serializable
    private data class StoredObservation(
        val id: String,
        @SerialName("assessment_id") val assessmentId: String,
        @SerialName("item_kind") val itemKind: String,
        @SerialName("value_code") val valueCode: String? = null,
        @SerialName("value_label") val valueLabel: String? = null,
        val notes: String? = null,
        val photos: List<StoredPhoto> = emptyList(),
        @SerialName("linked_pin_id") val linkedPinId: String? = null,
        @SerialName("linked_growth_record_id") val linkedGrowthRecordId: String? = null,
    )

    @Serializable
    private data class StoredAssessment(
        val id: String,
        @SerialName("visit_id") val visitId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        val status: String,
        val observations: List<StoredObservation> = emptyList(),
    )

    @Serializable
    private data class StoredWeather(
        @SerialName("observed_at") val observedAt: String? = null,
        @SerialName("captured_at") val capturedAt: String,
        val source: String? = null,
        val temperature: Double? = null,
        val humidity: Double? = null,
        @SerialName("wind_speed") val windSpeed: Double? = null,
        @SerialName("wind_gust") val windGust: Double? = null,
        @SerialName("recent_rainfall") val recentRainfall: Double? = null,
        @SerialName("is_stale") val isStale: Boolean = false,
        @SerialName("is_unavailable") val isUnavailable: Boolean = false,
    )

    @Serializable
    private data class StoredVisit(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("vintage_year") val vintageYear: Int,
        @SerialName("scout_date") val scoutDate: String,
        val status: String,
        @SerialName("visit_summary") val visitSummary: String? = null,
        val weather: StoredWeather? = null,
        @SerialName("scout_user_id") val scoutUserId: String? = null,
        @SerialName("scout_name") val scoutName: String? = null,
        val assessments: List<StoredAssessment> = emptyList(),
        @SerialName("client_updated_at") val clientUpdatedAt: String,
        @SerialName("sync_version") val syncVersion: Long = 0,
    )

    @Serializable
    private data class StoredNote(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("note_date") val noteDate: String,
        @SerialName("vintage_year") val vintageYear: Int,
        @SerialName("note_type_id") val noteTypeId: String? = null,
        @SerialName("note_type_label") val noteTypeLabel: String? = null,
        val notes: String? = null,
        @SerialName("observed_by") val observedBy: String? = null,
        @SerialName("observer_name") val observerName: String? = null,
        @SerialName("created_at") val createdAt: String,
        @SerialName("updated_at") val updatedAt: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
        @SerialName("sync_version") val syncVersion: Long = 0,
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    @Serializable
    private data class StoredQueueEntry(
        val id: String,
        /** The record's own client UUID — the idempotency key for replay. */
        @SerialName("record_id") val recordId: String,
        /**
         * Ownership captured at ENQUEUE time. Replay reads this and never the
         * currently selected vineyard.
         */
        @SerialName("vineyard_id") val vineyardId: String,
        val entity: String,
        val operation: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
        @SerialName("attempt_count") val attemptCount: Int = 0,
    )

    // ------------------------------------------------------------- Domain

    /** A queued, not-yet-synced change. */
    data class QueuedOperation(
        val id: String,
        val recordId: String,
        val vineyardId: String,
        val entity: Entity,
        val operation: Operation,
        val clientUpdatedAtIso: String,
        val attemptCount: Int = 0,
    ) {
        enum class Entity(val code: String) {
            SCOUT_VISIT("scout_visit"),
            VINTAGE_NOTE("vintage_note"),
            ;

            companion object {
                fun byCode(code: String?): Entity? = entries.firstOrNull { it.code == code }
            }
        }

        enum class Operation(val code: String) {
            UPSERT("upsert"),
            DELETE("delete"),
            ;

            companion object {
                fun byCode(code: String?): Operation? = entries.firstOrNull { it.code == code }
            }
        }
    }

    // ------------------------------------------------------------ Mapping

    private fun StoredPhoto.toDomain(): ScoutPhoto? = runCatching {
        val status = PhotoLocationStatus.byCode(locationStatus)
        // Defensive: a corrupted or older row claiming coordinates without a
        // confirmed fix is normalised DOWN to block-only rather than trusted.
        // Presenting an unverified position as measured is the one failure this
        // feature must never produce.
        val honest = status == PhotoLocationStatus.GPS_CONFIRMED &&
            latitude != null && longitude != null
        ScoutPhoto(
            id = id,
            observationId = observationId,
            localPath = localPath,
            storagePath = storagePath,
            capturedAtIso = capturedAt,
            capturedByUserId = capturedBy,
            latitude = if (honest) latitude else null,
            longitude = if (honest) longitude else null,
            accuracyMetres = if (honest) accuracy else null,
            locationStatus = if (honest) {
                PhotoLocationStatus.GPS_CONFIRMED
            } else {
                PhotoLocationStatus.UNAVAILABLE
            },
        )
    }.getOrNull()

    private fun ScoutPhoto.toStored(): StoredPhoto = StoredPhoto(
        id = id,
        observationId = observationId,
        localPath = localPath,
        storagePath = storagePath,
        capturedAt = capturedAtIso,
        capturedBy = capturedByUserId,
        latitude = latitude,
        longitude = longitude,
        accuracy = accuracyMetres,
        locationStatus = locationStatus.code,
    )

    private fun StoredObservation.toDomain(): ScoutObservation? {
        val item = ScoutItem.byCode(itemKind) ?: return null
        return ScoutObservation(
            id = id,
            assessmentId = assessmentId,
            item = item,
            valueCode = valueCode,
            valueLabel = valueLabel,
            notes = notes,
            photos = photos.mapNotNull { it.toDomain() },
            linkedPinId = linkedPinId,
            linkedGrowthStageRecordId = linkedGrowthRecordId,
        )
    }

    private fun ScoutObservation.toStored(): StoredObservation = StoredObservation(
        id = id,
        assessmentId = assessmentId,
        itemKind = item.code,
        valueCode = valueCode,
        valueLabel = valueLabel,
        notes = notes,
        photos = photos.map { it.toStored() },
        linkedPinId = linkedPinId,
        linkedGrowthRecordId = linkedGrowthStageRecordId,
    )

    private fun StoredVisit.toDomain(): ScoutVisit = ScoutVisit(
        id = id,
        vineyardId = vineyardId,
        vintageYear = vintageYear,
        scoutDateIso = scoutDate,
        status = ScoutStatus.byCode(status),
        visitSummary = visitSummary,
        weather = weather?.let {
            ScoutWeatherSnapshot(
                observedAtIso = it.observedAt,
                capturedAtIso = it.capturedAt,
                source = it.source,
                temperatureCelsius = it.temperature,
                humidityPercent = it.humidity,
                windSpeedKph = it.windSpeed,
                windGustKph = it.windGust,
                recentRainfallMm = it.recentRainfall,
                isStale = it.isStale,
                isUnavailable = it.isUnavailable,
            )
        },
        scoutUserId = scoutUserId,
        scoutNameSnapshot = scoutName,
        assessments = assessments.map { stored ->
            ScoutBlockAssessment(
                id = stored.id,
                visitId = stored.visitId,
                vineyardId = stored.vineyardId,
                paddockId = stored.paddockId,
                status = ScoutAssessmentStatus.byCode(stored.status),
                observations = stored.observations.mapNotNull { it.toDomain() },
            )
        },
        clientUpdatedAtIso = clientUpdatedAt,
        syncVersion = syncVersion,
    )

    private fun ScoutVisit.toStored(): StoredVisit = StoredVisit(
        id = id,
        vineyardId = vineyardId,
        vintageYear = vintageYear,
        scoutDate = scoutDateIso,
        status = status.code,
        visitSummary = visitSummary,
        weather = weather?.let {
            StoredWeather(
                observedAt = it.observedAtIso,
                capturedAt = it.capturedAtIso,
                source = it.source,
                temperature = it.temperatureCelsius,
                humidity = it.humidityPercent,
                windSpeed = it.windSpeedKph,
                windGust = it.windGustKph,
                recentRainfall = it.recentRainfallMm,
                isStale = it.isStale,
                isUnavailable = it.isUnavailable,
            )
        },
        scoutUserId = scoutUserId,
        scoutName = scoutNameSnapshot,
        assessments = assessments.map { assessment ->
            StoredAssessment(
                id = assessment.id,
                visitId = assessment.visitId,
                vineyardId = assessment.vineyardId,
                paddockId = assessment.paddockId,
                status = assessment.status.code,
                observations = assessment.observations.map { it.toStored() },
            )
        },
        clientUpdatedAt = clientUpdatedAtIso,
        syncVersion = syncVersion,
    )

    private fun StoredNote.toDomain(): VintageNote = VintageNote(
        id = id,
        vineyardId = vineyardId,
        noteDateIso = noteDate,
        vintageYear = vintageYear,
        noteTypeId = noteTypeId,
        noteTypeLabelSnapshot = noteTypeLabel,
        notes = notes,
        observedByUserId = observedBy,
        observerNameSnapshot = observerName,
        createdAtIso = createdAt,
        updatedAtIso = updatedAt,
        clientUpdatedAtIso = clientUpdatedAt,
        syncVersion = syncVersion,
        deletedAtIso = deletedAt,
    )

    private fun VintageNote.toStored(): StoredNote = StoredNote(
        id = id,
        vineyardId = vineyardId,
        noteDate = noteDateIso,
        vintageYear = vintageYear,
        noteTypeId = noteTypeId,
        noteTypeLabel = noteTypeLabelSnapshot,
        notes = notes,
        observedBy = observedByUserId,
        observerName = observerNameSnapshot,
        createdAt = createdAtIso,
        updatedAt = updatedAtIso,
        clientUpdatedAt = clientUpdatedAtIso,
        syncVersion = syncVersion,
        deletedAt = deletedAtIso,
    )

    // ------------------------------------------------------------- Reads

    fun loadVisits(): List<ScoutVisit> = decodeList<StoredVisit>(KEY_VISITS).map { it.toDomain() }

    fun loadNotes(): List<VintageNote> = decodeList<StoredNote>(KEY_NOTES).map { it.toDomain() }

    fun loadQueue(): List<QueuedOperation> =
        decodeList<StoredQueueEntry>(KEY_QUEUE).mapNotNull { entry ->
            val entity = QueuedOperation.Entity.byCode(entry.entity) ?: return@mapNotNull null
            val operation = QueuedOperation.Operation.byCode(entry.operation) ?: return@mapNotNull null
            QueuedOperation(
                id = entry.id,
                recordId = entry.recordId,
                vineyardId = entry.vineyardId,
                entity = entity,
                operation = operation,
                clientUpdatedAtIso = entry.clientUpdatedAt,
                attemptCount = entry.attemptCount,
            )
        }

    fun loadCustomNoteTypes(): List<VintageNoteType> =
        decodeList<StoredNoteType>(KEY_NOTE_TYPES).map {
            VintageNoteType(
                code = it.code,
                group = VintageNoteGroup.byCode(it.groupCode) ?: VintageNoteGroup.OTHER,
                label = it.label,
                sortOrder = it.sortOrder,
                isCustom = true,
                isActive = it.isActive,
            )
        }

    @Serializable
    private data class StoredNoteType(
        val code: String,
        @SerialName("group_code") val groupCode: String,
        val label: String,
        @SerialName("sort_order") val sortOrder: Int = 0,
        @SerialName("is_active") val isActive: Boolean = true,
        @SerialName("vineyard_id") val vineyardId: String,
    )

    // ------------------------------------------------------------ Writes

    /**
     * Persist a visit. Returns false when the write did not reach disk, so a
     * caller can tell the operator rather than assuming success.
     */
    fun saveVisit(visit: ScoutVisit): Boolean {
        val existing = decodeList<StoredVisit>(KEY_VISITS)
        val next = existing.filterNot { it.id == visit.id } + visit.toStored()
        return encodeAndWrite(KEY_VISITS, next)
    }

    fun deleteVisit(visitId: String): Boolean {
        val next = decodeList<StoredVisit>(KEY_VISITS).filterNot { it.id == visitId }
        return encodeAndWrite(KEY_VISITS, next)
    }

    fun saveNote(note: VintageNote): Boolean {
        val existing = decodeList<StoredNote>(KEY_NOTES)
        val next = existing.filterNot { it.id == note.id } + note.toStored()
        return encodeAndWrite(KEY_NOTES, next)
    }

    fun saveCustomNoteType(vineyardId: String, type: VintageNoteType): Boolean {
        val existing = decodeList<StoredNoteType>(KEY_NOTE_TYPES)
        val next = existing.filterNot { it.vineyardId == vineyardId && it.code == type.code } +
            StoredNoteType(
                code = type.code,
                groupCode = type.group.code,
                label = type.label,
                sortOrder = type.sortOrder,
                isActive = type.isActive,
                vineyardId = vineyardId,
            )
        return encodeAndWrite(KEY_NOTE_TYPES, next)
    }

    /** Custom types belonging to one vineyard. Never another's. */
    fun customNoteTypes(vineyardId: String): List<VintageNoteType> =
        decodeList<StoredNoteType>(KEY_NOTE_TYPES)
            .filter { it.vineyardId == vineyardId }
            .map {
                VintageNoteType(
                    code = it.code,
                    group = VintageNoteGroup.byCode(it.groupCode) ?: VintageNoteGroup.OTHER,
                    label = it.label,
                    sortOrder = it.sortOrder,
                    isCustom = true,
                    isActive = it.isActive,
                )
            }

    /**
     * Queue an operation for replay, collapsing any earlier pending entry for
     * the same record.
     *
     * Collapsing is what makes replay idempotent in practice: editing a note
     * five times offline must produce one upsert carrying the latest state,
     * not five that race each other into a different final answer. A DELETE
     * always supersedes a pending UPSERT for the same record.
     */
    fun enqueue(
        recordId: String,
        vineyardId: String,
        entity: QueuedOperation.Entity,
        operation: QueuedOperation.Operation,
        clientUpdatedAtIso: String,
        queueId: String = java.util.UUID.randomUUID().toString(),
    ): Boolean {
        val existing = decodeList<StoredQueueEntry>(KEY_QUEUE)
            .filterNot { it.recordId == recordId && it.entity == entity.code }
        val next = existing + StoredQueueEntry(
            id = queueId,
            recordId = recordId,
            vineyardId = vineyardId,
            entity = entity.code,
            operation = operation.code,
            clientUpdatedAt = clientUpdatedAtIso,
        )
        return encodeAndWrite(KEY_QUEUE, next)
    }

    /** Remove a queue entry after the server confirmed it. */
    fun dequeue(queueId: String): Boolean {
        val next = decodeList<StoredQueueEntry>(KEY_QUEUE).filterNot { it.id == queueId }
        return encodeAndWrite(KEY_QUEUE, next)
    }

    fun recordAttempt(queueId: String): Boolean {
        val next = decodeList<StoredQueueEntry>(KEY_QUEUE).map {
            if (it.id == queueId) it.copy(attemptCount = it.attemptCount + 1) else it
        }
        return encodeAndWrite(KEY_QUEUE, next)
    }

    /**
     * Wipe every locally held preview record.
     *
     * Called on sign-out: this is unreleased System Admin data and the next
     * person to sign in on this device may be someone else entirely.
     */
    fun clearForSignOut() {
        listOf(KEY_VISITS, KEY_NOTES, KEY_QUEUE, KEY_NOTE_TYPES).forEach { key ->
            if (!raw.remove(key)) Log.w(TAG, "Sign-out clear did not remove $key")
        }
    }

    // ------------------------------------------------------------ Plumbing

    private inline fun <reified T> decodeList(key: String): List<T> {
        val stored = raw.read(key) ?: return emptyList()
        return runCatching { json.decodeFromString<List<T>>(stored) }
            .onFailure { Log.w(TAG, "Unreadable $key: ${it.javaClass.simpleName}") }
            .getOrDefault(emptyList())
    }

    /**
     * Encode first, write second.
     *
     * A serialisation failure must never reach storage, and must certainly
     * never be allowed to clear the key — that turns a failed save into a
     * deletion of everything already captured.
     */
    private inline fun <reified T> encodeAndWrite(key: String, value: List<T>): Boolean {
        val encoded = runCatching { json.encodeToString(value) }
            .onFailure { Log.w(TAG, "Encoding $key failed: ${it.javaClass.simpleName}") }
            .getOrNull() ?: return false
        return raw.write(key, encoded)
    }

    private companion object {
        const val PREFS_NAME = "vineyard_insights_preview"
        const val TAG = "VineyardInsights"
        const val KEY_VISITS = "scout_visits"
        const val KEY_NOTES = "vintage_notes"
        const val KEY_QUEUE = "pending_operations"
        const val KEY_NOTE_TYPES = "custom_note_types"
    }
}
