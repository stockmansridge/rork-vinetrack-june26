import Foundation

/// Pure helpers for the Yield Determination / Yield Estimation maths.
///
/// Extracts the formula currently embedded in
/// `YieldDeterminationCalculatorView` (computed properties) and the
/// block-level multiplication used in `YieldEstimationViewModel.calculateYieldEstimates(...)`.
///
/// Only the maths is extracted. GIS, sample-site generation, damage
/// records, and persistence stay in the existing files. Behaviour is
/// unchanged because the live views still compute these values inline
/// — this file just exposes the same formulas as reusable functions
/// for the website port.
nonisolated enum YieldDeterminationFormula {
    nonisolated enum PruneMethod: String, Sendable {
        case spur
        case cane
    }

    /// Buds per vine, derived from prune method.
    ///
    /// - Spur: `budsPerSpur × spursPerVine`
    /// - Cane: `budsPerCane × canesPerVine`
    static func budsPerVine(
        method: PruneMethod,
        budsPerSpur: Double,
        spursPerVine: Double,
        budsPerCane: Double,
        canesPerVine: Double
    ) -> Double {
        switch method {
        case .spur: return budsPerSpur * spursPerVine
        case .cane: return budsPerCane * canesPerVine
        }
    }

    /// Bunches per hectare = bunchesPerBud × budsPerVine × vinesPerHa.
    static func bunchesPerHectare(
        bunchesPerBud: Double,
        budsPerVine: Double,
        vinesPerHa: Double
    ) -> Double {
        bunchesPerBud * budsPerVine * vinesPerHa
    }

    /// Yield in kg/ha = bunchesPerHa × bunchWeightGrams ÷ 1000.
    static func yieldKgPerHectare(
        bunchesPerHa: Double,
        bunchWeightGrams: Double
    ) -> Double {
        bunchesPerHa * bunchWeightGrams / 1000.0
    }

    /// Yield in tonnes/ha (kg/ha ÷ 1000).
    static func yieldTonnesPerHectare(yieldKgPerHa: Double) -> Double {
        yieldKgPerHa / 1000.0
    }

    /// Block total tonnes = tonnesPerHa × areaHectares (nil if area ≤ 0).
    static func totalYieldTonnes(yieldTonnesPerHa: Double, areaHectares: Double) -> Double? {
        guard areaHectares > 0 else { return nil }
        return yieldTonnesPerHa * areaHectares
    }

    // MARK: - Sample-based block estimate (matches YieldEstimationViewModel)

    nonisolated struct BlockEstimateInputs: Sendable {
        var totalVines: Int
        var averageBunchesPerVine: Double  // averaged across recorded sample sites
        var bunchWeightKg: Double
        var damageFactor: Double           // 1.0 if no damage applied
    }

    nonisolated struct BlockEstimateOutput: Sendable {
        var totalBunches: Double
        var estimatedYieldKg: Double
        var estimatedYieldTonnes: Double
    }

    /// Block-level yield from sampled bunch counts.
    ///
    /// Mirrors `YieldEstimationViewModel.calculateYieldEstimates`:
    /// `totalBunches = totalVines × avgBunchesPerVine` (rounded to 2 dp upstream),
    /// `yieldKg = totalBunches × bunchWeightKg × damageFactor`.
    static func blockEstimate(_ inputs: BlockEstimateInputs) -> BlockEstimateOutput {
        let totalBunches = Double(inputs.totalVines) * inputs.averageBunchesPerVine
        let yieldKg = totalBunches * inputs.bunchWeightKg * inputs.damageFactor
        return BlockEstimateOutput(
            totalBunches: totalBunches,
            estimatedYieldKg: yieldKg,
            estimatedYieldTonnes: yieldKg / 1000.0
        )
    }
}
