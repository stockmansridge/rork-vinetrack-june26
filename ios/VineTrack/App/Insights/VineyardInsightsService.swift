import Foundation
import Observation
import UIKit
import os

/// A GPS fix that ALREADY passed the existing strict validator.
///
/// Only the caller that ran the validator can construct one, so a
/// non-qualifying reading cannot reach photo storage as coordinates. The
/// absence of this value is what produces an explicit block-only photograph.
nonisolated struct ScoutPhotoFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracyMetres: Double
}

/// Local-first state holder for the Vineyard Insights preview.
///
/// Deliberately a self-contained service rather than state spread through the
/// existing app objects: this is an unreleased, System Admin-only preview, so
/// keeping it in one removable place means the feature can be withdrawn
/// without unpicking anything else. It also keeps the capture rules testable.
///
/// Every mutation writes to `VineyardInsightsStore` FIRST and queues a sync
/// operation second, then pushes opportunistically. The network is an eventual
/// reconciliation, never the place the data lives.
@Observable
@MainActor
final class VineyardInsightsService {

    private(set) var visits: [ScoutVisit] = []
    private(set) var notes: [VintageNote] = []
    private(set) var openVisitID: UUID?

    /// Non-fatal sync state, surfaced so a stuck queue is visible rather than
    /// silently pending forever.
    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var pendingPhotoCount = 0

    /// True when the most recent local write failed to reach disk.
    ///
    /// Surfaced so the operator can be told, rather than being left to assume a
    /// capture is safe. A field observation that silently failed to save is the
    /// worst outcome this feature can produce.
    private(set) var lastWriteFailed = false

    private let store: VineyardInsightsStore
    private let photoFiles: ScoutPhotoFileStore
    private let repository: VineyardInsightsSyncRepository
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.vinetrack.app", category: "vineyard-insights")

