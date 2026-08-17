import Foundation
import Observation

/// A Resistance Plan write the server refused because the row had moved on (sql/198).
typealias ResistancePlanConflict = SyncRevisionConflict<ResistancePlan>

/// Table name used in conflict records and audit trails.
nonisolated let resistancePlansEntity: String = "resistance_plans"

/// Server contract for Resistance Plans (`public.resistance_plans`, sql/196 + sql/198).
///
/// Deliberately narrow: fetch the vineyard slice, write whole plan documents, tombstone
/// one plan. The Planner UI never sees this type — it talks to `ResistancePlanRepository`
/// — so a screen can never issue an ad-hoc query or depend on network availability to
/// render.
///
/// Mirrors `ResistancePlanRemote` on Android.
protocol ResistancePlanRemote: Sendable {
    /// The full vineyard slice, INCLUDING tombstoned plans.
    ///
    /// Tombstones are not an implementation detail that can be filtered server-side: a
    /// delete performed on another device is only observable to this one as a tombstone
    /// arriving in a pull. Hiding them would make the deleted plan look merely absent,
    /// and this device would helpfully push it back.
    func fetchAll(vineyardId: String) async throws -> [ResistancePlan]

    /// Versioned whole-document write, ONE OUTCOME PER PLAN.
    ///
    /// Per-plan outcomes rather than one batch result because conflicts are per-row: a
    /// single multi-row statement is one transaction, so one conflicting plan would abort
    /// the write of every other plan in the batch and strand edits that had nothing wrong
    /// with them. Plans are a handful per vineyard per season — correctness is worth the
    /// extra round trips.
    ///
    /// Each returned outcome is either `.applied` carrying the authoritative server row
    /// (with its NEW `server_revision`) or `.conflict`. Implementations MUST NOT throw for
    /// a conflict — a thrown conflict gets counted as a transport failure and blindly
    /// retried.
    func upsert(_ plans: [ResistancePlan]) async throws -> [VersionedWriteOutcome<ResistancePlan>]

    /// Tombstone one plan via the sql/196 soft-delete RPC.
    func softDelete(planId: String) async throws
}

/// Outcome of one sync pass. Returned rather than logged so tests can assert on it.
nonisolated struct ResistancePlanSyncResult: Sendable, Equatable {
    nonisolated var pushed: Int = 0
    nonisolated var pulled: Int = 0
    /// Plans uploaded by the one-time local-only adoption path.
    nonisolated var adopted: Int = 0
    /// Remote plans ignored because a newer local edit is still pending.
    nonisolated var keptLocal: Int = 0
    nonisolated var deletesPushed: Int = 0
    /// Plans the server refused on revision grounds. NOT failures: the pass itself
    /// succeeded, and these plans are queued with both versions preserved.
    nonisolated var conflicted: Int = 0
    /// Remote rows ignored because they were OLDER than a revision this device has already
    /// had confirmed — read-after-write replica lag, decided by revision and never a clock.
    nonisolated var staleRemoteIgnored: Int = 0
    /// Non-nil when the pass could not complete. Local state is always still usable.
    nonisolated var failure: String?

    nonisolated var isSuccess: Bool { failure == nil }

    /// True when this pass produced or left behind an unresolved conflict.
    nonisolated var hasConflicts: Bool { conflicted > 0 }
}

