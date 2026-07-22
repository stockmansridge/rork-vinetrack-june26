import Foundation
import Supabase

final class SupabaseTripSyncRepository: TripSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("trips")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await query
                .gte("updated_at", value: ISO8601DateFormatter().string(from: since))
                .order("updated_at", ascending: true)
                .execute()
                .value
        } else {
            return try await query
                .order("updated_at", ascending: true)
                .execute()
                .value
        }
    }

    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] {
        try await fetchTrips(vineyardId: vineyardId, since: nil)
    }

    func upsertTrip(_ trip: BackendTripUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("trips")
            .upsert(trip, onConflict: "id")
            .execute()
    }

    func upsertTrips(_ trips: [BackendTripUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !trips.isEmpty else { return }
        try await provider.client
            .from("trips")
            .upsert(trips, onConflict: "id")
            .execute()
    }

    func fetchAllAccessibleTrips() async throws -> [BackendTrip] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("trips")
            .select()
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: false)
            .limit(10_000)
            .execute()
            .value
    }

    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("trips")
            .update(TripVineyardAssignmentUpdate(
                vineyardId: vineyardId,
                paddockId: paddockId,
                clientUpdatedAt: Date()
            ))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("trips")
            .update(TripWorkTaskLinkUpdate(
                workTaskId: workTaskId,
                clientUpdatedAt: Date()
            ))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func softDeleteTrip(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_trip", params: SoftDeleteTripRequest(tripId: id))
            .execute()
    }
}

nonisolated private struct TripVineyardAssignmentUpdate: Encodable, Sendable {
    let vineyardId: UUID
    let paddockId: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case clientUpdatedAt = "client_updated_at"
    }
}

/// Explicit `work_task_id` patch. Unlike the synthesized bulk upsert, this
/// forces `encode` (not `encodeIfPresent`) so a nil `workTaskId` is written as
/// an explicit SQL null — required to actually unlink a trip on the server.
nonisolated private struct TripWorkTaskLinkUpdate: Encodable, Sendable {
    let workTaskId: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case workTaskId = "work_task_id"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workTaskId, forKey: .workTaskId)
        try container.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

nonisolated private struct SoftDeleteTripRequest: Encodable, Sendable {
    let tripId: UUID

    enum CodingKeys: String, CodingKey {
        case tripId = "p_trip_id"
    }
}
