import Foundation

/// Server-shape model for `public.growth_stage_records`.
nonisolated struct BackendGrowthStageRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let pinId: UUID?
    let stageCode: String
    let stageLabel: String?
    let variety: String?
    let varietyId: UUID?
    let observedAt: Date?
    let latitude: Double?
    let longitude: Double?
    let rowNumber: Int?
    let side: String?
    let notes: String?
    let photoPaths: [String]?
    let recordedByName: String?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let clientUpdatedAt: Date?
    let syncVersion: Int?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case pinId = "pin_id"
        case stageCode = "stage_code"
        case stageLabel = "stage_label"
        case variety
        case varietyId = "variety_id"
        case observedAt = "observed_at"
        case latitude
        case longitude
        case rowNumber = "row_number"
        case side
        case notes
        case photoPaths = "photo_paths"
        case recordedByName = "recorded_by_name"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case clientUpdatedAt = "client_updated_at"
        case syncVersion = "sync_version"
        case deletedAt = "deleted_at"
    }
}

/// Client-authored upsert payload. Server fills `created_at`, `updated_at`,
/// `updated_by`, `sync_version`, `deleted_at`.
nonisolated struct BackendGrowthStageRecordUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let pinId: UUID?
    let stageCode: String
    let stageLabel: String?
    let variety: String?
    let varietyId: UUID?
    let observedAt: Date
    let latitude: Double?
    let longitude: Double?
    let rowNumber: Int?
    let side: String?
    let notes: String?
    let photoPaths: [String]
    let recordedByName: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case pinId = "pin_id"
        case stageCode = "stage_code"
        case stageLabel = "stage_label"
        case variety
        case varietyId = "variety_id"
        case observedAt = "observed_at"
        case latitude
        case longitude
        case rowNumber = "row_number"
        case side
        case notes
        case photoPaths = "photo_paths"
        case recordedByName = "recorded_by_name"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendGrowthStageRecord {
    static func upsert(
        from record: GrowthStageRecord,
        createdBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendGrowthStageRecordUpsert {
        BackendGrowthStageRecordUpsert(
            id: record.id,
            vineyardId: record.vineyardId,
            paddockId: record.paddockId,
            pinId: record.pinId,
            stageCode: record.stageCode,
            stageLabel: record.stageLabel,
            variety: record.variety,
            varietyId: record.varietyId,
            observedAt: record.observedAt,
            latitude: record.latitude,
            longitude: record.longitude,
            rowNumber: record.rowNumber,
            side: record.side,
            notes: record.notes,
            photoPaths: record.photoPaths,
            recordedByName: record.recordedByName,
            createdBy: record.createdBy ?? createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toGrowthStageRecord() -> GrowthStageRecord {
        GrowthStageRecord(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddockId,
            pinId: pinId,
            stageCode: stageCode,
            stageLabel: stageLabel,
            variety: variety,
            varietyId: varietyId,
            observedAt: observedAt ?? createdAt ?? Date(),
            latitude: latitude,
            longitude: longitude,
            rowNumber: rowNumber,
            side: side,
            notes: notes,
            photoPaths: photoPaths ?? [],
            recordedByName: recordedByName,
            createdBy: createdBy,
            updatedBy: updatedBy,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date()
        )
    }
}