    init(
        store: VineyardInsightsStore = VineyardInsightsStore(),
        photoFiles: ScoutPhotoFileStore = ScoutPhotoFileStore(),
        repository: VineyardInsightsSyncRepository = VineyardInsightsSyncRepository(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.photoFiles = photoFiles
        self.repository = repository
        self.now = now
        self.visits = store.loadVisits()
        self.notes = store.loadNotes()
        self.pendingPhotoCount = store.loadPhotoQueue().count
    }

    /// Local bytes for immediate display. Read from disk, so the photograph
    /// appears instantly and identically before, during and after upload.
    func localImage(_ photo: ScoutPhoto) -> UIImage? {
        guard let path = photo.localPath else { return nil }
        return photoFiles.image(atRelativePath: path)
    }

    @discardableResult
    private func record(_ success: Bool) -> Bool {
        lastWriteFailed = !success
        return success
    }

    // MARK: - Scout

    func openVisit(_ id: UUID?) { openVisitID = id }

    func visit(_ id: UUID?) -> ScoutVisit? {
        guard let id else { return nil }
        return visits.first { $0.id == id }
    }

    var openVisit: ScoutVisit? { visit(openVisitID) }

    func visitHistory(vineyardID: UUID, vintageYear: Int?) -> [ScoutVisit] {
        ScoutHistoryPolicy.select(visits, vineyardID: vineyardID, vintageYear: vintageYear)
    }

    func visits(status: ScoutStatus) -> [ScoutVisit] {
        visits.filter { $0.status == status }.sorted { $0.scoutDate > $1.scoutDate }
    }

    /// Start a new visit. The id is client-generated so an offline capture
    /// already has its permanent identity before the server ever hears of it.
    @discardableResult
    func startVisit(
        vineyardID: UUID,
        scoutUserID: UUID?,
        scoutName: String?,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        date: Date = Date()
    ) -> ScoutVisit {
        let visit = ScoutVisit(
            vineyardID: vineyardID,
            vintageYear: VintageResolver.vintageYear(
                for: date,
                seasonStartMonth: seasonStartMonth,
                seasonStartDay: seasonStartDay
            ),
            scoutDate: date,
            scoutUserID: scoutUserID,
            scoutNameSnapshot: scoutName,
            clientUpdatedAt: now()
        )
        persist(visit)
        openVisitID = visit.id
        return visit
    }

    func toggleBlock(visitID: UUID, paddockID: UUID) {
        guard var visit = visit(visitID), visit.isEditable else { return }
        if let existing = visit.assessment(paddockID: paddockID) {
            // Removing a block that already holds observations would discard
            // field work, so only an untouched block may be removed by a toggle.
            guard existing.recordedObservations.isEmpty else { return }
            visit.removeBlock(paddockID: paddockID)
        } else {
            visit.addBlock(paddockID: paddockID)
        }
        persist(visit)
    }

    func setSummary(visitID: UUID, summary: String) {
        guard var visit = visit(visitID), visit.isEditable else { return }
        visit.visitSummary = summary.isEmpty ? nil : summary
        persist(visit)
    }

    func setWeather(visitID: UUID, weather: ScoutWeatherSnapshot) {
        guard var visit = visit(visitID) else { return }
        visit.weather = weather
        persist(visit)
    }

    func setObservationValue(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        option: ScoutOption
    ) {
        updateObservation(visitID: visitID, assessmentID: assessmentID, item: item) {
            $0.valueCode = option.code
            $0.valueLabel = option.label
        }
    }

    func setObservationNotes(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        notes: String
    ) {
        updateObservation(visitID: visitID, assessmentID: assessmentID, item: item) {
            $0.notes = notes.isEmpty ? nil : notes
        }
    }

    // MARK: - Photographs

    /// Capture one photograph for one assessment item.
    ///
    /// Order matters and is the whole contract:
    ///  1. mint a stable client photo id,
    ///  2. write the compressed bytes to app-private storage,
    ///  3. record the photo against the observation locally,
    ///  4. queue the upload,
    ///  5. attempt the upload opportunistically.
    ///
    /// Steps 1–3 complete without any network. If step 5 fails the photograph
    /// is already safe and visible, and Retry is offered. Nothing about this
    /// path can lose the image because the server was unreachable.
    ///
    /// `locationFix` is the verdict from the EXISTING strict validator, resolved
    /// by the caller. A non-qualifying fix arrives here as nil and becomes an
    /// explicit block-only photograph — never a stale or last-known position.
    @discardableResult
    func capturePhoto(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        imageData: Data,
        locationFix: ScoutPhotoFix?,
        capturedByUserID: UUID?
    ) -> ScoutPhoto? {
        guard let visit = visit(visitID), visit.isEditable else { return nil }
        guard var assessment = visit.assessments.first(where: { $0.id == assessmentID }) else { return nil }

        // The observation must exist before the photo can reference it, because
        // scout_observation_photos.observation_id is a real foreign key.
        let observation = assessment.observation(item)
            ?? ScoutObservation.empty(assessmentID: assessmentID, item: item)
        let photoID = UUID()

        let relativePath: String
        do {
            relativePath = try photoFiles.write(
                data: imageData,
                vineyardID: visit.vineyardID,
                observationID: observation.id,
                photoID: photoID
            )
        } catch {
            // A photograph that could not be written to disk is NOT recorded.
            // Showing it and losing it later would be worse than refusing now.
            lastWriteFailed = true
            logger.warning("Scout photo write failed")
            return nil
        }

        let capturedAt = now()
        let photo: ScoutPhoto = {
            if let fix = locationFix {
                return ScoutPhoto.gpsConfirmed(
                    observationID: observation.id,
                    localPath: relativePath,
                    capturedAt: capturedAt,
                    capturedByUserID: capturedByUserID,
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    accuracyMetres: fix.accuracyMetres,
                    id: photoID
                )
            }
            return ScoutPhoto.blockOnly(
                observationID: observation.id,
                localPath: relativePath,
                capturedAt: capturedAt,
                capturedByUserID: capturedByUserID,
                id: photoID
            )
        }()

        var updated = observation
        updated.photos.append(photo)
        assessment.setObservation(updated)
        var nextVisit = visit
        nextVisit.setAssessment(assessment)
        guard persist(nextVisit) else { return nil }

        store.enqueuePhoto(
            VineyardInsightsStore.QueuedPhoto(
                id: photoID,
                vineyardID: visit.vineyardID,
                visitID: visitID,
                observationID: observation.id,
                localPath: relativePath,
                uploadedStoragePath: nil,
                rowCommitted: false,
                capturedAt: capturedAt,
                attemptCount: 0,
                lastError: nil
            )
        )
        pendingPhotoCount = store.loadPhotoQueue().count

        Task { await syncPhotos(vineyardID: visit.vineyardID) }
        return photo
    }

    /// Delete one photograph, invalidating any queued upload for it.
    ///
    /// The queue entry is removed FIRST so a replay already in flight cannot
    /// resurrect a photograph the operator deleted. If the bytes were already
    /// uploaded the row is soft-deleted server-side; the object itself is left
    /// for server-side lifecycle rather than hard-deleted from the client.
    @discardableResult
    func deletePhoto(visitID: UUID, assessmentID: UUID, item: ScoutItem, photoID: UUID) -> Bool {
        guard let visit = visit(visitID), visit.isEditable else { return false }
        guard var assessment = visit.assessments.first(where: { $0.id == assessmentID }),
              var observation = assessment.observation(item),
              let photo = observation.photos.first(where: { $0.id == photoID }) else { return false }

        let queued = store.loadPhotoQueue().first { $0.id == photoID }
        store.dequeuePhoto(photoID: photoID)
        pendingPhotoCount = store.loadPhotoQueue().count

        observation.photos.removeAll { $0.id == photoID }
        assessment.setObservation(observation)
        var nextVisit = visit
        nextVisit.setAssessment(assessment)
        guard persist(nextVisit) else { return false }

        if let path = photo.localPath { photoFiles.remove(relativePath: path) }

        let deletedAt = now()
        if let orphanedPath = queued?.uploadedStoragePath, queued?.rowCommitted != true {
            Task { [repository] in
                try? await repository.removePhotoObject(path: orphanedPath)
            }
        } else if photo.storagePath != nil || queued?.rowCommitted == true {
            Task { [repository] in
                try? await repository.softDeletePhoto(id: photoID, at: deletedAt)
            }
        }
        return true
    }

    /// Retry a failed photograph upload. The local bytes were never discarded.
    func retryPhotoUploads(vineyardID: UUID) {
        Task { await syncPhotos(vineyardID: vineyardID) }
    }

    // MARK: - E-L linkage

    /// Attach the canonical Growth Stage pin and record created for an E-L
    /// selection.
    ///
    /// The stage VALUE is deliberately not stored as an authoritative figure —
    /// only the two canonical ids plus a label snapshot for report
    /// presentation. See `ScoutGrowthStageLink`.
    func linkGrowthStageRecord(
        visitID: UUID,
        assessmentID: UUID,
        pinID: UUID?,
        recordID: UUID,
        stageLabel: String
    ) {
        updateObservation(visitID: visitID, assessmentID: assessmentID, item: .growthStage) {
            $0.linkedPinID = pinID
            $0.linkedGrowthStageRecordID = recordID
            $0.valueLabel = stageLabel
        }
    }

    /// Drop the Scout's reference to a canonical record.
    ///
    /// The canonical pin and `growth_stage_records` row are NOT touched. The
    /// observation genuinely happened; only the scout's citation of it is
    /// removed. Callers must confirm with the operator first.
    func unlinkGrowthStageRecord(visitID: UUID, assessmentID: UUID) {
        updateObservation(visitID: visitID, assessmentID: assessmentID, item: .growthStage) {
            $0.linkedPinID = nil
            $0.linkedGrowthStageRecordID = nil
            $0.valueLabel = nil
        }
    }

    private func updateObservation(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        _ transform: (inout ScoutObservation) -> Void
    ) {
        guard var visit = visit(visitID), visit.isEditable else { return }
        guard var assessment = visit.assessments.first(where: { $0.id == assessmentID }) else { return }
        var observation = assessment.observation(item)
            ?? ScoutObservation.empty(assessmentID: assessmentID, item: item)
        transform(&observation)
        assessment.setObservation(observation)
        visit.setAssessment(assessment)
        persist(visit)
    }

    func review(visitID: UUID) -> ScoutReview {
        guard let visit = visit(visitID) else {
            return ScoutReview(
                blocksAssessed: 0,
                blocksIncomplete: 0,
                growthStageObservations: 0,
                attentionItems: 0,
                photoCount: 0,
                otherIssues: 0,
                generalRecommendations: 0,
                incompletePaddockIDs: []
            )
        }
        return ScoutReview.of(visit)
    }

    /// Complete a visit, refusing when the review rule is not satisfied.
    @discardableResult
    func completeVisit(_ visitID: UUID) -> Bool {
        guard var visit = visit(visitID), ScoutReview.of(visit).canComplete else { return false }
        visit.status = .completed
        return persist(visit)
    }

    /// Deliberately return a completed visit to Draft, with caller confirmation.
    @discardableResult
    func reopenVisit(_ visitID: UUID) -> Bool {
        guard var visit = visit(visitID) else { return false }
        visit.status = .draft
        return persist(visit)
    }

    /// Delete a Scout. Canonical Growth Stage records it created are RETAINED —
    /// the returned links are what the caller should unlink, never delete.
    @discardableResult
    func deleteVisit(_ visitID: UUID) -> [ScoutGrowthStageLink] {
        guard let visit = visit(visitID) else { return [] }
        let retained = ScoutGrowthStageLink.onScoutDeleted(visit)
        let deletedAt = now()
        if record(store.deleteVisit(id: visitID)) {
            store.enqueue(
                recordID: visit.id,
                vineyardID: visit.vineyardID,
                entity: .scoutVisit,
                operation: .delete,
                clientUpdatedAt: deletedAt
            )
            visits = store.loadVisits()
            if openVisitID == visitID { openVisitID = nil }
        }
        return retained
    }

    @discardableResult
    private func persist(_ visit: ScoutVisit) -> Bool {
        var stamped = visit
        stamped.clientUpdatedAt = now()
        let saved = store.saveVisit(stamped)
        if saved {
            visits = store.loadVisits()
            store.enqueue(
                recordID: stamped.id,
                vineyardID: stamped.vineyardID,
                entity: .scoutVisit,
                operation: .upsert,
                clientUpdatedAt: stamped.clientUpdatedAt
            )
        }
        return record(saved)
    }

    // MARK: - Vintage Notes

    func noteHistory(vineyardID: UUID, vintageYear: Int?) -> [VintageNote] {
        VintageNoteRules.history(notes, vineyardID: vineyardID, vintageYear: vintageYear)
    }

    func notes(vintageYear: Int) -> [VintageNote] {
        VintageNoteRules.forVintage(notes, vintageYear: vintageYear)
    }

    func customNoteTypes(vineyardID: UUID) -> [VintageNoteType] {
        store.customNoteTypes(vineyardID: vineyardID)
    }

    @discardableResult
    func addCustomNoteType(
        vineyardID: UUID,
        label: String,
        group: VintageNoteGroup = .other
    ) -> VintageNoteType? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let type = VintageNoteType(
            code: "custom_\(UUID().uuidString.prefix(8).lowercased())",
            group: group,
            label: trimmed,
            sortOrder: 1_000,
            isCustom: true
        )
        return record(store.saveCustomNoteType(vineyardID: vineyardID, type: type)) ? type : nil
    }

