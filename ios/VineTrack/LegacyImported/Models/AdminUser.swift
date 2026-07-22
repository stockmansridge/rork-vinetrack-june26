import Foundation

nonisolated struct AdminUser: Codable, Identifiable, Sendable {
    let user_id: UUID
    let email: String
    let full_name: String
    let provider: String
    let created_at: String
    let last_sign_in_at: String?
    let is_admin: Bool
    let vineyard_count: Int
    let vineyard_names: String
    let total_members: Int

    var id: UUID { user_id }

    var createdDate: Date? {
        ISO8601DateFormatter().date(from: created_at)
    }

    var lastSignInDate: Date? {
        guard let str = last_sign_in_at else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    var vineyardList: [String] {
        guard !vineyard_names.isEmpty else { return [] }
        return vineyard_names.components(separatedBy: ", ")
    }

    var providerDisplay: String {
        switch provider.lowercased() {
        case "google": return "Google"
        case "email": return "Email"
        default: return provider.capitalized
        }
    }
}
