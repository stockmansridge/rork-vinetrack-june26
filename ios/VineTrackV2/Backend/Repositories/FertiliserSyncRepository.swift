import Foundation
import Supabase

/// Repository for `fertiliser_records` + `fertiliser_record_allocations`.
/// The product library is the shared `saved_chemicals` table (sql/111),
/// handled by `SavedChemicalSyncRepositoryProtocol`.
protocol FertiliserSyncRepositoryProtocol: Sendable {
    func fetchRecords(vineyardId: UUID, since: Date?) async throws -> [BackendFertiliserRecord]
    /// Allocations are small child rows — always fetched in full per vineyard.
    func fetchAllocations(vineyardId: UUID) async throws -> [BackendFertiliserAllocation]
    func upsertRecords(_ items: [BackendFertiliserRecordUpsert]) async throws
    func upsertAllocations(_ items: [BackendFertiliserAllocation]) async throws
    func softDeleteRecord(id: UUID) async throws
}

private nonisolated struct FertiliserIdRequest: Encodable, Sendable {
    let id: UUID
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
    }
}

private func isoTimestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

final class SupabaseFertiliserSyncRepository: FertiliserSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetchRecords(vineyardId: UUID, since: Date?) async throws -> [BackendFertiliserRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("fertiliser_records").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: isoTimestamp(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func fetchAllocations(vineyardId: UUID) async throws -> [BackendFertiliserAllocation] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("fertiliser_record_allocations")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .execute()
            .value
    }

    func upsertRecords(_ items: [BackendFertiliserRecordUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("fertiliser_records").upsert(items, onConflict: "id").execute()
    }

    func upsertAllocations(_ items: [BackendFertiliserAllocation]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("fertiliser_record_allocations").upsert(items, onConflict: "id").execute()
    }

    func softDeleteRecord(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_fertiliser_record", params: FertiliserIdRequest(id: id)).execute()
    }
}
