import Foundation

/// Owns persistence and merge/replace logic for VinePin.
@MainActor
final class PinRepository {

    static let storageKey = "vinetrack_pins"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [VinePin] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [VinePin] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    func saveSlice(_ items: [VinePin], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    // MARK: - Sync

    func replace(_ remote: [VinePin], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    /// Add-if-not-exists merge (does not overwrite existing items).
    /// Returns the slice for `vineyardId` after the merge.
    func merge(_ remote: [VinePin], for vineyardId: UUID) -> [VinePin] {
        var all = loadAll()
        for item in remote {
            if !all.contains(where: { $0.id == item.id }) {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.storageKey)
        return all.filter { $0.vineyardId == vineyardId }
    }
}
