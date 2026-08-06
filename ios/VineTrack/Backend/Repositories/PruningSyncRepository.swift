import Foundation
import Supabase

protocol PruningSyncRepositoryProtocol: Sendable {
    func fetchSeasons(vineyardId: UUID, since: Date?) async throws -> [BackendPruningSeason]
    func fetchEntries(vineyardId: UUID, since: Date?) async throws -> [BackendPruningEntry]
    /// Completed quarters are always fetched in full — they are the single
    /// source of truth for progress and re-attribution must see everything.
    func fetchSegments(vineyardId: UUID) async throws -> [BackendPruningSegment]
    func upsertSeasons(_ items: [BackendPruningSeasonUpsert]) async throws
    /// Records (or idempotently replays) an entry through `record_pruning_entry`.
    /// The result carries the CANONICAL season the server resolved from the
    /// entry date (sql/161) — callers must adopt it.
    func recordEntry(_ params: RecordPruningEntryParams) async throws -> RecordPruningEntryResult
    /// Transaction-safe edit through `update_pruning_entry` (sql/120) — the
    /// ONLY way an existing entry, its quarters and totals change.
    func updateEntry(_ params: UpdatePruningEntryParams) async throws -> UpdatePruningEntryResult
    /// Marks rows or row sections OUT OF PRUNING ROTATION through
    /// `record_skipped_pruning_entry` (sql/168). Same season resolution, same
    /// segment claim, same idempotency on the client id — the record simply
    /// has no worker, hours, cost or Work Task to give.
    func recordSkippedEntry(_ params: RecordSkippedPruningEntryParams) async throws -> RecordPruningEntryResult
    /// Edits the date or section selection of an existing skipped record
    /// through `update_skipped_pruning_entry` (sql/168).
    func updateSkippedEntry(_ params: UpdateSkippedPruningEntryParams) async throws -> UpdatePruningEntryResult
    /// Reversal is the SAME path for both kinds of record — there is no
    /// separate un-skip operation.
    func deleteEntry(id: UUID) async throws
    /// Creates a multi-block pruning ACTIVITY through `record_pruning_activity`
    /// (sql/166). Idempotent on the client activity id; a failed allocation
    /// rolls the whole activity back server-side.
    func recordActivity(_ params: RecordPruningActivityParams) async throws -> PruningActivityResult
    /// Full desired state of an existing activity — adds a block, removes a
    /// block, changes rows/quarters, changes the date (re-resolving EVERY
    /// allocation's season) or changes labour without touching allocations.
    func updateActivity(_ params: UpdatePruningActivityParams) async throws -> PruningActivityResult
    /// Reverses the parent activity as ONE operation; every allocation inherits it.
    func reverseActivity(id: UUID, reason: String?) async throws -> PruningActivityResult
    /// Canonical read-back of one activity with all its allocations.
    func fetchActivity(id: UUID) async throws -> BackendPruningActivityCanonical
    /// Every activity of the vineyard with all its allocations
    /// (`list_pruning_activities`) — one element per PARENT record, which is
    /// what the Tracker history and the mobile Activity Report render.
    func fetchActivities(vineyardId: UUID) async throws -> [BackendPruningActivityCanonical]
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

    func recordEntry(_ params: RecordPruningEntryParams) async throws -> RecordPruningEntryResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("record_pruning_entry", params: params)
            .execute()
            .value
    }

    func updateEntry(_ params: UpdatePruningEntryParams) async throws -> UpdatePruningEntryResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("update_pruning_entry", params: params)
            .execute()
            .value
    }

    func recordSkippedEntry(_ params: RecordSkippedPruningEntryParams) async throws -> RecordPruningEntryResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("record_skipped_pruning_entry", params: params)
            .execute()
            .value
    }

    func updateSkippedEntry(_ params: UpdateSkippedPruningEntryParams) async throws -> UpdatePruningEntryResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("update_skipped_pruning_entry", params: params)
            .execute()
            .value
    }

    func deleteEntry(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("delete_pruning_entry", params: PruningIdRequest(id: id)).execute()
    }

    func recordActivity(_ params: RecordPruningActivityParams) async throws -> PruningActivityResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("record_pruning_activity", params: params)
            .execute()
            .value
    }

    func updateActivity(_ params: UpdatePruningActivityParams) async throws -> PruningActivityResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("update_pruning_activity", params: params)
            .execute()
            .value
    }

    func reverseActivity(id: UUID, reason: String? = nil) async throws -> PruningActivityResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("reverse_pruning_activity", params: ReversePruningActivityParams(activityId: id, reason: reason))
            .execute()
            .value
    }

    func fetchActivity(id: UUID) async throws -> BackendPruningActivityCanonical {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("get_pruning_activity", params: PruningActivityIdParams(activityId: id))
            .execute()
            .value
    }

    func fetchActivities(vineyardId: UUID) async throws -> [BackendPruningActivityCanonical] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("list_pruning_activities", params: ListPruningActivitiesParams(vineyardId: vineyardId))
            .execute()
            .value
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
