import Foundation

/// Versioned domain envelope. JSON evidence is retained whole, never reconstructed from current geometry.
nonisolated enum SprayPlanningProtocol {
    typealias JSON = TripOccurrenceCoverage.JSON
    static let contract = "vinetrack.spray-planning"
    static let digestAlgorithm = "pg-jsonb-text-sha256-v1"
    enum Kind: String, Codable, Sendable, CaseIterable {
        case save = "save_plan", replace = "replace_plan", bind = "bind_route", start = "start_spray", tank = "start_tank"
        var rpc: String {
            switch self {
            case .save: return "save_spray_plan_v1"
            case .replace: return "replace_spray_plan_v1"
            case .bind: return "bind_spray_plan_route_v1"
            case .start: return "start_spray_plan_v1"
            case .tank: return "start_spray_plan_tank_v1"
            }
        }
    }
    struct Scope: Codable, Sendable, Equatable {
        let actorId: String
        let vineyardId: String
        /// Local authentication incarnation, not sent to the server or inferred from a cached capability.
        let incarnation: String
    }
    struct Snapshot: Codable, Sendable, Equatable {
        let recordId: String
        let tripId: String?
        let recipeRevisionId: String
        let expectedPreviousRevisionId: String?
        let expectedRecipeDigest: String?
        let routeRevisionId: String?
        let tankSessionId: String?
        let actualUseId: String?
        let planningInputs: JSON
        let frozenOutputs: JSON
        let chemicalLines: JSON
        let equipment: JSON
        let geometry: JSON
        let route: JSON?
        let originalRecord: JSON
        let originalTrip: JSON?
        let reviewedActuals: JSON?
        let dependencies: JSON
    }
    struct Request: Codable, Sendable, Equatable {
        let contract: String
        let schemaVersion: Int
        let operationId: String
        let actorId: String
        let vineyardId: String
        let kind: Kind
        let snapshot: Snapshot
        init(scope: Scope, kind: Kind, snapshot: Snapshot, operationId: String = UUID().uuidString.lowercased()) {
            contract = SprayPlanningProtocol.contract; schemaVersion = 1
            self.operationId = operationId; actorId = scope.actorId; vineyardId = scope.vineyardId
            self.kind = kind; self.snapshot = snapshot
        }
    }
    enum Phase: String, Codable, Sendable { case savedUnbound = "saved_unbound", bound, ready, active }
    struct Result: Codable, Sendable, Equatable {
        let recordId: String
        let tripId: String?
        let recipeRevisionId: String
        let routeRevisionId: String?
        let tankSessionId: String?
        let actualUseId: String?
        let phase: Phase
        let snapshot: Snapshot
        /// Established factual effects, never instructions to repeat inventory/labour/tank writes.
        let establishedEffects: JSON
    }
    struct Receipt: Codable, Sendable, Equatable {
        let contract: String
        let schemaVersion: Int
        let operationId: String
        let actorId: String
        let vineyardId: String
        let request: Request
        let digestAlgorithm: String
        let canonicalRequestSHA256: String
        let recipeSHA256: String
        let serverRevision: Int
        let acceptedAt: String
        let result: Result
    }
    struct Capability: Codable, Sendable {
        let contract: String
        let schemaVersion: Int
        let vineyardId: String
        let enabled: Bool
        let migrationId: String
        let validationSuiteId: String
        let digestAlgorithm: String
        let operations: [Kind]
        let occurrenceVersion: Int
        let tankVersion: Int
        func supports(_ request: Request) -> Bool {
            contract == SprayPlanningProtocol.contract && schemaVersion == 1 && enabled && vineyardId == request.vineyardId &&
                !migrationId.isEmpty && !validationSuiteId.isEmpty && digestAlgorithm == SprayPlanningProtocol.digestAlgorithm &&
                occurrenceVersion == 1 && tankVersion == 1 && operations.contains(request.kind)
        }
    }
    struct Recovery: Codable, Sendable {
        let contract: String
        let schemaVersion: Int
        let actorId: String
        let vineyardId: String
        let receipts: [Receipt]
        /// Separately labelled current state is evidence only; it cannot acknowledge an operation.
        let currentState: JSON
    }
    enum Failure: Error, LocalizedError {
        case storage, scope, conflict, invalidReceipt, unavailable, invalidRequest, repairRequired
        var errorDescription: String? {
            switch self {
            case .storage: return "Unable to retain the original spray plan. Nothing was submitted."
            case .scope: return "This pending plan is quarantined for its original account and vineyard."
            case .conflict: return "The spray plan needs reconciliation. Its original request is retained."
            case .invalidReceipt: return "The server receipt could not be verified. No success has been recorded."
            case .unavailable: return "Spray planning operations are not yet available. Local evidence is retained."
            case .invalidRequest: return "The plan is incomplete or its revision changed. Review it again."
            case .repairRequired: return "The accepted plan needs local repair. Do not create another attempt."
            }
        }
    }
    static func validate(_ request: Request) throws {
        let s = request.snapshot
        guard request.contract == contract, request.schemaVersion == 1,
              [request.operationId, request.actorId, request.vineyardId, s.recordId, s.recipeRevisionId].allSatisfy(TripOccurrenceCoverage.canonicalUUID),
              [s.tripId, s.expectedPreviousRevisionId, s.routeRevisionId, s.actualUseId].compactMap({ $0 }).allSatisfy(TripOccurrenceCoverage.canonicalUUID),
              s.planningInputs.occurrenceObject != nil, s.frozenOutputs.occurrenceObject != nil,
              case .array(let chemicals) = s.chemicalLines, !chemicals.isEmpty,
              s.originalRecord.occurrenceObject != nil, s.equipment.occurrenceObject != nil, s.geometry.occurrenceObject != nil else { throw Failure.invalidRequest }
        if request.kind != .save {
            guard s.expectedPreviousRevisionId != nil, s.expectedRecipeDigest.map(validDigest) == true else { throw Failure.invalidRequest }
        }
        if [.bind, .start, .tank].contains(request.kind) {
            guard s.route != nil, s.routeRevisionId != nil else { throw Failure.invalidRequest }
        }
        if [.start, .tank].contains(request.kind), s.tripId == nil || s.originalTrip == nil { throw Failure.invalidRequest }
        if request.kind == .tank, s.tankSessionId?.isEmpty != false || s.actualUseId == nil || s.reviewedActuals == nil { throw Failure.invalidRequest }
        let intent = try JSONDecoder().decode(SprayPlanningIntent.self, from: JSONEncoder().encode(s.planningInputs))
        let resolution = try JSONDecoder().decode(SprayPlanningResolution.self, from: JSONEncoder().encode(s.frozenOutputs))
        guard intent.frozenResolutionBlocker(resolution) == nil else { throw Failure.invalidRequest }
        for line in chemicals {
            guard let basis = line[occurrence: "rateBasis"]?.occurrenceString, ["whole_block_area", "treated_area", "per_100_litres", "per_100_metres"].contains(basis),
                  case .number(let quantity) = line[occurrence: "quantity"], quantity.isFinite, quantity > 0,
                  let unit = line[occurrence: "unit"]?.occurrenceString, !unit.isEmpty else { throw Failure.invalidRequest }
        }
        if request.kind == .save, s.route == nil, s.tripId != nil || s.originalTrip != nil { throw Failure.invalidRequest }
        // Label permission is deliberately absent: CF policy remains the existing calculation authority.
    }
    static func validDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func verify(_ receipt: Receipt, for request: Request) throws {
        let s = request.snapshot; let r = receipt.result
        guard receipt.contract == contract, receipt.schemaVersion == 1, receipt.operationId == request.operationId,
              receipt.actorId == request.actorId, receipt.vineyardId == request.vineyardId, receipt.request == request,
              receipt.digestAlgorithm == digestAlgorithm, validDigest(receipt.canonicalRequestSHA256), validDigest(receipt.recipeSHA256),
              receipt.serverRevision > 0, !receipt.acceptedAt.isEmpty,
              r.recordId == s.recordId, r.tripId == s.tripId, r.recipeRevisionId == s.recipeRevisionId,
              r.routeRevisionId == s.routeRevisionId, r.tankSessionId == s.tankSessionId, r.actualUseId == s.actualUseId,
              r.snapshot == s else { throw Failure.invalidReceipt }
        if [.start, .tank].contains(request.kind), r.phase != .active { throw Failure.invalidReceipt }
        if request.kind == .save, s.route == nil, r.phase != .savedUnbound || r.tripId != nil { throw Failure.invalidReceipt }
        if request.kind == .bind, ![.bound, .ready].contains(r.phase) { throw Failure.invalidReceipt }
        if [.save, .replace, .bind].contains(request.kind), r.phase == .active { throw Failure.invalidReceipt }
        if ![.save, .replace].contains(request.kind), receipt.recipeSHA256 != s.expectedRecipeDigest { throw Failure.invalidReceipt }
    }
}
