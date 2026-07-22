import Foundation

nonisolated struct BackendProfile: Identifiable, Codable, Sendable {
    let id: UUID
    let email: String
    let fullName: String?
    let avatarURL: String?
    let defaultVineyardId: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName = "full_name"
        case avatarURL = "avatar_url"
        case defaultVineyardId = "default_vineyard_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
