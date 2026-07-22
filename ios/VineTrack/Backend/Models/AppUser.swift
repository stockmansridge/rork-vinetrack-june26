import Foundation

nonisolated struct AppUser: Identifiable, Codable, Sendable {
    let id: UUID
    let email: String
    let displayName: String
    let avatarURL: URL?
    let createdAt: Date?
}
