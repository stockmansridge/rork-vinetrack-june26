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
    private val repository: VineyardInsightsSyncRepository? = null,
    private val clock: () -> Instant = { Instant.now() },
) {

    private val _visits = MutableStateFlow(store.loadVisits())
    val visits: StateFlow<List<ScoutVisit>> = _visits.asStateFlow()

    private val _notes = MutableStateFlow(store.loadNotes())
    val notes: StateFlow<List<VintageNote>> = _notes.asStateFlow()

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

    private fun nowIso(): String = clock().toString()

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

    fun visits(status: ScoutStatus): List<ScoutVisit> =
        _visits.value.filter { it.status == status }
            .sortedByDescending { it.scoutDateIso }

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
        persist(visit.copy(weather = weather))
    }

    fun setObservationValue(visitId: String, assessmentId: String, item: ScoutItem, option: ScoutOption) {
        updateObservation(visitId, assessmentId, item) {
            it.copy(valueCode = option.code, valueLabel = option.label)
        }
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

        store.enqueuePhoto(
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
        return photo
    }

    /**
     * Delete one photograph, invalidating any queued upload for it.
     *
     * The queue entry is removed FIRST so a replay already running cannot
     * resurrect a photograph the operator deleted. An already-uploaded row is
     * soft-deleted server-side on the next sync attempt.
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

        store.dequeuePhoto(photoId)
        _pendingPhotoCount.value = store.loadPhotoQueue().size

        val nextAssessment = assessment.withObservation(
            observation.copy(photos = observation.photos.filterNot { it.id == photoId }),
        )
        if (!persist(visit.withAssessment(nextAssessment))) return null
        photo.localPath?.let { photoFiles?.remove(it) }
        return photo
    }

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
    ) {
        val visit = visit(visitId) ?: return
        if (!visit.isEditable) return
        val assessment = visit.assessments.firstOrNull { it.id == assessmentId } ?: return
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
        persist(visit.withAssessment(nextAssessment))
    }

    fun review(visitId: String): ScoutReview =
        visit(visitId)?.let { ScoutReview.of(it) }
            ?: ScoutReview(0, 0, 0, 0, 0, 0, 0, emptyList())

    /** Complete a visit, refusing when the review rule is not satisfied. */
    fun completeVisit(visitId: String): Boolean {
        val visit = visit(visitId) ?: return false
        if (!ScoutReview.of(visit).canComplete) return false
        return persist(visit.copy(status = ScoutStatus.COMPLETED))
    }

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
        if (record(store.deleteVisit(visitId))) {
            _visits.value = store.loadVisits()
            if (_openVisitId.value == visitId) _openVisitId.value = null
        }
        return retained
    }

    private fun persist(visit: ScoutVisit): Boolean {
        val stamped = visit.copy(clientUpdatedAtIso = nowIso())
        val saved = store.saveVisit(stamped)
        if (saved) {
            _visits.value = store.loadVisits()
            store.enqueue(
                recordId = stamped.id,
                vineyardId = stamped.vineyardId,
                entity = VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT,
                operation = VineyardInsightsStore.QueuedOperation.Operation.UPSERT,
                clientUpdatedAtIso = stamped.clientUpdatedAtIso,
            )
        }
        return record(saved)
    }

    // ------------------------------------------------------ Vintage Notes

    fun notesForVintage(vintageYear: Int): List<VintageNote> =
        VintageNoteRules.forVintage(_notes.value, vintageYear)

    fun customNoteTypes(vineyardId: String): List<VintageNoteType> =
        store.customNoteTypes(vineyardId)

    fun addCustomNoteType(
        vineyardId: String,
        label: String,
        group: VintageNoteGroup = VintageNoteGroup.OTHER,
    ): VintageNoteType? {
        val trimmed = label.trim()
        if (trimmed.isEmpty()) return null
        val type = VintageNoteType(
            code = "custom_${UUID.randomUUID().toString().take(8)}",
            group = group,
            label = trimmed,
            sortOrder = 1_000,
            isCustom = true,
        )
        return if (record(store.saveCustomNoteType(vineyardId, type))) type else null
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
        val note = VintageNote(
            id = draft.id,
            vineyardId = vineyardId,
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
        store.enqueue(
            recordId = note.id,
            vineyardId = note.vineyardId,
            entity = VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE,
            operation = VineyardInsightsStore.QueuedOperation.Operation.UPSERT,
            clientUpdatedAtIso = note.clientUpdatedAtIso,
        )
        return note
    }

    /** Soft delete — the row is tombstoned locally so sync can reconcile it. */
    fun deleteNote(noteId: String): Boolean {
        val note = _notes.value.firstOrNull { it.id == noteId } ?: return false
        val now = nowIso()
        val tombstoned = note.copy(
            deletedAtIso = now,
            updatedAtIso = now,
            clientUpdatedAtIso = now,
        )
        if (!record(store.saveNote(tombstoned))) return false
        _notes.value = store.loadNotes()
        store.enqueue(
            recordId = note.id,
            vineyardId = note.vineyardId,
            entity = VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE,
            operation = VineyardInsightsStore.QueuedOperation.Operation.DELETE,
            clientUpdatedAtIso = now,
        )
        return true
    }

    // --------------------------------------------------------------- Sync

    private val worker: VineyardInsightsSyncWorker? = repository?.let {
        VineyardInsightsSyncWorker(store, photoFiles, it) { nowIso() }
    }

    /**
     * Push queued work then pull the server's view for one vineyard.
     *
     * Local state is already durable before this runs, so every failure path is
     * "try again later" and never data loss. Reloads state from the store at the
     * end so pulled work becomes visible.
     */
    suspend fun sync(vineyardId: String) {
        val outcome = worker?.sync(vineyardId) ?: return
        _visits.value = store.loadVisits()
        _notes.value = store.loadNotes()
        _pendingPhotoCount.value = store.loadPhotoQueue().size
        _lastSyncError.value = outcome.error
    }

    /** Retry failed photograph uploads. The local bytes were never discarded. */
    suspend fun retryPhotoUploads(vineyardId: String) {
        val outcome = worker?.pushPhotos(vineyardId) ?: return
        _visits.value = store.loadVisits()
        _pendingPhotoCount.value = store.loadPhotoQueue().size
        _lastSyncError.value = outcome.error
    }

    // ------------------------------------------------------------ Session

    /** Drop every locally held preview record on sign-out. */
    fun clearForSignOut() {
        store.clearForSignOut()
        photoFiles?.clearForSignOut()
        _visits.value = emptyList()
        _notes.value = emptyList()
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
)
