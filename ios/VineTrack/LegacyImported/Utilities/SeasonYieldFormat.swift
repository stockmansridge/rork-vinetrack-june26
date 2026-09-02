import Foundation

/// Presentation helpers shared by every seasonal-estimate surface, so "—"
/// means the same thing everywhere.
nonisolated enum SeasonYieldFormat {

    /// Tonnes, or "—" when the canonical figure is unknown.
    ///
    /// This is the single place the incomplete-estimate dash is produced. A
    /// withheld total must never render as `0 t`: zero is a measured answer,
    /// "—" is an honest one.
    static func tonnes(_ value: Double?, fractionDigits: Int = 2) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(fractionDigits)f t", value)
    }

    /// Hectares, or "—".
    static func hectares(_ value: Double?, fractionDigits: Int = 2) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(fractionDigits)f ha", value)
    }

    /// A percentage from a 0...1 fraction, e.g. 0.02 → "2.0%".
    static func percent(fraction: Double?, fractionDigits: Int = 1) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return String(format: "%.\(fractionDigits)f%%", fraction * 100)
    }

    /// A plain number, or "—".
    static func number(_ value: Double?, fractionDigits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(fractionDigits)f", value)
    }

    /// Human label for `season_yield_estimates.estimate_source`.
    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "manual": return "Manual entry"
        case "bunch_count": return "Bunch Count Trip"
        case "pruning", "pruning_calculator": return "Pruning Yield Calculator"
        case "none": return "Not estimated"
        default: return source.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Short label for the vine-count basis recorded in `source_inputs`.
    static func vineCountBasisLabel(_ basis: String?) -> String {
        switch basis {
        case "block_vine_count_override": return "Block vine count override"
        case "block_area_x_vines_per_ha": return "Block area × vines/ha"
        case .some(let other) where !other.isEmpty:
            return other.replacingOccurrences(of: "_", with: " ").capitalized
        default: return "—"
        }
    }

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Calculation timestamp, or "Never".
    static func calculatedAt(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return dateTime.string(from: date)
    }
}
