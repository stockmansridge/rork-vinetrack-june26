import Foundation

/// The training system the canopy is grown on.
///
/// # Why this had to become an explicit question
///
/// Every canopy control in VineTrack was headed "VSP Canopy Size", and the
/// water-rate table behind it is the VSP table. That was not a labelling
/// accident — the numbers genuinely describe a vertically positioned canopy,
/// where the wires hold the foliage to roughly half a metre of width no matter
/// how tall it grows. A sprawl block at the same height carries far more leaf
/// area and needs materially more water to wet through.
///
/// So the training system was always an input to the calculation; it was simply
/// hard-coded to VSP by being unasked. Making it a question is what allows a
/// second system to exist without a second calculator.
nonisolated enum CanopyType: String, CaseIterable, Sendable, Codable {
    case vsp = "VSP"
    case sprawl = "Sprawl"

    var help: String {
        "Choose the canopy/training style that best matches this block. "
            + "VSP is a vertically positioned canopy. Sprawl has a wider, "
            + "less vertically constrained canopy."
    }
}

/// Where a canopy reference picture comes from.
///
/// VSP's images are the existing hosted ones and are reused byte-for-byte. The
/// Sprawl slots are bundled asset names so the artwork can be dropped into the
/// asset catalogue without touching code — and until it is, the control shows
/// an explicit "image not available" state rather than a VSP picture standing
/// in for a sprawl canopy, which would be worse than no picture at all.
nonisolated enum CanopyReferenceImage: Sendable, Hashable {
    case remote(URL)
    case bundled(name: String)
}

nonisolated enum CanopySize: String, CaseIterable, Sendable, Codable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    case full = "Full"

    /// What this size means for a VSP canopy — the existing wording, unchanged.
    var description: String { description(for: .vsp) }

    /// The canopy dimensions this size represents, per training system.
    ///
    /// # The audit behind these strings
    ///
    /// The four sizes are HEIGHT steps: 0.5 m, 1 m, 1.5 m, 2 m. The second
    /// dimension is a property of the training system, not of the size:
    ///
    /// ```text
    /// size    VSP                     Sprawl
    /// Small   up to 0.5 m × 0.5 m     up to 0.5 m × 0.5 m
    /// Medium  up to 1 m × 1 m         up to 1 m × 1 m
    /// Large   wires up, 1.5 m × 0.5 m approx 1.5 m × 1.5 m
    /// Full    wires up, 2 m × 0.5 m   approx 2 m × 2 m
    /// ```
    ///
    /// Small and Medium are IDENTICAL in both systems, and the existing VSP
    /// wording already says why: neither carries "Wires Up". Before the wires
    /// go up there is no vertical positioning, so a VSP block and a sprawl
    /// block of the same height are the same canopy. They diverge exactly where
    /// the VSP wording starts saying "Wires Up" — which is where the source
    /// material's sprawl dimensions widen to 1.5 m and 2 m.
    ///
    /// That correspondence is why this is a mapping and not a guess.
    func description(for type: CanopyType) -> String {
        switch (type, self) {
        case (.vsp, .small): return "up to 0.5m × 0.5m"
        case (.vsp, .medium): return "up to 1m × 1m"
        case (.vsp, .large): return "Wires Up - 1.5m × 0.5m"
        case (.vsp, .full): return "Wires Up - 2m × 0.5m"
        case (.sprawl, .small): return "up to 0.5m × 0.5m"
        case (.sprawl, .medium): return "up to 1m × 1m"
        case (.sprawl, .large): return "approx. 1.5m × 1.5m"
        case (.sprawl, .full): return "approx. 2m × 2m and above"
        }
    }

    /// The existing hosted VSP reference imagery. Unchanged.
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

    /// The bundled asset name for this size's Sprawl reference picture.
    ///
    /// Drop the artwork into `ios/VineTrack/Assets.xcassets` under exactly
    /// these names and it appears with no code change.
    var sprawlAssetName: String {
        switch self {
        case .small: return "canopy-sprawl-small"
        case .medium: return "canopy-sprawl-medium"
        case .large: return "canopy-sprawl-large"
        case .full: return "canopy-sprawl-full"
        }
    }

    func referenceImage(for type: CanopyType) -> CanopyReferenceImage? {
        switch type {
        case .vsp:
            return referenceImageURL.map { .remote($0) }
        case .sprawl:
            return .bundled(name: sprawlAssetName)
        }
    }

    static let help = "Choose the image/size that most closely represents the canopy "
        + "being sprayed. This describes the canopy, not the vineyard area."
}

