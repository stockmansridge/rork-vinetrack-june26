import Foundation
import Observation

/// Offline-first sync for Work Task Material Costs (sql/247).
///
/// Three services, mirroring the existing operations-sync pattern
/// (`WorkTaskLabourLineSyncService` / `WorkTaskMachineLineSyncService`):
///
///  * ``MaterialCatalogueSyncService``  — pull-only global base catalogue
///  * ``VineyardMaterialSyncService``   — the vineyard's library
///  * ``WorkTaskMaterialSyncService``   — the task's material lines
///
/// ## Offline durability
///
/// Every id is minted locally BEFORE any network call and is the same id the
/// server row will carry, so a create that is replayed after a crash, a
/// relaunch or a reconnect upserts the SAME row instead of producing a second
/// material line. Pending upsert/delete markers live in `OperationsSyncMetadata`
/// on disk, so a material edit made offline survives app termination and syncs
/// once connectivity returns.
///
/// ## No admin logic here
///
/// These services know nothing about System Admin. The temporary
/// System-Admin-only exposure lives entirely in `WorkTaskMaterialCostsAccess`.

// MARK: - Base catalogue (pull only)

/// Keeps the global base catalogue available offline.
///
/// The catalogue is system owned: there is no push path at all. A successful
/// server read replaces the cache; an empty or failed read leaves the previous
/// cache (or the bundled `MaterialCatalogueSeed`) in place, so a picker is
/// never blanked by a bad network moment.
@Observable
@MainActor
final class MaterialCatalogueSyncService {
    typealias Status = OperationsSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any MaterialCatalogueRepositoryProtocol

    init(repository: (any MaterialCatalogueRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseMaterialCatalogueRepository()
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
    }

    func sync() async {
        guard let store, let auth, auth.isSignedIn else { return }
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        syncStatus = .syncing
        errorMessage = nil
        do {
            let remote = try await repository.fetchCatalogue()
            // An empty read means the migration has not been applied yet.
            // Keep the bundled fallback rather than emptying every picker.
            guard !remote.isEmpty else {
                syncStatus = .success
                lastSyncDate = Date()
                return
            }
            store.applyRemoteMaterialCatalogue(remote.map { $0.toCatalogueItem() })
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }
}

// MARK: - Vineyard material library

@Observable
@MainActor
final class VineyardMaterialSyncService {
    typealias Status = OperationsSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any VineyardMaterialSyncRepositoryProtocol
    private let metadata: OperationsSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    func isPendingUpsert(_ id: UUID) -> Bool { metadata.pendingUpserts[id] != nil }

    init(repository: (any VineyardMaterialSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseVineyardMaterialSyncRepository()
        self.metadata = OperationsSyncMetadata(key: "vinetrack_vineyard_material_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onVineyardMaterialChanged = { [weak self] id in
            self?.metadata.markDirty(id, at: Date()); self?.scheduleEagerPush()
        }
        store.onVineyardMaterialDeleted = { [weak self] id in
            self?.metadata.markDeleted(id, at: Date()); self?.scheduleEagerPush()
        }
    }

    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncForSelectedVineyard()
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
        let userId = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.vineyardMaterials.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendVineyardMaterialUpsert] = []
            var pushed: [UUID] = []
            var orphans: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id] else { orphans.append(id); continue }
                payloads.append(BackendVineyardMaterial.upsert(
                    from: item, createdBy: userId, updatedBy: userId, clientUpdatedAt: ts
                ))
                pushed.append(id)
            }
            metadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            let result = await SyncQueuePush.run(
                entity: "Vineyard Materials",
                ids: pushed,
                payloads: payloads,
                queuedAt: dirty,
                vineyardId: vineyardId
            ) { try await repository.upsertMany($0) }
            metadata.clearDirty(result.uploaded)
            SyncIssueCenter.shared.notePending(entity: "Vineyard Materials", count: metadata.pendingUpserts.count)
            if let error = result.firstRetryableError { throw error }
        }
        var firstDeleteError: Error?
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isOperationsMissingRowError(error) {
                    metadata.clearDeleted([id])
                } else if firstDeleteError == nil {
                    firstDeleteError = error
                }
            }
        }
        if let firstDeleteError { throw firstDeleteError }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        let catalogue = store.materialCatalogue
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteVineyardMaterialDelete(item.id)
                metadata.clearDirty([item.id]); metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteVineyardMaterialUpsert(item.toVineyardMaterial(catalogue: catalogue))
            metadata.clearDirty([item.id])
        }
    }
}

