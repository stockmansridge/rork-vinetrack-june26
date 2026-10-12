import Foundation

nonisolated struct SprayPlanningAdmissionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SprayRecord {
    nonisolated var operationalPlanningBlocker: String? {
        SprayPlanningOperationalGate.blocker(
            hasPlanningIntent: applicationGeometry?.planningIntent != nil || applicationGeometry?.planningResolution != nil,
            concentrationFactor: tanks.first(where: { !$0.concentrationFactor.isFinite })?.concentrationFactor
                ?? (tanks.map(\.concentrationFactor) + [applicationGeometry?.concentrationFactor].compactMap { $0 }).max(),
            hasDiluteRateProducts: tanks.contains { $0.chemicals.contains { $0.reportedRateBasis == .per100Litres } })
    }
}

extension BackendSprayRecordUpsert {
    nonisolated var operationalPlanningBlocker: String? {
        SprayPlanningOperationalGate.blocker(
            hasPlanningIntent: planningIntent != nil,
            concentrationFactor: tanks.first(where: { !$0.concentrationFactor.isFinite })?.concentrationFactor
                ?? (tanks.map(\.concentrationFactor) + [concentrationFactor].compactMap { $0 }).max(),
            hasDiluteRateProducts: tanks.contains { $0.chemicals.contains { $0.reportedRateBasis == .per100Litres } })
    }
}
