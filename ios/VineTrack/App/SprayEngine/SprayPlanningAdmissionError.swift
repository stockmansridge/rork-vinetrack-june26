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
        if let blocker = SprayPlanningOperationalGate.tankComplianceBlocker(tanks) { return blocker }
        return SprayPlanningOperationalGate.blocker(
            hasPlanningIntent: applicationGeometry?.planningIntent != nil || applicationGeometry?.planningResolution != nil,
            concentrationFactor: nil, hasDiluteRateProducts: false)
    }
}

extension BackendSprayRecordUpsert {
    nonisolated var operationalPlanningBlocker: String? {
        if !isTemplate, let intent = planningIntent, intent.method == .fullTank,
           let area = plannedApplicationAreaHa, let litres = resolvedPlanningCarrierLitres, let rate = resolvedPlanningLitresPerHectare,
           let factor = resolvedPlanningConcentrationFactor {
            let resolution = SprayPlanningResolution(intendedLitres: litres, plannedAreaHa: area, litresPerHectare: rate,
                physicalRowLitresPer100m: resolvedPlanningPhysicalRowLitresPer100m, controllerLitresPer100mTravel: controllerLitresPer100mTravel,
                effectiveWorkingWidthMetres: effectiveWorkingWidthMetres, concentrationFactor: factor)
            if let blocker = intent.fullTankExecutionBlocker(resolution: resolution, selectedGrossAreaHa: grossAreaHa) { return blocker }
        }
        if let blocker = SprayPlanningOperationalGate.tankComplianceBlocker(tanks) { return blocker }
        return SprayPlanningOperationalGate.blocker(
            hasPlanningIntent: planningIntent != nil || sprayerConfiguration != nil || sprayPlanningMethod != nil ||
                plannedApplicationAreaHa != nil || planningIntendedTankLitres != nil || controllerLitresPer100mTravel != nil ||
                effectiveWorkingWidthMetres != nil || fullTankSpecification != nil || planningCalibratedLitresPerHectare != nil ||
                planningInputProvenance != nil || planningTargetAreaHa != nil || resolvedPlanningCarrierLitres != nil ||
                resolvedPlanningLitresPerHectare != nil || resolvedPlanningPhysicalRowLitresPer100m != nil || resolvedPlanningConcentrationFactor != nil,
            concentrationFactor: nil, hasDiluteRateProducts: false)
    }
}
