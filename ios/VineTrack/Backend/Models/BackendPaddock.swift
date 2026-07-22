import Foundation

nonisolated struct BackendPaddock: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let rowDirection: Double?
    let rowWidth: Double?
    let rowOffset: Double?
    let vineSpacing: Double?
    let vineCountOverride: Int?
    let rowLengthOverride: Double?
    let flowPerEmitter: Double?
    let emitterSpacing: Double?
    let intermediatePostSpacing: Double?
    let budburstDate: Date?
    let floweringDate: Date?
    let veraisonDate: Date?
    let harvestDate: Date?
    let plantingYear: Int?
    let calculationModeOverride: String?
    let resetModeOverride: String?
    let polygonPoints: [CoordinatePoint]?
    let rows: [PaddockRow]?
    let varietyAllocations: [PaddockVarietyAllocation]?
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
        case name
        case rowDirection = "row_direction"
        case rowWidth = "row_width"
        case rowOffset = "row_offset"
        case vineSpacing = "vine_spacing"
        case vineCountOverride = "vine_count_override"
        case rowLengthOverride = "row_length_override"
        case flowPerEmitter = "flow_per_emitter"
        case emitterSpacing = "emitter_spacing"
        case intermediatePostSpacing = "intermediate_post_spacing"
        case budburstDate = "budburst_date"
        case floweringDate = "flowering_date"
        case veraisonDate = "veraison_date"
        case harvestDate = "harvest_date"
        case plantingYear = "planting_year"
        case calculationModeOverride = "calculation_mode_override"
        case resetModeOverride = "reset_mode_override"
        case polygonPoints = "polygon_points"
        case rows
        case varietyAllocations = "variety_allocations"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case syncVersion = "sync_version"
    }
}

/// Encodable payload used when upserting a paddock from the client. Server-managed
/// fields (created_at, updated_at, deleted_at, sync_version, updated_by) are omitted
/// so the client cannot spoof them.
nonisolated struct BackendPaddockUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let rowDirection: Double?
    let rowWidth: Double?
    let rowOffset: Double?
    let vineSpacing: Double?
    let vineCountOverride: Int?
    let rowLengthOverride: Double?
    let flowPerEmitter: Double?
    let emitterSpacing: Double?
    let intermediatePostSpacing: Double?
    let budburstDate: Date?
    let floweringDate: Date?
    let veraisonDate: Date?
    let harvestDate: Date?
    let plantingYear: Int?
    let calculationModeOverride: String?
    let resetModeOverride: String?
    let polygonPoints: [CoordinatePoint]
    let rows: [PaddockRow]
    let varietyAllocations: [PaddockVarietyAllocation]
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case name
        case rowDirection = "row_direction"
        case rowWidth = "row_width"
        case rowOffset = "row_offset"
        case vineSpacing = "vine_spacing"
        case vineCountOverride = "vine_count_override"
        case rowLengthOverride = "row_length_override"
        case flowPerEmitter = "flow_per_emitter"
        case emitterSpacing = "emitter_spacing"
        case intermediatePostSpacing = "intermediate_post_spacing"
        case budburstDate = "budburst_date"
        case floweringDate = "flowering_date"
        case veraisonDate = "veraison_date"
        case harvestDate = "harvest_date"
        case plantingYear = "planting_year"
        case calculationModeOverride = "calculation_mode_override"
        case resetModeOverride = "reset_mode_override"
        case polygonPoints = "polygon_points"
        case rows
        case varietyAllocations = "variety_allocations"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendPaddock {
    /// Map a local Paddock into a BackendPaddock upsert payload.
    static func upsert(from paddock: Paddock, createdBy: UUID?, clientUpdatedAt: Date) -> BackendPaddockUpsert {
        BackendPaddockUpsert(
            id: paddock.id,
            vineyardId: paddock.vineyardId,
            name: paddock.name,
            rowDirection: paddock.rowDirection,
            rowWidth: paddock.rowWidth,
            rowOffset: paddock.rowOffset,
            vineSpacing: paddock.vineSpacing,
            vineCountOverride: paddock.vineCountOverride,
            rowLengthOverride: paddock.rowLengthOverride,
            flowPerEmitter: paddock.flowPerEmitter,
            emitterSpacing: paddock.emitterSpacing,
            intermediatePostSpacing: paddock.intermediatePostSpacing,
            budburstDate: paddock.budburstDate,
            floweringDate: paddock.floweringDate,
            veraisonDate: paddock.veraisonDate,
            harvestDate: paddock.harvestDate,
            plantingYear: paddock.plantingYear,
            calculationModeOverride: paddock.calculationModeOverride?.rawValue,
            resetModeOverride: paddock.resetModeOverride?.rawValue,
            polygonPoints: paddock.polygonPoints,
            rows: paddock.rows,
            varietyAllocations: paddock.varietyAllocations,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    /// Map a remote BackendPaddock into a local Paddock.
    func toPaddock() -> Paddock {
        Paddock(
            id: id,
            vineyardId: vineyardId,
            name: name,
            polygonPoints: polygonPoints ?? [],
            rows: rows ?? [],
            rowDirection: rowDirection ?? 0,
            rowWidth: rowWidth ?? 2.5,
            rowOffset: rowOffset ?? 0,
            vineSpacing: vineSpacing ?? 1.0,
            vineCountOverride: vineCountOverride,
            rowLengthOverride: rowLengthOverride,
            flowPerEmitter: flowPerEmitter,
            emitterSpacing: emitterSpacing,
            intermediatePostSpacing: intermediatePostSpacing,
            varietyAllocations: varietyAllocations ?? [],
            budburstDate: budburstDate,
            floweringDate: floweringDate,
            veraisonDate: veraisonDate,
            harvestDate: harvestDate,
            plantingYear: plantingYear,
            calculationModeOverride: calculationModeOverride.flatMap { GDDCalculationMode(rawValue: $0) },
            resetModeOverride: resetModeOverride.flatMap { GDDResetMode(rawValue: $0) }
        )
    }
}
