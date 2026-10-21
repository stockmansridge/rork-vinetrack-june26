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

    /// A partial or corrupt cache must not erase another vineyard's labour.
    func loadForReconciliation() throws -> [WorkTaskLabourLine] {
        let outcome: PersistenceStore.LoadOutcome<[WorkTaskLabourLine]> = persistence.loadOutcome(key: Self.storageKey)
        switch outcome {
        case .missing: return []
        case .decoded(let items): return items
        case .failed(let error): throw error
        }
    }

    nonisolated enum ReconciliationError: LocalizedError {
        case wrongVineyard

        var errorDescription: String? { "Work task labour reconciliation contained a record for a different vineyard." }
    }

    /// Compare the actual persisted slice, then commit once before publication
    /// or acknowledgement. No suspension may follow the read of `persisted`.
    func saveReconciliation(_ items: [WorkTaskLabourLine], for vineyardId: UUID, persisted: [WorkTaskLabourLine]) throws {
        guard items.allSatisfy({ $0.vineyardId == vineyardId }) else { throw ReconciliationError.wrongVineyard }
        guard persisted.filter({ $0.vineyardId == vineyardId }) != items else { return }
        var all = persisted.filter { $0.vineyardId != vineyardId }
        all.append(contentsOf: items)
        try persistence.saveOrThrow(all, key: Self.storageKey)
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
