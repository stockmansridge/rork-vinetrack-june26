import Foundation

nonisolated struct VintageReportRequest: Codable, Sendable {
    let operationID: UUID
    let status: String
    let resultRevisionID: UUID?
    let errorCode: String?
    let input: VintageReportRequestInput?
    nonisolated private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", status, resultRevisionID = "result_revision_id", errorCode = "error_code", input
    }
}
