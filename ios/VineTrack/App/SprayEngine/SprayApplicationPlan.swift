import Foundation

/// What kind of application this is — decides how treated area is resolved.
nonisolated enum SprayApplicationMode: String, Sendable, Codable {
    /// Whole-canopy application: treated area equals gross area.
    case wholeBlock = "whole_block"
    /// Banded/strip application: treated area comes from band width × row length.
    case banded
}

/// The regulator's rate, exactly as the label prints it.
///
/// # Why this travels separately from the product's stock unit
///
/// `150 g/100 L` is a fact about the label. `Kg` is a fact about the drum in
/// the shed. They are different statements about different things, and the
/// calculator was formatting the first using the second — rendering an
/// authoritative `150 g/100 L` as `150 Kg/100 L` on the product card, a
/// thousand-fold misstatement of a legal rate sitting directly above the
/// quantity an operator is about to measure out.
///
/// Carrying the label's own value and unit through the plan makes that
/// impossible: nothing downstream has to reconstruct the rate, so nothing
/// downstream can reconstruct it wrongly.
nonisolated struct SprayLabelRateDescriptor: Sendable, Hashable {
    /// The number as the label states it — 150, not 0.15.
    let value: Double
    /// The label's own unit — "g", not the store's "Kg".
    let unit: String
    let basis: SprayProductRateBasis

    var text: String {
        "\(SprayRateFormatter.format(value)) \(unit)\(basis.rateSuffix)"
    }
}

/// How a base-unit quantity is presented in the product's own stock unit.
///
/// The engine works entirely in base units (mL / g) so that a rate, a total and
/// a tank share can never mean different things by the same number. This is the
/// single conversion applied at the edge, for display only.
nonisolated struct SprayProductUnitDisplay: Sendable, Hashable {
    /// What the operator's inventory calls it: "Kg", "L", "g", "mL".
    let displayUnit: String
    /// Base units in one display unit — 1000 for Kg and L, 1 for g and mL.
    let baseUnitsPerDisplayUnit: Double

    static func base(_ unit: String) -> SprayProductUnitDisplay {
        SprayProductUnitDisplay(displayUnit: unit, baseUnitsPerDisplayUnit: 1)
    }

    func display(_ baseValue: Double) -> Double {
        guard baseUnitsPerDisplayUnit.isFinite, baseUnitsPerDisplayUnit > 0 else { return baseValue }
        return baseValue / baseUnitsPerDisplayUnit
    }
}

/// One product line fed into the plan.
///
/// `rate` is expressed in the product's BASE unit (mL or g) per its `basis`.
/// The engine is unit-agnostic: quantities come back in the SAME unit as `rate`,
/// and `unitDisplay` is what converts them for the screen.
nonisolated struct SprayProductLineInput: Sendable, Hashable {
    let productId: String
    let name: String
    let unit: String
    let basis: SprayProductRateBasis
    let rate: Double
    let costPerUnit: Double?
    /// The label rate behind `rate`, for display. `nil` for a line with no
    /// authoritative label rate — a legacy hand-entered product, say.
    let labelRate: SprayLabelRateDescriptor?
    /// How to render totals in the operator's stock unit.
    let unitDisplay: SprayProductUnitDisplay
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
        isAreaBasisExplicit: Bool = true,
        labelRate: SprayLabelRateDescriptor? = nil,
        unitDisplay: SprayProductUnitDisplay? = nil
    ) {
        self.productId = productId
        self.name = name
        self.unit = unit
        self.basis = basis
        self.rate = rate
        self.costPerUnit = costPerUnit
        self.isAreaBasisExplicit = isAreaBasisExplicit
        self.labelRate = labelRate
        // Defaults to "already in the display unit", so every existing caller
        // and every historical record replayed through the engine keeps its
        // exact current meaning.
        self.unitDisplay = unitDisplay ?? .base(unit)
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
    /// The label rate this line was calculated from, verbatim.
    let labelRate: SprayLabelRateDescriptor?
    /// How to present `totalQuantity` in the operator's stock unit.
    let unitDisplay: SprayProductUnitDisplay
    /// Gross hectares this job covered, so a DERIVED per-hectare equivalent can
    /// be shown without the screen doing its own arithmetic.
    let grossAreaHectares: Double?

    init(
        productId: String,
        name: String,
        unit: String,
        basis: SprayProductRateBasis,
        rate: Double,
        totalQuantity: Double?,
        quantityPerFullTank: Double?,
        quantityInLastTank: Double?,
        costPerUnit: Double?,
        basisInput: Double?,
        labelRate: SprayLabelRateDescriptor? = nil,
        unitDisplay: SprayProductUnitDisplay? = nil,
        grossAreaHectares: Double? = nil
    ) {
        self.productId = productId
        self.name = name
        self.unit = unit
        self.basis = basis
        self.rate = rate
        self.totalQuantity = totalQuantity
        self.quantityPerFullTank = quantityPerFullTank
        self.quantityInLastTank = quantityInLastTank
        self.costPerUnit = costPerUnit
        self.basisInput = basisInput
        self.labelRate = labelRate
        self.unitDisplay = unitDisplay ?? .base(unit)
        self.grossAreaHectares = grossAreaHectares
    }

    /// The job's product requirement expressed per gross hectare.
    ///
    /// DERIVED, always — it is `total ÷ hectares`, an operational convenience,
    /// and it is never a registered rate. A `150 g/100 L` label that works out
    /// to 1.07 Kg/ha is still registered at 150 g/100 L, and any screen showing
    /// this figure must say "derived" beside it.
    var derivedQuantityPerHectare: Double? {
        guard let total = totalQuantity,
              let hectares = grossAreaHectares,
              hectares.isFinite, hectares > 0 else { return nil }
        return total / hectares
    }

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
            // A label BAND is the common case here: the regulator printed
            // `150–200 g/100 L` and the point inside it is the operator's
            // decision, never VineTrack's. Saying "choose" rather than
            // "enter" is the difference between a prompt and an accusation.
            return "Choose the applied label rate for this product. Where the label "
                + "states a range, VineTrack will not pick a point inside it for you."
        case .grossAreaUnavailable:
            return "Select blocks with an area before this product can be calculated."
        case .treatedAreaUnavailable:
            return "Complete the band width and block geometry before this product can be calculated."
        case .carrierUnavailable:
            // Names the canopy explicitly. On the 100 m workflow the canopy IS
            // the dilute/runoff figure this product's per-100 L rate is
            // written against, and an operator sent to "Carrier Volume"
            // without being told what is missing there has been given the
            // room number but not the question.
            return "Set the canopy / runoff and the actual applied volume in Carrier "
                + "Volume before this product quantity can be calculated."
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

    /// Creates a persisted tank whose carrier rate and concentration come from
    /// this exact plan, preventing UI entry state from disagreeing with Review.
    func persistedTank(
        tankNumber: Int,
        waterVolume: Double,
        chemicals: [SprayChemical] = []
    ) -> SprayTank {
        SprayTank(
            tankNumber: tankNumber,
            waterVolume: waterVolume,
            sprayRatePerHa: carrier.litresPerHectare ?? 0,
            concentrationFactor: carrier.concentrationFactor,
            chemicals: chemicals
        )
    }

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
                basisInput: basisInput,
                labelRate: line.labelRate,
                unitDisplay: line.unitDisplay,
                grossAreaHectares: geometry.grossAreaHectares
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
