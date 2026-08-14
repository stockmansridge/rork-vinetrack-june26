import Foundation

/// What kind of application this is — decides how treated area is resolved.
nonisolated enum SprayApplicationMode: String, Sendable, Codable {
    /// Whole-canopy application: treated area equals gross area.
    case wholeBlock = "whole_block"
    /// Banded/strip application: treated area comes from band width × row length.
    case banded
}

/// One product line fed into the plan.
///
/// `rate` is expressed in the product's own unit (L, mL, kg, g) per its `basis`.
/// The engine is unit-agnostic: quantities come back in the SAME unit as `rate`.
nonisolated struct SprayProductLineInput: Sendable, Hashable {
    let productId: String
    let name: String
    let unit: String
    let basis: SprayProductRateBasis
    let rate: Double
    let costPerUnit: Double?

    init(
        productId: String,
        name: String,
        unit: String,
        basis: SprayProductRateBasis,
        rate: Double,
        costPerUnit: Double? = nil
    ) {
        self.productId = productId
        self.name = name
        self.unit = unit
        self.basis = basis
        self.rate = rate
        self.costPerUnit = costPerUnit
    }
}

/// A calculated product line.
nonisolated struct SprayProductLineResult: Sendable, Hashable {
    let productId: String
    let name: String
    let unit: String
    let basis: SprayProductRateBasis
    let rate: Double
    /// Total product for the whole job, in `unit`. `nil` when the basis's input
    /// was unavailable (e.g. a treated-area product with no band width).
    let totalQuantity: Double?
    let quantityPerFullTank: Double?
    let quantityInLastTank: Double?
    let costPerUnit: Double?

    var totalCost: Double? {
        guard let total = totalQuantity, let cost = costPerUnit, cost > 0 else { return nil }
        return total * cost
    }

    /// True when this line could not be calculated and must be surfaced to the
    /// operator rather than silently omitted from the mix.
    var isUnresolved: Bool { totalQuantity == nil }
}

/// How the carrier volume splits into tanks.
nonisolated struct SprayTankSplit: Sendable, Hashable {
    let tankCapacityLitres: Double
    let fullTankCount: Int
    let lastTankLitres: Double

    var totalTanks: Int { fullTankCount + (lastTankLitres > 0 ? 1 : 0) }
}