/// Where the plans currently on screen came from. Drives the sync badge in the plan list.
nonisolated enum ResistancePlanSyncState: String, Sendable, Hashable {
    /// No server configured / not signed in — plans are on this device only.
    case localOnly
    /// Everything local has been accepted by the server.
    case synced
    /// Local changes are waiting to upload.
    case pendingUpload
    /// A push is in flight.
    case syncing
    /// The last sync attempt failed. Plans remain readable and editable.
    case failed
    /// Someone else edited a plan this device had also edited. Both versions are kept.
    ///
    /// Distinct from `.failed` because the remedies are opposites: a failure wants a retry,
    /// a conflict CANNOT be fixed by retrying — the same `base_revision` will be refused
    /// every time — and needs a person to choose a version.
    case conflict

    /// Operator-facing explanation. Identical wording to Android.
    nonisolated var notice: String {
        switch self {
        case .localOnly:
            return "Resistance plans are saved on this device only until you sign in. "
                + "Once signed in they sync to your vineyard and your team."
        case .synced:
            return "Resistance plans are shared with your vineyard team and sync across devices."
        case .pendingUpload:
            return "Changes are saved on this device and will upload when you are back online."
        case .syncing:
            return "Syncing resistance plans…"
        case .failed:
            return "Could not sync resistance plans. Your changes are saved on this device and will retry."
        case .conflict:
            // Deliberately NOT "sync failed — retry": retrying is the one thing that cannot
            // work here, and offering it would train the grower to tap a button that
            // silently does nothing.
            return "Changes need review. This plan was also edited on another device — "
                + "both versions are saved, so you can choose which one to keep."
        }
    }
}

/// Offline-first, server-authoritative repository for Resistance Plans.
///
/// CONCURRENCY (sql/198): the authority for "is this edit stale?" is the server-issued
/// `server_revision`, never a device clock. Each cached plan remembers the revision it was
/// based on; an update sends that as `base_revision`; the server either applies the write
/// and advances the revision, or raises REVISION_CONFLICT. Wall-clock timestamps remain
/// ONLY for display, audit and "when did the grower edit this" — they no longer decide who
/// wins, because a clock records WHEN someone edited and not WHICH version they started
/// from.
///
/// WHY WRITES NEVER WAIT FOR THE SERVER: a grower plans a season standing in a block with
/// no signal. Every mutation commits to the local cache first and returns immediately; the
/// id is minted on the device, so a plan created offline already has its final identity and
/// can be edited, reordered and reopened before it has ever been uploaded. Waiting on
/// Supabase to allocate an id would make the feature unusable exactly where it is used.
///
/// WHAT IS NEVER SYNCED: engine output. No status, warning, counter or explanation is cached
/// or uploaded — only the plan definition. Verdicts are recomputed from current spray
/// history on every load (see `ResistancePlanner`), because the history changes underneath a
/// saved plan. A cached "Good fit" would be a stale compliance claim.
///
/// Mirrors `ResistancePlanRepository.kt` on Android.
@Observable
@MainActor
final class ResistancePlanRepository {

    /// Live (non-deleted) plans for the loaded vineyard, newest first.
    private(set) var plans: [ResistancePlan] = []
    private(set) var syncState: ResistancePlanSyncState
    private(set) var isLoaded: Bool = false
    /// Unresolved conflicts, both versions intact. Exposed so a future review screen can
    /// present them; nothing here resolves a conflict automatically.
    private(set) var conflicts: [ResistancePlanConflict] = []

    private let local: any ResistancePlanLocalStore
    private let remote: (any ResistancePlanRemote)?
    /// Device clock. Still used — for the grower's edit time, which is real metadata — but
    /// NOT for deciding whether a write is stale. See the type doc.
    private let clock: @Sendable () -> Int64
    private let currentUserId: @Sendable () -> String?
    private var vineyardId: String?

    init(
        local: any ResistancePlanLocalStore = ResistancePlanStore(),
        remote: (any ResistancePlanRemote)? = nil,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        currentUserId: @escaping @Sendable () -> String? = { nil }
    ) {
        self.local = local
        self.remote = remote
        self.clock = clock
        self.currentUserId = currentUserId
        self.syncState = remote == nil ? .localOnly : .synced
    }

    private func allCached(_ vineyard: String) -> [ResistancePlan] { local.loadAll(vineyardId: vineyard) }

    // MARK: - Loading

