import Foundation

/// Only this server response can acknowledge a delete whose scoped SELECT
/// returned no rows. Empty lists, 404s, auth failures and timeouts are not proof.
nonisolated struct TripDeleteAbsenceReceipt: Decodable, Sendable {
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

    enum Failure: Error, LocalizedError {
        case unconfirmed
        var errorDescription: String? { "TRIP_DELETE_ABSENCE_UNCONFIRMED" }
    }

    func requireConfirmation(
        trip: UUID, owner: UUID, generation: UInt64,
        currentOwner: UUID?, currentGeneration: UInt64
    ) throws {
        guard currentOwner == owner, generation == currentGeneration else {
            throw CancellationError()
        }
        guard schemaVersion == 1, tripId == trip, actorId == owner, absent else {
            throw Failure.unconfirmed
        }
    }
}
