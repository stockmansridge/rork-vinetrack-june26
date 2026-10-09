import Foundation

nonisolated struct VintageReportCache: Codable, Sendable {
    var revisions: [VintageReportRevision] = []
    var currentID: UUID?
    var coverage: VintageReportCoverage?
    var pending: VintageReportCommand?
    var request: VintageReportRequest?
}
