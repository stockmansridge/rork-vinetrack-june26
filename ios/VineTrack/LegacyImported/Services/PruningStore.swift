import Foundation
import Observation

/// Admin diagnostic over the pruning activity cache. Every count should be
/// zero; each non-zero count names a specific way the parent-activity cache and
/// the legacy projected entries have fallen out of step.
nonisolated struct PruningActivityCacheAudit: Sendable, Equatable {
    /// Parent activities that exist locally but hold no allocation at all.
    var parentsWithoutAllocations: Int
    /// Allocations with no completed quarters locally, on activities whose
    /// server roll-up says quarters exist — detail was never adopted.
    var allocationsMissingSegmentDetail: Int
    /// Projected entries whose parent activity is no longer in the cache.
    var orphanedProjectedEntries: Int
    /// Blocks where the projected entries and the parent drafts disagree about
    /// how many quarters are complete.
    var blockProgressMismatches: Int
    /// Activities queued for a `get_pruning_activity` repair.
    var activityIdsNeedingDetail: [UUID]

    var isHealthy: Bool {
        parentsWithoutAllocations == 0
            && allocationsMissingSegmentDetail == 0
            && orphanedProjectedEntries == 0
            && blockProgressMismatches == 0
    }

    /// One-line summary for the diagnostic screen and the sync log.
    var summary: String {
        isHealthy
            ? "Pruning activity cache is consistent"
            : """
            \(parentsWithoutAllocations) parent(s) with no allocations · \
            \(allocationsMissingSegmentDetail) allocation(s) missing quarter detail · \
            \(orphanedProjectedEntries) orphaned projected row(s) · \
            \(blockProgressMismatches) block progress mismatch(es)
            """
    }
}

/// Offline-first store for the Pruning Tracker (System Admin only while in
/// development). Acts as the local cache for the shared `pruning_seasons` /
/// `pruning_entries` / `pruning_row_segments` Supabase tables:
///
/// * every write lands here first (instant UI, works offline) and fires a
///   change hook that `PruningSyncService` uses to queue the push,
/// * remote state is applied through the `applyRemote*` methods, which never
///   re-fire the hooks.
///
/// Storage note: v1 development data lived in UserDefaults and was device-only
/// test data — it is intentionally discarded by the move to the shared
/// `PersistenceStore` under new v2 keys.
@Observable
final class PruningStore {
    static let shared = PruningStore()

    private(set) var setups: [PruningBlockSetup] = []
    private(set) var entries: [PruningEntry] = []
    /// Offline drafts of multi-block pruning ACTIVITIES (sql/166). The COMPLETE
    /// activity is persisted — parent fields plus EVERY block allocation — so an
    /// offline draft is never partially saved and reopening it restores every
    /// block, not only the one that happened to be on screen.
    private(set) var activities: [PruningActivityDraft] = []

    /// Sync hooks — fired for local user edits only, never for remote applies.
    var onSeasonChanged: ((UUID) -> Void)?
    var onSeasonDeleted: ((UUID) -> Void)?
    var onEntryRecorded: ((UUID) -> Void)?
    var onEntryEdited: ((UUID) -> Void)?
    var onEntryDeleted: ((UUID) -> Void)?
    /// Fired when a multi-block activity is created or edited locally.
    /// `isNew` routes the push to `record_pruning_activity` vs
    /// `update_pruning_activity`.
    var onActivitySaved: ((UUID, Bool) -> Void)?
    var onActivityReversed: ((UUID) -> Void)?

