import Foundation

/// Owns persistence and merge/replace logic for `WorkTaskPieceRateRow`
/// (sql/188). Mirrors `WorkTaskPaddockRepository` exactly — the DataStore holds
/// the in-memory collection and delegates here for on-disk storage, so a
/// piece-rate job's historical vine quantities survive offline and relaunch.
@MainActor
final class WorkTaskPieceRateRowRepository {

    static let storageKey = "vinetrack_work_task_piece_rate_rows"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    // MARK: - Load

    func loadAll() -> [WorkTaskPieceRateRow] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [WorkTaskPieceRateRow] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    // MARK: - Save

    func saveSlice(_ items: [WorkTaskPieceRateRow], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    // MARK: - Sync

    func replace(_ remote: [WorkTaskPieceRateRow], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }

    func merge(_ remote: [WorkTaskPieceRateRow], for vineyardId: UUID) -> [WorkTaskPieceRateRow] {
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
