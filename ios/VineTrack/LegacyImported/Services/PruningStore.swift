import Foundation
import Observation

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

    /// Sync hooks — fired for local user edits only, never for remote applies.
    var onSeasonChanged: ((UUID) -> Void)?
    var onSeasonDeleted: ((UUID) -> Void)?
    var onEntryRecorded: ((UUID) -> Void)?
    var onEntryEdited: ((UUID) -> Void)?
    var onEntryDeleted: ((UUID) -> Void)?

    private static let setupsKey = "vinetrack_pruning_seasons_v2"
    private static let entriesKey = "vinetrack_pruning_entries_v2"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        setups = persistence.load(key: Self.setupsKey) ?? []
        entries = persistence.load(key: Self.entriesKey) ?? []
    }

    // MARK: Seasons (block setups)

    func setup(for paddockId: UUID) -> PruningBlockSetup? {
        setups
            .filter { $0.paddockId == paddockId }
            .max { $0.seasonYear < $1.seasonYear }
    }

    func upsertSetup(_ setup: PruningBlockSetup) {
        applySeasonUpsert(setup)
        persistSetups()
        onSeasonChanged?(setup.id)
    }

    // MARK: Entries

    func entries(for paddockId: UUID) -> [PruningEntry] {
        entries
            .filter { $0.paddockId == paddockId }
            .sorted { $0.date > $1.date }
    }

    func entries(forVineyard vineyardId: UUID) -> [PruningEntry] {
        entries.filter { $0.vineyardId == vineyardId }
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

    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persistEntries()
        onEntryDeleted?(id)
    }

    // MARK: Remote applies (no hooks)

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
}
