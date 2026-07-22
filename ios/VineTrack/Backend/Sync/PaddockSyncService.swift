import Foundation
import Observation

/// Local-first sync service for Paddock records.
/// Tracks dirty/deleted paddocks locally and pushes/pulls them against Supabase
/// using `SupabasePaddockSyncRepository`. Conflict resolution is last-write-wins
/// based on `client_updated_at`/`updated_at`.
@Observable
@MainActor
final class PaddockSyncService {

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

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any PaddockSyncRepositoryProtocol
    private let metadata: PaddockSyncMetadata
    private var isConfigured: Bool = false
    private var needsForceRepushMigration: Bool = false
    /// When true, the next `sync(vineyardId:)` pulls remote paddocks BEFORE
    /// pushing local changes, so any stale local `variety_allocations`
    /// don't overwrite server data that was repaired by the grape variety
    /// canonicalisation SQL migrations (067/068/069/070).
    private var pendingPullFirstAfterVarietyRepair: Bool = false

    init(
        repository: (any PaddockSyncRepositoryProtocol)? = nil,
        metadata: PaddockSyncMetadata? = nil
    ) {
        self.repository = repository ?? SupabasePaddockSyncRepository()
        self.metadata = metadata ?? PaddockSyncMetadata()

        // One-time recovery: paddocks created/edited before newer columns
        // (e.g. intermediate_post_spacing) were wired into the upsert payload
        // may sit in Supabase without those values, so other devices pull
        // incomplete rows. Reset lastSync once and force-mark all local
        // paddocks dirty in configure(...) so they get re-pushed with the
        // current schema.
        let migrationKey = "vinetrack_paddock_sync_reset_v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            self.metadata.resetAllLastSync()
            self.needsForceRepushMigration = true
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        // One-time follow-up: after the server-side grape variety
        // canonicalisation/repair (SQL 067/068/069/070), iOS devices may
        // still hold pre-repair paddock allocations cached locally with
        // stale `varietyId`s and missing `name` snapshots. Reset lastSync
        // once so the next sync pulls the repaired `variety_allocations`
        // JSON for every vineyard, even when the local `updated_at` is
        // already past the server's repaired timestamps.
        // NOTE: v1 of this key did not also clear pending dirty paddocks
        // and ran push-before-pull, so stale local `variety_allocations`
        // could overwrite server data that had just been repaired by
        // SQL 067-070. v2 fixes both: it clears any pending upserts that
        // existed at the moment the variety repair landed AND defers the
        // push-first ordering until after a fresh pull.
        let varietyRepullKey = "vinetrack_paddock_sync_variety_repull_v2"
        if !UserDefaults.standard.bool(forKey: varietyRepullKey) {
            self.metadata.resetAllLastSync()
            self.metadata.clearAllPendingUpserts()
            self.pendingPullFirstAfterVarietyRepair = true
            UserDefaults.standard.set(true, forKey: varietyRepullKey)
            #if DEBUG
            print("[PaddockSync] variety-repair re-pull v2: cleared lastSync + pending upserts, will pull before push on next sync")
            #endif
        }
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        guard !isConfigured else { return }
        isConfigured = true
        store.onPaddockChanged = { [weak self] id in
            self?.markPaddockDirty(id)
        }
        store.onPaddockDeleted = { [weak self] id in
            self?.markPaddockDeleted(id)
        }
        if needsForceRepushMigration {
            needsForceRepushMigration = false
            let now = Date()
            for paddock in store.paddocks {
                metadata.markDirty(paddock.id, at: now)
            }
            #if DEBUG
            print("[PaddockSync] force-repush migration: marked \(store.paddocks.count) paddock(s) dirty for re-push")
            #endif
        }
    }

    // MARK: - Dirty tracking

    func markPaddockDirty(_ id: UUID) {
        metadata.markDirty(id, at: Date())
    }

    func markPaddockDeleted(_ id: UUID) {
        metadata.markDeleted(id, at: Date())
    }

    // MARK: - Public sync entry points

