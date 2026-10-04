import Foundation

nonisolated enum CatalogueInventoryMutation {
    static let purchase = "chemical_inventory_record_purchase_v2"
    static let stocktake = "chemical_inventory_record_stocktake_v2"
    static let history = "chemical_inventory_purchase_history_v2"
    static let operations = ["chemical_inventory_record_purchase", "chemical_inventory_record_stocktake", purchase, stocktake, "chemical_inventory_mark_finished", "chemical_inventory_set_settings"]
    @MainActor static func perform(canManageInventory: Bool, operation: String, chemicalId: UUID,
        mutate: () async throws -> Void, refresh: (UUID) async -> Void) async throws {
        guard canManageInventory, operations.contains(operation) else { throw BackendRepositoryError.missingAuthenticatedUser }
        try await mutate()
        await refresh(chemicalId)
    }
}

/// Container metadata is independent of physical stock; totals here are previews only.
nonisolated enum CatalogueInventoryContainer {
    static func units(form: String, packUnit: String) -> [String] {
        if form.lowercased() == "solid" { return ["kg", "g"] }
        if form.lowercased() == "liquid" { return ["L", "mL"] }
        if ["kg", "g"].contains(packUnit) { return ["kg", "g"] }
        if ["L", "mL"].contains(packUnit) { return ["L", "mL"] }
        return []
    }
    static func valid(count: Double, size: Double) -> Bool {
        count.isFinite && count > 0 && count.rounded() == count && size.isFinite && size > 0 && (count * size).isFinite
    }
    static func fields(count: Double, size: Double, unit: String) -> [String: SprayReportPayloadV1.JSONValue] {
        ["p_container_count": .number(count), "p_container_size": .number(size), "p_container_unit": .string(unit)]
    }
    static func stockFields(quantity: Double, unit: String) -> [String: SprayReportPayloadV1.JSONValue] {
        ["p_current_quantity": .number(quantity), "p_current_unit": .string(unit)]
    }
    static func openingQuantity(count: String, size: String, physical: String, edited: Bool) -> String {
        guard !edited, let count = Double(count), let size = Double(size), valid(count: count, size: size) else { return physical }
        return number(count * size)
    }
    static func number(_ value: Double) -> String { value.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) }
    static func preview(count: Double, size: Double, unit: String) -> String {
        "\(number(count)) × \(number(size)) \(unit) = \(number(count * size)) \(unit) total"
    }
    static func historyText(_ row: CatalogueWire) -> String {
        let aggregate = "\(row.number("quantity").map(number) ?? "—") \(row.text("unit") ?? "") total"
        if let count = row.number("container_count"), let size = row.number("container_size"), let unit = row.text("container_unit"), valid(count: count, size: size) {
            return "\(number(count)) × \(number(size)) \(unit) · \(aggregate)"
        }
        return aggregate
    }
}
