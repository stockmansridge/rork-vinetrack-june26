import Foundation

nonisolated struct VintageReportCoverage: Codable, Sendable {
    let vineyardName: String?
    let timezone: String?
    let seasonStart: String
    let seasonEnd: String
    let reportThrough: String?
    let seasonToDate: Bool?
    let notStarted: Bool?
    let coverage: [String: Int]?
    let gaps: [String]?
    nonisolated private enum CodingKeys: String, CodingKey {
        case vineyardName = "vineyard_name", timezone, seasonStart = "season_start", seasonEnd = "season_end"
        case reportThrough = "report_through", seasonToDate = "season_to_date", notStarted = "not_started", coverage, gaps
    }
}