nonisolated enum CanopyDensity: String, CaseIterable, Sendable, Codable {
    case low = "Low"
    case high = "High"

    static let help = "Low is an open, well-exposed canopy. High is denser growth "
        + "that requires more water to wet through."
}

/// The canopy water-rate table: litres per 100 m of row, by training system,
/// canopy size and density.
///
/// Low density takes the lower end of each source range and High the upper end
/// — the established VineTrack reading of the guidance, unchanged.
nonisolated struct CanopyWaterRateEntry: Codable, Sendable {
    // VSP — the existing values. NOT modified by the addition of Sprawl.
    var smallLow: Double
    var smallHigh: Double
    var mediumLow: Double
    var mediumHigh: Double
    var largeLow: Double
    var largeHigh: Double
    var fullLow: Double
    var fullHigh: Double

    // Sprawl — source-backed ranges.
    var sprawlSmallLow: Double
    var sprawlSmallHigh: Double
    var sprawlMediumLow: Double
    var sprawlMediumHigh: Double
    var sprawlLargeLow: Double
    var sprawlLargeHigh: Double
    var sprawlFullLow: Double
    var sprawlFullHigh: Double

    /// ```text
    /// VSP     Small 10–20   Medium 20–40   Large 30–45   Full 45–75
    /// Sprawl  Small 10–20   Medium 20–40   Large 45–60   Full 60–90
    /// ```
    ///
    /// The VSP row is untouched. Sprawl matches VSP at Small and Medium — the
    /// pre-wires-up sizes, where the two systems are the same canopy — and is
    /// higher at Large and Full, which is the whole reason the question exists.
    static let defaults = CanopyWaterRateEntry(
        smallLow: 10, smallHigh: 20,
        mediumLow: 20, mediumHigh: 40,
        largeLow: 30, largeHigh: 45,
        fullLow: 45, fullHigh: 75,
        sprawlSmallLow: 10, sprawlSmallHigh: 20,
        sprawlMediumLow: 20, sprawlMediumHigh: 40,
        sprawlLargeLow: 45, sprawlLargeHigh: 60,
        sprawlFullLow: 60, sprawlFullHigh: 90
    )

    init(
        smallLow: Double,
        smallHigh: Double,
        mediumLow: Double,
        mediumHigh: Double,
        largeLow: Double,
        largeHigh: Double,
        fullLow: Double,
        fullHigh: Double,
        sprawlSmallLow: Double = 10,
        sprawlSmallHigh: Double = 20,
        sprawlMediumLow: Double = 20,
        sprawlMediumHigh: Double = 40,
        sprawlLargeLow: Double = 45,
        sprawlLargeHigh: Double = 60,
        sprawlFullLow: Double = 60,
        sprawlFullHigh: Double = 90
    ) {
        self.smallLow = smallLow
        self.smallHigh = smallHigh
        self.mediumLow = mediumLow
        self.mediumHigh = mediumHigh
        self.largeLow = largeLow
        self.largeHigh = largeHigh
        self.fullLow = fullLow
        self.fullHigh = fullHigh
        self.sprawlSmallLow = sprawlSmallLow
        self.sprawlSmallHigh = sprawlSmallHigh
        self.sprawlMediumLow = sprawlMediumLow
        self.sprawlMediumHigh = sprawlMediumHigh
        self.sprawlLargeLow = sprawlLargeLow
        self.sprawlLargeHigh = sprawlLargeHigh
        self.sprawlFullLow = sprawlFullLow
        self.sprawlFullHigh = sprawlFullHigh
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case smallLow, smallHigh, mediumLow, mediumHigh
        case largeLow, largeHigh, fullLow, fullHigh
        case sprawlSmallLow, sprawlSmallHigh, sprawlMediumLow, sprawlMediumHigh
        case sprawlLargeLow, sprawlLargeHigh, sprawlFullLow, sprawlFullHigh
    }

    /// Tolerant decode — and this one is load-bearing.
    ///
    /// Every existing user has a persisted settings blob containing the eight
    /// VSP keys and none of the eight Sprawl ones. The synthesised decoder
    /// would require all sixteen and throw, and `AppSettings` decodes this with
    /// `try container.decodeIfPresent(...)` — a throw there propagates and takes
    /// the operator's ENTIRE settings record with it, not just the canopy
    /// table. Absent Sprawl keys fall back to the source defaults; an absent or
    /// unreadable VSP key falls back to its existing default, exactly as
    /// before.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double) -> Double {
            guard let decoded = try? c.decodeIfPresent(Double.self, forKey: key),
                  decoded.isFinite else { return fallback }
            return decoded
        }
        let d = CanopyWaterRateEntry.defaults
        smallLow = value(.smallLow, d.smallLow)
        smallHigh = value(.smallHigh, d.smallHigh)
        mediumLow = value(.mediumLow, d.mediumLow)
        mediumHigh = value(.mediumHigh, d.mediumHigh)
        largeLow = value(.largeLow, d.largeLow)
        largeHigh = value(.largeHigh, d.largeHigh)
        fullLow = value(.fullLow, d.fullLow)
        fullHigh = value(.fullHigh, d.fullHigh)
        sprawlSmallLow = value(.sprawlSmallLow, d.sprawlSmallLow)
        sprawlSmallHigh = value(.sprawlSmallHigh, d.sprawlSmallHigh)
        sprawlMediumLow = value(.sprawlMediumLow, d.sprawlMediumLow)
        sprawlMediumHigh = value(.sprawlMediumHigh, d.sprawlMediumHigh)
        sprawlLargeLow = value(.sprawlLargeLow, d.sprawlLargeLow)
        sprawlLargeHigh = value(.sprawlLargeHigh, d.sprawlLargeHigh)
        sprawlFullLow = value(.sprawlFullLow, d.sprawlFullLow)
        sprawlFullHigh = value(.sprawlFullHigh, d.sprawlFullHigh)
    }

    /// The existing VSP-only lookup. Kept so every current caller and every
    /// stored VSP calculation keeps its exact meaning.
    func litresPer100m(size: CanopySize, density: CanopyDensity) -> Double {
        litresPer100m(type: .vsp, size: size, density: density)
    }

    func litresPer100m(
        type: CanopyType,
        size: CanopySize,
        density: CanopyDensity
    ) -> Double {
        switch (type, size, density) {
        case (.vsp, .small, .low): return smallLow
        case (.vsp, .small, .high): return smallHigh
        case (.vsp, .medium, .low): return mediumLow
        case (.vsp, .medium, .high): return mediumHigh
        case (.vsp, .large, .low): return largeLow
        case (.vsp, .large, .high): return largeHigh
        case (.vsp, .full, .low): return fullLow
        case (.vsp, .full, .high): return fullHigh
        case (.sprawl, .small, .low): return sprawlSmallLow
        case (.sprawl, .small, .high): return sprawlSmallHigh
        case (.sprawl, .medium, .low): return sprawlMediumLow
        case (.sprawl, .medium, .high): return sprawlMediumHigh
        case (.sprawl, .large, .low): return sprawlLargeLow
        case (.sprawl, .large, .high): return sprawlLargeHigh
        case (.sprawl, .full, .low): return sprawlFullLow
        case (.sprawl, .full, .high): return sprawlFullHigh
        }
    }
}