    func syncPaddocksForSelectedVineyard() async {
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
            if pendingPullFirstAfterVarietyRepair {
                // First sync after the variety-repair migration: pull the
                // canonicalised server rows BEFORE pushing anything local,
                // so we don't clobber the repaired `variety_allocations`.
                pendingPullFirstAfterVarietyRepair = false
                try await pullRemotePaddocks(vineyardId: vineyardId)
                try await pushLocalPaddocks(vineyardId: vineyardId)
                try await pullRemotePaddocks(vineyardId: vineyardId)
            } else {
                try await pushLocalPaddocks(vineyardId: vineyardId)
                try await pullRemotePaddocks(vineyardId: vineyardId)
            }
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    // MARK: - Force refresh helpers (admin / diagnostics)

    /// Result of a manual force refresh, surfaced to Sync Diagnostics.
    struct ForceRefreshResult: Sendable, Equatable {
        let vineyardId: UUID
        let pulled: Int
        let appliedUpserts: Int
        let appliedDeletes: Int
        let error: String?
    }

    /// Drop the `lastSync` watermark for the given vineyard and re-pull
    /// every paddock from Supabase. Does NOT push local changes — useful
    /// when local rows are suspected stale (e.g. after a server-side
    /// canonicalisation repair) and we need authoritative server data.
    @discardableResult
    func forceRepullAllPaddocks(vineyardId: UUID) async -> ForceRefreshResult {
        guard let store, SupabaseClientProvider.shared.isConfigured else {
            return ForceRefreshResult(
                vineyardId: vineyardId,
                pulled: 0,
                appliedUpserts: 0,
                appliedDeletes: 0,
                error: "Supabase not configured"
            )
        }
        syncStatus = .syncing
        errorMessage = nil
        do {
            metadata.resetAllLastSync()
            let remote = try await repository.fetchAllPaddocks(vineyardId: vineyardId)
            var upserts = 0
            var deletes = 0
            let remoteIds = Set(remote.map { $0.id })
            for backendPaddock in remote {
                if backendPaddock.deletedAt != nil {
                    store.applyRemotePaddockDelete(backendPaddock.id)
                    metadata.clearDirty([backendPaddock.id])
                    metadata.clearDeleted([backendPaddock.id])
                    deletes += 1
                } else {
                    // Force-apply: ignore pending dirty so the server row wins.
                    let mapped = backendPaddock.toPaddock()
                    store.applyRemotePaddockUpsert(mapped)
                    metadata.clearDirty([backendPaddock.id])
                    upserts += 1
                }
            }
            // Sweep hard-deleted local paddocks (no longer present remotely).
            let pendingLocalCreates = Set(metadata.pendingUpserts.keys)
            for local in store.paddocks where local.vineyardId == vineyardId {
                if remoteIds.contains(local.id) { continue }
                if pendingLocalCreates.contains(local.id) { continue }
                store.applyRemotePaddockDelete(local.id)
                metadata.clearDirty([local.id])
                metadata.clearDeleted([local.id])
                deletes += 1
            }
            GrapeVarietyCanonicalization.run(store: store)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
            return ForceRefreshResult(
                vineyardId: vineyardId,
                pulled: remote.count,
                appliedUpserts: upserts,
                appliedDeletes: deletes,
                error: nil
            )
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
            return ForceRefreshResult(
                vineyardId: vineyardId,
                pulled: 0,
                appliedUpserts: 0,
                appliedDeletes: 0,
                error: error.localizedDescription
            )
        }
    }

    /// Re-fetch a single paddock by id from Supabase and apply it
    /// authoritatively (server wins). Used by `EditPaddockSheet` as a
    /// safe fallback when a local allocation has no usable name snapshot
    /// and resolves to "no-match".
    @discardableResult
    func refreshPaddock(id paddockId: UUID, vineyardId: UUID) async -> Bool {
        guard let store, SupabaseClientProvider.shared.isConfigured else { return false }
        do {
            let remote = try await repository.fetchAllPaddocks(vineyardId: vineyardId)
            guard let match = remote.first(where: { $0.id == paddockId }) else { return false }
            if match.deletedAt != nil {
                store.applyRemotePaddockDelete(match.id)
            } else {
                let mapped = match.toPaddock()
                store.applyRemotePaddockUpsert(mapped)
                metadata.clearDirty([match.id])
                GrapeVarietyCanonicalization.run(store: store)
            }
            return true
        } catch {
            #if DEBUG
            print("[PaddockSync] refreshPaddock(\(paddockId)) failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    // MARK: - Push

    func pushLocalPaddocks(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.paddocks.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var payloads: [BackendPaddockUpsert] = []
            var pushedIds: [UUID] = []
            for (paddockId, ts) in dirty {
                guard let paddock = byId[paddockId], paddock.vineyardId == vineyardId else { continue }
                payloads.append(BackendPaddock.upsert(from: paddock, createdBy: createdBy, clientUpdatedAt: ts))
                pushedIds.append(paddockId)
            }
            if !payloads.isEmpty {
                try await repository.upsertPaddocks(payloads)
                metadata.clearDirty(pushedIds)
            }
        }

        let deletes = metadata.pendingDeletes
        var deleteFailures: [String] = []
        for (paddockId, _) in deletes {
            do {
                try await repository.softDeletePaddock(id: paddockId)
                metadata.clearDeleted([paddockId])
            } catch {
                if Self.isMissingRowError(error) {
                    metadata.clearDeleted([paddockId])
                    #if DEBUG
                    print("[PaddockSync] soft delete: remote paddock \(paddockId) already missing — clearing pending delete")
                    #endif
                } else {
                    #if DEBUG
                    print("[PaddockSync] soft delete failed for \(paddockId): \(error.localizedDescription)")
                    #endif
                    deleteFailures.append(error.localizedDescription)
                    continue
                }
            }
        }
        if !deleteFailures.isEmpty {
            errorMessage = "Some block deletes failed: \(deleteFailures.first ?? "unknown")"
        }
    }

    private static func isMissingRowError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        if message.contains("paddock not found") { return true }
        if message.contains("not found") { return true }
        if message.contains("pgrst116") { return true }
        if message.contains("no rows") { return true }
        if message.contains("0 rows") { return true }
        return false
    }

    // MARK: - Pull

    func pullRemotePaddocks(vineyardId: UUID) async throws {
        guard let store else { return }
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchPaddocks(vineyardId: vineyardId, since: lastSync)

        // Initial sync: push any local paddocks that don't yet exist remotely.
        // Previously this only ran when `remote.isEmpty`, which missed the
        // partial-remote case where some local paddocks were already pushed
        // but others (or newer fields) were never persisted to Supabase.
        if lastSync == nil {
            let remoteIds = Set(remote.map { $0.id })
            let localForVineyard = store.paddocks.filter { $0.vineyardId == vineyardId }
            let missing = localForVineyard.filter { !remoteIds.contains($0.id) }
            if !missing.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = missing.map {
                    BackendPaddock.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now)
                }
                do {
                    try await repository.upsertPaddocks(payloads)
                    #if DEBUG
                    print("[PaddockSync] initial seed pushed \(payloads.count) local paddock(s) missing remotely")
                    #endif
                } catch {
                    #if DEBUG
                    print("[PaddockSync] initial seed push failed: \(error.localizedDescription)")
                    #endif
                }
            }
            if remote.isEmpty { return }
        }

        for backendPaddock in remote {
            applyRemote(backendPaddock, vineyardId: vineyardId, store: store)
        }

        // Reconcile against the authoritative remote id set. Catches:
        //   * hard deletes (row removed entirely on Supabase) — incremental
        //     pull can never see these because `fetchPaddocks(since:)` only
        //     returns rows that still exist.
        //   * soft deletes whose `updated_at` predates `lastSync` for any
        //     reason (defensive — the `paddocks_set_updated_at` trigger
        //     normally bumps it, but we don't want to rely on that alone).
        // Local rows that haven't been pushed yet (pendingUpserts) are
        // preserved so we don't delete a freshly-created local paddock that
        // is still in flight.
        do {
            let idRows = try await repository.fetchPaddockIds(vineyardId: vineyardId)
            let liveRemoteIds = Set(idRows.filter { $0.deletedAt == nil }.map { $0.id })
            let pendingLocalCreates = Set(metadata.pendingUpserts.keys)
            let localForVineyard = store.paddocks.filter { $0.vineyardId == vineyardId }
            var sweptHardDeletes = 0
            var sweptSoftDeletes = 0
            for local in localForVineyard {
                if liveRemoteIds.contains(local.id) { continue }
                if pendingLocalCreates.contains(local.id) { continue }
                store.applyRemotePaddockDelete(local.id)
                metadata.clearDirty([local.id])
                metadata.clearDeleted([local.id])
                if idRows.contains(where: { $0.id == local.id }) {
                    sweptSoftDeletes += 1
                } else {
                    sweptHardDeletes += 1
                }
            }
            #if DEBUG
            if sweptHardDeletes > 0 || sweptSoftDeletes > 0 {
                print("[PaddockSync] reconciliation removed \(sweptHardDeletes) hard-deleted and \(sweptSoftDeletes) soft-deleted local paddock(s)")
            }
            #endif
        } catch {
            #if DEBUG
            print("[PaddockSync] reconciliation id-sweep failed: \(error.localizedDescription)")
            #endif
        }

        // After a pull, re-run the local grape variety canonicalisation
        // pass. Pulled paddocks may carry repaired `variety_allocations`
        // from the server (deterministic ids + backfilled names) which
        // the local master variety list also needs to converge on, and
        // any stale local allocations get repaired by id/name match.
        if !remote.isEmpty {
            GrapeVarietyCanonicalization.run(store: store)
        }
    }