    /// Load a vineyard's plans from the local cache. Synchronous and offline-safe: the
    /// Planner opens on cached data and never blocks on a network round trip.
    func load(vineyardId: String) {
        self.vineyardId = vineyardId
        isLoaded = true
        conflicts = local.loadConflicts(vineyardId: vineyardId)
        publish(allCached(vineyardId))
        refreshSyncState()
    }

    /// Plans for a season and disease, newest first. Live plans only.
    func plans(seasonId: String, disease: ResistanceDisease) -> [ResistancePlan] {
        plans.filter { $0.seasonId == seasonId && $0.disease == disease }
    }

    func plan(id planId: String) -> ResistancePlan? { plans.first { $0.id == planId } }

    /// The unresolved conflict for a plan, if any.
    func conflict(id planId: String) -> ResistancePlanConflict? {
        conflicts.first { $0.rowId == planId }
    }

    // MARK: - Mutations — always local-first

    /// Create or update a plan.
    ///
    /// Commits locally and enqueues the id. Works identically online and offline; the
    /// caller gets no error to handle and no spinner to show, because nothing about the
    /// grower's edit depends on connectivity.
    ///
    /// The cached `server_revision` is re-stamped from the cache rather than trusted from
    /// the incoming plan. The revision is SERVER state: if an editor, a stale view or a
    /// copied value could carry a different number into a save, this device would end up
    /// asserting a `base_revision` it never actually read.
    func save(_ plan: ResistancePlan) {
        guard let vineyard = vineyardId else { return }
        let cached = allCached(vineyard)
        var stamped = plan
        if stamped.createdBy == nil { stamped.createdBy = currentUserId() }
        stamped.serverRevision = cached.first { $0.id == stamped.id }?.serverRevision
        let merged = cached.filter { $0.id != stamped.id } + [stamped]
        local.saveAll(vineyardId: vineyard, plans: merged)
        local.savePending(vineyardId: vineyard, ids: local.loadPending(vineyardId: vineyard).union([stamped.id]))
        publish(merged)
        refreshSyncState()
    }

    /// Soft-delete (archive) a plan.
    ///
    /// A tombstone, never a local erasure. Dropping the row locally would leave this device
    /// with nothing to tell the server about, so the plan would return on the next pull —
    /// and if this device were offline at the time, the delete would simply never happen.
    /// Deleting a plan removes advisory planning data only: no spray record, chemical or
    /// resistance history is touched, on the server (sql/196 has no FK into operational
    /// data) or here.
    func delete(id planId: String) {
        guard let vineyard = vineyardId else { return }
        let now = clock()
        let updated = allCached(vineyard).map { plan -> ResistancePlan in
            guard plan.id == planId else { return plan }
            var copy = plan
            copy.deletedAtEpochMs = now
            copy.updatedAtEpochMs = now
            return copy
        }
        local.saveAll(vineyardId: vineyard, plans: updated)
        local.savePending(vineyardId: vineyard, ids: local.loadPending(vineyardId: vineyard).union([planId]))
        publish(updated)
        refreshSyncState()
    }

    /// Undo an archive.
    func restore(id planId: String) {
        guard let vineyard = vineyardId else { return }
        let now = clock()
        let updated = allCached(vineyard).map { plan -> ResistancePlan in
            guard plan.id == planId else { return plan }
            var copy = plan
            copy.deletedAtEpochMs = nil
            copy.updatedAtEpochMs = now
            return copy
        }
        local.saveAll(vineyardId: vineyard, plans: updated)
        local.savePending(vineyardId: vineyard, ids: local.loadPending(vineyardId: vineyard).union([planId]))
        publish(updated)
        refreshSyncState()
    }

    // MARK: - Conflict resolution — explicit, never automatic

