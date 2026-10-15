import Foundation

/// New generic spray starts must carry a scoped validated recipe; factual recovery uses its existing path.
@MainActor
enum SprayTripStartAdmission {
    static func blocker(isSpray: Bool, vineyardId: UUID, record: SprayRecord?) -> String? {
        guard isSpray else { return nil }
        guard let record, record.vineyardId == vineyardId, !record.isTemplate, record.endTime == nil else {
            return "Start this spray from a validated saved recipe or the Spray Calculator. Generic start does not authorise spraying."
        }
        return record.operationalPlanningBlocker ?? SprayStartRecipeValidation.blocker(record.tanks)
    }
}
