import Foundation

protocol TripSyncRepositoryProtocol: Sendable {
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip]
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip]
    /// Fetch every non-deleted trip the current user can see across all
    /// vineyards (RLS gates the result). Used by the admin trip audit tool.
    func fetchAllAccessibleTrips() async throws -> [BackendTrip]
    func upsertTrip(_ trip: BackendTripUpsert) async throws
    func upsertTrips(_ trips: [BackendTripUpsert]) async throws
    /// Patch a trip's `vineyard_id` (and optional scalar `paddock_id`) without
    /// having to send a full upsert payload. Used by the admin trip audit tool.
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws
    /// Patch a trip's `work_task_id` link explicitly, sending an explicit null
    /// when `workTaskId` is nil. The bulk upsert payload omits nil optionals
    /// (partial-sync guardrail), so unlinking must use this dedicated patch to
    /// actually clear the server value. See sql/102_trips_work_task_link.sql.
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws
    func softDeleteTrip(id: UUID) async throws
    func resolveDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String
    /// Previously held ambiguities are rechecked read-only; never issue a fresh delete here.
    func reverifyDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String
    func fetchOccurrenceRecovery(tripId: UUID, operationIds: [String]) async throws -> TripOccurrenceCoverage.JSON
    /// P0 3.1.9 Phase B: exact scoped readback of a live Trip's tank session IDs (lowercased).
    /// nil means the Trip is absent or soft-deleted.
    func fetchTankSessionIds(tripId: UUID, vineyardId: UUID) async throws -> Set<String>?
    /// First-stage dependency upload for an original ended occurrence Trip.
    /// Writes only its already recorded tank sessions, without finalising
    /// the Trip or touching its Spray/Actual Use.
    func establishOccurrenceTankSessions(_ trip: BackendTripUpsert, required: Set<String>) async throws
}

extension TripSyncRepositoryProtocol {
    func reverifyDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String {
        throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED")
    }
    func resolveDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String {
        throw TripDeletionJournal.Held(reason: "TRIP_DELETE_SCOPED_TRANSPORT_UNAVAILABLE")
    }
    func fetchOccurrenceRecovery(tripId: UUID, operationIds: [String]) async throws -> TripOccurrenceCoverage.JSON {
        throw TripOccurrenceCoverage.Failure.updateRequired
    }
    func fetchTankSessionIds(tripId: UUID, vineyardId: UUID) async throws -> Set<String>? {
        throw TankSessionReadbackUnsupported()
    }
    func establishOccurrenceTankSessions(_ trip: BackendTripUpsert, required: Set<String>) async throws {
        // Test fakes must explicitly implement the evidence-preserving stage;
        // a missing transport never becomes an implicit server acknowledgement.
        throw TankSessionReadbackUnsupported()
    }
}
