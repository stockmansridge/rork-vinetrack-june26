import Foundation
import os

/// Durable local storage for Scout visits, Vintage Notes and their pending
/// sync operations.
///
/// ## Why local-first is not optional here
///
/// Scouting happens in the rows, which is exactly where there is no signal. A
/// visit that only exists once the server acknowledges it is a visit that gets
/// lost. So every capture is written to disk FIRST and queued second; the
/// network is treated as an eventual reconciliation, never as the place the
/// data lives.
///
/// ## Vineyard ownership travels with the queue
///
/// Each queued operation carries its own `vineyardID`. Replay must never
/// consult "the currently selected vineyard" — an operator who captures in
/// Block 4, drives home, switches vineyards and reconnects would otherwise file
/// their morning's work against someone else's business.
///
/// ## Sign-out
///
/// `clearForSignOut()` wipes everything. Preview data captured by one System
/// Admin must not be visible to the next person who signs in on the device.
nonisolated final class VineyardInsightsStore: @unchecked Sendable {

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.vinetrack.app", category: "vineyard-insights")

    private enum Key {
        static let visits = "vineyard_insights.scout_visits"
        static let notes = "vineyard_insights.vintage_notes"
        static let queue = "vineyard_insights.pending_operations"
        static let noteTypes = "vineyard_insights.custom_note_types"
        static let photoQueue = "vineyard_insights.pending_photos"
        static let lastPull = "vineyard_insights.last_pull"
        static let deletionCursors = "vineyard_insights.deletion_cursors"
        static let consumedDeletions = "vineyard_insights.consumed_deletions"
        static let objectCleanup = "vineyard_insights.object_cleanup"
        static let localFileCleanup = "vineyard_insights.local_file_cleanup"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Queue

    /// A queued, not-yet-synced change.
    nonisolated struct QueuedOperation: Codable, Equatable, Sendable {
        enum Entity: String, Codable, Sendable {
            case scoutVisit = "scout_visit"
            case vintageNote = "vintage_note"
        }

        enum Operation: String, Codable, Sendable {
            case upsert
            case delete
        }

        let id: UUID
        /// The record's own client UUID — the idempotency key for replay.
        let recordID: UUID
        /// Ownership captured at ENQUEUE time. Replay reads this and never the
        /// currently selected vineyard.
        let vineyardID: UUID
        let entity: Entity
        let operation: Operation
        let clientUpdatedAt: Date
        var attemptCount: Int
    }

    /// A photograph whose bytes are already on disk and whose upload is owed.
    ///
    /// Separate from `QueuedOperation` because a photo upload is two distinct
    /// server effects — bytes into the `scout-photos` bucket, then a row in
    /// `scout_observation_photos` — and the bytes may succeed while the row
    /// write fails. Keeping the entry until BOTH are done is what makes a
    /// half-finished upload retryable instead of silently lost.
    nonisolated enum PhotoUploadState: String, Codable, Sendable {
        case localSaved = "local_saved"
        case queued
        case objectUploaded = "object_uploaded"
        case rowCommitted = "row_committed"
        case completed
    }

    nonisolated struct QueuedPhoto: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        /// Ownership captured at enqueue time, never re-derived from whatever
        /// vineyard happens to be selected when connectivity returns.
        let vineyardID: UUID
        let visitID: UUID
        let observationID: UUID
        /// Relative path under the app's ScoutPhotos directory.
        let localPath: String
        /// Filled once the bytes are in the bucket but the row is still owed.
        var uploadedStoragePath: String?
        /// Optional for backward-compatible decoding of entries saved before this state existed.
        var rowCommitted: Bool?
        let capturedAt: Date
        var attemptCount: Int
        var lastError: String?

        var uploadState: PhotoUploadState {
            if rowCommitted == true { return .rowCommitted }
            if uploadedStoragePath != nil { return .objectUploaded }
            return .queued
        }
    }

    nonisolated struct DeletionCursor: Codable, Equatable, Sendable {
        let deletedAt: Date
        let ledgerID: UUID
    }

    nonisolated struct ConsumedDeletion: Codable, Equatable, Sendable {
        let vineyardID: UUID
        let entity: QueuedOperation.Entity
        let entityID: UUID
    }

    nonisolated struct ObjectCleanup: Codable, Equatable, Sendable {
        let vineyardID: UUID
        let storagePath: String
        var attemptCount: Int
    }

    nonisolated struct LocalFileCleanup: Codable, Equatable, Sendable {
        let vineyardID: UUID
        let relativePath: String
    }

    private struct StoredDeletionCursor: Codable {
        let vineyardID: UUID
        let cursor: DeletionCursor
    }

    // MARK: - Codable DTOs

    private struct StoredPhoto: Codable {
        let id: UUID
        let observationID: UUID
        let localPath: String?
        let storagePath: String?
        let capturedAt: Date
        let capturedBy: UUID?
        let latitude: Double?
        let longitude: Double?
        let accuracy: Double?
        let locationStatus: String
        /// Optional for backward compatibility with rows written before upload
        /// failure was tracked; absent decodes as "no failure recorded".
        let uploadFailed: Bool?
    }

    private struct StoredObservation: Codable {
        let id: UUID
        let assessmentID: UUID
        let itemKind: String
        let valueCode: String?
        let valueLabel: String?
        let notes: String?
        let photos: [StoredPhoto]
        let linkedPinID: UUID?
        let linkedGrowthRecordID: UUID?
    }

    private struct StoredAssessment: Codable {
        let id: UUID
        let visitID: UUID
        let vineyardID: UUID
        let paddockID: UUID
        let status: String
        let observations: [StoredObservation]
    }

    private struct StoredWeather: Codable {
        let observedAt: Date?
        let capturedAt: Date
        let source: String?
        let temperature: Double?
        let humidity: Double?
        let windSpeed: Double?
        let windGust: Double?
        let recentRainfall: Double?
        let isStale: Bool
        let isUnavailable: Bool
    }

    private struct StoredVisit: Codable {
        let id: UUID
        let vineyardID: UUID
        let vintageYear: Int
        let scoutDate: Date
        let status: String
        let visitSummary: String?
        let weather: StoredWeather?
        let scoutUserID: UUID?
        let scoutName: String?
        let assessments: [StoredAssessment]
        let clientUpdatedAt: Date
        let syncVersion: Int
    }

    private struct StoredNote: Codable {
        let id: UUID
        let vineyardID: UUID
        let noteDate: Date
        let vintageYear: Int
        let noteTypeID: String?
        let noteTypeLabel: String?
        let notes: String?
        let observedBy: UUID?
        let observerName: String?
        let createdAt: Date
        let updatedAt: Date
        let clientUpdatedAt: Date
        let syncVersion: Int
        let deletedAt: Date?
    }

    private struct StoredNoteType: Codable {
        let id: UUID?
        let code: String
        let groupCode: String
        let label: String
        let sortOrder: Int
        let isActive: Bool
        let vineyardID: UUID?
        let isSystem: Bool?
        let isPending: Bool?
    }

    // MARK: - Mapping

    private func domain(_ stored: StoredPhoto) -> ScoutPhoto {
        let status = PhotoLocationStatus.byCode(stored.locationStatus)
        // Defensive: a corrupted or older row claiming coordinates without a
        // confirmed fix is normalised DOWN to block-only rather than trusted.
        // Presenting an unverified position as measured is the one failure this
        // feature must never produce.
        if status == .gpsConfirmed,
           let latitude = stored.latitude,
           let longitude = stored.longitude {
            return ScoutPhoto.gpsConfirmed(
                observationID: stored.observationID,
                localPath: stored.localPath,
                capturedAt: stored.capturedAt,
                capturedByUserID: stored.capturedBy,
                latitude: latitude,
                longitude: longitude,
                accuracyMetres: stored.accuracy ?? 0,
                id: stored.id,
                storagePath: stored.storagePath,
                uploadFailed: stored.uploadFailed ?? false
            )
        }
        return ScoutPhoto.blockOnly(
            observationID: stored.observationID,
            localPath: stored.localPath,
            capturedAt: stored.capturedAt,
            capturedByUserID: stored.capturedBy,
            id: stored.id,
            storagePath: stored.storagePath,
            uploadFailed: stored.uploadFailed ?? false
        )
    }

    private func stored(_ photo: ScoutPhoto) -> StoredPhoto {
        StoredPhoto(
            id: photo.id,
            observationID: photo.observationID,
            localPath: photo.localPath,
            storagePath: photo.storagePath,
            capturedAt: photo.capturedAt,
            capturedBy: photo.capturedByUserID,
            latitude: photo.latitude,
            longitude: photo.longitude,
            accuracy: photo.accuracyMetres,
            locationStatus: photo.locationStatus.code,
            uploadFailed: photo.uploadFailed
        )
    }

    private func domain(_ stored: StoredVisit) -> ScoutVisit {
        ScoutVisit(
            id: stored.id,
            vineyardID: stored.vineyardID,
            vintageYear: stored.vintageYear,
            scoutDate: stored.scoutDate,
            status: ScoutStatus.byCode(stored.status),
            visitSummary: stored.visitSummary,
            weather: stored.weather.map {
                ScoutWeatherSnapshot(
                    observedAt: $0.observedAt,
                    capturedAt: $0.capturedAt,
                    source: $0.source,
                    temperatureCelsius: $0.temperature,
                    humidityPercent: $0.humidity,
                    windSpeedKph: $0.windSpeed,
                    windGustKph: $0.windGust,
                    recentRainfallMm: $0.recentRainfall,
                    isStale: $0.isStale,
                    isUnavailable: $0.isUnavailable
                )
            },
            scoutUserID: stored.scoutUserID,
            scoutNameSnapshot: stored.scoutName,
            assessments: stored.assessments.map { assessment in
                ScoutBlockAssessment(
                    id: assessment.id,
                    visitID: assessment.visitID,
                    vineyardID: assessment.vineyardID,
                    paddockID: assessment.paddockID,
                    status: ScoutAssessmentStatus(rawValue: assessment.status) ?? .inProgress,
                    observations: assessment.observations.compactMap { observation in
                        guard let item = ScoutItem.byCode(observation.itemKind) else { return nil }
                        return ScoutObservation(
                            id: observation.id,
                            assessmentID: observation.assessmentID,
                            item: item,
                            valueCode: observation.valueCode,
                            valueLabel: observation.valueLabel,
                            notes: observation.notes,
                            photos: observation.photos.map { domain($0) },
                            linkedPinID: observation.linkedPinID,
                            linkedGrowthStageRecordID: observation.linkedGrowthRecordID
                        )
                    }
                )
            },
            clientUpdatedAt: stored.clientUpdatedAt,
            syncVersion: stored.syncVersion
        )
    }

    private func stored(_ visit: ScoutVisit) -> StoredVisit {
        StoredVisit(
            id: visit.id,
            vineyardID: visit.vineyardID,
            vintageYear: visit.vintageYear,
            scoutDate: visit.scoutDate,
            status: visit.status.code,
            visitSummary: visit.visitSummary,
            weather: visit.weather.map {
                StoredWeather(
                    observedAt: $0.observedAt,
                    capturedAt: $0.capturedAt,
                    source: $0.source,
                    temperature: $0.temperatureCelsius,
                    humidity: $0.humidityPercent,
                    windSpeed: $0.windSpeedKph,
                    windGust: $0.windGustKph,
                    recentRainfall: $0.recentRainfallMm,
                    isStale: $0.isStale,
                    isUnavailable: $0.isUnavailable
                )
            },
            scoutUserID: visit.scoutUserID,
            scoutName: visit.scoutNameSnapshot,
            assessments: visit.assessments.map { assessment in
                StoredAssessment(
                    id: assessment.id,
                    visitID: assessment.visitID,
                    vineyardID: assessment.vineyardID,
                    paddockID: assessment.paddockID,
                    status: assessment.status.code,
                    observations: assessment.observations.map { observation in
                        StoredObservation(
                            id: observation.id,
                            assessmentID: observation.assessmentID,
                            itemKind: observation.item.code,
                            valueCode: observation.valueCode,
                            valueLabel: observation.valueLabel,
                            notes: observation.notes,
                            photos: observation.photos.map { stored($0) },
                            linkedPinID: observation.linkedPinID,
                            linkedGrowthRecordID: observation.linkedGrowthStageRecordID
                        )
                    }
                )
            },
            clientUpdatedAt: visit.clientUpdatedAt,
            syncVersion: visit.syncVersion
        )
    }

    private func domain(_ stored: StoredNote) -> VintageNote {
        VintageNote(
            id: stored.id,
            vineyardID: stored.vineyardID,
            noteDate: stored.noteDate,
            vintageYear: stored.vintageYear,
            noteTypeID: stored.noteTypeID,
            noteTypeLabelSnapshot: stored.noteTypeLabel,
            notes: stored.notes,
            observedByUserID: stored.observedBy,
            observerNameSnapshot: stored.observerName,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            clientUpdatedAt: stored.clientUpdatedAt,
            syncVersion: stored.syncVersion,
            deletedAt: stored.deletedAt
        )
    }

    private func stored(_ note: VintageNote) -> StoredNote {
        StoredNote(
            id: note.id,
            vineyardID: note.vineyardID,
            noteDate: note.noteDate,
            vintageYear: note.vintageYear,
            noteTypeID: note.noteTypeID,
            noteTypeLabel: note.noteTypeLabelSnapshot,
            notes: note.notes,
            observedBy: note.observedByUserID,
            observerName: note.observerNameSnapshot,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            clientUpdatedAt: note.clientUpdatedAt,
            syncVersion: note.syncVersion,
            deletedAt: note.deletedAt
        )
    }

    // MARK: - Reads

    func loadVisits() -> [ScoutVisit] {
        decode([StoredVisit].self, Key.visits)?.map { domain($0) } ?? []
    }

    func loadNotes() -> [VintageNote] {
        decode([StoredNote].self, Key.notes)?.map { domain($0) } ?? []
    }

    func loadQueue() -> [QueuedOperation] {
        decode([QueuedOperation].self, Key.queue) ?? []
    }

    func loadPhotoQueue() -> [QueuedPhoto] {
        decode([QueuedPhoto].self, Key.photoQueue) ?? []
    }

    func deletionCursor(vineyardID: UUID) -> DeletionCursor? {
        (decode([StoredDeletionCursor].self, Key.deletionCursors) ?? [])
            .first { $0.vineyardID == vineyardID }?.cursor
    }

    @discardableResult
    func setDeletionCursor(_ cursor: DeletionCursor, vineyardID: UUID) -> Bool {
        var all = decode([StoredDeletionCursor].self, Key.deletionCursors) ?? []
        all.removeAll { $0.vineyardID == vineyardID }
        all.append(StoredDeletionCursor(vineyardID: vineyardID, cursor: cursor))
        return encodeAndWrite(all, Key.deletionCursors)
    }

    func isDeleted(vineyardID: UUID, entity: QueuedOperation.Entity, entityID: UUID) -> Bool {
        (decode([ConsumedDeletion].self, Key.consumedDeletions) ?? []).contains {
            $0.vineyardID == vineyardID && $0.entity == entity && $0.entityID == entityID
        }
    }

    func loadObjectCleanup() -> [ObjectCleanup] {
        decode([ObjectCleanup].self, Key.objectCleanup) ?? []
    }

    func loadLocalFileCleanup() -> [LocalFileCleanup] {
        decode([LocalFileCleanup].self, Key.localFileCleanup) ?? []
    }

    /// Delta cursor per vineyard, so a pull asks only for what changed.
    func lastPull(vineyardID: UUID) -> Date? {
        (decode([String: Date].self, Key.lastPull) ?? [:])[vineyardID.uuidString]
    }

    @discardableResult
    func setLastPull(_ date: Date, vineyardID: UUID) -> Bool {
        var all = decode([String: Date].self, Key.lastPull) ?? [:]
        all[vineyardID.uuidString] = date
        return encodeAndWrite(all, Key.lastPull)
    }

    /// Custom types belonging to one vineyard. Never another's.
    func customNoteTypes(vineyardID: UUID) -> [VintageNoteType] {
        (decode([StoredNoteType].self, Key.noteTypes) ?? [])
            .filter { $0.isSystem == true || $0.vineyardID == vineyardID }
            .map {
                VintageNoteType(
                    databaseID: $0.id,
                    code: $0.code,
                    group: VintageNoteGroup.byCode($0.groupCode) ?? .other,
                    label: $0.label,
                    sortOrder: $0.sortOrder,
                    isCustom: !($0.isSystem ?? false),
                    isActive: $0.isActive,
                    vineyardID: $0.vineyardID,
                    isSystem: $0.isSystem ?? false
                )
            }
    }

    // MARK: - Writes

    /// Persist a visit. Returns false when the write did not reach disk, so a
    /// caller can tell the operator rather than assuming success.
    @discardableResult
    func saveVisit(_ visit: ScoutVisit) -> Bool {
        var all = decode([StoredVisit].self, Key.visits) ?? []
        all.removeAll { $0.id == visit.id }
        all.append(stored(visit))
        return encodeAndWrite(all, Key.visits)
    }

    @discardableResult
    func deleteVisit(id: UUID) -> Bool {
        var all = decode([StoredVisit].self, Key.visits) ?? []
        all.removeAll { $0.id == id }
        return encodeAndWrite(all, Key.visits)
    }

    @discardableResult
    func saveNote(_ note: VintageNote) -> Bool {
        var all = decode([StoredNote].self, Key.notes) ?? []
        all.removeAll { $0.id == note.id }
        all.append(stored(note))
        return encodeAndWrite(all, Key.notes)
    }

    @discardableResult
    func deleteNote(id: UUID) -> Bool {
        var all = decode([StoredNote].self, Key.notes) ?? []
        all.removeAll { $0.id == id }
        return encodeAndWrite(all, Key.notes)
    }

    /// Permanently reconcile one authorised deletion marker. Safe to repeat.
    @discardableResult
    func consumeDeletion(vineyardID: UUID, entity: QueuedOperation.Entity, entityID: UUID) -> Bool {
        var markers = decode([ConsumedDeletion].self, Key.consumedDeletions) ?? []
        let marker = ConsumedDeletion(vineyardID: vineyardID, entity: entity, entityID: entityID)
        if !markers.contains(marker) { markers.append(marker) }
        guard encodeAndWrite(markers, Key.consumedDeletions) else { return false }

        if entity == .scoutVisit {
            let cleanup = loadPhotoQueue()
                .filter { $0.vineyardID == vineyardID && $0.visitID == entityID }
                .compactMap { entry in
                    entry.uploadedStoragePath.map {
                        ObjectCleanup(vineyardID: vineyardID, storagePath: $0, attemptCount: 0)
                    }
                }
            var cleanupQueue = loadObjectCleanup()
            for item in cleanup where !cleanupQueue.contains(where: { $0.storagePath == item.storagePath }) {
                cleanupQueue.append(item)
            }
            guard encodeAndWrite(cleanupQueue, Key.objectCleanup) else { return false }
            if loadVisits().contains(where: { $0.id == entityID && $0.vineyardID == vineyardID }),
               !deleteVisit(id: entityID) { return false }
            let remainingPhotos = loadPhotoQueue().filter {
                !($0.vineyardID == vineyardID && $0.visitID == entityID)
            }
            guard encodeAndWrite(remainingPhotos, Key.photoQueue) else { return false }
        } else {
            if loadNotes().contains(where: { $0.id == entityID && $0.vineyardID == vineyardID }),
               !deleteNote(id: entityID) { return false }
        }
        let remaining = loadQueue().filter {
            !($0.vineyardID == vineyardID && $0.entity == entity && $0.recordID == entityID)
        }
        return encodeAndWrite(remaining, Key.queue)
    }

    @discardableResult
    func queueLocalFileCleanup(vineyardID: UUID, relativePaths: [String]) -> Bool {
        let additions = relativePaths.map { LocalFileCleanup(vineyardID: vineyardID, relativePath: $0) }
        let all = (loadLocalFileCleanup() + additions).reduce(into: [LocalFileCleanup]()) { result, item in
            if !result.contains(where: { $0.relativePath == item.relativePath }) { result.append(item) }
        }
        return encodeAndWrite(all, Key.localFileCleanup)
    }

    @discardableResult
    func acknowledgeLocalFileCleanup(relativePath: String) -> Bool {
        encodeAndWrite(loadLocalFileCleanup().filter { $0.relativePath != relativePath }, Key.localFileCleanup)
    }

    @discardableResult
    func queueObjectCleanup(vineyardID: UUID, storagePath: String) -> Bool {
        var all = loadObjectCleanup()
        if !all.contains(where: { $0.storagePath == storagePath }) {
            all.append(ObjectCleanup(vineyardID: vineyardID, storagePath: storagePath, attemptCount: 0))
        }
        return encodeAndWrite(all, Key.objectCleanup)
    }

    @discardableResult
    func acknowledgeObjectCleanup(storagePath: String) -> Bool {
        encodeAndWrite(loadObjectCleanup().filter { $0.storagePath != storagePath }, Key.objectCleanup)
    }

    @discardableResult
    func recordObjectCleanupFailure(storagePath: String) -> Bool {
        var all = loadObjectCleanup()
        guard let index = all.firstIndex(where: { $0.storagePath == storagePath }) else { return false }
        all[index].attemptCount += 1
        return encodeAndWrite(all, Key.objectCleanup)
    }

    @discardableResult
    func saveCustomNoteType(vineyardID: UUID, type: VintageNoteType) -> Bool {
        var all = decode([StoredNoteType].self, Key.noteTypes) ?? []
        all.removeAll { $0.vineyardID == vineyardID && $0.code == type.code }
        all.append(
            StoredNoteType(
                id: type.databaseID,
                code: type.code,
                groupCode: type.group.code,
                label: type.label,
                sortOrder: type.sortOrder,
                isActive: type.isActive,
                vineyardID: vineyardID,
                isSystem: false,
                isPending: true
            )
        )
        return encodeAndWrite(all, Key.noteTypes)
    }

    func pendingNoteTypes(vineyardID: UUID) -> [VintageNoteType] {
        let rows = decode([StoredNoteType].self, Key.noteTypes) ?? []
        return rows.filter { $0.vineyardID == vineyardID && $0.isPending == true }.map {
            VintageNoteType(databaseID: $0.id, code: $0.code,
                group: VintageNoteGroup.byCode($0.groupCode) ?? .other, label: $0.label,
                sortOrder: $0.sortOrder, isCustom: true, isActive: $0.isActive,
                vineyardID: vineyardID)
        }
    }

    @discardableResult
    func reconcileNoteTypes(_ types: [VintageNoteType], vineyardID: UUID) -> Bool {
        var all = decode([StoredNoteType].self, Key.noteTypes) ?? []
        let pending = all.filter { $0.vineyardID == vineyardID && $0.isPending == true }
        all.removeAll { $0.isSystem == true || $0.vineyardID == vineyardID }
        all += types.map { type in
            StoredNoteType(id: type.databaseID, code: type.code, groupCode: type.group.code,
                label: type.label, sortOrder: type.sortOrder, isActive: type.isActive,
                vineyardID: type.vineyardID, isSystem: type.isSystem, isPending: false)
        }
        for row in pending where !all.contains(where: { $0.id == row.id }) { all.append(row) }
        guard encodeAndWrite(all, Key.noteTypes) else { return false }
        let byCode = Dictionary(uniqueKeysWithValues: types.compactMap { type in
            type.databaseID.map { (type.code, $0.uuidString) }
        })
        var notes = loadNotes()
        var changed = false
        for index in notes.indices where UUID(uuidString: notes[index].noteTypeID ?? "") == nil {
            if let legacy = notes[index].noteTypeID, let resolved = byCode[legacy] {
                notes[index].noteTypeID = resolved
                changed = true
            }
        }
        return !changed || encodeAndWrite(notes.map { stored($0) }, Key.notes)
    }

    @discardableResult
    func markNoteTypeSynced(_ id: UUID) -> Bool {
        var all = decode([StoredNoteType].self, Key.noteTypes) ?? []
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        let row = all[index]
        all[index] = StoredNoteType(id: row.id, code: row.code, groupCode: row.groupCode,
            label: row.label, sortOrder: row.sortOrder, isActive: row.isActive,
            vineyardID: row.vineyardID, isSystem: row.isSystem, isPending: false)
        return encodeAndWrite(all, Key.noteTypes)
    }

    /// Queue an operation for replay, collapsing any earlier pending entry for
    /// the same record.
    ///
    /// Collapsing is what makes replay idempotent in practice: editing a note
    /// five times offline must produce one upsert carrying the latest state,
    /// not five that race each other into a different final answer. A delete
    /// always supersedes a pending upsert for the same record.
    @discardableResult
    func enqueue(
        recordID: UUID,
        vineyardID: UUID,
        entity: QueuedOperation.Entity,
        operation: QueuedOperation.Operation,
        clientUpdatedAt: Date,
        queueID: UUID = UUID()
    ) -> Bool {
        var all = loadQueue()
        all.removeAll { $0.recordID == recordID && $0.entity == entity }
        all.append(
            QueuedOperation(
                id: queueID,
                recordID: recordID,
                vineyardID: vineyardID,
                entity: entity,
                operation: operation,
                clientUpdatedAt: clientUpdatedAt,
                attemptCount: 0
            )
        )
        return encodeAndWrite(all, Key.queue)
    }

    /// Remove a queue entry after the server confirmed it.
    @discardableResult
    func dequeue(queueID: UUID) -> Bool {
        var all = loadQueue()
        all.removeAll { $0.id == queueID }
        return encodeAndWrite(all, Key.queue)
    }

    /// Queue a photograph whose bytes are ALREADY on disk.
    ///
    /// Keyed by the photo's own id so repeated capture of several photographs
    /// for one item produces several independent entries — photographs must
    /// never collapse into one another the way repeated edits of a single
    /// record legitimately do.
    @discardableResult
    func enqueuePhoto(_ photo: QueuedPhoto) -> Bool {
        var all = loadPhotoQueue()
        all.removeAll { $0.id == photo.id }
        all.append(photo)
        return encodeAndWrite(all, Key.photoQueue)
    }

    /// Record that the bytes landed but the row write is still owed.
    @discardableResult
    func markPhotoUploaded(photoID: UUID, storagePath: String) -> Bool {
        var all = loadPhotoQueue()
        guard let index = all.firstIndex(where: { $0.id == photoID }) else { return false }
        all[index].uploadedStoragePath = storagePath
        all[index].lastError = nil
        return encodeAndWrite(all, Key.photoQueue)
    }

    @discardableResult
    func markPhotoRowCommitted(photoID: UUID) -> Bool {
        var all = loadPhotoQueue()
        guard let index = all.firstIndex(where: { $0.id == photoID }) else { return false }
        all[index].rowCommitted = true
        all[index].lastError = nil
        return encodeAndWrite(all, Key.photoQueue)
    }

    @discardableResult
    func recordPhotoFailure(photoID: UUID, message: String) -> Bool {
        var all = loadPhotoQueue()
        guard let index = all.firstIndex(where: { $0.id == photoID }) else { return false }
        all[index].attemptCount += 1
        all[index].lastError = message
        return encodeAndWrite(all, Key.photoQueue)
    }

    /// Remove a photo entry once BOTH the bytes and the row are stored, or when
    /// the operator deleted the photograph before it ever uploaded.
    @discardableResult
    func dequeuePhoto(photoID: UUID) -> Bool {
        var all = loadPhotoQueue()
        all.removeAll { $0.id == photoID }
        return encodeAndWrite(all, Key.photoQueue)
    }

    /// Wipe every locally held preview record.
    ///
    /// Called on sign-out: this is unreleased System Admin data and the next
    /// person to sign in on this device may be someone else entirely.
    func clearForSignOut() {
        defaults.removeObject(forKey: Key.visits)
        defaults.removeObject(forKey: Key.notes)
        defaults.removeObject(forKey: Key.queue)
        defaults.removeObject(forKey: Key.noteTypes)
        defaults.removeObject(forKey: Key.photoQueue)
        defaults.removeObject(forKey: Key.lastPull)
        defaults.removeObject(forKey: Key.deletionCursors)
        defaults.removeObject(forKey: Key.consumedDeletions)
        defaults.removeObject(forKey: Key.objectCleanup)
        defaults.removeObject(forKey: Key.localFileCleanup)
    }

    // MARK: - Plumbing

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.warning("Unreadable \(key, privacy: .public)")
            return nil
        }
    }

    /// Encode first, write second.
    ///
    /// A serialisation failure must never reach storage, and must certainly
    /// never be allowed to clear the key — that turns a failed save into a
    /// deletion of everything already captured.
    private func encodeAndWrite<T: Encodable>(_ value: T, _ key: String) -> Bool {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            logger.warning("Encoding \(key, privacy: .public) failed")
            return false
        }
        defaults.set(data, forKey: key)
        return true
    }
}
