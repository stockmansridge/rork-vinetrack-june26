import Foundation
import Observation
import UIKit

/// Local-first sync service for vineyard custom E-L reference images.
/// Owner/manager uploads write the JPEG to `vineyard-el-stage-images` and
/// upsert a metadata row. Other vineyard members download and cache the
/// image locally so it overrides the bundled asset offline as well.
@Observable
@MainActor
final class GrowthStageImageSyncService {

    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any GrowthStageImageSyncRepositoryProtocol
    private let storageService: ELStageImageStorageService
    private let metadata: ManagementSyncMetadata
    private let pendingStore: GrowthStageImagePendingStore
    private var isConfigured: Bool = false

    init(
        repository: (any GrowthStageImageSyncRepositoryProtocol)? = nil,
        storage: ELStageImageStorageService? = nil
    ) {
        self.repository = repository ?? SupabaseGrowthStageImageSyncRepository()
        self.storageService = storage ?? ELStageImageStorageService()
        self.metadata = ManagementSyncMetadata(key: "vinetrack_growth_stage_image_sync_metadata")
        self.pendingStore = GrowthStageImagePendingStore()
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onCustomELStageImageChanged = { [weak self] vineyardId, stageCode in
            self?.pendingStore.markUpsert(vineyardId: vineyardId, stageCode: stageCode, at: Date())
        }
        store.onCustomELStageImageDeleted = { [weak self] vineyardId, stageCode in
            self?.pendingStore.markDelete(vineyardId: vineyardId, stageCode: stageCode, at: Date())
        }
    }

