import Foundation

/// Boundary conversion only. Chemical engines and physical-vine-row dilute references are unchanged.
nonisolated enum SprayControllerRateEntry {
    static func canonical(_ value: Double?, basis: SprayCarrierBasis, configuration: SprayPassConfiguration?, spacing: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        if basis == .litresPerHectare { return value }
        guard basis == .litresPer100Metres, let spacing, spacing.isFinite, spacing > 0 else { return nil }
        return value * 100 / (spacing * (configuration?.rowEquivalents ?? 1))
    }

    static func displayed(_ canonical: Double?, basis: SprayCarrierBasis, configuration: SprayPassConfiguration?, spacing: Double?) -> Double? {
        guard let canonical, canonical.isFinite, canonical > 0 else { return nil }
        if basis == .litresPerHectare { return canonical }
        guard basis == .litresPer100Metres, let spacing, spacing.isFinite, spacing > 0 else { return nil }
        return canonical * spacing * (configuration?.rowEquivalents ?? 1) / 100
    }
}
