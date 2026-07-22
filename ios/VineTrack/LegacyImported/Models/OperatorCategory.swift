import Foundation

nonisolated struct OperatorCategory: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var costPerHour: Double

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        costPerHour: Double = 0
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.costPerHour = costPerHour
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, costPerHour
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        costPerHour = try container.decodeIfPresent(Double.self, forKey: .costPerHour) ?? 0
    }
}