    func syncForSelectedVineyard() async {
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
            try await push(vineyardId: vineyardId)
            try await pull(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let pendingUpserts = pendingStore.upserts(for: vineyardId)
        var payloads: [BackendGrowthStageImageUpsert] = []
        var pushed: [(UUID, String)] = []

        for (stageCode, ts) in pendingUpserts {
            guard let data = store.loadCustomELStageImageData(for: stageCode) else {
                pendingStore.clearUpsert(vineyardId: vineyardId, stageCode: stageCode)
                continue
            }
            // Pre-warm the cache so a subsequent upload failure still leaves
            // a usable image bytes locally on disk.
            SharedImageCache.shared.saveImageData(
                data,
                for: .elStageImage(vineyardId: vineyardId, stageCode: stageCode),
                remotePath: nil,
                remoteUpdatedAt: ts
            )
            do {
                let path = try await storageService.uploadStageImage(
                    vineyardId: vineyardId,
                    stageCode: stageCode,
                    imageData: data,
                    remoteUpdatedAt: ts
                )
                let id = pendingStore.idFor(vineyardId: vineyardId, stageCode: stageCode)
                payloads.append(BackendGrowthStageImageUpsert(
                    id: id,
                    vineyardId: vineyardId,
                    stageCode: stageCode,
                    imagePath: path,
                    createdBy: createdBy,
                    clientUpdatedAt: ts
                ))
                pushed.append((id, stageCode))
            } catch {
                #if DEBUG
                print("[GrowthStageImageSync] upload failed for \(stageCode): \(error.localizedDescription)")
                #endif
            }
        }

        if !payloads.isEmpty {
            do {
                try await repository.upsertMany(payloads)
                for (_, code) in pushed {
                    pendingStore.clearUpsert(vineyardId: vineyardId, stageCode: code)
                }
            } catch {
                // Likely RLS — non-manager. Don't keep retrying forever; clear locally.
                #if DEBUG
                print("[GrowthStageImageSync] upsert failed: \(error.localizedDescription)")
                #endif
            }
        }

        let pendingDeletes = pendingStore.deletes(for: vineyardId)
        for (stageCode, _) in pendingDeletes {
            let id = pendingStore.idFor(vineyardId: vineyardId, stageCode: stageCode)
            do {
                try await repository.softDelete(id: id)
                // Also remove the storage object; ignore errors.
                let path = ELStageImageStorage.path(vineyardId: vineyardId, stageCode: stageCode)
                try? await storageService.deleteStageImage(
                    path: path,
                    vineyardId: vineyardId,
                    stageCode: stageCode
                )
                pendingStore.clearDelete(vineyardId: vineyardId, stageCode: stageCode)
            } catch {
                if Self.isMissingRowError(error) {
                    pendingStore.clearDelete(vineyardId: vineyardId, stageCode: stageCode)
                } else {
                    #if DEBUG
                    print("[GrowthStageImageSync] soft delete failed for \(stageCode): \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)

        for item in remote {
            // Skip remote rows that conflict with a local pending change.
            if let pendingAt = pendingStore.upsertTimestamp(vineyardId: vineyardId, stageCode: item.stageCode) {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            // Track id mapping so future deletes use the correct id.
            pendingStore.recordRemoteId(item.id, vineyardId: vineyardId, stageCode: item.stageCode)

            if item.deletedAt != nil {
                SharedImageCache.shared.removeCachedImage(
                    for: .elStageImage(vineyardId: vineyardId, stageCode: item.stageCode)
                )
                store.applyRemoteCustomELStageImageDelete(stageCode: item.stageCode)
                continue
            }

            // Skip download if the cache already has this exact remote
            // version. Just make sure local storage on the store has it.
            let cacheKey = SharedImageCacheKey.elStageImage(vineyardId: vineyardId, stageCode: item.stageCode)
            let remoteUpdatedAt = item.clientUpdatedAt ?? item.updatedAt
            if SharedImageCache.shared.isCacheCurrent(
                for: cacheKey,
                remotePath: item.imagePath,
                remoteUpdatedAt: remoteUpdatedAt
            ),
               let cached = SharedImageCache.shared.cachedImageData(for: cacheKey) {
                store.applyRemoteCustomELStageImage(data: cached, for: item.stageCode)
                continue
            }

            do {
                let data = try await storageService.downloadStageImage(
                    path: item.imagePath,
                    vineyardId: vineyardId,
                    stageCode: item.stageCode,
                    remoteUpdatedAt: remoteUpdatedAt
                )
                store.applyRemoteCustomELStageImage(data: data, for: item.stageCode)
            } catch {
                #if DEBUG
                print("[GrowthStageImageSync] download failed for \(item.stageCode): \(error.localizedDescription)")
                #endif
                // Keep showing the existing cached image (if any).
            }
        }
    }

    private static func isMissingRowError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        if message.contains("not found") { return true }
        if message.contains("pgrst116") { return true }
        if message.contains("no rows") { return true }
        if message.contains("0 rows") { return true }
        return false
    }
}

// MARK: - Pending store

@MainActor
final class GrowthStageImagePendingStore {
    private let persistence: PersistenceStore
    private let key: String = "vinetrack_growth_stage_image_pending"
    private var state: State

    nonisolated struct State: Codable, Sendable {
        // Per-vineyard maps keyed by stage code.
        var pendingUpserts: [UUID: [String: Date]] = [:]
        var pendingDeletes: [UUID: [String: Date]] = [:]
        // Stable id assignment per (vineyardId, stageCode) so upsert and
        // soft-delete reference the same row.
        var idsByStage: [String: UUID] = [:]
    }

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
    }

    private func compositeKey(_ vineyardId: UUID, _ stageCode: String) -> String {
        "\(vineyardId.uuidString.lowercased())|\(stageCode)"
    }

    func idFor(vineyardId: UUID, stageCode: String) -> UUID {
        let key = compositeKey(vineyardId, stageCode)
        if let existing = state.idsByStage[key] { return existing }
        let new = UUID()
        state.idsByStage[key] = new
        save()
        return new
    }

    func recordRemoteId(_ id: UUID, vineyardId: UUID, stageCode: String) {
        state.idsByStage[compositeKey(vineyardId, stageCode)] = id
        save()
    }

    func upserts(for vineyardId: UUID) -> [String: Date] {
        state.pendingUpserts[vineyardId] ?? [:]
    }

    func deletes(for vineyardId: UUID) -> [String: Date] {
        state.pendingDeletes[vineyardId] ?? [:]
    }

    func upsertTimestamp(vineyardId: UUID, stageCode: String) -> Date? {
        state.pendingUpserts[vineyardId]?[stageCode]
    }

    func markUpsert(vineyardId: UUID, stageCode: String, at date: Date) {
        var map = state.pendingUpserts[vineyardId] ?? [:]
        map[stageCode] = date
        state.pendingUpserts[vineyardId] = map
        // Cancel any pending delete for the same stage.
        if var deletes = state.pendingDeletes[vineyardId] {
            deletes.removeValue(forKey: stageCode)
            state.pendingDeletes[vineyardId] = deletes
        }
        _ = idFor(vineyardId: vineyardId, stageCode: stageCode)
        save()
    }

    func markDelete(vineyardId: UUID, stageCode: String, at date: Date) {
        var map = state.pendingDeletes[vineyardId] ?? [:]
        map[stageCode] = date
        state.pendingDeletes[vineyardId] = map
        if var upserts = state.pendingUpserts[vineyardId] {
            upserts.removeValue(forKey: stageCode)
            state.pendingUpserts[vineyardId] = upserts
        }
        save()
    }

    func clearUpsert(vineyardId: UUID, stageCode: String) {
        if var map = state.pendingUpserts[vineyardId] {
            map.removeValue(forKey: stageCode)
            state.pendingUpserts[vineyardId] = map
            save()
        }
    }

    func clearDelete(vineyardId: UUID, stageCode: String) {
        if var map = state.pendingDeletes[vineyardId] {
            map.removeValue(forKey: stageCode)
            state.pendingDeletes[vineyardId] = map
            save()
        }
    }

    private func save() {
        persistence.save(state, key: key)
    }
}
