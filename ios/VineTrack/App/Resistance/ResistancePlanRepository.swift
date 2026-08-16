import Foundation
import Observation

/// Server contract for Resistance Plans (`public.resistance_plans`, sql/196).
///
/// Deliberately narrow: fetch the vineyard slice, upsert whole plan documents, tombstone
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
    /// Upsert whole plan documents. Idempotent on plan id.
    func upsert(_ plans: [ResistancePlan]) async throws
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
    /// Non-nil when the pass could not complete. Local state is always still usable.
    nonisolated var failure: String?

    nonisolated var isSuccess: Bool { failure == nil }
}

/// Where the plans currently on screen came from. Drives the sync badge in the plan list.
nonisolated enum ResistancePlanSyncState: String, Sendable, Hashable {
    /// No server configured / not signed in — plans are on this device only.
    case localOnly
    /// Everything local has been accepted by the server.
    case synced
    /// Local changes are waiting to upload.
    case pendingUpload
    /// The last sync attempt failed. Plans remain readable and editable.
    case failed

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
        case .failed:
            return "Could not sync resistance plans. Your changes are saved on this device and will retry."
        }
    }
}

/// Offline-first, server-authoritative repository for Resistance Plans.
///
/// ARCHITECTURE (audited against VineTrack's existing sync patterns before writing): this
/// follows the same shape as `PickingRecordSyncService` and the pruning services — a local
/// cache, an id-keyed outbox of pending writes, push-then-pull, and `client_updated_at`
/// last-write-wins arbitrated by the sql/185 stale-write trigger. No new sync framework was
/// invented, and the Planner UI's dependency direction is unchanged: it holds a repository,
/// never a Supabase client.
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

    private let local: any ResistancePlanLocalStore
    private let remote: (any ResistancePlanRemote)?
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
        publish(allCached(vineyardId))
        refreshSyncState()
    }

    /// Plans for a season and disease, newest first. Live plans only.
    func plans(seasonId: String, disease: ResistanceDisease) -> [ResistancePlan] {
        plans.filter { $0.seasonId == seasonId && $0.disease == disease }
    }

    func plan(id planId: String) -> ResistancePlan? { plans.first { $0.id == planId } }

    // MARK: - Mutations — always local-first

    /// Create or update a plan.
    ///
    /// Commits locally and enqueues the id. Works identically online and offline; the
    /// caller gets no error to handle and no spinner to show, because nothing about the
    /// grower's edit depends on connectivity.
    func save(_ plan: ResistancePlan) {
        guard let vineyard = vineyardId else { return }
        var stamped = plan
        if stamped.createdBy == nil { stamped.createdBy = currentUserId() }
        let merged = allCached(vineyard).filter { $0.id != stamped.id } + [stamped]
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

    // MARK: - Sync

    /// One sync pass: adopt legacy local plans, push the outbox, pull and merge.
    ///
    /// Order matters. Pushing BEFORE pulling means a local edit is offered to the server
    /// (and arbitrated by the sql/185 stale-write guard) before any remote version can
    /// overwrite the cache, so an offline edit is never discarded by the very sync that was
    /// supposed to deliver it.
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
            // Captured BEFORE the push and used for the merge decision below. The outbox is
            // deliberately NOT cleared until after the pull has been merged: a read that
            // lands on a lagging replica can return the pre-push row, and if the outbox were
            // already empty that stale row would look authoritative and overwrite the newer
            // edit the grower is looking at.
            let pending = local.loadPending(vineyardId: vineyardId)
            var remainingPending = pending
            if !pending.isEmpty {
                let cached = allCached(vineyardId)
                let toPush = cached.filter { pending.contains($0.id) }

                // Upsert the full document for every pending plan, tombstoned or not. The
                // tombstone must reach the server as a row update first, so a plan created
                // AND deleted while offline still exists to be soft-deleted.
                let live = toPush.filter { !$0.isDeleted }
                if !live.isEmpty {
                    try await server.upsert(live)
                    pushed = live.count
                }
                for tombstoned in toPush.filter({ $0.isDeleted }) {
                    var revived = tombstoned
                    revived.deletedAtEpochMs = nil
                    try await server.upsert([revived])
                    try await server.softDelete(planId: tombstoned.id)
                    deletesPushed += 1
                }

                // Only ids we actually attempted are dropped. An id that vanished from the
                // cache is dropped too, so a deleted-then-purged plan cannot wedge the
                // outbox forever.
                let attempted = Set(toPush.map { $0.id })
                let orphans = pending.subtracting(Set(cached.map { $0.id }))
                remainingPending = pending.subtracting(attempted).subtracting(orphans)
            }

            if adopted > 0 { local.markAdopted(vineyardId: vineyardId) }

            let remotePlans = try await server.fetchAll(vineyardId: vineyardId)
            let merge = Self.merge(
                local: allCached(vineyardId),
                remote: remotePlans,
                pending: pending
            )
            local.saveAll(vineyardId: vineyardId, plans: merge.plans)
            // Safe to shrink the outbox only now that the pull has been reconciled. A plan
            // whose newer local copy was kept stays queued, so the next pass retries it
            // instead of leaving this device permanently ahead of the server.
            local.savePending(
                vineyardId: vineyardId,
                ids: remainingPending.union(merge.keptLocalIds)
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
                deletesPushed: deletesPushed
            )
        } catch {
            // Everything stays in the cache and in the outbox. The grower keeps working;
            // the next successful pass replays.
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

    nonisolated struct MergeOutcome: Sendable {
        nonisolated var plans: [ResistancePlan]
        nonisolated var acceptedRemote: Int
        nonisolated var keptLocal: Int
        nonisolated var keptLocalIds: Set<String> = []
    }

    /// Whole-document last-write-wins.
    ///
    /// A remote plan is adopted UNLESS this device still holds an unpushed edit that is
    /// strictly newer. Position arrays are NEVER merged element-by-element: there is no
    /// defensible automatic reconciliation of "A moved the Group 11 spray earlier" against
    /// "B removed that spray", and any row-wise merge could produce a spray sequence that
    /// neither operator authored and then present it as resistance-compliant. Losing the
    /// older edit is visible and recoverable; inventing a third plan is not.
    nonisolated static func merge(
        local: [ResistancePlan],
        remote: [ResistancePlan],
        pending: Set<String>
    ) -> MergeOutcome {
        var order: [String] = local.map { $0.id }
        var byId: [String: ResistancePlan] = Dictionary(
            local.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )

        var accepted = 0
        var keptIds: Set<String> = []
        for row in remote {
            let mine = byId[row.id]
            let hasNewerLocalEdit = mine != nil
                && pending.contains(row.id)
                && (mine?.updatedAtEpochMs ?? 0) > row.updatedAtEpochMs
            if hasNewerLocalEdit {
                keptIds.insert(row.id)
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
            keptLocalIds: keptIds
        )
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
}
