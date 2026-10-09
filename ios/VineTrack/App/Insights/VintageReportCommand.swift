import Foundation

/// Exact locally persisted intent. The operation identity and baseline never rebase.
nonisolated struct VintageReportCommand: Codable, Sendable {
    let action: String
    let operation: UUID
    let expected: UUID?
    let through: String
    let narrative: String?
}
