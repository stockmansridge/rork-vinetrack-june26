import Foundation

nonisolated struct BackendSprayRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let tripId: UUID?
    let date: Date?
    let startTime: Date?
    let endTime: Date?
    let temperature: Double?
    let windSpeed: Double?
    let windDirection: String?
    let humidity: Double?
    let sprayReference: String?
    let notes: String?
    let numberOfFansJets: String?
    let averageSpeed: Double?
    let equipmentType: String?
    let tractor: String?
    let tractorGear: String?
    let machineId: UUID?
    let tractorId: UUID?
    let sprayEquipmentId: UUID?
    let isTemplate: Bool?
    let operationType: String?
    let tanks: [SprayTank]?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?
    let syncVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case tripId = "trip_id"
        case date
        case startTime = "start_time"
        case endTime = "end_time"
        case temperature
        case windSpeed = "wind_speed"
        case windDirection = "wind_direction"
        case humidity
        case sprayReference = "spray_reference"
        case notes
        case numberOfFansJets = "number_of_fans_jets"
        case averageSpeed = "average_speed"
        case equipmentType = "equipment_type"
        case tractor
        case tractorGear = "tractor_gear"
        case machineId = "machine_id"
        case tractorId = "tractor_id"
        case sprayEquipmentId = "spray_equipment_id"
        case isTemplate = "is_template"
        case operationType = "operation_type"
        case tanks
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case syncVersion = "sync_version"
    }
}

/// Encodable payload used when upserting a spray record from the client.
/// Server-managed fields (created_at, updated_at, deleted_at, sync_version,
/// updated_by) are omitted.
nonisolated struct BackendSprayRecordUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let tripId: UUID?
    let date: Date
    let startTime: Date
    let endTime: Date?
    let temperature: Double?
    let windSpeed: Double?
    let windDirection: String
    let humidity: Double?
    let sprayReference: String
    let notes: String
    let numberOfFansJets: String
    let averageSpeed: Double?
    let equipmentType: String
    let tractor: String
    let tractorGear: String
    let machineId: UUID?
    let tractorId: UUID?
    let sprayEquipmentId: UUID?
    let isTemplate: Bool
    let operationType: String
    let tanks: [SprayTank]
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case tripId = "trip_id"
        case date
        case startTime = "start_time"
        case endTime = "end_time"
        case temperature
        case windSpeed = "wind_speed"
        case windDirection = "wind_direction"
        case humidity
        case sprayReference = "spray_reference"
        case notes
        case numberOfFansJets = "number_of_fans_jets"
        case averageSpeed = "average_speed"
        case equipmentType = "equipment_type"
        case tractor
        case tractorGear = "tractor_gear"
        case machineId = "machine_id"
        case tractorId = "tractor_id"
        case sprayEquipmentId = "spray_equipment_id"
        case isTemplate = "is_template"
        case operationType = "operation_type"
        case tanks
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendSprayRecord {
    /// Map a local SprayRecord into an upsert payload.
    static func upsert(from record: SprayRecord, createdBy: UUID?, clientUpdatedAt: Date) -> BackendSprayRecordUpsert {
        BackendSprayRecordUpsert(
            id: record.id,
            vineyardId: record.vineyardId,
            tripId: record.tripId,
            date: record.date,
            startTime: record.startTime,
            endTime: record.endTime,
            temperature: record.temperature,
            windSpeed: record.windSpeed,
            windDirection: record.windDirection,
            humidity: record.humidity,
            sprayReference: record.sprayReference,
            notes: record.notes,
            numberOfFansJets: record.numberOfFansJets,
            averageSpeed: record.averageSpeed,
            equipmentType: record.equipmentType,
            tractor: record.tractor,
            tractorGear: record.tractorGear,
            machineId: record.machineId,
            tractorId: record.tractorId,
            sprayEquipmentId: record.sprayEquipmentId,
            isTemplate: record.isTemplate,
            operationType: record.operationType.rawValue,
            tanks: record.tanks,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    /// Map a remote BackendSprayRecord into a local SprayRecord.
    func toSprayRecord() -> SprayRecord {
        SprayRecord(
            id: id,
            tripId: tripId ?? UUID(),
            vineyardId: vineyardId,
            date: date ?? Date(),
            startTime: startTime ?? Date(),
            endTime: endTime,
            temperature: temperature,
            windSpeed: windSpeed,
            windDirection: windDirection ?? "",
            humidity: humidity,
            sprayReference: sprayReference ?? "",
            tanks: tanks ?? [],
            notes: notes ?? "",
            numberOfFansJets: numberOfFansJets ?? "",
            averageSpeed: averageSpeed,
            equipmentType: equipmentType ?? "",
            tractor: tractor ?? "",
            tractorGear: tractorGear ?? "",
            machineId: machineId,
            tractorId: tractorId,
            sprayEquipmentId: sprayEquipmentId,
            isTemplate: isTemplate ?? false,
            operationType: operationType.flatMap { OperationType(rawValue: $0) } ?? .foliarSpray
        )
    }
}
