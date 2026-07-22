import Foundation

/// Formats chemical spray rates for display with up to 3 decimal places,
/// trimming trailing zeros. Small per-100L rates such as 0.15 must never
/// collapse to "0" (which previous "%.0f"/"%.1f" formatting caused), while
/// whole-number rates still render cleanly ("200", not "200.000").
enum SprayRateFormatter {
    /// "0.15" for 0.15, "2" for 2.0, "1.5" for 1.5, "0.125" for 0.125.
    static func format(_ value: Double) -> String {
        var formatted = String(format: "%.3f", value)
        while formatted.hasSuffix("0") {
            formatted.removeLast()
        }
        if formatted.hasSuffix(".") {
            formatted.removeLast()
        }
        return formatted
    }
}