/// THE end-to-end spray calculation result.
///
/// Pipeline, in order, each stage feeding the next:
///
/// ```text
/// Row geometry → Application geometry → Carrier volume → Product quantities → Tank splits
/// ```
///
/// Gross and treated hectares are BOTH retained; treated area never replaces
/// gross. The banded treated-area calculation and the L/100 m carrier volume
/// read the SAME `geometry.totalRowLengthMetres`, so they cannot disagree.
nonisolated struct SprayApplicationPlan: Sendable {
    let mode: SprayApplicationMode
    let geometry: SprayApplicationGeometry
    let treatedArea: SprayTreatedArea
    let carrier: SprayCarrierVolume
    let tankSplit: SprayTankSplit
    let productLines: [SprayProductLineResult]

    var grossAreaHectares: Double { treatedArea.grossAreaHectares }
    var treatedAreaHectares: Double? { treatedArea.treatedAreaHectares }
    var totalCarrierLitres: Double { carrier.totalLitres }
    var concentrationFactor: Double { carrier.concentrationFactor }

    /// Product lines that could not be calculated.
    var unresolvedProductLines: [SprayProductLineResult] { productLines.filter(\.isUnresolved) }

    var totalProductCost: Double? {
        let costs = productLines.compactMap(\.totalCost)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    /// Cost per GROSS hectare — the basis every existing report uses.
    var costPerGrossHectare: Double? {
        guard let total = totalProductCost, grossAreaHectares > 0 else { return nil }
        return total / grossAreaHectares
    }

    /// Cost per TREATED hectare — only meaningful for banded jobs.
    var costPerTreatedHectare: Double? {
        guard let total = totalProductCost, let treated = treatedAreaHectares, treated > 0 else { return nil }
        return total / treated
    }
}

nonisolated enum SprayApplicationPlanner {

    /// Splits a carrier volume into tanks.
    ///
    /// Arithmetic preserved EXACTLY from the existing `SprayCalculator` so tank
    /// counts and per-tank volumes on current jobs cannot shift.
    static func tankSplit(totalLitres: Double, tankCapacityLitres: Double) -> SprayTankSplit {
        guard totalLitres > 0, tankCapacityLitres > 0 else {
            return SprayTankSplit(tankCapacityLitres: tankCapacityLitres, fullTankCount: 0, lastTankLitres: 0)
        }
        let numberOfTanks = Int(ceil(totalLitres / tankCapacityLitres))
        let fullTankCount = totalLitres > tankCapacityLitres ? numberOfTanks - 1 : 0
        let lastTankLitres = totalLitres <= tankCapacityLitres
            ? totalLitres
            : totalLitres - (Double(fullTankCount) * tankCapacityLitres)
        return SprayTankSplit(
            tankCapacityLitres: tankCapacityLitres,
            fullTankCount: fullTankCount,
            lastTankLitres: lastTankLitres
        )
    }

    /// Builds the full plan.
    ///
    /// - Parameters:
    ///   - blocks: the selected blocks' raw geometry inputs.
    ///   - mode: whole-block or banded.
    ///   - bandWidth: required for `.banded`; ignored otherwise.
    ///   - carrier: a resolved carrier volume (built via
    ///     `SprayCarrierVolumeCalculator`). Passed in rather than derived so the
    ///     caller controls whether L/ha or L/100 m applies.
    static func plan(
        blocks: [SprayBlockInput],
        mode: SprayApplicationMode,
        bandWidth: SprayBandWidth? = nil,
        carrier: SprayCarrierVolume,
        tankCapacityLitres: Double,
        productLines: [SprayProductLineInput]
    ) -> SprayApplicationPlan {
        let geometry = SprayGeometryResolver.resolve(blocks)

        let treated: SprayTreatedArea = {
            switch mode {
            case .wholeBlock:
                return SprayBandedAreaCalculator.wholeBlock(geometry: geometry)
            case .banded:
                guard let bandWidth else {
                    return SprayTreatedArea(
                        grossAreaHectares: geometry.grossAreaHectares,
                        treatedAreaHectares: nil,
                        method: .unavailable,
                        bandWidth: nil,
                        rowLengthMetres: geometry.totalRowLengthMetres
                    )
                }
                return SprayBandedAreaCalculator.banded(geometry: geometry, bandWidth: bandWidth)
            }
        }()

        let context = SprayQuantityContext(
            geometry: geometry,
            carrier: carrier,
            treatedAreaHectares: treated.treatedAreaHectares
        )
        let split = tankSplit(totalLitres: carrier.totalLitres, tankCapacityLitres: tankCapacityLitres)

        let lines = productLines.map { line -> SprayProductLineResult in
            let total = SprayProductQuantityCalculator.totalQuantity(
                rate: line.rate,
                basis: line.basis,
                context: context
            )
            let perFullTank: Double?
            let inLastTank: Double?
            if let total, carrier.totalLitres > 0, split.totalTanks > 0 {
                perFullTank = total * (split.tankCapacityLitres / carrier.totalLitres)
                inLastTank = split.lastTankLitres > 0
                    ? total * (split.lastTankLitres / carrier.totalLitres)
                    : (split.totalTanks == 1 ? total : 0)
            } else {
                perFullTank = total == nil ? nil : 0
                inLastTank = total == nil ? nil : 0
            }
            return SprayProductLineResult(
                productId: line.productId,
                name: line.name,
                unit: line.unit,
                basis: line.basis,
                rate: line.rate,
                totalQuantity: total,
                quantityPerFullTank: perFullTank,
                quantityInLastTank: inLastTank,
                costPerUnit: line.costPerUnit
            )
        }

        return SprayApplicationPlan(
            mode: mode,
            geometry: geometry,
            treatedArea: treated,
            carrier: carrier,
            tankSplit: split,
            productLines: lines
        )
    }
}
