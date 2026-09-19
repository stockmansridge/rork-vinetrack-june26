package com.rork.vinetrack.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.UUID

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
class VineyardInsightsStore(
    private val raw: InsightsKeyValueStore,
    /**
     * Diagnostics seam. Defaulting to silent keeps this class free of
     * `android.util.Log`, so it compiles into an ordinary JVM test.
     */
    private val logger: InsightsLogger = InsightsLogger.Silent,
) {

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
        /** Defaulted so rows written before upload tracking still decode. */
        @SerialName("upload_failed") val uploadFailed: Boolean = false,
    )

    /**
     * A photograph whose bytes are already on disk and whose upload is owed.
     *
     * Separate from [StoredQueueEntry] because a photo upload is two distinct
     * server effects — bytes into the `scout-photos` bucket, then a row in
     * `scout_observation_photos` — and the bytes may succeed while the row
     * write fails. Keeping the entry until BOTH are done is what makes a
     * half-finished upload retryable instead of silently lost.
     */
    @Serializable
    data class QueuedPhoto(
        val id: String,
        /**
         * Ownership captured at enqueue time, never re-derived from whatever
         * vineyard happens to be selected when connectivity returns.
         */
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("visit_id") val visitId: String,
        @SerialName("observation_id") val observationId: String,
        /** Relative path under the app's scout_photos directory. */
        @SerialName("local_path") val localPath: String,
        /**
         * Set once the bytes are in the bucket but the row is still owed.
         *
         * This is the persisted [PhotoUploadState.OBJECT_UPLOADED] marker. It
         * survives a restart so the next attempt resumes at the metadata upsert
         * instead of re-uploading bytes that are already there.
         */
        @SerialName("uploaded_storage_path") val uploadedStoragePath: String? = null,
        /**
         * Set once the metadata row exists. Only when this AND
         * [uploadedStoragePath] are set is the photograph genuinely stored, so
         * a crash between the two effects can never present as success.
         */
        @SerialName("row_committed") val rowCommitted: Boolean = false,
        @SerialName("captured_at") val capturedAt: String,
        @SerialName("attempt_count") val attemptCount: Int = 0,
        @SerialName("last_error") val lastError: String? = null,
    ) {
        /** Observable progression, for display and for assertions. */
        val uploadState: PhotoUploadState
            get() = ScoutPhotoUpload.state(
                isQueued = true,
                uploadedStoragePath = uploadedStoragePath,
                rowCommitted = rowCommitted,
            )
    }

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
    @Serializable
    data class DeletionCursor(
        @SerialName("deleted_at") val deletedAt: String,
        @SerialName("ledger_id") val ledgerId: String,
    )

    @Serializable
    data class ConsumedDeletion(
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("entity_type") val entityType: String,
        @SerialName("entity_id") val entityId: String,
    )

    @Serializable
    data class ObjectCleanup(
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("storage_path") val storagePath: String,
        @SerialName("attempt_count") val attemptCount: Int = 0,
    )

    @Serializable
    data class LocalFileCleanup(
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("relative_path") val relativePath: String,
    )

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
            uploadFailed = uploadFailed,
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
        uploadFailed = uploadFailed,
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

    fun loadPhotoQueue(): List<QueuedPhoto> = decodeList<QueuedPhoto>(KEY_PHOTO_QUEUE)

    fun deletionCursor(vineyardId: String): DeletionCursor? =
        decodeList<StoredDeletionCursor>(KEY_DELETION_CURSORS)
            .firstOrNull { it.vineyardId == vineyardId }
            ?.cursor

    fun setDeletionCursor(vineyardId: String, cursor: DeletionCursor): Boolean {
        val next = decodeList<StoredDeletionCursor>(KEY_DELETION_CURSORS)
            .filterNot { it.vineyardId == vineyardId } + StoredDeletionCursor(vineyardId, cursor)
        return encodeAndWrite(KEY_DELETION_CURSORS, next)
    }

    fun isDeleted(vineyardId: String, entityType: String, entityId: String): Boolean =
        decodeList<ConsumedDeletion>(KEY_CONSUMED_DELETIONS).any {
            it.vineyardId == vineyardId && it.entityType == entityType && it.entityId == entityId
        }

    fun loadObjectCleanup(): List<ObjectCleanup> = decodeList(KEY_OBJECT_CLEANUP)

    fun loadLocalFileCleanup(): List<LocalFileCleanup> = decodeList(KEY_LOCAL_FILE_CLEANUP)

    @Serializable
    private data class StoredDeletionCursor(
        @SerialName("vineyard_id") val vineyardId: String,
        val cursor: DeletionCursor,
    )

    /** Delta cursor per vineyard, so a pull asks only for what changed. */
    fun lastPull(vineyardId: String): String? =
        decodeList<StoredPullCursor>(KEY_LAST_PULL)
            .firstOrNull { it.vineyardId == vineyardId }
            ?.updatedAt

    fun setLastPull(vineyardId: String, updatedAtIso: String): Boolean {
        val next = decodeList<StoredPullCursor>(KEY_LAST_PULL)
            .filterNot { it.vineyardId == vineyardId } + StoredPullCursor(vineyardId, updatedAtIso)
        return encodeAndWrite(KEY_LAST_PULL, next)
    }

    @Serializable
    private data class StoredPullCursor(
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("updated_at") val updatedAt: String,
    )

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
                databaseId = it.id,
                code = it.code,
                group = VintageNoteGroup.byCode(it.groupCode) ?: VintageNoteGroup.OTHER,
                label = it.label,
                sortOrder = it.sortOrder,
                isCustom = !it.isSystem,
                isActive = it.isActive,
                vineyardId = it.vineyardId,
                isSystem = it.isSystem,
            )
        }

    @Serializable
    private data class StoredNoteType(
        val id: String? = null,
        val code: String,
        @SerialName("group_code") val groupCode: String,
        val label: String,
        @SerialName("sort_order") val sortOrder: Int = 0,
        @SerialName("is_active") val isActive: Boolean = true,
        @SerialName("vineyard_id") val vineyardId: String? = null,
        @SerialName("is_system") val isSystem: Boolean = false,
        @SerialName("is_pending") val isPending: Boolean = false,
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

    fun deleteNote(noteId: String): Boolean {
        val next = decodeList<StoredNote>(KEY_NOTES).filterNot { it.id == noteId }
        return encodeAndWrite(KEY_NOTES, next)
    }

    /** Permanently reconcile one authorised ledger row. Safe to repeat after a partial failure. */
    fun consumeDeletion(
        vineyardId: String,
        entityType: String,
        entityId: String,
    ): Boolean {
        val marker = ConsumedDeletion(vineyardId, entityType, entityId)
        val markers = decodeList<ConsumedDeletion>(KEY_CONSUMED_DELETIONS)
        if (!encodeAndWrite(KEY_CONSUMED_DELETIONS, (markers + marker).distinct())) return false

        if (entityType == QueuedOperation.Entity.SCOUT_VISIT.code) {
            val ownedVisit = loadVisits().firstOrNull { it.id == entityId && it.vineyardId == vineyardId }
            val queuedPhotos = loadPhotoQueue().filter { it.visitId == entityId && it.vineyardId == vineyardId }
            val cleanup = queuedPhotos.mapNotNull { entry ->
                entry.uploadedStoragePath?.let { ObjectCleanup(vineyardId, it) }
            }
            if (!encodeAndWrite(KEY_OBJECT_CLEANUP, (loadObjectCleanup() + cleanup).distinctBy { it.storagePath })) return false
            if (ownedVisit != null && !deleteVisit(entityId)) return false
            if (!encodeAndWrite(KEY_PHOTO_QUEUE, loadPhotoQueue().filterNot {
                    it.visitId == entityId && it.vineyardId == vineyardId
                })) return false
        } else if (entityType == QueuedOperation.Entity.VINTAGE_NOTE.code) {
            val ownedNote = loadNotes().firstOrNull { it.id == entityId && it.vineyardId == vineyardId }
            if (ownedNote != null && !deleteNote(entityId)) return false
        } else {
            return false
        }
        return encodeAndWrite(KEY_QUEUE, decodeList<StoredQueueEntry>(KEY_QUEUE).filterNot {
            it.recordId == entityId && it.vineyardId == vineyardId && it.entity == entityType
        })
    }

    fun queueLocalFileCleanup(vineyardId: String, relativePaths: List<String>): Boolean = encodeAndWrite(
        KEY_LOCAL_FILE_CLEANUP,
        (loadLocalFileCleanup() + relativePaths.map { LocalFileCleanup(vineyardId, it) })
            .distinctBy { it.relativePath },
    )

    fun acknowledgeLocalFileCleanup(relativePath: String): Boolean = encodeAndWrite(
        KEY_LOCAL_FILE_CLEANUP,
        loadLocalFileCleanup().filterNot { it.relativePath == relativePath },
    )

    fun queueObjectCleanup(vineyardId: String, storagePath: String): Boolean = encodeAndWrite(
        KEY_OBJECT_CLEANUP,
        (loadObjectCleanup() + ObjectCleanup(vineyardId, storagePath)).distinctBy { it.storagePath },
    )

    fun acknowledgeObjectCleanup(storagePath: String): Boolean = encodeAndWrite(
        KEY_OBJECT_CLEANUP,
        loadObjectCleanup().filterNot { it.storagePath == storagePath },
    )

    fun recordObjectCleanupFailure(storagePath: String): Boolean = encodeAndWrite(
        KEY_OBJECT_CLEANUP,
        loadObjectCleanup().map {
            if (it.storagePath == storagePath) it.copy(attemptCount = it.attemptCount + 1) else it
        },
    )

    fun saveCustomNoteType(vineyardId: String, type: VintageNoteType): Boolean {
        val existing = decodeList<StoredNoteType>(KEY_NOTE_TYPES)
        val next = existing.filterNot { it.vineyardId == vineyardId && it.code == type.code } +
            StoredNoteType(
                id = type.databaseId,
                code = type.code,
                groupCode = type.group.code,
                label = type.label,
                sortOrder = type.sortOrder,
                isActive = type.isActive,
                vineyardId = vineyardId,
                isSystem = false,
                isPending = true,
            )
        return encodeAndWrite(KEY_NOTE_TYPES, next)
    }

    /** Custom types belonging to one vineyard. Never another's. */
    fun noteTypes(vineyardId: String): List<VintageNoteType> =
        decodeList<StoredNoteType>(KEY_NOTE_TYPES)
            .filter { it.isSystem || it.vineyardId == vineyardId }
            .map {
                VintageNoteType(
                    databaseId = it.id,
                    code = it.code,
                    group = VintageNoteGroup.byCode(it.groupCode) ?: VintageNoteGroup.OTHER,
                    label = it.label,
                    sortOrder = it.sortOrder,
                    isCustom = !it.isSystem,
                    isActive = it.isActive,
                    vineyardId = it.vineyardId,
                    isSystem = it.isSystem,
                )
            }

    fun pendingNoteTypes(vineyardId: String): List<VintageNoteType> =
        decodeList<StoredNoteType>(KEY_NOTE_TYPES)
            .filter { it.vineyardId == vineyardId && it.isPending }
            .map {
                VintageNoteType(it.id, it.code, VintageNoteGroup.byCode(it.groupCode) ?: VintageNoteGroup.OTHER,
                    it.label, it.sortOrder, true, it.isActive, vineyardId, false)
            }

    fun reconcileNoteTypes(vineyardId: String, types: List<VintageNoteType>): Boolean {
        val existing = decodeList<StoredNoteType>(KEY_NOTE_TYPES)
        val pending = existing.filter { it.vineyardId == vineyardId && it.isPending }
        val retained = existing.filterNot { it.isSystem || it.vineyardId == vineyardId }
        val server = types.map {
            StoredNoteType(it.databaseId, it.code, it.group.code, it.label, it.sortOrder,
                it.isActive, it.vineyardId, it.isSystem, false)
        }
        val merged = retained + server + pending.filterNot { p -> server.any { it.id == p.id } }
        if (!encodeAndWrite(KEY_NOTE_TYPES, merged)) return false
        val byCode = types.mapNotNull { type -> type.databaseId?.let { type.code to it } }.toMap()
        val notes = loadNotes().map { note ->
            val legacyCode = note.noteTypeId?.takeIf { runCatching { UUID.fromString(it) }.isFailure }
            if (legacyCode != null) byCode[legacyCode]?.let { note.copy(noteTypeId = it) } ?: note else note
        }
        return encodeAndWrite(KEY_NOTES, notes.map { it.toStored() })
    }

    fun markNoteTypeSynced(id: String): Boolean {
        val rows = decodeList<StoredNoteType>(KEY_NOTE_TYPES).map {
            if (it.id == id) it.copy(isPending = false) else it
        }
        return encodeAndWrite(KEY_NOTE_TYPES, rows)
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

    /**
     * Queue a photograph whose bytes are ALREADY on disk.
     *
     * Keyed by the photograph's own id so capturing several photographs for one
     * item produces several independent entries. Photographs must never
     * collapse into one another the way repeated edits of a single record
     * legitimately do.
     */
    fun enqueuePhoto(photo: QueuedPhoto): Boolean {
        val next = loadPhotoQueue().filterNot { it.id == photo.id } + photo
        return encodeAndWrite(KEY_PHOTO_QUEUE, next)
    }

    /**
     * Record that the bytes landed but the metadata row is still owed.
     *
     * Deliberately does NOT dequeue and does NOT mark the photograph complete.
     * A storage object with no metadata row is invisible to every client, so
     * reporting success here would tell the operator their evidence was saved
     * when no report could ever find it.
     *
     * Only applied while the entry is still queued: a photograph the operator
     * deleted mid-upload has already left the queue and must not be revived by
     * its own in-flight callback.
     */
    fun markPhotoObjectUploaded(photoId: String, storagePath: String): Boolean {
        val queue = loadPhotoQueue()
        if (queue.none { it.id == photoId }) return false
        val next = queue.map {
            if (it.id == photoId) it.copy(uploadedStoragePath = storagePath, lastError = null) else it
        }
        return encodeAndWrite(KEY_PHOTO_QUEUE, next)
    }

    /**
     * Record that the metadata row committed. The entry stays queued until
     * [dequeuePhoto] discharges it, so a crash between the two is still visibly
     * outstanding rather than silently finished.
     */
    fun markPhotoRowCommitted(photoId: String): Boolean {
        val queue = loadPhotoQueue()
        if (queue.none { it.id == photoId }) return false
        val next = queue.map {
            if (it.id == photoId) it.copy(rowCommitted = true, lastError = null) else it
        }
        return encodeAndWrite(KEY_PHOTO_QUEUE, next)
    }

    /** The queue entry for one photograph, if it is still owed. */
    fun photoQueueEntry(photoId: String): QueuedPhoto? =
        loadPhotoQueue().firstOrNull { it.id == photoId }

    fun recordPhotoFailure(photoId: String, message: String): Boolean {
        val next = loadPhotoQueue().map {
            if (it.id == photoId) {
                it.copy(attemptCount = it.attemptCount + 1, lastError = message)
            } else {
                it
            }
        }
        return encodeAndWrite(KEY_PHOTO_QUEUE, next)
    }

    /**
     * Remove a photo entry once BOTH the bytes and the row are stored, or when
     * the operator deleted the photograph before it ever uploaded.
     */
    fun dequeuePhoto(photoId: String): Boolean {
        val next = loadPhotoQueue().filterNot { it.id == photoId }
        return encodeAndWrite(KEY_PHOTO_QUEUE, next)
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
        listOf(
            KEY_VISITS,
            KEY_NOTES,
            KEY_QUEUE,
            KEY_NOTE_TYPES,
            KEY_PHOTO_QUEUE,
            KEY_LAST_PULL,
            KEY_DELETION_CURSORS,
            KEY_CONSUMED_DELETIONS,
            KEY_OBJECT_CLEANUP,
        ).forEach { key ->
            if (!raw.remove(key)) logger.warn("Sign-out clear did not remove $key")
        }
    }

    // ------------------------------------------------------------ Plumbing

    private inline fun <reified T> decodeList(key: String): List<T> {
        val stored = raw.read(key) ?: return emptyList()
        return runCatching { json.decodeFromString<List<T>>(stored) }
            .onFailure { logger.warn("Unreadable $key: ${it.javaClass.simpleName}") }
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
            .onFailure { logger.warn("Encoding $key failed: ${it.javaClass.simpleName}") }
            .getOrNull() ?: return false
        return raw.write(key, encoded)
    }

    internal companion object {
        const val PREFS_NAME = "vineyard_insights_preview"
        const val KEY_VISITS = "scout_visits"
        const val KEY_NOTES = "vintage_notes"
        const val KEY_QUEUE = "pending_operations"
        const val KEY_NOTE_TYPES = "custom_note_types"
        const val KEY_PHOTO_QUEUE = "pending_photos"
        const val KEY_LAST_PULL = "last_pull"
        const val KEY_DELETION_CURSORS = "deletion_cursors"
        const val KEY_CONSUMED_DELETIONS = "consumed_deletions"
        const val KEY_OBJECT_CLEANUP = "object_cleanup"
        const val KEY_LOCAL_FILE_CLEANUP = "local_file_cleanup"
    }
}