    /// Create or update a note from the form draft.
    ///
    /// Returns nil when the draft is empty — the rule lives on
    /// `VintageNoteDraft` so the form, this path and the server all state it
    /// the same way. The vintage written here is the local mirror for display;
    /// the server recomputes it from the date and its answer wins.
    @discardableResult
    func saveNote(
        draft: VintageNoteDraft,
        vineyardID: UUID,
        observedByUserID: UUID?,
        observerName: String?,
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> VintageNote? {
        guard draft.canSave else { return nil }
        let timestamp = now()
        let existing = notes.first { $0.id == draft.id }
        guard existing == nil || existing?.vineyardID == vineyardID else { return nil }
        let note = VintageNote(
            id: draft.id,
            vineyardID: existing?.vineyardID ?? vineyardID,
            noteDate: draft.date,
            vintageYear: draft.resolvedVintage(
                seasonStartMonth: seasonStartMonth,
                seasonStartDay: seasonStartDay
            ),
            noteTypeID: draft.noteTypeID,
            // Only overwrite the historical snapshot when the form carries a
            // label. An edit that does not touch the type must not blank what
            // the original observer chose.
            noteTypeLabelSnapshot: draft.noteTypeLabel ?? existing?.noteTypeLabelSnapshot,
            notes: draft.notes.isEmpty ? nil : draft.notes,
            observedByUserID: existing?.observedByUserID ?? observedByUserID,
            observerNameSnapshot: existing?.observerNameSnapshot ?? observerName,
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: timestamp,
            clientUpdatedAt: timestamp,
            syncVersion: existing?.syncVersion ?? 0,
            deletedAt: nil
        )
        guard record(store.saveNote(note)) else { return nil }
        notes = store.loadNotes()
        store.enqueue(
            recordID: note.id,
            vineyardID: note.vineyardID,
            entity: .vintageNote,
            operation: .upsert,
            clientUpdatedAt: note.clientUpdatedAt
        )
        return note
    }

    /// Hard-delete locally immediately and queue the durable server deletion.
    @discardableResult
    func deleteNote(_ noteID: UUID) -> Bool {
        guard let note = notes.first(where: { $0.id == noteID }) else { return false }
        let timestamp = now()
        guard record(store.deleteNote(id: noteID)) else { return false }
        notes = store.loadNotes()
        store.enqueue(
            recordID: note.id,
            vineyardID: note.vineyardID,
            entity: .vintageNote,
            operation: .delete,
            clientUpdatedAt: timestamp
        )
        return true
    }

    // MARK: - Sync
    //
    // The replay worker. Local state is already durable before any of this
    // runs, so every failure path here is "try again later", never data loss.

    /// Push queued work then pull the server's view for one vineyard.
    ///
    /// The vineyard is passed in rather than read from the current selection
    /// because queue entries carry their OWN vineyard id — see `syncQueue`.
    func sync(vineyardID: UUID) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await pullDeletions(vineyardID: vineyardID)
        await processPhotoCleanup(vineyardID: vineyardID)
        await syncQueue()
        await syncPhotos(vineyardID: vineyardID)
        await pull(vineyardID: vineyardID)
        await pullDeletions(vineyardID: vineyardID)
    }