    /// Resolve a conflict by keeping THIS device's authored plan.
    ///
    /// Rebases the local document onto the server's current revision, so the next push
    /// carries a `base_revision` the server will accept. The document itself is untouched —
    /// this is the grower saying "my version is the one I want", not a merge.
    func resolveKeepingLocal(id planId: String) {
        guard let vineyard = vineyardId else { return }
        guard let conflict = conflicts.first(where: { $0.rowId == planId }) else { return }
        var rebased = conflict.localPending
        rebased.serverRevision = conflict.serverRevision ?? conflict.localPending.serverRevision
        let updated = allCached(vineyard).map { $0.id == planId ? rebased : $0 }
        local.saveAll(vineyardId: vineyard, plans: updated)
        local.savePending(vineyardId: vineyard, ids: local.loadPending(vineyardId: vineyard).union([planId]))
        clearConflicts(vineyard, ids: [planId])
        publish(updated)
        refreshSyncState(force: true)
    }

    /// Resolve a conflict by accepting the server's version and DISCARDING the local edit.
    ///
    /// Only ever called from an explicit user choice. Nothing in this repository decides
    /// this on the grower's behalf, and in particular never by comparing timestamps: both
    /// versions descend from the same revision, so "later" says nothing about which one is
    /// right (see sql/198 rationale).
    func resolveKeepingServer(id planId: String) {
        guard let vineyard = vineyardId else { return }
        guard let conflict = conflicts.first(where: { $0.rowId == planId }) else { return }
        let updated: [ResistancePlan]
        if let serverCopy = conflict.serverCurrent {
            updated = allCached(vineyard).map { $0.id == planId ? serverCopy : $0 }
        } else {
            updated = allCached(vineyard)
        }
        local.saveAll(vineyardId: vineyard, plans: updated)
        // Dequeued: the local edit has been deliberately abandoned, so there is nothing left
        // to push.
        local.savePending(
            vineyardId: vineyard,
            ids: local.loadPending(vineyardId: vineyard).subtracting([planId])
        )
        clearConflicts(vineyard, ids: [planId])
        publish(updated)
        refreshSyncState(force: true)
    }

    // MARK: - Sync

