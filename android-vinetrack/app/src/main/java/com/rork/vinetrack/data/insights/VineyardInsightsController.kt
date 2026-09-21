package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.VintageResolver
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

/**
 * Local-first state holder for the Vineyard Insights preview.
 *
 * Deliberately NOT part of `AppViewModel`: this is an unreleased, System
 * Admin-only preview, and keeping its state in one removable object means the
 * feature can be withdrawn without unpicking the app's main view model. It
 * also keeps the capture rules testable without Android.
 *
 * Every mutation writes to [VineyardInsightsStore] FIRST and queues a sync
 * operation second. Nothing here performs network work — Round 1 establishes
 * the capture and durability contract; the replay worker is a later slice and
 * consumes [VineyardInsightsStore.loadQueue], which already carries each
 * record's own vineyard id.
 */
class VineyardInsightsController(
    private val store: VineyardInsightsStore,
    /**
     * Durable photo bytes. Null only in pure-JVM tests that exercise capture
     * rules without a filesystem; capture then refuses rather than pretending
     * to have stored an image.
     */
    private val photoFiles: ScoutPhotoFiles? = null,
    /** Null in tests and whenever the backend is unreachable. */
    private val repository: VineyardInsightsSyncApi? = null,
    private val weatherLoader: (suspend (String, String) -> ScoutWeatherSnapshot)? = null,
    private val clock: () -> Instant = { Instant.now() },
    private val onMutation: (String) -> Unit = {},
) {

    private val _visits = MutableStateFlow(store.loadVisits())
    val visits: StateFlow<List<ScoutVisit>> = _visits.asStateFlow()

    private val _notes = MutableStateFlow(store.loadNotes())
    val notes: StateFlow<List<VintageNote>> = _notes.asStateFlow()

    private val _noteTypesByVineyard = MutableStateFlow<Map<String, List<VintageNoteType>>>(emptyMap())
    val noteTypesByVineyard: StateFlow<Map<String, List<VintageNoteType>>> = _noteTypesByVineyard.asStateFlow()

    /** The visit currently open for editing, if any. */
    private val _openVisitId = MutableStateFlow<String?>(null)
    val openVisitId: StateFlow<String?> = _openVisitId.asStateFlow()

    /**
     * True when the most recent local write failed to reach disk.
     *
     * Surfaced so the operator can be told, rather than being left to assume a
     * capture is safe. A field observation that silently failed to save is the
     * worst outcome this feature can produce.
     */
    private val _lastWriteFailed = MutableStateFlow(false)
    val lastWriteFailed: StateFlow<Boolean> = _lastWriteFailed.asStateFlow()

    /** Non-fatal sync state, so a stuck queue is visible rather than silent. */
    private val _lastSyncError = MutableStateFlow<String?>(null)
    val lastSyncError: StateFlow<String?> = _lastSyncError.asStateFlow()

    private val _pendingPhotoCount = MutableStateFlow(store.loadPhotoQueue().size)
    val pendingPhotoCount: StateFlow<Int> = _pendingPhotoCount.asStateFlow()

    init {
        store.repairMissingObligations()
        _pendingPhotoCount.value = store.loadPhotoQueue().size
    }

    private fun nowIso(): String = clock().truncatedTo(java.time.temporal.ChronoUnit.MILLIS).toString()

    private fun nextRevisionIso(previousIso: String): String {
        val candidate = clock().truncatedTo(java.time.temporal.ChronoUnit.MILLIS)
        val previous = runCatching { Instant.parse(previousIso) }.getOrNull()
        return if (previous != null && !candidate.isAfter(previous)) previous.plusMillis(1).toString() else candidate.toString()
    }

    private fun record(success: Boolean): Boolean {
        _lastWriteFailed.value = !success
        return success
    }

    // ------------------------------------------------------------- Scout

    fun openVisit(visitId: String?) {
        _openVisitId.value = visitId
    }

    fun visit(visitId: String?): ScoutVisit? =
        visitId?.let { id -> _visits.value.firstOrNull { it.id == id } }

    val openVisit: ScoutVisit? get() = visit(_openVisitId.value)

    fun visitHistory(vineyardId: String, vintageYear: Int?): List<ScoutVisit> =
        ScoutHistoryPolicy.select(_visits.value, vineyardId, vintageYear)

    fun visits(status: ScoutStatus): List<ScoutVisit> =
        _visits.value.filter { it.status == status }
            .sortedByDescending { it.scoutDateIso }

    fun syncStatus(visit: ScoutVisit): String {
        val queued = store.loadQueue().any {
            it.entity == VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT && it.recordId == visit.id
        }
        val queuedPhoto = store.loadPhotoQueue().any { it.visitId == visit.id }
        val unacknowledgedPhoto = visit.assessments.flatMap { it.observations }.flatMap { it.photos }
            .any { it.storagePath == null || it.uploadFailed }
        val failed = store.loadQueue().firstOrNull {
            it.entity == VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT &&
                it.recordId == visit.id && it.attemptCount > 0
        }
        if (failed != null) return "Sync failed: ${failed.lastError ?: "Retry required"}"
        if (store.isSyncOwedForVisit(visit.id) || queued || queuedPhoto || unacknowledgedPhoto) return "Sync pending"
        return if (visit.syncVersion > 0) "Synced" else "Saved on this device"
    }

    /**
     * Start a new visit. The id is client-generated so an offline capture
     * already has its permanent identity before the server ever hears of it.
     */
    fun startVisit(
        vineyardId: String,
        scoutUserId: String?,
        scoutName: String?,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        date: LocalDate = LocalDate.now(),
    ): ScoutVisit {
        val visit = ScoutVisit(
            id = UUID.randomUUID().toString(),
            vineyardId = vineyardId,
            vintageYear = VintageResolver.vintageYear(date, seasonStartMonth, seasonStartDay),
            scoutDateIso = date.toString(),
            status = ScoutStatus.DRAFT,
            scoutUserId = scoutUserId,
            scoutNameSnapshot = scoutName,
            clientUpdatedAtIso = nowIso(),
        )
        persist(visit)
        _openVisitId.value = visit.id
        return visit
    }

    fun toggleBlock(visitId: String, paddockId: String) {
        val visit = visit(visitId) ?: return
        if (!visit.isEditable) return
        val existing = visit.assessment(paddockId)
        // Removing a block that already holds observations would discard field
        // work, so only an untouched block may be removed by a toggle.
        val next = when {
            existing == null -> visit.withBlock(paddockId)
            existing.recordedObservations.isEmpty() -> visit.withoutBlock(paddockId)
            else -> return
        }
        persist(next)
    }

    fun setSummary(visitId: String, summary: String) {
        val visit = visit(visitId) ?: return
        if (!visit.isEditable) return
        persist(visit.copy(visitSummary = summary.takeIf { it.isNotBlank() }))
    }

    fun setWeather(visitId: String, weather: ScoutWeatherSnapshot) {
        val visit = visit(visitId) ?: return
        if (!visit.isEditable) return
        persist(visit.copy(weather = weather))
    }

    /** Capture current configured-source weather only for a visit dated today. */
    suspend fun captureWeather(visitId: String) {
        val visit = visit(visitId) ?: return
        if (!visit.isEditable) return
        val capturedAt = nowIso()
        val today = clock().atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        val visitDate = runCatching { LocalDate.parse(visit.scoutDateIso) }.getOrNull()
        if (visitDate != today) {
            if (visit.weather == null) {
                setWeather(
                    visitId,
                    ScoutWeatherSnapshot.unavailable(
                        capturedAt,
                        "Current weather not used for an older Scout visit",
                    ),
                )
            }
            return
        }
        val snapshot = runCatching { weatherLoader?.invoke(visit.vineyardId, capturedAt) }
            .getOrNull()
            ?: ScoutWeatherSnapshot.unavailable(capturedAt, "Configured vineyard weather source")
        setWeather(visitId, snapshot)
    }

    fun setObservationValue(visitId: String, assessmentId: String, item: ScoutItem, option: ScoutOption) {
        updateObservation(visitId, assessmentId, item) {
            it.copy(valueCode = option.code, valueLabel = option.label)
        }
    }

    fun setObservationLocation(
        visitId: String,
        assessmentId: String,
        item: ScoutItem,
        fix: ScoutPhotoFix?,
    ): Boolean {
        if (fix == null) return false
        val visit = visit(visitId) ?: return false
        if (!visit.isEditable) return false
        val assessment = visit.assessments.firstOrNull { it.id == assessmentId } ?: return false
        val previousSyncOwed = store.isSyncOwedForVisit(visitId)
        val observation = assessment.observation(item) ?: ScoutObservation.empty(assessmentId, item)
        val nextObservation = observation.copy(
            latitude = fix.latitude,
            longitude = fix.longitude,
            accuracyMetres = fix.accuracyMetres,
            locationCapturedAtIso = fix.measuredAtIso,
            locationStatus = PhotoLocationStatus.GPS_CONFIRMED,
        )
        val nextAssessment = assessment.withObservation(nextObservation).let {
            it.copy(status = if (it.isComplete) ScoutAssessmentStatus.COMPLETE else ScoutAssessmentStatus.IN_PROGRESS)
        }
        if (persist(visit.withAssessment(nextAssessment))) return true
        store.saveVisit(visit, previousSyncOwed)
        _visits.value = store.loadVisits()
        return false
    }

    fun setObservationNotes(visitId: String, assessmentId: String, item: ScoutItem, notes: String) {
        updateObservation(visitId, assessmentId, item) {
            it.copy(notes = notes.takeIf { text -> text.isNotBlank() })
        }
    }

    // -------------------------------------------------------- Photographs

    /** Local bytes for immediate display, identical before and after upload. */
    fun photoBytes(photo: ScoutPhoto): ByteArray? =
        photo.localPath?.let { photoFiles?.read(it) }

    /**
     * Capture one photograph for one assessment item.
     *
     * Order matters and is the whole contract:
     *  1. mint a stable client photo id,
     *  2. write the compressed bytes to app-private storage,
     *  3. record the photograph against the observation locally,
     *  4. queue the upload.
     *
     * All four complete without any network. A later upload failure therefore
     * cannot lose the photograph, and Retry is genuinely retryable.
     *
     * [fix] is the verdict from the EXISTING strict validator, resolved by the
     * caller. A non-qualifying fix arrives here as null and becomes an explicit
     * block-only photograph — never a stale or last-known position.
     */
    fun capturePhoto(
        visitId: String,
        assessmentId: String,
        item: ScoutItem,
        jpeg: ByteArray,
        fix: ScoutPhotoFix?,
        capturedByUserId: String?,
    ): ScoutPhoto? {
        val visit = visit(visitId) ?: return null
        if (!visit.isEditable) return null
        val assessment = visit.assessments.firstOrNull { it.id == assessmentId } ?: return null
        val files = photoFiles ?: run { record(false); return null }

        // The observation must exist before the photograph can reference it:
        // scout_observation_photos.observation_id is a real foreign key.
        val observation = assessment.observation(item)
            ?: ScoutObservation.empty(assessmentId, item)
        val photoId = UUID.randomUUID().toString()

        val localPath = files.write(jpeg, visit.vineyardId, observation.id, photoId)
            ?: run {
                // A photograph that could not be written is NOT recorded.
                // Showing it and losing it later is worse than refusing now.
                record(false)
                return null
            }

        val capturedAt = nowIso()
        val photo = if (fix != null) {
            ScoutPhoto.gpsConfirmed(
                observationId = observation.id,
                localPath = localPath,
                capturedAtIso = capturedAt,
                capturedByUserId = capturedByUserId,
                latitude = fix.latitude,
                longitude = fix.longitude,
                accuracyMetres = fix.accuracyMetres,
                id = photoId,
            )
        } else {
            ScoutPhoto.blockOnly(
                observationId = observation.id,
                localPath = localPath,
                capturedAtIso = capturedAt,
                capturedByUserId = capturedByUserId,
                id = photoId,
            )
        }

        val nextAssessment = assessment
            .withObservation(observation.copy(photos = observation.photos + photo))
            .let {
                it.copy(
                    status = if (it.isComplete) {
                        ScoutAssessmentStatus.COMPLETE
                    } else {
                        ScoutAssessmentStatus.IN_PROGRESS
                    },
                )
            }
        if (!persist(visit.withAssessment(nextAssessment))) return null

        val photoQueued = store.enqueuePhoto(
            VineyardInsightsStore.QueuedPhoto(
                id = photoId,
                vineyardId = visit.vineyardId,
                visitId = visitId,
                observationId = observation.id,
                localPath = localPath,
                capturedAt = capturedAt,
            ),
        )
        _pendingPhotoCount.value = store.loadPhotoQueue().size
        if (!photoQueued) {
            record(false)
            return null
        }
        onMutation(visit.vineyardId)
        return photo
    }

    /**
     * Delete one photograph, by how far its upload had progressed.
     *
     * The queue entry is cancelled FIRST, always. A replay already in flight
     * checks the queue before it writes anything, so removing the entry up front
     * is what stops a deleted photograph being resurrected by its own callback.
     *
     * The four cases, per [ScoutPhotoUpload.planDeletion]:
     *  - local-only: remove the bytes; nothing exists server-side.
     *  - queued: cancel, then remove the bytes.
     *  - object uploaded, row pending: cancel, remove the bytes, and mark the
     *    orphaned object for removal — no row references it, so nothing could
     *    ever find it again.
     *  - fully uploaded: the row is SOFT-deleted on the next sync and the object
     *    retained, following the established evidence-retention policy.
     */
    fun deletePhoto(
        visitId: String,
        assessmentId: String,
        item: ScoutItem,
        photoId: String,
    ): ScoutPhoto? {
        val visit = visit(visitId) ?: return null
        if (!visit.isEditable) return null
        val assessment = visit.assessments.firstOrNull { it.id == assessmentId } ?: return null
        val observation = assessment.observation(item) ?: return null
        val photo = observation.photos.firstOrNull { it.id == photoId } ?: return null

        val entry = store.photoQueueEntry(photoId)
        val plan = ScoutPhotoUpload.planDeletion(
            localPath = photo.localPath,
            isQueued = entry != null,
            uploadedStoragePath = entry?.uploadedStoragePath ?: photo.storagePath,
            rowCommitted = entry?.rowCommitted ?: (entry == null && photo.storagePath != null),
        )

        // Cancelled before anything else, so an in-flight upload cannot revive it.
        store.dequeuePhoto(photoId)
        if (!store.markPhotoDeletionIntent(photoId)) return null
        if (plan is ScoutPhotoUpload.Deletion.FullyUploaded &&
            store.photoDeletionRevision(photoId, visit.vineyardId, nowIso()) == null
        ) return null
        _pendingPhotoCount.value = store.loadPhotoQueue().size

        val nextAssessment = assessment.withObservation(
            observation.copy(photos = observation.photos.filterNot { it.id == photoId }),
        ).let {
            it.copy(status = if (it.isComplete) ScoutAssessmentStatus.COMPLETE else ScoutAssessmentStatus.IN_PROGRESS)
        }
        if (!persist(visit.withAssessment(nextAssessment))) return null

        when (plan) {
            is ScoutPhotoUpload.Deletion.LocalOnly -> plan.localPath?.let { photoFiles?.remove(it) }
            is ScoutPhotoUpload.Deletion.Queued -> plan.localPath?.let { photoFiles?.remove(it) }
            is ScoutPhotoUpload.Deletion.ObjectUploadedPending -> {
                plan.localPath?.let { photoFiles?.remove(it) }
                // Queued as a tombstone so the unreferenced object is removed on
                // the next sync, rather than lingering unreachable.
                pendingOrphanedObjects.add(plan.orphanedStoragePath)
            }
            is ScoutPhotoUpload.Deletion.FullyUploaded -> {
                plan.localPath?.let { photoFiles?.remove(it) }
            }
        }
        onMutation(visit.vineyardId)
        return photo
    }

    /**
     * Storage objects whose bytes uploaded but whose metadata row never landed,
     * for a deleted photograph. Removed on the next sync: nothing references
     * them, so they are unreachable rather than recoverable.
     */
    private val pendingOrphanedObjects = mutableSetOf<String>()

    // ------------------------------------------------------------ E-L link

    /**
     * Attach the canonical Growth Stage pin and record created for an E-L
     * selection.
     *
     * The stage VALUE is deliberately not stored as an authoritative figure —
     * only the two canonical ids plus a label snapshot for report
     * presentation. See [ScoutGrowthStageLink].
     */
    fun linkGrowthStageRecord(
        visitId: String,
        assessmentId: String,
        pinId: String?,
        recordId: String,
        stageLabel: String,
    ) {
        updateObservation(visitId, assessmentId, ScoutItem.GROWTH_STAGE) {
            it.copy(
                linkedPinId = pinId,
                linkedGrowthStageRecordId = recordId,
                valueLabel = stageLabel,
            )
        }
    }

    /**
     * Drop the Scout's reference to a canonical record.
     *
     * The canonical pin and `growth_stage_records` row are NOT touched. The
     * observation genuinely happened; only the scout's citation of it is
     * removed. Callers must confirm with the operator first.
     */
    fun unlinkGrowthStageRecord(visitId: String, assessmentId: String) {
        updateObservation(visitId, assessmentId, ScoutItem.GROWTH_STAGE) {
            it.copy(linkedPinId = null, linkedGrowthStageRecordId = null, valueLabel = null)
        }
    }

    private fun updateObservation(
        visitId: String,
        assessmentId: String,
        item: ScoutItem,
        transform: (ScoutObservation) -> ScoutObservation,
    ): Boolean {
        val visit = visit(visitId) ?: return false
        if (!visit.isEditable) return false
        val assessment = visit.assessments.firstOrNull { it.id == assessmentId } ?: return false
        val existing = assessment.observation(item) ?: ScoutObservation.empty(assessmentId, item)
        val updated = transform(existing)
        val nextAssessment = assessment.withObservation(updated).let {
            it.copy(
                status = if (it.isComplete) {
                    ScoutAssessmentStatus.COMPLETE
                } else {
                    ScoutAssessmentStatus.IN_PROGRESS
                },
            )
        }
        return persist(visit.withAssessment(nextAssessment))
    }

    fun review(visitId: String): ScoutReview =
        visit(visitId)?.let { ScoutReview.of(it) }
            ?: ScoutReview(0, 0, 0, 0, 0, 0, 0, emptyList())

    /** Complete a visit, refusing when the review rule is not satisfied. */
    fun completeVisit(visitId: String): Boolean {
        val visit = visit(visitId) ?: return false
        if (!ScoutReview.of(visit).canComplete) return false
        if (visit.status == ScoutStatus.COMPLETED) {
            if (!store.repairMissingObligations()) return record(false)
            val durable = store.loadQueue().any {
                it.entity == VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT &&
                    it.recordId == visitId && it.clientUpdatedAtIso == visit.clientUpdatedAtIso
            }
            if (durable) onMutation(visit.vineyardId)
            return record(durable)
        }
        return persist(visit.copy(status = ScoutStatus.COMPLETED))
    }

    fun completionNeedsRetry(visitId: String): Boolean =
        visit(visitId)?.status == ScoutStatus.COMPLETED && store.isSyncOwedForVisit(visitId)

    /** Deliberately return a completed visit to Draft, with caller confirmation. */
    fun reopenVisit(visitId: String): Boolean {
        val visit = visit(visitId) ?: return false
        return persist(visit.copy(status = ScoutStatus.DRAFT))
    }

    /**
     * Delete a Scout. Canonical Growth Stage records it created are RETAINED —
     * the returned links are what the caller should unlink, never delete.
     */
    fun deleteVisit(visitId: String): List<ScoutGrowthStageLink.Unlink> {
        val visit = visit(visitId) ?: return emptyList()
        val retained = ScoutGrowthStageLink.onScoutDeleted(visit)
        val deletedAt = nowIso()
        val localPaths = visit.assessments.flatMap { it.observations }.flatMap { it.photos }.mapNotNull { it.localPath }
        val queued = store.loadPhotoQueue().filter { it.visitId == visitId && it.vineyardId == visit.vineyardId }
        val cleanupPaths = queued.filterNot { it.rowCommitted }.map { entry ->
            entry.uploadedStoragePath
                ?: photoFiles?.storagePath(entry.vineyardId, entry.observationId, entry.id)
                ?: "${entry.vineyardId.lowercase()}/${entry.observationId.lowercase()}/${entry.id.lowercase()}.jpg"
        }.distinct()
        val pathsToRemove = (localPaths + queued.map { it.localPath }).distinct()
        val localCleanupPersisted = store.queueLocalFileCleanup(visit.vineyardId, pathsToRemove)
        val cleanupPersisted = localCleanupPersisted && cleanupPaths.all {
            store.queueObjectCleanup(visit.vineyardId, it)
        }
        val deleteQueued = cleanupPersisted && store.enqueue(
            recordId = visit.id,
            vineyardId = visit.vineyardId,
            entity = VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT,
            operation = VineyardInsightsStore.QueuedOperation.Operation.DELETE,
            clientUpdatedAtIso = deletedAt,
        )
        val visitDeleted = deleteQueued && store.deleteVisit(visitId)
        val uploadsInvalidated = visitDeleted && queued.all { store.dequeuePhoto(it.id) }
        if (record(uploadsInvalidated)) {
            processLocalFileCleanup(visit.vineyardId)
            _visits.value = store.loadVisits()
            _pendingPhotoCount.value = store.loadPhotoQueue().size
            if (_openVisitId.value == visitId) _openVisitId.value = null
            onMutation(visit.vineyardId)
        }
        return retained
    }

    private fun persist(visit: ScoutVisit): Boolean {
        val stamped = visit.copy(clientUpdatedAtIso = nextRevisionIso(visit.clientUpdatedAtIso))
        val saved = store.saveVisit(stamped)
        if (saved) {
            _visits.value = store.loadVisits()
            val queued = store.enqueue(
                recordId = stamped.id,
                vineyardId = stamped.vineyardId,
                entity = VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT,
                operation = VineyardInsightsStore.QueuedOperation.Operation.UPSERT,
                clientUpdatedAtIso = stamped.clientUpdatedAtIso,
            )
            if (queued) onMutation(stamped.vineyardId)
            return record(queued)
        }
        return record(false)
    }

    // ------------------------------------------------------ Vintage Notes

    fun noteHistory(vineyardId: String, vintageYear: Int?): List<VintageNote> =
        VintageNoteRules.history(_notes.value, vineyardId, vintageYear)

    fun notesForVintage(vintageYear: Int): List<VintageNote> =
        VintageNoteRules.forVintage(_notes.value, vintageYear)

    fun noteTypes(vineyardId: String): List<VintageNoteType> =
        _noteTypesByVineyard.value[vineyardId] ?: store.noteTypes(vineyardId)

    fun addCustomNoteType(
        vineyardId: String,
        label: String,
        group: VintageNoteGroup = VintageNoteGroup.OTHER,
    ): VintageNoteType? {
        val trimmed = label.trim()
        if (trimmed.isEmpty()) return null
        val type = VintageNoteType(
            databaseId = UUID.randomUUID().toString(),
            code = "custom_${UUID.randomUUID().toString().take(8)}",
            group = group,
            label = trimmed,
            sortOrder = 1_000,
            isCustom = true,
            vineyardId = vineyardId,
        )
        return if (record(store.saveCustomNoteType(vineyardId, type))) {
            _noteTypesByVineyard.value = _noteTypesByVineyard.value + (vineyardId to store.noteTypes(vineyardId))
            onMutation(vineyardId)
            type
        } else null
    }

    /**
     * Create or update a note from the form draft.
     *
     * Returns null when the draft is empty — the rule lives on
     * [VintageNoteDraft] so the form, this path and the server all state it the
     * same way. The vintage written here is the local mirror for display; the
     * server recomputes it from the date and its answer wins.
     */
    fun saveNote(
        draft: VintageNoteDraft,
        vineyardId: String,
        observedByUserId: String?,
        observerName: String?,
        seasonStartMonth: Int,
        seasonStartDay: Int,
    ): VintageNote? {
        if (!draft.canSave) return null
        val now = nowIso()
        val existing = _notes.value.firstOrNull { it.id == draft.id }
        if (existing != null && existing.vineyardId != vineyardId) return null
        val note = VintageNote(
            id = draft.id,
            vineyardId = existing?.vineyardId ?: vineyardId,
            noteDateIso = draft.date.toString(),
            vintageYear = draft.resolvedVintage(seasonStartMonth, seasonStartDay),
            noteTypeId = draft.noteTypeId,
            // Only overwrite the historical snapshot when the form carries a
            // label. An edit that does not touch the type must not blank what
            // the original observer chose.
            noteTypeLabelSnapshot = draft.noteTypeLabel ?: existing?.noteTypeLabelSnapshot,
            notes = draft.notes.takeIf { it.isNotBlank() },
            observedByUserId = existing?.observedByUserId ?: observedByUserId,
            observerNameSnapshot = existing?.observerNameSnapshot ?: observerName,
            createdAtIso = existing?.createdAtIso ?: now,
            updatedAtIso = now,
            clientUpdatedAtIso = now,
            syncVersion = existing?.syncVersion ?: 0,
            deletedAtIso = null,
        )
        if (!record(store.saveNote(note))) return null
        _notes.value = store.loadNotes()
        val queued = store.enqueue(
            recordId = note.id,
            vineyardId = note.vineyardId,
            entity = VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE,
            operation = VineyardInsightsStore.QueuedOperation.Operation.UPSERT,
            clientUpdatedAtIso = note.clientUpdatedAtIso,
        )
        if (!record(queued)) return null
        onMutation(note.vineyardId)
        return note
    }

    /** Hard-delete locally immediately and queue the durable server deletion. */
    fun deleteNote(noteId: String): Boolean {
        val note = _notes.value.firstOrNull { it.id == noteId } ?: return false
        val now = nowIso()
        val queued = store.enqueue(
            recordId = note.id,
            vineyardId = note.vineyardId,
            entity = VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE,
            operation = VineyardInsightsStore.QueuedOperation.Operation.DELETE,
            clientUpdatedAtIso = now,
        )
        if (!record(queued)) return false
        if (!record(store.deleteNote(noteId))) return false
        _notes.value = store.loadNotes()
        onMutation(note.vineyardId)
        return true
    }

    // --------------------------------------------------------------- Sync

    @Volatile
    private var syncGeneration: Long = 0

    private fun worker(generation: Long): VineyardInsightsSyncWorker? = repository?.let {
        VineyardInsightsSyncWorker(store, photoFiles, it, { nowIso() }) {
            generation == syncGeneration
        }
    }
    private val syncCoordinator = VineyardInsightsSingleFlightCoordinator()

    /**
     * Push queued work then pull the server's view for one vineyard.
     *
     * Local state is already durable before this runs, so every failure path is
     * "try again later" and never data loss. Reloads state from the store at the
     * end so pulled work becomes visible.
     */
    suspend fun sync(vineyardId: String) {
        val requestGeneration = syncGeneration
        val worker = worker(requestGeneration) ?: return
        syncCoordinator.request(vineyardId) {
            if (requestGeneration != syncGeneration) return@request
            processLocalFileCleanup(vineyardId)
            flushPhotoDeletions(worker)
            val outcome = worker.sync(vineyardId)
            if (requestGeneration != syncGeneration) return@request
            _visits.value = store.loadVisits()
            _notes.value = store.loadNotes()
            _noteTypesByVineyard.value = _noteTypesByVineyard.value + (vineyardId to store.noteTypes(vineyardId))
            _pendingPhotoCount.value = store.loadPhotoQueue().size
            _lastSyncError.value = outcome.error
        }
    }

    private fun processLocalFileCleanup(vineyardId: String) {
        val files = photoFiles ?: return
        store.loadLocalFileCleanup().filter { it.vineyardId == vineyardId }.forEach { item ->
            files.remove(item.relativePath)
            if (!files.exists(item.relativePath)) store.acknowledgeLocalFileCleanup(item.relativePath)
        }
    }

    /** Retry failed photograph uploads. The local bytes were never discarded. */
    suspend fun retryPhotoUploads(vineyardId: String) {
        val worker = worker(syncGeneration) ?: return
        flushPhotoDeletions(worker)
        val outcome = worker.pushPhotos(vineyardId)
        _visits.value = store.loadVisits()
        _pendingPhotoCount.value = store.loadPhotoQueue().size
        _lastSyncError.value = outcome.error
    }

    /**
     * Apply deletions that could only be finished server-side.
     *
     * Each entry is dropped only once its server effect succeeded, so a failure
     * here leaves the obligation outstanding for the next attempt rather than
     * silently abandoning an unreachable object or an un-tombstoned row.
     */
    private suspend fun flushPhotoDeletions(worker: VineyardInsightsSyncWorker) {
        pendingOrphanedObjects.toList().forEach { path ->
            if (worker.removeOrphanedPhotoObject(path)) pendingOrphanedObjects.remove(path)
        }
        store.photoDeletionRevisions().forEach { revision ->
            worker.tombstonePhoto(revision)
        }
    }

    // ------------------------------------------------------------ Session

    /** Drop every locally held preview record on sign-out. */
    suspend fun clearForSignOut() {
        syncGeneration += 1
        syncCoordinator.invalidateAll()
        pendingOrphanedObjects.clear()
        store.clearForSignOut()
        photoFiles?.clearForSignOut()
        _visits.value = emptyList()
        _notes.value = emptyList()
        _noteTypesByVineyard.value = emptyMap()
        _openVisitId.value = null
        _lastWriteFailed.value = false
        _lastSyncError.value = null
        _pendingPhotoCount.value = 0
    }
}

/**
 * A GPS fix that ALREADY passed the existing strict validator.
 *
 * Only a caller that ran the validator can construct one, so a non-qualifying
 * reading cannot reach photo storage as coordinates. The absence of this value
 * is what produces an explicit block-only photograph.
 */
data class ScoutPhotoFix(
    val latitude: Double,
    val longitude: Double,
    val accuracyMetres: Double,
    val measuredAtIso: String = Instant.now().toString(),
)