nonisolated enum CanopyWaterRate {
    struct RateEntry: Sendable {
        let litresPer100m: Double
        let litresPerHa: Double
    }

    /// VSP lookup — the existing signature, unchanged behaviour.
    static func litresPer100m(
        size: CanopySize,
        density: CanopyDensity,
        settings: CanopyWaterRateEntry = .defaults
    ) -> Double {
        settings.litresPer100m(type: .vsp, size: size, density: density)
    }

    static func litresPer100m(
        type: CanopyType,
        size: CanopySize,
        density: CanopyDensity,
        settings: CanopyWaterRateEntry = .defaults
    ) -> Double {
        settings.litresPer100m(type: type, size: size, density: density)
    }

    static func litresPerHa(litresPer100m: Double, rowSpacingMetres: Double) -> Double {
        guard rowSpacingMetres > 0 else { return 0 }
        return litresPer100m * 10000.0 / rowSpacingMetres / 100.0
    }

    static func rate(
        size: CanopySize,
        density: CanopyDensity,
        rowSpacingMetres: Double,
        settings: CanopyWaterRateEntry = .defaults
    ) -> RateEntry {
        rate(type: .vsp, size: size, density: density, rowSpacingMetres: rowSpacingMetres, settings: settings)
    }

    static func rate(
        type: CanopyType,
        size: CanopySize,
        density: CanopyDensity,
        rowSpacingMetres: Double,
        settings: CanopyWaterRateEntry = .defaults
    ) -> RateEntry {
        let per100m = litresPer100m(type: type, size: size, density: density, settings: settings)
        let perHa = litresPerHa(litresPer100m: per100m, rowSpacingMetres: rowSpacingMetres)
        return RateEntry(litresPer100m: per100m, litresPerHa: perHa)
    }
}
