import Foundation

/// Vineyard-scoped, user-editable "Other" equipment item used as the
/// Maintenance page Item / Machine source for assets that are not tractors
/// and not spray equipment (quad bike, ute, trailer, pump, generator,
/// compressor, slasher, mulcher, irrigation pump, workshop tool, etc.).
///
/// Mirrors public.equipment_items on Supabase (sql/053).
nonisolated struct EquipmentItem: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var category: String
    var make: String?
    var model: String?
    var serialNumber: String?
    var notes: String

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        category: String = "other",
        make: String? = nil,
        model: String? = nil,
        serialNumber: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.category = category
        self.make = make
        self.model = model
        self.serialNumber = serialNumber
        self.notes = notes
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, category, make, model, serialNumber, notes
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "other"
        make = try c.decodeIfPresent(String.self, forKey: .make)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed item" : trimmed
    }
}
