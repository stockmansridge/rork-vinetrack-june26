import Foundation

/// Sync service for the Detailed picking log (`public.picking_records`,
/// sql/180). Same push→pull, last-write-wins pattern as
/// `HistoricalYieldRecordSyncService`.
@Observable
@MainActor
final class PickingRecordSyncService {
    typealias Status = OperationsSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }
    private let repository: any PickingRecordSyncRepositoryProtocol
    private let metadata: OperationsSyncMetadata
    private var isConfigured: Bool = false

    init(repository: (any PickingRecordSyncRepositoryProtocol)? = nil) {
        self.repository = repository ?? SupabasePickingRecordSyncRepository()
        self.metadata = OperationsSyncMetadata(key: "vinetrack_picking_record_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onPickingRecordChanged = { [weak self] id in self?.metadata.markDirty(id, at: Date()) }
        store.onPickingRecordDeleted = { [weak self] id in self?.metadata.markDeleted(id, at: Date()) }
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
            let byId = Dictionary(store.pickingRecords.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendPickingRecordUpsert] = []
            var pushed: [UUID] = []
            var orphans: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id] else { orphans.append(id); continue }
                payloads.append(BackendPickingRecord.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            metadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            let result = await SyncQueuePush.run(
                entity: "Picking Records",
                ids: pushed,
                payloads: payloads,
                queuedAt: dirty,
                vineyardId: vineyardId
            ) { try await repository.upsertMany($0) }
            metadata.clearDirty(result.uploaded)
            SyncIssueCenter.shared.notePending(entity: "Picking Records", count: metadata.pendingUpserts.count)
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
        // Always pull the FULL vineyard slice (audit #4). An incremental
        // cursor of `updated_at >= lastSync` compares the server's updated_at
        // against the device clock captured at the end of the previous sync —
        // a device clock running ahead of the server (or a portal row
        // committing while a pull is in flight) would fall permanently behind
        // the cursor and never be fetched again. Per-vineyard picking volume
        // is small, upserts are idempotent and deletes are tombstoned
        // (`deleted_at`), so a full fetch is safe and self-healing — the same
        // correction already used by the labour/machine-line sync services.
        // `lastSync` is kept solely to detect the one-time initial seed below.
        let remote = try await repository.fetch(vineyardId: vineyardId, since: nil)
        // Owner/manager commercial projection (sql/187): the base columns read
        // back NULL for every role, so money is merged from the gated RPC.
        // Lower roles fail the RPC (42501) — swallowed, masked NULLs kept.
        let financials = (try? await repository.fetchFinancials(vineyardId: vineyardId)) ?? []
        let financialsById = Dictionary(financials.map { ($0.pickingRecordId, $0) }, uniquingKeysWith: { a, _ in a })
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = store.pickingRecords.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendPickingRecord.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                do {
                    try await repository.upsertMany(payloads)
                    #if DEBUG
                    print("[PickingRecordSync] initial seed pushed \(payloads.count) local row(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[PickingRecordSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemotePickingRecordDelete(item.id)
                metadata.clearDirty([item.id]); metadata.clearDeleted([item.id]); continue
            }
            if let pendingAt = metadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            var record = item.toPickingRecord()
            if let row = financialsById[record.id] {
                record.soldTo = row.soldTo
                record.pricePerTonne = row.pricePerTonne
            }
            store.applyRemotePickingRecordUpsert(record)
            metadata.clearDirty([item.id])
        }
    }
}
