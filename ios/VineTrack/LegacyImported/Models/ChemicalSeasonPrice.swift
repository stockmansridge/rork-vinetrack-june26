import Foundation

/// Financial RPC provenance; quantities and prices are always per mL or g.
nonisolated struct ChemicalSeasonPrice: Codable, Sendable {
    let savedChemicalId: UUID
    let vintage: Int
    let weightedCostPerBaseUnit: Double?
    let baseUnit: String?
    let currency: String?
    let purchaseCount: Int
    let totalQuantityBase: Double?
    let totalPurchaseCost: Double?
    let pricingBasis: String
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case savedChemicalId = "saved_chemical_id", vintage
        case weightedCostPerBaseUnit = "weighted_cost_per_base_unit"
        case baseUnit = "base_unit", currency
        case purchaseCount = "purchase_count"
        case totalQuantityBase = "total_quantity_base"
        case totalPurchaseCost = "total_purchase_cost"
        case pricingBasis = "pricing_basis", warning
    }

    func price(for unit: ChemicalUnit) -> Double? {
        guard pricingBasis == "season_weighted_purchase_average",
              baseUnit == (unit.dimension == .mass ? "g" : "mL"),
              let price = weightedCostPerBaseUnit, price.isFinite, price >= 0 else { return nil }
        return price
    }
}

/// Explicit vineyard/vintage scope prevents a price from another season being used.
nonisolated struct ChemicalSeasonPriceBatch: Sendable {
    let vineyardId: UUID
    let vintage: Int
    let prices: [ChemicalSeasonPrice]
}
