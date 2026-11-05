import Foundation

/// One parser for every engine-hour meter field (Start Trip, Spray start,
/// End Trip Review). Hour meters routinely read above 1,000, so text such as
/// "1,234.5" — including the app's own grouped display when a saved reading
/// is pre-filled — must round-trip instead of silently becoming nil (which
/// erased the saved end reading) or 1.234 (comma blindly treated as decimal).
nonisolated enum EngineHoursInput {
    /// Parses a typed or pre-filled meter reading. Returns nil for empty,
    /// malformed, negative or non-finite input.
    ///
    /// Rules, in order:
    /// - Spaces (including non-breaking/narrow) and apostrophes are grouping.
    /// - When both "," and "." appear, the LAST one is the decimal mark and
    ///   the other is grouping ("1,234.5" and "1.234,5" both → 1234.5).
    /// - A single kind of mark appearing more than once is grouping
    ///   ("1,234,567" → 1234567).
    /// - A single "," followed by exactly three digits is grouping
    ///   ("1,234" → 1234); otherwise it is the decimal mark ("1234,5").
    /// - A single "." is always the decimal mark.
    static func parse(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for grouping in [" ", "\u{00A0}", "\u{202F}", "'", "\u{2019}"] {
            s = s.replacingOccurrences(of: grouping, with: "")
        }
        guard !s.isEmpty else { return nil }
        let commas = s.filter { $0 == "," }.count
        let dots = s.filter { $0 == "." }.count
        if commas > 0 && dots > 0 {
            let lastComma = s.lastIndex(of: ",")!
            let lastDot = s.lastIndex(of: ".")!
            let decimal: Character = lastComma > lastDot ? "," : "."
            let grouping: Character = decimal == "," ? "." : ","
            guard s.filter({ $0 == decimal }).count == 1 else { return nil }
            s.removeAll { $0 == grouping }
            if decimal == "," { s = s.replacingOccurrences(of: ",", with: ".") }
        } else if commas > 1 {
            s.removeAll { $0 == "," }
        } else if dots > 1 {
            s.removeAll { $0 == "." }
        } else if commas == 1 {
            let after = s[s.index(after: s.firstIndex(of: ",")!)...]
            if after.count == 3 && after.allSatisfy(\.isNumber) && s.first != "," {
                s.removeAll { $0 == "," }
            } else {
                s = s.replacingOccurrences(of: ",", with: ".")
            }
        }
        guard s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(s), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Text used to pre-fill an editable meter field: no grouping separators,
    /// at most one fraction digit, so it always parses back to the same value.
    static func editableText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
