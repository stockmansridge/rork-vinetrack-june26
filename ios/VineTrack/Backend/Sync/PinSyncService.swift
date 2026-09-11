import Foundation
import Observation

/// Local-first sync service for VinePin records.
/// Tracks dirty/deleted pins locally and pushes/pulls them against Supabase
/// using `SupabasePinSyncRepository`. Conflict resolution is last-write-wins
/// based on `client_updated_at`/`updated_at`.
@Observable
@MainActor
final class PinSyncService {

    enum Status: Equatable, Sendable {
        case idle
        case syncing
        case success
        case failure(String)
    }

    nonisolated struct LocalPinDetail: Sendable, Identifiable {
        var id: UUID
        var title: String
        var mode: String
        var category: String?
        var growthStageCode: String?
        var localVineyardId: UUID
        var paddockId: UUID?
        var paddockName: String?
        var isCompleted: Bool
        var createdAt: Date
        var createdBy: String?
        var createdByUserId: UUID?
        var hasPhotoPath: Bool
        var hasLocalPhotoBytes: Bool
        var isPendingUpsert: Bool
        var isPendingDelete: Bool
    }

    nonisolated struct RemotePinDetail: Sendable, Identifiable {
        var id: UUID
        var title: String
        var mode: String?
        var vineyardId: UUID
        var paddockId: UUID?
        var isCompleted: Bool
        var deletedAt: Date?
        var createdAt: Date?
        var updatedAt: Date?
        var createdBy: UUID?
    }

    nonisolated struct AuditResult: Sendable {
        var ranAt: Date?
        var localAcrossAllVineyards: Int = 0
        var localForVineyard: Int = 0
        var remoteForVineyard: Int = 0
        var remoteActive: Int = 0
        var remoteSoftDeleted: Int = 0
        var localOnlyIds: [UUID] = []
        var remoteOnlyIds: [UUID] = []
        var localVineyardMismatch: [UUID] = []
        var localOnlyDetails: [LocalPinDetail] = []
        var orphanLocalDetails: [LocalPinDetail] = []
        var remoteSoftDeletedDetails: [RemotePinDetail] = []
        var pendingUpsertIds: [UUID] = []
        var pendingDeleteIds: [UUID] = []
        var error: String?
    }

    var lastAuditResult: AuditResult = AuditResult()

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    /// Diagnostics-only: count of locally pending upserts not yet pushed.
    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    /// Diagnostics-only: count of locally pending soft-deletes not yet pushed.
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    /// Whether a specific pin has local changes queued for upload.
    func isPendingUpsert(_ id: UUID) -> Bool { metadata.pendingUpserts[id] != nil }

    /// Whether a specific pin is queued for a remote delete.
    func isPendingDelete(_ id: UUID) -> Bool { metadata.pendingDeletes[id] != nil }

    /// True while a full sweep is actively pushing/pulling pins.
    var isSyncing: Bool { syncStatus == .syncing }

    /// True if the last sweep failed.
    var hasFailure: Bool { if case .failure = syncStatus { return true }; return false }

    /// Whether a specific pin's last push failed while still pending. Used for
    /// per-record error isolation so one failed pin never makes others look
    /// failed.
    func hasFailure(_ id: UUID) -> Bool { metadata.isUpsertFailed(id) || metadata.isDeleteFailed(id) }

