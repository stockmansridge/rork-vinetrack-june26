import Foundation
import Observation

/// Local-first sync service for `GrowthStageRecord` entities.
///
/// Mirrors growth-stage pins into the dedicated `growth_stage_records`
/// table so the Lovable web portal can read observations from one
/// canonical source. The legacy pin-based growth observations remain
/// unchanged and continue to be written by the existing iOS flow; this
/// service simply duplicates them into the new table via `pinId`.
@Observable
@MainActor
final class GrowthStageRecordSyncService {

    enum Status: Equatable, Sendable {
        case idle
        case syncing
        case success
        case failure(String)
    }

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    /// In-memory cache of records for the selected vineyard. Persisted to
    /// disk via `PersistenceStore`.
    private(set) var records: [GrowthStageRecord] = []

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any GrowthStageRecordSyncRepositoryProtocol
    private let pinRepository: any PinSyncRepositoryProtocol
    private let photoStorage: any PinPhotoStorageProtocol
    private let metadata: GrowthStageRecordSyncMetadata
    private let persistence: PersistenceStore
    private let deletionStore: LinkedPinGrowthDeletionStore
    private let persistenceKey = "vinetrack_growth_stage_records"
    private let pendingPhotosKey = "vinetrack_pending_growth_photos_v1"
    private var pendingPhotos: [UUID: PendingGrowthPhoto] = [:]
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?
    private var isSyncInFlight: Bool = false

