import Foundation

nonisolated struct VintageReportRequestInput: Codable, Sendable {
    nonisolated struct Narrative: Codable, Sendable { let narrative: String }
    let action: String
    let through: String
    let expected: UUID?
    let content: Narrative?
}
