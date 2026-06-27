import Foundation
import Supabase

final class SupabaseButtonConfigSyncRepository: ButtonConfigSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchButtonConfigs(vineyardId: UUID) async throws -> [BackendButtonConfig] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("vineyard_button_configs")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: true)
            .execute()
            .value
    }

    func upsertButtonConfig(_ config: BackendButtonConfigUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("vineyard_button_configs")
            .upsert(config, onConflict: "vineyard_id,config_type")
            .execute()
    }

    func upsertButtonConfigs(_ configs: [BackendButtonConfigUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !configs.isEmpty else { return }
        try await provider.client
            .from("vineyard_button_configs")
            .upsert(configs, onConflict: "vineyard_id,config_type")
            .execute()
    }
}