    /// One sync pass: adopt legacy local plans, push the outbox, pull and merge.
    ///
    /// Order matters. Pushing BEFORE pulling means a local edit is offered to the server
    /// (and arbitrated by the sql/198 revision guard) before any remote version can
    /// overwrite the cache, so an offline edit is never discarded by the very sync that was
    /// supposed to deliver it.
    ///
    /// The push set is the outbox MINUS plans with an unresolved conflict: those stay
    /// queued (their authored document exists nowhere else) but are not re-offered,
    /// because the same stale `base_revision` would be refused on every pass. Explicit
    /// resolution is what returns them to the push set.
    @discardableResult
    func sync(vineyardId: String) async -> ResistancePlanSyncResult {
        guard let server = remote else {
            syncState = .localOnly
            return ResistancePlanSyncResult()
        }
        self.vineyardId = vineyardId

        let adopted = adoptLocalOnlyPlans(vineyardId: vineyardId)

        var pushed = 0
        var deletesPushed = 0
        do {
            syncState = .syncing
            // Captured BEFORE the push and used for the merge decision below. The outbox is
            // deliberately NOT cleared until after the pull has been merged: a read that
            // lands on a lagging replica can return the pre-push row, and if the outbox were
            // already empty that stale row would look authoritative and overwrite the newer
            // edit the grower is looking at.
            let pending = local.loadPending(vineyardId: vineyardId)
            var remainingPending = pending
            // Ids the server ACCEPTED this pass, mapped to the authoritative row it
            // returned. Those rows carry the new `server_revision`, which is the only way
            // this device learns what version its edit became.
            var applied: [String: ResistancePlan] = [:]
            var conflictedRevisions: [String: (base: Int64?, server: Int64?)] = [:]

            if !pending.isEmpty {
                let cached = allCached(vineyardId)
                // A plan with an UNRESOLVED CONFLICT is not re-offered. Replaying it would
                // resend the same stale `base_revision`, which the server refuses every
                // time — a retry loop that burns battery, keeps the badge flickering and
                // can never converge. The plan STAYS QUEUED (its authored edit exists
                // nowhere else); it re-enters the push set only when an explicit
                // resolution either rebases it (keep local) or dequeues it (keep server).
                let conflictedIds = Set(local.loadConflicts(vineyardId: vineyardId).map { $0.rowId })
                let toPush = cached.filter { pending.contains($0.id) && !conflictedIds.contains($0.id) }

                // Write the full document for every pending plan, tombstoned or not. The
                // tombstone must reach the server as a row update first, so a plan created
                // AND deleted while offline still exists to be soft-deleted.
                let live = toPush.filter { !$0.isDeleted }
                if !live.isEmpty {
                    for outcome in try await server.upsert(live) {
                        switch outcome {
                        case .applied(let row):
                            applied[row.id] = row
                            pushed += 1
                        case .conflict(let rowId, let base, let serverRevision):
                            conflictedRevisions[rowId] = (base, serverRevision)
                        }
                    }
                }
                for tombstoned in toPush.filter({ $0.isDeleted }) {
                    var revived = tombstoned
                    revived.deletedAtEpochMs = nil
                    let outcomes = try await server.upsert([revived])
                    if case .conflict(_, let base, let serverRevision) = outcomes.first {
                        // A delete that lost a race is still a conflict: the other device's
                        // edit may be exactly what the grower would want to keep.
                        conflictedRevisions[tombstoned.id] = (base, serverRevision)
                        continue
                    }
                    try await server.softDelete(planId: tombstoned.id)
                    deletesPushed += 1
                    applied.removeValue(forKey: tombstoned.id)
                    remainingPending.remove(tombstoned.id)
                }

                // Only ids the server ACCEPTED are dropped from the outbox. A conflicted id
                // stays queued — its edit exists nowhere else. An id that vanished from the
                // cache is dropped too, so a deleted-then-purged plan cannot wedge the
                // outbox forever.
                let orphans = pending.subtracting(Set(cached.map { $0.id }))
                remainingPending = remainingPending
                    .subtracting(Set(applied.keys))
                    .subtracting(orphans)
            }

            if adopted > 0 { local.markAdopted(vineyardId: vineyardId) }

            // Apply the authoritative returned rows immediately. This is what teaches the
            // cache its new `server_revision`; without it the next edit would resend the OLD
            // base_revision and be refused for no reason.
            if !applied.isEmpty {
                local.saveAll(
                    vineyardId: vineyardId,
                    plans: allCached(vineyardId).map { applied[$0.id] ?? $0 }
                )
            }

            let remotePlans = try await server.fetchAll(vineyardId: vineyardId)
            // Plans whose local copy must survive the pull: still-queued edits (never
            // offered, or offered and refused). A just-accepted plan is NOT in this set —
            // its server row is the authority now.
            let keepLocalIds = pending
                .subtracting(Set(applied.keys))
                .union(Set(conflictedRevisions.keys))
            let merge = Self.merge(
                local: allCached(vineyardId),
                remote: remotePlans,
                keepLocalIds: keepLocalIds
            )
            local.saveAll(vineyardId: vineyardId, plans: merge.plans)

            // Record conflicts with BOTH documents. The server copy comes from the pull we
            // just did, so the grower can see what the other device actually saved.
            if !conflictedRevisions.isEmpty {
                recordConflicts(
                    vineyardId: vineyardId,
                    revisions: conflictedRevisions,
                    localById: Dictionary(merge.plans.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }),
                    remoteById: Dictionary(remotePlans.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                )
            }

            // Safe to shrink the outbox only now that the pull has been reconciled. A plan
            // whose newer local copy was kept stays queued, so the next pass retries it
            // instead of leaving this device permanently ahead of the server.
            local.savePending(
                vineyardId: vineyardId,
                ids: remainingPending
                    .union(merge.keptLocalIds)
                    .union(Set(conflictedRevisions.keys))
            )
            publish(merge.plans)
            // `force` because a pass that has just SUCCEEDED must be able to clear a
            // previous `.failed` state. Without it the badge stays red forever after one
            // dropout and stops meaning anything.
            refreshSyncState(force: true)

            return ResistancePlanSyncResult(
                pushed: pushed,
                pulled: merge.acceptedRemote,
                adopted: adopted,
                keptLocal: merge.keptLocal,
                deletesPushed: deletesPushed,
                conflicted: conflictedRevisions.count,
                staleRemoteIgnored: merge.staleRemoteIgnored
            )
        } catch {
            // Everything stays in the cache and in the outbox. The grower keeps working; the
            // next successful pass replays. A conflict never arrives here — the remote
            // returns it as an outcome precisely so it cannot be mistaken for this.
            syncState = .failed
            return ResistancePlanSyncResult(
                pushed: pushed,
                adopted: adopted,
                deletesPushed: deletesPushed,
                failure: error.localizedDescription
            )
        }
    }

