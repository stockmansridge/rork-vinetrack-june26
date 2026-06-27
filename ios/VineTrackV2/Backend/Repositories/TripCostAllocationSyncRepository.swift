import Foundation
import Supabase

protocol TripCostAllocationSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendTripCostAllocation]
    func upsertMany(_ items: [BackendTripCostAllocationUpsert]) async throws
    func softDelete(id: UUID) async throws
    func softDeleteForTrip(tripId: UUID) async throws
}

private nonisolated struct SoftDeleteByIdRequest: Encodable, Sendable {
    let id: UUID
    enum CodingKeys: String, CodingKey { case id = "p_id" }
}

private nonisolated struct SoftDeleteForTripRequest: Encodable, Sendable {
    let tripId: UUID
    enum CodingKeys: String, CodingKey { case tripId = "p_trip_id" }
}

private func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

final class SupabaseTripCostAllocationSyncRepository: TripCostAllocationSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendTripCostAllocation] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("trip_cost_allocations").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendTripCostAllocationUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("trip_cost_allocations").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_trip_cost_allocation", params: SoftDeleteByIdRequest(id: id)).execute()
    }

    func softDeleteForTrip(tripId: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc(
            "soft_delete_trip_cost_allocations_for_trip",
            params: SoftDeleteForTripRequest(tripId: tripId)
        ).execute()
    }
}
