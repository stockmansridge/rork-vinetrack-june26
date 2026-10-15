import Foundation
import CryptoKit

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
    /// Exact server timestamp text, preserving microseconds for conditional writes.
    private(set) var updatedAtToken: String? = nil

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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        configType = try c.decode(String.self, forKey: .configType)
        let entries = try c.decode([LegacyButton].self, forKey: .configData)
        let scope = vineyardId
        let kind = configType
        configData = try entries.map { try $0.resolved(vineyard: scope, type: kind) }
        guard Set(configData.map(\.id)).count == configData.count,
              Set(configData.map(\.index)).count == configData.count else {
            throw DecodingError.dataCorruptedError(forKey: .configData, in: c, debugDescription: "Duplicate button identities or slots require review")
        }
        createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        updatedBy = try c.decodeIfPresent(UUID.self, forKey: .updatedBy)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        updatedAtToken = try? c.decode(String.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        clientUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .clientUpdatedAt)
        syncVersion = try c.decodeIfPresent(Int.self, forKey: .syncVersion)
    }

    /// Missing legacy identities are resolved from the containing row and stable slot,
    /// never from defaults or a random UUID. Existing identities/values are untouched.
    private struct LegacyButton: Decodable {
        let id: UUID?
        let vineyardId: UUID?
        let name: String
        let color: String
        let index: Int
        let mode: PinMode
        let isGrowthStageButton: Bool

        func resolved(vineyard: UUID, type: String) throws -> ButtonConfig {
            guard vineyardId == nil || vineyardId == vineyard else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Foreign button vineyard requires review"))
            }
            let digest = SHA256.hash(data: Data("vinetrack.button.v1/\(vineyard.uuidString.lowercased())/\(type)/\(index)".utf8))
            let bytes = Array(digest.prefix(16))
            let stable = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                (bytes[6] & 0x0f) | 0x50, bytes[7], (bytes[8] & 0x3f) | 0x80,
                bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            return ButtonConfig(id: id ?? stable, vineyardId: vineyardId ?? vineyard,
                name: name, color: color, index: index, mode: mode, isGrowthStageButton: isGrowthStageButton)
        }
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
