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
    // sql/191 + sql/192 application geometry / carrier snapshot. All nullable:
    // records written before the migration simply have no values and must keep
    // reading back as "not recorded" rather than acquiring guessed geometry.
    let grossAreaHa: Double?
    let treatedAreaHa: Double?
    let applicationMode: String?
    let treatedAreaMethod: String?
    let bandWidthTotalMetres: Double?
    let bandWidthLeftMetres: Double?
    let bandWidthRightMetres: Double?
    let canonicalRowLengthMetres: Double?
    let rowSpacingMetres: Double?
    let geometrySource: String?
    let geometryQuality: String?
    let carrierVolumeBasis: String?
    let totalCarrierLitres: Double?
    let carrierLitresPerHectare: Double?
    let diluteLitresPer100m: Double?
    let appliedLitresPer100m: Double?
    let concentrationFactor: Double?
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
        case grossAreaHa = "gross_area_ha"
        case treatedAreaHa = "treated_area_ha"
        case applicationMode = "application_mode"
        case treatedAreaMethod = "treated_area_method"
        case bandWidthTotalMetres = "band_width_total_metres"
        case bandWidthLeftMetres = "band_width_left_metres"
        case bandWidthRightMetres = "band_width_right_metres"
        case canonicalRowLengthMetres = "canonical_row_length_metres"
        case rowSpacingMetres = "row_spacing_metres"
        case geometrySource = "geometry_source"
        case geometryQuality = "geometry_quality"
        case carrierVolumeBasis = "carrier_volume_basis"
        case totalCarrierLitres = "total_carrier_litres"
        case carrierLitresPerHectare = "carrier_litres_per_hectare"
        case diluteLitresPer100m = "dilute_litres_per_100m"
        case appliedLitresPer100m = "applied_litres_per_100m"
        case concentrationFactor = "concentration_factor"
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
    /// sql/191 + sql/192 snapshot columns, projected from the canonical plan.
    /// Encoded even when nil so an edit that clears geometry (for example a job
    /// switched from banded back to whole-block) actually clears the stored
    /// columns instead of leaving a stale treated area behind.
    let grossAreaHa: Double?
    let treatedAreaHa: Double?
    let applicationMode: String?
    let treatedAreaMethod: String?
    let bandWidthTotalMetres: Double?
    let bandWidthLeftMetres: Double?
    let bandWidthRightMetres: Double?
    let canonicalRowLengthMetres: Double?
    let rowSpacingMetres: Double?
    let geometrySource: String?
    let geometryQuality: String?
    let carrierVolumeBasis: String?
    let totalCarrierLitres: Double?
    let carrierLitresPerHectare: Double?
    let diluteLitresPer100m: Double?
    let appliedLitresPer100m: Double?
    let concentrationFactor: Double?
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
        case grossAreaHa = "gross_area_ha"
        case treatedAreaHa = "treated_area_ha"
        case applicationMode = "application_mode"
        case treatedAreaMethod = "treated_area_method"
        case bandWidthTotalMetres = "band_width_total_metres"
        case bandWidthLeftMetres = "band_width_left_metres"
        case bandWidthRightMetres = "band_width_right_metres"
        case canonicalRowLengthMetres = "canonical_row_length_metres"
        case rowSpacingMetres = "row_spacing_metres"
        case geometrySource = "geometry_source"
        case geometryQuality = "geometry_quality"
        case carrierVolumeBasis = "carrier_volume_basis"
        case totalCarrierLitres = "total_carrier_litres"
        case carrierLitresPerHectare = "carrier_litres_per_hectare"
        case diluteLitresPer100m = "dilute_litres_per_100m"
        case appliedLitresPer100m = "applied_litres_per_100m"
        case concentrationFactor = "concentration_factor"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendSprayRecord {
    /// Map a local SprayRecord into an upsert payload.
    static func upsert(from record: SprayRecord, createdBy: UUID?, clientUpdatedAt: Date) -> BackendSprayRecordUpsert {
        // Templates persist reusable INPUT INTENT, never calculated output: a
        // template must not freeze one season's row length and silently reuse it
        // against different blocks next season. Enforced here, at the single
        // persistence point, so no caller can forget it.
        let geometry = record.isTemplate
            ? record.applicationGeometry?.templateConfiguration()
            : record.applicationGeometry
        return BackendSprayRecordUpsert(
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
            grossAreaHa: geometry?.grossAreaHa,
            treatedAreaHa: geometry?.treatedAreaHa,
            applicationMode: geometry?.applicationMode?.rawValue,
            treatedAreaMethod: geometry?.treatedAreaMethod?.rawValue,
            bandWidthTotalMetres: geometry?.bandWidthTotalMetres,
            bandWidthLeftMetres: geometry?.bandWidthLeftMetres,
            bandWidthRightMetres: geometry?.bandWidthRightMetres,
            canonicalRowLengthMetres: geometry?.canonicalRowLengthMetres,
            rowSpacingMetres: geometry?.rowSpacingMetres,
            geometrySource: geometry?.geometrySource?.rawValue,
            geometryQuality: geometry?.geometryQuality?.rawValue,
            carrierVolumeBasis: geometry?.carrierVolumeBasis?.rawValue,
            totalCarrierLitres: geometry?.totalCarrierLitres,
            carrierLitresPerHectare: geometry?.carrierLitresPerHectare,
            diluteLitresPer100m: geometry?.diluteLitresPer100m,
            appliedLitresPer100m: geometry?.appliedLitresPer100m,
            concentrationFactor: geometry?.concentrationFactor,
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
            operationType: operationType.flatMap { OperationType(rawValue: $0) } ?? .foliarSpray,
            applicationGeometry: applicationGeometrySnapshot
        )
    }

    /// Rebuild the stored snapshot from the flat columns.
    ///
    /// Read back VERBATIM — nothing is re-derived from current block geometry,
    /// which is what keeps a completed record stable after the vineyard is
    /// edited. Returns nil when every column is null (a pre-sql/191 record), so
    /// "not recorded" stays distinguishable from "recorded as zero".
    private var applicationGeometrySnapshot: SprayApplicationSnapshot? {
        let snapshot = SprayApplicationSnapshot(
            grossAreaHa: grossAreaHa,
            treatedAreaHa: treatedAreaHa,
            applicationMode: applicationMode.flatMap { SprayApplicationMode(rawValue: $0) },
            treatedAreaMethod: treatedAreaMethod.flatMap { SprayTreatedAreaMethod(rawValue: $0) },
            bandWidthTotalMetres: bandWidthTotalMetres,
            bandWidthLeftMetres: bandWidthLeftMetres,
            bandWidthRightMetres: bandWidthRightMetres,
            canonicalRowLengthMetres: canonicalRowLengthMetres,
            rowSpacingMetres: rowSpacingMetres,
            geometrySource: geometrySource.flatMap { SprayGeometrySource(rawValue: $0) },
            geometryQuality: geometryQuality.flatMap { SprayGeometryQuality(rawValue: $0) },
            carrierVolumeBasis: carrierVolumeBasis.flatMap { SprayCarrierBasis(rawValue: $0) },
            totalCarrierLitres: totalCarrierLitres,
            carrierLitresPerHectare: carrierLitresPerHectare,
            diluteLitresPer100m: diluteLitresPer100m,
            appliedLitresPer100m: appliedLitresPer100m,
            concentrationFactor: concentrationFactor
        )
        return snapshot.isEmpty ? nil : snapshot
    }
}
