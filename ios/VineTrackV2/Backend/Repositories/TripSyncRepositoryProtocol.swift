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
}
