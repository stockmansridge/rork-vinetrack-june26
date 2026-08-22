import Foundation
import Supabase

/// Server-authoritative access to the sql/204 vineyard spray target library.
///
/// Writes go through the SECURITY DEFINER RPC rather than a table insert so the
/// database owns the role check and the "same identifier converges" rule — the
/// client cannot be the place those are decided, because two devices can add
/// the same target at the same moment.
final class VineyardSprayTargetRepository {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    /// Idempotent create keyed by the client-generated id; a duplicate active
    /// identifier returns the existing shared entry.
    func createTarget(_ params: VineyardSprayTargetCreateParams) async throws -> VineyardSprayTargetRecord {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("create_vineyard_spray_target", params: params)
            .execute()
            .value
    }

    func listTargets(vineyardId: UUID, includeInactive: Bool = false) async throws -> [VineyardSprayTargetRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "list_vineyard_spray_targets",
                params: ListSprayTargetsParams(vineyardId: vineyardId, includeInactive: includeInactive)
            )
            .execute()
            .value
    }
}

nonisolated private struct ListSprayTargetsParams: Encodable, Sendable {
    let vineyardId: UUID
    let includeInactive: Bool

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case includeInactive = "p_include_inactive"
    }
}
