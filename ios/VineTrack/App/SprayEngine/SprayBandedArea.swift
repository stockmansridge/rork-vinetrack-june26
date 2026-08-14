import Foundation

/// The sprayed band width per row for a banded/strip application.
///
/// The AUTHORITATIVE value for every calculation is `totalMetres` — the total
/// treated width per row. Left/right are carried for future nozzle-level setups
/// (e.g. an under-vine boom treating 0.5 m one side and 0.3 m the other) and are
/// never used directly by the arithmetic.
nonisolated struct SprayBandWidth: Sendable, Hashable, Codable {
    let leftMetres: Double?
    let rightMetres: Double?
    /// Total treated width per row, in metres. This is what the maths uses.
    let totalMetres: Double

    /// A single total treated width per row.
    static func total(_ metres: Double) -> SprayBandWidth {
        SprayBandWidth(leftMetres: nil, rightMetres: nil, totalMetres: metres)
    }

    /// Separate left/right widths; the total is their sum.
    static func leftRight(left: Double, right: Double) -> SprayBandWidth {
        SprayBandWidth(leftMetres: left, rightMetres: right, totalMetres: left + right)
    }

    var isValid: Bool { totalMetres.isFinite && totalMetres > 0 }
}

/// How a treated area was arrived at.
nonisolated enum SprayTreatedAreaMethod: String, Sendable, Codable {
    /// `canonicalRowLengthMetres × totalBandWidth ÷ 10_000` — preferred.
    case canonicalRowLength = "canonical_row_length"
    /// `grossHa × totalBandWidth ÷ rowSpacing` — only when no canonical length.
    case areaAndSpacingFallback = "area_and_spacing_fallback"
    /// Not a banded application: treated area IS the gross area.
    case wholeBlock = "whole_block"
    /// Could not be determined.
    case unavailable
}

/// Gross vs actual treated area for an application.
///
/// Both figures are always retained. Treated area NEVER replaces gross area —
/// reporting, per-hectare costs and whole-block product rates still need gross.
nonisolated struct SprayTreatedArea: Sendable, Hashable {
    let grossAreaHectares: Double
    /// Actual treated hectares. `nil` when it could not be calculated.
    let treatedAreaHectares: Double?
    let method: SprayTreatedAreaMethod
    let bandWidth: SprayBandWidth?
    let rowLengthMetres: Double?

    /// Treated ÷ gross, e.g. 0.25 for a 0.8 m band at 3.2 m spacing.
    var treatedFraction: Double? {
        guard let treated = treatedAreaHectares, grossAreaHectares > 0 else { return nil }
        return treated / grossAreaHectares
    }
}

