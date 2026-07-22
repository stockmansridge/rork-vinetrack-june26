import Foundation

/// Local persistence for `TripCostAllocation` rows. Single UserDefaults key
/// holds all rows across vineyards; per-vineyard slices are filtered in
/// memory. Mirrors `SavedInputRepository`.
@MainActor
final class TripCostAllocationRepository {

    static let storageKey = "vinetrack_trip_cost_allocations"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    func loadAll() -> [TripCostAllocation] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [TripCostAllocation] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    func saveSlice(_ items: [TripCostAllocation], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }

    func replace(_ remote: [TripCostAllocation], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: remote)
        persistence.save(all, key: Self.storageKey)
    }
}