    private static let setupsKey = "vinetrack_pruning_seasons_v2"
    private static let entriesKey = "vinetrack_pruning_entries_v2"
    private static let activitiesKey = "vinetrack_pruning_activities_v1"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        setups = persistence.load(key: Self.setupsKey) ?? []
        entries = persistence.load(key: Self.entriesKey) ?? []
        activities = persistence.load(key: Self.activitiesKey) ?? []
    }

    // MARK: Seasons (block setups)

    /// The block's setup for TODAY's pruning season (sql/161 canonical rule).
    /// Falls back to the most recent PAST season when the current year has no
    /// row yet, and only then to a future-dated row — a stray season created
    /// under next year (e.g. a portal row keyed by the vintage) must never
    /// hijack the block the way `max(seasonYear)` used to.
    func setup(for paddockId: UUID) -> PruningBlockSetup? {
        setup(for: paddockId, seasonYear: PruningSeasonId.currentSeasonYear)
    }

    /// The block's setup for a specific pruning season year, with the same
    /// deterministic fallback order. Shared with Android's
    /// `PruningSeasonSelection.setupFor`.
    func setup(for paddockId: UUID, seasonYear: Int) -> PruningBlockSetup? {
        let blockSetups = setups.filter { $0.paddockId == paddockId }
        if let exact = blockSetups.first(where: { $0.seasonYear == seasonYear }) { return exact }
        if let previous = blockSetups
            .filter({ $0.seasonYear < seasonYear })
            .max(by: { $0.seasonYear < $1.seasonYear }) {
            return previous
        }
        return blockSetups.min(by: { $0.seasonYear < $1.seasonYear })
    }

    /// The season row a record dated `date` belongs to — the ONLY selector the
    /// record path may use.
    func setup(for paddockId: UUID, on date: Date) -> PruningBlockSetup? {
        setups.first { $0.paddockId == paddockId && $0.seasonYear == PruningSeasonId.seasonYear(for: date) }
    }

    func upsertSetup(_ setup: PruningBlockSetup) {
        applySeasonUpsert(setup)
        persistSetups()
        onSeasonChanged?(setup.id)
    }

    // MARK: Entries

    /// Every entry that still counts as work done. Reversed entries are kept
    /// in `entries` purely as Activity Report audit history and must never
    /// reach a progress, rate or forecast calculation.
    var activeEntries: [PruningEntry] { entries.filter { !$0.isReversed } }

    func entries(for paddockId: UUID) -> [PruningEntry] {
        entries
            .filter { $0.paddockId == paddockId && !$0.isReversed }
            .sorted { $0.date > $1.date }
    }

    func entries(forVineyard vineyardId: UUID) -> [PruningEntry] {
        entries.filter { $0.vineyardId == vineyardId && !$0.isReversed }
    }

    /// Audit view for the Pruning Activity Report — active AND reversed
    /// entries for the vineyard, newest first.
    func auditEntries(forVineyard vineyardId: UUID) -> [PruningEntry] {
        entries
            .filter { $0.vineyardId == vineyardId }
            .sorted {
                $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date
            }
    }

    func addEntry(_ entry: PruningEntry) {
        entries.append(entry)
        persistEntries()
        onEntryRecorded?(entry.id)
    }

    /// Local-first edit of an existing entry — fires the edit hook so the
    /// sync layer queues an `update_pruning_entry` push (or folds the change
    /// into a still-pending create).
    func updateEntry(_ entry: PruningEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persistEntries()
        onEntryEdited?(entry.id)
    }

    /// Reverses an entry. The row is RETAINED locally (flagged `reversedAt`)
    /// so the Activity Report keeps the audit trail; every calculation path
    /// already filters reversed entries out, so progress reverts exactly as
    /// before. The queued push is still `delete_pruning_entry`.
    func deleteEntry(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            onEntryDeleted?(id)
            return
        }
        if entries[index].reversedAt == nil {
            entries[index].reversedAt = Date()
        }
        persistEntries()
        onEntryDeleted?(id)
    }

    // MARK: Multi-block activities (sql/166)

    func activities(forVineyard vineyardId: UUID) -> [PruningActivityDraft] {
        activities
            .filter { $0.vineyardId == vineyardId }
            .sorted { $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date }
    }

    func activity(id: UUID) -> PruningActivityDraft? {
        activities.first { $0.id == id }
    }

    /// Local-first save of a multi-block activity. The whole draft is persisted
    /// AND projected onto the legacy per-block entries, so every existing
    /// progress, rate, forecast and report screen keeps working. Labour rides on
    /// the primary allocation only, so no total double-counts it.
    ///
    /// Allocations the edit dropped are flagged reversed rather than deleted —
    /// the Activity Report keeps the audit trail while every calculation path
    /// already excludes them.
    @discardableResult
    func saveActivity(_ draft: PruningActivityDraft) -> PruningActivityDraft {
        let previous = activity(id: draft.id)
        let cleaned = PruningAllocationEditor.pruneEmptyBlocks(draft)
        let kept = Set(cleaned.activeAllocations.map { $0.allocationId(for: cleaned.id) })
        let stale = Set((previous?.activeAllocations ?? []).map { $0.allocationId(for: cleaned.id) })
            .subtracting(kept)

        if let index = activities.firstIndex(where: { $0.id == cleaned.id }) {
            activities[index] = cleaned
        } else {
            activities.append(cleaned)
        }
        mergeActivityEntries(PruningAllocationEditor.toLegacyEntries(cleaned), staleAllocationIds: stale)
        persistActivities()
        persistEntries()
        // A create that has not been acknowledged yet keeps replaying through
        // the record RPC: its payload carries the FULL desired state.
        onActivitySaved?(cleaned.id, previous == nil || !(previous?.serverAcknowledged ?? false))
        return cleaned
    }

    /// Reverses the whole activity — one operation, every allocation inherits it.
    func reverseActivity(id: UUID) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else {
            onActivityReversed?(id)
            return
        }
        if activities[index].reversedAt == nil {
            activities[index].reversedAt = Date()
        }
        let now = Date()
        for allocation in activities[index].activeAllocations {
            let allocationId = allocation.allocationId(for: id)
            if let entryIndex = entries.firstIndex(where: { $0.id == allocationId }),
               entries[entryIndex].reversedAt == nil {
                entries[entryIndex].reversedAt = now
            }
        }
        persistActivities()
        persistEntries()
        onActivityReversed?(id)
    }

    /// Replaces the local activity and ALL its allocations with the canonical
    /// server state (sql/166). No hook fires — adopting the server's own answer
    /// is not a user edit and must never re-queue a push.
    func adoptCanonicalActivity(id: UUID, canonical: BackendPruningActivityCanonical) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        let before = activities[index]
        let scope = PruningCanonicalScope(canonical)
        let adopted = PruningAllocationEditor.adoptCanonical(
            before,
            canonical: canonical,
            knownSegments: projectedSegments(for: canonical)
        )
        activities[index] = adopted
        mergeActivityEntries(
            PruningAllocationEditor.toLegacyEntries(adopted),
            staleAllocationIds: staleAllocationIds(previous: before, canonical: canonical),
            replaceSegments: scope.replacesSegments
        )
        persistActivities()
        persistEntries()
    }

    /// Adopts a canonical activity PULLED from the server (`get_pruning_activity`
    /// / `list_pruning_activities`), inserting it when this device has never seen
    /// it. No hook fires — a pull is not a user edit and must never re-queue a
    /// push. Returns the adopted draft.
    @discardableResult
    func applyRemoteActivity(_ canonical: BackendPruningActivityCanonical) -> PruningActivityDraft? {
        guard let activity = canonical.activity, let id = activity.id, let vineyardId = activity.vineyardId else {
            return nil
        }
        let base = self.activity(id: id) ?? PruningActivityDraft(
            id: id,
            vineyardId: vineyardId,
            date: PruningSyncDate.date(fromYmd: activity.entryDate) ?? Date(),
            createdAt: activity.createdAt ?? Date(),
            enteredBy: activity.createdBy
        )
        let scope = PruningCanonicalScope(canonical)
        let adopted = PruningAllocationEditor.adoptCanonical(
            base,
            canonical: canonical,
            knownSegments: projectedSegments(for: canonical)
        )
        if let index = activities.firstIndex(where: { $0.id == id }) {
            activities[index] = adopted
        } else {
            activities.append(adopted)
        }
        mergeActivityEntries(
            PruningAllocationEditor.toLegacyEntries(adopted),
            staleAllocationIds: staleAllocationIds(previous: base, canonical: canonical),
            replaceSegments: scope.replacesSegments
        )
        persistActivities()
        persistEntries()
        return adopted
    }

    /// Quarters already held by the LEGACY projected entry of each allocation
    /// whose detail this response withheld.
    ///
    /// Those entries carry the server's own `pruning_row_segments` attribution
    /// (pulled independently of the activity feed), so they let a summary
    /// refresh — or a reinstalled device seeing an activity for the first time —
    /// rehydrate real quarters instead of adopting an empty set.
    private func projectedSegments(
        for canonical: BackendPruningActivityCanonical
    ) -> [UUID: [PruningSegment]] {
        var known: [UUID: [PruningSegment]] = [:]
        for allocation in canonical.allocations where !allocation.hasSegmentDetail {
            guard let entry = entries.first(where: { $0.id == allocation.id }),
                  !entry.segments.isEmpty else { continue }
            known[allocation.id] = entry.segments
        }
        return known
    }

    /// The allocations the SERVER no longer lists — the ONLY ones a pull may
    /// reverse.
    ///
    /// Absence from the canonical allocation set is authoritative and is stated
    /// in both response fidelities, so it is safe to act on. A locally HOLLOW
    /// allocation — one the server still lists but whose quarters this response
    /// withheld — is emphatically not stale. Deriving staleness from "has no
    /// segments" instead is what reversed every projected entry of a
    /// perfectly healthy activity on each list refresh, erasing its progress.
    private func staleAllocationIds(
        previous: PruningActivityDraft,
        canonical: BackendPruningActivityCanonical
    ) -> Set<UUID> {
        let live = Set(canonical.allocations.map(\.paddockId))
        return Set(
            previous.activeAllocations
                .filter { !live.contains($0.paddockId) }
                .map { $0.allocationId(for: previous.id) }
        )
    }

    /// Merges a projection into the legacy entry cache.
    ///
    /// `replaceSegments` is false for a summary-scoped adopt: parent metadata is
    /// refreshed, but the entry's completed quarters — the single source of
    /// truth for progress — are left exactly as they are. Only a detailed
    /// canonical record may rewrite them.
    private func mergeActivityEntries(
        _ incoming: [PruningEntry],
        staleAllocationIds: Set<UUID>,
        replaceSegments: Bool = true
    ) {
        let now = Date()
        for entry in incoming {
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                var merged = entry
                if !replaceSegments {
                    merged.segments = entries[index].segments
                }
                entries[index] = merged
            } else {
                entries.append(entry)
            }
        }
        for id in staleAllocationIds {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
            if entries[index].reversedAt == nil { entries[index].reversedAt = now }
        }
    }

    /// Local activities whose server roll-up exceeds what this device holds —
    /// the repair queue for `get_pruning_activity`, newest first.
    func activitiesNeedingCanonicalDetail(vineyardId: UUID) -> [PruningActivityDraft] {
        activities(forVineyard: vineyardId).filter(\.needsCanonicalDetail)
    }

    /// Admin diagnostic: counts every way the two local representations of an
    /// activity — the parent draft with its allocations, and the legacy
    /// projected entries progress is calculated from — can disagree.
    ///
    /// All four counts should be zero. A non-zero count is a cache defect, not a
    /// data-entry problem, and names which repair is needed.
    func auditActivityCache(vineyardId: UUID) -> PruningActivityCacheAudit {
        let drafts = activities(forVineyard: vineyardId)
        let live = drafts.filter { !$0.isReversed }
        let draftIds = Set(drafts.map(\.id))

        let parentsWithoutAllocations = live.filter { $0.activeAllocations.isEmpty }.count

        // Allocations the server says hold quarters but which are locally empty.
        let hollowAllocations = live.reduce(into: 0) { total, draft in
            guard (draft.serverQuarters ?? 0) > 0 else { return }
            total += draft.allocations.values.filter(\.isEmpty).count
        }

        // Projected rows whose parent activity is no longer in the cache. A
        // legacy single-block entry is its OWN activity, so an entry whose
        // activity id equals its own id is not an orphan.
        let orphanedProjectedEntries = entries.filter { entry in
            guard entry.vineyardId == vineyardId,
                  let activityId = entry.pruningActivityId,
                  activityId != entry.id else { return false }
            return !draftIds.contains(activityId)
        }.count

        // Per block: quarters the projected entries carry vs quarters the parent
        // drafts claim. Progress reads the former, the breakdown shows the
        // latter, so any difference is visible to the user as a contradiction.
        var fromEntries: [UUID: Int] = [:]
        for entry in entries where entry.vineyardId == vineyardId && !entry.isReversed {
            guard let activityId = entry.pruningActivityId, draftIds.contains(activityId) else { continue }
            fromEntries[entry.paddockId, default: 0] += entry.segments.count
        }
        var fromDrafts: [UUID: Int] = [:]
        for draft in live {
            for allocation in draft.activeAllocations {
                fromDrafts[allocation.paddockId, default: 0] += allocation.quarters
            }
        }
        let blockProgressMismatches = Set(fromEntries.keys).union(fromDrafts.keys)
            .filter { (fromEntries[$0] ?? 0) != (fromDrafts[$0] ?? 0) }
            .count

        return PruningActivityCacheAudit(
            parentsWithoutAllocations: parentsWithoutAllocations,
            allocationsMissingSegmentDetail: hollowAllocations,
            orphanedProjectedEntries: orphanedProjectedEntries,
            blockProgressMismatches: blockProgressMismatches,
            activityIdsNeedingDetail: live.filter(\.needsCanonicalDetail).map(\.id)
        )
    }

    // MARK: Remote applies (no hooks)

    /// Adopts the canonical season the SERVER attached an entry to (sql/161
    /// returns `season_id` from every `record_pruning_entry` /
    /// `update_pruning_entry` call). Server resolution is authoritative, so a
    /// client that guessed a different season row converges silently — no
    /// hook fires, this is not a user edit and must not re-queue a push.
    func adoptServerSeason(entryId: UUID, seasonId: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryId }),
              entries[index].seasonId != seasonId else { return }
        entries[index].seasonId = seasonId
        persistEntries()
    }

    func applyRemoteSeasonUpsert(_ setup: PruningBlockSetup) {
        applySeasonUpsert(setup)
        persistSetups()
    }

    func applyRemoteSeasonDelete(_ id: UUID) {
        let before = setups.count
        setups.removeAll { $0.id == id }
        if setups.count != before { persistSetups() }
    }

    func applyRemoteEntryUpsert(_ entry: PruningEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            // Preserve the local segment list until the attribution pass runs.
            var merged = entry
            merged.segments = entries[index].segments
            entries[index] = merged
        } else {
            entries.append(entry)
        }
        persistEntries()
    }

    /// A reversal seen on the server. The row stays as audit history with its
    /// values intact; only the reversal stamp is applied.
    func applyRemoteEntryReversal(id: UUID, reversedAt: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].reversedAt != reversedAt else { return }
        entries[index].reversedAt = reversedAt
        persistEntries()
    }

    func applyRemoteEntryDelete(_ id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before { persistEntries() }
    }

    /// Re-points queued entries at the canonical season row for their block.
    ///
    /// After a season pull, `applyRemoteSeasonUpsert` may have replaced a
    /// locally created season (deterministic id) with the server's row for
    /// the same vineyard + paddock + year under a DIFFERENT id (e.g. a row
    /// created from the portal). Entries still queued against the stale id
    /// would collide with the server's active-season unique index on every
    /// replay, wedging the outbox forever — remapping them to the surviving
    /// setup row lets the push land. Only entries in `pendingIds` (still
    /// queued) are touched. Returns the remapped entry ids.
    func remapPendingEntrySeasons(vineyardId: UUID, pendingIds: Set<UUID>) -> [UUID] {
        guard !pendingIds.isEmpty else { return [] }
        let knownSetupIds = Set(setups.map { $0.id })
        var remapped: [UUID] = []
        for index in entries.indices {
            let entry = entries[index]
            guard entry.vineyardId == vineyardId,
                  pendingIds.contains(entry.id),
                  !knownSetupIds.contains(entry.seasonId),
                  let canonical = setup(for: entry.paddockId),
                  canonical.id != entry.seasonId else { continue }
            entries[index].seasonId = canonical.id
            remapped.append(entry.id)
        }
        if !remapped.isEmpty { persistEntries() }
        return remapped
    }

    /// Applies the server's segment attribution (the `pruning_row_segments`
    /// table is the single source of truth for completed quarters). Entries in
    /// `protectedIds` are still queued locally and keep their optimistic
    /// segment list until their push lands.
    func applyRemoteSegmentAttribution(
        vineyardId: UUID,
        segmentsByEntry: [UUID: [PruningSegment]],
        protectedIds: Set<UUID>
    ) {
        var changed = false
        for index in entries.indices where entries[index].vineyardId == vineyardId {
            let id = entries[index].id
            guard !protectedIds.contains(id) else { continue }
            // A reversed entry keeps its recorded quarters for the audit trail;
            // the server no longer attributes any segment to it.
            guard !entries[index].isReversed else { continue }
            let remote = (segmentsByEntry[id] ?? []).sorted {
                ($0.row, $0.quarter) < ($1.row, $1.quarter)
            }
            let local = entries[index].segments.sorted {
                ($0.row, $0.quarter) < ($1.row, $1.quarter)
            }
            if local != remote {
                entries[index].segments = remote
                changed = true
            }
        }
        if changed { persistEntries() }
    }

    // MARK: Persistence

    private func applySeasonUpsert(_ setup: PruningBlockSetup) {
        if let index = setups.firstIndex(where: { $0.id == setup.id }) {
            setups[index] = setup
        } else if let index = setups.firstIndex(where: {
            $0.vineyardId == setup.vineyardId && $0.paddockId == setup.paddockId && $0.seasonYear == setup.seasonYear
        }) {
            setups[index] = setup
        } else {
            setups.append(setup)
        }
    }

    private func persistSetups() {
        persistence.save(setups, key: Self.setupsKey)
    }

    private func persistEntries() {
        persistence.save(entries, key: Self.entriesKey)
    }

    private func persistActivities() {
        persistence.save(activities, key: Self.activitiesKey)
    }
}
