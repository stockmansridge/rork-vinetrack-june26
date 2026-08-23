import Foundation

/// The Calculation Reference shown in Review.
///
/// # Why this is engine-side and not a view
///
/// Its whole purpose is to let a human check the arithmetic on a device. A
/// reference that recomputed its own operands could agree with itself perfectly
/// while disagreeing with the spray that actually gets recorded — it would
/// verify nothing. So every number here is READ from the plan and the volume
/// decision; this type only chooses words and decimal places.
///
/// The one thing it computes is the tank concentration (`label rate × CF`),
/// which is a presentation of the concentration factor rather than a second
/// dosing path: the engine's product totals do not consult it.
nonisolated struct SprayCalculationReference: Sendable, Hashable {

    nonisolated struct Line: Sendable, Hashable, Identifiable {
        let id: String
        let label: String
        let value: String
        /// The working, when the value is worth showing the arithmetic for.
        var workings: String?
    }

    nonisolated struct ProductReference: Sendable, Hashable, Identifiable {
        let id: String
        let name: String
        let lines: [Line]
    }

    let canopy: [Line]
    let volume: [Line]
    let water: [Line]
    let products: [ProductReference]

    var isEmpty: Bool {
        canopy.isEmpty && volume.isEmpty && water.isEmpty && products.isEmpty
    }
}

