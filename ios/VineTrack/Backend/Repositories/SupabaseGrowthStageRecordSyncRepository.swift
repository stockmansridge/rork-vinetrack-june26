import Foundation
import Supabase

final class SupabaseGrowthStageRecordSyncRepository: GrowthStageRecordSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("growth_stage_records")
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

    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("growth_stage_records")
            .upsert(record, onConflict: "id")
            .execute()
    }

    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !records.isEmpty else { return }
        try await provider.client
            .from("growth_stage_records")
            .upsert(records, onConflict: "id")
            .execute()
    }

    func updatePhotoPaths(recordId: UUID, vineyardId: UUID, photoPaths: [String]) async throws -> AttachmentReferenceConfirmation {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let updated: [BackendGrowthStageRecord] = try await provider.client
            .from("growth_stage_records")
            .update(GrowthPhotoPathsPatch(photoPaths: photoPaths, clientUpdatedAt: Date()))
            .eq("id", value: recordId.uuidString)
            .eq("vineyard_id", value: vineyardId.uuidString)
            .is("deleted_at", value: nil)
            .select()
            .execute()
            .value
        if let row = updated.first {
            guard updated.count == 1,
                  row.id == recordId,
                  row.vineyardId == vineyardId,
                  row.deletedAt == nil,
                  row.photoPaths ?? [] == photoPaths else { throw AttachmentReferenceWriteError.unexpectedRecord }
            return AttachmentReferenceConfirmation(
                recordId: row.id,
                vineyardId: row.vineyardId,
                photoPath: nil,
                photoPaths: row.photoPaths
            )
        }
        let existing: [BackendGrowthStageRecord] = try await provider.client
            .from("growth_stage_records")
            .select()
            .eq("id", value: recordId.uuidString)
            .eq("vineyard_id", value: vineyardId.uuidString)
            .limit(1)
            .execute()
            .value
        if existing.first?.deletedAt != nil { throw AttachmentReferenceWriteError.recordDeleted }
        throw AttachmentReferenceWriteError.unresolved
    }

    func softDeleteGrowthStageRecord(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_growth_stage_record", params: SoftDeleteGrowthStageRecordRequest(id: id))
            .execute()
    }
}

nonisolated private struct GrowthPhotoPathsPatch: Encodable, Sendable {
    let photoPaths: [String]
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case photoPaths = "photo_paths"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated private struct SoftDeleteGrowthStageRecordRequest: Encodable, Sendable {
    let id: UUID

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
    }
}
