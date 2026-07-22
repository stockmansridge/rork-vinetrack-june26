import Foundation
import Observation

/// Local-first sync service for SprayRecord entities.
/// Tracks dirty/deleted spray records locally and pushes/pulls them against
/// Supabase using `SupabaseSprayRecordSyncRepository`. Conflict resolution is
/// last-write-wins based on `client_updated_at`/`updated_at`.
@Observable
@MainActor
final class SprayRecordSyncService {

    enum Status: Equatable, Sendable {
        case idle
        case syncing
        case success
        case failure(String)
    }

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }

    /// Whether a specific spray record has local changes queued for upload.
    func isPendingUpsert(_ id: UUID) -> Bool { metadata.pendingUpserts[id] != nil }

    /// Whether a specific spray record is queued for a remote delete.
    func isPendingDelete(_ id: UUID) -> Bool { metadata.pendingDeletes[id] != nil }

    /// True while a full sweep is actively pushing/pulling spray records.
    var isSyncing: Bool { syncStatus == .syncing }

    /// True if the last sweep failed.
    var hasFailure: Bool { if case .failure = syncStatus { return true }; return false }

    /// Whether a specific spray record's last push failed while still pending.
    /// Used for per-record error isolation so one failed record never makes
    /// others look failed. Resolves purely from this record's own state.
    func hasFailure(_ id: UUID) -> Bool { metadata.isUpsertFailed(id) || metadata.isDeleteFailed(id) }

    var failedUpsertIds: Set<UUID> { metadata.failedUpsertIds }
    var failedDeleteIds: Set<UUID> { metadata.failedDeleteIds }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any SprayRecordSyncRepositoryProtocol
    private let metadata: SprayRecordSyncMetadata
    private var isConfigured: Bool = false

    init(
        repository: (any SprayRecordSyncRepositoryProtocol)? = nil,
        metadata: SprayRecordSyncMetadata? = nil
    ) {
        self.repository = repository ?? SupabaseSprayRecordSyncRepository()
        self.metadata = metadata ?? SprayRecordSyncMetadata()
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onSprayRecordChanged = { [weak self] id in
            self?.markSprayRecordDirty(id)
        }
        store.onSprayRecordDeleted = { [weak self] id in
            self?.markSprayRecordDeleted(id)
        }
    }

    // MARK: - Dirty tracking

    func markSprayRecordDirty(_ id: UUID) {
        metadata.markDirty(id, at: Date())
    }

    func markSprayRecordDeleted(_ id: UUID) {
        metadata.markDeleted(id, at: Date())
    }

    // MARK: - Public sync entry points

    func syncSprayRecordsForSelectedVineyard() async {
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
            try await pushLocalSprayRecords(vineyardId: vineyardId)
            try await pullRemoteSprayRecords(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Push

    func pushLocalSprayRecords(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.sprayRecords.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendSprayRecordUpsert] = []
            var pushedIds: [UUID] = []
            for (recordId, ts) in dirty {
                guard let record = byId[recordId], record.vineyardId == vineyardId else { continue }
                payloads.append(BackendSprayRecord.upsert(from: record, createdBy: createdBy, clientUpdatedAt: ts))
                pushedIds.append(recordId)
            }
            if !payloads.isEmpty {
                do {
                    try await repository.upsertSprayRecords(payloads)
                    metadata.clearDirty(pushedIds)
                } catch {
                    metadata.markUpsertsFailed(pushedIds)
                    throw error
                }
            }
        }

        let deletes = metadata.pendingDeletes
        var deleteFailures: [String] = []
        for (recordId, _) in deletes {
            do {
                try await repository.softDeleteSprayRecord(id: recordId)
                metadata.clearDeleted([recordId])
            } catch {
                if Self.isMissingRowError(error) {
                    metadata.clearDeleted([recordId])
                    #if DEBUG
                    print("[SprayRecordSync] soft delete: remote record \(recordId) already missing — clearing pending delete")
                    #endif
                } else {
                    #if DEBUG
                    print("[SprayRecordSync] soft delete failed for \(recordId): \(error.localizedDescription)")
                    #endif
                    metadata.markDeletesFailed([recordId])
                    deleteFailures.append(error.localizedDescription)
                    continue
                }
            }
        }
        if !deleteFailures.isEmpty {
            errorMessage = "Some spray record deletes failed: \(deleteFailures.first ?? "unknown")"
        }
    }

    private static func isMissingRowError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        if message.contains("spray record not found") { return true }
        if message.contains("record not found") { return true }
        if message.contains("not found") { return true }
        if message.contains("pgrst116") { return true }
        if message.contains("no rows") { return true }
        if message.contains("0 rows") { return true }
        return false
    }

    // MARK: - Pull

    func pullRemoteSprayRecords(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchSprayRecords(vineyardId: vineyardId, since: lastSync)

        // Initial sync: if remote is empty AND we have local records AND we have
        // never synced before, push them all up.
        if remote.isEmpty, lastSync == nil {
            let localForVineyard = store.sprayRecords.filter { $0.vineyardId == vineyardId }
            if !localForVineyard.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = localForVineyard.map {
                    BackendSprayRecord.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now)
                }
                try await repository.upsertSprayRecords(payloads)
            }
            return
        }

        for backendRecord in remote {
            applyRemote(backendRecord, vineyardId: vineyardId, store: store)
        }
    }

    private func applyRemote(_ backendRecord: BackendSprayRecord, vineyardId: UUID, store: MigratedDataStore) {
        // Soft-deleted remotely.
        if backendRecord.deletedAt != nil {
            store.applyRemoteSprayRecordDelete(backendRecord.id)
            metadata.clearDirty([backendRecord.id])
            metadata.clearDeleted([backendRecord.id])
            return
        }

        // Last-write-wins: only apply remote if it's newer than the local pending change.
        if let pendingDirtyAt = metadata.pendingUpserts[backendRecord.id] {
            let remoteAt = backendRecord.clientUpdatedAt ?? backendRecord.updatedAt ?? .distantPast
            if pendingDirtyAt > remoteAt { return }
        }

        let mapped = backendRecord.toSprayRecord()
        store.applyRemoteSprayRecordUpsert(mapped)
        metadata.clearDirty([backendRecord.id])
    }
}

// MARK: - Metadata

@MainActor
final class SprayRecordSyncMetadata {
    private let persistence: PersistenceStore
    private let key: String = "vinetrack_spray_record_sync_metadata"
    private var state: State

    nonisolated struct State: Codable, Sendable {
        var lastSyncByVineyard: [UUID: Date] = [:]
        var pendingUpserts: [UUID: Date] = [:]
        var pendingDeletes: [UUID: Date] = [:]
        /// Records whose last upsert/delete push failed while still pending.
        var failedUpserts: Set<UUID> = []
        var failedDeletes: Set<UUID> = []
    }

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
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