    /// One-time adoption of Planner v1 local-only plans.
    ///
    /// Existing users have plans in `UserDefaults` that the server has never seen, so only
    /// this device can supply them — there is no SQL backfill that could. Each keeps its
    /// EXISTING id, which is what makes the upload idempotent: a repeated run upserts the
    /// same primary key instead of minting a second copy of the same season plan.
    ///
    /// Returns the number of plans enqueued. The adopted flag is set only AFTER the push
    /// succeeds (see `sync`), so a mid-migration network failure leaves the plans local,
    /// usable and still queued rather than marked done and silently unsynced.
    private func adoptLocalOnlyPlans(vineyardId: String) -> Int {
        guard remote != nil else { return 0 }
        guard !local.isAdopted(vineyardId: vineyardId) else { return 0 }
        let existing = allCached(vineyardId)
        guard !existing.isEmpty else {
            // Nothing to carry across; record completion so this never runs again.
            local.markAdopted(vineyardId: vineyardId)
            return 0
        }
        local.savePending(
            vineyardId: vineyardId,
            ids: local.loadPending(vineyardId: vineyardId).union(Set(existing.map { $0.id }))
        )
        return existing.count
    }

    private func recordConflicts(
        vineyardId: String,
        revisions: [String: (base: Int64?, server: Int64?)],
        localById: [String: ResistancePlan],
        remoteById: [String: ResistancePlan]
    ) {
        let now = clock()
        var existing = Dictionary(
            local.loadConflicts(vineyardId: vineyardId).map { ($0.rowId, $0) },
            uniquingKeysWith: { _, new in new }
        )
        for (planId, pair) in revisions {
            guard let localPlan = localById[planId] else { continue }
            existing[planId] = ResistancePlanConflict(
                rowId: planId,
                entity: resistancePlansEntity,
                localPending: localPlan,
                serverCurrent: remoteById[planId],
                baseRevision: pair.base,
                serverRevision: pair.server ?? remoteById[planId]?.serverRevision,
                detectedAtEpochMs: now
            )
        }
        let all = Array(existing.values)
        local.saveConflicts(vineyardId: vineyardId, conflicts: all)
        conflicts = all
    }

    private func clearConflicts(_ vineyard: String, ids: Set<String>) {
        let remaining = local.loadConflicts(vineyardId: vineyard).filter { !ids.contains($0.rowId) }
        local.saveConflicts(vineyardId: vineyard, conflicts: remaining)
        conflicts = remaining
    }

    nonisolated struct MergeOutcome: Sendable {
        nonisolated var plans: [ResistancePlan]
        nonisolated var acceptedRemote: Int
        nonisolated var keptLocal: Int
        nonisolated var keptLocalIds: Set<String> = []
        nonisolated var staleRemoteIgnored: Int = 0
    }

