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
    private let photoStorage: PinPhotoStorageService
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    init(
        repository: (any PinSyncRepositoryProtocol)? = nil,
        metadata: PinSyncMetadata? = nil,
        photoStorage: PinPhotoStorageService? = nil
    ) {
        self.repository = repository ?? SupabasePinSyncRepository()
        self.metadata = metadata ?? PinSyncMetadata()
        self.photoStorage = photoStorage ?? PinPhotoStorageService()
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
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
        metadata.markDeleted(id, at: Date())
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
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
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
        let currentUserId = auth?.userId
        let currentUserName = auth?.userName
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let pinsById = Dictionary(store.pins.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendPinUpsert] = []
            var pushedIds: [UUID] = []
            var photoUploadFailures: [String] = []
            for (pinId, ts) in dirty {
                guard var pin = pinsById[pinId], pin.vineyardId == vineyardId else { continue }
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
                // If the pin has local photo bytes but no synced path yet, upload first.
                if let data = pin.photoData, pin.photoPath == nil {
                    // Cache locally first so even an upload failure leaves a
                    // hot cache entry for the next sync attempt.
                    SharedImageCache.shared.saveImageData(
                        data,
                        for: .pinPhoto(vineyardId: vineyardId, pinId: pin.id),
                        remotePath: nil,
                        remoteUpdatedAt: nil
                    )
                    do {
                        let path = try await photoStorage.uploadPhoto(
                            vineyardId: vineyardId,
                            pinId: pin.id,
                            imageData: data
                        )
                        pin.photoPath = path
                        store.applyRemotePinUpsert(pin)
                    } catch {
                        #if DEBUG
                        print("[PinSync] photo upload failed for \(pin.id): \(error.localizedDescription)")
                        #endif
                        photoUploadFailures.append(error.localizedDescription)
                        // Still upsert pin metadata; photo will retry next sync.
                    }
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
                do {
                    try await repository.upsertPins(payloads)
                    metadata.clearDirty(pushedIds)
                    PinSyncDiagnostics.shared.recordBatchResult(count: payloads.count, success: true, errorMessage: nil)
                } catch {
                    // Isolate the failure to exactly the pins in this batch.
                    metadata.markUpsertsFailed(pushedIds)
                    PinSyncDiagnostics.shared.recordBatchResult(count: payloads.count, success: false, errorMessage: error.localizedDescription)
                    throw error
                }
            }
            if !photoUploadFailures.isEmpty {
                errorMessage = "Some pin photos failed to upload: \(photoUploadFailures.first ?? "unknown")"
            }
        }

        let deletes = metadata.pendingDeletes
        var deleteFailures: [String] = []
        for (pinId, _) in deletes {
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
            // Surface a non-fatal warning via errorMessage but don't throw — let pull and
            // future upserts continue.
            errorMessage = "Some pin deletes failed: \(deleteFailures.first ?? "unknown")"
        }
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
        let remote = try await repository.fetchPins(vineyardId: vineyardId, since: lastSync)

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
        for backendPin in remote {
            await applyRemote(backendPin, vineyardId: vineyardId, store: store, nameColorMap: nameColorMap)
        }
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

    private func applyRemote(_ backendPin: BackendPin, vineyardId: UUID, store: MigratedDataStore, nameColorMap: [String: String]) async {
        let existingIndex = store.pins.firstIndex { $0.id == backendPin.id }

        // Soft-deleted remotely.
        if backendPin.deletedAt != nil {
            if existingIndex != nil {
                store.applyRemotePinDelete(backendPin.id)
            }
            metadata.clearDirty([backendPin.id])
            metadata.clearDeleted([backendPin.id])
            return
        }

        // Last-write-wins: only apply remote if it's newer than the local pending change.
        if let pendingDirtyAt = metadata.pendingUpserts[backendPin.id] {
            let remoteAt = backendPin.clientUpdatedAt ?? backendPin.updatedAt ?? .distantPast
            if pendingDirtyAt > remoteAt {
                return
            }
        }

        let existingPin: VinePin? = existingIndex.map { store.pins[$0] }
        let existingPhotoData: Data? = existingPin?.photoData
        let existingPhotoPath: String? = existingPin?.photoPath
        let existingCreatedByText: String? = existingPin?.createdBy

        guard var mapped = backendPin.toVinePin(
            preservingPhoto: existingPhotoData,
            preservingCreatedByText: existingCreatedByText,
            nameColorMap: nameColorMap
        ) else { return }

        // If the remote has a photoPath, try the disk cache first, then
        // fall back to a network download. Failures are non-fatal — we keep
        // whatever cached/local bytes we already have.
        if let remotePath = mapped.photoPath {
            let cacheKey = SharedImageCacheKey.pinPhoto(vineyardId: vineyardId, pinId: backendPin.id)
            let pathChanged = existingPhotoPath != remotePath

            if mapped.photoData == nil || pathChanged {
                if !pathChanged,
                   let cached = SharedImageCache.shared.cachedImageData(for: cacheKey) {
                    mapped.photoData = cached
                }
            }

            let needsDownload = mapped.photoData == nil || pathChanged
            if needsDownload {
                do {
                    let data = try await photoStorage.downloadPhoto(
                        path: remotePath,
                        vineyardId: vineyardId,
                        pinId: backendPin.id
                    )
                    mapped.photoData = data
                } catch {
                    #if DEBUG
                    print("[PinSync] photo download failed for \(backendPin.id) at \(remotePath): \(error.localizedDescription)")
                    #endif
                    // Keep existing cached bytes if any.
                    if mapped.photoData == nil,
                       let cached = SharedImageCache.shared.cachedImageData(for: cacheKey) {
                        mapped.photoData = cached
                    }
                }
            }
        }

        store.applyRemotePinUpsert(mapped)
        metadata.clearDirty([backendPin.id])
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

    private func save() {
        persistence.save(state, key: key)
    }
}