    /// Debounced eager-push. Multiple quick edits coalesce into a single sync.
    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncForSelectedVineyard()
        }
    }

    init(
        repository: (any GrowthStageRecordSyncRepositoryProtocol)? = nil,
        pinRepository: (any PinSyncRepositoryProtocol)? = nil,
        photoStorage: (any PinPhotoStorageProtocol)? = nil,
        metadata: GrowthStageRecordSyncMetadata? = nil,
        persistence: PersistenceStore = .shared,
        deletionStore: LinkedPinGrowthDeletionStore? = nil
    ) {
        self.repository = repository ?? SupabaseGrowthStageRecordSyncRepository()
        self.pinRepository = pinRepository ?? SupabasePinSyncRepository()
        self.photoStorage = photoStorage ?? PinPhotoStorageService()
        self.metadata = metadata ?? GrowthStageRecordSyncMetadata()
        self.persistence = persistence
        self.deletionStore = deletionStore ?? .shared
        self.records = persistence.load(key: persistenceKey) ?? []
        self.pendingPhotos = persistence.load(key: pendingPhotosKey) ?? [:]
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        records.removeAll { deletionStore.growthRecordIds.contains($0.id) }
        for pinId in deletionStore.pinIds { store.applyRemotePinDelete(pinId) }
        persist()
        guard !isConfigured else { return }
        isConfigured = true

        // Mirror new growth-stage pins into growth_stage_records.
        store.onGrowthStagePinAdded = { [weak self] pin in
            self?.mirrorGrowthStagePin(pin)
        }
        // When a growth-stage pin is soft-deleted locally, also soft-delete
        // its mirrored record so the dedicated table stays in sync.
        store.onGrowthStagePinDeleted = { [weak self] pin in
            self?.softDeleteByPin(pin) ?? false
        }
        // Backfill: mirror any growth-stage pins that already exist locally
        // (e.g. pins created before this sync service was wired up, or
        // imported from a previous app version) so they appear in the new
        // Growth Stage Records list without requiring a fresh observation.
        backfillFromExistingPins()
    }

    // MARK: - Backfill

    /// Mirror any growth-stage pins in `store.pins` that don't yet have a
    /// corresponding `GrowthStageRecord`. Idempotent and cheap to call on
    /// every configure.
    func backfillFromExistingPins() {
        guard let store else { return }
        let mirroredPinIds = Set(records.compactMap { $0.pinId })
        let candidates = store.pins.filter { pin in
            pin.mode == .growth
                && (pin.growthStageCode?.isEmpty == false)
                && !mirroredPinIds.contains(pin.id)
        }
        guard !candidates.isEmpty else { return }
        #if DEBUG
        print("[GrowthStageRecord] backfillFromExistingPins mirroring \(candidates.count) legacy pins")
        #endif
        for pin in candidates {
            mirrorPinWithoutSync(pin)
        }
        persist()
        // Push the backfilled rows once at the end.
        scheduleEagerPush()
    }

    // MARK: - Mirroring

    /// Mirror a freshly added growth-stage pin into the dedicated table.
    /// Idempotent — if a record already exists for this `pinId`, the
    /// existing row is updated in place.
    func mirrorGrowthStagePin(_ pin: VinePin) {
        #if DEBUG
        print("[GrowthStageRecord] mirrorGrowthStagePin pinId=\(pin.id) mode=\(pin.mode) code=\(pin.growthStageCode ?? "nil") vineyardId=\(pin.vineyardId) paddockId=\(pin.paddockId?.uuidString ?? "nil")")
        #endif
        guard mirrorPinWithoutSync(pin) else { return }
        persist()
        // Auto-suggest budburst date when a Budburst (EL4) growth stage
        // is recorded against a paddock with no Budburst date yet.
        if pin.growthStageCode == GrowthStage.budburstCode,
           let paddockId = pin.paddockId,
           let store,
           let pIdx = store.paddocks.firstIndex(where: { $0.id == paddockId }),
           store.paddocks[pIdx].budburstDate == nil {
            var p = store.paddocks[pIdx]
            p.budburstDate = pin.timestamp
            store.updatePaddock(p)
            #if DEBUG
            print("[GrowthStageRecord] auto-set budburstDate=\(pin.timestamp) for paddock=\(paddockId) from EL4 pin=\(pin.id)")
            #endif
        }
        // Best-effort: push (debounced) so the record is visible to other
        // devices / Lovable without waiting for the next sync cycle.
        scheduleEagerPush()
    }

    /// Core mirror logic without persistence or sync side-effects. Returns
    /// `true` if the pin was a valid growth-stage pin and was mirrored.
    @discardableResult
    private func mirrorPinWithoutSync(_ pin: VinePin) -> Bool {
        guard pin.mode == .growth, let code = pin.growthStageCode, !code.isEmpty else {
            #if DEBUG
            print("[GrowthStageRecord] mirrorPinWithoutSync SKIPPED — not a growth-stage pin")
            #endif
            return false
        }
        let stageLabel = GrowthStage.allStages.first { $0.code == code }?.description
        let variety = variety(for: pin.paddockId)
        if let idx = records.firstIndex(where: { $0.pinId == pin.id }) {
            var updated = records[idx]
            updated.stageCode = code
            updated.stageLabel = stageLabel
            updated.variety = variety ?? updated.variety
            updated.observedAt = pin.timestamp
            updated.latitude = pin.latitude
            updated.longitude = pin.longitude
            updated.rowNumber = pin.rowNumber
            updated.side = pin.side?.rawValue
            updated.notes = pin.notes
            updated.photoPaths = pin.photoPath.map { [$0] } ?? updated.photoPaths
            updated.recordedByName = pin.createdBy ?? updated.recordedByName
            updated.updatedBy = pin.createdByUserId ?? updated.updatedBy
            updated.updatedAt = Date()
            records[idx] = updated
            metadata.markDirty(updated.id, at: Date())
        } else {
            guard var mirrored = GrowthStageRecord.mirroring(
                pin,
                stageLabel: stageLabel,
                variety: variety
            ) else { return false }
            mirrored.recordedByName = pin.createdBy ?? auth?.userName
            records.append(mirrored)
            metadata.markDirty(mirrored.id, at: Date())
            #if DEBUG
            print("[GrowthStageRecord] mirrored new record id=\(mirrored.id) for pin=\(pin.id)")
            #endif
        }
        return true
    }

    private func variety(for paddockId: UUID?) -> String? {
        guard let paddockId, let store else { return nil }
        guard let paddock = store.paddocks.first(where: { $0.id == paddockId }) else { return nil }
        // Paddock.variety / grapeVariety field names vary across the codebase;
        // resolve via Mirror so we don't hard-couple to a specific schema.
        for child in Mirror(reflecting: paddock).children {
            guard let label = child.label else { continue }
            let l = label.lowercased()
            if l == "variety" || l == "grapevariety" || l == "grape" {
                if let s = child.value as? String, !s.isEmpty { return s }
                if let s = (child.value as? String?) ?? nil, !s.isEmpty { return s }
            }
        }
        return nil
    }

    func localPhotoData(recordId: UUID) -> Data? {
        pendingPhotos[recordId]?.imageData
    }

    func attachmentRevision(recordId: UUID) -> UUID? {
        pendingPhotos[recordId]?.revision
    }

    /// Retain a captured growth photo before any network work. A newer capture
    /// replaces the pending revision for this observation without affecting metadata.
    func attachPhoto(recordId: UUID, imageData: Data) throws {
        guard let record = records.first(where: { $0.id == recordId }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The growth observation is no longer available."])
        }
        let payload = PinPhotoStorage.compress(imageData) ?? imageData
        guard !payload.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The captured photo was empty."])
        }
        let revision = UUID()
        let pending = PendingGrowthPhoto(
            recordId: record.id,
            vineyardId: record.vineyardId,
            pinId: record.pinId,
            revision: revision,
            imageData: payload,
            capturedAt: Date(),
            previousRemotePath: record.photoPaths.first
        )
        var next = pendingPhotos
        next[record.id] = pending
        try persistence.saveOrThrow(next, key: pendingPhotosKey)
        let cacheKey: SharedImageCacheKey = record.pinId.map {
            .pinPhoto(vineyardId: record.vineyardId, pinId: $0)
        } ?? .growthRecordPhoto(vineyardId: record.vineyardId, recordId: record.id)
        try SharedImageCache.shared.saveImageDataOrThrow(
            payload,
            for: cacheKey,
            remotePath: nil,
            remoteUpdatedAt: nil,
            attachmentRevision: revision
        )
        pendingPhotos = next
        scheduleEagerPush()
    }

    /// Source-aware local delete. SQL 230 makes the existing growth RPC delete
    /// a linked pin and observation atomically when this queue replays.
    func deleteRecord(id: UUID) throws {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if record.pinId == nil,
           metadata.pendingUpserts[id] != nil,
           !metadata.isUnknownOutcome(id) {
            pendingPhotos.removeValue(forKey: id)
            try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
            metadata.clearDirty([id])
            records.removeAll { $0.id == id }
            persist()
            return
        }
        let pinSnapshot = record.pinId.flatMap { pinId in store?.pins.first(where: { $0.id == pinId }) }
        let target = PendingLinkedPinGrowthDeletion(
            id: record.id,
            vineyardId: record.vineyardId,
            pinId: record.pinId,
            growthRecordId: record.id,
            queuedAt: Date(),
            growthSnapshot: record,
            pinSnapshot: pinSnapshot
        )
        try deletionStore.enqueue(target)
        pendingPhotos.removeValue(forKey: id)
        try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
        records.removeAll { $0.id == id }
        metadata.markDeleted(id, at: Date())
        persist()
        if let pinId = record.pinId { store?.applyRemotePinDelete(pinId) }
        scheduleEagerPush()
    }

    private func softDeleteByPin(_ pin: VinePin) -> Bool {
        guard let record = records.first(where: { $0.pinId == pin.id }) else { return true }
        let target = PendingLinkedPinGrowthDeletion(
            id: record.id,
            vineyardId: record.vineyardId,
            pinId: pin.id,
            growthRecordId: record.id,
            queuedAt: Date(),
            growthSnapshot: record,
            pinSnapshot: pin
        )
        do {
            try deletionStore.enqueue(target)
            records.removeAll { $0.id == record.id }
            pendingPhotos.removeValue(forKey: record.id)
            try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
            metadata.markDeleted(record.id, at: Date())
            persist()
            scheduleEagerPush()
            return true
        } catch {
            errorMessage = "Couldn't retain the deletion on this device."
            return false
        }
    }

    // MARK: - Public sync entry points

    func syncForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        await sync(vineyardId: vineyardId)
    }

    func sync(vineyardId: UUID) async {
        guard !isSyncInFlight else { return }
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        isSyncInFlight = true
        defer { isSyncInFlight = false }
        syncStatus = .syncing
        errorMessage = nil
        do {
            try await pushLocal(vineyardId: vineyardId)
            try await pullRemote(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Push

    private func pushLocal(vineyardId: UUID) async throws {
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendGrowthStageRecordUpsert] = []
            var pushedIds: [UUID] = []
            var orphans: [UUID] = []
            for (recordId, ts) in dirty {
                // Reclaim queue entries with no local record — they can never
                // upload and used to sit in the queue forever.
                guard let record = byId[recordId] else { orphans.append(recordId); continue }
                payloads.append(BackendGrowthStageRecord.upsert(
                    from: record,
                    createdBy: createdBy,
                    clientUpdatedAt: ts
                ))
                pushedIds.append(recordId)
            }
            metadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            metadata.markUnknownOutcome(pushedIds)
            let result = await SyncQueuePush.run(
                entity: "Growth Stages",
                ids: pushedIds,
                payloads: payloads,
                queuedAt: dirty,
                vineyardId: vineyardId
            ) { try await repository.upsertGrowthStageRecords($0) }
            metadata.clearDirty(result.uploaded)
            metadata.clearUnknownOutcome(result.uploaded)
            SyncIssueCenter.shared.notePending(entity: "Growth Stages", count: metadata.pendingUpserts.count)
            if let error = result.firstRetryableError { throw error }
        }

        // Attachment failures must not prevent independent linked deletions.
        var independentPhotoError: Error?
        do { try await pushPendingPhotos(vineyardId: vineyardId) }
        catch { independentPhotoError = error }

        let targets = deletionStore.targets.values.filter { $0.vineyardId == vineyardId }
        var firstDeletionError: Error?
        for target in targets {
            do {
                try await deletePersistedTarget(target)
                if target.pinId != nil {
                    try deletionStore.markConfirmed(target.id)
                } else {
                    try deletionStore.remove(target.id)
                }
                if let growthId = target.growthRecordId {
                    metadata.clearDeleted([growthId])
                    metadata.clearUnknownOutcome([growthId])
                }
            } catch {
                if Self.isPermissionError(error) {
                    if let growth = target.growthSnapshot, !records.contains(where: { $0.id == growth.id }) {
                        records.append(growth)
                    }
                    if let pin = target.pinSnapshot { store?.applyRemotePinUpsert(pin) }
                    try deletionStore.remove(target.id)
                    if let growthId = target.growthRecordId {
                        metadata.clearDeleted([growthId])
                        metadata.clearUnknownOutcome([growthId])
                    }
                    persist()
                    errorMessage = "You don't have permission to delete this observation."
                } else if firstDeletionError == nil {
                    firstDeletionError = error
                }
            }
        }
        if let firstDeletionError { throw firstDeletionError }
        if let independentPhotoError { throw independentPhotoError }
    }

    func deletePersistedTarget(_ target: PendingLinkedPinGrowthDeletion) async throws {
        if let pinId = target.pinId, let growthId = target.growthRecordId {
            do {
                try await pinRepository.softDeletePin(id: pinId)
                return
            } catch where Self.isMissingRowError(error) {
                try await repository.softDeleteGrowthStageRecord(id: growthId)
                return
            }
        }
        if let growthId = target.growthRecordId {
            do { try await repository.softDeleteGrowthStageRecord(id: growthId) }
            catch where Self.isMissingRowError(error) { return }
            return
        }
        if let pinId = target.pinId {
            do { try await pinRepository.softDeletePin(id: pinId) }
            catch where Self.isMissingRowError(error) { return }
        }
    }

    nonisolated private static func isMissingRowError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("not found") || message.contains("pgrst116") ||
            message.contains("no rows") || message.contains("0 rows")
    }

    nonisolated private static func isPermissionError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("permission") || message.contains("forbidden") || message.contains("403")
    }

    func pushPendingPhotos(vineyardId: UUID) async throws {
        let candidates = pendingPhotos.values
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.capturedAt < $1.capturedAt }
        var firstFailure: Error?
        for snapshot in candidates {
            guard metadata.pendingDeletes[snapshot.recordId] == nil,
                  metadata.pendingUpserts[snapshot.recordId] == nil,
                  records.contains(where: { $0.id == snapshot.recordId }),
                  pendingPhotos[snapshot.recordId]?.revision == snapshot.revision else { continue }
            do {
                var work = snapshot
                if work.uploadedPath == nil {
                    let path: String
                    if let pinId = work.pinId {
                        path = try await photoStorage.uploadPhoto(
                            vineyardId: work.vineyardId,
                            pinId: pinId,
                            revision: work.revision,
                            imageData: work.imageData
                        )
                    } else {
                        path = try await photoStorage.uploadGrowthPhoto(
                            vineyardId: work.vineyardId,
                            recordId: work.recordId,
                            revision: work.revision,
                            imageData: work.imageData
                        )
                    }
                    guard metadata.pendingDeletes[work.recordId] == nil,
                          pendingPhotos[work.recordId]?.revision == work.revision else { continue }
                    work.uploadedPath = path
                    pendingPhotos[work.recordId] = work
                    try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
                }

                guard let path = work.uploadedPath,
                      metadata.pendingDeletes[work.recordId] == nil,
                      pendingPhotos[work.recordId]?.revision == work.revision,
                      let current = records.first(where: { $0.id == work.recordId }) else { continue }
                let photoPaths = Self.replacingOwnedPhoto(
                    in: current.photoPaths,
                    previousPath: work.previousRemotePath,
                    with: path
                )

                if let pinId = work.pinId {
                    _ = try await pinRepository.updatePhotoPath(
                        pinId: pinId,
                        vineyardId: work.vineyardId,
                        path: path
                    )
                    guard metadata.pendingDeletes[work.recordId] == nil,
                          pendingPhotos[work.recordId]?.revision == work.revision else { continue }
                }
                _ = try await repository.updatePhotoPaths(
                    recordId: work.recordId,
                    vineyardId: work.vineyardId,
                    photoPaths: photoPaths
                )
                guard metadata.pendingDeletes[work.recordId] == nil,
                      pendingPhotos[work.recordId]?.revision == work.revision,
                      let currentIndex = records.firstIndex(where: { $0.id == work.recordId }) else { continue }

                records[currentIndex].photoPaths = photoPaths
                records[currentIndex].updatedAt = Date()
                if let pinId = work.pinId,
                   var pin = store?.pins.first(where: { $0.id == pinId }) {
                    pin.photoData = work.imageData
                    pin.photoPath = path
                    store?.applyRemotePinUpsert(pin)
                }
                let cacheKey: SharedImageCacheKey = work.pinId.map {
                    .pinPhoto(vineyardId: work.vineyardId, pinId: $0)
                } ?? .growthRecordPhoto(vineyardId: work.vineyardId, recordId: work.recordId)
                try SharedImageCache.shared.saveImageDataOrThrow(
                    work.imageData,
                    for: cacheKey,
                    remotePath: path,
                    remoteUpdatedAt: nil,
                    attachmentRevision: work.revision
                )
                guard pendingPhotos[work.recordId]?.revision == work.revision else { continue }
                pendingPhotos.removeValue(forKey: work.recordId)
                try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
                persist()
            } catch AttachmentReferenceWriteError.recordDeleted {
                guard pendingPhotos[snapshot.recordId]?.revision == snapshot.revision else { continue }
                pendingPhotos.removeValue(forKey: snapshot.recordId)
                try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    nonisolated static func replacingOwnedPhoto(
        in paths: [String],
        previousPath: String?,
        with newPath: String
    ) -> [String] {
        var unrelated = paths.filter { $0 != previousPath && $0 != newPath }
        unrelated.insert(newPath, at: 0)
        return unrelated
    }

    // MARK: - Pull

    private func pullRemote(vineyardId: UUID) async throws {
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchGrowthStageRecords(vineyardId: vineyardId, since: lastSync)

        // Initial sync: push everything local if remote is empty.
        if remote.isEmpty, lastSync == nil {
            let local = records.filter { $0.vineyardId == vineyardId }
            if !local.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = local.map {
                    BackendGrowthStageRecord.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now)
                }
                try await repository.upsertGrowthStageRecords(payloads)
            }
            return
        }

        for backendRecord in remote {
            apply(backendRecord, vineyardId: vineyardId)
        }
        persist()
    }

    private func apply(_ backend: BackendGrowthStageRecord, vineyardId: UUID) {
        if metadata.pendingDeletes[backend.id] != nil || deletionStore.growthRecordIds.contains(backend.id) { return }

        if backend.deletedAt != nil {
            records.removeAll { $0.id == backend.id }
            metadata.clearDirty([backend.id])
            metadata.clearDeleted([backend.id])
            return
        }

        if let pendingAt = metadata.pendingUpserts[backend.id] {
            let remoteAt = backend.clientUpdatedAt ?? backend.updatedAt ?? .distantPast
            if pendingAt > remoteAt { return }
        }

        let mapped = backend.toGrowthStageRecord()
        if let idx = records.firstIndex(where: { $0.id == mapped.id }) {
            records[idx] = mapped
        } else {
            records.append(mapped)
        }
        metadata.clearDirty([backend.id])
    }

    // MARK: - Persistence

    private func persist() {
        persistence.save(records, key: persistenceKey)
    }
}