    /// Whole-document reconciliation, arbitrated by REVISION.
    ///
    /// Two independent reasons to keep the local copy:
    ///
    ///   1. `keepLocalIds` — the grower has an edit the server has not accepted. It exists on
    ///      this device and nowhere else, so a pull must not paint over it.
    ///   2. The remote row is at an OLDER revision than one this device has already had
    ///      confirmed. That is read-after-write replica lag, and it used to be detected by
    ///      comparing device timestamps — which failed in exactly the case it mattered,
    ///      because a slow phone's "newer" edit looks older than the row it just wrote.
    ///      Revisions are monotonic and server-issued, so the comparison is now sound.
    ///
    /// Position arrays are NEVER merged element-by-element: there is no defensible automatic
    /// reconciliation of "A moved the Group 11 spray earlier" against "B removed that
    /// spray", and any row-wise merge could produce a spray sequence that neither operator
    /// authored and then present it as resistance-compliant. Preserving both authored
    /// documents is recoverable; inventing a third plan is not.
    nonisolated static func merge(
        local: [ResistancePlan],
        remote: [ResistancePlan],
        keepLocalIds: Set<String>
    ) -> MergeOutcome {
        var order: [String] = local.map { $0.id }
        var byId: [String: ResistancePlan] = Dictionary(
            local.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )

        var accepted = 0
        var staleRemote = 0
        var keptIds: Set<String> = []
        for row in remote {
            let mine = byId[row.id]
            if mine != nil, keepLocalIds.contains(row.id) {
                keptIds.insert(row.id)
                continue
            }
            if let mine, Self.isRemoteBehind(mine: mine, row: row) {
                staleRemote += 1
                continue
            }
            if byId[row.id] == nil { order.append(row.id) }
            byId[row.id] = row
            accepted += 1
        }
        return MergeOutcome(
            plans: order.compactMap { byId[$0] },
            acceptedRemote: accepted,
            keptLocal: keptIds.count,
            keptLocalIds: keptIds,
            staleRemoteIgnored: staleRemote
        )
    }

    /// True when the pulled row is at a strictly OLDER server revision than the copy this
    /// device already holds — i.e. the read went to a replica that has not caught up.
    ///
    /// Returns false when either side has no revision: a legacy row (written by an old
    /// client, or cached before sql/198) is NOT evidence of lag, and treating an unknown
    /// revision as "behind" would make such rows permanently unpullable.
    nonisolated static func isRemoteBehind(mine: ResistancePlan, row: ResistancePlan) -> Bool {
        guard let localRevision = mine.serverRevision else { return false }
        guard let remoteRevision = row.serverRevision else { return false }
        return remoteRevision < localRevision
    }

    // MARK: - Internals

    private func publish(_ all: [ResistancePlan]) {
        plans = all
            .filter { !$0.isDeleted }
            .sorted { $0.updatedAtEpochMs > $1.updatedAtEpochMs }
    }

    private func refreshSyncState(force: Bool = false) {
        guard let vineyard = vineyardId else { return }
        guard remote != nil else { syncState = .localOnly; return }
        // A conflict outranks every other state. It is the only one that needs a person, and
        // showing "will retry" over the top of it would promise something the app cannot
        // deliver: the same base_revision is refused every time.
        if !conflicts.isEmpty { syncState = .conflict; return }
        // A local edit must not silently downgrade a `.failed` badge to `.pendingUpload`:
        // the last attempt really did fail, and the grower should keep seeing that until a
        // pass actually succeeds.
        guard force || syncState != .failed else { return }
        syncState = local.loadPending(vineyardId: vineyard).isEmpty ? .synced : .pendingUpload
    }

    /// Pending-upload count, for the plan list badge.
    func pendingCount() -> Int {
        guard let vineyard = vineyardId else { return 0 }
        return local.loadPending(vineyardId: vineyard).count
    }

    /// Unresolved-conflict count, for the plan list badge.
    func conflictCount() -> Int { conflicts.count }
}
