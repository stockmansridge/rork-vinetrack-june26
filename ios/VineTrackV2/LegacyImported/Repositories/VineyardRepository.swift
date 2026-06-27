import Foundation

/// Owns persistence and merge logic for Vineyard (top-level, not per-vineyard scoped).
@MainActor
final class VineyardRepository {

    static let storageKey = "vinetrack_vineyards"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [Vineyard] {
        persistence.load(key: Self.storageKey) ?? []
    }

    // MARK: - Save

    func saveAll(_ items: [Vineyard]) {
        persistence.save(items, key: Self.storageKey)
    }

    /// Upsert a single vineyard by id.
    func upsert(_ vineyard: Vineyard) -> [Vineyard] {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.id == vineyard.id }) {
            all[index] = vineyard
        } else {
            all.append(vineyard)
        }
        persistence.save(all, key: Self.storageKey)
        return all
    }

    /// Remove a vineyard by id.
    func remove(id: UUID) -> [Vineyard] {
        var all = loadAll()
        all.removeAll { $0.id == id }
        persistence.save(all, key: Self.storageKey)
        return all
    }

    // MARK: - Sync

    /// Merge remote vineyards. Adds new ones and refreshes the users list of
    /// existing ones so accepted invitations appear in the team roster.
    func merge(_ remote: [Vineyard]) -> [Vineyard] {
        var all = loadAll()
        for item in remote {
            if let index = all.firstIndex(where: { $0.id == item.id }) {
                var existing = all[index]
                existing.users = item.users
                all[index] = existing
            } else {
                all.append(item)
            }
        }
        persistence.save(all, key: Self.storageKey)
        return all
    }
}
