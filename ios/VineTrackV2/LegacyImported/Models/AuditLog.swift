import Foundation

nonisolated enum AuditAction: String, Codable, Sendable, CaseIterable {
    case delete
    case softDelete = "soft_delete"
    case restore
    case settingsChanged = "settings_changed"
    case roleChanged = "role_changed"
    case userAdded = "user_added"
    case userRemoved = "user_removed"
    case financialExport = "financial_export"
    case recordFinalized = "record_finalized"
    case recordReopened = "record_reopened"

    var displayName: String {
        switch self {
        case .delete: return "Deleted"
        case .softDelete: return "Archived"
        case .restore: return "Restored"
        case .settingsChanged: return "Settings Changed"
        case .roleChanged: return "Role Changed"
        case .userAdded: return "User Added"
        case .userRemoved: return "User Removed"
        case .financialExport: return "Financial Export"
        case .recordFinalized: return "Record Finalised"
        case .recordReopened: return "Record Reopened"
        }
    }
}

nonisolated struct AuditLogEntry: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let timestamp: Date
    let userId: String?
    let userName: String
    let userRole: String
    let action: AuditAction
    let entityType: String
    let entityId: String?
    let entityLabel: String
    let details: String

    init(
        id: UUID = UUID(),
        vineyardId: UUID,
        timestamp: Date = Date(),
        userId: String? = nil,
        userName: String = "",
        userRole: String = "",
        action: AuditAction,
        entityType: String,
        entityId: String? = nil,
        entityLabel: String = "",
        details: String = ""
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.timestamp = timestamp
        self.userId = userId
        self.userName = userName
        self.userRole = userRole
        self.action = action
        self.entityType = entityType
        self.entityId = entityId
        self.entityLabel = entityLabel
        self.details = details
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, timestamp, userId, userName, userRole
        case action, entityType, entityId, entityLabel, details
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
        userRole = try c.decodeIfPresent(String.self, forKey: .userRole) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .action) ?? "delete"
        action = AuditAction(rawValue: raw) ?? .delete
        entityType = try c.decodeIfPresent(String.self, forKey: .entityType) ?? ""
        entityId = try c.decodeIfPresent(String.self, forKey: .entityId)
        entityLabel = try c.decodeIfPresent(String.self, forKey: .entityLabel) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
    }
}
