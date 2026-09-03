import Foundation

/// Formats a Vintage identifier without locale grouping separators.
nonisolated enum VintageYearText {
    static func format(_ year: Int) -> String {
        String(year)
    }

    static func label(_ year: Int) -> String {
        "Vintage \(format(year))"
    }
}
