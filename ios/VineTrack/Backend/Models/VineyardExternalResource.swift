import Foundation

/// A vineyard resource is not a login account and carries no labour-rate authority.
nonisolated struct VineyardExternalResource: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID
    var name: String
    var kind: String
    var contactName: String?
    var phone: String?
    var email: String?
    var notes: String?
    var isActive: Bool
    var deletedAt: String?
    var updatedAt: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, name, kind, phone, email, notes
        case vineyardId = "vineyard_id", contactName = "contact_name", isActive = "is_active", deletedAt = "deleted_at", updatedAt = "updated_at"
    }
}