nonisolated enum SprayBandedAreaCalculator {

    static let squareMetresPerHectare: Double = 10_000

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Treated area from canonical row length — the authoritative form.
    ///
    /// ```text
    /// treatedAreaHa = canonicalRowLengthMetres × totalTreatedBandWidthMetres ÷ 10_000
    /// ```
    ///
    /// Example: 31,250 m × 0.8 m ÷ 10,000 = 2.50 ha treated (from a 10 ha block).
    static func treatedAreaFromRowLength(rowLengthMetres: Double, bandWidthMetres: Double) -> Double? {
        guard let metres = positive(rowLengthMetres), let band = positive(bandWidthMetres) else { return nil }
        return metres * band / squareMetresPerHectare
    }

    /// Fallback when no canonical row length exists but gross hectares and row
    /// spacing are both known and valid.
    ///
    /// ```text
    /// treatedAreaHa = grossBlockHa × totalTreatedBandWidthMetres ÷ rowSpacingMetres
    /// ```
    ///
    /// Example: 10 ha × 0.8 m ÷ 3.2 m = 2.50 ha treated — the same answer the
    /// canonical form gives, because deriving a row length from area and spacing
    /// and then applying the band is algebraically identical.
    ///
    /// This is NEVER a fixed fraction of block area: without a real row spacing
    /// it returns `nil` instead of guessing.
    static func treatedAreaFromAreaAndSpacing(
        grossAreaHectares: Double,
        rowSpacingMetres: Double,
        bandWidthMetres: Double
    ) -> Double? {
        guard let area = positive(grossAreaHectares),
              let spacing = positive(rowSpacingMetres),
              let band = positive(bandWidthMetres) else { return nil }
        return area * band / spacing
    }

    /// Resolves treated area for ONE block, preferring canonical row length and
    /// falling back to area × spacing.
    static func banded(block: SprayBlockGeometry, bandWidth: SprayBandWidth) -> SprayTreatedArea {
        guard bandWidth.isValid else {
            return SprayTreatedArea(
                grossAreaHectares: block.grossAreaHectares,
                treatedAreaHectares: nil,
                method: .unavailable,
                bandWidth: bandWidth,
                rowLengthMetres: block.rowLengthMetres
            )
        }
        if let metres = positive(block.rowLengthMetres),
           let treated = treatedAreaFromRowLength(rowLengthMetres: metres, bandWidthMetres: bandWidth.totalMetres) {
            return SprayTreatedArea(
                grossAreaHectares: block.grossAreaHectares,
                treatedAreaHectares: treated,
                method: .canonicalRowLength,
                bandWidth: bandWidth,
                rowLengthMetres: metres
            )
        }
        if let treated = treatedAreaFromAreaAndSpacing(
            grossAreaHectares: block.grossAreaHectares,
            rowSpacingMetres: block.rowSpacingMetres ?? 0,
            bandWidthMetres: bandWidth.totalMetres
        ) {
            return SprayTreatedArea(
                grossAreaHectares: block.grossAreaHectares,
                treatedAreaHectares: treated,
                method: .areaAndSpacingFallback,
                bandWidth: bandWidth,
                rowLengthMetres: nil
            )
        }
        return SprayTreatedArea(
            grossAreaHectares: block.grossAreaHectares,
            treatedAreaHectares: nil,
            method: .unavailable,
            bandWidth: bandWidth,
            rowLengthMetres: nil
        )
    }

    /// Resolves treated area across the whole selection.
    ///
    /// Calculated PER BLOCK and then summed, so a selection whose blocks have
    /// different row spacings stays correct — an averaged spacing would be wrong
    /// for every block in the set.
    ///
    /// If ANY block cannot be resolved, the treated total is `nil`: a partial
    /// treated area silently under-doses the mix.
    static func banded(geometry: SprayApplicationGeometry, bandWidth: SprayBandWidth) -> SprayTreatedArea {
        let perBlock = geometry.blocks.map { banded(block: $0, bandWidth: bandWidth) }
        let treated: Double? = perBlock.allSatisfy { $0.treatedAreaHectares != nil } && !perBlock.isEmpty
            ? perBlock.reduce(0) { $0 + ($1.treatedAreaHectares ?? 0) }
            : nil
        let method: SprayTreatedAreaMethod = {
            guard treated != nil, let first = perBlock.first?.method else { return .unavailable }
            if perBlock.allSatisfy({ $0.method == first }) { return first }
            return .areaAndSpacingFallback
        }()
        return SprayTreatedArea(
            grossAreaHectares: geometry.grossAreaHectares,
            treatedAreaHectares: treated,
            method: method,
            bandWidth: bandWidth,
            rowLengthMetres: geometry.totalRowLengthMetres
        )
    }

    /// A non-banded application: the treated area IS the gross area. Modelled
    /// explicitly so callers never have to special-case foliar jobs.
    static func wholeBlock(geometry: SprayApplicationGeometry) -> SprayTreatedArea {
        SprayTreatedArea(
            grossAreaHectares: geometry.grossAreaHectares,
            treatedAreaHectares: geometry.grossAreaHectares,
            method: .wholeBlock,
            bandWidth: nil,
            rowLengthMetres: geometry.totalRowLengthMetres
        )
    }
}
