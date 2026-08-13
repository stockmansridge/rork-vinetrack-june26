import Foundation

/// Owns persistence and merge/replace logic for `PruningActivityLabourLine`
/// (sql/190). Mirrors `WorkTaskLabourLineRepository` exactly — DataStore holds
/// the in-memory collection and delegates here for on-disk storage — because
/// the two tables mirror each other column for column.
@MainActor
final class PruningActivityLabourLineRepository {

    static let storageKey = "vinetrack_pruning_activity_labour_lines"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [PruningActivityLabourLine] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [PruningActivityLabourLine] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    func saveSlice(_ items: [PruningActivityLabourLine], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    // MARK: - Sync

    func replace(_ remote: [PruningActivityLabourLine], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    /// Replaces the COMPLETE set of one activity with the canonical server
    /// answer. This is the desired-state counterpart of
    /// `save_pruning_activity_labour_lines`: whatever the server did not return
    /// for that activity no longer exists, so a line deleted on another device
    /// cannot survive locally.
    func replaceActivity(
        _ remote: [PruningActivityLabourLine],
        activityId: UUID,
        vineyardId: UUID
    ) {
        var all = loadAll()
        all.removeAll { $0.pruningActivityId == activityId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    func merge(_ remote: [PruningActivityLabourLine], for vineyardId: UUID) -> [PruningActivityLabourLine] {
        var all = loadAll()
        for item in remote {
            if let idx = all.firstIndex(where: { $0.id == item.id }) {
                all[idx] = item
            } else {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.storageKey)
        return all.filter { $0.vineyardId == vineyardId }
    }
}
