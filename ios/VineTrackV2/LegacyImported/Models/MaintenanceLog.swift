import Foundation

nonisolated struct MaintenanceLog: Codable, Identifiable, Sendable {
    var id: UUID
    var vineyardId: UUID
    var itemName: String
    /// Optional stable equipment link source: vineyard_machine | tractor |
    /// spray_equipment | equipment_item | free_text. item_name remains the
    /// authoritative display snapshot; this enables stable linking going forward.
    var equipmentSource: String?
    /// Id of the linked equipment row in the table named by equipmentSource.
    var equipmentRefId: UUID?
    var hours: Double
    var machineHours: Double?
    var workCompleted: String
    var partsUsed: String
    var partsCost: Double
    var labourCost: Double
    var date: Date
    var invoicePhotoData: Data?
    var photoPath: String?
    var createdBy: String?
    var isArchived: Bool
    var archivedAt: Date?
    var archivedBy: String?
    var isFinalized: Bool
    var finalizedAt: Date?
    var finalizedBy: String?

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        itemName: String = "",
        equipmentSource: String? = nil,
        equipmentRefId: UUID? = nil,
        hours: Double = 0,
        machineHours: Double? = nil,
        workCompleted: String = "",
        partsUsed: String = "",
        partsCost: Double = 0,
        labourCost: Double = 0,
        date: Date = Date(),
        invoicePhotoData: Data? = nil,
        photoPath: String? = nil,
        createdBy: String? = nil,
        isArchived: Bool = false,
        archivedAt: Date? = nil,
        archivedBy: String? = nil,
        isFinalized: Bool = false,
        finalizedAt: Date? = nil,
        finalizedBy: String? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.itemName = itemName
        self.equipmentSource = equipmentSource
        self.equipmentRefId = equipmentRefId
        self.hours = hours
        self.machineHours = machineHours
        self.workCompleted = workCompleted
        self.partsUsed = partsUsed
        self.partsCost = partsCost
        self.labourCost = labourCost
        self.date = date
        self.invoicePhotoData = invoicePhotoData
        self.photoPath = photoPath
        self.createdBy = createdBy
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.archivedBy = archivedBy
        self.isFinalized = isFinalized
        self.finalizedAt = finalizedAt
        self.finalizedBy = finalizedBy
    }

    var totalCost: Double { partsCost + labourCost }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, itemName, equipmentSource, equipmentRefId, hours, machineHours, workCompleted, partsUsed, partsCost, labourCost, date, invoicePhotoData, photoPath, createdBy
        case isArchived, archivedAt, archivedBy, isFinalized, finalizedAt, finalizedBy
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        itemName = try container.decodeIfPresent(String.self, forKey: .itemName) ?? ""
        equipmentSource = try container.decodeIfPresent(String.self, forKey: .equipmentSource)
        equipmentRefId = try container.decodeIfPresent(UUID.self, forKey: .equipmentRefId)
        hours = try container.decodeIfPresent(Double.self, forKey: .hours) ?? 0
        machineHours = try container.decodeIfPresent(Double.self, forKey: .machineHours)
        workCompleted = try container.decodeIfPresent(String.self, forKey: .workCompleted) ?? ""
        partsUsed = try container.decodeIfPresent(String.self, forKey: .partsUsed) ?? ""
        partsCost = try container.decodeIfPresent(Double.self, forKey: .partsCost) ?? 0
        labourCost = try container.decodeIfPresent(Double.self, forKey: .labourCost) ?? 0
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        invoicePhotoData = try container.decodeIfPresent(Data.self, forKey: .invoicePhotoData)
        photoPath = try container.decodeIfPresent(String.self, forKey: .photoPath)
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        archivedBy = try container.decodeIfPresent(String.self, forKey: .archivedBy)
        isFinalized = try container.decodeIfPresent(Bool.self, forKey: .isFinalized) ?? false
        finalizedAt = try container.decodeIfPresent(Date.self, forKey: .finalizedAt)
        finalizedBy = try container.decodeIfPresent(String.self, forKey: .finalizedBy)
    }
}
