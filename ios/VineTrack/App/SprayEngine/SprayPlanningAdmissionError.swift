import Foundation

nonisolated struct SprayPlanningAdmissionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SprayRecord {
    nonisolated var operationalPlanningBlocker: String? {
        if !isTemplate, let geometry = applicationGeometry, let intent = geometry.planningIntent,
           geometry.planningResolution != nil,
           let blocker = intent.fullTankExecutionBlocker(resolution: geometry.planningResolution, selectedGrossAreaHa: geometry.grossAreaHa) { return blocker }
        return SprayPlanningOperationalGate.blocker(
            hasPlanningIntent: applicationGeometry?.planningIntent != nil || applicationGeometry?.planningResolution != nil,
            concentrationFactor: tanks.first(where: { !$0.concentrationFactor.isFinite })?.concentrationFactor
                ?? (tanks.map(\.concentrationFactor) + [applicationGeometry?.concentrationFactor].compactMap { $0 }).max(),
            hasDiluteRateProducts: tanks.contains { $0.chemicals.contains { $0.reportedRateBasis == .per100Litres } },
            chemicalNames: tanks.flatMap(\.chemicals).filter { $0.reportedRateBasis == .per100Litres }.map(\.name))
    }
}

extension BackendSprayRecordUpsert {
    nonisolated var operationalPlanningBlocker: String? {
        if !isTemplate, let intent = planningIntent, intent.method == .fullTank,
           let area = plannedApplicationAreaHa, let litres = totalCarrierLitres, let rate = carrierLitresPerHectare,
           let factor = concentrationFactor {
            let resolution = SprayPlanningResolution(intendedLitres: litres, plannedAreaHa: area, litresPerHectare: rate,
                physicalRowLitresPer100m: appliedLitresPer100m, controllerLitresPer100mTravel: controllerLitresPer100mTravel,
                effectiveWorkingWidthMetres: effectiveWorkingWidthMetres, concentrationFactor: factor)
            if let blocker = intent.fullTankExecutionBlocker(resolution: resolution, selectedGrossAreaHa: grossAreaHa) { return blocker }
        }
        return SprayPlanningOperationalGate.blocker(
            hasPlanningIntent: planningIntent != nil || sprayerConfiguration != nil || sprayPlanningMethod != nil ||
                plannedApplicationAreaHa != nil || planningTankCapacityLitres != nil || controllerLitresPer100mTravel != nil ||
                effectiveWorkingWidthMetres != nil || fullTankSpecification != nil || planningCalibratedLitresPerHectare != nil,
            concentrationFactor: tanks.first(where: { !$0.concentrationFactor.isFinite })?.concentrationFactor
                ?? (tanks.map(\.concentrationFactor) + [concentrationFactor].compactMap { $0 }).max(),
            hasDiluteRateProducts: tanks.contains { $0.chemicals.contains { $0.reportedRateBasis == .per100Litres } },
            chemicalNames: tanks.flatMap(\.chemicals).filter { $0.reportedRateBasis == .per100Litres }.map(\.name))
    }
}
