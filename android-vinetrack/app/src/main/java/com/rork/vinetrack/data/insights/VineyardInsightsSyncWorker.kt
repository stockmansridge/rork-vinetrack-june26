package com.rork.vinetrack.data.insights

/**
 * Replay worker for Scout and Vintage Notes.
 *
 * ## Why this is a separate class
 *
 * It reads and writes through [VineyardInsightsStore] only, so the whole
 * local-to-Supabase lifecycle can be exercised in a plain JVM test with a fake
 * repository. A worker buried inside the controller could only be "verified" by
 * reading it.
 *
 * ## Vineyard ownership travels with the work
 *
 * Every queue entry carries its own `vineyardId` and this worker uses that
 * value, never a "currently selected vineyard". An operator who scouts Block 4,
 * drives home, switches vineyards and reconnects must have that morning's work
 * filed against the vineyard they were standing in.
 *
 * ## Nothing here can lose data
 *
 * Local state is already durable before any of this runs. Every failure path is
 * therefore "try again later": the queue entry stays, the local record stays,
 * and the photograph's bytes stay on disk.
 */
class VineyardInsightsSyncWorker(
    private val store: VineyardInsightsStore,
    private val photoFiles: ScoutPhotoFiles?,
    private val repository: VineyardInsightsSyncRepository,
    private val nowIso: () -> String,
) {

    /** What one sync attempt did, for the caller to surface. */
    data class Outcome(
        val pushed: Int = 0,
        val photosUploaded: Int = 0,
        val pulledVisits: Int = 0,
        val pulledNotes: Int = 0,
        val error: String? = null,
    )

    suspend fun sync(vineyardId: String): Outcome {
        val push = pushQueue()
        val photos = pushPhotos(vineyardId)
        val pull = pull(vineyardId)
        return Outcome(
            pushed = push.pushed,
            photosUploaded = photos.photosUploaded,
            pulledVisits = pull.pulledVisits,
            pulledNotes = pull.pulledNotes,
            error = push.error ?: photos.error ?: pull.error,
        )
    }

    // ------------------------------------------------------------ Push

    suspend fun pushQueue(): Outcome {
        var pushed = 0
        var error: String? = null
        for (entry in store.loadQueue()) {
            try {
                when (entry.entity) {
                    VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT -> pushVisit(entry)
                    VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE -> pushNote(entry)
                }
                store.dequeue(entry.id)
                pushed += 1
            } catch (e: Exception) {
                // Left queued deliberately: the local record is intact, so a
                // later attempt can still deliver it.
                store.recordAttempt(entry.id)
                error = e.message ?: "Could not sync yet."
            }
        }
        return Outcome(pushed = pushed, error = error)
    }

    private suspend fun pushVisit(entry: VineyardInsightsStore.QueuedOperation) {
        if (entry.operation == VineyardInsightsStore.QueuedOperation.Operation.DELETE) {
            repository.softDeleteVisit(entry.recordId, entry.vineyardId, entry.clientUpdatedAtIso)
            return
        }
        val visit = store.loadVisits().firstOrNull { it.id == entry.recordId } ?: return

        // vintage_year is NOT sent: SQL 236 resolves it from scout_date.
        val payload = VineyardInsightsSyncRepository.VisitUpsert(
            id = visit.id,
            vineyardId = visit.vineyardId,
            scoutDate = visit.scoutDateIso,
            status = visit.status.code,
            visitSummary = visit.visitSummary,
            weatherSnapshot = visit.weather?.let {
                VineyardInsightsSyncRepository.WeatherPayload(
                    observedAt = it.observedAtIso,
                    capturedAt = it.capturedAtIso,
                    source = it.source,
                    temperatureC = it.temperatureCelsius,
                    humidityPct = it.humidityPercent,
                    windKph = it.windSpeedKph,
                    gustKph = it.windGustKph,
                    recentRainfallMm = it.recentRainfallMm,
                    isStale = it.isStale,
                    isUnavailable = it.isUnavailable,
                )
            },
            scoutUserId = visit.scoutUserId,
            scoutNameSnapshot = visit.scoutNameSnapshot,
            clientUpdatedAt = visit.clientUpdatedAtIso,
        )

        val assessments = visit.assessments.map {
            VineyardInsightsSyncRepository.AssessmentUpsert(
                id = it.id,
                scoutVisitId = visit.id,
                vineyardId = it.vineyardId,
                paddockId = it.paddockId,
                status = it.status.code,
                clientUpdatedAt = visit.clientUpdatedAtIso,
            )
        }

        // Only observations carrying content are sent. An untouched defaulted
        // row is not evidence, and sending it would pad a future report with
        // "not assessed" entries the scout never actually considered.
        val observations = visit.assessments.flatMap { assessment ->
            assessment.observations.filter { it.hasContent }.map {
                VineyardInsightsSyncRepository.ObservationUpsert(
                    id = it.id,
                    assessmentId = assessment.id,
                    vineyardId = assessment.vineyardId,
                    itemKind = it.item.code,
                    valueCode = it.valueCode,
                    valueLabel = it.valueLabel,
                    notes = it.notes,
                    linkedPinId = it.linkedPinId,
                    linkedGrowthStageRecordId = it.linkedGrowthStageRecordId,
                    clientUpdatedAt = visit.clientUpdatedAtIso,
                )
            }
        }

        // Parent-first ordering is guaranteed inside pushVisit: the SQL 236
        // foreign keys are real, so a child replayed before its parent would be
        // rejected.
        repository.pushVisit(payload, assessments, observations)
    }

    private suspend fun pushNote(entry: VineyardInsightsStore.QueuedOperation) {
        if (entry.operation == VineyardInsightsStore.QueuedOperation.Operation.DELETE) {
            repository.softDeleteNote(entry.recordId)
            return
        }
        val note = store.loadNotes().firstOrNull { it.id == entry.recordId } ?: return
        val returned = repository.upsertNote(
            VineyardInsightsSyncRepository.UpsertNoteArgs(
                id = note.id,
                vineyardId = note.vineyardId,
                noteDate = note.noteDateIso,
                // note_type_id is a uuid column; a catalogue CODE is not a uuid,
                // so only a real type id is sent. The label snapshot carries the
                // operator's choice either way.
                noteTypeId = note.noteTypeId?.takeIf { isUuid(it) },
                noteTypeLabel = note.noteTypeLabelSnapshot,
                notes = note.notes,
                observerName = note.observerNameSnapshot,
                clientUpdatedAt = note.clientUpdatedAtIso,
            ),
        )
        // Reconcile the server's canonical answer, above all the vintage it
        // resolved from the date. The local value was only ever for display.
        returned?.let { applyNoteRow(it) }
    }

    // ---------------------------------------------------------- Photographs

    /**
     * Upload queued photographs, then write their metadata rows.
     *
     * A late completion can only ever touch ITS OWN photo id, so it cannot
     * replace or remove a newer photograph. A photograph the operator deleted
     * has already left the queue and is skipped.
     */
    suspend fun pushPhotos(vineyardId: String): Outcome {
        val files = photoFiles ?: return Outcome()
        var uploaded = 0
        var error: String? = null
        for (entry in store.loadPhotoQueue().filter { it.vineyardId == vineyardId }) {
            val photo = findPhoto(entry.id)
            if (photo == null) {
                // Deleted locally while queued. Tombstone the row if it was
                // already referenced, then drop the obligation.
                if (entry.uploadedStoragePath != null) {
                    runCatching { repository.softDeletePhoto(entry.id, nowIso()) }
                }
                store.dequeuePhoto(entry.id)
                continue
            }
            val jpeg = files.read(entry.localPath)
            if (jpeg == null) {
                error = "The photograph file is missing on this device."
                store.recordPhotoFailure(entry.id, error)
                markPhotoFailed(entry.id)
                continue
            }
            try {
                // Bytes already landed on a previous attempt; only the row is
                // still owed. Re-uploading would be wasted work.
                val path = entry.uploadedStoragePath ?: repository.uploadPhotoBytes(
                    files.storagePath(entry.vineyardId, entry.observationId, entry.id),
                    jpeg,
                ).also { store.markPhotoUploaded(entry.id, it) }

                repository.pushPhotoRow(
                    VineyardInsightsSyncRepository.PhotoUpsert(
                        id = photo.id,
                        observationId = photo.observationId,
                        vineyardId = entry.vineyardId,
                        storagePath = path,
                        capturedAt = photo.capturedAtIso,
                        latitude = photo.latitude,
                        longitude = photo.longitude,
                        horizontalAccuracy = photo.accuracyMetres,
                        locationStatus = photo.locationStatus.code,
                        capturedBy = photo.capturedByUserId,
                        clientUpdatedAt = nowIso(),
                    ),
                )
                applyPhotoStoragePath(entry.id, path, failed = false)
                store.dequeuePhoto(entry.id)
                uploaded += 1
            } catch (e: Exception) {
                // The local photograph is retained and Retry stays available. A
                // failed upload must never present as a lost photograph.
                error = e.message ?: "Could not upload the photograph yet."
                store.recordPhotoFailure(entry.id, error)
                markPhotoFailed(entry.id)
            }
        }
        return Outcome(photosUploaded = uploaded, error = error)
    }

    private fun findPhoto(photoId: String): ScoutPhoto? =
        store.loadVisits().asSequence()
            .flatMap { it.assessments.asSequence() }
            .flatMap { it.observations.asSequence() }
            .flatMap { it.photos.asSequence() }
            .firstOrNull { it.id == photoId }

    private fun markPhotoFailed(photoId: String) =
        applyPhotoStoragePath(photoId, storagePath = null, failed = true)

    /**
     * Reconcile one photograph, addressed by its own id.
     *
     * Saved WITHOUT re-queuing the visit: a storage path arriving is the
     * server's own answer coming home, not a new local edit, and re-queuing it
     * would make sync loop forever.
     */
    private fun applyPhotoStoragePath(photoId: String, storagePath: String?, failed: Boolean) {
        val visit = store.loadVisits().firstOrNull { candidate ->
            candidate.assessments.any { assessment ->
                assessment.observations.any { it.photos.any { photo -> photo.id == photoId } }
            }
        } ?: return
        val next = visit.copy(
            assessments = visit.assessments.map { assessment ->
                assessment.copy(
                    observations = assessment.observations.map { observation ->
                        observation.copy(
                            photos = observation.photos.map { photo ->
                                if (photo.id != photoId) {
                                    photo
                                } else {
                                    photo.copy(
                                        storagePath = storagePath ?: photo.storagePath,
                                        uploadFailed = failed,
                                    )
                                }
                            },
                        )
                    },
                )
            },
        )
        store.saveVisit(next)
    }

    // ------------------------------------------------------------ Pull

    /** Pull the server's view so another device's or session's work appears. */
    suspend fun pull(vineyardId: String): Outcome {
        return try {
            val since = store.lastPull(vineyardId)
            val noteRows = repository.fetchNotes(vineyardId, since)
            noteRows.forEach { applyNoteRow(it) }

            val visitRows = repository.fetchVisits(vineyardId, since)
            if (visitRows.isNotEmpty()) {
                val assessmentRows = repository.fetchAssessments(vineyardId, visitRows.map { it.id })
                val observationRows =
                    repository.fetchObservations(vineyardId, assessmentRows.map { it.id })
                val photoRows = repository.fetchPhotos(vineyardId, observationRows.map { it.id })
                visitRows.forEach { row ->
                    applyVisitRow(
                        row,
                        assessmentRows.filter { it.scoutVisitId == row.id },
                        observationRows,
                        photoRows,
                    )
                }
            }
            store.setLastPull(vineyardId, nowIso())
            Outcome(pulledVisits = visitRows.size, pulledNotes = noteRows.size)
        } catch (e: Exception) {
            Outcome(error = e.message ?: "Could not refresh yet.")
        }
    }

    /**
     * Merge one server note, respecting local unsynced edits.
     *
     * A record still sitting in the outbox is NOT overwritten: the operator's
     * unsent change is newer than anything the server can currently return, and
     * clobbering it would silently discard their work.
     */
    fun applyNoteRow(row: VineyardInsightsSyncRepository.NoteRow) {
        val pending = store.loadQueue().any {
            it.recordId == row.id &&
                it.entity == VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE
        }
        if (pending) return
        store.saveNote(
            VintageNote(
                id = row.id,
                vineyardId = row.vineyardId,
                noteDateIso = row.noteDate,
                // The server's vintage, which is authoritative.
                vintageYear = row.vintageYear,
                noteTypeId = row.noteTypeId,
                noteTypeLabelSnapshot = row.noteTypeLabel,
                notes = row.notes,
                observedByUserId = row.observedByUserId,
                observerNameSnapshot = row.observerNameSnapshot,
                createdAtIso = row.createdAt ?: row.noteDate,
                updatedAtIso = row.updatedAt ?: row.createdAt ?: row.noteDate,
                clientUpdatedAtIso = row.clientUpdatedAt ?: row.updatedAt ?: row.noteDate,
                syncVersion = row.syncVersion,
                deletedAtIso = row.deletedAt,
            ),
        )
    }

    fun applyVisitRow(
        row: VineyardInsightsSyncRepository.VisitRow,
        assessments: List<VineyardInsightsSyncRepository.AssessmentRow>,
        observations: List<VineyardInsightsSyncRepository.ObservationRow>,
        photos: List<VineyardInsightsSyncRepository.PhotoRow>,
    ) {
        val pending = store.loadQueue().any {
            it.recordId == row.id &&
                it.entity == VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT
        }
        if (pending) return

        // A tombstoned visit is removed locally rather than shown as empty.
        if (row.deletedAt != null) {
            store.deleteVisit(row.id)
            return
        }

        val builtAssessments = assessments
            .filter { it.deletedAt == null }
            .map { assessmentRow ->
                val built = observations
                    .filter { it.assessmentId == assessmentRow.id && it.deletedAt == null }
                    .mapNotNull { observationRow ->
                        val item = ScoutItem.byCode(observationRow.itemKind)
                            ?: return@mapNotNull null
                        ScoutObservation(
                            id = observationRow.id,
                            assessmentId = assessmentRow.id,
                            item = item,
                            valueCode = observationRow.valueCode,
                            valueLabel = observationRow.valueLabel,
                            notes = observationRow.notes,
                            photos = photos
                                .filter {
                                    it.observationId == observationRow.id && it.deletedAt == null
                                }
                                .map { photoRow -> photoRow.toDomain() },
                            linkedPinId = observationRow.linkedPinId,
                            linkedGrowthStageRecordId =
                            observationRow.linkedGrowthStageRecordId,
                        )
                    }
                // Items absent server-side are re-created as defaulted rows so
                // the form still presents every question.
                val present = built.map { it.item }.toSet()
                val filled = built + ScoutItem.entries
                    .filterNot { present.contains(it) }
                    .map { ScoutObservation.empty(assessmentRow.id, it) }
                ScoutBlockAssessment(
                    id = assessmentRow.id,
                    visitId = assessmentRow.scoutVisitId,
                    vineyardId = assessmentRow.vineyardId,
                    paddockId = assessmentRow.paddockId,
                    status = ScoutAssessmentStatus.byCode(assessmentRow.status),
                    observations = filled,
                )
            }

        store.saveVisit(
            ScoutVisit(
                id = row.id,
                vineyardId = row.vineyardId,
                // Server-resolved vintage wins.
                vintageYear = row.vintageYear,
                scoutDateIso = row.scoutDate,
                status = ScoutStatus.byCode(row.status),
                visitSummary = row.visitSummary,
                weather = row.weatherSnapshot?.let {
                    ScoutWeatherSnapshot(
                        observedAtIso = it.observedAt,
                        capturedAtIso = it.capturedAt,
                        source = it.source,
                        temperatureCelsius = it.temperatureC,
                        humidityPercent = it.humidityPct,
                        windSpeedKph = it.windKph,
                        windGustKph = it.gustKph,
                        recentRainfallMm = it.recentRainfallMm,
                        isStale = it.isStale,
                        isUnavailable = it.isUnavailable,
                    )
                },
                scoutUserId = row.scoutUserId,
                scoutNameSnapshot = row.scoutNameSnapshot,
                assessments = builtAssessments,
                clientUpdatedAtIso = row.clientUpdatedAt ?: row.updatedAt ?: row.scoutDate,
                syncVersion = row.syncVersion,
            ),
        )
    }

    /**
     * Local bytes are retained when this device already holds them, so a pulled
     * row never blanks a preview that is already on screen.
     */
    private fun VineyardInsightsSyncRepository.PhotoRow.toDomain(): ScoutPhoto {
        val relative = photoFiles?.relativePath(vineyardId, observationId, id)
        val localPath = relative?.takeIf { photoFiles?.exists(it) == true }
        return if (
            locationStatus == PhotoLocationStatus.GPS_CONFIRMED.code &&
            latitude != null && longitude != null
        ) {
            ScoutPhoto.gpsConfirmed(
                observationId = observationId,
                localPath = localPath,
                capturedAtIso = capturedAt,
                capturedByUserId = capturedBy,
                latitude = latitude,
                longitude = longitude,
                accuracyMetres = horizontalAccuracy ?: 0.0,
                id = id,
                storagePath = storagePath,
            )
        } else {
            // Normalised DOWN to block-only: presenting an unverified position
            // as measured is the one failure this feature must never produce.
            ScoutPhoto.blockOnly(
                observationId = observationId,
                localPath = localPath,
                capturedAtIso = capturedAt,
                capturedByUserId = capturedBy,
                id = id,
                storagePath = storagePath,
            )
        }
    }

    private fun isUuid(value: String): Boolean =
        runCatching { java.util.UUID.fromString(value) }.isSuccess
}
