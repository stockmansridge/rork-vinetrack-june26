import Foundation

/// Declared machine pass, independent of physical vineyard row spacing.
nonisolated enum SprayPassConfiguration: String, Codable, Sendable, CaseIterable {
    case standardPass = "standard_pass"
    case overRow = "over_row_two_rows"
    var title: String { self == .standardPass ? "Standard Pass" : "Over-Row" }
    var rowEquivalents: Double { self == .standardPass ? 1 : 2 }
}

nonisolated enum SprayPlanningMethod: String, Codable, Sendable, CaseIterable {
    case byArea = "by_area"
    case fullTank = "full_tank"
    var title: String { self == .byArea ? "By Area" : "Full Tank" }
}

nonisolated enum SprayFullTankSpecification: String, Codable, Sendable, CaseIterable {
    case targetArea = "target_area"
    case calibratedRate = "calibrated_rate"
    var title: String { self == .targetArea ? "Target area" : "Calibrated rate" }
}

/// Local, nullable provenance. No server writer is activated by this model.
nonisolated struct SprayPlanningIntent: Codable, Sendable, Hashable {
    var configuration: SprayPassConfiguration?
    var method: SprayPlanningMethod?
    var fullTankSpecification: SprayFullTankSpecification?
    var intendedTankLitres: Double?
    var targetAreaHa: Double?
    var calibratedLitresPerHectare: Double?

    func resolve(selectedAreaHa: Double, physicalRowSpacingMetres: Double?, diluteLitresPerHectare: Double?) -> SprayPlanningResolution? {
        guard let configuration, let method, selectedAreaHa.isFinite, selectedAreaHa > 0 else { return nil }
        let litres: Double
        let area: Double
        let rate: Double
        if method == .fullTank {
            guard let tank = intendedTankLitres, tank.isFinite, tank > 0 else { return nil }
            litres = tank
            switch fullTankSpecification {
            case .targetArea:
                guard let target = targetAreaHa, target.isFinite, target > 0, target <= selectedAreaHa else { return nil }
                area = target
                rate = tank / target
            case .calibratedRate:
                guard let calibrated = calibratedLitresPerHectare, calibrated.isFinite, calibrated > 0 else { return nil }
                rate = calibrated
                area = tank / calibrated
                guard area <= selectedAreaHa else { return nil }
            case nil: return nil
            }
        } else {
            guard let calibrated = calibratedLitresPerHectare, calibrated.isFinite, calibrated > 0 else { return nil }
            area = selectedAreaHa
            rate = calibrated
            litres = area * rate
        }
        guard litres.isFinite, area.isFinite, rate.isFinite else { return nil }
        let spacing = physicalRowSpacingMetres.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let physicalRowRate = spacing.map { rate * $0 / 100 }
        return SprayPlanningResolution(
            intendedLitres: litres, plannedAreaHa: area, litresPerHectare: rate,
            physicalRowLitresPer100m: physicalRowRate,
            controllerLitresPer100mTravel: physicalRowRate.map { $0 * configuration.rowEquivalents },
            effectiveWorkingWidthMetres: spacing.map { $0 * configuration.rowEquivalents },
            concentrationFactor: SprayCarrierConversion.concentrationFactor(dilute: diluteLitresPerHectare, actual: rate)
        )
    }
}

nonisolated struct SprayPlanningResolution: Codable, Sendable, Hashable {
    let intendedLitres: Double
    let plannedAreaHa: Double
    let litresPerHectare: Double
    let physicalRowLitresPer100m: Double?
    let controllerLitresPer100mTravel: Double?
    let effectiveWorkingWidthMetres: Double?
    let concentrationFactor: Double
}

/// No mutable capability flag: activation requires a separately reviewed integration.
nonisolated enum SprayPlanningOperationalGate {
    static let migrationMessage = "Calculation preview only. New spray planning save/start and replay are disabled until the schema and operational workflows are approved and validated."
    static let concentrateMessage = "Concentrate spraying permission and limits are unverified for this dilute-rate mix. Save/start is blocked. A displayed CF is not label approval."
    static func blocker(hasPlanningIntent: Bool, concentrationFactor: Double?, hasDiluteRateProducts: Bool) -> String? {
        if hasDiluteRateProducts, let factor = concentrationFactor, !factor.isFinite || factor > 1.000001 { return concentrateMessage }
        return hasPlanningIntent ? migrationMessage : nil
    }
}