nonisolated enum SprayCalculationReferenceBuilder {

    // MARK: - Formatting

    private static func number(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = decimals
        formatter.minimumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Trims trailing zeros — `2.8`, not `2.80`.
    private static func trim(_ value: Double, maxDecimals: Int = 4) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = maxDecimals
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Build

    static func make(flow: SprayGuidedFlow) -> SprayCalculationReference {
        let plan = flow.plan
        let decision = flow.volumeDecision
        return SprayCalculationReference(
            canopy: canopyLines(decision: decision),
            volume: volumeLines(decision: decision),
            water: waterLines(plan: plan, decision: decision),
            products: productLines(plan: plan, decision: decision)
        )
    }

    private static func canopyLines(decision: SprayVolumeDecision?) -> [SprayCalculationReference.Line] {
        guard let recommendation = decision?.recommendation else { return [] }
        var lines: [SprayCalculationReference.Line] = [
            .init(id: "canopyType", label: "Canopy type", value: recommendation.type.rawValue),
            .init(
                id: "canopySize",
                label: "Canopy size",
                value: recommendation.size.rawValue,
                workings: recommendation.size.description(for: recommendation.type)
            ),
            .init(id: "canopyDensity", label: "Canopy density", value: recommendation.density.rawValue),
            .init(
                id: "recommendedPer100m",
                label: "Recommended dilute volume",
                value: "\(trim(recommendation.diluteLitresPer100Metres)) L/100 m"
            )
        ]
        if let spacing = recommendation.rowSpacingMetres {
            lines.append(.init(
                id: "rowSpacing",
                label: "Row spacing",
                value: "\(trim(spacing)) m"
            ))
        }
        if let perHectare = recommendation.diluteLitresPerHectare,
           let spacing = recommendation.rowSpacingMetres {
            lines.append(.init(
                id: "recommendedPerHa",
                label: "Recommended per area",
                value: "\(number(perHectare, decimals: 1)) L/ha",
                workings: "\(trim(recommendation.diluteLitresPer100Metres)) L/100 m × 100 ÷ "
                    + "\(trim(spacing)) m"
            ))
        } else {
            lines.append(.init(
                id: "recommendedPerHa",
                label: "Recommended per area",
                value: "—",
                workings: "Needs one matching row spacing across the selected blocks"
            ))
        }
        return lines
    }

    private static func volumeLines(decision: SprayVolumeDecision?) -> [SprayCalculationReference.Line] {
        guard let decision, decision.recommendation != nil else { return [] }
        let selection: String
        switch decision.choice {
        case .undecided: selection = "Not chosen yet"
        case .useRecommended: selection = "Use recommended"
        case .useCustomSprayerRate: selection = "Different sprayer rate"
        }
        var lines: [SprayCalculationReference.Line] = [
            .init(id: "sprayerSelection", label: "Sprayer selection", value: selection)
        ]
        if let actual = decision.actualLitresPerHectare {
            lines.append(.init(
                id: "actualOutput",
                label: "Actual sprayer output",
                value: "\(number(actual, decimals: 1)) L/ha"
            ))
        }
        if let recommended = decision.recommendedLitresPerHectare,
           let actual = decision.actualLitresPerHectare {
            lines.append(.init(
                id: "concentrationFactor",
                label: "Concentration factor",
                value: "\(number(decision.concentrationFactor, decimals: 2))×",
                workings: "max(1.00, \(number(recommended, decimals: 1)) ÷ "
                    + "\(number(actual, decimals: 1)))"
            ))
        }
        return lines
    }

    private static func waterLines(
        plan: SprayApplicationPlan,
        decision: SprayVolumeDecision?
    ) -> [SprayCalculationReference.Line] {
        let carrier = plan.carrier
        var lines: [SprayCalculationReference.Line] = []
        let treated = plan.treatedAreaHectares ?? plan.grossAreaHectares

        // Manual reverses the direction of every derivation on this panel, so
        // it cannot share the calibrated branch below. There the total is the
        // RESULT of `rate x area`; here the total is the INPUT and the rate is
        // what falls out of it. Printing "6.7 L/ha x 0.6 ha" underneath a total
        // the operator typed would show them a derivation that never happened,
        // and invite them to trust a per-hectare figure as though VineTrack had
        // calibrated it.
        if carrier.basis == .manualTotalVolume {
            lines.append(.init(
                id: "totalWater",
                label: "Total water",
                value: "\(number(carrier.totalLitres, decimals: 0)) L",
                workings: "Entered directly — not calculated from a rate or an area"
            ))
            if treated > 0 {
                lines.append(.init(
                    id: "treatedArea",
                    label: "Treated area",
                    value: "\(number(treated, decimals: 2)) ha",
                    workings: plan.treatedAreaHectares == nil
                        ? "Whole block area"
                        : "Treated band area"
                ))
            }
            if let perHectare = carrier.litresPerHectare, perHectare > 0, treated > 0 {
                lines.append(.init(
                    id: "impliedPerHa",
                    label: "Works out to",
                    value: "\(number(perHectare, decimals: 1)) L/ha",
                    workings: "\(number(carrier.totalLitres, decimals: 0)) L ÷ "
                        + "\(number(treated, decimals: 2)) ha — for reference only"
                ))
            }
            if let per100m = carrier.appliedLitresPer100Metres,
               let metres = carrier.rowLengthMetres, metres > 0 {
                lines.append(.init(
                    id: "impliedPer100m",
                    label: "Works out to",
                    value: "\(number(per100m, decimals: 1)) L/100 m",
                    workings: "\(number(carrier.totalLitres, decimals: 0)) L ÷ "
                        + "\(number(metres, decimals: 0)) m × 100 — for reference only"
                ))
            }
            return lines
        }

        lines.append(.init(
            id: "treatedArea",
            label: "Treated area",
            value: "\(number(treated, decimals: 2)) ha",
            workings: plan.treatedAreaHectares == nil ? "Whole block area" : "Treated band area"
        ))
        if let perHectare = carrier.litresPerHectare, perHectare > 0, treated > 0 {
            lines.append(.init(
                id: "totalWater",
                label: "Total water",
                value: "\(number(carrier.totalLitres, decimals: 0)) L",
                workings: "\(number(perHectare, decimals: 1)) L/ha × "
                    + "\(number(treated, decimals: 2)) ha"
            ))
        } else {
            lines.append(.init(
                id: "totalWater",
                label: "Total water",
                value: "\(number(carrier.totalLitres, decimals: 0)) L"
            ))
        }
        return lines
    }

    private static func productLines(
        plan: SprayApplicationPlan,
        decision: SprayVolumeDecision?
    ) -> [SprayCalculationReference.ProductReference] {
        let factor = plan.carrier.concentrationFactor
        let isManualVolume = plan.carrier.basis == .manualTotalVolume
        return plan.productLines.map { line in
            var lines: [SprayCalculationReference.Line] = []
            if let labelRate = line.labelRate {
                lines.append(.init(
                    id: "labelRate",
                    label: "Registered label rate",
                    value: labelRate.text
                ))
            }
            switch line.basis {
            case .per100Litres:
                if isManualVolume {
                    // "1.00x" is arithmetically true here, but it reads as a
                    // FINDING — as though a canopy comparison had been run and
                    // come back neutral. Nothing was compared. Naming that is
                    // the difference between a reference panel that explains
                    // the job and one that quietly invents a step.
                    lines.append(.init(
                        id: "cf",
                        label: "Concentration factor",
                        value: "Not used",
                        workings: "Manual spray volume isn't compared to a canopy "
                            + "recommendation, so there is nothing to concentrate"
                    ))
                } else {
                    lines.append(.init(
                        id: "cf",
                        label: "Concentration factor",
                        value: "\(number(factor, decimals: 2))×"
                    ))
                    if let labelRate = line.labelRate {
                        // Presentation of the CF, not a second dosing path — the
                        // engine's total below does not read this figure.
                        let concentrated = labelRate.value * factor
                        lines.append(.init(
                            id: "tankConcentration",
                            label: "Tank concentration",
                            value: "\(number(concentrated, decimals: 2)) \(labelRate.unit)/100 L",
                            workings: "\(trim(labelRate.value)) × \(number(factor, decimals: 2))"
                        ))
                    }
                }
                if let basisInput = line.basisInput {
                    lines.append(.init(
                        id: "carrier",
                        label: "Carrier volume",
                        value: "\(number(basisInput, decimals: 0)) L"
                    ))
                }
            case .wholeBlockArea, .treatedArea, .per100Metres:
                if let basisInput = line.basisInput {
                    let unit = line.basis.measuredUnit
                    lines.append(.init(
                        id: "measured",
                        label: "Measured against",
                        value: "\(number(basisInput, decimals: unit == "ha" ? 2 : 0)) \(unit) "
                            + line.basis.measuredNoun
                    ))
                }
                lines.append(.init(
                    id: "cfNotApplied",
                    label: "Concentration factor",
                    value: "Not applied",
                    workings: "A registered per-area rate is measured against area, "
                        + "never against carrier volume"
                ))
            }
            if let total = line.totalQuantity {
                let display = line.unitDisplay.display(total)
                let decimals: Int = display < 10 ? 3 : (display < 100 ? 2 : 0)
                var workings: String?
                if line.basis == .per100Litres, let basisInput = line.basisInput,
                   let labelRate = line.labelRate {
                    workings = "\(trim(labelRate.value)) × \(number(basisInput, decimals: 0)) ÷ 100"
                        + (factor > 1.0 ? " × \(number(factor, decimals: 2))" : "")
                } else if let basisInput = line.basisInput, let labelRate = line.labelRate {
                    workings = "\(trim(labelRate.value)) × "
                        + "\(number(basisInput, decimals: 2)) \(line.basis.measuredUnit)"
                }
                lines.append(.init(
                    id: "total",
                    label: "Product required",
                    value: "\(number(display, decimals: decimals)) \(line.unitDisplay.displayUnit)",
                    workings: workings
                ))
            } else if let reason = line.unresolvedReason {
                lines.append(.init(
                    id: "total",
                    label: "Product required",
                    value: reason.title
                ))
            }
            return SprayCalculationReference.ProductReference(
                id: line.productId,
                name: line.name,
                lines: lines
            )
        }
    }
}