// MARK: - Metadata

@MainActor
final class GrowthStageRecordSyncMetadata {
    private let persistence: PersistenceStore
    private let key: String = "vinetrack_growth_stage_record_sync_metadata"
    private var state: State

    nonisolated struct State: Codable, Sendable {
        var lastSyncByVineyard: [UUID: Date] = [:]
        var pendingUpserts: [UUID: Date] = [:]
        var pendingDeletes: [UUID: Date] = [:]
        var unknownOutcomeUpserts: Set<UUID>?
    }

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
    }

    var pendingUpserts: [UUID: Date] { state.pendingUpserts }
    var pendingDeletes: [UUID: Date] { state.pendingDeletes }
    func isUnknownOutcome(_ id: UUID) -> Bool { state.unknownOutcomeUpserts?.contains(id) == true }

    func lastSync(for vineyardId: UUID) -> Date? {
        state.lastSyncByVineyard[vineyardId]
    }

    func setLastSync(_ date: Date, for vineyardId: UUID) {
        state.lastSyncByVineyard[vineyardId] = date
        save()
    }

    func markDirty(_ id: UUID, at date: Date) {
        state.pendingUpserts[id] = date
        state.unknownOutcomeUpserts?.remove(id)
        save()
    }

    func markDeleted(_ id: UUID, at date: Date) {
        state.pendingUpserts.removeValue(forKey: id)
        state.unknownOutcomeUpserts?.remove(id)
        state.pendingDeletes[id] = date
        save()
    }

    func markUnknownOutcome(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var values = state.unknownOutcomeUpserts ?? []
        values.formUnion(ids)
        state.unknownOutcomeUpserts = values
        save()
    }

    func clearUnknownOutcome(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        state.unknownOutcomeUpserts?.subtract(ids)
        save()
    }

    func clearDirty(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingUpserts.removeValue(forKey: id) }
        save()
    }

    func clearDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingDeletes.removeValue(forKey: id) }
        save()
    }

    private func save() {
        persistence.save(state, key: key)
    }
}
