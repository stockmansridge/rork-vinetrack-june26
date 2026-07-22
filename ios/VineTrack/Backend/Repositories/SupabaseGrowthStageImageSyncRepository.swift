import Foundation
import Supabase

final class SupabaseGrowthStageImageSyncRepository: GrowthStageImageSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageImage] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("vineyard_growth_stage_images")
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

    func upsertMany(_ items: [BackendGrowthStageImageUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client
            .from("vineyard_growth_stage_images")
            .upsert(items, onConflict: "id")
            .execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_growth_stage_image", params: SoftDeleteGSIRequest(imageId: id))
            .execute()
    }
}

nonisolated private struct SoftDeleteGSIRequest: Encodable, Sendable {
    let imageId: UUID

    enum CodingKeys: String, CodingKey {
        case imageId = "p_image_id"
    }
}
