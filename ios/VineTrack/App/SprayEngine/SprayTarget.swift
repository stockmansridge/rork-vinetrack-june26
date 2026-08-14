import Foundation

/// What a spray is aimed at — the pest, disease or agronomic purpose.
///
/// Stored as a STABLE INTERNAL IDENTIFIER, never as display text, so the label
/// can be reworded (or localised) without orphaning historical records and
/// without breaking the future Resistance Check, which will match on these
/// identifiers rather than on strings a user typed.
///
/// Multiple targets per spray are supported by design: a single tank commonly
/// addresses powdery and downy in one pass.
nonisolated enum SprayTarget: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case powderyMildew = "powdery_mildew"
    case downyMildew = "downy_mildew"
    case botrytis = "botrytis"
    case weeds = "weeds"
    case nutritionBiostimulant = "nutrition_biostimulant"
    case other = "other"

    nonisolated var id: String { rawValue }

    var label: String {
        switch self {
        case .powderyMildew: return "Powdery Mildew"
        case .downyMildew: return "Downy Mildew"
        case .botrytis: return "Botrytis"
        case .weeds: return "Weeds"
        case .nutritionBiostimulant: return "Nutrition / Biostimulant"
        case .other: return "Other"
        }
    }

    var iconName: String {
        switch self {
        case .powderyMildew: return "circle.dotted"
        case .downyMildew: return "drop.triangle"
        case .botrytis: return "allergens"
        case .weeds: return "leaf"
        case .nutritionBiostimulant: return "sparkles"
        case .other: return "questionmark.circle"
        }
    }

    /// True for targets a fungicide resistance strategy applies to.
    ///
    /// This is the hook the Resistance Check will read. It deliberately lives on
    /// the target rather than in the UI so the future rules engine and this flow
    /// cannot disagree about which targets are resistance-relevant.
    var isFungicideResistanceRelevant: Bool {
        switch self {
        case .powderyMildew, .downyMildew, .botrytis: return true
        case .weeds, .nutritionBiostimulant, .other: return false
        }
    }

    /// Tolerant decode from stored text, so an unknown or legacy value degrades
    /// to `nil` instead of failing the record.
    static func from(_ raw: String?) -> SprayTarget? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if let exact = SprayTarget(rawValue: raw) { return exact }
        switch raw {
        case "powdery", "pm", "powdery mildew": return .powderyMildew
        case "downy", "dm", "downy mildew": return .downyMildew
        case "nutrition", "biostimulant", "foliar nutrition": return .nutritionBiostimulant
        case "weed", "herbicide": return .weeds
        default: return nil
        }
    }

    /// Stable display order for pickers on both platforms, so iOS and Android
    /// present the same decisions in the same sequence.
    static let presentationOrder: [SprayTarget] = [
        .powderyMildew, .downyMildew, .botrytis, .weeds, .nutritionBiostimulant, .other
    ]
}

/// Where the spray head is aimed for a foliar application.
///
/// Extensible on purpose: other Australian and New Zealand terminology will be
/// added without changing the persisted shape, because this is stored as a
/// stable identifier too.
nonisolated enum SprayHeadTarget: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case fullCanopy = "full_canopy"
    case bunchLine = "bunch_line"
    case leafZone = "leaf_zone"

    nonisolated var id: String { rawValue }

    var label: String {
        switch self {
        case .fullCanopy: return "Full Canopy"
        case .bunchLine: return "Bunch Line"
        case .leafZone: return "Leaf Zone"
        }
    }

    var detail: String {
        switch self {
        case .fullCanopy: return "Whole canopy, top to bottom"
        case .bunchLine: return "Fruit zone only"
        case .leafZone: return "Foliage above the fruit zone"
        }
    }

    static func from(_ raw: String?) -> SprayHeadTarget? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if let exact = SprayHeadTarget(rawValue: raw) { return exact }
        switch raw {
        case "full canopy", "canopy", "whole canopy": return .fullCanopy
        case "bunch line", "bunchline", "fruit zone": return .bunchLine
        case "leaf zone", "leafzone", "foliage": return .leafZone
        default: return nil
        }
    }
}