    var failedUpsertIds: Set<UUID> { metadata.failedUpsertIds }
    var failedDeleteIds: Set<UUID> { metadata.failedDeleteIds }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any PinSyncRepositoryProtocol
    private let metadata: PinSyncMetadata
    private let photoStorage: any PinPhotoStorageProtocol
    private let persistence: PersistenceStore
    private let deletionStore: LinkedPinGrowthDeletionStore
    private let pendingPhotosKey = "vinetrack_pending_pin_photos_v2"
    private var pendingPhotos: [UUID: PendingPinPhoto]
    private var isConfigured: Bool = false
    private var isSyncInFlight: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    init(
        repository: (any PinSyncRepositoryProtocol)? = nil,
        metadata: PinSyncMetadata? = nil,
        photoStorage: (any PinPhotoStorageProtocol)? = nil,
        persistence: PersistenceStore = .shared,
        deletionStore: LinkedPinGrowthDeletionStore? = nil
    ) {
        self.repository = repository ?? SupabasePinSyncRepository()
        self.metadata = metadata ?? PinSyncMetadata(persistence: persistence)
        self.photoStorage = photoStorage ?? PinPhotoStorageService()
        self.persistence = persistence
        self.deletionStore = deletionStore ?? .shared
        self.pendingPhotos = persistence.load(key: pendingPhotosKey) ?? [:]
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        for pinId in deletionStore.pinIds { store.applyRemotePinDelete(pinId) }
        // Always refresh the user-id/name providers so addPin/updatePin can
        // self-heal even on subsequent sign-ins. Safe to overwrite.
        store.currentUserIdProvider = { [weak auth] in auth?.userId }
        store.currentUserNameProvider = { [weak auth] in auth?.userName }
        guard !isConfigured else { return }
        isConfigured = true
        store.onPinChanged = { [weak self] id in
            self?.markPinDirty(id)
            self?.scheduleEagerPush()
        }
        store.onPinDeleted = { [weak self] id in
            self?.markPinDeleted(id)
            self?.scheduleEagerPush()
        }
    }

