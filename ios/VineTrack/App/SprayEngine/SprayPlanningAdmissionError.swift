import Foundation

nonisolated struct SprayPlanningAdmissionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SprayPlanningOperationalGate {
    /// A delayed confirmation must still describe the exact current frozen record.
    nonisolated static func tankConfirmationBlocker(current: SprayRecord?, captured: SprayRecord) -> String? {
        guard let current, current.hasSameRecipeEvidence(as: captured) else {
            return "The planned mix changed while this tank was open. Reopen Start Tank and confirm again."
        }
        return current.operationalPlanningBlocker
    }
}

extension SprayRecord {
    /// Exact evidence comparison, including unchanged legacy NaN CF; no quantity or history normalization.
    nonisolated func hasSameRecipeEvidence(as other: SprayRecord) -> Bool {
        if self == other { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        guard let current = try? encoder.encode(self), let captured = try? encoder.encode(other) else { return false }
        return current == captured
    }

    nonisolated var operationalPlanningBlocker: String? {
        if !isTemplate, let geometry = applicationGeometry, let intent = geometry.planningIntent,
           let resolution = geometry.planningResolution,
           let blocker = intent.frozenResolutionBlocker(resolution) { return blocker }
        if !isTemplate, let geometry = applicationGeometry, let intent = geometry.planningIntent,
           geometry.planningResolution != nil,
           let blocker = intent.fullTankExecutionBlocker(resolution: geometry.planningResolution, selectedGrossAreaHa: geometry.grossAreaHa) { return blocker }
        if let blocker = SprayPlanningOperationalGate.tankComplianceBlocker(tanks) { return blocker }
        return LegacySpraySetup.blocker(intent: applicationGeometry?.planningIntent,
            resolution: applicationGeometry?.planningResolution, cleared: applicationGeometry?.planningFieldsCleared == true)
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
        return LegacySpraySetup.blocker(intent: legacySetupFields.intent,
            resolution: legacySetupFields.resolution(), cleared: planningFieldsCleared)
    }
}
