import Foundation

/// Declared machine pass, independent of physical vineyard row spacing.
nonisolated enum SprayPassConfiguration: String, Codable, Sendable, CaseIterable {
    case standardPass = "standard_pass"
    case overRow = "over_row_two_rows"
    var title: String { self == .standardPass ? "Single Row" : "Over-Row" }
    var rowEquivalents: Double { self == .standardPass ? 1 : 2 }
}

nonisolated enum SprayPlanningMethod: String, Codable, Sendable, CaseIterable {
    case byArea = "by_area"
    case fullTank = "full_tank"
    var title: String { self == .byArea ? "By Area" : "Only Full Tanks" }
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
    var inputProvenance: SprayPlanningInputProvenance? = nil

    /// Full-Tank execution validation only. Historical records and non-executable drafts do not call this.
    func fullTankExecutionBlocker(resolution: SprayPlanningResolution?, selectedGrossAreaHa: Double?) -> String? {
        guard method == .fullTank else { return nil }
        let message = "Only Full Tanks plan is incomplete or inconsistent. Recalculate before saving or starting."
        guard let configuration, let tank = intendedTankLitres, tank.isFinite, tank > 0,
              let resolution, let gross = selectedGrossAreaHa, gross.isFinite, gross > 0 else { return message }
        func matches(_ a: Double, _ b: Double) -> Bool {
            a.isFinite && b.isFinite && abs(a - b) <= max(0.000001, max(abs(a), abs(b)) * 0.00000001)
        }
        guard resolution.plannedAreaHa.isFinite, resolution.plannedAreaHa > 0,
              resolution.plannedAreaHa <= gross + max(0.000001, gross * 0.00000001),
              resolution.litresPerHectare.isFinite, resolution.litresPerHectare > 0,
              matches(tank, resolution.intendedLitres),
              matches(tank, resolution.plannedAreaHa * resolution.litresPerHectare) else { return message }
        switch fullTankSpecification {
        case .targetArea:
            guard let targetAreaHa, targetAreaHa > 0, matches(targetAreaHa, resolution.plannedAreaHa) else { return message }
        case .calibratedRate:
            guard let calibratedLitresPerHectare, calibratedLitresPerHectare > 0,
                  matches(calibratedLitresPerHectare, resolution.litresPerHectare) else { return message }
        case nil: return message
        }
        if let physical = resolution.physicalRowLitresPer100m, let travel = resolution.controllerLitresPer100mTravel,
           !matches(travel, physical * configuration.rowEquivalents) { return message }
        return nil
    }

    /// Checks frozen outputs without recalculating quantities or granting operational authority.
    func frozenResolutionBlocker(_ resolution: SprayPlanningResolution) -> String? {
        let message = "Spray planning outputs are incomplete or inconsistent. Recalculate before saving or starting."
        guard let configuration, method != nil,
              [resolution.intendedLitres, resolution.plannedAreaHa, resolution.litresPerHectare].allSatisfy({ $0.isFinite && $0 > 0 }),
              resolution.concentrationFactor.isFinite, resolution.concentrationFactor >= 1 else { return message }
        let geometry = [resolution.physicalRowLitresPer100m, resolution.controllerLitresPer100mTravel, resolution.effectiveWorkingWidthMetres]
        if geometry.contains(where: { $0 != nil }) && !geometry.allSatisfy({ $0.map { $0.isFinite && $0 > 0 } ?? false }) { return message }
        func matches(_ a: Double, _ b: Double) -> Bool {
            a.isFinite && b.isFinite && abs(a - b) <= max(0.000001, max(abs(a), abs(b)) * 0.00000001)
        }
        if let physical = resolution.physicalRowLitresPer100m,
           let travel = resolution.controllerLitresPer100mTravel, let width = resolution.effectiveWorkingWidthMetres,
           (!matches(travel, physical * configuration.rowEquivalents) || !matches(travel, resolution.litresPerHectare * width / 100)) { return message }
        // By Area may retain measured-row carrier totals; do not substitute gross-area arithmetic.
        return nil
    }

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

/// Original display-unit inputs are retained separately from canonical numeric quantities.
nonisolated struct SprayPlanningInputProvenance: Codable, Sendable, Hashable {
    let tankText: String
    let areaText: String
    let rateText: String
    let volumeUnit: String
    let areaUnit: String
    let rateAreaUnit: String
    let countryCode: String
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
    static let concentrateMessage = "The concentration factor must be finite and at least 1.00. Recalculate before saving or starting."
    static let warningTitle = "Concentration / Label Warning"
    static let warningMessage = "VineTrack has calculated the chemical concentration factor (CF), but concentrate-spraying permission and applicable limits have not been verified against the product label.\n\nA calculated CF does not confirm label approval. Check the relevant product labels and application directions before spraying."

    /// Advisory only; never feeds operational readiness or durable write admission.
    static func warningProducts(_ names: [String]) -> [String] {
        Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
    /// Evaluate each chemical against its own tank, not the maximum CF of unrelated tanks.
    static func tankComplianceBlocker(_ tanks: [SprayTank]) -> String? {
        for tank in tanks {
            let ambiguous = tank.chemicals.filter { $0.rateBasis == nil && $0.ratePer100L > 0 && $0.ratePerHa > 0 }
            if !ambiguous.isEmpty {
                return "Choose an explicit rate basis before saving or starting. Ambiguous rate basis: " + ambiguous.map(\.name).joined(separator: ", ")
            }
            let dilute = tank.chemicals.filter { $0.rateBasis == .per100Litres || ($0.rateBasis == nil && $0.ratePer100L > 0) }
            if let message = blocker(hasPlanningIntent: false, concentrationFactor: tank.concentrationFactor,
                hasDiluteRateProducts: !dilute.isEmpty, chemicalNames: dilute.map(\.name)) { return message }
        }
        return nil
    }

    static func blocker(hasPlanningIntent: Bool, concentrationFactor: Double?, hasDiluteRateProducts: Bool, chemicalNames: [String] = []) -> String? {
        if hasDiluteRateProducts {
            let factorIsSafe = concentrationFactor.map { $0.isFinite && $0 >= 1 } ?? false
            if !factorIsSafe {
                let names = Array(Set(chemicalNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                return names.isEmpty ? concentrateMessage : concentrateMessage + " Products: " + names.joined(separator: ", ")
            }
        }
        return hasPlanningIntent ? migrationMessage : nil
    }
}
