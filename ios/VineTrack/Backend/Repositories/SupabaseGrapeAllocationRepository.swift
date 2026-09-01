import Foundation
import Supabase

/// Grape allocations (sql/217): base rows via RLS-guarded table access,
/// deletes through the soft-delete RPC, and owner/manager money through the
/// `get_grape_allocation_financials` RPC (42501 for lower roles).
final class SupabaseGrapeAllocationRepository {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private nonisolated struct SoftDeleteRequest: Encodable, Sendable {
        let id: UUID
        enum CodingKeys: String, CodingKey { case id = "p_id" }
    }

    private nonisolated struct VineyardIdRequest: Encodable, Sendable {
        let vineyardId: UUID
        enum CodingKeys: String, CodingKey { case vineyardId = "p_vineyard_id" }
    }

    func fetch(vineyardId: UUID) async throws -> [BackendGrapeAllocation] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client.from("grape_allocations")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .order("created_at", ascending: false)
            .execute().value
    }

    func fetchBlocks(vineyardId: UUID) async throws -> [BackendGrapeAllocationBlock] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client.from("grape_allocation_blocks")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .execute().value
    }

    /// Owner/manager only — throws (42501) for other roles; callers swallow
    /// that and show no money.
    func fetchFinancials(vineyardId: UUID) async throws -> [GrapeAllocationFinancialRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("get_grape_allocation_financials", params: VineyardIdRequest(vineyardId: vineyardId))
            .execute()
            .value
    }

    func upsert(_ item: BackendGrapeAllocationUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.from("grape_allocations").upsert(item, onConflict: "id").execute()
    }

    /// Detail rows are replaced wholesale (sql/217 header): delete-then-insert.
    func replaceBlocks(allocationId: UUID, blocks: [BackendGrapeAllocationBlockInsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.from("grape_allocation_blocks")
            .delete()
            .eq("allocation_id", value: allocationId.uuidString)
            .execute()
        guard !blocks.isEmpty else { return }
        try await provider.client.from("grape_allocation_blocks").insert(blocks).execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_grape_allocation", params: SoftDeleteRequest(id: id)).execute()
    }
}
