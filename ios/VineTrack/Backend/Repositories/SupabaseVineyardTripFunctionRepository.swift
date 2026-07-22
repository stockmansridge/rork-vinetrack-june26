import Foundation
import Supabase

/// Repository for `public.vineyard_trip_functions`. Vineyard-scoped custom
/// Trip Functions. Built-in trip functions live in the `TripFunction` enum
/// and are NOT stored here.
final class SupabaseVineyardTripFunctionRepository: Sendable {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    /// Fetch all (active + archived) trip functions for a vineyard. Soft-deleted
    /// rows are included so the Settings screen can surface restore actions.
    func fetchAll(vineyardId: UUID) async throws -> [VineyardTripFunction] {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        let response: [BackendVineyardTripFunction] = try await provider.client
            .from("vineyard_trip_functions")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .order("sort_order", ascending: true)
            .order("label", ascending: true)
            .execute()
            .value
        return response.map(VineyardTripFunction.init(backend:))
    }

    /// Insert or update a custom trip function. The caller is responsible for
    /// ensuring the user has Owner/Manager role; RLS enforces this on the
    /// server side as well.
    func upsert(_ item: VineyardTripFunction) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        try await provider.client
            .from("vineyard_trip_functions")
            .upsert(item.upsertPayload, onConflict: "id")
            .execute()
    }

    /// Soft-delete a custom trip function via the `archive_vineyard_trip_function`
    /// RPC. Leaves any historical trips referencing this function untouched.
    func archive(id: UUID) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        struct Params: Encodable, Sendable {
            let p_id: UUID
        }
        try await provider.client
            .rpc("archive_vineyard_trip_function", params: Params(p_id: id))
            .execute()
    }

    /// Restore a previously-archived custom trip function via the
    /// `restore_vineyard_trip_function` RPC.
    func restore(id: UUID) async throws {
        guard provider.isConfigured else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        struct Params: Encodable, Sendable {
            let p_id: UUID
        }
        try await provider.client
            .rpc("restore_vineyard_trip_function", params: Params(p_id: id))
            .execute()
    }
}