// MARK: - Work Task material lines

@Observable
@MainActor
final class WorkTaskMaterialSyncService {
    typealias Status = OperationsSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any WorkTaskMaterialSyncRepositoryProtocol
    private let metadata: OperationsSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    func isPendingUpsert(_ id: UUID) -> Bool { metadata.pendingUpserts[id] != nil }

    /// True while ANY material line of `workTaskId` still has an unacknowledged
    /// local write — the same dependency signal the labour and machine line
    /// services expose, so a caller can tell a task's costing is still settling.
    func isPendingUpsert(forWorkTask workTaskId: UUID) -> Bool {
        guard let store else { return false }
        let lineIds = Set(
            store.workTaskMaterials
                .filter { $0.workTaskId == workTaskId }
                .map(\.id)
        )
        guard !lineIds.isEmpty else { return false }
        return metadata.pendingUpserts.keys.contains { lineIds.contains($0) }
    }

    init(repository: (any WorkTaskMaterialSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabaseWorkTaskMaterialSyncRepository()
        self.metadata = OperationsSyncMetadata(key: "vinetrack_work_task_material_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onWorkTaskMaterialChanged = { [weak self] id in
            self?.metadata.markDirty(id, at: Date()); self?.scheduleEagerPush()
        }
        store.onWorkTaskMaterialDeleted = { [weak self] id in
            self?.metadata.markDeleted(id, at: Date()); self?.scheduleEagerPush()
        }
    }

    private func scheduleEagerPush() {
        eagerPushTask?.cancel()
        eagerPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }
            await self?.syncForSelectedVineyard()
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
        let userId = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.workTaskMaterials.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendWorkTaskMaterialUpsert] = []
            var pushed: [UUID] = []
            var orphans: [UUID] = []
            for (id, ts) in dirty {
                // A queue entry whose local line no longer exists can never
                // upload; reclaim it rather than wedging the queue.
                guard let item = byId[id] else { orphans.append(id); continue }
                payloads.append(BackendWorkTaskMaterial.upsert(
                    from: item, createdBy: userId, updatedBy: userId, clientUpdatedAt: ts
                ))
                pushed.append(id)
            }
            metadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            let result = await SyncQueuePush.run(
                entity: "Work Task Materials",
                ids: pushed,
                payloads: payloads,
                queuedAt: dirty,
                vineyardId: vineyardId
            ) { try await repository.upsertMany($0) }
            metadata.clearDirty(result.uploaded)
            SyncIssueCenter.shared.notePending(entity: "Work Task Materials", count: metadata.pendingUpserts.count)
            if let error = result.firstRetryableError { throw error }
        }
        var firstDeleteError: Error?
        for (id, _) in metadata.pendingDeletes {
            do {
                try await repository.softDelete(id: id)
                metadata.clearDeleted([id])
            } catch {
                if isOperationsMissingRowError(error) {
                    // Already gone server-side — the delete intent is met.
                    metadata.clearDeleted([id])
                } else if firstDeleteError == nil {
                    firstDeleteError = error
                }
            }
        }
        if let firstDeleteError { throw firstDeleteError }
    }

    private func pull(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetch(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            // First sync for this vineyard: upload any locally-created lines
            // the server has never seen (created offline before this device
            // ever synced) so an offline-first line is never lost.
            let remoteIds = Set(remote.map { $0.id })
            let local = store.workTaskMaterials.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let userId = auth?.userId
                let payloads = missing.map {
                    BackendWorkTaskMaterial.upsert(from: $0, createdBy: userId, updatedBy: userId, clientUpdatedAt: now)
                }
                // Best effort: a failure here leaves the local lines and their
                // pending markers intact for the next attempt.
                try? await repository.upsertMany(payloads)
            }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemoteWorkTaskMaterialDelete(item.id)
                metadata.clearDirty([item.id]); metadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            store.applyRemoteWorkTaskMaterialUpsert(item.toWorkTaskMaterial())
            metadata.clearDirty([item.id])
        }
    }
}