    /// Debounced eager-push. Multiple quick edits coalesce into a single sync.
    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncPinsForSelectedVineyard()
        }
    }

    // MARK: - Dirty tracking

    func markPinDirty(_ id: UUID) {
        metadata.markDirty(id, at: Date())
    }

    func markPinDeleted(_ id: UUID) {
        pendingPhotos.removeValue(forKey: id)
        try? persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
        metadata.markDeleted(id, at: Date())
    }

    func localPhotoData(pinId: UUID) -> Data? { pendingPhotos[pinId]?.imageData }
    func attachmentRevision(pinId: UUID) -> UUID? { pendingPhotos[pinId]?.revision }
    func hasPendingPhoto(pinId: UUID) -> Bool { pendingPhotos[pinId] != nil }

    /// Retains bytes and target identity durably before updating display state.
    func attachPhoto(pinId: UUID, imageData: Data) throws {
        guard var pin = store?.pins.first(where: { $0.id == pinId }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The pin is no longer available."])
        }
        let payload = PinPhotoStorage.compress(imageData) ?? imageData
        guard !payload.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The captured photo was empty."])
        }
        let revision = UUID()
        let work = PendingPinPhoto(
            pinId: pin.id,
            vineyardId: pin.vineyardId,
            revision: revision,
            imageData: payload,
            capturedAt: Date(),
            previousRemotePath: pin.photoPath,
            uploadedPath: nil
        )
        var next = pendingPhotos
        next[pin.id] = work
        try persistence.saveOrThrow(next, key: pendingPhotosKey)
        try SharedImageCache.shared.saveImageDataOrThrow(
            payload,
            for: .pinPhoto(vineyardId: pin.vineyardId, pinId: pin.id),
            remotePath: nil,
            remoteUpdatedAt: nil,
            attachmentRevision: revision
        )
        pendingPhotos = next
        pin.photoData = payload
        store?.updatePin(pin)
        scheduleEagerPush()
    }

    // MARK: - Public sync entry points

    /// Compare local pins against Supabase for the selected vineyard so the
    /// user can see whether locally-visible pins have reached the backend.
    /// Read-only — does not push, pull or repair.
    func auditPinSync(vineyardId: UUID) async -> AuditResult {
        var result = AuditResult()
        result.ranAt = Date()
        guard let store else { return result }
        guard SupabaseClientProvider.shared.isConfigured else {
            result.error = "Supabase not configured"
            lastAuditResult = result
            return result
        }

        let allLocal = store.pinRepo.loadAll()
        result.localAcrossAllVineyards = allLocal.count
        let localForVineyard = allLocal.filter { $0.vineyardId == vineyardId }
        result.localForVineyard = localForVineyard.count
        result.localVineyardMismatch = allLocal
            .filter { $0.vineyardId != vineyardId }
            .map { $0.id }
        let pendingUpsertIds = Array(metadata.pendingUpserts.keys)
        let pendingDeleteIds = Array(metadata.pendingDeletes.keys)
        result.pendingUpsertIds = pendingUpsertIds
        result.pendingDeleteIds = pendingDeleteIds
        let pendingUpsertSet = Set(pendingUpsertIds)
        let pendingDeleteSet = Set(pendingDeleteIds)

        let paddockNames = Dictionary(
            store.paddocks.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        func detail(for pin: VinePin) -> LocalPinDetail {
            LocalPinDetail(
                id: pin.id,
                title: pin.buttonName,
                mode: pin.mode.rawValue,
                category: nil,
                growthStageCode: pin.growthStageCode,
                localVineyardId: pin.vineyardId,
                paddockId: pin.paddockId,
                paddockName: pin.paddockId.flatMap { paddockNames[$0] },
                isCompleted: pin.isCompleted,
                createdAt: pin.timestamp,
                createdBy: pin.createdBy,
                createdByUserId: pin.createdByUserId,
                hasPhotoPath: pin.photoPath != nil,
                hasLocalPhotoBytes: pin.photoData != nil,
                isPendingUpsert: pendingUpsertSet.contains(pin.id),
                isPendingDelete: pendingDeleteSet.contains(pin.id)
            )
        }

        // Orphans: local pins assigned to a different vineyard.
        result.orphanLocalDetails = allLocal
            .filter { $0.vineyardId != vineyardId }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(50)
            .map { detail(for: $0) }

        do {
            let remote = try await repository.fetchAllPins(vineyardId: vineyardId)
            result.remoteForVineyard = remote.count
            let active = remote.filter { $0.deletedAt == nil }
            result.remoteActive = active.count
            result.remoteSoftDeleted = remote.count - active.count
            let activeIds = Set(active.map { $0.id })
            let remoteAllIds = Set(remote.map { $0.id })
            let localIds = Set(localForVineyard.map { $0.id })

            let localOnly = localForVineyard.filter { !activeIds.contains($0.id) }
            result.localOnlyIds = localOnly.map { $0.id }
            result.localOnlyDetails = localOnly
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(50)
                .map { detail(for: $0) }

            result.remoteOnlyIds = active
                .filter { !localIds.contains($0.id) }
                .map { $0.id }

            // Remote rows that are soft-deleted server-side (and may be
            // why Lovable does not show them).
            let softDeleted = remote.filter { $0.deletedAt != nil }
            result.remoteSoftDeletedDetails = softDeleted
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
                .prefix(50)
                .map { backendPin in
                    RemotePinDetail(
                        id: backendPin.id,
                        title: backendPin.buttonName ?? backendPin.title ?? "",
                        mode: backendPin.mode,
                        vineyardId: backendPin.vineyardId,
                        paddockId: backendPin.paddockId,
                        isCompleted: backendPin.isCompleted,
                        deletedAt: backendPin.deletedAt,
                        createdAt: backendPin.createdAt,
                        updatedAt: backendPin.updatedAt,
                        createdBy: backendPin.createdBy
                    )
                }
            _ = remoteAllIds
        } catch {
            result.error = error.localizedDescription
        }

        lastAuditResult = result
        return result
    }

    func syncPinsForSelectedVineyard() async {
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
            try await pushLocalPins(vineyardId: vineyardId)
            try await pullRemotePins(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Push

    func pushLocalPins(vineyardId: UUID) async throws {
        guard let store else { return }
        let pinPushCount = metadata.pendingUpserts.count
        let pinPushStartedAt = Date()
        VineyardSelectionDiagnostics.intervalStage(
            "pin-push",
            phase: "started",
            vineyardId: vineyardId,
            count: pinPushCount
        )
        for target in deletionStore.targets.values where target.isConfirmed {
            if let pinId = target.pinId { metadata.clearDeleted([pinId]) }
            try deletionStore.remove(target.id)
        }
        let currentUserId = auth?.userId
        let currentUserName = auth?.userName
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let pinsById = Dictionary(store.pins.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendPinUpsert] = []
            var pushedIds: [UUID] = []
            var orphans: [UUID] = []
            for (pinId, ts) in dirty {
                // Reclaim queue entries whose local pin no longer exists — they
                // can never upload and used to wedge the queue forever. Pins
                // belonging to another vineyard are still pushed: the payload
                // carries their own vineyard id.
                guard var pin = pinsById[pinId] else { orphans.append(pinId); continue }
                // Manual issues are RPC-owned (sql/169): every write goes
                // through ManualIssueSyncService so the server enforces the
                // no-labour contract and permissions. The generic upsert
                // path must never touch them — reclaim the queue slot.
                if pin.mode == .manualIssue { orphans.append(pinId); continue }
                // Self-heal: stamp the current authenticated user as the
                // creator if the pin was created without one. Never
                // overwrite an existing non-nil value — that would lose
                // attribution to the original creator.
                if pin.createdByUserId == nil, let uid = currentUserId {
                    pin.createdByUserId = uid
                    if (pin.createdBy ?? "").isEmpty, let name = currentUserName, !name.isEmpty {
                        pin.createdBy = name
                    }
                    store.applyRemotePinUpsert(pin)
                    #if DEBUG
                    print("[PinSync] stamped created_by=\(uid) on pin \(pin.id) before push")
                    #endif
                }
                let payload = BackendPin.upsert(from: pin, clientUpdatedAt: ts)
                #if DEBUG
                let _createdByText = pin.createdBy ?? "nil"
                let _createdByUserId = pin.createdByUserId?.uuidString ?? "nil"
                let _payloadCreatedBy = payload.createdBy?.uuidString ?? "nil"
                let _authUserId = currentUserId?.uuidString ?? "nil"
                print("[PinSync] push pin id=\(pin.id) createdByText=\(_createdByText) createdByUserId=\(_createdByUserId) payload.created_by=\(_payloadCreatedBy) authUserId=\(_authUserId)")
                #endif
                PinSyncDiagnostics.shared.recordPush(pin: pin, payload: payload, authUserId: currentUserId)
                payloads.append(payload)
                pushedIds.append(pinId)
            }
            if !payloads.isEmpty {
                #if DEBUG
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                if let json = try? encoder.encode(payloads),
                   let str = String(data: json, encoding: .utf8) {
                    print("[PinSync] upsert payload JSON: \(str)")
                }
                #endif
                let result = await SyncQueuePush.run(
                    entity: "Pins",
                    ids: pushedIds,
                    payloads: payloads,
                    queuedAt: dirty,
                    vineyardId: vineyardId
                ) { try await repository.upsertPins($0) }
                metadata.clearDirty(result.uploaded)
                metadata.markUpsertsFailed(result.failed)
                PinSyncDiagnostics.shared.recordBatchResult(
                    count: payloads.count,
                    success: !result.hasFailures,
                    errorMessage: result.hasFailures ? "\(result.failed.count) of \(payloads.count) pin(s) rejected" : nil
                )
                if let error = result.firstRetryableError { throw error }
            }
            metadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            SyncIssueCenter.shared.notePending(entity: "Pins", count: metadata.pendingUpserts.count)
        }
        VineyardSelectionDiagnostics.intervalStage(
            "pin-push",
            phase: "finished",
            vineyardId: vineyardId,
            count: pinPushCount,
            elapsedSince: pinPushStartedAt
        )

        let photoCount = pendingPhotos.values.count { $0.vineyardId == vineyardId }
        let photoUploadStartedAt = Date()
        VineyardSelectionDiagnostics.intervalStage(
            "pin-photo-upload",
            phase: "started",
            vineyardId: vineyardId,
            count: photoCount
        )
        var independentPhotoError: Error?
        do { try await pushPendingPhotos(vineyardId: vineyardId) }
        catch { independentPhotoError = error }
        VineyardSelectionDiagnostics.intervalStage(
            "pin-photo-upload",
            phase: "finished",
            vineyardId: vineyardId,
            count: photoCount,
            elapsedSince: photoUploadStartedAt
        )

        let deletes = metadata.pendingDeletes
        let deleteStartedAt = Date()
        VineyardSelectionDiagnostics.intervalStage(
            "pin-deletion",
            phase: "started",
            vineyardId: vineyardId,
            count: deletes.count
        )
        var deleteFailures: [String] = []
        for (pinId, _) in deletes {
            if deletionStore.pinIds.contains(pinId) { continue }
            do {
                try await repository.softDeletePin(id: pinId)
                metadata.clearDeleted([pinId])
            } catch {
                if Self.isMissingRowError(error) {
                    // Remote row already gone — treat as already deleted.
                    metadata.clearDeleted([pinId])
                    #if DEBUG
                    print("[PinSync] soft delete: remote pin \(pinId) already missing — clearing pending delete")
                    #endif
                } else {
                    #if DEBUG
                    print("[PinSync] soft delete failed for \(pinId): \(error.localizedDescription)")
                    #endif
                    metadata.markDeletesFailed([pinId])
                    deleteFailures.append(error.localizedDescription)
                    // Keep the deletion pending so it retries next sync, but don't abort.
                    continue
                }
            }
        }
        if !deleteFailures.isEmpty {
            errorMessage = "Some pin deletes failed: \(deleteFailures.first ?? "unknown")"
        }
        VineyardSelectionDiagnostics.intervalStage(
            "pin-deletion",
            phase: "finished",
            vineyardId: vineyardId,
            count: deletes.count,
            elapsedSince: deleteStartedAt
        )
        if let independentPhotoError { throw independentPhotoError }
    }

    private func pushPendingPhotos(vineyardId: UUID) async throws {
        let candidates = pendingPhotos.values
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.capturedAt < $1.capturedAt }
        var firstFailure: Error?
        for snapshot in candidates {
            guard metadata.pendingDeletes[snapshot.pinId] == nil,
                  metadata.pendingUpserts[snapshot.pinId] == nil,
                  store?.pins.contains(where: { $0.id == snapshot.pinId }) == true,
                  pendingPhotos[snapshot.pinId]?.revision == snapshot.revision else { continue }
            do {
                var work = snapshot
                if work.uploadedPath == nil {
                    let path = try await photoStorage.uploadPhoto(
                        vineyardId: work.vineyardId,
                        pinId: work.pinId,
                        revision: work.revision,
                        imageData: work.imageData
                    )
                    guard metadata.pendingDeletes[work.pinId] == nil,
                          pendingPhotos[work.pinId]?.revision == work.revision else { continue }
                    work.uploadedPath = path
                    pendingPhotos[work.pinId] = work
                    try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
                }

                guard let path = work.uploadedPath,
                      metadata.pendingDeletes[work.pinId] == nil,
                      pendingPhotos[work.pinId]?.revision == work.revision else { continue }
                _ = try await repository.updatePhotoPath(
                    pinId: work.pinId,
                    vineyardId: work.vineyardId,
                    path: path
                )
                guard metadata.pendingDeletes[work.pinId] == nil,
                      pendingPhotos[work.pinId]?.revision == work.revision else { continue }
                if var pin = store?.pins.first(where: { $0.id == work.pinId }) {
                    pin.photoPath = path
                    pin.photoData = work.imageData
                    store?.applyRemotePinUpsert(pin)
                }
                try SharedImageCache.shared.saveImageDataOrThrow(
                    work.imageData,
                    for: .pinPhoto(vineyardId: work.vineyardId, pinId: work.pinId),
                    remotePath: path,
                    remoteUpdatedAt: nil,
                    attachmentRevision: work.revision
                )
                guard pendingPhotos[work.pinId]?.revision == work.revision else { continue }
                pendingPhotos.removeValue(forKey: work.pinId)
                try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
            } catch AttachmentReferenceWriteError.recordDeleted {
                guard pendingPhotos[snapshot.pinId]?.revision == snapshot.revision else { continue }
                pendingPhotos.removeValue(forKey: snapshot.pinId)
                try persistence.saveOrThrow(pendingPhotos, key: pendingPhotosKey)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private static func isMissingRowError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        if message.contains("pin not found") { return true }
        if message.contains("not found") { return true }
        if message.contains("pgrst116") { return true }
        if message.contains("no rows") { return true }
        if message.contains("0 rows") { return true }
        return false
    }

    // MARK: - Pull

    func pullRemotePins(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let fetchStartedAt = Date()
        VineyardSelectionDiagnostics.intervalStage(
            "pin-fetch-decode",
            phase: "started",
            vineyardId: vineyardId,
            count: 0
        )
        let remote = try await repository.fetchPins(vineyardId: vineyardId, since: lastSync)
        VineyardSelectionDiagnostics.intervalStage(
            "pin-fetch-decode",
            phase: "finished",
            vineyardId: vineyardId,
            count: remote.count,
            elapsedSince: fetchStartedAt
        )

        // Initial sync: if both local and remote slices are empty, nothing to do.
        // If remote is empty AND we have local pins AND we have never synced before,
        // push them all up so the cloud picks them up.
        if remote.isEmpty, lastSync == nil {
            var localForVineyard = store.pins.filter { $0.vineyardId == vineyardId }
            if !localForVineyard.isEmpty {
                let currentUserId = auth?.userId
                let currentUserName = auth?.userName
                if let uid = currentUserId {
                    for i in localForVineyard.indices where localForVineyard[i].createdByUserId == nil {
                        localForVineyard[i].createdByUserId = uid
                        if (localForVineyard[i].createdBy ?? "").isEmpty,
                           let name = currentUserName, !name.isEmpty {
                            localForVineyard[i].createdBy = name
                        }
                        store.applyRemotePinUpsert(localForVineyard[i])
                    }
                }
                let now = Date()
                let payloads = localForVineyard.map {
                    BackendPin.upsert(from: $0, clientUpdatedAt: now)
                }
                try await repository.upsertPins(payloads)
            }
            return
        }

        let nameColorMap = Self.buttonNameColorMap(for: vineyardId)
        var downloadedPhotos: [UUID: DownloadedRemotePhoto] = [:]
        let photoCandidates = remote.compactMap { backendPin -> (BackendPin, String)? in
            guard backendPin.deletedAt == nil,
                  metadata.pendingDeletes[backendPin.id] == nil,
                  !deletionStore.pinIds.contains(backendPin.id),
                  pendingPhotos[backendPin.id] == nil,
                  let path = backendPin.photoPath else { return nil }
            let existing = store.pins.first { $0.id == backendPin.id }
            guard existing?.photoPath != path || existing?.photoData == nil else { return nil }
            return (backendPin, path)
        }
        let photoStartedAt = Date()
        VineyardSelectionDiagnostics.intervalStage(
            "pin-photo-download",
            phase: "started",
            vineyardId: vineyardId,
            count: photoCandidates.count
        )
        for (backendPin, path) in photoCandidates {
            let cacheKey = SharedImageCacheKey.pinPhoto(vineyardId: vineyardId, pinId: backendPin.id)
            do {
                let data = try await photoStorage.downloadPhoto(
                    path: path,
                    vineyardId: vineyardId,
                    pinId: backendPin.id
                )
                downloadedPhotos[backendPin.id] = DownloadedRemotePhoto(path: path, data: data)
            } catch {
                #if DEBUG
                print("[PinSync] photo download failed for \(backendPin.id) at \(path): \(error.localizedDescription)")
                #endif
                if let cached = SharedImageCache.shared.cachedImageData(for: cacheKey) {
                    downloadedPhotos[backendPin.id] = DownloadedRemotePhoto(path: path, data: cached)
                }
            }
        }
        VineyardSelectionDiagnostics.intervalStage(
            "pin-photo-download",
            phase: "finished",
            vineyardId: vineyardId,
            count: photoCandidates.count,
            elapsedSince: photoStartedAt
        )

        let mergeStartedAt = Date()
        let publicationCount = store.selectedVineyardId == vineyardId ? 1 : 0
        VineyardSelectionDiagnostics.intervalStage(
            "pin-merge-cache-r1-w1-p\(publicationCount)",
            phase: "started",
            vineyardId: vineyardId,
            count: remote.count
        )
        try applyRemoteBatch(
            remote,
            vineyardId: vineyardId,
            store: store,
            nameColorMap: nameColorMap,
            downloadedPhotos: downloadedPhotos
        )
        VineyardSelectionDiagnostics.intervalStage(
            "pin-merge-cache-r1-w1-p\(publicationCount)",
            phase: "finished",
            vineyardId: vineyardId,
            count: remote.count,
            elapsedSince: mergeStartedAt
        )
    }

    /// Button-name → colour-token map for a vineyard, loaded straight from the
    /// persisted launcher configuration (falling back to the defaults) so pins
    /// with no stored colour resolve exactly like Android's `pinColor`.
    private static func buttonNameColorMap(for vineyardId: UUID) -> [String: String] {
        let persistence = PersistenceStore.shared
        let repair: [ButtonConfig] = persistence.load(key: MigratedDataStore.repairButtonsKey(for: vineyardId))
            ?? ButtonConfig.defaultRepairButtons(for: vineyardId)
        let growth: [ButtonConfig] = persistence.load(key: MigratedDataStore.growthButtonsKey(for: vineyardId))
            ?? ButtonConfig.defaultGrowthButtons(for: vineyardId)
        var map: [String: String] = [:]
        for config in repair + growth where map[config.name] == nil {
            map[config.name] = config.color
        }
        return map
    }

    private struct DownloadedRemotePhoto {
        let path: String
        let data: Data
    }

    /// Re-evaluates every conflict against current state after photo awaits,
    /// then durably commits one vineyard slice before acknowledging metadata.
    private func applyRemoteBatch(
        _ remote: [BackendPin],
        vineyardId: UUID,
        store: MigratedDataStore,
        nameColorMap: [String: String],
        downloadedPhotos: [UUID: DownloadedRemotePhoto]
    ) throws {
        let cacheSnapshot = try store.pinRepo.loadAllForDurableUpdate()
        let latestPins = store.selectedVineyardId == vineyardId
            ? store.pins
            : cacheSnapshot.filter { $0.vineyardId == vineyardId }
        let existingById = Dictionary(latestPins.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var upserts: [VinePin] = []
        var deletions = Set<UUID>()
        var acknowledgedUpserts: [UUID] = []
        var acknowledgedDeletes: [UUID] = []

        for backendPin in remote {
            // Revalidate all mutable protection state after awaited photo work.
            guard metadata.pendingDeletes[backendPin.id] == nil,
                  !deletionStore.pinIds.contains(backendPin.id),
                  pendingPhotos[backendPin.id] == nil else { continue }

            if backendPin.deletedAt != nil {
                if existingById[backendPin.id] != nil { deletions.insert(backendPin.id) }
                acknowledgedUpserts.append(backendPin.id)
                acknowledgedDeletes.append(backendPin.id)
                continue
            }

            if let pendingDirtyAt = metadata.pendingUpserts[backendPin.id] {
                let remoteAt = backendPin.clientUpdatedAt ?? backendPin.updatedAt ?? .distantPast
                if pendingDirtyAt > remoteAt { continue }
            }

            let existing = existingById[backendPin.id]
            guard var mapped = backendPin.toVinePin(
                preservingPhoto: existing?.photoData,
                preservingCreatedByText: existing?.createdBy,
                nameColorMap: nameColorMap
            ) else { continue }

            if let remotePath = mapped.photoPath {
                let pathChanged = existing?.photoPath != remotePath
                if let downloaded = downloadedPhotos[backendPin.id], downloaded.path == remotePath {
                    mapped.photoData = downloaded.data
                } else if !pathChanged, mapped.photoData == nil {
                    mapped.photoData = SharedImageCache.shared.cachedImageData(
                        for: .pinPhoto(vineyardId: vineyardId, pinId: backendPin.id)
                    )
                }
            }
            upserts.append(mapped)
            acknowledgedUpserts.append(backendPin.id)
        }

        try store.applyRemotePinBatch(
            vineyardId: vineyardId,
            cacheSnapshot: cacheSnapshot,
            upserts: upserts,
            deleting: deletions
        )
        metadata.clearRemoteAcknowledged(
            upsertIds: acknowledgedUpserts,
            deleteIds: acknowledgedDeletes
        )
    }
}

// MARK: - Metadata

@MainActor
final class PinSyncMetadata {
    private let persistence: PersistenceStore
    private let key: String = "vinetrack_pin_sync_metadata"
    private var state: State

    nonisolated struct State: Codable, Sendable {
        var lastSyncByVineyard: [UUID: Date] = [:]
        var pendingUpserts: [UUID: Date] = [:]
        var pendingDeletes: [UUID: Date] = [:]
        /// Records whose last upsert/delete push failed while still pending.
        var failedUpserts: Set<UUID> = []
        var failedDeletes: Set<UUID> = []
        /// Version of the remote→local pin mapping logic that last populated the
        /// local cache. Bumping `currentMappingVersion` forces one full re-pull
        /// so already-cached pins are re-mapped with the newer logic
        /// (title/colour fallbacks for Android-created pins).
        var mappingVersion: Int? = nil
    }

    /// Bump when `BackendPin.toVinePin` mapping rules change in a way that
    /// should rewrite pins already cached on the device.
    private static let currentMappingVersion = 2

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        var loaded: State = persistence.load(key: key) ?? State()
        if loaded.mappingVersion != Self.currentMappingVersion {
            // Old cache was mapped with stale logic (blank names / hardcoded
            // blue for Android pins) — clear the sync cursors so the next sync
            // re-downloads and re-maps every pin. Pending local edits still win
            // via the last-write-wins check.
            loaded.lastSyncByVineyard = [:]
            loaded.mappingVersion = Self.currentMappingVersion
            self.state = loaded
            persistence.save(loaded, key: key)
            return
        }
        self.state = loaded
    }

    var pendingUpserts: [UUID: Date] { state.pendingUpserts }
    var pendingDeletes: [UUID: Date] { state.pendingDeletes }

    var failedUpsertIds: Set<UUID> { state.failedUpserts }
    var failedDeleteIds: Set<UUID> { state.failedDeletes }
    func isUpsertFailed(_ id: UUID) -> Bool { state.failedUpserts.contains(id) }
    func isDeleteFailed(_ id: UUID) -> Bool { state.failedDeletes.contains(id) }

    func markUpsertsFailed(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.failedUpserts.insert(id) }
        save()
    }
    func markDeletesFailed(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.failedDeletes.insert(id) }
        save()
    }
    func clearUpsertFailures(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let before = state.failedUpserts.count
        for id in ids { state.failedUpserts.remove(id) }
        if state.failedUpserts.count != before { save() }
    }
    func clearDeleteFailures(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let before = state.failedDeletes.count
        for id in ids { state.failedDeletes.remove(id) }
        if state.failedDeletes.count != before { save() }
    }

    func lastSync(for vineyardId: UUID) -> Date? {
        state.lastSyncByVineyard[vineyardId]
    }

    func setLastSync(_ date: Date, for vineyardId: UUID) {
        state.lastSyncByVineyard[vineyardId] = date
        save()
    }

    func markDirty(_ id: UUID, at date: Date) {
        state.pendingUpserts[id] = date
        state.failedUpserts.remove(id)
        save()
    }

    func markDeleted(_ id: UUID, at date: Date) {
        state.pendingUpserts.removeValue(forKey: id)
        state.failedUpserts.remove(id)
        state.pendingDeletes[id] = date
        save()
    }

    func clearDirty(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingUpserts.removeValue(forKey: id); state.failedUpserts.remove(id) }
        save()
    }

    func clearDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingDeletes.removeValue(forKey: id); state.failedDeletes.remove(id) }
        save()
    }

    func clearRemoteAcknowledged(upsertIds: [UUID], deleteIds: [UUID]) {
        guard !upsertIds.isEmpty || !deleteIds.isEmpty else { return }
        for id in upsertIds {
            state.pendingUpserts.removeValue(forKey: id)
            state.failedUpserts.remove(id)
        }
        for id in deleteIds {
            state.pendingDeletes.removeValue(forKey: id)
            state.failedDeletes.remove(id)
        }
        save()
    }

    private func save() {
        persistence.save(state, key: key)
    }
}
