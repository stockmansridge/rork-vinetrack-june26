import Foundation

/// Owns persistence and merge/replace logic for WorkTask.
/// DataStore holds the in-memory collection and delegates here for storage.
@MainActor
final class WorkTaskRepository {

    static let storageKey = "vinetrack_work_tasks"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [WorkTask] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [WorkTask] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    /// Replace the stored slice for `vineyardId` with `items` and write to disk.
    func saveSlice(_ items: [WorkTask], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    // MARK: - Sync

    func replace(_ remote: [WorkTask], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    func merge(_ remote: [WorkTask], for vineyardId: UUID) -> [WorkTask] {
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