    /// Replay every queued record operation.
    ///
    /// Entries are grouped by the vineyard they were CAPTURED in. An operator
    /// who scouts Block 4, drives home, switches vineyards and reconnects must
    /// have that morning's work filed against the vineyard they were standing
    /// in — never against whichever one happens to be selected now.
    func syncQueue() async {
        for entry in store.loadQueue() {
            do {
                switch entry.entity {
                case .scoutVisit:
                    try await pushVisit(entry: entry)
                case .vintageNote:
                    try await pushNote(entry: entry)
                }
                store.dequeue(queueID: entry.id)
                lastSyncError = nil
            } catch {
                // Left queued deliberately: the local record is intact, so a
                // later attempt can still deliver it.
                lastSyncError = error.localizedDescription
                logger.warning("Insights queue entry deferred")
            }
        }
    }

    private func pushVisit(entry: VineyardInsightsStore.QueuedOperation) async throws {
        if entry.operation == .delete {
            try await repository.hardDeleteVisit(
                id: entry.recordID,
                vineyardID: entry.vineyardID,
                operationID: entry.id,
                at: entry.clientUpdatedAt
            )
            return
        }
        if store.isDeleted(vineyardID: entry.vineyardID, entity: .scoutVisit, entityID: entry.recordID) {
            store.dequeue(queueID: entry.id)
            return
        }
        guard let visit = visits.first(where: { $0.id == entry.recordID }) else { return }

        let weather = visit.weather.map {
            VineyardInsightsSyncRepository.WeatherPayload(
                observed_at: $0.observedAt.map { VineyardInsightsSyncRepository.timestamp($0) },
                captured_at: VineyardInsightsSyncRepository.timestamp($0.capturedAt),
                source: $0.source,
                temperature_c: $0.temperatureCelsius,
                humidity_pct: $0.humidityPercent,
                wind_kph: $0.windSpeedKph,
                gust_kph: $0.windGustKph,
                recent_rainfall_mm: $0.recentRainfallMm,
                is_stale: $0.isStale,
                is_unavailable: $0.isUnavailable
            )
        }

        // vintage_year is NOT sent: SQL 236 resolves it from scout_date.
        let visitPayload = VineyardInsightsSyncRepository.VisitUpsert(
            id: visit.id.uuidString,
            vineyard_id: visit.vineyardID.uuidString,
            scout_date: VineyardInsightsSyncRepository.day(visit.scoutDate),
            status: visit.status.code,
            visit_summary: visit.visitSummary,
            weather_snapshot: weather,
            scout_user_id: visit.scoutUserID?.uuidString,
            scout_name_snapshot: visit.scoutNameSnapshot,
            client_updated_at: VineyardInsightsSyncRepository.timestamp(visit.clientUpdatedAt),
            deleted_at: nil
        )

        let assessments = visit.assessments.map { assessment in
            VineyardInsightsSyncRepository.AssessmentUpsert(
                id: assessment.id.uuidString,
                scout_visit_id: visit.id.uuidString,
                vineyard_id: assessment.vineyardID.uuidString,
                paddock_id: assessment.paddockID.uuidString,
                status: assessment.status.code,
                client_updated_at: VineyardInsightsSyncRepository.timestamp(visit.clientUpdatedAt)
            )
        }

        // Only observations carrying content are sent. An untouched defaulted
        // row is not evidence and would pad the report with "not assessed"
        // entries the scout never actually considered.
        let observations = visit.assessments.flatMap { assessment in
            assessment.observations.filter(\.hasContent).map { observation in
                VineyardInsightsSyncRepository.ObservationUpsert(
                    id: observation.id.uuidString,
                    assessment_id: assessment.id.uuidString,
                    vineyard_id: assessment.vineyardID.uuidString,
                    item_kind: observation.item.code,
                    value_code: observation.valueCode,
                    value_label: observation.valueLabel,
                    notes: observation.notes,
                    linked_pin_id: observation.linkedPinID?.uuidString,
                    linked_growth_stage_record_id: observation.linkedGrowthStageRecordID?.uuidString,
                    client_updated_at: VineyardInsightsSyncRepository.timestamp(visit.clientUpdatedAt)
                )
            }
        }

        // Parent-first ordering is guaranteed inside pushVisit.
        try await repository.pushVisit(
            visit: visitPayload,
            assessments: assessments,
            observations: observations
        )
    }

