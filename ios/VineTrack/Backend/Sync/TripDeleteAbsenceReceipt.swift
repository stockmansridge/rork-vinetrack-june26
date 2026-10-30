import Foundation

/// Actor-bound proof from the existing read-only RPC. RLS-empty SELECTs are not proof.
nonisolated struct TripDeleteAbsenceReceipt: Codable, Sendable {
    let schemaVersion: Int
    let tripId: UUID
    let actorId: UUID
    let absent: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tripId = "trip_id"
        case actorId = "actor_id"
        case absent
    }

    func requireConfirmation(trip: UUID, owner: UUID, generation: UInt64,
                             currentOwner: UUID?, currentGeneration: UInt64) throws {
        guard currentOwner == owner, generation == currentGeneration else {
            throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ACCOUNT_CHANGED")
        }
        guard schemaVersion == 1, tripId == trip, actorId == owner, absent else {
            throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED")
        }
    }
}
