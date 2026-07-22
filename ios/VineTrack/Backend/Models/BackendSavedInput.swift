import Foundation

// MARK: - Saved Inputs

nonisolated struct BackendSavedInput: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String?
    let inputType: String?
    let unit: String?
    let costPerUnit: Double?
    let supplier: String?
    let notes: String?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case inputType = "input_type"
        case unit
        case costPerUnit = "cost_per_unit"
        case supplier
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.inputType = try c.decodeIfPresent(String.self, forKey: .inputType)
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit)
        self.costPerUnit = try c.decodeIfPresent(Double.self, forKey: .costPerUnit)
        self.supplier = try c.decodeIfPresent(String.self, forKey: .supplier)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.clientUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .clientUpdatedAt)
    }
}

nonisolated struct BackendSavedInputUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let inputType: String
    let unit: String
    let costPerUnit: Double?
    let supplier: String?
    let notes: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case inputType = "input_type"
        case unit
        case costPerUnit = "cost_per_unit"
        case supplier
        case notes
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendSavedInput {
    static func upsert(from i: SavedInput, createdBy: UUID?, clientUpdatedAt: Date) -> BackendSavedInputUpsert {
        BackendSavedInputUpsert(
            id: i.id,
            vineyardId: i.vineyardId,
            name: i.name,
            inputType: i.inputType.rawValue,
            unit: i.unit.rawValue,
            costPerUnit: i.costPerUnit,
            supplier: i.supplier,
            notes: i.notes,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toSavedInput() -> SavedInput {
        SavedInput(
            id: id,
            vineyardId: vineyardId,
            name: name ?? "",
            inputType: SavedInputType(rawValue: inputType ?? "") ?? .other,
            unit: SavedInputUnit(rawValue: unit ?? "") ?? .kg,
            costPerUnit: costPerUnit,
            supplier: supplier,
            notes: notes
        )
    }
}
