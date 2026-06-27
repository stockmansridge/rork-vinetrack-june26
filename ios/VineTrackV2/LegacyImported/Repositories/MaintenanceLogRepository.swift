import Foundation

/// Owns persistence and merge/replace logic for MaintenanceLog.
@MainActor
final class MaintenanceLogRepository {

    static let storageKey = "vinetrack_maintenance_logs"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [MaintenanceLog] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [MaintenanceLog] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    func saveSlice(_ items: [MaintenanceLog], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    // MARK: - Sync

    func replace(_ remote: [MaintenanceLog], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    func merge(_ remote: [MaintenanceLog], for vineyardId: UUID) -> [MaintenanceLog] {
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
