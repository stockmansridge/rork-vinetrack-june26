import Foundation

/// Owns persistence and merge/replace logic for WorkTaskPaddock.
/// Mirrors WorkTaskLabourLineRepository — DataStore holds the in-memory
/// collection and delegates here for on-disk storage.
@MainActor
final class WorkTaskPaddockRepository {

    static let storageKey = "vinetrack_work_task_paddocks"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [WorkTaskPaddock] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [WorkTaskPaddock] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    func saveSlice(_ items: [WorkTaskPaddock], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    // MARK: - Sync

    func replace(_ remote: [WorkTaskPaddock], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    func merge(_ remote: [WorkTaskPaddock], for vineyardId: UUID) -> [WorkTaskPaddock] {
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
