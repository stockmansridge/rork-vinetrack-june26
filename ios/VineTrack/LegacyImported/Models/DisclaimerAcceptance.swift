import Foundation

nonisolated struct DisclaimerAcceptance: Codable, Identifiable, Sendable {
    let id: UUID
    let user_id: String
    let user_name: String
    let user_email: String
    let accepted_at: String

    var acceptedDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: accepted_at) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: accepted_at)
    }
}

nonisolated struct DisclaimerInsert: Codable, Sendable {
    let user_id: String
    let user_name: String
    let user_email: String
}
