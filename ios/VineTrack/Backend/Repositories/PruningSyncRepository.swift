import Foundation
import Supabase

protocol PruningSyncRepositoryProtocol: Sendable {
    func fetchSeasons(vineyardId: UUID, since: Date?) async throws -> [BackendPruningSeason]
    func fetchEntries(vineyardId: UUID, since: Date?) async throws -> [BackendPruningEntry]
    /// Completed quarters are always fetched in full — they are the single
    /// source of truth for progress and re-attribution must see everything.
    func fetchSegments(vineyardId: UUID) async throws -> [BackendPruningSegment]
    func upsertSeasons(_ items: [BackendPruningSeasonUpsert]) async throws
    func recordEntry(_ params: RecordPruningEntryParams) async throws
    /// Transaction-safe edit through `update_pruning_entry` (sql/120) — the
    /// ONLY way an existing entry, its quarters and totals change.
    func updateEntry(_ params: UpdatePruningEntryParams) async throws -> UpdatePruningEntryResult
    func deleteEntry(id: UUID) async throws
    func softDeleteSeason(id: UUID) async throws
    /// Fetches the authoritative SQL 115 vineyard summary for the online
    /// parity check. Offline callers must treat failures as "no check".
    func fetchVineyardSummary(vineyardId: UUID) async throws -> BackendPruningVineyardSummary
}

private nonisolated struct PruningIdRequest: Encodable, Sendable {
    let id: UUID
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
    }
}

private func isoTimestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

final class SupabasePruningSyncRepository: PruningSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetchSeasons(vineyardId: UUID, since: Date?) async throws -> [BackendPruningSeason] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("pruning_seasons").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: isoTimestamp(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func fetchEntries(vineyardId: UUID, since: Date?) async throws -> [BackendPruningEntry] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("pruning_entries").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: isoTimestamp(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func fetchSegments(vineyardId: UUID) async throws -> [BackendPruningSegment] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("pruning_row_segments")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .eq("completed", value: true)
            .execute()
            .value
    }

    func upsertSeasons(_ items: [BackendPruningSeasonUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("pruning_seasons").upsert(items, onConflict: "id").execute()
    }

    func recordEntry(_ params: RecordPruningEntryParams) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("record_pruning_entry", params: params).execute()
    }

    func updateEntry(_ params: UpdatePruningEntryParams) async throws -> UpdatePruningEntryResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("update_pruning_entry", params: params)
            .execute()
            .value
    }

    func deleteEntry(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("delete_pruning_entry", params: PruningIdRequest(id: id)).execute()
    }

    func softDeleteSeason(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_pruning_season", params: PruningIdRequest(id: id)).execute()
    }

    func fetchVineyardSummary(vineyardId: UUID) async throws -> BackendPruningVineyardSummary {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("get_pruning_vineyard_summary", params: PruningSummaryRequest(vineyardId: vineyardId))
            .execute()
            .value
    }
}
