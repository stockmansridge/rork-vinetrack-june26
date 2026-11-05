import Foundation

/// Server end/delete state of one Trip row, without its GPS history.
nonisolated struct TripServerEndState: Sendable, Equatable {
    let id: UUID
    let hasEnded: Bool
    let isDeleted: Bool
}

protocol TripSyncRepositoryProtocol: Sendable {
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip]
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip]
    /// Every Trip id in the vineyard with only its end/delete state. Upload
    /// preflight used to download every Trip's full GPS history on each sweep.
    func fetchTripEndStates(vineyardId: UUID) async throws -> [TripServerEndState]
    /// Full rows for the given ids only (the Trips queued for upload).
    func fetchTrips(ids: [UUID], vineyardId: UUID) async throws -> [BackendTrip]
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
    // Defaults keep test fakes and probes working unchanged; the Supabase
    // repository overrides both with column- and id-scoped queries.
    func fetchTripEndStates(vineyardId: UUID) async throws -> [TripServerEndState] {
        try await fetchAllTrips(vineyardId: vineyardId).map {
            TripServerEndState(id: $0.id, hasEnded: $0.endTime != nil, isDeleted: $0.deletedAt != nil)
        }
    }
    func fetchTrips(ids: [UUID], vineyardId: UUID) async throws -> [BackendTrip] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }
        return try await fetchAllTrips(vineyardId: vineyardId).filter { wanted.contains($0.id) }
    }
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
