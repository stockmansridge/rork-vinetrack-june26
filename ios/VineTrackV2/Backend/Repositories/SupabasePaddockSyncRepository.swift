import Foundation
import Supabase

final class SupabasePaddockSyncRepository: PaddockSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchPaddocks(vineyardId: UUID, since: Date?) async throws -> [BackendPaddock] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("paddocks")
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

    func fetchAllPaddocks(vineyardId: UUID) async throws -> [BackendPaddock] {
        try await fetchPaddocks(vineyardId: vineyardId, since: nil)
    }

    func fetchAllAccessiblePaddocks() async throws -> [BackendPaddock] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("paddocks")
            .select()
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: false)
            .limit(10_000)
            .execute()
            .value
    }

    func fetchPaddockIds(vineyardId: UUID) async throws -> [BackendPaddockIdRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("paddocks")
            .select("id,deleted_at")
            .eq("vineyard_id", value: vineyardId.uuidString)
            .execute()
            .value
    }

    func upsertPaddock(_ paddock: BackendPaddockUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("paddocks")
            .upsert(paddock, onConflict: "id")
            .execute()
    }

    func upsertPaddocks(_ paddocks: [BackendPaddockUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !paddocks.isEmpty else { return }
        try await provider.client
            .from("paddocks")
            .upsert(paddocks, onConflict: "id")
            .execute()
    }

    func softDeletePaddock(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_paddock", params: SoftDeletePaddockRequest(paddockId: id))
            .execute()
    }

    func paddockReferenceCounts(id: UUID) async throws -> PaddockReferenceCounts {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [PaddockReferenceCounts] = try await provider.client
            .rpc("paddock_reference_counts", params: SoftDeletePaddockRequest(paddockId: id))
            .execute()
            .value
        guard let first = rows.first else {
            throw BackendRepositoryError.missingSupabaseConfiguration
        }
        return first
    }

    func hardDeletePaddock(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("hard_delete_paddock", params: SoftDeletePaddockRequest(paddockId: id))
            .execute()
    }

    func restorePaddock(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("restore_paddock", params: SoftDeletePaddockRequest(paddockId: id))
            .execute()
    }
}

nonisolated private struct SoftDeletePaddockRequest: Encodable, Sendable {
    let paddockId: UUID

    enum CodingKeys: String, CodingKey {
        case paddockId = "p_paddock_id"
    }
}