    private func pushNote(entry: VineyardInsightsStore.QueuedOperation) async throws {
        if entry.operation == .delete {
            try await repository.hardDeleteNote(
                id: entry.recordID,
                vineyardID: entry.vineyardID,
                operationID: entry.id,
                at: entry.clientUpdatedAt
            )
            return
        }
        if store.isDeleted(vineyardID: entry.vineyardID, entity: .vintageNote, entityID: entry.recordID) {
            store.dequeue(queueID: entry.id)
            return
        }
        guard let note = notes.first(where: { $0.id == entry.recordID }) else { return }

        let returned = try await repository.upsertNote(
            VineyardInsightsSyncRepository.UpsertNoteParams(
                p_id: note.id.uuidString,
                p_vineyard_id: note.vineyardID.uuidString,
                p_note_date: VineyardInsightsSyncRepository.day(note.noteDate),
                // note_type_id is a uuid column; a catalogue CODE is not a uuid,
                // so only an actual type id is sent. The label snapshot carries
                // the operator's choice either way.
                p_note_type_id: UUID(uuidString: note.noteTypeID ?? "")?.uuidString,
                p_note_type_label: note.noteTypeLabelSnapshot,
                p_notes: note.notes,
                p_observer_name: note.observerNameSnapshot,
                p_client_updated_at: VineyardInsightsSyncRepository.timestamp(note.clientUpdatedAt)
            )
        )

        // Reconcile the server's canonical answer, above all the vintage it
        // resolved from the date. The local value was only ever for display.
        if let returned { apply(noteRow: returned) }
    }

    /// Upload queued photographs, then write their metadata rows.
    ///
    /// A late completion can only ever touch ITS OWN photo id, so it cannot
    /// replace or remove a newer photograph. A photo the operator deleted has
    /// already left the queue and is skipped entirely.
    func syncPhotos(vineyardID: UUID) async {
        for entry in store.loadPhotoQueue() where entry.vineyardID == vineyardID {
            guard let photo = photo(id: entry.id) else {
                // Deleted locally while queued — drop the obligation.
                store.dequeuePhoto(photoID: entry.id)
                continue
            }
            guard let data = photoFiles.data(atRelativePath: entry.localPath) else {
                markPhotoFailed(entry: entry, message: "The photograph file is missing on this device.")
                continue
            }
            do {
                let path: String
                if let already = entry.uploadedStoragePath {
                    // Bytes already landed on a previous attempt; only the row
                    // is still owed. Re-uploading would be wasted work.
                    path = already
                } else {
                    path = try await repository.uploadPhotoBytes(
                        path: ScoutPhotoFileStore.storagePath(
                            vineyardID: entry.vineyardID,
                            observationID: entry.observationID,
                            photoID: entry.id
                        ),
                        data: data
                    )
                    guard store.markPhotoUploaded(photoID: entry.id, storagePath: path) else {
                        // Deleted while upload was in flight: remove the now-orphaned object.
                        try? await repository.removePhotoObject(path: path)
                        continue
                    }
                }

                // Cancellation always wins, including after a restart-resumed object upload.
                guard store.loadPhotoQueue().contains(where: { $0.id == entry.id }) else {
                    try? await repository.removePhotoObject(path: path)
                    continue
                }

                try await repository.pushPhotoRow(
                    VineyardInsightsSyncRepository.PhotoUpsert(
                        id: photo.id.uuidString,
                        observation_id: photo.observationID.uuidString,
                        vineyard_id: entry.vineyardID.uuidString,
                        storage_path: path,
                        captured_at: VineyardInsightsSyncRepository.timestamp(photo.capturedAt),
                        latitude: photo.latitude,
                        longitude: photo.longitude,
                        horizontal_accuracy: photo.accuracyMetres,
                        location_status: photo.locationStatus.code,
                        captured_by: photo.capturedByUserID?.uuidString,
                        client_updated_at: VineyardInsightsSyncRepository.timestamp(now())
                    )
                )

                guard store.markPhotoRowCommitted(photoID: entry.id) else {
                    // A deletion raced the metadata callback. Tombstone the row;
                    // never recreate the local queue entry or photograph.
                    try? await repository.softDeletePhoto(id: entry.id, at: now())
                    continue
                }
                applyPhotoStoragePath(photoID: entry.id, storagePath: path, failed: false)
                store.dequeuePhoto(photoID: entry.id)
            } catch {
                // The local photograph is retained and Retry is offered. A
                // failed upload must never present as a lost photograph.
                markPhotoFailed(entry: entry, message: error.localizedDescription)
            }
        }
        pendingPhotoCount = store.loadPhotoQueue().count
    }

