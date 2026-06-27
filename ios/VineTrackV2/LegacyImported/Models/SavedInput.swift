import Foundation

/// Reusable vineyard input (seed, fertiliser, compost, biological,
/// soil amendment, etc.) used by seeding/spreading/fertilising trips
/// so cost-per-unit can be snapshotted onto a trip's mix lines and
/// `TripCostService` can compute seed/input cost reliably.
nonisolated enum SavedInputType: String, CaseIterable, Codable, Sendable {
    case seed
    case fertiliser
    case compost
    case biological
    case soilAmendment = "soil_amendment"
    case other

    var displayName: String {
        switch self {
        case .seed: return "Seed"
        case .fertiliser: return "Fertiliser"
        case .compost: return "Compost"
        case .biological: return "Biological"
        case .soilAmendment: return "Soil Amendment"
        case .other: return "Other"
        }
    }
}

nonisolated enum SavedInputUnit: String, CaseIterable, Codable, Sendable {
    case kg
    case g
    case litres = "L"
    case millilitres = "mL"
    case tonne

    var displayName: String { rawValue }
}

nonisolated struct SavedInput: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var inputType: SavedInputType
    var unit: SavedInputUnit
    /// Optional. `nil` means "not configured" — TripCostService must NOT
    /// treat this as zero.
    var costPerUnit: Double?
    var supplier: String?
    var notes: String?

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        inputType: SavedInputType = .other,
        unit: SavedInputUnit = .kg,
        costPerUnit: Double? = nil,
        supplier: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.inputType = inputType
        self.unit = unit
        self.costPerUnit = costPerUnit
        self.supplier = supplier
        self.notes = notes
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, inputType, unit, costPerUnit, supplier, notes
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        inputType = (try? c.decodeIfPresent(SavedInputType.self, forKey: .inputType)) ?? .other
        unit = (try? c.decodeIfPresent(SavedInputUnit.self, forKey: .unit)) ?? .kg
        costPerUnit = try c.decodeIfPresent(Double.self, forKey: .costPerUnit)
        supplier = try c.decodeIfPresent(String.self, forKey: .supplier)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}
