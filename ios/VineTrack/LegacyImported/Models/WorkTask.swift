import Foundation

nonisolated struct WorkTaskResource: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var operatorCategoryId: UUID?
    var workerTypeName: String
    var hourlyRate: Double
    var count: Int

    init(
        id: UUID = UUID(),
        operatorCategoryId: UUID? = nil,
        workerTypeName: String = "",
        hourlyRate: Double = 0,
        count: Int = 1
    ) {
        self.id = id
        self.operatorCategoryId = operatorCategoryId
        self.workerTypeName = workerTypeName
        self.hourlyRate = hourlyRate
        self.count = count
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, operatorCategoryId, workerTypeName, hourlyRate, count
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        operatorCategoryId = try c.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
        workerTypeName = try c.decodeIfPresent(String.self, forKey: .workerTypeName) ?? ""
        hourlyRate = try c.decodeIfPresent(Double.self, forKey: .hourlyRate) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
    }
}

nonisolated struct WorkTask: Codable, Identifiable, Sendable {
    var id: UUID
    var vineyardId: UUID
    var date: Date
    var taskType: String
    var paddockId: UUID?
    var paddockName: String
    var durationHours: Double
    var resources: [WorkTaskResource]
    var notes: String
    var createdBy: String?
    var isArchived: Bool
    var archivedAt: Date?
    var archivedBy: String?
    var isFinalized: Bool
    var finalizedAt: Date?
    var finalizedBy: String?

    // Phase 16 additive multi-day / costing parent fields. All optional —
    // existing simple work tasks continue to work without these.
    var startDate: Date?
    var endDate: Date?
    var areaHa: Double?
    var taskDescription: String?
    var status: String?

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        date: Date = Date(),
        taskType: String = "",
        paddockId: UUID? = nil,
        paddockName: String = "",
        durationHours: Double = 0,
        resources: [WorkTaskResource] = [],
        notes: String = "",
        createdBy: String? = nil,
        isArchived: Bool = false,
        archivedAt: Date? = nil,
        archivedBy: String? = nil,
        isFinalized: Bool = false,
        finalizedAt: Date? = nil,
        finalizedBy: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        areaHa: Double? = nil,
        taskDescription: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.date = date
        self.taskType = taskType
        self.paddockId = paddockId
        self.paddockName = paddockName
        self.durationHours = durationHours
        self.resources = resources
        self.notes = notes
        self.createdBy = createdBy
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.archivedBy = archivedBy
        self.isFinalized = isFinalized
        self.finalizedAt = finalizedAt
        self.finalizedBy = finalizedBy
        self.startDate = startDate
        self.endDate = endDate
        self.areaHa = areaHa
        self.taskDescription = taskDescription
        self.status = status
    }

    var totalPeople: Int { resources.reduce(0) { $0 + $1.count } }

    var costPerPerson: Double {
        // Weighted average per person
        guard totalPeople > 0 else { return 0 }
        return totalCost / Double(totalPeople)
    }

    var totalCost: Double {
        resources.reduce(0.0) { partial, r in
            partial + (r.hourlyRate * durationHours * Double(r.count))
        }
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, date, taskType, paddockId, paddockName, durationHours, resources, notes, createdBy
        case isArchived, archivedAt, archivedBy, isFinalized, finalizedAt, finalizedBy
        case startDate, endDate, areaHa, taskDescription, status
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        taskType = try c.decodeIfPresent(String.self, forKey: .taskType) ?? ""
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId)
        paddockName = try c.decodeIfPresent(String.self, forKey: .paddockName) ?? ""
        durationHours = try c.decodeIfPresent(Double.self, forKey: .durationHours) ?? 0
        resources = try c.decodeIfPresent([WorkTaskResource].self, forKey: .resources) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        archivedBy = try c.decodeIfPresent(String.self, forKey: .archivedBy)
        isFinalized = try c.decodeIfPresent(Bool.self, forKey: .isFinalized) ?? false
        finalizedAt = try c.decodeIfPresent(Date.self, forKey: .finalizedAt)
        finalizedBy = try c.decodeIfPresent(String.self, forKey: .finalizedBy)
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        areaHa = try c.decodeIfPresent(Double.self, forKey: .areaHa)
        taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
}

nonisolated enum WorkTaskTypeCatalog {
    static let defaults: [String] = [
        "Pruning",
        "Cane Tying",
        "Shoot Thinning",
        "Leaf Plucking",
        "Canopy Trimming",
        "Wire Lifting",
        "Bud Rubbing",
        "Weed Control",
        "Mowing",
        "Irrigation Check",
        "Harvest",
        "Planting",
        "Training",
        "Bird Netting",
        "Other"
    ]

    /// Merge vineyard-scoped custom task types (from work_task_types) with the
    /// built-in defaults. Custom types appear first (sorted by sortOrder then
    /// name); defaults fill in the rest. Case-insensitive de-duplication so a
    /// vineyard rename of a default name does not double-list.
    static func merged(with customTypes: [WorkTaskType]) -> [String] {
        let sortedCustom = customTypes
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { $0.name }
        var seen = Set<String>()
        var result: [String] = []
        for name in sortedCustom + defaults {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty { continue }
            if seen.insert(key).inserted { result.append(name) }
        }
        return result
    }
}
