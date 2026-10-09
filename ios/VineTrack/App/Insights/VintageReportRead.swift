import Foundation

nonisolated struct VintageReportRead: Decodable {
    nonisolated struct Pointer: Decodable {
        let currentRevisionID: UUID?
        nonisolated private enum CodingKeys: String, CodingKey { case currentRevisionID = "current_revision_id" }
    }
    let report: Pointer?
    let revisions: [VintageReportRevisionMetadata]
    let requests: [VintageReportRequest]
}
