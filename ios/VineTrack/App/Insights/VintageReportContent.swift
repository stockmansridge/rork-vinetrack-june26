import Foundation

/// Provider-independent saved narrative shared by the screen, PDF and Word.
nonisolated struct VintageReportContent: Codable, Sendable {
    let narrative: String
    let timeline: [String]
    let appendix: [String]
}
