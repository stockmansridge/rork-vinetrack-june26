import Foundation

/// The ONE place row-length and hectare carrier figures convert into each other.
///
/// # Why this exists as a named type
///
/// `L/100 m` and `L/ha` are two views of a single physical quantity — litres of
/// water per unit of vineyard — related only by row spacing:
///
/// ```text
/// row metres per hectare = 10,000 / S
/// L/ha    = L/100 m × 100 / S
/// L/100 m = L/ha × S / 100
/// ```
///
/// When each carrier branch derived that arithmetic for itself, the canopy could
/// answer differently depending on which basis the operator happened to be
/// looking at. The canopy table is dimensional: Small/Low is *one* dilute demand
/// (10 L/100 m, which at S = 2.8 m is 357.14 L/ha), not two numbers that happen
/// to be near each other.
///
/// Everything here is pure arithmetic with no defaults. A missing or
/// non-positive row spacing returns `nil` rather than a plausible-looking
/// number, because a spacing VineTrack had to guess would silently scale every
/// hectare figure on the job.
nonisolated enum SprayCarrierConversion {

    /// Metres of row in one hectare at this spacing. `nil` when spacing is
    /// unknown — never defaulted.
    static func rowMetresPerHectare(rowSpacingMetres: Double?) -> Double? {
        guard let spacing = positive(rowSpacingMetres) else { return nil }
        return 10_000.0 / spacing
    }

    /// `L/100 m → L/ha`.
    static func litresPerHectare(
        litresPer100Metres: Double,
        rowSpacingMetres: Double?
    ) -> Double? {
        guard let spacing = positive(rowSpacingMetres),
              let value = finite(litresPer100Metres) else { return nil }
        return value * 100.0 / spacing
    }

    /// `L/ha → L/100 m`.
    static func litresPer100Metres(
        litresPerHectare: Double,
        rowSpacingMetres: Double?
    ) -> Double? {
        guard let spacing = positive(rowSpacingMetres),
              let value = finite(litresPerHectare) else { return nil }
        return value * spacing / 100.0
    }

    /// Total carrier for a row-length application: `A100 × R / 100`.
    static func totalLitres(
        appliedLitresPer100Metres: Double,
        rowLengthMetres: Double?
    ) -> Double? {
        guard let applied = positive(appliedLitresPer100Metres),
              let metres = positive(rowLengthMetres) else { return nil }
        return applied * metres / 100.0
    }

    /// Total carrier for a hectare application: `Aha × A`.
    static func totalLitres(
        appliedLitresPerHectare: Double,
        areaHectares: Double
    ) -> Double? {
        guard let applied = positive(appliedLitresPerHectare),
              let area = positive(areaHectares) else { return nil }
        return applied * area
    }

    /// THE concentration factor, for every carrier basis.
    ///
    /// # One definition, and why it floors at 1.0
    ///
    /// A per-100 L label rate is written against the DILUTE (to-runoff) volume.
    /// Concentrating means carrying less water for the same chemical, so the
    /// factor restores the dose:
    ///
    /// ```text
    /// CF = max(1.0, dilute ÷ actual)
    /// ```
    ///
    /// The floor is the load-bearing part. A factor below 1.0 would mean an
    /// operator applying MORE water than runoff also applied proportionally less
    /// chemical — but a per-100 L rate does not weaken when the vine is wetter
    /// than the label assumed; the label's concentration still has to be in the
    /// tank. Multiplying by 0.5 there would under-dose by half, silently, on the
    /// jobs most likely to be dilute sprays.
    ///
    /// Over-application of water is a real agronomic issue (drift, runoff, wash
    /// -off) — it is simply not a DOSING correction, and it is not this
    /// function's job to express it.
    static func concentrationFactor(dilute: Double?, actual: Double?) -> Double {
        guard let actual = positive(actual) else { return 1.0 }
        guard let dilute = positive(dilute) else { return 1.0 }
        return max(1.0, dilute / actual)
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
