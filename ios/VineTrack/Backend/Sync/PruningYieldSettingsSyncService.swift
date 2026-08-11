import Foundation

/// Sync service for the shared per-block Pruning Yield Calculator
/// configuration (`public.pruning_yield_settings`, sql/181). Same push→pull,
/// last-write-wins pattern as `PickingRecordSyncService`, with one addition:
/// on the FIRST sync it migrates any legacy device-local saves (pre-sql/181
/// UserDefaults) into the shared contract for blocks that have no shared
/// record yet — never overwriting an existing shared configuration.
@Observable
@MainActor
final class PruningYieldSettingsSyncService {
    typealias Status = OperationsSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }
    private let repository: any PruningYieldSettingsSyncRepositoryProtocol
    private let metadata: OperationsSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any PruningYieldSettingsSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabasePruningYieldSettingsSyncRepository()
        self.metadata = OperationsSyncMetadata(key: "vinetrack_pruning_yield_settings_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onPruningYieldSettingsChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onPruningYieldSettingsDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
    }

    func syncForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        await sync(vineyardId: vineyardId)
    }

    func sync(vineyardId: UUID) async {
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"; syncStatus = .failure("Supabase not configured"); return
        }
        syncStatus = .syncing; errorMessage = nil
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
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.pruningYieldSettings.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendPruningYieldSettingsUpsert] = []
            var pushed: [UUID] = []
            var orphans: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id] else { orphans.append(id); continue }
                payloads.append(BackendPruningYieldSettings.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            metadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            let result = await SyncQueuePush.run(
                entity: "Pruning Yield Settings",
                ids: pushed,
                payloads: payloads,
                queuedAt: dirty,
                vineyardId: vineyardId
            ) { try await repository.upsertMany($0) }
            metadata.clearDirty(result.uploaded)
            SyncIssueCenter.shared.notePending(entity: "Pruning Yield Settings", count: metadata.pendingUpserts.count)
            if let error = result.firstRetryableError { throw error }
        }
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isOperationsMissingRowError(error) { metadata.clearDeleted([id]) }
            }
        }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            // One-time migration: adopt legacy device-local calculator saves
            // for blocks that have NO shared record yet (remote wins when it
            // exists, so a newer shared configuration is never overwritten).
            adoptLegacyLocalSettings(vineyardId: vineyardId, remote: remote)

            let remoteIds = Set(remote.map { $0.id })
            let remoteBlocks = Set(remote.filter { $0.deletedAt == nil }.map { $0.paddockId })
            let local = store.pruningYieldSettings.filter { $0.vineyardId == vineyardId }
            // Seed push: local rows whose BLOCK has no remote record. Matching
            // by block (not row id) respects the one-record-per-block contract.
            let missing = local.filter { !remoteIds.contains($0.id) && !remoteBlocks.contains($0.paddockId) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendPruningYieldSettings.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    metadata.clearDirty(missing.map { $0.id })
                    #if DEBUG
                    print("[PruningYieldSettingsSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[PruningYieldSettingsSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemotePruningYieldSettingsDelete(item.id)
                metadata.clearDirty([item.id]); metadata.clearDeleted([item.id]); continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemotePruningYieldSettingsUpsert(item.toPruningYieldSettings())
            metadata.clearDirty([item.id])
        }
    }

    /// Pre-sql/181 the calculator saved per-block inputs to UserDefaults
    /// (`vinetrack_yield_determination_{userId}_{paddockId}`). On the first
    /// sync after upgrade, upload those values for blocks with no shared
    /// record AND no local shared record — a shared record always wins.
    private func adoptLegacyLocalSettings(vineyardId: UUID, remote: [BackendPruningYieldSettings]) {
        guard let store else { return }
        guard let userId = auth?.userId?.uuidString else { return }
        let remoteBlocks = Set(remote.filter { $0.deletedAt == nil }.map { $0.paddockId })
        let localBlocks = Set(store.pruningYieldSettings.filter { $0.vineyardId == vineyardId }.map { $0.paddockId })
        var adopted = 0
        for paddock in store.paddocks where paddock.vineyardId == vineyardId {
            guard !remoteBlocks.contains(paddock.id), !localBlocks.contains(paddock.id) else { continue }
            guard let legacy = PruningYieldSettings.legacySettings(userId: userId, paddockId: paddock.id) else { continue }
            let settings = PruningYieldSettings.fromLegacy(legacy, vineyardId: vineyardId, paddockId: paddock.id)
            store.savePruningYieldSettings(settings)
            adopted += 1
        }
        #if DEBUG
        if adopted > 0 {
            print("[PruningYieldSettingsSync] adopted \(adopted) legacy device-local block save(s)")
        }
        #endif
    }
}
