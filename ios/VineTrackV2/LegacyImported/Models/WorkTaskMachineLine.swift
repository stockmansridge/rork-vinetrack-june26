import Foundation

/// Manual machine/tractor/equipment work entry for a WorkTask, used when no
/// GPS Trip exists (missed, failed, or a correction). Sibling of
/// WorkTaskLabourLine. Mirrors public.work_task_machine_lines (sql/103).
///
/// Equipment identity uses the migration-safe maintenance pattern:
/// `equipmentSource` + `equipmentRefId` + `equipmentNameSnapshot`, where the
/// snapshot is the authoritative display value when no stable link resolves.
nonisolated struct WorkTaskMachineLine: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var workTaskId: UUID
    var vineyardId: UUID
    var workDate: Date

    /// vineyard_machine | tractor | spray_equipment | equipment_item | free_text
    var equipmentSource: String?
    var equipmentRefId: UUID?
    var equipmentNameSnapshot: String

    var operatorUserId: UUID?
    var operatorCategoryId: UUID?

    var durationHours: Double?
    var startTime: Date?
    var endTime: Date?
    var startEngineHours: Double?
    var endEngineHours: Double?
    var engineHoursUsed: Double?

    var fuelLitres: Double?
    var fuelCost: Double?
    var hourlyMachineRate: Double?
    var totalMachineCost: Double?

    /// manual | missed_trip | trip_failed | correction
    var entrySource: String

    var notes: String

    init(
        id: UUID = UUID(),
        workTaskId: UUID,
        vineyardId: UUID,
        workDate: Date = Date(),
        equipmentSource: String? = nil,
        equipmentRefId: UUID? = nil,
        equipmentNameSnapshot: String = "",
        operatorUserId: UUID? = nil,
        operatorCategoryId: UUID? = nil,
        durationHours: Double? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        startEngineHours: Double? = nil,
        endEngineHours: Double? = nil,
        engineHoursUsed: Double? = nil,
        fuelLitres: Double? = nil,
        fuelCost: Double? = nil,
        hourlyMachineRate: Double? = nil,
        totalMachineCost: Double? = nil,
        entrySource: String = "manual",
        notes: String = ""
    ) {
        self.id = id
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.workDate = workDate
        self.equipmentSource = equipmentSource
        self.equipmentRefId = equipmentRefId
        self.equipmentNameSnapshot = equipmentNameSnapshot
        self.operatorUserId = operatorUserId
        self.operatorCategoryId = operatorCategoryId
        self.durationHours = durationHours
        self.startTime = startTime
        self.endTime = endTime
        self.startEngineHours = startEngineHours
        self.endEngineHours = endEngineHours
        self.engineHoursUsed = engineHoursUsed
        self.fuelLitres = fuelLitres
        self.fuelCost = fuelCost
        self.hourlyMachineRate = hourlyMachineRate
        self.totalMachineCost = totalMachineCost
        self.entrySource = entrySource
        self.notes = notes
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, workTaskId, vineyardId, workDate
        case equipmentSource, equipmentRefId, equipmentNameSnapshot
        case operatorUserId, operatorCategoryId
        case durationHours, startTime, endTime
        case startEngineHours, endEngineHours, engineHoursUsed
        case fuelLitres, fuelCost, hourlyMachineRate, totalMachineCost
        case entrySource, notes
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        workDate = try c.decodeIfPresent(Date.self, forKey: .workDate) ?? Date()
        equipmentSource = try c.decodeIfPresent(String.self, forKey: .equipmentSource)
        equipmentRefId = try c.decodeIfPresent(UUID.self, forKey: .equipmentRefId)
        equipmentNameSnapshot = try c.decodeIfPresent(String.self, forKey: .equipmentNameSnapshot) ?? ""
        operatorUserId = try c.decodeIfPresent(UUID.self, forKey: .operatorUserId)
        operatorCategoryId = try c.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
        durationHours = try c.decodeIfPresent(Double.self, forKey: .durationHours)
        startTime = try c.decodeIfPresent(Date.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime)
        startEngineHours = try c.decodeIfPresent(Double.self, forKey: .startEngineHours)
        endEngineHours = try c.decodeIfPresent(Double.self, forKey: .endEngineHours)
        engineHoursUsed = try c.decodeIfPresent(Double.self, forKey: .engineHoursUsed)
        fuelLitres = try c.decodeIfPresent(Double.self, forKey: .fuelLitres)
        fuelCost = try c.decodeIfPresent(Double.self, forKey: .fuelCost)
        hourlyMachineRate = try c.decodeIfPresent(Double.self, forKey: .hourlyMachineRate)
        totalMachineCost = try c.decodeIfPresent(Double.self, forKey: .totalMachineCost)
        entrySource = try c.decodeIfPresent(String.self, forKey: .entrySource) ?? "manual"
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}
