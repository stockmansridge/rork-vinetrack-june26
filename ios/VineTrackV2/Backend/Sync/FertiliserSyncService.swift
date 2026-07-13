import Foundation
import Observation

/// Sync service for the Fertiliser Calculator (System Admin only while in
/// development). Standard management-sync template over three tables:
/// `fertiliser_products`, `fertiliser_records` and the per-block
/// `fertiliser_record_allocations` child rows (pushed with their record,
/// pulled and re-attached by record id).
@Observable
@MainActor
final class FertiliserSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int {
        productMetadata.pendingUpserts.count + recordMetadata.pendingUpserts.count
    }
    var pendingDeleteCount: Int {
        productMetadata.pendingDeletes.count + recordMetadata.pendingDeletes.count
    }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let fertStore: FertiliserStore
    private let repository: any FertiliserSyncRepositoryProtocol
    private let productMetadata: ManagementSyncMetadata
    private let recordMetadata: ManagementSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    init(repository: (any FertiliserSyncRepositoryProtocol)? = nil, fertStore: FertiliserStore? = nil) {
        self.repository = repository ?? SupabaseFertiliserSyncRepository()
        self.fertStore = fertStore ?? .shared
        self.productMetadata = ManagementSyncMetadata(key: "vinetrack_fertiliser_product_sync_metadata")
        self.recordMetadata = ManagementSyncMetadata(key: "vinetrack_fertiliser_record_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        fertStore.onProductChanged = { [weak self] id in
            self?.productMetadata.markDirty(id, at: Date())
            self?.scheduleEagerPush()
        }
        fertStore.onProductDeleted = { [weak self] id in
            self?.productMetadata.markDeleted(id, at: Date())
            self?.scheduleEagerPush()
        }
        fertStore.onRecordChanged = { [weak self] id in
            self?.recordMetadata.markDirty(id, at: Date())
            self?.scheduleEagerPush()
        }
        fertStore.onRecordDeleted = { [weak self] id in
            self?.recordMetadata.markDeleted(id, at: Date())
            self?.scheduleEagerPush()
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
            try await pushProducts(vineyardId: vineyardId)
            try await pushRecords(vineyardId: vineyardId)
            try await pullProducts(vineyardId: vineyardId)
            try await pullRecords(vineyardId: vineyardId)
            productMetadata.setLastSync(Date(), for: vineyardId)
            recordMetadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: Push

    private func pushProducts(vineyardId: UUID) async throws {
        let createdBy = auth?.userId
        let dirty = productMetadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(fertStore.products.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendFertiliserProductUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendFertiliserProduct.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertProducts(payloads)
                productMetadata.clearDirty(pushed)
            }
        }
        for (id, _) in productMetadata.pendingDeletes {
            do {
                try await repository.softDeleteProduct(id: id)
                productMetadata.clearDeleted([id])
            } catch {
                if isFertiliserMissingRowError(error) { productMetadata.clearDeleted([id]) }
            }
        }
    }

    private func pushRecords(vineyardId: UUID) async throws {
        let createdBy = auth?.userId
        let dirty = recordMetadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(fertStore.records.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var recordPayloads: [BackendFertiliserRecordUpsert] = []
            var allocationPayloads: [BackendFertiliserAllocation] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                recordPayloads.append(BackendFertiliserRecord.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                allocationPayloads.append(contentsOf: item.allocations.map {
                    BackendFertiliserAllocation.upsert(from: $0, record: item)
                })
                pushed.append(id)
            }
            if !recordPayloads.isEmpty {
                try await repository.upsertRecords(recordPayloads)
                try await repository.upsertAllocations(allocationPayloads)
                recordMetadata.clearDirty(pushed)
            }
        }
        for (id, _) in recordMetadata.pendingDeletes {
            do {
                try await repository.softDeleteRecord(id: id)
                recordMetadata.clearDeleted([id])
            } catch {
                if isFertiliserMissingRowError(error) { recordMetadata.clearDeleted([id]) }
            }
        }
    }

    // MARK: Pull

    private func pullProducts(vineyardId: UUID) async throws {
        let lastSync = productMetadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchProducts(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = fertStore.products.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendFertiliserProduct.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                try? await repository.upsertProducts(payloads)
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                fertStore.applyRemoteProductDelete(item.id)
                productMetadata.clearDirty([item.id])
                productMetadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = productMetadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            fertStore.applyRemoteProductUpsert(item.toFertiliserProduct())
            productMetadata.clearDirty([item.id])
        }
    }

    private func pullRecords(vineyardId: UUID) async throws {
        let lastSync = recordMetadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchRecords(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = fertStore.records.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let recordPayloads = missing.map { BackendFertiliserRecord.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                let allocationPayloads = missing.flatMap { record in
                    record.allocations.map { BackendFertiliserAllocation.upsert(from: $0, record: record) }
                }
                do {
                    try await repository.upsertRecords(recordPayloads)
                    try await repository.upsertAllocations(allocationPayloads)
                } catch {
                    #if DEBUG
                    print("[FertiliserSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }

        let allocations = try await repository.fetchAllocations(vineyardId: vineyardId)
        let allocationsByRecord = Dictionary(grouping: allocations, by: { $0.fertiliserRecordId })

        for item in remote {
            if item.deletedAt != nil {
                fertStore.applyRemoteRecordDelete(item.id)
                recordMetadata.clearDirty([item.id])
                recordMetadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = recordMetadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            let attached = (allocationsByRecord[item.id] ?? []).map { $0.toFertiliserAllocation() }
            fertStore.applyRemoteRecordUpsert(item.toFertiliserRecord(allocations: attached))
            recordMetadata.clearDirty([item.id])
        }
    }
}

private func isFertiliserMissingRowError(_ error: Error) -> Bool {
    let message = String(describing: error).lowercased()
    if message.contains("not found") { return true }
    if message.contains("pgrst116") { return true }
    if message.contains("no rows") { return true }
    if message.contains("0 rows") { return true }
    return false
}
