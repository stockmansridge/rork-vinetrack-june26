import Foundation

/// Immutable local-unit editor seed that preserves exact canonical values when untouched.
nonisolated struct RegionalInput {
    let canonical: Double?
    let text: String

    init(canonical: Double?, forward: (Double) -> Double) {
        self.canonical = canonical
        text = canonical.map { String(forward($0)) } ?? ""
    }

    func resolve(_ editedText: String, inverse: (Double) -> Double) -> Double? {
        if editedText == text { return canonical }
        guard let value = Double(editedText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        let result = inverse(value)
        return result.isFinite ? result : nil
    }
}
