import Foundation

/// P0 3.1.9 Phase B (mirrors Android `TankDependencyVerification`).
///
/// A Trip upload carrying tank progress is never acknowledged while a tank session
/// referenced by a local Tank actual is missing from the payload or from the server
/// readback, and a Tank actual is never acknowledged until a server readback returns
/// its exact recorded evidence. Codes are fixed and carry no private values.
nonisolated enum TankDependencyVerification {
    static let requiredSessionMissing = "TRIP_TANK_REQUIRED_SESSION_MISSING"
    static let patchReadbackMismatch = "TRIP_TANK_PATCH_READBACK_MISMATCH"
    static let actualSessionNotOnServer = "TANK_ACTUAL_SESSION_NOT_ON_SERVER"
    static let actualReadbackMismatch = "TANK_ACTUAL_READBACK_MISMATCH"

    private static let epsilon = 1e-9

    static func normalized(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString.lowercased() ?? id.lowercased()
    }

    static func ids(_ sessions: [TankSession]) -> Set<String> {
        Set(sessions.map { $0.id.uuidString.lowercased() })
    }

    /// Normalised session IDs referenced by actuals for one Trip.
    static func requiredSessions(tripId: UUID, actuals: [SprayTankActual]) -> Set<String> {
        Set(actuals.filter { $0.tripId == tripId }.map { normalized($0.tankSessionId) })
    }

    static func missing(required: Set<String>, in sessionIds: Set<String>) -> Set<String> {
        required.subtracting(sessionIds)
    }

    /// Exact recorded evidence survives on the server row: identity, links and actual quantities.
    static func actualMatches(local: SprayTankActual, server: SprayTankActual?) -> Bool {
        guard let server else { return false }
        guard server.id == local.id, server.vineyardId == local.vineyardId, server.tripId == local.tripId,
              server.sprayRecordId == local.sprayRecordId,
              normalized(server.tankSessionId) == normalized(local.tankSessionId),
              server.tankNumber == local.tankNumber,
              (server.correctionVersion ?? 0) >= (local.correctionVersion ?? 0) else { return false }
        switch (local.waterVolumeL, server.waterVolumeL) {
        case (nil, nil): break
        case let (l?, s?): guard abs(l - s) <= epsilon else { return false }
        default: return false
        }
        guard local.chemicals.count == server.chemicals.count else { return false }
        let remote = Dictionary(server.chemicals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard remote.count == server.chemicals.count else { return false }
        return local.chemicals.allSatisfy { chem in
            guard let other = remote[chem.id] else { return false }
            return other.name == chem.name && other.unit == chem.unit
                && abs(other.actualAmountBase - chem.actualAmountBase) <= epsilon
        }
    }
}

/// Raised by fakes that cannot read back a Trip's tank sessions; production always can.
nonisolated struct TankSessionReadbackUnsupported: Error {}