    private func markPhotoFailed(entry: VineyardInsightsStore.QueuedPhoto, message: String) {
        store.recordPhotoFailure(photoID: entry.id, message: message)
        applyPhotoStoragePath(photoID: entry.id, storagePath: nil, failed: true)
        lastSyncError = message
    }

    private func photo(id: UUID) -> ScoutPhoto? {
        for visit in visits {
            for assessment in visit.assessments {
                for observation in assessment.observations {
                    if let match = observation.photos.first(where: { $0.id == id }) { return match }
                }
            }
        }
        return nil
    }

    /// Reconcile one photograph's server path, addressed by its own id.
    private func applyPhotoStoragePath(photoID: UUID, storagePath: String?, failed: Bool) {
        for visitIndex in visits.indices {
            var visit = visits[visitIndex]
            var changed = false
            for assessmentIndex in visit.assessments.indices {
                var assessment = visit.assessments[assessmentIndex]
                for observationIndex in assessment.observations.indices {
                    var observation = assessment.observations[observationIndex]
                    guard let photoIndex = observation.photos.firstIndex(where: { $0.id == photoID })
                    else { continue }
                    if let storagePath { observation.photos[photoIndex].storagePath = storagePath }
                    observation.photos[photoIndex].uploadFailed = failed
                    assessment.observations[observationIndex] = observation
                    changed = true
                }
                visit.assessments[assessmentIndex] = assessment
            }
            guard changed else { continue }
            // Saved WITHOUT re-queuing the visit: reconciling a storage path is
            // the server's own answer coming home, not a new local edit.
            if store.saveVisit(visit) { visits = store.loadVisits() }
            return
        }
    }

    /// Consume the hard-deletion ledger before replay and after ordinary pulls.
    func pullDeletions(vineyardID: UUID) async {
        do {
            let cursor = store.deletionCursor(vineyardID: vineyardID)
            let rows = try await repository.fetchDeletions(vineyardID: vineyardID, since: cursor?.deletedAt)
                .filter { row in
                    guard row.vineyard_id == vineyardID,
                          let deletedAt = VineyardInsightsSyncRepository.parseTimestamp(row.deleted_at)
                    else { return false }
                    guard let cursor else { return true }
                    return deletedAt > cursor.deletedAt
                        || (deletedAt == cursor.deletedAt
                            && row.id.uuidString.lowercased() > cursor.ledgerID.uuidString.lowercased())
                }
                .sorted { lhs, rhs in
                    let left = VineyardInsightsSyncRepository.parseTimestamp(lhs.deleted_at) ?? .distantPast
                    let right = VineyardInsightsSyncRepository.parseTimestamp(rhs.deleted_at) ?? .distantPast
                    return left == right
                        ? lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
                        : left < right
                }
            for row in rows {
                guard let entity = VineyardInsightsStore.QueuedOperation.Entity(rawValue: row.entity_type),
                      let deletedAt = VineyardInsightsSyncRepository.parseTimestamp(row.deleted_at)
                else { continue }
                if entity == .scoutVisit {
                    visits.first { $0.id == row.entity_id && $0.vineyardID == vineyardID }?
                        .assessments.flatMap(\.observations).flatMap(\.photos)
                        .compactMap(\.localPath).forEach { photoFiles.remove(relativePath: $0) }
                    store.loadPhotoQueue().filter {
                        $0.visitID == row.entity_id && $0.vineyardID == vineyardID
                    }.forEach { photoFiles.remove(relativePath: $0.localPath) }
                }
                guard store.consumeDeletion(vineyardID: vineyardID, entity: entity, entityID: row.entity_id),
                      store.setDeletionCursor(
                        .init(deletedAt: deletedAt, ledgerID: row.id),
                        vineyardID: vineyardID
                      )
                else { throw VineyardInsightsReconciliationError.localWriteFailed }
                visits = store.loadVisits()
                notes = store.loadNotes()
                if openVisitID == row.entity_id { openVisitID = nil }
            }
        } catch {
            lastSyncError = error.localizedDescription
            logger.warning("Insights deletion pull deferred")
        }
    }

