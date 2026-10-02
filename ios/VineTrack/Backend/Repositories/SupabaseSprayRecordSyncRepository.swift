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
        let existing: [BackendSprayRecord] = try await provider.client.from("spray_records")
            .select().eq("id", value: record.id.uuidString).execute().value
        if let server = existing.first {
            // Never regress server completion, including confirmation between
            // this read and the write. Keep every unrelated queued form field.
            let fields = try Self.editableFieldsPreservingCompletion(record)
            if server.endTime == nil, let end = record.endTime {
                var completingFields = fields
                completingFields["end_time"] = .string(end.ISO8601Format(.init(includingFractionalSeconds: true)))
                let updated: [BackendSprayRecord] = try await provider.client.from("spray_records")
                    .update(completingFields).eq("id", value: record.id.uuidString)
                    .is("end_time", value: nil).select().execute().value
                if updated.count == 1 { return }
                // A concurrent server completion won: replay only form edits.
            }
            let updated: [BackendSprayRecord] = try await provider.client.from("spray_records")
                .update(fields).eq("id", value: record.id.uuidString).select().execute().value
            guard updated.count == 1 else { throw BackendRepositoryError.emptyResponse }
        } else {
            try await provider.client.from("spray_records").upsert(record, onConflict: "id").execute()
        }
    }

    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !records.isEmpty else { return }
        for record in records { try await upsertSprayRecord(record) }
    }

    nonisolated static func editableFieldsPreservingCompletion(_ record: BackendSprayRecordUpsert) throws -> [String: SprayReportPayloadV1.JSONValue] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.ISO8601Format(.init(includingFractionalSeconds: true)))
        }
        var fields = try JSONDecoder().decode([String: SprayReportPayloadV1.JSONValue].self, from: encoder.encode(record))
        fields.removeValue(forKey: "end_time")
        fields.removeValue(forKey: "created_by")
        return fields
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
