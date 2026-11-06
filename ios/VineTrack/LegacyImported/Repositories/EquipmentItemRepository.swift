import Foundation

/// Persistence for the vineyard-scoped "Other" equipment items catalog.
@MainActor
final class EquipmentItemRepository {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}

    static let storageKey = "vinetrack_equipment_items"

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
    }

    func loadAll() -> [EquipmentItem] {
        persistence.load(key: Self.storageKey) ?? []
    }

    func load(for vineyardId: UUID) -> [EquipmentItem] {
        loadAll().filter { $0.vineyardId == vineyardId }
    }

    func saveSlice(_ items: [EquipmentItem], for vineyardId: UUID) {
        var all = loadAll()
        all.removeAll { $0.vineyardId == vineyardId }
        all.append(contentsOf: items)
        persistence.save(all, key: Self.storageKey)
    }
}
