import Foundation

nonisolated struct BackendGrowthStageImage: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let stageCode: String
    let imagePath: String
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
        case stageCode = "stage_code"
        case imagePath = "image_path"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case syncVersion = "sync_version"
    }
}

nonisolated struct BackendGrowthStageImageUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let stageCode: String
    let imagePath: String
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case stageCode = "stage_code"
        case imagePath = "image_path"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}
