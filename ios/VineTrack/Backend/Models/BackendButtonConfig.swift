import Foundation

/// Config types stored in `vineyard_button_configs.config_type`.
nonisolated enum BackendButtonConfigType: String, Codable, Sendable, CaseIterable {
    case repairButtons = "repair_buttons"
    case growthButtons = "growth_buttons"
    case buttonTemplates = "button_templates"
}

/// Remote row mapping for `public.vineyard_button_configs`.
/// `configData` is the raw JSON jsonb value; decode into a typed array using
/// `decodedButtonConfigs()`.
nonisolated struct BackendButtonConfig: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let configType: String
    let configData: [ButtonConfig]
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
        case configType = "config_type"
        case configData = "config_data"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case syncVersion = "sync_version"
    }

    var type: BackendButtonConfigType? {
        BackendButtonConfigType(rawValue: configType)
    }
}

/// Encodable upsert payload. Server-managed fields are omitted.
nonisolated struct BackendButtonConfigUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let configType: String
    let configData: [ButtonConfig]
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case configType = "config_type"
        case configData = "config_data"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendButtonConfig {
    static func upsert(
        id: UUID,
        vineyardId: UUID,
        configType: BackendButtonConfigType,
        buttons: [ButtonConfig],
        createdBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendButtonConfigUpsert {
        BackendButtonConfigUpsert(
            id: id,
            vineyardId: vineyardId,
            configType: configType.rawValue,
            configData: buttons,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }
}
