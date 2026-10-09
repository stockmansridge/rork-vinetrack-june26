import Foundation

/// Lightweight history entry; immutable content is fetched only when needed.
nonisolated struct VintageReportRevisionMetadata: Codable, Identifiable, Sendable {
    let id: UUID
    let revision: Int
    let operationID: UUID
    let action: String
    let createdAt: String
    let reportThrough: String
    let collectedAt: String
    nonisolated private enum CodingKeys: String, CodingKey {
        case id, revision, operationID = "operation_id", action, createdAt = "created_at"
        case reportThrough = "report_through", collectedAt = "collected_at"
    }
    init(_ revision: VintageReportRevision) {
        id = revision.id; self.revision = revision.revision; operationID = revision.operationID
        action = revision.action; createdAt = revision.createdAt
        reportThrough = revision.reportThrough; collectedAt = revision.collectedAt
    }
}
