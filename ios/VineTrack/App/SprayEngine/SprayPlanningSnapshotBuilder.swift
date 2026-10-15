import Foundation

/// Freezes actual production record/tank payloads without changing doses, original units or historical evidence.
nonisolated enum SprayPlanningSnapshotBuilder {
    typealias W = SprayPlanningProtocol
    struct Binding {
        let recipeRevisionId: String
        let previousRevisionId: String?
        let previousRecipeDigest: String?
        let routeRevisionId: String?
        let route: W.JSON?
        let trip: Trip?
        let equipment: W.JSON
        let physicalGeometry: W.JSON
        let dependencies: W.JSON
        let tankSessionId: String?
        let actualUseId: String?
        let reviewedActuals: W.JSON?
    }
    static func freeze(_ record: SprayRecord, scope: W.Scope, kind: W.Kind, binding: Binding) throws -> W.Request {
        guard record.vineyardId.uuidString.lowercased() == scope.vineyardId,
              let geometry = record.applicationGeometry, let intent = geometry.planningIntent,
              let resolution = geometry.planningResolution,
              intent.frozenResolutionBlocker(resolution) == nil,
              intent.fullTankExecutionBlocker(resolution: resolution, selectedGrossAreaHa: geometry.grossAreaHa) == nil,
              record.tanks.allSatisfy({ $0.waterVolume.isFinite && $0.waterVolume > 0 && $0.concentrationFactor.isFinite && $0.concentrationFactor >= 1 }),
              SprayPlanningOperationalGate.tankComplianceBlocker(record.tanks) == nil,
              binding.trip.map({ $0.id == record.tripId && $0.vineyardId == record.vineyardId }) ?? true else { throw W.Failure.invalidRequest }
        func raw<T: Encodable>(_ value: T) throws -> W.JSON { try JSONDecoder().decode(W.JSON.self, from: JSONEncoder().encode(value)) }
        let lines: [W.JSON] = try record.tanks.flatMap { tank in
            try tank.chemicals.map { chemical in
                guard let basis = chemical.rateBasis else { throw W.Failure.invalidRequest }
                return .object(["tankId": .string(tank.id.uuidString.lowercased()), "tankNumber": .number(Double(tank.tankNumber)),
                    "lineId": .string(chemical.id.uuidString.lowercased()), "rateBasis": .string(basis.rawValue),
                    "quantity": .number(chemical.volumePerTank), "unit": .string(chemical.unit.rawValue),
                    "originalLine": try raw(chemical)])
            }
        }
        let snapshot = W.Snapshot(recordId: record.id.uuidString.lowercased(), tripId: binding.trip?.id.uuidString.lowercased(),
            recipeRevisionId: binding.recipeRevisionId, expectedPreviousRevisionId: binding.previousRevisionId,
            expectedRecipeDigest: binding.previousRecipeDigest, routeRevisionId: binding.routeRevisionId,
            tankSessionId: binding.tankSessionId, actualUseId: binding.actualUseId,
            planningInputs: try raw(intent), frozenOutputs: try raw(resolution), chemicalLines: .array(lines),
            equipment: binding.equipment, geometry: .object(["application": try raw(geometry), "physical": binding.physicalGeometry]),
            route: binding.route, originalRecord: try raw(record), originalTrip: try binding.trip.map(raw),
            reviewedActuals: binding.reviewedActuals, dependencies: binding.dependencies)
        let request = W.Request(scope: scope, kind: kind, snapshot: snapshot)
        try W.validate(request); return request
    }
    /// Confirmation captures the complete recipe. Existing factual sessions are recovery evidence, never deleted here.
    static func validateTankConfirmation(captured: SprayRecord, current: SprayRecord?) throws {
        guard captured == current else { throw W.Failure.conflict }
    }
}