    private func applyRemote(_ backendPaddock: BackendPaddock, vineyardId: UUID, store: MigratedDataStore) {
        // Soft-deleted remotely.
        if backendPaddock.deletedAt != nil {
            store.applyRemotePaddockDelete(backendPaddock.id)
            metadata.clearDirty([backendPaddock.id])
            metadata.clearDeleted([backendPaddock.id])
            return
        }

        // Last-write-wins: only apply remote if it's newer than the local pending change.
        if let pendingDirtyAt = metadata.pendingUpserts[backendPaddock.id] {
            let remoteAt = backendPaddock.clientUpdatedAt ?? backendPaddock.updatedAt ?? .distantPast
            if pendingDirtyAt > remoteAt { return }
        }

        let mapped = backendPaddock.toPaddock()
        store.applyRemotePaddockUpsert(mapped)
        metadata.clearDirty([backendPaddock.id])
    }
}

// MARK: - Metadata

@MainActor
final class PaddockSyncMetadata {
    private let persistence: PersistenceStore
    private let key: String = "vinetrack_paddock_sync_metadata"
    private var state: State

    nonisolated struct State: Codable, Sendable {
        var lastSyncByVineyard: [UUID: Date] = [:]
        var pendingUpserts: [UUID: Date] = [:]
        var pendingDeletes: [UUID: Date] = [:]
    }

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
    }

    var pendingUpserts: [UUID: Date] { state.pendingUpserts }
    var pendingDeletes: [UUID: Date] { state.pendingDeletes }

    func lastSync(for vineyardId: UUID) -> Date? {
        state.lastSyncByVineyard[vineyardId]
    }

    func setLastSync(_ date: Date, for vineyardId: UUID) {
        state.lastSyncByVineyard[vineyardId] = date
        save()
    }

    func markDirty(_ id: UUID, at date: Date) {
        state.pendingUpserts[id] = date
        save()
    }

    func markDeleted(_ id: UUID, at date: Date) {
        state.pendingUpserts.removeValue(forKey: id)
        state.pendingDeletes[id] = date
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

    /// One-time migration helper: clear all stored lastSync timestamps so the
    /// next sync is treated as a fresh initial sync. Does NOT touch local
    /// paddock data or pending dirty/delete sets.
    func resetAllLastSync() {
        state.lastSyncByVineyard = [:]
        save()
    }

    /// Clear every pending dirty upsert. Used by the variety-repair
    /// migration so we don't re-push stale local `variety_allocations`
    /// that were superseded by the server-side canonicalisation.
    func clearAllPendingUpserts() {
        state.pendingUpserts = [:]
        save()
    }

    private func save() {
        persistence.save(state, key: key)
    }
}
