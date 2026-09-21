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
    private val repository: VineyardInsightsSyncApi,
    private val nowIso: () -> String,
    private val canApplyServerResults: () -> Boolean = { true },
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
        if (!store.repairMissingObligations()) {
            return Outcome(error = "Local changes could not be prepared safely for sync.")
        }
        val deletionsBeforePush = pullDeletions(vineyardId)
        val localCleanup = processLocalObjectCleanup(vineyardId)
        val serverCleanup = processServerPhotoCleanup(vineyardId)
        val typePull = pullNoteTypes(vineyardId)
        val typePush = pushNoteTypes(vineyardId)
        val push = pushQueue(vineyardId)
        val photos = pushPhotos(vineyardId)
        val pull = pull(vineyardId)
        val deletionsAfterPull = pullDeletions(vineyardId)
        return Outcome(
            pushed = push.pushed,
            photosUploaded = photos.photosUploaded,
            pulledVisits = pull.pulledVisits,
            pulledNotes = pull.pulledNotes,
            error = deletionsBeforePush.error ?: localCleanup.error ?: serverCleanup.error ?:
                typePull.error ?: typePush.error ?: push.error ?: photos.error ?: pull.error ?: deletionsAfterPull.error,
        )
    }

    // ------------------------------------------------------------ Deletions

    suspend fun pullDeletions(vineyardId: String): Outcome = try {
        val cursor = store.deletionCursor(vineyardId)
        val rows = repository.fetchDeletions(vineyardId, cursor?.deletedAt)
            .filter { row ->
                row.vineyardId == vineyardId && (cursor == null ||
                    row.deletedAt > cursor.deletedAt ||
                    (row.deletedAt == cursor.deletedAt && row.id > cursor.ledgerId))
            }
            .sortedWith(compareBy<VineyardInsightsSyncApi.DeletionRow> { it.deletedAt }.thenBy { it.id })
        for (row in rows) {
            val localPaths = if (row.entityType == VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT.code) {
                val visitPaths = store.loadVisits().firstOrNull {
                    it.id == row.entityId && it.vineyardId == vineyardId
                }?.assessments?.flatMap { it.observations }?.flatMap { it.photos }
                    ?.mapNotNull { it.localPath }.orEmpty()
                val queuedPaths = store.loadPhotoQueue().filter {
                    it.visitId == row.entityId && it.vineyardId == vineyardId
                }.map { it.localPath }
                (visitPaths + queuedPaths).distinct()
            } else {
                emptyList()
            }
            if (!store.queueLocalFileCleanup(vineyardId, localPaths)) {
                return Outcome(error = "Could not preserve local photograph cleanup work.")
            }
            if (!store.consumeDeletion(vineyardId, row.entityType, row.entityId)) {
                return Outcome(error = "Could not reconcile a deletion on this device.")
            }
            if (!store.setDeletionCursor(
                    vineyardId,
                    VineyardInsightsStore.DeletionCursor(row.deletedAt, row.id),
                )) return Outcome(error = "Could not save the deletion cursor.")
            localPaths.forEach { path ->
                photoFiles?.remove(path)
                if (photoFiles?.exists(path) == false) store.acknowledgeLocalFileCleanup(path)
            }
        }
        Outcome()
    } catch (e: Exception) {
        Outcome(error = e.message ?: "Could not refresh deletions yet.")
    }

    suspend fun processLocalObjectCleanup(vineyardId: String): Outcome {
        var error: String? = null
        store.loadObjectCleanup().filter { it.vineyardId == vineyardId }.forEach { item ->
            try {
                repository.removePhotoObject(item.storagePath)
                store.acknowledgeObjectCleanup(item.storagePath)
            } catch (e: Exception) {
                store.recordObjectCleanupFailure(item.storagePath)
                error = e.message ?: "Could not clean up a photograph yet."
            }
        }
        return Outcome(error = error)
    }

    suspend fun processServerPhotoCleanup(vineyardId: String): Outcome = try {
        var error: String? = null
        repository.claimPhotoCleanup(vineyardId).forEach { item ->
            try {
                repository.removePhotoObject(item.storagePath)
                repository.acknowledgePhotoCleanup(item.id, item.leaseToken)
            } catch (e: Exception) {
                runCatching {
                    repository.failPhotoCleanup(
                        item.id,
                        item.leaseToken,
                        e.message ?: "Transient storage removal failure",
                    )
                }
                error = e.message ?: "Could not clean up a photograph yet."
            }
        }
        Outcome(error = error)
    } catch (e: Exception) {
        Outcome(error = e.message ?: "Could not load photograph cleanup work yet.")
    }

    // ------------------------------------------------------------ Push

    suspend fun pullNoteTypes(vineyardId: String): Outcome = try {
        val rows = repository.fetchNoteTypes(vineyardId)
        if (!canApplyServerResults()) return Outcome()
        val types = rows.filter { it.deletedAt == null }
            .mapNotNull { row ->
                VintageNoteGroup.byCode(row.groupCode)?.let { group ->
                    VintageNoteType(row.id, row.code, group, row.label, row.sortOrder,
                        !row.isSystem, row.isActive, row.vineyardId, row.isSystem)
                }
            }
        if (!store.reconcileNoteTypes(vineyardId, types)) {
            Outcome(error = "Could not cache note types on this device.")
        } else {
            Outcome()
        }
    } catch (e: Exception) {
        Outcome(error = e.message ?: "Could not load note types yet.")
    }

    suspend fun pushNoteTypes(vineyardId: String): Outcome {
        var pushed = 0
        var error: String? = null
        for (type in store.pendingNoteTypes(vineyardId)) {
            val id = type.databaseId ?: continue
            try {
                repository.upsertNoteType(
                    VineyardInsightsSyncApi.UpsertNoteTypeArgs(
                        id = id, vineyardId = vineyardId, code = type.code,
                        groupCode = type.group.code, label = type.label,
                        sortOrder = type.sortOrder, isActive = type.isActive,
                    ),
                )
                store.markNoteTypeSynced(id)
                pushed += 1
            } catch (e: Exception) {
                error = e.message ?: "Could not sync a custom note type yet."
            }
        }
        return Outcome(pushed = pushed, error = error)
    }

    suspend fun pushQueue(vineyardId: String? = null): Outcome {
        var pushed = 0
        var error: String? = null
        for (entry in store.loadQueue().filter { vineyardId == null || it.vineyardId == vineyardId }) {
            try {
                val acknowledgedVersion = when (entry.entity) {
                    VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT -> pushVisit(entry)
                    VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE -> {
                        pushNote(entry)
                        null
                    }
                }
                store.dequeue(entry.id, acknowledgedVersion)
                pushed += 1
            } catch (e: Exception) {
                // Left queued deliberately: the local record is intact, so a
                // later attempt can still deliver it.
                error = e.message ?: "Could not sync yet."
                store.recordAttempt(entry.id, error)
            }
        }
        return Outcome(pushed = pushed, error = error)
    }

    private suspend fun pushVisit(entry: VineyardInsightsStore.QueuedOperation): Long? {
        if (entry.operation == VineyardInsightsStore.QueuedOperation.Operation.DELETE) {
            repository.hardDeleteVisit(
                entry.recordId,
                entry.vineyardId,
                entry.id,
                entry.clientUpdatedAtIso,
            )
            return null
        }
        if (store.isDeleted(entry.vineyardId, entry.entity.code, entry.recordId)) {
            store.dequeue(entry.id)
            return null
        }
        val visit = store.loadVisits().firstOrNull { it.id == entry.recordId } ?: return null
        check(visit.clientUpdatedAtIso == entry.clientUpdatedAtIso) {
            "A newer local Scout revision is waiting; the older operation was not acknowledged."
        }
        val revisionId = entry.id

        // vintage_year is NOT sent: SQL 236 resolves it from scout_date.
        val payload = VineyardInsightsSyncApi.VisitUpsert(
            id = visit.id,
            vineyardId = visit.vineyardId,
            scoutDate = visit.scoutDateIso,
            status = visit.status.code,
            visitSummary = visit.visitSummary,
            weatherSnapshot = visit.weather?.let {
                VineyardInsightsSyncApi.WeatherPayload(
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
            clientUpdatedAt = entry.clientUpdatedAtIso,
            clientRevisionId = revisionId,
        )

        val assessments = visit.assessments.map {
            VineyardInsightsSyncApi.AssessmentUpsert(
                id = it.id,
                scoutVisitId = visit.id,
                vineyardId = it.vineyardId,
                paddockId = it.paddockId,
                status = it.status.code,
                clientUpdatedAt = entry.clientUpdatedAtIso,
                clientRevisionId = revisionId,
            )
        }

        // Stable observation rows are sent even when cleared. Reports continue
        // to ignore hasContent=false, while peers receive explicit nulls rather
        // than retaining stale server content.
        val observations = visit.assessments.flatMap { assessment ->
            assessment.observations.map {
                VineyardInsightsSyncApi.ObservationUpsert(
                    id = it.id,
                    assessmentId = assessment.id,
                    vineyardId = assessment.vineyardId,
                    itemKind = it.item.code,
                    valueCode = it.valueCode,
                    valueLabel = it.valueLabel,
                    notes = it.notes,
                    latitude = it.latitude,
                    longitude = it.longitude,
                    horizontalAccuracy = it.accuracyMetres,
                    locationCapturedAt = it.locationCapturedAtIso,
                    locationStatus = it.locationStatus.code,
                    linkedPinId = it.linkedPinId,
                    linkedGrowthStageRecordId = it.linkedGrowthStageRecordId,
                    clientUpdatedAt = entry.clientUpdatedAtIso,
                    clientRevisionId = revisionId,
                )
            }
        }

        // Parent-first ordering is guaranteed inside pushVisit: the SQL 236
        // foreign keys are real, so a child replayed before its parent would be
        // rejected.
        val acknowledged = repository.pushVisit(payload, assessments, observations)
        check(acknowledged.id == entry.recordId && acknowledged.clientRevisionId == revisionId) {
            "The server did not acknowledge this exact Scout revision."
        }
        return acknowledged.syncVersion
    }

    private suspend fun pushNote(entry: VineyardInsightsStore.QueuedOperation) {
        if (entry.operation == VineyardInsightsStore.QueuedOperation.Operation.DELETE) {
            repository.hardDeleteNote(
                entry.recordId,
                entry.vineyardId,
                entry.id,
                entry.clientUpdatedAtIso,
            )
            return
        }
        if (store.isDeleted(entry.vineyardId, entry.entity.code, entry.recordId)) {
            store.dequeue(entry.id)
            return
        }
        val note = store.loadNotes().firstOrNull { it.id == entry.recordId } ?: return
        val returned = repository.upsertNote(
            VineyardInsightsSyncApi.UpsertNoteArgs(
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
     * Drive queued photographs through
     * local_saved -> queued -> object_uploaded -> row_committed -> completed.
     *
     * The ordering rule this method exists to honour: the queue entry is
     * discharged and the photograph reported stored only after BOTH the storage
     * object and the metadata row exist. A storage object with no row is
     * invisible to every client, so completing on the upload alone would tell
     * the operator their evidence was saved when no report could find it.
     *
     * Ownership comes from each entry's own `vineyardId`, never from whatever
     * vineyard is selected when connectivity returns.
     *
     * A late completion can only ever touch ITS OWN photo id, and a photograph
     * the operator deleted has already left the queue, so an in-flight upload
     * cannot resurrect it.
     */
    suspend fun pushPhotos(vineyardId: String): Outcome {
        val files = photoFiles ?: return Outcome()
        var uploaded = 0
        var error: String? = null
        for (entry in store.loadPhotoQueue().filter { it.vineyardId == vineyardId }) {
            val photo = findPhoto(entry.id)
            val step = ScoutPhotoUpload.nextStep(
                photoId = entry.id,
                storagePath = files.storagePath(entry.vineyardId, entry.observationId, entry.id),
                uploadedStoragePath = entry.uploadedStoragePath,
                stillPresentLocally = photo != null,
                rowCommitted = entry.rowCommitted,
            )

            if (step is ScoutPhotoUpload.Step.Cancel) {
                // Deleted locally while queued. An object with no row is
                // referenced by nothing, so it is removed rather than left as
                // unreachable clutter; a committed row is tombstoned instead.
                step.orphanedStoragePath?.let { orphan ->
                    runCatching { repository.removePhotoObject(orphan) }
                }
                if (entry.rowCommitted) {
                    runCatching { repository.softDeletePhoto(entry.id, nowIso()) }
                }
                store.dequeuePhoto(entry.id)
                continue
            }
            if (photo == null) continue

            try {
                // ---- object_uploaded ----------------------------------------
                // Persisted BEFORE the row is attempted, so a crash in between
                // resumes at the metadata upsert instead of re-uploading bytes
                // that are already in the bucket.
                var path = entry.uploadedStoragePath
                if (step is ScoutPhotoUpload.Step.UploadObject) {
                    val jpeg = files.read(entry.localPath)
                    if (jpeg == null) {
                        error = "The photograph file is missing on this device."
                        store.recordPhotoFailure(entry.id, error)
                        markPhotoFailed(entry.id)
                        continue
                    }
                    // Same photo id, same path on every retry: the object is
                    // overwritten, never duplicated.
                    path = repository.uploadPhotoBytes(step.storagePath, jpeg)
                    // Refuses if the operator deleted the photograph while this
                    // upload was in flight — the entry is gone and must not be
                    // recreated by its own callback.
                    if (!store.markPhotoObjectUploaded(entry.id, path)) {
                        runCatching { repository.removePhotoObject(path) }
                        continue
                    }
                }
                val storagePath = path ?: continue

                // ---- row_committed -------------------------------------------
                // Upserted on the photograph's own primary key, so a retry after
                // a failed row write updates rather than duplicating.
                repository.pushPhotoRow(
                    VineyardInsightsSyncApi.PhotoUpsert(
                        id = photo.id,
                        observationId = photo.observationId,
                        vineyardId = entry.vineyardId,
                        storagePath = storagePath,
                        capturedAt = photo.capturedAtIso,
                        latitude = photo.latitude,
                        longitude = photo.longitude,
                        horizontalAccuracy = photo.accuracyMetres,
                        locationStatus = photo.locationStatus.code,
                        capturedBy = photo.capturedByUserId,
                        clientUpdatedAt = entry.capturedAt,
                        clientRevisionId = entry.id,
                    ),
                )
                if (!store.markPhotoRowCommitted(entry.id)) continue

                // ---- completed ------------------------------------------------
                // Only now, with both effects durable, is the obligation gone.
                applyPhotoStoragePath(entry.id, storagePath, failed = false)
                store.dequeuePhoto(entry.id)
                uploaded += 1
            } catch (e: Exception) {
                // The local photograph and its queue entry are both retained, so
                // a half-finished upload stays retryable. A failed upload must
                // never present as a lost photograph.
                error = e.message ?: "Could not upload the photograph yet."
                store.recordPhotoFailure(entry.id, error)
                markPhotoFailed(entry.id)
            }
        }
        return Outcome(photosUploaded = uploaded, error = error)
    }

    /**
     * Remove a storage object left behind by a photograph the operator deleted
     * between its bytes landing and its metadata row being written.
     *
     * Returns whether the object is genuinely gone, so the caller keeps the
     * obligation outstanding on failure rather than abandoning an unreachable
     * object nobody can ever see or clean up.
     */
    suspend fun removeOrphanedPhotoObject(storagePath: String): Boolean =
        runCatching { repository.removePhotoObject(storagePath) }.isSuccess

    /**
     * Tombstone a fully stored photograph's metadata row. The storage object is
     * retained: the established policy keeps uploaded evidence recoverable
     * rather than destroying the record of a real observation.
     */
    suspend fun tombstonePhoto(photoId: String): Boolean =
        runCatching { repository.softDeletePhoto(photoId, nowIso()) }.isSuccess

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
        store.saveVisit(next, store.isSyncOwedForVisit(next.id))
    }

    // ------------------------------------------------------------ Pull

    /** Pull the server's view so another device's or session's work appears. */
    suspend fun pull(vineyardId: String): Outcome {
        return try {
            // System Admin preview uses a complete active-graph pull. This is
            // server-authoritative and cannot miss a changed child because its
            // parent row did not change or because a client clock was skewed.
            val typeOutcome = pullNoteTypes(vineyardId)
            if (typeOutcome.error != null) return typeOutcome

            val noteRows = repository.fetchNotes(vineyardId, null)
            if (!canApplyServerResults()) return Outcome()
            noteRows.forEach { applyNoteRow(it) }

            val visitRows = repository.fetchVisits(vineyardId, null)
            if (!canApplyServerResults()) return Outcome()
            if (visitRows.isNotEmpty()) {
                val assessmentRows = repository.fetchAssessments(vineyardId, visitRows.map { it.id })
                if (!canApplyServerResults()) return Outcome()
                val observationRows =
                    repository.fetchObservations(vineyardId, assessmentRows.map { it.id })
                if (!canApplyServerResults()) return Outcome()
                val photoRows = repository.fetchPhotos(vineyardId, observationRows.map { it.id })
                if (!canApplyServerResults()) return Outcome()
                val failedDownloads = mutableSetOf<String>()
                photoRows.filter { it.deletedAt == null && it.storagePath.isNotBlank() }.forEach { photo ->
                    val files = photoFiles
                    val localPath = files?.relativePath(photo.vineyardId, photo.observationId, photo.id)
                    if (files != null && localPath != null && !files.exists(localPath)) {
                        runCatching { repository.downloadPhotoBytes(photo.storagePath) }
                            .onSuccess { bytes ->
                                if (!canApplyServerResults()) return@onSuccess
                                if (files.write(bytes, photo.vineyardId, photo.observationId, photo.id) == null) {
                                    failedDownloads += photo.id
                                }
                            }
                            .onFailure { failedDownloads += photo.id }
                    }
                }
                if (!canApplyServerResults()) return Outcome()
                visitRows.forEach { row ->
                    applyVisitRow(
                        row,
                        assessmentRows.filter { it.scoutVisitId == row.id },
                        observationRows,
                        photoRows,
                        failedDownloads,
                    )
                }
            }
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
    fun applyNoteRow(row: VineyardInsightsSyncApi.NoteRow) {
        val pending = store.loadQueue().any {
            it.recordId == row.id &&
                it.entity == VineyardInsightsStore.QueuedOperation.Entity.VINTAGE_NOTE
        }
        if (pending || store.isSyncOwedForNote(row.id) || store.isDeleted(row.vineyardId, "vintage_note", row.id)) return
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
            syncOwed = false,
        )
    }

    fun applyVisitRow(
        row: VineyardInsightsSyncApi.VisitRow,
        assessments: List<VineyardInsightsSyncApi.AssessmentRow>,
        observations: List<VineyardInsightsSyncApi.ObservationRow>,
        photos: List<VineyardInsightsSyncApi.PhotoRow>,
        failedPhotoDownloads: Set<String> = emptySet(),
    ) {
        val pending = store.loadQueue().any {
            it.recordId == row.id &&
                it.entity == VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT
        }
        if (pending || store.isSyncOwedForVisit(row.id) || store.isDeleted(row.vineyardId, "scout_visit", row.id)) return

        // A tombstoned visit is removed locally rather than shown as empty.
        if (row.deletedAt != null) {
            store.deleteVisit(row.id)
            return
        }

        val localVisit = store.loadVisits().firstOrNull { it.id == row.id }
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
                            photos = mergePhotos(
                                server = photos
                                    .filter { it.observationId == observationRow.id && it.deletedAt == null }
                                    .map { photoRow -> photoRow.toDomain(photoRow.id in failedPhotoDownloads) },
                                explicitlyDeletedIds = photos
                                    .filter { it.observationId == observationRow.id && it.deletedAt != null }
                                    .mapTo(mutableSetOf()) { it.id },
                                local = localVisit?.assessments
                                    ?.firstOrNull { it.id == assessmentRow.id }
                                    ?.observations
                                    ?.firstOrNull { it.id == observationRow.id }
                                    ?.photos.orEmpty(),
                            ),
                            latitude = observationRow.latitude,
                            longitude = observationRow.longitude,
                            accuracyMetres = observationRow.horizontalAccuracy,
                            locationCapturedAtIso = observationRow.locationCapturedAt,
                            locationStatus = PhotoLocationStatus.byCode(observationRow.locationStatus),
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
            syncOwed = false,
        )
    }

    private fun mergePhotos(
        server: List<ScoutPhoto>,
        local: List<ScoutPhoto>,
        explicitlyDeletedIds: Set<String>,
    ): List<ScoutPhoto> {
        store.clearPhotoDeletionIntents(explicitlyDeletedIds)
        val deletionIntents = store.photoDeletionIntents()
        val pendingIds = store.loadPhotoQueue().mapTo(mutableSetOf()) { it.id }
        val localById = local.associateBy { it.id }
        val merged = server.filterNot { it.id in deletionIntents }.map { serverPhoto ->
            val localPhoto = localById[serverPhoto.id]
            when {
                localPhoto == null -> serverPhoto
                serverPhoto.id in pendingIds -> localPhoto
                else -> serverPhoto.copy(localPath = localPhoto.localPath?.takeIf { photoFiles?.exists(it) == true })
            }
        }.toMutableList()
        val serverIds = merged.mapTo(mutableSetOf()) { it.id }
        merged += local.filterNot {
            it.id in serverIds || it.id in explicitlyDeletedIds || it.id in deletionIntents
        }
        return merged
    }

    /**
     * Local bytes are retained when this device already holds them, so a pulled
     * row never blanks a preview that is already on screen.
     */
    private fun VineyardInsightsSyncApi.PhotoRow.toDomain(downloadFailed: Boolean = false): ScoutPhoto {
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
                uploadFailed = downloadFailed,
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
                uploadFailed = downloadFailed,
            )
        }
    }

    private fun isUuid(value: String): Boolean =
        runCatching { java.util.UUID.fromString(value) }.isSuccess
}
