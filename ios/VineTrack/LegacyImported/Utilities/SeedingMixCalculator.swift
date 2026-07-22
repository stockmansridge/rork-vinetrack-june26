import Foundation

/// Pure helpers for the Seeding Mix Calculator.
///
/// Mirrors the logic currently embedded in
/// `StartTripSheet.fillCalculatedPercentOfMix(in:)` so the same maths can
/// be reused on the website without depending on SwiftUI views.
///
/// IMPORTANT: This file ONLY exposes pure functions. The existing
/// `StartTripSheet` implementation is unchanged and remains the live
/// path inside the iOS app. Behaviour is identical — see the call site
/// in `StartTripSheet.buildSeedingDetails()` which still owns the UI
/// flow.
nonisolated enum SeedingMixCalculator {
    /// Per-box totals for an array of mix lines, keyed by seed box
    /// (`"Front"` / `"Back"` / `"_unspecified"` for blank).
    ///
    /// - Parameter lines: Mix lines as captured on the Start Trip sheet.
    /// - Returns: A dictionary of total kg/ha per seed box. Lines with
    ///   `kgPerHa == nil` or `<= 0` are ignored.
    static func totalsByBox(in lines: [SeedingMixLine]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for line in lines {
            guard let kg = line.kgPerHa, kg > 0 else { continue }
            let key = (line.seedBox?.isEmpty == false ? line.seedBox! : "_unspecified")
            totals[key, default: 0] += kg
        }
        return totals
    }

    /// Returns `lines` with any missing `percentOfMix` populated from
    /// `kgPerHa` as a percentage of the total kg/ha within the same
    /// seed box.
    ///
    /// Rules (must match `StartTripSheet.fillCalculatedPercentOfMix`):
    /// - Operator-entered `percentOfMix` is preserved as-is.
    /// - Lines without a positive `kgPerHa` stay blank.
    /// - Lines whose box has zero total kg/ha stay blank.
    /// - Calculated values are rounded to one decimal place.
    /// - Inputs: kg/ha, seed box label.
    /// - Outputs: `percent_of_mix` (0–100, one decimal).
    /// - Validation: `kgPerHa > 0` required; otherwise blank.
    static func fillCalculatedPercentOfMix(in lines: [SeedingMixLine]) -> [SeedingMixLine] {
        guard !lines.isEmpty else { return lines }
        let totals = totalsByBox(in: lines)
        return lines.map { line in
            var updated = line
            if updated.percentOfMix == nil,
               let kg = updated.kgPerHa, kg > 0 {
                let key = (updated.seedBox?.isEmpty == false ? updated.seedBox! : "_unspecified")
                if let total = totals[key], total > 0 {
                    let pct = (kg / total) * 100.0
                    updated.percentOfMix = (pct * 10).rounded() / 10
                }
            }
            return updated
        }
    }
}
