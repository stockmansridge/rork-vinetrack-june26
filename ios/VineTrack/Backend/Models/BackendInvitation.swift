import Foundation

nonisolated struct BackendInvitation: Identifiable, Codable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let email: String
    let role: BackendRole
    let status: String
    let invitedBy: UUID?
    let expiresAt: Date?
    let createdAt: Date?
    let vineyardName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case email
        case role
        case status
        case invitedBy = "invited_by"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case vineyards
    }

    private struct VineyardRef: Codable {
        let name: String
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        email = try c.decode(String.self, forKey: .email)
        role = try c.decode(BackendRole.self, forKey: .role)
        status = try c.decode(String.self, forKey: .status)
        invitedBy = try c.decodeIfPresent(UUID.self, forKey: .invitedBy)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        vineyardName = try c.decodeIfPresent(VineyardRef.self, forKey: .vineyards)?.name
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(email, forKey: .email)
        try c.encode(role, forKey: .role)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(invitedBy, forKey: .invitedBy)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}
