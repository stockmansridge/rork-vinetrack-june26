import Foundation

nonisolated enum CanopySize: String, CaseIterable, Sendable, Codable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    case full = "Full"

    var description: String {
        switch self {
        case .small: "up to 0.5m × 0.5m"
        case .medium: "up to 1m × 1m"
        case .large: "Wires Up - 1.5m × 0.5m"
        case .full: "Wires Up - 2m × 0.5m"
        }
    }

    var referenceImageURL: URL? {
        switch self {
        case .small:
            URL(string: "https://r2-pub.rork.com/attachments/n9g6j5bjz0l47bkxhd42r.png")
        case .medium:
            URL(string: "https://pub-e001eb4506b145aa938b5d3badbff6a5.r2.dev/attachments/5dye3l0veago38uvra0ec.png")
        case .large:
            URL(string: "https://pub-e001eb4506b145aa938b5d3badbff6a5.r2.dev/attachments/00p3rr1b6qpdaht5ihsdh.png")
        case .full:
            URL(string: "https://pub-e001eb4506b145aa938b5d3badbff6a5.r2.dev/attachments/iducbl7zsx0yk8ftvuntf.png")
        }
    }
}

nonisolated enum CanopyDensity: String, CaseIterable, Sendable, Codable {
    case low = "Low"
    case high = "High"
}

nonisolated struct CanopyWaterRateEntry: Codable, Sendable {
    var smallLow: Double
    var smallHigh: Double
    var mediumLow: Double
    var mediumHigh: Double
    var largeLow: Double
    var largeHigh: Double
    var fullLow: Double
    var fullHigh: Double

    static let defaults = CanopyWaterRateEntry(
        smallLow: 10, smallHigh: 20,
        mediumLow: 20, mediumHigh: 40,
        largeLow: 30, largeHigh: 45,
        fullLow: 45, fullHigh: 75
    )

    func litresPer100m(size: CanopySize, density: CanopyDensity) -> Double {
        switch (size, density) {
        case (.small, .low): return smallLow
        case (.small, .high): return smallHigh
        case (.medium, .low): return mediumLow
        case (.medium, .high): return mediumHigh
        case (.large, .low): return largeLow
        case (.large, .high): return largeHigh
        case (.full, .low): return fullLow
        case (.full, .high): return fullHigh
        }
    }
}

nonisolated enum CanopyWaterRate {
    struct RateEntry: Sendable {
        let litresPer100m: Double
        let litresPerHa: Double
    }

    static func litresPer100m(size: CanopySize, density: CanopyDensity, settings: CanopyWaterRateEntry = .defaults) -> Double {
        settings.litresPer100m(size: size, density: density)
    }

    static func litresPerHa(litresPer100m: Double, rowSpacingMetres: Double) -> Double {
        guard rowSpacingMetres > 0 else { return 0 }
        return litresPer100m * 10000.0 / rowSpacingMetres / 100.0
    }

    static func rate(size: CanopySize, density: CanopyDensity, rowSpacingMetres: Double, settings: CanopyWaterRateEntry = .defaults) -> RateEntry {
        let per100m = litresPer100m(size: size, density: density, settings: settings)
        let perHa = litresPerHa(litresPer100m: per100m, rowSpacingMetres: rowSpacingMetres)
        return RateEntry(litresPer100m: per100m, litresPerHa: perHa)
    }
}
