import Foundation

/// Persistence for the vineyard-scoped Work Task Type catalog. Mirrors the
/// pattern used by WorkTaskPaddockRepository — the DataStore holds the
/// in-memory collection and delegates here for on-disk storage.
@MainActor
final class WorkTaskTypeRepository {

    static let storageKey = "vinetrack_work_task_types"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    func loadAll() -> [WorkTaskType] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [WorkTaskType] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    func saveSlice(_ items: [WorkTaskType], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }
}
