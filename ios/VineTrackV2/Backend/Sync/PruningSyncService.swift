import Foundation
import Observation

/// Sync service for the Pruning Tracker (System Admin only while in
/// development). Follows the management-sync template with two twists:
///
/// * Entries + quarters are written through the idempotent
///   `record_pruning_entry` RPC — never direct table writes — so replaying a
///   queued entry can never double-count a quarter, and a quarter completed
///   first on another device stays with that device's entry.
/// * After every pull the server's `pruning_row_segments` attribution is
///   re-applied to local entries. A completed quarter can only revert through
///   the explicit `delete_pruning_entry` action, never a stale-sync overwrite.
@Observable
@MainActor
final class PruningSyncService {
    typealias Status = ManagementSyncStatus

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int {
        seasonMetadata.pendingUpserts.count + entryMetadata.pendingUpserts.count
    }
    var pendingDeleteCount: Int {
        seasonMetadata.pendingDeletes.count + entryMetadata.pendingDeletes.count
    }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let pruningStore: PruningStore
    private let repository: any PruningSyncRepositoryProtocol
    private let seasonMetadata: ManagementSyncMetadata
    private let entryMetadata: ManagementSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    init(repository: (any PruningSyncRepositoryProtocol)? = nil, pruningStore: PruningStore? = nil) {
        self.repository = repository ?? SupabasePruningSyncRepository()
        self.pruningStore = pruningStore ?? .shared
        self.seasonMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_season_sync_metadata")
        self.entryMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_entry_sync_metadata")
    }

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        pruningStore.onSeasonChanged = { [weak self] id in
            self?.seasonMetadata.markDirty(id, at: Date())
            self?.scheduleEagerPush()
        }
        pruningStore.onSeasonDeleted = { [weak self] id in
            self?.seasonMetadata.markDeleted(id, at: Date())
            self?.scheduleEagerPush()
        }
        pruningStore.onEntryRecorded = { [weak self] id in
            self?.entryMetadata.markDirty(id, at: Date())
            self?.scheduleEagerPush()
        }
        pruningStore.onEntryDeleted = { [weak self] id in
            self?.entryMetadata.markDeleted(id, at: Date())
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
            try await pushSeasons(vineyardId: vineyardId)
            try await pushEntries(vineyardId: vineyardId)
            try await pullSeasons(vineyardId: vineyardId)
            try await pullEntriesAndSegments(vineyardId: vineyardId)
            seasonMetadata.setLastSync(Date(), for: vineyardId)
            entryMetadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: Push

    private func pushSeasons(vineyardId: UUID) async throws {
        let createdBy = auth?.userId
        let dirty = seasonMetadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(pruningStore.setups.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendPruningSeasonUpsert] = []
            var pushed: [UUID] = []
            for (id, ts) in dirty {
                guard let item = byId[id], item.vineyardId == vineyardId else { continue }
                payloads.append(BackendPruningSeason.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts))
                pushed.append(id)
            }
            if !payloads.isEmpty {
                try await repository.upsertSeasons(payloads)
                seasonMetadata.clearDirty(pushed)
            }
        }
        for (id, _) in seasonMetadata.pendingDeletes {
            do {
                try await repository.softDeleteSeason(id: id)
                seasonMetadata.clearDeleted([id])
            } catch {
                if isPruningMissingRowError(error) { seasonMetadata.clearDeleted([id]) }
            }
        }
    }

    private func pushEntries(vineyardId: UUID) async throws {
        let dirty = entryMetadata.pendingUpserts
        var firstError: Error?
        if !dirty.isEmpty {
            let byId = Dictionary(pruningStore.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for (id, ts) in dirty {
                guard let entry = byId[id] else {
                    entryMetadata.clearDirty([id])
                    continue
                }
                guard entry.vineyardId == vineyardId else { continue }
                do {
                    try await repository.recordEntry(RecordPruningEntryParams(from: entry, clientUpdatedAt: ts))
                    entryMetadata.clearDirty([id])
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        for (id, _) in entryMetadata.pendingDeletes {
            do {
                try await repository.deleteEntry(id: id)
                entryMetadata.clearDeleted([id])
            } catch {
                if isPruningMissingRowError(error) {
                    entryMetadata.clearDeleted([id])
                } else if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: Pull

    private func pullSeasons(vineyardId: UUID) async throws {
        let lastSync = seasonMetadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchSeasons(vineyardId: vineyardId, since: lastSync)
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = pruningStore.setups.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map { BackendPruningSeason.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now) }
                try? await repository.upsertSeasons(payloads)
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                pruningStore.applyRemoteSeasonDelete(item.id)
                seasonMetadata.clearDirty([item.id])
                seasonMetadata.clearDeleted([item.id])
                continue
            }
            if let pendingAt = seasonMetadata.pendingUpserts[item.id] {
                let remoteAt = item.clientUpdatedAt ?? item.updatedAt ?? .distantPast
                if pendingAt > remoteAt { continue }
            }
            pruningStore.applyRemoteSeasonUpsert(item.toPruningBlockSetup())
            seasonMetadata.clearDirty([item.id])
        }
    }

    private func pullEntriesAndSegments(vineyardId: UUID) async throws {
        let lastSync = entryMetadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchEntries(vineyardId: vineyardId, since: lastSync)

        // Initial sync: push local entries the server has never seen (the RPC
        // is idempotent, so replaying is always safe).
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let local = pruningStore.entries.filter { $0.vineyardId == vineyardId }
            let missing = local.filter { !remoteIds.contains($0.id) && entryMetadata.pendingUpserts[$0.id] == nil }
            let now = Date()
            for entry in missing {
                try? await repository.recordEntry(RecordPruningEntryParams(from: entry, clientUpdatedAt: now))
            }
        }

        for item in remote {
            if item.deletedAt != nil {
                pruningStore.applyRemoteEntryDelete(item.id)
                entryMetadata.clearDirty([item.id])
                entryMetadata.clearDeleted([item.id])
                continue
            }
            if entryMetadata.pendingUpserts[item.id] != nil { continue }
            pruningStore.applyRemoteEntryUpsert(item.toPruningEntry())
        }

        // Server segment attribution is the truth for completed quarters.
        let segments = try await repository.fetchSegments(vineyardId: vineyardId)
        var byEntry: [UUID: [PruningSegment]] = [:]
        for segment in segments where (segment.completed ?? false) {
            guard let entryId = segment.pruningEntryId else { continue }
            byEntry[entryId, default: []].append(
                PruningSegment(rowId: segment.paddockRowId, row: segment.rowNumber, quarter: segment.segmentNumber)
            )
        }
        pruningStore.applyRemoteSegmentAttribution(
            vineyardId: vineyardId,
            segmentsByEntry: byEntry,
            protectedIds: Set(entryMetadata.pendingUpserts.keys)
        )
    }
}

private func isPruningMissingRowError(_ error: Error) -> Bool {
    let message = String(describing: error).lowercased()
    if message.contains("not found") { return true }
    if message.contains("pgrst116") { return true }
    if message.contains("no rows") { return true }
    if message.contains("0 rows") { return true }
    return false
}
