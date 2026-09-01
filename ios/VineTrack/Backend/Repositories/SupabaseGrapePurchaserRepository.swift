import Foundation
import Supabase

/// Saved grape purchasers (sql/219): RLS-guarded table access + the
/// soft-delete RPC. Purchasers are never hard-deleted.
final class SupabaseGrapePurchaserRepository {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private nonisolated struct SoftDeleteRequest: Encodable, Sendable {
        let id: UUID
        enum CodingKeys: String, CodingKey { case id = "p_id" }
    }

    func fetch(vineyardId: UUID) async throws -> [BackendGrapePurchaser] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client.from("grape_purchasers")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .is("deleted_at", value: nil)
            .order("winery_name", ascending: true)
            .execute().value
    }

    func upsert(_ item: BackendGrapePurchaserUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.from("grape_purchasers").upsert(item, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_grape_purchaser", params: SoftDeleteRequest(id: id)).execute()
    }
}
