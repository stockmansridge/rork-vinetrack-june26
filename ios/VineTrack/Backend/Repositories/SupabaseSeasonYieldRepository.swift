import Foundation
import Supabase

/// Canonical seasonal yield estimates (sql/221).
///
/// `season_yield_estimates` is client READ-ONLY — there is deliberately no
/// insert/update/delete here. The ONLY write path is
/// `refresh_pruning_yield_estimates`, which re-derives the vintage's pruning
/// rows server-side and never downgrades a bunch_count or manual estimate.
final class SupabaseSeasonYieldRepository {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private nonisolated struct OverviewRequest: Encodable, Sendable {
        let vineyardId: UUID
        let vintage: Int
        enum CodingKeys: String, CodingKey {
            case vineyardId = "p_vineyard_id"
            case vintage = "p_vintage"
        }
    }

    /// The single authority for base (undamaged) seasonal estimates.
    func fetchOverview(vineyardId: UUID, vintage: Int) async throws -> BackendSeasonYieldOverview {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "get_season_yield_base_overview",
                params: OverviewRequest(vineyardId: vineyardId, vintage: vintage)
            )
            .execute()
            .value
    }

    /// Re-derive the vintage's pruning-based estimates. Safe and idempotent:
    /// a group already carrying a higher-priority estimate is skipped, not
    /// overwritten.
    @discardableResult
    func refreshPruningEstimates(vineyardId: UUID, vintage: Int) async throws -> BackendSeasonYieldRefreshResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc(
                "refresh_pruning_yield_estimates",
                params: OverviewRequest(vineyardId: vineyardId, vintage: vintage)
            )
            .execute()
            .value
    }
}
