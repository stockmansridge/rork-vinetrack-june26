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
    /// Result of the last online SQL 115 parity check ("match" or a diff
    /// description). Nil while offline / unavailable — the check never blocks
    /// the field workflow.
    private(set) var lastParityReport: String?

    var pendingUpsertCount: Int {
        seasonMetadata.pendingUpserts.count + entryMetadata.pendingUpserts.count + editMetadata.pendingUpserts.count
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
    /// Queued `update_pruning_entry` pushes — separate from the create queue
    /// so an edit of an already-synced entry replays through the edit RPC
    /// (which can RELEASE removed quarters; the record RPC never can).
    private let editMetadata: ManagementSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?

    init(repository: (any PruningSyncRepositoryProtocol)? = nil, pruningStore: PruningStore? = nil) {
        self.repository = repository ?? SupabasePruningSyncRepository()
        self.pruningStore = pruningStore ?? .shared
        self.seasonMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_season_sync_metadata")
        self.entryMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_entry_sync_metadata")
        self.editMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_edit_sync_metadata")
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
        pruningStore.onEntryEdited = { [weak self] id in
            guard let self else { return }
            if self.entryMetadata.pendingUpserts[id] != nil {
                // The create hasn't landed yet — fold the edit into the queued
                // record push (record_pruning_entry replays the full new state
                // and nothing was ever claimed server-side to release).
                self.entryMetadata.markDirty(id, at: Date())
            } else {
                self.editMetadata.markDirty(id, at: Date())
            }
            self.scheduleEagerPush()
        }
        pruningStore.onEntryDeleted = { [weak self] id in
            self?.entryMetadata.markDeleted(id, at: Date())
            self?.editMetadata.clearDirty([id])
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

    /// Sync order matters: seasons are pushed and PULLED before entries are
    /// pushed, and a push failure never blocks the pulls. Previously a single
    /// failing push aborted the whole sync (including pulls), so one wedged
    /// entry silently stopped ALL pruning sync in both directions with no
    /// diagnostics. Queued entries are also re-pointed at the canonical
    /// season row after the season pull so they can never collide with the
    /// server's active-season unique index.
    func sync(vineyardId: UUID) async {
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        syncStatus = .syncing
        errorMessage = nil
        logEnvironment(vineyardId: vineyardId)
        var pushError: Error?

        do {
            try await pushSeasons(vineyardId: vineyardId)
        } catch {
            pushError = error
            print("[PruningSync] season push failed: \(error)")
        }

        do {
            try await pullSeasons(vineyardId: vineyardId)
            seasonMetadata.setLastSync(Date(), for: vineyardId)
        } catch {
            print("[PruningSync] season pull failed: \(error)")
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
            return
        }

        // The season pull may have replaced a locally created season row with
        // the server's canonical row for the same block + year (different id).
        // Re-point queued entries so their push lands on the surviving row.
        let remapped = pruningStore.remapPendingEntrySeasons(
            vineyardId: vineyardId,
            pendingIds: Set(entryMetadata.pendingUpserts.keys)
        )
        if !remapped.isEmpty {
            print("[PruningSync] remapped \(remapped.count) queued entry(ies) to the canonical season row")
        }

        do {
            try await pushEntries(vineyardId: vineyardId)
        } catch {
            if pushError == nil { pushError = error }
            print("[PruningSync] entry push failed: \(error)")
        }

        // Edits replay AFTER creates — an edit of an entry whose create hasn't
        // landed yet returns entry_not_found and stays queued for next pass.
        do {
            try await pushEdits(vineyardId: vineyardId)
        } catch {
            if pushError == nil { pushError = error }
            print("[PruningSync] entry edit push failed: \(error)")
        }

        do {
            try await pullEntriesAndSegments(vineyardId: vineyardId)
            entryMetadata.setLastSync(Date(), for: vineyardId)
        } catch {
            print("[PruningSync] entry pull failed: \(error)")
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
            return
        }

        lastSyncDate = Date()
        if let pushError {
            errorMessage = pushError.localizedDescription
            syncStatus = .failure(pushError.localizedDescription)
        } else {
            syncStatus = .success
            await verifyServerParity(vineyardId: vineyardId)
        }
    }

    /// Diagnostic: the exact runtime pruning environment (no secrets). Proves
    /// which Supabase project, vineyard UUID and season year this device is
    /// actually reading/writing — for cross-checking against the portal.
    private func logEnvironment(vineyardId: UUID) {
        let seasonRows = pruningStore.setups
            .filter { $0.vineyardId == vineyardId }
            .map { "\($0.seasonYear):\($0.id.uuidString.lowercased())" }
            .sorted()
        print("""
        [PruningEnv] url=\(AppConfig.supabaseURL.absoluteString) \
        user=\(auth?.userId?.uuidString.lowercased() ?? "-") \
        vineyard=\(vineyardId.uuidString.lowercased()) \
        resolvedSeasonYear=\(PruningSeasonId.currentSeasonYear) \
        seasonRows=[\(seasonRows.joined(separator: " "))] \
        pendingUpserts=\(pendingUpsertCount) pendingDeletes=\(pendingDeleteCount) \
        lastSync=\(lastSyncDate.map { ISO8601DateFormatter().string(from: $0) } ?? "never")
        """)
    }

    // MARK: SQL 115 parity check

    /// Online reconciliation against the authoritative
    /// `get_pruning_vineyard_summary` RPC (SQL 115). The local offline
    /// calculation must produce the identical rounded values; a mismatch is
    /// logged for diagnosis. RPC unavailability (offline, older schema) is
    /// silent — the mobile calculation path stays fully offline-capable.
    private func verifyServerParity(vineyardId: UUID) async {
        guard let store else { return }
        do {
            let server = try await repository.fetchVineyardSummary(vineyardId: vineyardId)
            let paddocks = store.paddocks.filter { $0.vineyardId == vineyardId }
            let local = PruningCalculator.vineyardSummary(
                paddocks: paddocks,
                setups: pruningStore.setups.filter { $0.vineyardId == vineyardId },
                entries: pruningStore.entries(forVineyard: vineyardId)
            )

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let localProjected = local.projectedFinish.map { formatter.string(from: $0) }

            var diffs: [String] = []
            func check(_ label: String, _ localValue: String, _ serverValue: String) {
                if localValue != serverValue { diffs.append("\(label) local \(localValue) vs server \(serverValue)") }
            }
            check("progress%", "\(local.displayPercent)", "\(server.displayPercent ?? -1)")
            check("vinesPruned", "\(local.vinesPruned)", "\(server.vinesPruned ?? -1)")
            check("totalVines", "\(local.vinesTotal)", "\(server.totalVines ?? -1)")
            check("vinesRemaining", "\(local.vinesRemaining)", "\(server.vinesRemaining ?? -1)")
            check(
                "vinesPerDay",
                local.vinesPerDay.map { "\(Int($0.rounded()))" } ?? "—",
                server.vinesPerDay.map { "\(Int($0.rounded()))" } ?? "—"
            )
            check(
                "vinesPerLabourHour",
                local.vinesPerLabourHour.map { "\(Int($0.rounded()))" } ?? "—",
                server.vinesPerLabourHour.map { "\(Int($0.rounded()))" } ?? "—"
            )
            check("blocksComplete", "\(local.blocksComplete)", "\(server.blocksComplete ?? -1)")
            check("blocksAtRisk", "\(local.blocksAtRisk)", "\(server.blocksAtRisk ?? -1)")
            check("projected", localProjected ?? "—", server.projectedCompletionDate ?? "—")

            if diffs.isEmpty {
                lastParityReport = "match"
                print("[PruningParity] LOCAL == SQL115 — \(local.displayPercent)% · \(local.vinesPruned)/\(local.vinesTotal) vines · projected \(localProjected ?? "—")")
            } else {
                lastParityReport = diffs.joined(separator: "; ")
                print("[PruningParity] MISMATCH — \(diffs.joined(separator: "; "))")
            }
        } catch {
            // Offline or RPC not installed — keep the local offline-first path.
            lastParityReport = nil
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
                do {
                    try await repository.upsertSeasons(payloads)
                    seasonMetadata.clearDirty(pushed)
                } catch {
                    let message = String(describing: error).lowercased()
                    if message.contains("pruning_seasons_active_unique") || message.contains("duplicate key") || message.contains("23505") {
                        // A different-id ACTIVE season already exists on the
                        // server for the same vineyard + block + year (e.g.
                        // created from the portal). Keeping these dirty would
                        // wedge the queue forever — drop the local copy and
                        // let the pull adopt the server's canonical row.
                        seasonMetadata.clearDirty(pushed)
                        print("[PruningSync] season push hit the active-season unique index — adopting the server row instead")
                    } else {
                        throw error
                    }
                }
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
                    print("[PruningSync] record_pruning_entry failed for entry \(id): \(error)")
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

    /// Replays queued `update_pruning_entry` pushes. The RPC is idempotent
    /// (full desired state, LWW on client_updated_at), so a retry can never
    /// duplicate quarters or restore quarters removed by a newer edit.
    private func pushEdits(vineyardId: UUID) async throws {
        let dirty = editMetadata.pendingUpserts
        guard !dirty.isEmpty else { return }
        var firstError: Error?
        let byId = Dictionary(pruningStore.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for (id, ts) in dirty {
            guard let entry = byId[id] else {
                editMetadata.clearDirty([id])
                continue
            }
            guard entry.vineyardId == vineyardId else { continue }
            do {
                let result = try await repository.updateEntry(UpdatePruningEntryParams(from: entry, clientUpdatedAt: ts))
                if result.error == "entry_not_found" {
                    // Ordered dependency: the entry create hasn't landed on the
                    // server yet — keep the edit queued and retry next sync.
                    print("[PruningSync] edit \(id) waiting for the entry create to land — kept queued")
                    if firstError == nil {
                        firstError = NSError(
                            domain: "PruningSync",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Pruning edit is waiting for the entry to reach the server — it will retry automatically."]
                        )
                    }
                    continue
                }
                if result.error == "entry_reversed" {
                    // The entry was reversed elsewhere — the edit is obsolete.
                    editMetadata.clearDirty([id])
                    continue
                }
                if result.stale == true {
                    print("[PruningSync] edit \(id) superseded by a newer edit on another device — dropped")
                }
                if let conflicts = result.conflicts, !conflicts.isEmpty {
                    let detail = conflicts
                        .map { "row \($0.row.map(String.init) ?? "?") q\($0.segment.map(String.init) ?? "?")" }
                        .joined(separator: ", ")
                    print("[PruningSync] edit \(id): \(conflicts.count) quarter(s) already completed by another entry — \(detail)")
                }
                editMetadata.clearDirty([id])
            } catch {
                print("[PruningSync] update_pruning_entry failed for \(id): \(error)")
                if firstError == nil { firstError = error }
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

        // Entries with a queued create OR a queued edit keep their optimistic
        // local state until the push lands.
        let protected = Set(entryMetadata.pendingUpserts.keys)
            .union(editMetadata.pendingUpserts.keys)

        for item in remote {
            if item.deletedAt != nil {
                pruningStore.applyRemoteEntryDelete(item.id)
                entryMetadata.clearDirty([item.id])
                entryMetadata.clearDeleted([item.id])
                editMetadata.clearDirty([item.id])
                continue
            }
            if protected.contains(item.id) { continue }
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
            protectedIds: protected
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
