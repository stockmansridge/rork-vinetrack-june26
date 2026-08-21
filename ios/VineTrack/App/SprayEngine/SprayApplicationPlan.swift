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
    /// Whether the operator has EXPLICITLY chosen this line's area basis.
    ///
    /// Only meaningful for area-rated lines on a banded pass, where whole-block
    /// and treated-band hectares differ by several times. `false` means "the
    /// screen is showing a default nobody has confirmed", which the flow blocks
    /// on rather than freezing a guess into a compliance record.
    ///
    /// Defaults to `true` so every legacy caller — and every historical record
    /// replayed through the engine — keeps its existing meaning untouched.
    let isAreaBasisExplicit: Bool

    init(
        productId: String,
        name: String,
        unit: String,
        basis: SprayProductRateBasis,
        rate: Double,
        costPerUnit: Double? = nil,
        isAreaBasisExplicit: Bool = true
    ) {
        self.productId = productId
        self.name = name
        self.unit = unit
        self.basis = basis
        self.rate = rate
        self.costPerUnit = costPerUnit
        self.isAreaBasisExplicit = isAreaBasisExplicit
    }

    /// True when this line still needs the operator to answer the Whole Block vs
    /// Treated Band question.
    ///
    /// A per-100 L line is never ambiguous: its basis comes from the product's
    /// own label, not from how the block was covered.
    var needsAreaBasisDecision: Bool {
        basis.isAreaBased && !isAreaBasisExplicit
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
    /// The MEASURED value this line's rate was multiplied against — gross
    /// hectares, treated hectares, carrier litres or row metres, depending on
    /// `basis`.
    ///
    /// Carried out of the planner so the UI can explain a quantity
    /// ("2 L/ha × 10.00 ha whole block") without recomputing anything. A screen
    /// that reached for its own hectares here could show a sum that no longer
    /// matches the persisted record. `nil` when the input was unavailable, which
    /// is exactly when `totalQuantity` is `nil` too.
    let basisInput: Double?

    var totalCost: Double? {
        guard let total = totalQuantity, let cost = costPerUnit, cost > 0 else { return nil }
        return total * cost
    }

    /// True when this line could not be calculated and must be surfaced to the
    /// operator rather than silently omitted from the mix.
    var isUnresolved: Bool { totalQuantity == nil }

    /// Why this line cannot be calculated, as the ONE input that is missing.
    ///
    /// Distinguishing these matters: a treated-area product needs band geometry,
    /// while a per-100 L product needs the carrier step — telling an operator to
    /// fix the wrong one wastes a spray window.
    var unresolvedReason: SprayProductUnresolvedReason? {
        guard isUnresolved else { return nil }
        // The rate is checked first: when the product itself has no rate, no
        // amount of block or carrier geometry will fix the line, and pointing
        // the operator at their block setup would send them to the wrong screen.
        guard rate.isFinite, rate > 0 else { return .rateUnavailable }
        switch basis {
        case .wholeBlockArea: return .grossAreaUnavailable
        case .treatedArea: return .treatedAreaUnavailable
        case .per100Litres: return .carrierUnavailable
        case .per100Metres: return .rowLengthUnavailable
        }
    }
}

/// The single missing input behind an unresolved product line.
nonisolated enum SprayProductUnresolvedReason: Sendable, Hashable {
    case grossAreaUnavailable
    case treatedAreaUnavailable
    case carrierUnavailable
    case rowLengthUnavailable
    /// The product line carries no usable rate. Distinct from every other case
    /// here: the missing input belongs to the PRODUCT, not the block geometry
    /// or the carrier step.
    case rateUnavailable

    var title: String {
        switch self {
        case .grossAreaUnavailable: return "Block area required"
        case .treatedAreaUnavailable: return "Treated area unavailable"
        case .carrierUnavailable: return "Carrier volume required"
        case .rowLengthUnavailable: return "Row length unavailable"
        case .rateUnavailable: return "Product rate required"
        }
    }

    var message: String {
        switch self {
        case .rateUnavailable:
            return "Enter the label rate for this product. VineTrack does not apply a "
                + "product at an assumed rate."
        case .grossAreaUnavailable:
            return "Select blocks with an area before this product can be calculated."
        case .treatedAreaUnavailable:
            return "Complete the band width and block geometry before this product can be calculated."
        case .carrierUnavailable:
            return "Complete the Carrier Volume step before this product quantity can be calculated."
        case .rowLengthUnavailable:
            return "Complete the block row geometry before this product can be calculated."
        }
    }
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
            let basisInput = SprayProductQuantityCalculator.basisInput(
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
                costPerUnit: line.costPerUnit,
                basisInput: basisInput
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
