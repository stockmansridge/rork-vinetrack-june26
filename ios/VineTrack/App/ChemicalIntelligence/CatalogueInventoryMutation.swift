import Foundation

nonisolated enum CatalogueInventoryMutation {
    static let operations = ["chemical_inventory_record_purchase", "chemical_inventory_record_stocktake", "chemical_inventory_mark_finished", "chemical_inventory_set_settings"]
    @MainActor static func perform(systemAdmin: Bool, operation: String, chemicalId: UUID,
        mutate: () async throws -> Void, refresh: (UUID) async -> Void) async throws {
        guard systemAdmin, operations.contains(operation) else { throw BackendRepositoryError.missingAuthenticatedUser }
        try await mutate()
        await refresh(chemicalId)
    }
}
