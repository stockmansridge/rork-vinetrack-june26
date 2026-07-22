import Foundation

/// Owns persistence and merge/replace logic for WorkTaskLabourLine.
/// Mirrors WorkTaskRepository — DataStore holds the in-memory collection
/// and delegates here for on-disk storage.
@MainActor
final class WorkTaskLabourLineRepository {

    static let storageKey = "vinetrack_work_task_labour_lines"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [WorkTaskLabourLine] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [WorkTaskLabourLine] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    func saveSlice(_ items: [WorkTaskLabourLine], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    // MARK: - Sync

    func replace(_ remote: [WorkTaskLabourLine], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    func merge(_ remote: [WorkTaskLabourLine], for vineyardId: UUID) -> [WorkTaskLabourLine] {
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
