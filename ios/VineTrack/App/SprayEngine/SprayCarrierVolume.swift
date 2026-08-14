import Foundation

/// How the operator expresses carrier (water) volume.
///
/// This is the SPRAY/CARRIER VOLUME BASIS and is completely independent of a
/// product's label rate basis (`SprayProductRateBasis`). A New Zealand vineyard
/// may enter carrier volume exclusively in L/100 m while still dosing a product
/// whose label is authoritative in L/ha.
nonisolated enum SprayCarrierBasis: String, Sendable, Codable, CaseIterable {
    /// Hectare-based carrier volume — the long-standing VineTrack behaviour.
    case litresPerHectare = "l_per_ha"
    /// Row-length-based carrier volume — authoritative for NZ/SWNZ workflows.
    case litresPer100Metres = "l_per_100m"
}

/// A fully resolved carrier-volume calculation.
///
/// Both modes populate `totalLitres` and `concentrationFactor`, so every
/// downstream consumer (tank splitting, per-100 L product dosing, reporting)
/// works identically regardless of how the grower entered the volume.
nonisolated struct SprayCarrierVolume: Sendable, Hashable {
    let basis: SprayCarrierBasis
    /// Total actual carrier litres for the whole application.
    let totalLitres: Double
    /// Litres per hectare — as entered in `.litresPerHectare` mode, or DERIVED
    /// in `.litresPer100Metres` mode. `nil` when it cannot be derived (no
    /// uniform row spacing).
    let litresPerHectare: Double?
    /// Dilute/runoff reference rate (L/100 m). `.litresPer100Metres` only.
    let diluteLitresPer100Metres: Double?
    /// Actual applied rate (L/100 m). `.litresPer100Metres` only.
    let appliedLitresPer100Metres: Double?
    /// `dilute ÷ actual`. 1.0 when spraying dilute (no concentration).
    let concentrationFactor: Double
    /// The canonical row/trellis metres this volume was calculated from.
    let rowLengthMetres: Double?
    /// The hectares this volume was calculated from (`.litresPerHectare` mode).
    let areaHectaresUsed: Double?
    let rowSpacingMetres: Double?

    /// Dilute-equivalent litres — the volume a per-100 L label rate is written
    /// against. Equals `totalLitres × concentrationFactor`.
    var diluteEquivalentLitres: Double { totalLitres * concentrationFactor }
}

nonisolated enum SprayCarrierVolumeCalculator {

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// L/ha mode — the existing hectare-based carrier calculation.
    ///
    /// `areaHectares` is supplied by the caller rather than assumed, so a banded
    /// job can dose against treated hectares while a foliar job uses gross
    /// hectares. Existing callers pass gross hectares and are unchanged.
    ///
    /// `concentrationFactor` keeps its established VineTrack meaning
    /// (`recommendedRate ÷ chosenRate`) and defaults to 1.0.
    static func perHectare(
        litresPerHectare: Double,
        areaHectares: Double,
        concentrationFactor: Double = 1.0,
        rowLengthMetres: Double? = nil,
        rowSpacingMetres: Double? = nil
    ) -> SprayCarrierVolume {
        let rate = max(0, litresPerHectare.isFinite ? litresPerHectare : 0)
        let area = max(0, areaHectares.isFinite ? areaHectares : 0)
        let factor = positive(concentrationFactor) ?? 1.0
        return SprayCarrierVolume(
            basis: .litresPerHectare,
            totalLitres: rate * area,
            litresPerHectare: rate,
            diluteLitresPer100Metres: nil,
            appliedLitresPer100Metres: nil,
            concentrationFactor: factor,
            rowLengthMetres: rowLengthMetres,
            areaHectaresUsed: area,
            rowSpacingMetres: rowSpacingMetres
        )
    }

    /// L/100 m mode — the authoritative row-length carrier calculation.
    ///
    /// ```text
    /// totalCarrierLitres = rowLengthMetres ÷ 100 × appliedLitresPer100m
    /// derivedLitresPerHa = appliedLitresPer100m × 100 ÷ rowSpacingMetres
    /// concentrationFactor = diluteLitresPer100m ÷ appliedLitresPer100m
    /// ```
    ///
    /// `rowLengthMetres` MUST come from `SprayApplicationGeometry`, which is the
    /// same source the banded treated-area calculation uses.
    ///
    /// Returns `nil` when the row length or the applied rate is unusable —
    /// a carrier volume is never guessed.
    static func per100Metres(
        appliedLitresPer100Metres: Double,
        diluteLitresPer100Metres: Double? = nil,
        rowLengthMetres: Double?,
        rowSpacingMetres: Double? = nil
    ) -> SprayCarrierVolume? {
        guard let applied = positive(appliedLitresPer100Metres),
              let metres = positive(rowLengthMetres) else { return nil }

        let dilute = positive(diluteLitresPer100Metres)
        // Concentrating means applying LESS water than dilute/runoff. A dilute
        // reference below the applied rate is not a concentration, so the
        // factor floors at 1.0 rather than silently reducing product.
        let factor = max(1.0, (dilute ?? applied) / applied)
        let spacing = positive(rowSpacingMetres)

        return SprayCarrierVolume(
            basis: .litresPer100Metres,
            totalLitres: metres / 100.0 * applied,
            litresPerHectare: spacing.map { applied * 100.0 / $0 },
            diluteLitresPer100Metres: dilute,
            appliedLitresPer100Metres: applied,
            concentrationFactor: factor,
            rowLengthMetres: metres,
            areaHectaresUsed: nil,
            rowSpacingMetres: spacing
        )
    }

    /// Convenience: build a L/100 m carrier volume straight from canonical
    /// geometry, so callers cannot accidentally pass a different row length.
    static func per100Metres(
        appliedLitresPer100Metres: Double,
        diluteLitresPer100Metres: Double? = nil,
        geometry: SprayApplicationGeometry
    ) -> SprayCarrierVolume? {
        per100Metres(
            appliedLitresPer100Metres: appliedLitresPer100Metres,
            diluteLitresPer100Metres: diluteLitresPer100Metres,
            rowLengthMetres: geometry.totalRowLengthMetres,
            rowSpacingMetres: geometry.uniformRowSpacingMetres
        )
    }
}
