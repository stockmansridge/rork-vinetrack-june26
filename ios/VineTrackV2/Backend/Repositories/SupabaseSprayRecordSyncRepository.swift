import Foundation
import Supabase

final class SupabaseSprayRecordSyncRepository: SprayRecordSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchSprayRecords(vineyardId: UUID, since: Date?) async throws -> [BackendSprayRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("spray_records")
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

    func fetchAllSprayRecords(vineyardId: UUID) async throws -> [BackendSprayRecord] {
        try await fetchSprayRecords(vineyardId: vineyardId, since: nil)
    }

    func upsertSprayRecord(_ record: BackendSprayRecordUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("spray_records")
            .upsert(record, onConflict: "id")
            .execute()
    }

    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !records.isEmpty else { return }
        try await provider.client
            .from("spray_records")
            .upsert(records, onConflict: "id")
            .execute()
    }

    func softDeleteSprayRecord(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_spray_record", params: SoftDeleteSprayRecordRequest(sprayRecordId: id))
            .execute()
    }
}

nonisolated private struct SoftDeleteSprayRecordRequest: Encodable, Sendable {
    let sprayRecordId: UUID

    enum CodingKeys: String, CodingKey {
        case sprayRecordId = "p_spray_record_id"
    }
}
