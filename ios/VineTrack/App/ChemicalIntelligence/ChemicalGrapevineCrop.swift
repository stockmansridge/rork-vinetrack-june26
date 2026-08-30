import Foundation

/// Whether a label's crop wording means GRAPEVINES.
///
/// Device mirror of the canonical server predicate `isGrapevineCrop` in
/// `supabase/functions/chemical-info-lookup/grapevine_label.ts`. The two must
/// agree exactly: the server decides which directions land in `grapevine_uses`,
/// and a client that partitions the same label differently would show, save or
/// dose off a use the server never classified as viticultural.
///
/// # Why this is not a substring test
///
/// `"GRAPEFRUIT"` contains `"grape"`. A naive `contains("grape")` therefore
/// classifies a citrus as a grapevine, which puts a citrus rate on a vineyard
/// spray record — a wrong dose wearing a plausible name, which is worse than a
/// visible gap. Matching is whole-token and adjacent-pair only.
nonisolated enum ChemicalGrapevineCrop {

    /// Crop wording that means grapevines, as WHOLE tokens.
    private static let tokens: Set<String> = [
        "grape",
        "grapes",
        "grapevine",
        "grapevines",
        "vine",
        "vines",
        "vineyard",
        "vineyards",
        "winegrape",
        "winegrapes",
        "tablegrape",
        "tablegrapes"
    ]

    /// Multi-word crop wordings that mean grapevines.
    ///
    /// Checked as adjacent token PAIRS, so `"WINE GRAPES"`, `"TABLE GRAPES"`
    /// and `"DRIED GRAPES"` resolve without letting a bare `"wine"` or
    /// `"dried"` through on its own.
    private static let phrases: Set<String> = [
        "wine grape",
        "wine grapes",
        "table grape",
        "table grapes",
        "dried grape",
        "dried grapes",
        "grape vine",
        "grape vines"
    ]

    /// VineTrack's single normalised crop class for everything above.
    static let cropClass: String = "Grapevines"

    /// Split crop wording into lowercase alphanumeric tokens.
    static func cropTokens(_ crop: String) -> [String] {
        crop.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Whether this crop wording means grapevines.
    ///
    /// `GRAPEFRUIT` must never match: it is a citrus, and a citrus rate on a
    /// vineyard record is a wrong dose with a plausible name.
    static func matches(_ crop: String) -> Bool {
        let parts = cropTokens(crop)
        guard !parts.isEmpty else { return false }
        for token in parts where tokens.contains(token) { return true }
        guard parts.count > 1 else { return false }
        for index in 0..<(parts.count - 1) {
            if phrases.contains("\(parts[index]) \(parts[index + 1])") { return true }
        }
        return false
    }
}