    func processPhotoCleanup(vineyardID: UUID) async {
        for item in store.loadObjectCleanup() where item.vineyardID == vineyardID {
            do {
                try await repository.removePhotoObject(path: item.storagePath)
                store.acknowledgeObjectCleanup(storagePath: item.storagePath)
            } catch {
                store.recordObjectCleanupFailure(storagePath: item.storagePath)
                lastSyncError = error.localizedDescription
            }
        }
        do {
            for item in try await repository.claimPhotoCleanup(vineyardID: vineyardID) {
                do {
                    try await repository.removePhotoObject(path: item.storage_path)
                    try await repository.acknowledgePhotoCleanup(id: item.id, leaseToken: item.lease_token)
                } catch {
                    try? await repository.failPhotoCleanup(
                        id: item.id,
                        leaseToken: item.lease_token,
                        error: error.localizedDescription
                    )
                    lastSyncError = error.localizedDescription
                }
            }
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    /// Pull the server's view so another device's or session's work appears.
    func pull(vineyardID: UUID) async {
        do {
            let since = store.lastPull(vineyardID: vineyardID)
            let noteRows = try await repository.fetchNotes(vineyardID: vineyardID, since: since)
            for row in noteRows { apply(noteRow: row) }

            let visitRows = try await repository.fetchVisits(vineyardID: vineyardID, since: since)
            if !visitRows.isEmpty {
                let assessmentRows = try await repository.fetchAssessments(
                    vineyardID: vineyardID,
                    visitIDs: visitRows.map(\.id)
                )
                let observationRows = try await repository.fetchObservations(
                    vineyardID: vineyardID,
                    assessmentIDs: assessmentRows.map(\.id)
                )
                let photoRows = try await repository.fetchPhotos(
                    vineyardID: vineyardID,
                    observationIDs: observationRows.map(\.id)
                )
                for row in visitRows {
                    apply(
                        visitRow: row,
                        assessments: assessmentRows.filter { $0.scout_visit_id == row.id },
                        observations: observationRows,
                        photos: photoRows
                    )
                }
            }
            store.setLastPull(now(), vineyardID: vineyardID)
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
            logger.warning("Insights pull deferred")
        }
    }

    /// Merge one server note, respecting local unsynced edits.
    ///
    /// A record still sitting in the outbox is NOT overwritten: the operator's
    /// unsent change is newer than anything the server can currently return,
    /// and clobbering it would silently discard their work.
    private func apply(noteRow row: VineyardInsightsSyncRepository.NoteRow) {
        let hasLocalPending = store.loadQueue().contains {
            $0.recordID == row.id && $0.entity == .vintageNote
        }
        if hasLocalPending || store.isDeleted(
            vineyardID: row.vineyard_id,
            entity: .vintageNote,
            entityID: row.id
        ) { return }

        guard let noteDate = VineyardInsightsSyncRepository.parseDay(row.note_date) else { return }
        let deletedAt = VineyardInsightsSyncRepository.parseTimestamp(row.deleted_at)
        let createdAt = VineyardInsightsSyncRepository.parseTimestamp(row.created_at) ?? noteDate
        let updatedAt = VineyardInsightsSyncRepository.parseTimestamp(row.updated_at) ?? createdAt

        let note = VintageNote(
            id: row.id,
            vineyardID: row.vineyard_id,
            noteDate: noteDate,
            // The server's vintage, which is authoritative.
            vintageYear: row.vintage_year,
            noteTypeID: row.note_type_id?.uuidString,
            noteTypeLabelSnapshot: row.note_type_label,
            notes: row.notes,
            observedByUserID: row.observed_by_user_id,
            observerNameSnapshot: row.observer_name_snapshot,
            createdAt: createdAt,
            updatedAt: updatedAt,
            clientUpdatedAt: VineyardInsightsSyncRepository.parseTimestamp(row.client_updated_at) ?? updatedAt,
            syncVersion: row.sync_version ?? 0,
            deletedAt: deletedAt
        )
        if store.saveNote(note) { notes = store.loadNotes() }
    }

    private func apply(
        visitRow row: VineyardInsightsSyncRepository.VisitRow,
        assessments: [VineyardInsightsSyncRepository.AssessmentRow],
        observations: [VineyardInsightsSyncRepository.ObservationRow],
        photos: [VineyardInsightsSyncRepository.PhotoRow]
    ) {
        let hasLocalPending = store.loadQueue().contains {
            $0.recordID == row.id && $0.entity == .scoutVisit
        }
        if hasLocalPending || store.isDeleted(
            vineyardID: row.vineyard_id,
            entity: .scoutVisit,
            entityID: row.id
        ) { return }

        // A tombstoned visit is removed locally rather than shown as empty.
        if VineyardInsightsSyncRepository.parseTimestamp(row.deleted_at) != nil {
            if store.deleteVisit(id: row.id) {
                visits = store.loadVisits()
                if openVisitID == row.id { openVisitID = nil }
            }
            return
        }

        guard let scoutDate = VineyardInsightsSyncRepository.parseDay(row.scout_date) else { return }

        let builtAssessments: [ScoutBlockAssessment] = assessments
            .filter { VineyardInsightsSyncRepository.parseTimestamp($0.deleted_at) == nil }
            .map { assessmentRow in
                let rows = observations.filter {
                    $0.assessment_id == assessmentRow.id
                        && VineyardInsightsSyncRepository.parseTimestamp($0.deleted_at) == nil
                }
                let built: [ScoutObservation] = rows.compactMap { observationRow in
                    guard let item = ScoutItem.byCode(observationRow.item_kind) else { return nil }
                    let ownPhotos: [ScoutPhoto] = photos
                        .filter {
                            $0.observation_id == observationRow.id
                                && VineyardInsightsSyncRepository.parseTimestamp($0.deleted_at) == nil
                        }
                        .compactMap { photoRow in
                            let capturedAt = VineyardInsightsSyncRepository
                                .parseTimestamp(photoRow.captured_at) ?? scoutDate
                            // Local bytes are kept when this device already has
                            // them, so a pulled row does not blank a preview.
                            let localPath: String? = photoFiles.exists(
                                atRelativePath: ScoutPhotoFileStore.relativePath(
                                    vineyardID: photoRow.vineyard_id,
                                    observationID: photoRow.observation_id,
                                    photoID: photoRow.id
                                )
                            )
                                ? ScoutPhotoFileStore.relativePath(
                                    vineyardID: photoRow.vineyard_id,
                                    observationID: photoRow.observation_id,
                                    photoID: photoRow.id
                                )
                                : nil
                            if photoRow.location_status == PhotoLocationStatus.gpsConfirmed.code,
                               let latitude = photoRow.latitude,
                               let longitude = photoRow.longitude {
                                return ScoutPhoto.gpsConfirmed(
                                    observationID: photoRow.observation_id,
                                    localPath: localPath,
                                    capturedAt: capturedAt,
                                    capturedByUserID: photoRow.captured_by,
                                    latitude: latitude,
                                    longitude: longitude,
                                    accuracyMetres: photoRow.horizontal_accuracy ?? 0,
                                    id: photoRow.id,
                                    storagePath: photoRow.storage_path
                                )
                            }
                            return ScoutPhoto.blockOnly(
                                observationID: photoRow.observation_id,
                                localPath: localPath,
                                capturedAt: capturedAt,
                                capturedByUserID: photoRow.captured_by,
                                id: photoRow.id,
                                storagePath: photoRow.storage_path
                            )
                        }
                    return ScoutObservation(
                        id: observationRow.id,
                        assessmentID: assessmentRow.id,
                        item: item,
                        valueCode: observationRow.value_code,
                        valueLabel: observationRow.value_label,
                        notes: observationRow.notes,
                        photos: ownPhotos,
                        linkedPinID: observationRow.linked_pin_id,
                        linkedGrowthStageRecordID: observationRow.linked_growth_stage_record_id
                    )
                }
                // Items absent server-side are re-created as defaulted rows so
                // the form still shows every question.
                let present = Set(built.map(\.item))
                let filled = built + ScoutItem.allCases
                    .filter { !present.contains($0) }
                    .map { ScoutObservation.empty(assessmentID: assessmentRow.id, item: $0) }
                return ScoutBlockAssessment(
                    id: assessmentRow.id,
                    visitID: assessmentRow.scout_visit_id,
                    vineyardID: assessmentRow.vineyard_id,
                    paddockID: assessmentRow.paddock_id,
                    status: ScoutAssessmentStatus(rawValue: assessmentRow.status) ?? .inProgress,
                    observations: filled
                )
            }

        let visit = ScoutVisit(
            id: row.id,
            vineyardID: row.vineyard_id,
            // Server-resolved vintage wins.
            vintageYear: row.vintage_year,
            scoutDate: scoutDate,
            status: ScoutStatus.byCode(row.status),
            visitSummary: row.visit_summary,
            weather: row.weather_snapshot.map {
                ScoutWeatherSnapshot(
                    observedAt: VineyardInsightsSyncRepository.parseTimestamp($0.observed_at),
                    capturedAt: VineyardInsightsSyncRepository.parseTimestamp($0.captured_at) ?? scoutDate,
                    source: $0.source,
                    temperatureCelsius: $0.temperature_c,
                    humidityPercent: $0.humidity_pct,
                    windSpeedKph: $0.wind_kph,
                    windGustKph: $0.gust_kph,
                    recentRainfallMm: $0.recent_rainfall_mm,
                    isStale: $0.is_stale,
                    isUnavailable: $0.is_unavailable
                )
            },
            scoutUserID: row.scout_user_id,
            scoutNameSnapshot: row.scout_name_snapshot,
            assessments: builtAssessments,
            clientUpdatedAt: VineyardInsightsSyncRepository.parseTimestamp(row.client_updated_at) ?? scoutDate,
            syncVersion: row.sync_version ?? 0
        )
        if store.saveVisit(visit) { visits = store.loadVisits() }
    }

    // MARK: - Session

    /// Drop every locally held preview record on sign-out.
    func clearOnSignOut() {
        store.clearForSignOut()
        photoFiles.clearForSignOut()
        visits = []
        notes = []
        openVisitID = nil
        lastWriteFailed = false
        lastSyncError = nil
        pendingPhotoCount = 0
    }
}

nonisolated enum VineyardInsightsReconciliationError: LocalizedError, Sendable {
    case localWriteFailed

    var errorDescription: String? {
        "The deletion could not be saved safely on this device."
    }
}
