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

    // MARK: sql/198 revision conflicts

    /// Block configurations whose last write the server REFUSED on revision grounds. The
    /// grower's authored values are still queued; nothing here resolves a conflict
    /// automatically.
    var conflictedIds: Set<UUID> { metadata.conflictedIds }

    /// The unresolved conflict for a block configuration, if any. Survives app restarts.
    func revisionConflict(id: UUID) -> SyncRevisionConflictMark? {
        metadata.revisionConflict(for: id)
    }

    /// RE-FETCHES the server's current row for a conflicted block configuration.
    ///
    /// Deliberately a fresh read rather than a stored side-by-side copy: a cached "server
    /// version" starts drifting the moment it is written. The LOCAL authored copy is the half
    /// that must survive, and that lives in the store plus the queue.
    func serverCopyOfSettings(id: UUID, vineyardId: UUID) async -> PruningYieldSettings? {
        guard let remote = try? await repository.fetch(vineyardId: vineyardId, since: nil) else { return nil }
        return remote.first { $0.id == id && $0.deletedAt == nil }?.toPruningYieldSettings()
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

    /// Pushes queued block configurations under the sql/198 revision contract.
    ///
    /// ONE REQUEST PER BLOCK. The batch upsert this replaced was a single transaction, so one
    /// conflicting block would have aborted every other block's write in the same call.
    private func push(vineyardId: UUID) async throws {
        guard let store else { return }
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.pruningYieldSettings.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let conflicted = metadata.conflictedIds
            var orphans: [UUID] = []
            var firstRetryableError: Error?
            for (id, ts) in dirty {
                guard let item = byId[id] else { orphans.append(id); continue }
                // A conflicted write is NEVER auto-retried: it would resend the same stale
                // `base_revision` and be refused every single time. It waits for a person.
                if conflicted.contains(id) { continue }
                do {
                    switch try await repository.upsertSettings(item, createdBy: createdBy, clientUpdatedAt: ts) {
                    case let .applied(row):
                        // The returned representation carries the NEW `server_revision` (and the
                        // id the block converged on) — the only way this device learns what
                        // version its own edit became. Never base + 1.
                        store.applyRemotePruningYieldSettingsUpsert(row)
                        metadata.setObservedRevision(row.serverRevision, for: row.id)
                        metadata.clearDirty([id])
                        SyncIssueCenter.shared.clearIssues([id])
                    case let .conflict(_, base, server):
                        // NOT cleared, NOT marked synced, NOT retried, and the queued local
                        // values are NOT replaced by the server's.
                        metadata.markRevisionConflict(id, baseRevision: base, serverRevision: server)
                        SyncIssueCenter.shared.recordFailure(
                            id: id,
                            entity: "Pruning Yield Settings",
                            detail: SyncFailureDetail(
                                kind: .permanent,
                                reasonCode: "revision_conflict",
                                friendlyMessage: "These calculator settings were also changed on another device. Both versions are saved — open the block to review.",
                                technicalDetail: "pruning_yield_settings row=\(id.uuidString) base_revision=\(base.map(String.init) ?? "none") server_revision=\(server.map(String.init) ?? "unknown")"
                            ),
                            queuedAt: ts,
                            payloadKeys: [],
                            vineyardId: vineyardId
                        )
                        print("[PruningYieldSettingsSync] block config \(id) REVISION_CONFLICT (base \(base.map(String.init) ?? "none") vs server \(server.map(String.init) ?? "unknown")) — kept queued for review")
                    }
                } catch {
                    // Isolate: one bad configuration must not block the others.
                    let detail = BackendErrorDiagnostics.classify(error, endpoint: "Pruning Yield Settings")
                    SyncIssueCenter.shared.recordFailure(
                        id: id,
                        entity: "Pruning Yield Settings",
                        detail: detail,
                        queuedAt: ts,
                        payloadKeys: SyncQueuePush.payloadKeys(
                            BackendPruningYieldSettings.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts)
                        ),
                        vineyardId: vineyardId
                    )
                    if detail.kind == .retryable, firstRetryableError == nil {
                        firstRetryableError = SyncPushError(entity: "Pruning Yield Settings", detail: detail)
                    }
                }
            }
            metadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            SyncIssueCenter.shared.notePending(entity: "Pruning Yield Settings", count: metadata.pendingUpserts.count)
            if let firstRetryableError { throw firstRetryableError }
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
                var seeded = 0
                // Per row: a conflict on one seeded block must not abort the others. A refused
                // seed simply stays local and is retried by the normal push path.
                for item in missing {
                    do {
                        if case let .applied(row) = try await repository.upsertSettings(item, createdBy: createdBy, clientUpdatedAt: now) {
                            store.applyRemotePruningYieldSettingsUpsert(row)
                            metadata.setObservedRevision(row.serverRevision, for: row.id)
                            metadata.clearDirty([item.id])
                            seeded += 1
                        }
                    } catch {
                        #if DEBUG
                        print("[PruningYieldSettingsSync] initial seed push failed for \(item.id): \(error.localizedDescription)")
                        #endif
                    }
                }
                #if DEBUG
                if seeded > 0 {
                    print("[PruningYieldSettingsSync] initial seed pushed \(seeded) local row(s) missing remotely")
                }
                #endif
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            if item.deletedAt != nil {
                store.applyRemotePruningYieldSettingsDelete(item.id)
                metadata.clearDirty([item.id]); metadata.clearDeleted([item.id]); continue
            }
            // sql/198: the SERVER's revision decides what is current — never a device clock.
            // The `client_updated_at` comparison that used to live here is gone, because a
            // phone with a slow clock had its perfectly valid edit discarded and a phone with
            // a fast clock locked every other device out until real time caught up.
            //
            // A row with an unacknowledged local edit keeps its local copy: the queued write
            // still carries `base_revision`, so the SERVER decides whether that edit is stale.
            if metadata.pendingUpserts[item.id] != nil { continue }
            // An unresolved conflict means the grower's authored settings exist ONLY on this
            // device. Applying the server row here would destroy them.
            if metadata.conflictedIds.contains(item.id) { continue }
            // Replica lag: a read served by a replica still on an older revision must not
            // overwrite a newer state this device has already had confirmed.
            if SyncRevisionContract.isRemoteBehind(
                observed: metadata.observedRevision(for: item.id),
                remote: item.serverRevision
            ) {
                print("[PruningYieldSettingsSync] block config \(item.id) pull ignored: replica at revision \(item.serverRevision.map(String.init) ?? "none") is behind confirmed \(metadata.observedRevision(for: item.id).map(String.init) ?? "none")")
                continue
            }
            store.applyRemotePruningYieldSettingsUpsert(item.toPruningYieldSettings())
            metadata.setObservedRevision(item.serverRevision, for: item.id)
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
