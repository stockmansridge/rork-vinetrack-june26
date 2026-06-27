import Foundation

/// Local persistence for the Saved Inputs library. Mirrors `SprayRepository`'s
/// chemical/preset slice pattern so a single UserDefaults key holds all rows
/// across vineyards and per-vineyard slices are filtered in memory.
@MainActor
final class SavedInputRepository {

    static let storageKey = "vinetrack_saved_inputs"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    func loadAll() -> [SavedInput] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [SavedInput] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    func saveSlice(_ items: [SavedInput], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    func replace(_ remote: [SavedInput], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }
}
