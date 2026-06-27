import Foundation

nonisolated struct SprayEquipmentItem: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var tankCapacityLitres: Double

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        tankCapacityLitres: Double = 0
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.tankCapacityLitres = tankCapacityLitres
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, tankCapacityLitres
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        tankCapacityLitres = try container.decodeIfPresent(Double.self, forKey: .tankCapacityLitres) ?? 0
    }
}

nonisolated struct Tractor: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var brand: String
    var model: String
    var modelYear: Int?
    var fuelUsageLPerHour: Double

    var displayName: String {
        let combined = "\(brand) \(model)".trimmingCharacters(in: .whitespaces)
        return combined.isEmpty ? name : combined
    }

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        brand: String = "",
        model: String = "",
        modelYear: Int? = nil,
        fuelUsageLPerHour: Double = 0
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.brand = brand
        self.model = model
        self.modelYear = modelYear
        self.fuelUsageLPerHour = fuelUsageLPerHour
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, name, brand, model, modelYear, fuelUsageLPerHour
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        brand = try container.decodeIfPresent(String.self, forKey: .brand) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        modelYear = try container.decodeIfPresent(Int.self, forKey: .modelYear)
        fuelUsageLPerHour = try container.decodeIfPresent(Double.self, forKey: .fuelUsageLPerHour) ?? 0
    }
}

nonisolated struct FuelPurchase: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var volumeLitres: Double
    var totalCost: Double
    var date: Date

    var costPerLitre: Double {
        guard volumeLitres > 0 else { return 0 }
        return totalCost / volumeLitres
    }

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        volumeLitres: Double = 0,
        totalCost: Double = 0,
        date: Date = Date()
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.volumeLitres = volumeLitres
        self.totalCost = totalCost
        self.date = date
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, volumeLitres, totalCost, date
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        volumeLitres = try container.decodeIfPresent(Double.self, forKey: .volumeLitres) ?? 0
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
    }
}
