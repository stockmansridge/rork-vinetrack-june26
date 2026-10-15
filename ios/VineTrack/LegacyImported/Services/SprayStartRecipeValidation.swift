import Foundation

/// Admission only for a new operational start; never rewrites or rejects historical sync.
nonisolated enum SprayStartRecipeValidation {
    static func blocker(_ tanks: [SprayTank]) -> String? {
        guard !tanks.isEmpty else { return "A validated tank mix is required before starting a spray." }
        for tank in tanks {
            guard tank.waterVolume.isFinite, tank.waterVolume > 0, !tank.chemicals.isEmpty else {
                return "Confirm positive water and at least one product in every planned tank."
            }
            for chemical in tank.chemicals {
                guard chemical.reportedRateBaseValue.isFinite, chemical.reportedRateBaseValue > 0,
                      chemical.volumePerTank.isFinite, chemical.volumePerTank > 0 else {
                    return "Confirm a valid positive chemical rate and quantity for \(chemical.name) before starting."
                }
            }
        }
        return SprayPlanningOperationalGate.tankComplianceBlocker(tanks)
    }
}
