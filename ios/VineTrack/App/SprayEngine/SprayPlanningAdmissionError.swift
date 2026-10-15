import Foundation

nonisolated struct SprayPlanningAdmissionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SprayPlanningOperationalGate {
    /// A delayed confirmation must still describe the exact current frozen record.
    nonisolated static func tankConfirmationBlocker(current: SprayRecord?, captured: SprayRecord) -> String? {
        guard let current, current == captured else {
            return "The planned mix changed while this tank was open. Reopen Start Tank and confirm again."
        }
        return current.operationalPlanningBlocker
    }
}

extension SprayRecord {
    nonisolated var operationalPlanningBlocker: String? {
        if !isTemplate, let geometry = applicationGeometry, let intent = geometry.planningIntent,
           let resolution = geometry.planningResolution,
           let blocker = intent.frozenResolutionBlocker(resolution) { return blocker }
        if !isTemplate, let geometry = applicationGeometry, let intent = geometry.planningIntent,
           geometry.planningResolution != nil,
           let blocker = intent.fullTankExecutionBlocker(resolution: geometry.planningResolution, selectedGrossAreaHa: geometry.grossAreaHa) { return blocker }
        if let blocker = SprayPlanningOperationalGate.tankComplianceBlocker(tanks) { return blocker }
        return SprayPlanningOperationalGate.blocker(
            hasPlanningIntent: applicationGeometry?.planningFieldsCleared == true || applicationGeometry?.planningIntent != nil || applicationGeometry?.planningResolution != nil,
            concentrationFactor: nil, hasDiluteRateProducts: false)
    }
}

extension BackendSprayRecordUpsert {
    nonisolated var operationalPlanningBlocker: String? {
        if !isTemplate, let intent = planningIntent,
           let area = plannedApplicationAreaHa, let litres = resolvedPlanningCarrierLitres, let rate = resolvedPlanningLitresPerHectare,
           let factor = resolvedPlanningConcentrationFactor {
            let resolution = SprayPlanningResolution(intendedLitres: litres, plannedAreaHa: area, litresPerHectare: rate,
                physicalRowLitresPer100m: resolvedPlanningPhysicalRowLitresPer100m, controllerLitresPer100mTravel: controllerLitresPer100mTravel,
                effectiveWorkingWidthMetres: effectiveWorkingWidthMetres, concentrationFactor: factor)
            if let blocker = intent.frozenResolutionBlocker(resolution) { return blocker }
            if let blocker = intent.fullTankExecutionBlocker(resolution: resolution, selectedGrossAreaHa: grossAreaHa) { return blocker }
        }
        if let blocker = SprayPlanningOperationalGate.tankComplianceBlocker(tanks) { return blocker }
        return SprayPlanningOperationalGate.blocker(
            hasPlanningIntent: planningFieldsCleared || planningIntent != nil || sprayerConfiguration != nil || sprayPlanningMethod != nil ||
                plannedApplicationAreaHa != nil || planningIntendedTankLitres != nil || controllerLitresPer100mTravel != nil ||
                effectiveWorkingWidthMetres != nil || fullTankSpecification != nil || planningCalibratedLitresPerHectare != nil ||
                planningInputProvenance != nil || planningTargetAreaHa != nil || resolvedPlanningCarrierLitres != nil ||
                resolvedPlanningLitresPerHectare != nil || resolvedPlanningPhysicalRowLitresPer100m != nil || resolvedPlanningConcentrationFactor != nil,
            concentrationFactor: nil, hasDiluteRateProducts: false)
    }
}
