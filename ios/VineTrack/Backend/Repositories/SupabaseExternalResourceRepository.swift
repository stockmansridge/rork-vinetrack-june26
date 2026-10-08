import Foundation
import Supabase

/// Thin directory access through the deployed member/owner-manager RLS contract.
final class SupabaseExternalResourceRepository {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func list(vineyardId: UUID) async throws -> [VineyardExternalResource] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client.from("vineyard_external_resources").select()
            .eq("vineyard_id", value: vineyardId.uuidString).order("name").execute().value
    }
}
