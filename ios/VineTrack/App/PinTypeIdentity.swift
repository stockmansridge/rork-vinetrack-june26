import Foundation

/// Stable duplicate-warning identity for a launcher pin. Location, colour,
/// launcher position and observation details deliberately do not participate.
nonisolated struct PinTypeIdentity: Hashable, Sendable, CustomStringConvertible {
    static let growthStageLogicalType = "growth stage"

    let mode: String
    let logicalType: String

    init(mode: PinMode, logicalType: String) {
        self.mode = Self.normalize(mode.rawValue)
        self.logicalType = Self.normalizeLogicalType(logicalType)
    }

    init(existing pin: VinePin) {
        self.init(mode: pin.mode, logicalType: pin.buttonName)
    }

    var description: String { "\(mode)|\(logicalType)" }

    static func normalize(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func normalizeLogicalType(_ value: String) -> String {
        let normalized = normalize(value)
        if normalized == growthStageLogicalType || normalized.hasPrefix("\(growthStageLogicalType) ") {
            return growthStageLogicalType
        }
        return normalized
    }
}
