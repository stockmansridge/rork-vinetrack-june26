import Foundation

/// Immutable server revision; evidence dates remain independent of its save time.
nonisolated struct VintageReportRevision: Codable, Identifiable, Sendable {
    let id: UUID
    let revision: Int
    let operationID: UUID
    let action: String
    let createdAt: String
    let reportThrough: String
    let collectedAt: String
    let evidence: VintageReportCoverage
    let content: VintageReportContent
    nonisolated private enum CodingKeys: String, CodingKey {
        case id, revision, operationID = "operation_id", action, createdAt = "created_at"
        case reportThrough = "report_through", collectedAt = "collected_at", evidence, content
    }
}
