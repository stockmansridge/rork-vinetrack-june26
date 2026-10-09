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
    let measuredAt: Date

    init(latitude: Double, longitude: Double, accuracyMetres: Double, measuredAt: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMetres = accuracyMetres
        self.measuredAt = measuredAt
    }
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
    private var failedVisitDrafts: [UUID: ScoutVisit] = [:]
    private(set) var notes: [VintageNote] = []
    private(set) var openVisitID: UUID?

    /// Non-fatal sync state, surfaced so a stuck queue is visible rather than
    /// silently pending forever.
    private(set) var isSyncing = false
    private(set) var lastSyncError: String? {
        didSet { if lastSyncError != nil { syncErrorRevision += 1 } }
    }
    private var syncErrorRevision: Int = 0
    private var lastGraphPull: [UUID: Date] = [:]
    private var lastCataloguePull: [UUID: Date] = [:]
    private var requestedFullPulls: Set<UUID> = []
    private(set) var pendingPhotoCount = 0
    private(set) var noteTypesByVineyard: [UUID: [VintageNoteType]] = [:]

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
    private var scoutDeletionAccess: (UUID) -> Bool = { _ in false }
    private var vineyardTimeZone: (UUID) -> TimeZone = { _ in .current }

    func configureCalendarTimeZone(_ resolve: @escaping (UUID) -> TimeZone) { vineyardTimeZone = resolve }

    func calendar(vineyardID: UUID) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = vineyardTimeZone(vineyardID)
        return calendar
    }

    func scoutDay(_ visit: ScoutVisit) -> String {
        // Old caches have no snapshot: retain their previous outgoing day, not a historical rewrite.
        visit.scoutDateOnly ?? VineyardInsightsSyncRepository.day(visit.scoutDate)
    }

    func noteDay(_ note: VintageNote) -> String {
        note.noteDateOnly ?? VineyardInsightsSyncRepository.day(note.noteDate)
    }

    /// Installed by the app shell; evaluates current scoped membership, not a saved admin flag.
    func configureScoutDeletionAccess(_ access: @escaping (UUID) -> Bool) {
        scoutDeletionAccess = access
    }

    func canDeleteVisit(vineyardID: UUID) -> Bool { scoutDeletionAccess(vineyardID) }

    func deletionPending(visitID: UUID) -> Bool {
        store.loadQueue().contains { $0.entity == .scoutVisit && $0.recordID == visitID && $0.operation == .delete }
    }
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
        _ = store.repairMissingObligations()
        self.reloadVisits()
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
                seasonStartDay: seasonStartDay,
                calendar: calendar(vineyardID: vineyardID)
            ),
            scoutDate: date,
            scoutUserID: scoutUserID,
            scoutNameSnapshot: scoutName,
            clientUpdatedAt: now(),
            scoutDateOnly: VineyardInsightsSyncRepository.day(date, timeZone: vineyardTimeZone(vineyardID))
        )
        if persist(visit) { openVisitID = visit.id }
        return visit
    }

    /// A new UUID is allocated for every stop, including repeat visits to the same block.
    func beginStop(visitID: UUID, paddockID: UUID, observerID: UUID?, observerName: String?, fix: ScoutPhotoFix?) -> UUID? {
        guard var visit = visit(visitID), visit.isEditable, !deletionPending(visitID: visitID) else { return nil }
        var stop = ScoutBlockAssessment.create(visitID: visitID, vineyardID: visit.vineyardID, paddockID: paddockID)
        var context = ScoutStopContext(captured_at: VineyardInsightsSyncRepository.timestamp(now()),
            observer_id: observerID?.uuidString, observer_name: observerName, is_draft: true,
            latitude: fix?.latitude, longitude: fix?.longitude, accuracy_metres: fix?.accuracyMetres,
            location_measured_at: fix.map { VineyardInsightsSyncRepository.timestamp($0.measuredAt) })
        context.setWeather(.unavailable(capturedAt: now(), source: "Configured vineyard weather source"))
        stop.stopContext = context
        visit.assessments.append(stop)
        _ = persist(visit)
        // Keep the same stop in the mounted editor even if the local obligation needs Retry.
        Task { await captureStopWeather(visitID: visitID, stopID: stop.id) }
        return stop.id
    }

    /// Reassign only new stops without canonical links; GPS/photos stay unchanged.
    @discardableResult
    func correctStopBlock(visitID: UUID, stopID: UUID, paddockID: UUID) -> Bool {
        guard var visit = visit(visitID), visit.isEditable, !deletionPending(visitID: visitID),
              var stop = visit.assessments.first(where: { $0.id == stopID }), stop.stopContext != nil,
              !stop.observations.contains(where: { $0.linkedPinID != nil || $0.linkedGrowthStageRecordID != nil }) else { return false }
        stop.paddockID = paddockID; stop.stopContext?.is_draft = true
        visit.setAssessment(stop)
        return persist(visit)
    }

    @discardableResult
    func discardEmptyStop(visitID: UUID, stopID: UUID) -> Bool {
        guard var visit = visit(visitID), visit.isEditable,
              let stop = visit.assessments.first(where: { $0.id == stopID }), stop.recordedObservations.isEmpty else { return false }
        visit.removedAssessments.append(.init(id: stop.id, paddockID: stop.paddockID, removedAt: now(), status: stop.status.code))
        visit.assessments.removeAll { $0.id == stopID }
        return persist(visit)
    }

    @discardableResult
    func saveObservationDraft(visitID: UUID) -> Bool {
        guard let current = visit(visitID), current.isEditable else { return !lastWriteFailed }
        return persist(current) && record(store.repairMissingObligations())
    }

    @discardableResult
    func saveStop(visitID: UUID, stopID: UUID) -> Bool {
        guard var visit = visit(visitID), visit.isEditable, !deletionPending(visitID: visitID),
              var stop = visit.assessments.first(where: { $0.id == stopID }), !stop.recordedObservations.isEmpty else { return false }
        stop.stopContext?.is_draft = false
        stop.status = .complete
        visit.setAssessment(stop)
        guard persist(visit), store.repairMissingObligations() else { return record(false) }
        return record(true)
    }

    @discardableResult
    func setStopLocation(visitID: UUID, stopID: UUID, fix: ScoutPhotoFix) -> Bool {
        guard var visit = visit(visitID), visit.isEditable,
              var stop = visit.assessments.first(where: { $0.id == stopID }), var context = stop.stopContext else { return false }
        context.latitude = fix.latitude; context.longitude = fix.longitude
        context.accuracy_metres = fix.accuracyMetres
        context.location_measured_at = VineyardInsightsSyncRepository.timestamp(fix.measuredAt)
        stop.stopContext = context; visit.setAssessment(stop)
        return persist(visit)
    }

    func captureStopWeather(visitID: UUID, stopID: UUID) async {
        guard let visit = visit(visitID), let original = visit.assessments.first(where: { $0.id == stopID })?.stopContext else { return }
        let capturedAt = original.capturedAt ?? now()
        var weather = ScoutWeatherSnapshot.unavailable(capturedAt: capturedAt, source: "Configured vineyard weather source")
        if let snapshot = try? await WeatherCurrentService().fetchCachedCurrent(vineyardId: visit.vineyardID), snapshot.status == "ok" {
            weather = .init(observedAt: snapshot.observedAt, capturedAt: capturedAt,
                source: snapshot.stationName.map { "\(snapshot.source) — \($0)" } ?? snapshot.source,
                temperatureCelsius: snapshot.temperatureC, humidityPercent: snapshot.humidityPct,
                windSpeedKph: snapshot.windSpeedKmh, windGustKph: nil, recentRainfallMm: snapshot.rainTodayMm,
                isStale: snapshot.isStale)
        }
        guard var current = self.visit(visitID), current.isEditable, !deletionPending(visitID: visitID),
              var stop = current.assessments.first(where: { $0.id == stopID }),
              stop.stopContext?.captured_at == original.captured_at else { return }
        // Completion must not be followed by a late weather mutation. Only this stop changes.
        stop.stopContext?.setWeather(weather); current.setAssessment(stop); _ = persist(current)
    }

    func toggleBlock(visitID: UUID, paddockID: UUID) {
        guard var visit = visit(visitID), visit.isEditable else { return }
        if let existing = visit.assessment(paddockID: paddockID) {
            // Removing a block that already holds observations would discard
            // field work, so only an untouched block may be removed by a toggle.
            guard existing.recordedObservations.isEmpty else { return }
            visit.removeBlock(paddockID: paddockID, at: now())
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
        guard var visit = visit(visitID), visit.isEditable else { return }
        visit.weather = weather
        persist(visit)
    }

    /// Capture the configured vineyard weather without blocking local Scout saving.
    func captureWeather(visitID: UUID) async {
        guard let current = visit(visitID), current.isEditable else { return }
        let capturedAt = now()
        guard scoutDay(current) == VineyardInsightsSyncRepository.day(capturedAt, timeZone: vineyardTimeZone(current.vineyardID)) else {
            if current.weather == nil {
                setWeather(visitID: visitID, weather: .unavailable(
                    capturedAt: capturedAt,
                    source: "Current weather not used for an older Scout visit"
                ))
            }
            return
        }
        do {
            guard let snapshot = try await WeatherCurrentService().fetchCachedCurrent(vineyardId: current.vineyardID),
                  snapshot.status == "ok" else {
                setWeather(visitID: visitID, weather: .unavailable(capturedAt: capturedAt, source: "Configured vineyard weather source"))
                return
            }
            setWeather(visitID: visitID, weather: ScoutWeatherSnapshot(
                observedAt: snapshot.observedAt,
                capturedAt: capturedAt,
                source: snapshot.stationName.map { "\(snapshot.source) — \($0)" } ?? snapshot.source,
                temperatureCelsius: snapshot.temperatureC,
                humidityPercent: snapshot.humidityPct,
                windSpeedKph: snapshot.windSpeedKmh,
                windGustKph: nil,
                recentRainfallMm: snapshot.rainTodayMm,
                isStale: snapshot.isStale,
                isUnavailable: false
            ))
        } catch {
            setWeather(visitID: visitID, weather: .unavailable(capturedAt: capturedAt, source: "Configured vineyard weather source"))
        }
    }

    /// Local-only coverage preflight. Other devices' pending evidence cannot be known here.
    func hasPendingReportEvidence(vineyardID: UUID) -> Bool {
        store.loadQueue().contains { $0.vineyardID == vineyardID }
            || store.loadPhotoQueue().contains { $0.vineyardID == vineyardID }
            || store.pendingNoteTypeVineyards().contains(vineyardID)
            || visits.contains { $0.vineyardID == vineyardID && store.isSyncOwed(visitID: $0.id) }
            || failedVisitDrafts.values.contains { $0.vineyardID == vineyardID }
    }

    func syncStatus(for visit: ScoutVisit) -> String {
        let isQueued = store.loadQueue().contains { $0.entity == .scoutVisit && $0.recordID == visit.id }
        let hasQueuedPhoto = store.loadPhotoQueue().contains { $0.visitID == visit.id }
        let hasUnacknowledgedPhoto = visit.assessments.flatMap(\.observations).flatMap(\.photos).contains {
            $0.storagePath == nil || $0.uploadFailed
        }
        let failed = store.loadQueue().first {
            $0.entity == .scoutVisit && $0.recordID == visit.id && $0.attemptCount > 0
        }
        if deletionPending(visitID: visit.id) {
            if let failed { return "Deletion failed — local Scout retained: \(failed.lastError ?? "Retry required")" }
            return "Deletion pending — local Scout retained until confirmed"
        }
        if let failed { return "Sync failed: \(failed.lastError ?? "Retry required")" }
        if store.isSyncOwed(visitID: visit.id) || isQueued || hasQueuedPhoto || hasUnacknowledgedPhoto {
            return "Sync pending"
        }
        return visit.syncVersion > 0 ? "Synced" : "Saved on this device"
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

    @discardableResult
    func setObservationLocation(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        fix: ScoutPhotoFix?
    ) -> Bool {
        guard let fix,
              var visit = visit(visitID),
              visit.isEditable,
              var assessment = visit.assessments.first(where: { $0.id == assessmentID }) else { return false }
        let previousVisit = visit
        let previousSyncOwed = store.isSyncOwed(visitID: visitID)
        var observation = assessment.observation(item)
            ?? ScoutObservation.empty(assessmentID: assessmentID, item: item)
        observation.latitude = fix.latitude
        observation.longitude = fix.longitude
        observation.accuracyMetres = fix.accuracyMetres
        observation.locationCapturedAt = fix.measuredAt
        observation.locationStatus = .gpsConfirmed
        assessment.setObservation(observation)
        visit.setAssessment(assessment)
        guard persist(visit) else {
            _ = store.saveVisit(previousVisit, syncOwed: previousSyncOwed)
            reloadVisits()
            return false
        }
        return true
    }

    func retrySync(vineyardID: UUID) {
        scheduleSync(vineyardID: vineyardID)
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
        guard let visit = visit(visitID), visit.isEditable, !deletionPending(visitID: visitID) else { return nil }
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
        assessment.stopContext?.is_draft = true
        assessment.setObservation(updated)
        var nextVisit = visit
        nextVisit.setAssessment(assessment)
        guard persist(nextVisit) else { return nil }

        let photoQueued = store.enqueuePhoto(
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
        guard record(photoQueued) else { return nil }

        scheduleSync(vineyardID: visit.vineyardID)
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
        guard let visit = visit(visitID), visit.isEditable, !deletionPending(visitID: visitID) else { return false }
        guard var assessment = visit.assessments.first(where: { $0.id == assessmentID }),
              var observation = assessment.observation(item),
              let photo = observation.photos.first(where: { $0.id == photoID }) else { return false }

        let queued = store.loadPhotoQueue().first { $0.id == photoID }
        let deletedAt = now()
        store.dequeuePhoto(photoID: photoID)
        guard store.markPhotoDeletionIntent(photoID) else { return false }
        pendingPhotoCount = store.loadPhotoQueue().count

        observation.photos.removeAll { $0.id == photoID }
        assessment.stopContext?.is_draft = true
        assessment.setObservation(observation)
        var nextVisit = visit
        nextVisit.setAssessment(assessment)
        guard persist(nextVisit) else { return false }

        if let path = photo.localPath { photoFiles.remove(relativePath: path) }

        if let orphanedPath = queued?.uploadedStoragePath, queued?.rowCommitted != true {
            Task { [repository] in
                try? await repository.removePhotoObject(path: orphanedPath)
            }
        } else if photo.storagePath != nil || queued?.rowCommitted == true,
                  let revision = store.photoDeletionRevision(
                    photoID: photoID,
                    vineyardID: visit.vineyardID,
                    fallbackDate: deletedAt
                  ) {
            Task { [repository] in
                try? await repository.softDeletePhoto(revision)
            }
        }
        scheduleSync(vineyardID: visit.vineyardID)
        return true
    }

    /// Retry a failed photograph upload. The local bytes were never discarded.
    func retryPhotoUploads(vineyardID: UUID) {
        Task { await sync(vineyardID: vineyardID) }
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

    @discardableResult
    private func updateObservation(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        _ transform: (inout ScoutObservation) -> Void
    ) -> Bool {
        guard var visit = visit(visitID), visit.isEditable else { return false }
        guard var assessment = visit.assessments.first(where: { $0.id == assessmentID }) else { return false }
        var observation = assessment.observation(item)
            ?? ScoutObservation.empty(assessmentID: assessmentID, item: item)
        transform(&observation)
        assessment.stopContext?.is_draft = true
        assessment.setObservation(observation)
        visit.setAssessment(assessment)
        return persist(visit)
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
        guard var visit = visit(visitID), !deletionPending(visitID: visitID), ScoutReview.of(visit).canComplete else { return false }
        if visit.status == .completed {
            guard store.repairMissingObligations() else { return record(false) }
            let durable = store.loadQueue().contains {
                $0.entity == .scoutVisit && $0.recordID == visitID && $0.clientUpdatedAt == visit.clientUpdatedAt
            }
            if durable { scheduleSync(vineyardID: visit.vineyardID) }
            return record(durable)
        }
        let draft = visit
        visit.status = .completed
        if persist(visit), store.repairMissingObligations() { return true }
        if !store.saveVisit(draft, syncOwed: true) { failedVisitDrafts[draft.id] = draft }
        reloadVisits()
        return record(false)
    }

    func completionNeedsRetry(_ visitID: UUID) -> Bool {
        guard let visit = visit(visitID), visit.status == .completed else { return false }
        return store.isSyncOwed(visitID: visitID)
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
        guard canDeleteVisit(vineyardID: visit.vineyardID) else {
            lastSyncError = "Delete denied: only this vineyard’s Owner or Manager may delete Scouts. Local information has been retained."
            return []
        }
        let retained = ScoutGrowthStageLink.onScoutDeleted(visit)
        // Never discard the only copy or queue cleanup before server acknowledgement.
        // An existing delete retains its operation identity and failure information.
        if deletionPending(visitID: visitID) {
            scheduleSync(vineyardID: visit.vineyardID)
            return retained
        }
        if record(store.enqueue(recordID: visit.id, vineyardID: visit.vineyardID,
            entity: .scoutVisit, operation: .delete, clientUpdatedAt: now())) {
            reloadVisits()
            if openVisitID == visitID { openVisitID = nil }
            scheduleSync(vineyardID: visit.vineyardID)
        }
        return retained
    }

    @discardableResult
    private func persist(_ visit: ScoutVisit) -> Bool {
        guard !deletionPending(visitID: visit.id) else { return false }
        var stamped = visit
        let candidate = now()
        stamped.clientUpdatedAt = candidate > visit.clientUpdatedAt
            ? candidate
            : visit.clientUpdatedAt.addingTimeInterval(0.001)
        let saved = store.saveVisit(stamped)
        if saved {
            failedVisitDrafts.removeValue(forKey: stamped.id)
            reloadVisits()
            let queued = store.enqueue(
                recordID: stamped.id,
                vineyardID: stamped.vineyardID,
                entity: .scoutVisit,
                operation: .upsert,
                clientUpdatedAt: stamped.clientUpdatedAt
            )
            if queued { scheduleSync(vineyardID: stamped.vineyardID) }
            return record(queued)
        }
        // Retain failed edits in the mounted editor so Retry writes the exact content.
        failedVisitDrafts[stamped.id] = stamped
        reloadVisits()
        return record(false)
    }

    private func reloadVisits() {
        // A sync refresh cannot discard text whose disk write failed. Authoritative deletion still wins.
        failedVisitDrafts = failedVisitDrafts.filter {
            !store.isDeleted(vineyardID: $0.value.vineyardID, entity: .scoutVisit, entityID: $0.key)
        }
        let stored = store.loadVisits()
        visits = stored.map { failedVisitDrafts[$0.id] ?? $0 }
            + failedVisitDrafts.values.filter { draft in !stored.contains { $0.id == draft.id } }
    }

    // MARK: - Vintage Notes

    func noteHistory(vineyardID: UUID, vintageYear: Int?) -> [VintageNote] {
        VintageNoteRules.history(notes, vineyardID: vineyardID, vintageYear: vintageYear)
    }

    func notes(vintageYear: Int) -> [VintageNote] {
        VintageNoteRules.forVintage(notes, vintageYear: vintageYear)
    }

    func customNoteTypes(vineyardID: UUID) -> [VintageNoteType] {
        noteTypesByVineyard[vineyardID] ?? store.customNoteTypes(vineyardID: vineyardID)
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
            databaseID: UUID(),
            code: "custom_\(UUID().uuidString.prefix(8).lowercased())",
            group: group,
            label: trimmed,
            sortOrder: 1_000,
            isCustom: true,
            vineyardID: vineyardID
        )
        guard record(store.saveCustomNoteType(vineyardID: vineyardID, type: type)) else { return nil }
        noteTypesByVineyard[vineyardID] = store.customNoteTypes(vineyardID: vineyardID)
        scheduleSync(vineyardID: vineyardID)
        return type
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
                seasonStartDay: seasonStartDay,
                calendar: calendar(vineyardID: vineyardID)
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
            deletedAt: nil,
            noteDateOnly: existing.map {
                $0.noteDate == draft.date || noteDay($0) == VineyardInsightsSyncRepository.day(draft.date, timeZone: vineyardTimeZone(vineyardID))
            } == true
                ? existing.map { noteDay($0) }
                : VineyardInsightsSyncRepository.day(draft.date, timeZone: vineyardTimeZone(vineyardID))
        )
        guard record(store.saveNote(note)) else { return nil }
        notes = store.loadNotes()
        let queued = store.enqueue(
            recordID: note.id,
            vineyardID: note.vineyardID,
            entity: .vintageNote,
            operation: .upsert,
            clientUpdatedAt: note.clientUpdatedAt
        )
        guard record(queued) else { return nil }
        scheduleSync(vineyardID: note.vineyardID)
        return note
    }

    /// Hard-delete locally immediately and queue the durable server deletion.
    @discardableResult
    func deleteNote(_ noteID: UUID) -> Bool {
        guard let note = notes.first(where: { $0.id == noteID }) else { return false }
        let timestamp = now()
        let queued = store.enqueue(
            recordID: note.id,
            vineyardID: note.vineyardID,
            entity: .vintageNote,
            operation: .delete,
            clientUpdatedAt: timestamp
        )
        guard record(queued) else { return false }
        guard record(store.deleteNote(id: noteID)) else { return false }
        notes = store.loadNotes()
        scheduleSync(vineyardID: note.vineyardID)
        return true
    }

    // MARK: - Sync
    //
    // The replay worker. Local state is already durable before any of this
    // runs, so every failure path here is "try again later", never data loss.

    private var scheduledSyncs: [UUID: Task<Void, Never>] = [:]
    private let syncCoordinator = VineyardInsightsSingleFlightCoordinator()
    private var syncGeneration = 0

    private func scheduleSync(vineyardID: UUID) {
        let generation = syncGeneration
        scheduledSyncs[vineyardID]?.cancel()
        scheduledSyncs[vineyardID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self, generation == self.syncGeneration else { return }
            self.scheduledSyncs[vineyardID] = nil
            // Once the debounce expires, the full pass has an independent task;
            // cancelling a later timer cannot cancel an active network pass.
            Task {
                guard generation == self.syncGeneration else { return }
                await self.sync(vineyardID: vineyardID, refreshGraph: false)
            }
        }
    }

    /// Push queued work then pull the server's view for one vineyard.
    ///
    /// The vineyard is passed in rather than read from the current selection
    /// because queue entries carry their OWN vineyard id — see `syncQueue`.
    func sync(vineyardID: UUID, refreshGraph: Bool = true) async {
        let generation = syncGeneration
        if refreshGraph { requestedFullPulls.insert(vineyardID) }
        await syncCoordinator.request(vineyardID: vineyardID) { [weak self] in
            guard let self, generation == self.syncGeneration else { return }
            self.isSyncing = true
            let fullPullRequested = self.requestedFullPulls.remove(vineyardID) != nil
            let errorRevision = self.syncErrorRevision
            guard self.store.repairMissingObligations() else {
                self.lastSyncError = "Local changes could not be prepared safely for sync."
                return
            }
            self.visits = self.store.loadVisits()
            self.notes = self.store.loadNotes()
            self.processLocalFileCleanup(vineyardID: vineyardID)
            await self.pullDeletions(vineyardID: vineyardID, generation: generation)
            guard generation == self.syncGeneration else { return }
            await self.processPhotoCleanup(vineyardID: vineyardID)
            guard generation == self.syncGeneration else { return }
            await self.syncPhotoDeletions(vineyardID: vineyardID)
            guard generation == self.syncGeneration else { return }
            if fullPullRequested || self.lastCataloguePull[vineyardID].map({ self.now().timeIntervalSince($0) >= 300 }) != false {
                await self.pullNoteTypes(vineyardID: vineyardID, generation: generation)
            }
            guard generation == self.syncGeneration else { return }
            await self.syncNoteTypes(vineyardID: vineyardID)
            guard generation == self.syncGeneration else { return }
            await self.syncQueue(vineyardID: vineyardID)
            guard generation == self.syncGeneration else { return }
            await self.syncPhotos(vineyardID: vineyardID)
            guard generation == self.syncGeneration else { return }
            if fullPullRequested || self.lastGraphPull[vineyardID].map({ self.now().timeIntervalSince($0) >= 60 }) != false {
                await self.pull(vineyardID: vineyardID, generation: generation)
            }
            guard generation == self.syncGeneration else { return }
            await self.pullDeletions(vineyardID: vineyardID, generation: generation)
            // Only a complete successful pass with no outstanding durable effects
            // may clear a previous failure; a successful pull alone cannot.
            if self.syncErrorRevision == errorRevision && self.store.loadQueue().isEmpty
                && self.store.loadPhotoQueue().isEmpty && self.store.photoDeletionRevisions().isEmpty
                && self.store.loadObjectCleanup().isEmpty && self.store.loadLocalFileCleanup().isEmpty
                && self.store.pendingNoteTypeVineyards().isEmpty {
                self.lastSyncError = nil
            }
        }
        guard generation == syncGeneration else { return }
        isSyncing = syncCoordinator.hasRunningPass
    }

    private func pullNoteTypes(vineyardID: UUID, generation: Int? = nil) async {
        let expectedGeneration = generation ?? syncGeneration
        do {
            let rows = try await repository.fetchNoteTypes(vineyardID: vineyardID)
            guard expectedGeneration == syncGeneration else { return }
            let types = rows.compactMap { row -> VintageNoteType? in
                guard VineyardInsightsSyncRepository.parseTimestamp(row.deleted_at) == nil,
                      let group = VintageNoteGroup.byCode(row.group_code) else { return nil }
                return VintageNoteType(databaseID: row.id, code: row.code, group: group,
                    label: row.label, sortOrder: row.sort_order, isCustom: !row.is_system,
                    isActive: row.is_active, vineyardID: row.vineyard_id, isSystem: row.is_system)
            }
            guard store.reconcileNoteTypes(types, vineyardID: vineyardID) else {
                throw VineyardInsightsReconciliationError.localWriteFailed
            }
            noteTypesByVineyard[vineyardID] = store.customNoteTypes(vineyardID: vineyardID)
            try Task.checkCancellation()
            lastCataloguePull[vineyardID] = now()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    private func syncNoteTypes(vineyardID: UUID) async {
        let generation = syncGeneration
        for type in store.pendingNoteTypes(vineyardID: vineyardID) {
            guard let id = type.databaseID else { continue }
            do {
                try await repository.upsertNoteType(
                    .init(p_id: id.uuidString, p_vineyard_id: vineyardID.uuidString,
                        p_code: type.code, p_group_code: type.group.code,
                        p_label: type.label, p_sort_order: type.sortOrder,
                        p_is_active: type.isActive)
                )
                guard generation == syncGeneration else { return }
                guard store.markNoteTypeSynced(id) else { throw VineyardInsightsReconciliationError.localWriteFailed }
            } catch {
                lastSyncError = error.localizedDescription
            }
        }
    }

    /// Replay every queued record operation.
    ///
    /// Entries are grouped by the vineyard they were CAPTURED in. An operator
    /// who scouts Block 4, drives home, switches vineyards and reconnects must
    /// have that morning's work filed against the vineyard they were standing
    /// in — never against whichever one happens to be selected now.
    func syncQueue(vineyardID: UUID) async {
        let generation = syncGeneration
        for entry in store.loadQueue() where entry.vineyardID == vineyardID {
            guard generation == syncGeneration else { return }
            if entry.entity == .scoutVisit && entry.operation != .delete && deletionPending(visitID: entry.recordID) { continue }
            do {
                let acknowledgedVersion: Int?
                switch entry.entity {
                case .scoutVisit:
                    acknowledgedVersion = try await pushVisit(entry: entry)
                case .vintageNote:
                    try await pushNote(entry: entry)
                    acknowledgedVersion = nil
                }
                guard generation == syncGeneration else { return }
                guard store.dequeue(queueID: entry.id, acknowledgedSyncVersion: acknowledgedVersion) else {
                    throw VineyardInsightsReconciliationError.localWriteFailed
                }
            } catch {
                // Left queued deliberately: the local record is intact, so a
                // later attempt can still deliver it.
                lastSyncError = error.localizedDescription
                _ = store.recordFailure(queueID: entry.id, message: error.localizedDescription)
                logger.warning("Insights queue entry deferred")
            }
        }
    }

    private func pushVisit(entry: VineyardInsightsStore.QueuedOperation) async throws -> Int? {
        if entry.operation == .delete {
            let generation = syncGeneration
            try await repository.hardDeleteVisit(
                id: entry.recordID,
                vineyardID: entry.vineyardID,
                operationID: entry.id,
                at: entry.clientUpdatedAt
            )
            guard generation == syncGeneration else { throw CancellationError() }
            let localPaths = store.loadVisits().first { $0.id == entry.recordID && $0.vineyardID == entry.vineyardID }?
                .assessments.flatMap(\.observations).flatMap(\.photos).compactMap(\.localPath) ?? []
            let queued = store.loadPhotoQueue().filter { $0.visitID == entry.recordID && $0.vineyardID == entry.vineyardID }
            let orphanPaths = queued.filter { $0.rowCommitted != true }.map {
                $0.uploadedStoragePath ?? ScoutPhotoFileStore.storagePath(vineyardID: $0.vineyardID, observationID: $0.observationID, photoID: $0.id)
            }
            guard store.queueLocalFileCleanup(vineyardID: entry.vineyardID, relativePaths: Array(Set(localPaths + queued.map(\.localPath)))),
                  orphanPaths.allSatisfy({ store.queueObjectCleanup(vineyardID: entry.vineyardID, storagePath: $0) }),
                  store.consumeDeletion(vineyardID: entry.vineyardID, entity: .scoutVisit, entityID: entry.recordID)
            else { throw VineyardInsightsReconciliationError.localWriteFailed }
            processLocalFileCleanup(vineyardID: entry.vineyardID)
            reloadVisits()
            pendingPhotoCount = store.loadPhotoQueue().count
            if openVisitID == entry.recordID { openVisitID = nil }
            return nil
        }
        if store.isDeleted(vineyardID: entry.vineyardID, entity: .scoutVisit, entityID: entry.recordID) {
            store.dequeue(queueID: entry.id)
            return nil
        }
        guard let visit = store.loadVisits().first(where: { $0.id == entry.recordID }) else { return nil }
        guard visit.clientUpdatedAt == entry.clientUpdatedAt else {
            throw VineyardInsightsReconciliationError.localWriteFailed
        }
        let revisionID = entry.id.uuidString

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
            scout_date: scoutDay(visit),
            status: visit.status.code,
            visit_summary: visit.visitSummary,
            weather_snapshot: weather,
            scout_user_id: visit.scoutUserID?.uuidString,
            scout_name_snapshot: visit.scoutNameSnapshot,
            client_updated_at: VineyardInsightsSyncRepository.timestamp(entry.clientUpdatedAt),
            client_revision_id: revisionID,
            deleted_at: nil
        )

        let removals = visit.removedAssessments.filter { $0.acknowledged != true }.map {
            VineyardInsightsSyncRepository.AssessmentUpsert(id: $0.id.uuidString,
                scout_visit_id: visit.id.uuidString, vineyard_id: visit.vineyardID.uuidString,
                paddock_id: $0.paddockID.uuidString, status: $0.status,
                deleted_at: VineyardInsightsSyncRepository.timestamp($0.removedAt),
                client_updated_at: VineyardInsightsSyncRepository.timestamp(entry.clientUpdatedAt), client_revision_id: revisionID)
        }
        let assessments = removals + visit.assessments.map { assessment in
            VineyardInsightsSyncRepository.AssessmentUpsert(
                id: assessment.id.uuidString,
                scout_visit_id: visit.id.uuidString,
                vineyard_id: assessment.vineyardID.uuidString,
                paddock_id: assessment.paddockID.uuidString,
                status: assessment.status.code,
                stop_context: assessment.stopContext,
                client_updated_at: VineyardInsightsSyncRepository.timestamp(entry.clientUpdatedAt),
                client_revision_id: revisionID
            )
        }

        // Stable rows are sent even when cleared so nulls replace stale remote
        // content. Report selection still ignores hasContent=false.
        let observations = visit.assessments.flatMap { assessment in
            assessment.observations.map { observation in
                VineyardInsightsSyncRepository.ObservationUpsert(
                    id: observation.id.uuidString,
                    assessment_id: assessment.id.uuidString,
                    vineyard_id: assessment.vineyardID.uuidString,
                    item_kind: observation.item.code,
                    value_code: observation.valueCode,
                    value_label: observation.valueLabel,
                    notes: observation.notes,
                    latitude: observation.latitude,
                    longitude: observation.longitude,
                    horizontal_accuracy: observation.accuracyMetres,
                    location_captured_at: observation.locationCapturedAt.map { VineyardInsightsSyncRepository.timestamp($0) },
                    location_status: observation.locationStatus.code,
                    linked_pin_id: observation.linkedPinID?.uuidString,
                    linked_growth_record_id: observation.linkedGrowthStageRecordID?.uuidString,
                    client_updated_at: VineyardInsightsSyncRepository.timestamp(entry.clientUpdatedAt),
                    client_revision_id: revisionID
                )
            }
        }

        // Parent-first ordering is guaranteed inside pushVisit.
        let acknowledged = try await repository.pushVisit(
            visit: visitPayload,
            assessments: assessments,
            observations: observations
        )
        guard acknowledged.id == entry.recordID,
              acknowledged.client_revision_id == entry.id else {
            throw VineyardInsightsReconciliationError.localWriteFailed
        }
        return acknowledged.sync_version
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
                p_note_date: noteDay(note),
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
        guard let returned, returned.id == entry.recordID, returned.vineyard_id == entry.vineyardID else {
            throw VineyardInsightsReconciliationError.localWriteFailed
        }
        try apply(noteRow: returned)
    }

    /// Upload queued photographs, then write their metadata rows.
    ///
    /// A late completion can only ever touch ITS OWN photo id, so it cannot
    /// replace or remove a newer photograph. A photo the operator deleted has
    /// already left the queue and is skipped entirely.
    func syncPhotos(vineyardID: UUID) async {
        for entry in store.loadPhotoQueue() where entry.vineyardID == vineyardID {
            if deletionPending(visitID: entry.visitID) { continue }
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
                        client_updated_at: VineyardInsightsSyncRepository.timestamp(entry.capturedAt),
                        client_revision_id: entry.id.uuidString
                    )
                )

                guard store.markPhotoRowCommitted(photoID: entry.id) else {
                    // A deletion raced the metadata callback. Tombstone the row;
                    // never recreate the local queue entry or photograph.
                    let deletedAt = now()
                    if let revision = store.photoDeletionRevision(
                        photoID: entry.id,
                        vineyardID: entry.vineyardID,
                        fallbackDate: deletedAt
                    ) {
                        try? await repository.softDeletePhoto(revision)
                    }
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

    private func syncPhotoDeletions(vineyardID: UUID) async {
        for revision in store.photoDeletionRevisions() where revision.vineyardID == vineyardID {
            do {
                try await repository.softDeletePhoto(revision)
            } catch {
                lastSyncError = error.localizedDescription
            }
        }
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
            if store.saveVisit(visit, syncOwed: store.isSyncOwed(visitID: visit.id)) { reloadVisits() }
            return
        }
    }

    /// Consume the hard-deletion ledger before replay and after ordinary pulls.
    func pullDeletions(vineyardID: UUID, generation: Int? = nil) async {
        let expectedGeneration = generation ?? syncGeneration
        do {
            let cursor = store.deletionCursor(vineyardID: vineyardID)
            let fetchedRows = try await repository.fetchDeletions(vineyardID: vineyardID, since: cursor?.deletedAt,
                sinceISO: cursor?.serverDeletedAt, ledgerID: cursor?.serverDeletedAt == nil ? nil : cursor?.ledgerID)
            guard expectedGeneration == syncGeneration else { return }
            let rows = fetchedRows.filter { row in
                    guard row.vineyard_id == vineyardID,
                          let deletedAt = VineyardInsightsSyncRepository.parseTimestamp(row.deleted_at)
                    else { return false }
                    // Exact server tuple is filtered by the repository. Legacy
                    // Date-only cursors overlap a second and reconsume idempotently.
                    return deletedAt.timeIntervalSince1970.isFinite
                }

            for row in rows {
                guard let entity = VineyardInsightsStore.QueuedOperation.Entity(rawValue: row.entity_type),
                      let deletedAt = VineyardInsightsSyncRepository.parseTimestamp(row.deleted_at)
                else { continue }
                let localPaths: [String]
                if entity == .scoutVisit {
                    let visitPaths = visits.first { $0.id == row.entity_id && $0.vineyardID == vineyardID }?
                        .assessments.flatMap(\.observations).flatMap(\.photos).compactMap(\.localPath) ?? []
                    let queuedPaths = store.loadPhotoQueue().filter {
                        $0.visitID == row.entity_id && $0.vineyardID == vineyardID
                    }.map(\.localPath)
                    localPaths = Array(Set(visitPaths + queuedPaths))
                    guard store.queueLocalFileCleanup(vineyardID: vineyardID, relativePaths: localPaths) else {
                        throw VineyardInsightsReconciliationError.localWriteFailed
                    }
                } else {
                    localPaths = []
                }
                guard store.consumeDeletion(vineyardID: vineyardID, entity: entity, entityID: row.entity_id),
                      store.setDeletionCursor(
                        .init(deletedAt: deletedAt, ledgerID: row.id, serverDeletedAt: row.deleted_at),
                        vineyardID: vineyardID
                      )
                else { throw VineyardInsightsReconciliationError.localWriteFailed }
                processLocalFileCleanup(vineyardID: vineyardID)
                reloadVisits()
                notes = store.loadNotes()
                if openVisitID == row.entity_id { openVisitID = nil }
            }
        } catch {
            lastSyncError = error.localizedDescription
            logger.warning("Insights deletion pull deferred")
        }
    }

    private func processLocalFileCleanup(vineyardID: UUID) {
        for item in store.loadLocalFileCleanup() where item.vineyardID == vineyardID {
            photoFiles.remove(relativePath: item.relativePath)
            if !photoFiles.exists(atRelativePath: item.relativePath) {
                _ = store.acknowledgeLocalFileCleanup(relativePath: item.relativePath)
            }
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
    func pull(vineyardID: UUID, generation: Int? = nil) async {
        let expectedGeneration = generation ?? syncGeneration
        do {
            // Round 1 preview pulls the complete active graph. No client clock
            // can skip a row, and changed children are discovered even when the
            // parent visit's updated_at did not move.
            var downloadFailed = false
            let noteRows = try await repository.fetchNotes(vineyardID: vineyardID, since: nil)
            guard expectedGeneration == syncGeneration else { return }
            let visitRows = try await repository.fetchVisits(vineyardID: vineyardID, since: nil)
            guard expectedGeneration == syncGeneration else { return }
            if !visitRows.isEmpty {
                let assessmentRows = try await repository.fetchAssessments(
                    vineyardID: vineyardID,
                    visitIDs: visitRows.map(\.id)
                )
                guard expectedGeneration == syncGeneration else { return }
                let observationRows = try await repository.fetchObservations(
                    vineyardID: vineyardID,
                    assessmentIDs: assessmentRows.map(\.id)
                )
                guard expectedGeneration == syncGeneration else { return }
                let photoRows = try await repository.fetchPhotos(
                    vineyardID: vineyardID,
                    observationIDs: observationRows.map(\.id)
                )
                guard expectedGeneration == syncGeneration else { return }
                let deletionIntents = store.photoDeletionIntents()
                for photo in photoRows where
                    deletionIntents.contains(photo.id)
                        && VineyardInsightsSyncRepository.parseTimestamp(photo.deleted_at) == nil {
                    _ = store.photoDeletionRevision(
                        photoID: photo.id,
                        vineyardID: photo.vineyard_id,
                        fallbackDate: now()
                    )
                }
                var failedDownloads: Set<UUID> = []
                for photo in photoRows where VineyardInsightsSyncRepository.parseTimestamp(photo.deleted_at) == nil {
                    let relative = ScoutPhotoFileStore.relativePath(vineyardID: photo.vineyard_id,
                        observationID: photo.observation_id, photoID: photo.id)
                    guard !photoFiles.exists(atRelativePath: relative) else { continue }
                    do {
                        let data = try await repository.downloadPhotoBytes(path: photo.storage_path)
                        guard expectedGeneration == syncGeneration else { return }
                        _ = try photoFiles.write(data: data, vineyardID: photo.vineyard_id,
                            observationID: photo.observation_id, photoID: photo.id)
                    } catch {
                        failedDownloads.insert(photo.id)
                    }
                }
                guard expectedGeneration == syncGeneration else { return }
                downloadFailed = !failedDownloads.isEmpty
                if downloadFailed { lastSyncError = "Some Scout photographs could not be downloaded. Retry sync; local photographs are retained." }
                for row in visitRows {
                    try apply(
                        visitRow: row,
                        assessments: assessmentRows.filter { $0.scout_visit_id == row.id },
                        observations: observationRows,
                        photos: photoRows,
                        failedPhotoDownloads: failedDownloads
                    )
                }
            }
            guard expectedGeneration == syncGeneration else { return }
            for row in noteRows { try apply(noteRow: row) }
            try Task.checkCancellation()
            if !downloadFailed { lastGraphPull[vineyardID] = now() }
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
    private func apply(noteRow row: VineyardInsightsSyncRepository.NoteRow) throws {
        let hasLocalPending = store.loadQueue().contains {
            $0.recordID == row.id && $0.entity == .vintageNote
        }
        if hasLocalPending || store.isSyncOwed(noteID: row.id) || store.isDeleted(
            vineyardID: row.vineyard_id,
            entity: .vintageNote,
            entityID: row.id
        ) { return }

        guard let noteDate = VineyardInsightsSyncRepository.parseDay(row.note_date, timeZone: vineyardTimeZone(row.vineyard_id)) else { return }
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
            deletedAt: deletedAt,
            noteDateOnly: row.note_date
        )
        guard store.saveNote(note, syncOwed: false) else { throw VineyardInsightsReconciliationError.localWriteFailed }
        notes = store.loadNotes()
    }

    private func apply(
        visitRow row: VineyardInsightsSyncRepository.VisitRow,
        assessments: [VineyardInsightsSyncRepository.AssessmentRow],
        observations: [VineyardInsightsSyncRepository.ObservationRow],
        photos: [VineyardInsightsSyncRepository.PhotoRow],
        failedPhotoDownloads: Set<UUID> = []
    ) throws {
        let hasLocalPending = store.loadQueue().contains {
            $0.recordID == row.id && $0.entity == .scoutVisit
        }
        if hasLocalPending || store.isSyncOwed(visitID: row.id) || store.isDeleted(
            vineyardID: row.vineyard_id,
            entity: .scoutVisit,
            entityID: row.id
        ) { return }

        // A tombstoned visit is removed locally rather than shown as empty.
        if VineyardInsightsSyncRepository.parseTimestamp(row.deleted_at) != nil {
            guard store.deleteVisit(id: row.id) else { throw VineyardInsightsReconciliationError.localWriteFailed }
            reloadVisits()
            if openVisitID == row.id { openVisitID = nil }
            return
        }

        guard let scoutDate = VineyardInsightsSyncRepository.parseDay(row.scout_date, timeZone: vineyardTimeZone(row.vineyard_id)) else { return }
        let localVisit = store.loadVisits().first { $0.id == row.id }

        let removedIDs = Set(localVisit?.removedAssessments.map(\.id) ?? [])
        var builtAssessments: [ScoutBlockAssessment] = assessments
            .filter { VineyardInsightsSyncRepository.parseTimestamp($0.deleted_at) == nil && !removedIDs.contains($0.id) }
            .map { assessmentRow in
                let rows = observations.filter {
                    $0.assessment_id == assessmentRow.id
                        && VineyardInsightsSyncRepository.parseTimestamp($0.deleted_at) == nil
                }
                let built: [ScoutObservation] = rows.compactMap { observationRow in
                    guard let item = ScoutItem.byCode(observationRow.item_kind) else { return nil }
                    let deletedPhotoIDs = Set(photos.filter {
                        $0.observation_id == observationRow.id
                            && VineyardInsightsSyncRepository.parseTimestamp($0.deleted_at) != nil
                    }.map(\.id))
                    let deletionIntents = store.photoDeletionIntents()
                    _ = store.clearPhotoDeletionIntents(deletedPhotoIDs)
                    let pendingPhotoIDs = Set(store.loadPhotoQueue().map(\.id))
                    var ownPhotos: [ScoutPhoto] = photos
                        .filter {
                            $0.observation_id == observationRow.id
                                && VineyardInsightsSyncRepository.parseTimestamp($0.deleted_at) == nil
                                && !deletionIntents.contains($0.id)
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
                                    storagePath: photoRow.storage_path,
                                    uploadFailed: failedPhotoDownloads.contains(photoRow.id)
                                )
                            }
                            return ScoutPhoto.blockOnly(
                                observationID: photoRow.observation_id,
                                localPath: localPath,
                                capturedAt: capturedAt,
                                capturedByUserID: photoRow.captured_by,
                                id: photoRow.id,
                                storagePath: photoRow.storage_path,
                                uploadFailed: failedPhotoDownloads.contains(photoRow.id)
                            )
                        }
                    if let localObservation = localVisit?.assessments
                        .first(where: { $0.id == assessmentRow.id })?
                        .observations.first(where: { $0.id == observationRow.id }) {
                        let localByID = Dictionary(uniqueKeysWithValues: localObservation.photos.map { ($0.id, $0) })
                        ownPhotos = ownPhotos.map { serverPhoto in
                            guard let localPhoto = localByID[serverPhoto.id] else { return serverPhoto }
                            if pendingPhotoIDs.contains(serverPhoto.id) { return localPhoto }
                            return mergedAcknowledgedPhoto(server: serverPhoto, local: localPhoto)
                        }
                        let serverIDs = Set(ownPhotos.map(\.id))
                        ownPhotos.append(contentsOf: localObservation.photos.filter {
                            !serverIDs.contains($0.id) && !deletedPhotoIDs.contains($0.id) && !deletionIntents.contains($0.id)
                        })
                    }
                    return ScoutObservation(
                        id: observationRow.id,
                        assessmentID: assessmentRow.id,
                        item: item,
                        valueCode: observationRow.value_code,
                        valueLabel: observationRow.value_label,
                        notes: observationRow.notes,
                        photos: ownPhotos,
                        latitude: observationRow.latitude,
                        longitude: observationRow.longitude,
                        accuracyMetres: observationRow.horizontal_accuracy,
                        locationCapturedAt: VineyardInsightsSyncRepository.parseTimestamp(observationRow.location_captured_at),
                        locationStatus: PhotoLocationStatus.byCode(observationRow.location_status),
                        linkedPinID: observationRow.linked_pin_id,
                        linkedGrowthStageRecordID: observationRow.linked_growth_record_id
                    )
                }
                // Absence is not deletion and never licenses a replacement UUID.
                let knownIDs = Set(built.map(\.id))
                let deletedIDs = Set(observations.filter { $0.assessment_id == assessmentRow.id && $0.deleted_at != nil }.map(\.id))
                let retained = localVisit?.assessments.first { $0.id == assessmentRow.id }?.observations.filter {
                    !knownIDs.contains($0.id) && !deletedIDs.contains($0.id)
                } ?? []
                let filled = built + retained
                return ScoutBlockAssessment(
                    id: assessmentRow.id,
                    visitID: assessmentRow.scout_visit_id,
                    vineyardID: assessmentRow.vineyard_id,
                    paddockID: assessmentRow.paddock_id,
                    status: ScoutAssessmentStatus(rawValue: assessmentRow.status) ?? .inProgress,
                    observations: filled,
                    stopContext: assessmentRow.stop_context
                )
            }

        let activeIDs = Set(builtAssessments.map(\.id))
        let deletedAssessmentIDs = Set(assessments.filter { $0.deleted_at != nil }.map(\.id)).union(removedIDs)
        builtAssessments += localVisit?.assessments.filter {
            !activeIDs.contains($0.id) && !deletedAssessmentIDs.contains($0.id)
        } ?? []

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
            syncVersion: row.sync_version ?? 0,
            removedAssessments: localVisit?.removedAssessments ?? [],
            scoutDateOnly: row.scout_date
        )
        guard store.saveVisit(visit, syncOwed: false) else { throw VineyardInsightsReconciliationError.localWriteFailed }
        reloadVisits()
    }

    // MARK: - Session

    /// Claim retained data for the restored account. If another account owns
    /// it, invalidate that session before removing its local records.
    func activateAccount(_ accountID: UUID) {
        if let owner = store.accountOwnerID(), owner != accountID {
            clearOnSignOut()
        }
        guard store.claimAccount(accountID) else {
            visits = []
            notes = []
            noteTypesByVineyard = [:]
            openVisitID = nil
            lastWriteFailed = true
            return
        }
        _ = store.repairMissingObligations()
        reloadVisits()
        notes = store.loadNotes()
        pendingPhotoCount = store.loadPhotoQueue().count
    }

    private func mergedAcknowledgedPhoto(server: ScoutPhoto, local: ScoutPhoto) -> ScoutPhoto {
        let localPath = local.localPath.flatMap { photoFiles.exists(atRelativePath: $0) ? $0 : nil }
        if server.locationStatus == .gpsConfirmed,
           let latitude = server.latitude, let longitude = server.longitude {
            return .gpsConfirmed(observationID: server.observationID, localPath: localPath,
                capturedAt: server.capturedAt, capturedByUserID: server.capturedByUserID,
                latitude: latitude, longitude: longitude, accuracyMetres: server.accuracyMetres ?? 0,
                id: server.id, storagePath: server.storagePath, uploadFailed: server.uploadFailed)
        }
        return .blockOnly(observationID: server.observationID, localPath: localPath,
            capturedAt: server.capturedAt, capturedByUserID: server.capturedByUserID,
            id: server.id, storagePath: server.storagePath, uploadFailed: server.uploadFailed)
    }

    /// Existing foreground/reconnect hooks call the same scoped single-flight path.
    func retryPendingWork() async {
        let vineyardIDs = Set(store.loadQueue().map(\.vineyardID)
            + store.loadPhotoQueue().map(\.vineyardID)
            + store.photoDeletionRevisions().map(\.vineyardID)
            + store.loadObjectCleanup().map(\.vineyardID)
            + store.loadLocalFileCleanup().map(\.vineyardID)).union(store.pendingNoteTypeVineyards())
        for vineyardID in vineyardIDs { await sync(vineyardID: vineyardID, refreshGraph: false) }
    }

    /// Drop every locally held preview record on explicit sign-out.
    func clearOnSignOut() {
        syncGeneration += 1
        scheduledSyncs.values.forEach { $0.cancel() }
        scheduledSyncs.removeAll()
        syncCoordinator.invalidateAll()
        lastGraphPull.removeAll()
        lastCataloguePull.removeAll()
        requestedFullPulls.removeAll()
        isSyncing = false
        failedVisitDrafts.removeAll()
        store.clearForSignOut()
        photoFiles.clearForSignOut()
        visits = []
        notes = []
        noteTypesByVineyard = [:]
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
