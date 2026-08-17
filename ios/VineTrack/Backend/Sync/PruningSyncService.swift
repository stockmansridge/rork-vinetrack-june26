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
    /// Reconciliation of the last multi-block activity the SERVER answered
    /// (sql/166): how many quarters actually landed and how many were already
    /// recorded elsewhere. A save with refused quarters is never presented as
    /// fully successful.
    private(set) var lastActivityReconciliation: PruningActivityReconciliation?
    /// Consistency snapshot of the pruning activity cache from the last refresh,
    /// surfaced in the admin Backend Diagnostics screen.
    private(set) var lastCacheAudit: PruningActivityCacheAudit?

    func clearActivityReconciliation() {
        lastActivityReconciliation = nil
    }

    // MARK: sql/198 season revision conflicts

    /// Seasons whose last write the server REFUSED on revision grounds. The grower's authored
    /// values are still queued; nothing here resolves a conflict automatically.
    var conflictedSeasonIds: Set<UUID> { seasonMetadata.conflictedIds }

    /// The unresolved conflict for a season, if any. Survives app restarts.
    func seasonRevisionConflict(id: UUID) -> SyncRevisionConflictMark? {
        seasonMetadata.revisionConflict(for: id)
    }

    /// RE-FETCHES the server's current row for a conflicted season.
    ///
    /// Deliberately a fresh read rather than a stored side-by-side copy: a cached "server
    /// version" starts drifting the moment it is written, and a review screen showing a stale
    /// server copy is worse than one that fetches. The LOCAL authored copy is the half that
    /// must survive, and that lives in ``PruningStore`` plus the queue.
    func serverCopyOfSeason(id: UUID, vineyardId: UUID) async -> PruningBlockSetup? {
        guard let remote = try? await repository.fetchSeasons(vineyardId: vineyardId, since: nil) else { return nil }
        return remote.first { $0.id == id }?.toPruningBlockSetup()
    }

    var pendingUpsertCount: Int {
        seasonMetadata.pendingUpserts.count + entryMetadata.pendingUpserts.count
            + editMetadata.pendingUpserts.count + activityMetadata.pendingUpserts.count
            + activityEditMetadata.pendingUpserts.count
            + activityLabourMetadata.pendingUpserts.count
    }
    var pendingDeleteCount: Int {
        seasonMetadata.pendingDeletes.count + entryMetadata.pendingDeletes.count
            + activityMetadata.pendingDeletes.count
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
    /// Queued `record_pruning_activity` pushes — multi-block activities
    /// (sql/166), keyed by the stable client activity id so a replay can never
    /// create a second parent or duplicate an allocation.
    private let activityMetadata: ManagementSyncMetadata
    /// Queued `update_pruning_activity` pushes — the FULL desired state of an
    /// already-acknowledged activity (adds/removes a block, changes quarters,
    /// changes the date, or changes labour without touching allocations).
    private let activityEditMetadata: ManagementSyncMetadata
    /// Queued `save_pruning_activity_labour_lines` pushes (sql/190), keyed by
    /// the ACTIVITY id rather than the line id.
    ///
    /// The RPC is a DESIRED-STATE save of an activity's whole set, so the unit
    /// of work is the activity: adding, editing and removing lines all collapse
    /// into ONE queued push carrying the final set. That is what makes an
    /// offline replay idempotent — replaying the same payload produces the same
    /// rows, and a queued edit cannot resurrect a line deleted on another
    /// device afterwards.
    private let activityLabourMetadata: ManagementSyncMetadata
    private var isConfigured: Bool = false
    private var eagerPushTask: Task<Void, Never>?
    /// Resolves whether a Work Task still has an unacknowledged local write.
    ///
    /// `pruning_activities.work_task_id` is a real foreign key, so an activity
    /// linked to a task created offline must WAIT for that task to reach the
    /// server. The link is never dropped to make the pruning upload succeed.
    private var isWorkTaskPending: ((UUID) -> Bool)?

    init(repository: (any PruningSyncRepositoryProtocol)? = nil, pruningStore: PruningStore? = nil) {
        self.repository = repository ?? SupabasePruningSyncRepository()
        self.pruningStore = pruningStore ?? .shared
        self.seasonMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_season_sync_metadata")
        self.entryMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_entry_sync_metadata")
        self.editMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_edit_sync_metadata")
        self.activityMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_activity_sync_metadata")
        self.activityEditMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_activity_edit_sync_metadata")
        self.activityLabourMetadata = ManagementSyncMetadata(key: "vinetrack_pruning_activity_labour_sync_metadata")
    }

    /// Wires the Work Task dependency used to order the activity push. Injected
    /// rather than referenced directly, so the pruning service keeps no hard
    /// dependency on the work-task sync service.
    func configureWorkTaskDependency(_ isPending: @escaping (UUID) -> Bool) {
        isWorkTaskPending = isPending
    }

    /// True while this activity's linked Work Task has not been acknowledged.
    private func isWaitingForWorkTask(_ draft: PruningActivityDraft) -> Bool {
        guard let isWorkTaskPending else { return false }
        return PruningWorkTaskLink.isWaitingForTask(draft.workTaskId, isTaskPending: isWorkTaskPending)
    }

    private func workTaskDependencyError() -> Error {
        NSError(
            domain: "PruningSync",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: PruningWorkTaskLink.waitingReason]
        )
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
        pruningStore.onActivitySaved = { [weak self] id, isNew in
            guard let self else { return }
            if isNew || self.activityMetadata.pendingUpserts[id] != nil {
                // The create hasn't been acknowledged yet — fold the edit into
                // the queued record push, whose payload already carries the FULL
                // desired state (parent + every allocation).
                self.activityMetadata.markDirty(id, at: Date())
            } else {
                self.activityEditMetadata.markDirty(id, at: Date())
            }
            self.scheduleEagerPush()
        }
        pruningStore.onActivityReversed = { [weak self] id in
            self?.activityMetadata.markDeleted(id, at: Date())
            self?.activityMetadata.clearDirty([id])
            self?.activityEditMetadata.clearDirty([id])
            // Labour lines cascade with the activity server-side, so a queued
            // labour push for a reversed activity is obsolete rather than lost.
            self?.activityLabourMetadata.clearDirty([id])
            self?.scheduleEagerPush()
        }
        // Fired with the ACTIVITY id: one queued push carries the activity's
        // final desired set, however many lines were added, edited or removed.
        store.onPruningActivityLabourLinesChanged = { [weak self] activityId in
            self?.activityLabourMetadata.markDirty(activityId, at: Date())
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

        // Activities push after the single-block queue: both write the same
        // segment table, and the activity RPCs are the only path that can add a
        // block to an existing parent.
        do {
            try await pushActivities(vineyardId: vineyardId)
        } catch {
            if pushError == nil { pushError = error }
            print("[PruningSync] activity push failed: \(error)")
        }

        // Labour lines push AFTER the activities: `save_pruning_activity_labour_lines`
        // resolves the parent first, so an activity created offline must exist
        // server-side before its labour can be attached. A failure here leaves
        // the set queued with its lines intact and never blocks the pulls.
        do {
            try await pushActivityLabourLines(vineyardId: vineyardId)
        } catch {
            if pushError == nil { pushError = error }
            print("[PruningSync] activity labour push failed: \(error)")
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

        // Labour lines pull last: they depend on nothing else, and a failure
        // must not cost the caller the entry/segment work already applied.
        do {
            try await pullActivityLabourLines(vineyardId: vineyardId)
            activityLabourMetadata.setLastSync(Date(), for: vineyardId)
        } catch {
            print("[PruningSync] activity labour pull failed: \(error)")
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

    /// Pushes queued season setups under the sql/198 revision contract.
    ///
    /// ONE REQUEST PER SEASON. The batch upsert this replaced was a single transaction, so a
    /// single conflicting season would have aborted every other season's write in the same
    /// call — valid edits stranded because an unrelated block lost a race.
    private func pushSeasons(vineyardId: UUID) async throws {
        let createdBy = auth?.userId
        let dirty = seasonMetadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(pruningStore.setups.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let conflicted = seasonMetadata.conflictedIds
            var orphans: [UUID] = []
            var firstRetryableError: Error?
            for (id, ts) in dirty {
                // Reclaim queue entries with no local season — they can never
                // upload and used to sit in the queue forever.
                guard let item = byId[id] else { orphans.append(id); continue }
                // A conflicted write is NEVER auto-retried: it would resend the same stale
                // `base_revision` and be refused every single time. It waits for a person.
                if conflicted.contains(id) { continue }
                do {
                    switch try await repository.upsertSeason(item, createdBy: createdBy, clientUpdatedAt: ts) {
                    case let .applied(row):
                        // The returned representation carries the NEW `server_revision` — the
                        // only way this device learns what version its own edit became. Never
                        // base + 1.
                        pruningStore.applyRemoteSeasonUpsert(row)
                        seasonMetadata.setObservedRevision(row.serverRevision, for: id)
                        seasonMetadata.clearDirty([id])
                        SyncIssueCenter.shared.clearIssues([id])
                    case let .conflict(_, base, server):
                        // NOT cleared, NOT marked synced, NOT retried, and the queued local
                        // values are NOT replaced by the server's. The grower's edit exists
                        // nowhere else; the server's current row is re-read on demand.
                        seasonMetadata.markRevisionConflict(id, baseRevision: base, serverRevision: server)
                        SyncIssueCenter.shared.recordFailure(
                            id: id,
                            entity: "Pruning Seasons",
                            detail: SyncFailureDetail(
                                kind: .permanent,
                                reasonCode: "revision_conflict",
                                friendlyMessage: "This block setup was also changed on another device. Both versions are saved — open the block to review.",
                                technicalDetail: "pruning_seasons row=\(id.uuidString) base_revision=\(base.map(String.init) ?? "none") server_revision=\(server.map(String.init) ?? "unknown")"
                            ),
                            queuedAt: ts,
                            payloadKeys: [],
                            vineyardId: vineyardId
                        )
                        print("[PruningSync] season \(id) REVISION_CONFLICT (base \(base.map(String.init) ?? "none") vs server \(server.map(String.init) ?? "unknown")) — kept queued for review")
                    }
                } catch {
                    let message = String(describing: error).lowercased()
                    if message.contains("pruning_seasons_active_unique") || message.contains("duplicate key") || message.contains("23505") {
                        // A different-id ACTIVE season already exists on the server for the
                        // same vineyard + block + year (e.g. created from the portal). This is
                        // NOT a revision conflict — nobody raced this edit — so it must not be
                        // reported as one. Keeping it dirty would wedge the queue forever, so
                        // drop the local copy and let the pull adopt the canonical server row.
                        seasonMetadata.clearDirty([id])
                        SyncIssueCenter.shared.clearIssues([id])
                        print("[PruningSync] season \(id) hit the active-season unique index — adopting the server row instead")
                        continue
                    }
                    // Isolate: one bad season must not block the others.
                    let detail = BackendErrorDiagnostics.classify(error, endpoint: "Pruning Seasons")
                    SyncIssueCenter.shared.recordFailure(
                        id: id,
                        entity: "Pruning Seasons",
                        detail: detail,
                        queuedAt: ts,
                        payloadKeys: SyncQueuePush.payloadKeys(
                            BackendPruningSeason.upsert(from: item, createdBy: createdBy, clientUpdatedAt: ts)
                        ),
                        vineyardId: vineyardId
                    )
                    if detail.kind == .retryable, firstRetryableError == nil {
                        firstRetryableError = SyncPushError(entity: "Pruning Seasons", detail: detail)
                    }
                }
            }
            seasonMetadata.clearDirty(orphans)
            SyncIssueCenter.shared.clearIssues(orphans)
            SyncIssueCenter.shared.notePending(entity: "Pruning Seasons", count: seasonMetadata.pendingUpserts.count)
            if let firstRetryableError { throw firstRetryableError }
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
                    // A skipped record takes the sql/168 path, whose signature
                    // has nowhere to put a worker, hours, a rate or a task — so
                    // an out-of-rotation section can never reach the server
                    // carrying labour, however the local draft was built.
                    let result = entry.isSkipped
                        ? try await repository.recordSkippedEntry(
                            RecordSkippedPruningEntryParams(from: entry, clientUpdatedAt: ts)
                          )
                        : try await repository.recordEntry(
                            RecordPruningEntryParams(from: entry, clientUpdatedAt: ts)
                          )
                    adoptCanonicalSeason(for: entry, result: result)
                    entryMetadata.clearDirty([id])
                } catch {
                    let rpc = entry.isSkipped ? "record_skipped_pruning_entry" : "record_pruning_entry"
                    print("[PruningSync] \(rpc) failed for entry \(id): \(error)")
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

    /// Adopts the season `record_pruning_entry` resolved from the entry date
    /// (sql/161). Server resolution is authoritative: if this device guessed a
    /// different season row — the cross-platform 2026-vs-2027 defect — the
    /// local cache converges silently instead of drifting further.
    private func adoptCanonicalSeason(for entry: PruningEntry, result: RecordPruningEntryResult) {
        guard let seasonId = result.seasonId else { return }
        if result.seasonMismatch == true {
            // A historical row stored under a non-canonical season. Never moved
            // silently — reported for the reviewed data correction (sql/162).
            print("[PruningSync] entry \(entry.id) is stored under a non-canonical season \(seasonId) — reported, not moved")
        } else if seasonId != entry.seasonId {
            print("[PruningSync] entry \(entry.id) adopted canonical season \(seasonId) (\(result.seasonYear.map(String.init) ?? "?"))")
        }
        pruningStore.adoptServerSeason(entryId: entry.id, seasonId: seasonId)
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
                let result = entry.isSkipped
                    ? try await repository.updateSkippedEntry(
                        UpdateSkippedPruningEntryParams(from: entry, clientUpdatedAt: ts)
                      )
                    : try await repository.updateEntry(
                        UpdatePruningEntryParams(from: entry, clientUpdatedAt: ts)
                      )
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

    // MARK: Push — multi-block activities (sql/166)

    /// Replays queued activity writes. Every RPC is atomic and idempotent on the
    /// stable client activity id, so a retry can never create a second parent or
    /// duplicate an allocation, and a failed allocation rolls the whole activity
    /// back server-side. The response replaces the local activity AND all its
    /// allocations wholesale.
    private func pushActivities(vineyardId: UUID) async throws {
        var firstError: Error?

        for (id, ts) in activityMetadata.pendingUpserts {
            guard let draft = pruningStore.activity(id: id) else {
                activityMetadata.clearDirty([id])
                continue
            }
            guard draft.vineyardId == vineyardId else { continue }
            // ORDERED DEPENDENCY: the linked Work Task must exist server-side
            // first, or this atomic write is rejected outright. The activity
            // stays queued WITH its link and retries on the next pass.
            if isWaitingForWorkTask(draft) {
                print("[PruningSync] activity \(id) held: linked Work Task has not synced yet")
                if firstError == nil { firstError = workTaskDependencyError() }
                continue
            }
            do {
                let params = RecordPruningActivityParams(from: draft, clientUpdatedAt: ts)
                let result = try await repository.recordActivity(params)
                adoptCanonicalActivity(id: id, result: result)
                activityMetadata.clearDirty([id])
            } catch {
                print("[PruningSync] record_pruning_activity failed for \(id): \(error)")
                if firstError == nil { firstError = error }
            }
        }

        for (id, ts) in activityEditMetadata.pendingUpserts {
            guard let draft = pruningStore.activity(id: id) else {
                activityEditMetadata.clearDirty([id])
                continue
            }
            guard draft.vineyardId == vineyardId else { continue }
            if isWaitingForWorkTask(draft) {
                print("[PruningSync] activity edit \(id) held: linked Work Task has not synced yet")
                if firstError == nil { firstError = workTaskDependencyError() }
                continue
            }
            do {
                let params = UpdatePruningActivityParams(from: draft, clientUpdatedAt: ts)
                let result = try await repository.updateActivity(params)
                if result.error == "activity_not_found" {
                    // Ordered dependency: the create hasn't landed yet.
                    print("[PruningSync] activity edit \(id) is waiting for the create to land — kept queued")
                    if firstError == nil {
                        firstError = NSError(
                            domain: "PruningSync",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Pruning activity edit is waiting for the activity to reach the server — it will retry automatically."]
                        )
                    }
                    continue
                }
                if result.error == "activity_reversed" {
                    activityEditMetadata.clearDirty([id])
                    continue
                }
                if result.stale != true { adoptCanonicalActivity(id: id, result: result) }
                activityEditMetadata.clearDirty([id])
            } catch {
                print("[PruningSync] update_pruning_activity failed for \(id): \(error)")
                if firstError == nil { firstError = error }
            }
        }

        for (id, _) in activityMetadata.pendingDeletes {
            do {
                let result = try await repository.reverseActivity(id: id, reason: nil)
                publishReconciliation(id: id, result: result, isReversal: true)
                activityMetadata.clearDeleted([id])
            } catch {
                if isPruningMissingRowError(error) {
                    activityMetadata.clearDeleted([id])
                } else if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError { throw firstError }
    }

    /// Canonical read-back of ONE activity through `get_pruning_activity` — the
    /// edit path, so reopening an activity restores the real server state (every
    /// block, every quarter, the shared labour and both resolved years) instead
    /// of reconstructing it from legacy per-block rows. Falls back to the local
    /// draft when the read is unavailable.
    func loadActivity(id: UUID) async -> PruningActivityDraft? {
        let local = pruningStore.activity(id: id)
        guard let auth, auth.isSignedIn else { return local }
        guard let canonical = try? await repository.fetchActivity(id: id), canonical.activity != nil else {
            return local
        }
        return pruningStore.applyRemoteActivity(canonical) ?? local
    }

    /// Pulls every activity of the vineyard through `list_pruning_activities` and
    /// adopts the canonical parents + allocations. Activities with an unresolved
    /// queued write keep their optimistic local state — a pull must never
    /// overwrite work that hasn't been pushed yet.
    ///
    /// SUMMARY SCOPE. `list_pruning_activities` withholds the per-quarter detail,
    /// so this refresh updates parent metadata and the allocation set but never
    /// rewrites completed quarters. Whatever it cannot account for is then
    /// repaired from `get_pruning_activity`, which IS authoritative — so a pull
    /// converges on the full record instead of leaving a hollow one behind.
    @discardableResult
    func refreshActivities(vineyardId: UUID) async -> [PruningActivityDraft] {
        guard let auth, auth.isSignedIn else { return pruningStore.activities(forVineyard: vineyardId) }
        guard let remote = try? await repository.fetchActivities(vineyardId: vineyardId) else {
            return pruningStore.activities(forVineyard: vineyardId)
        }
        let queued = Set(activityMetadata.pendingUpserts.keys)
            .union(activityEditMetadata.pendingUpserts.keys)
            .union(activityMetadata.pendingDeletes.keys)
        var summaryOnly = 0
        for canonical in remote {
            guard let id = canonical.activity?.id, !queued.contains(id) else { continue }
            if canonical.isSummaryOnly { summaryOnly += 1 }
            pruningStore.applyRemoteActivity(canonical)
        }
        if summaryOnly > 0 {
            print("[PruningSync] \(summaryOnly) activity summary(ies) carried no quarter detail — quarters preserved, detail repaired on demand")
        }
        await repairActivityProjections(vineyardId: vineyardId)
        logCacheAudit(vineyardId: vineyardId)
        return pruningStore.activities(forVineyard: vineyardId)
    }

    /// Repairs activities whose local copy is HOLLOW — the parent exists but its
    /// allocations or their quarters are missing, which the server's own roll-up
    /// contradicts.
    ///
    /// Runs after every activity refresh (so on pull-to-refresh and on app
    /// launch), fetches the authoritative detailed record through
    /// `get_pruning_activity`, rebuilds the legacy projection and therefore the
    /// block and vineyard progress. The user never has to re-enter the activity.
    ///
    /// Bounded per pass: a large backlog repairs over several refreshes rather
    /// than firing hundreds of RPCs at once.
    @discardableResult
    func repairActivityProjections(vineyardId: UUID, limit: Int = 25) async -> Int {
        guard let auth, auth.isSignedIn else { return 0 }
        let queued = Set(activityMetadata.pendingUpserts.keys)
            .union(activityEditMetadata.pendingUpserts.keys)
            .union(activityMetadata.pendingDeletes.keys)
        let candidates = pruningStore.activitiesNeedingCanonicalDetail(vineyardId: vineyardId)
            .filter { !queued.contains($0.id) }
            .prefix(limit)
        guard !candidates.isEmpty else { return 0 }

        var repaired = 0
        for draft in candidates {
            guard let canonical = try? await repository.fetchActivity(id: draft.id),
                  canonical.activity != nil else { continue }
            guard canonical.hasSegmentDetail else {
                // The detailed RPC answered without detail — adopting it would
                // be no better than the summary. Leave the local record alone.
                print("[PruningSync] activity \(draft.id) detail fetch returned no quarters — local record kept")
                continue
            }
            pruningStore.applyRemoteActivity(canonical)
            repaired += 1
        }
        if repaired > 0 {
            print("[PruningSync] repaired \(repaired) hollow activity projection(s) from get_pruning_activity")
        }
        return repaired
    }

    /// Diagnostic snapshot of the activity cache, logged after each refresh.
    /// Silent when the cache is consistent.
    private func logCacheAudit(vineyardId: UUID) {
        let audit = pruningStore.auditActivityCache(vineyardId: vineyardId)
        lastCacheAudit = audit
        if !audit.isHealthy {
            print("[PruningCache] \(audit.summary)")
        }
    }

    /// Adopts the canonical activity the server returned. The shared labour stays
    /// on the parent, and every allocation takes the season the server resolved
    /// from the ACTIVITY date (sql/161 applied per allocation).
    private func adoptCanonicalActivity(id: UUID, result: PruningActivityResult) {
        publishReconciliation(id: id, result: result)
        guard let canonical = result.canonical else { return }
        if let conflicts = result.conflicts, !conflicts.isEmpty {
            let detail = conflicts
                .map { "row \($0.row.map(String.init) ?? "?") q\($0.segment.map(String.init) ?? "?")" }
                .joined(separator: ", ")
            print("[PruningSync] activity \(id): \(conflicts.count) quarter(s) already completed by another record — \(detail)")
        }
        if let season = canonical.activity?.seasonYear,
           let date = PruningSyncDate.date(fromYmd: canonical.activity?.entryDate),
           season != PruningSeasonId.seasonYear(for: date) {
            print("[PruningSync] activity \(id) is filed under season \(season) for \(PruningSyncDate.ymd(from: date)) — reported, not moved")
        }
        pruningStore.adoptCanonicalActivity(id: id, canonical: canonical)
    }

    /// Surfaces the server's answer to the UI, including the quarters it refused
    /// because another record already owns them (never stolen).
    private func publishReconciliation(id: UUID, result: PruningActivityResult, isReversal: Bool = false) {
        let draft = pruningStore.activity(id: id)
        var names: [UUID: String] = [:]
        for allocation in draft?.allocations.values ?? [:].values {
            names[allocation.paddockId] = allocation.blockName
        }
        lastActivityReconciliation = PruningActivityReconciliation.from(
            result,
            blockNames: names,
            blockSummary: draft?.blockSummary ?? "",
            activityId: id,
            isReversal: isReversal
        )
    }

    // MARK: Push — pruning-owned labour lines (sql/190)

    /// Replays queued labour-line writes through `save_pruning_activity_labour_lines`.
    ///
    /// The payload is the activity's COMPLETE desired set, so this one call
    /// covers creates, edits and removals together. An EMPTY set is a legitimate
    /// payload meaning "this activity has no labour lines" — it is what clears
    /// the last line — so it is never skipped as a no-op.
    private func pushActivityLabourLines(vineyardId: UUID) async throws {
        guard let store else { return }
        let dirty = activityLabourMetadata.pendingUpserts
        guard !dirty.isEmpty else { return }
        var firstError: Error?

        for (activityId, ts) in dirty {
            guard let draft = pruningStore.activity(id: activityId) else {
                // No local activity: nothing this queue entry can ever describe.
                activityLabourMetadata.clearDirty([activityId])
                continue
            }
            guard draft.vineyardId == vineyardId else { continue }

            // ORDERED DEPENDENCY: the parent activity must exist server-side, or
            // the RPC raises "Pruning activity not found". The labour stays
            // queued (with every line intact) and retries on the next pass.
            if activityMetadata.pendingUpserts[activityId] != nil {
                print("[PruningSync] labour for activity \(activityId) held: the activity has not synced yet")
                if firstError == nil {
                    firstError = NSError(
                        domain: "PruningSync",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Pruning labour is waiting for its activity to reach the server — it will retry automatically."]
                    )
                }
                continue
            }

            let lines = store.labourLines(forPruningActivity: activityId)
            let payload = lines.enumerated().map { index, line in
                BackendPruningActivityLabourLinePayload(from: line, lineIndex: index)
            }
            do {
                let result = try await repository.saveActivityLabourLines(
                    SavePruningActivityLabourLinesParams(
                        activityId: activityId,
                        lines: payload,
                        clientUpdatedAt: ts
                    )
                )
                adoptCanonicalLabourLines(
                    activityId: activityId,
                    vineyardId: draft.vineyardId,
                    result: result
                )
                activityLabourMetadata.clearDirty([activityId])
            } catch {
                print("[PruningSync] save_pruning_activity_labour_lines failed for \(activityId): \(error)")
                if firstError == nil { firstError = error }
            }
        }
        SyncIssueCenter.shared.notePending(
            entity: "Pruning Labour",
            count: activityLabourMetadata.pendingUpserts.count
        )
        if let firstError { throw firstError }
    }

    /// Adopts the canonical set the server returned, replacing the activity's
    /// whole local set. The server has just acknowledged this state, so the
    /// apply is deliberately silent — re-marking it dirty would push the same
    /// rows back forever.
    private func adoptCanonicalLabourLines(
        activityId: UUID,
        vineyardId: UUID,
        result: SavePruningActivityLabourLinesResult
    ) {
        guard let store, let remote = result.labourLines else { return }
        store.applyRemotePruningActivityLabourLines(
            remote.filter { $0.deletedAt == nil }.map { $0.toLabourLine() },
            forPruningActivity: activityId,
            vineyardId: vineyardId
        )
        #if DEBUG
        print("""
        [PruningLabourSync] activity=\(activityId) saved=\(result.saved ?? 0) \
        removed=\(result.removed ?? 0) hours=\(result.totalLabourHours.map { "\($0)" } ?? "-") \
        cost=\(result.labourCost.map { "\($0)" } ?? "not specified") \
        source=\(result.labourCostSource ?? "-")
        """)
        #endif
    }

    // MARK: Pull

    /// Pulls every pruning labour line of the vineyard and applies them one
    /// ACTIVITY at a time.
    ///
    /// The apply is a wholesale per-activity replace, matching the desired-state
    /// write contract: an activity the server reports with no live lines really
    /// has none, so a line deleted on another device disappears here too.
    /// Activities with an unresolved queued write keep their optimistic local
    /// set — a pull must never overwrite work that has not been pushed yet.
    private func pullActivityLabourLines(vineyardId: UUID) async throws {
        guard let store else { return }
        let remote = try await repository.fetchActivityLabourLines(vineyardId: vineyardId)
        let queued = Set(activityLabourMetadata.pendingUpserts.keys)

        var byActivity: [UUID: [PruningActivityLabourLine]] = [:]
        for row in remote where row.deletedAt == nil {
            byActivity[row.pruningActivityId, default: []].append(row.toLabourLine())
        }
        // Every activity the server mentioned at all, so one whose last line was
        // soft-deleted remotely is cleared locally instead of lingering.
        let touched = Set(remote.map(\.pruningActivityId))

        var applied = 0
        for activityId in touched where !queued.contains(activityId) {
            store.applyRemotePruningActivityLabourLines(
                (byActivity[activityId] ?? []).sorted { $0.lineIndex < $1.lineIndex },
                forPruningActivity: activityId,
                vineyardId: vineyardId
            )
            applied += 1
        }
        #if DEBUG
        print("[PruningLabourSync] pull: \(remote.count) row(s) across \(applied) activity(ies), \(queued.count) held for push")
        #endif
    }

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
                // Per row: a conflict on one seeded season must not abort the others. A refused
                // seed simply stays local and is retried by the normal push path.
                for setup in missing {
                    if case let .applied(row) = try? await repository.upsertSeason(setup, createdBy: createdBy, clientUpdatedAt: now) {
                        pruningStore.applyRemoteSeasonUpsert(row)
                        seasonMetadata.setObservedRevision(row.serverRevision, for: row.id)
                    }
                }
            }
            if remote.isEmpty { return }
        }
        for item in remote {
            // A season archived on the portal (`status = 'archived'`) must not
            // keep showing as an active block setup on mobile — treat it like
            // a tombstone for display. Client upserts never send `status`, so
            // the archive marker itself is always preserved server-side.
            if item.deletedAt != nil || item.status?.lowercased() == "archived" {
                pruningStore.applyRemoteSeasonDelete(item.id)
                seasonMetadata.clearDirty([item.id])
                seasonMetadata.clearDeleted([item.id])
                continue
            }
            // sql/198: the SERVER's revision decides what is current — never a device clock.
            // The `client_updated_at` comparison that used to live here is gone, because a
            // phone with a slow clock had its perfectly valid edit discarded and a phone with
            // a fast clock locked every other device out until real time caught up.
            //
            // A row with an unacknowledged local edit keeps its local copy. The queued write
            // still carries `base_revision`, so the SERVER decides whether that edit is stale
            // when it is pushed — this pull must not pre-empt that by overwriting the authored
            // values first.
            if seasonMetadata.pendingUpserts[item.id] != nil { continue }
            // An unresolved conflict means the grower's authored setup exists ONLY on this
            // device. Applying the server row here would destroy it.
            if seasonMetadata.conflictedIds.contains(item.id) { continue }
            // Replica lag: a read served by a replica still on an older revision must not
            // overwrite a newer state this device has already had confirmed. Normal merging
            // resumes as soon as the replica reports the confirmed revision or later.
            if SyncRevisionContract.isRemoteBehind(
                observed: seasonMetadata.observedRevision(for: item.id),
                remote: item.serverRevision
            ) {
                print("[PruningSync] season \(item.id) pull ignored: replica at revision \(item.serverRevision.map(String.init) ?? "none") is behind confirmed \(seasonMetadata.observedRevision(for: item.id).map(String.init) ?? "none")")
                continue
            }
            pruningStore.applyRemoteSeasonUpsert(item.toPruningBlockSetup())
            seasonMetadata.setObservedRevision(item.serverRevision, for: item.id)
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
                if let result = try? await repository.recordEntry(
                    RecordPruningEntryParams(from: entry, clientUpdatedAt: now)
                ) {
                    adoptCanonicalSeason(for: entry, result: result)
                }
            }
        }

        // Entries with a queued create OR a queued edit keep their optimistic
        // local state until the push lands. A queued ACTIVITY protects every one
        // of its allocations the same way.
        let queuedActivityIds = Set(activityMetadata.pendingUpserts.keys)
            .union(activityEditMetadata.pendingUpserts.keys)
        let protectedAllocations = Set(
            queuedActivityIds.flatMap { activityId -> [UUID] in
                (pruningStore.activity(id: activityId)?.activeAllocations ?? [])
                    .map { $0.allocationId(for: activityId) }
            }
        )
        let protected = Set(entryMetadata.pendingUpserts.keys)
            .union(editMetadata.pendingUpserts.keys)
            .union(protectedAllocations)

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
