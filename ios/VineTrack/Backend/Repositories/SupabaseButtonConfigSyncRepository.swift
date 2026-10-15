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

    func saveButtonConfig(_ config: BackendButtonConfigUpsert, replacing expected: BackendButtonConfig?) async throws -> BackendButtonConfig {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [BackendButtonConfig]
        if let expected {
            var query = try provider.client.from("vineyard_button_configs").update(config)
                .eq("id", value: expected.id.uuidString)
                .eq("vineyard_id", value: config.vineyardId.uuidString)
                .eq("config_type", value: config.configType)
                .is("deleted_at", value: nil)
            // sync_version is not guaranteed to advance on ordinary config writes.
            // Use the exact server-issued token, never a rounded native Date.
            guard let token = expected.updatedAtToken else { throw ButtonConfigSyncError.reviewRequired }
            query = query.eq("updated_at", value: token)
            rows = try await query.select().execute().value
        } else {
            // A concurrent first insert must fail the unique constraint, not replace its winner.
            rows = try await provider.client.from("vineyard_button_configs").insert(config).select().execute().value
        }
        guard rows.count == 1, let row = rows.first,
              row.id == config.id, row.vineyardId == config.vineyardId,
              row.configType == config.configType, row.deletedAt == nil,
              row.configData == config.configData else { throw ButtonConfigSyncError.reviewRequired }
        return row
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
