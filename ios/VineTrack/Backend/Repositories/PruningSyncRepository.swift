import Foundation
import Supabase

protocol PruningSyncRepositoryProtocol: Sendable {
    func fetchSeasons(vineyardId: UUID, since: Date?) async throws -> [BackendPruningSeason]
    func fetchEntries(vineyardId: UUID, since: Date?) async throws -> [BackendPruningEntry]
    /// Completed quarters are always fetched in full — they are the single
    /// source of truth for progress and re-attribution must see everything.
    func fetchSegments(vineyardId: UUID) async throws -> [BackendPruningSegment]
    /// Upserts ONE block season setup under the sql/198 revision contract.
    ///
    /// One request per season, deliberately: a multi-row upsert is a single transaction, so
    /// one REVISION_CONFLICT would abort the write of every other season in the batch and
    /// strand edits that were perfectly valid.
    ///
    /// Returns ``VersionedWriteOutcome/applied(_:)`` carrying the authoritative row (with its
    /// NEW `server_revision`), or ``VersionedWriteOutcome/conflict(rowId:baseRevision:serverRevision:)``.
    /// A conflict is NEVER thrown: a thrown conflict is classified as a transport failure and
    /// retried forever with the same stale `base_revision`, which can never succeed.
    func upsertSeason(
        _ setup: PruningBlockSetup,
        createdBy: UUID?,
        clientUpdatedAt: Date
    ) async throws -> VersionedWriteOutcome<PruningBlockSetup>
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
    /// DESIRED-STATE save of ALL labour lines of one pruning activity (sql/190).
    /// Lines present are upserted on their CLIENT id, lines absent are
    /// soft-deleted, and a re-sent soft-deleted line is restored — which is what
    /// makes replaying a queued offline edit idempotent.
    func saveActivityLabourLines(
        _ params: SavePruningActivityLabourLinesParams
    ) async throws -> SavePruningActivityLabourLinesResult
    /// Every pruning labour line of the vineyard, soft-deleted rows included so
    /// a delete made on another device is applied locally too.
    func fetchActivityLabourLines(vineyardId: UUID) async throws -> [BackendPruningActivityLabourLine]
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

    func upsertSeason(
        _ setup: PruningBlockSetup,
        createdBy: UUID?,
        clientUpdatedAt: Date
    ) async throws -> VersionedWriteOutcome<PruningBlockSetup> {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let payload = BackendPruningSeason.upsert(from: setup, createdBy: createdBy, clientUpdatedAt: clientUpdatedAt)
        do {
            // `.select()` asks for the representation back. It is NOT decoration: the response
            // body is the only place the new `server_revision` appears. Without it this device
            // could never learn what version its own edit became, would resend the previous
            // `base_revision` on the next edit, and would be refused forever.
            let response = try await provider.client
                .from("pruning_seasons")
                .upsert(payload, onConflict: "id")
                .select()
                .execute()
            // ONE shared classifier for every versioned entity. Retry policy hangs off this
            // decision, and a second hand-rolled copy is how a refused write eventually gets
            // reported as saved.
            return try VersionedWriteClassifier.classify(
                rowId: setup.id.uuidString,
                baseRevision: setup.serverRevision,
                status: response.status,
                body: String(data: response.data, encoding: .utf8)
            ) { text in
                guard let row = VersionedRepresentation.first(in: text) else { return nil }
                // The server accepted these values, so the row holds what was just sent; only
                // the server-issued revision is adopted from the response.
                var applied = setup
                applied.serverRevision = row.serverRevision
                return applied
            }
        } catch let error as VersionedWriteError {
            throw error
        } catch {
            // supabase-swift raises for a non-2xx, so a PT409 arrives here rather than as a
            // status. Routed through the SAME classifier so the SDK path and the raw-status
            // path cannot disagree about what a REVISION_CONFLICT means.
            if let outcome: VersionedWriteOutcome<PruningBlockSetup> = VersionedWriteClassifier.conflict(
                rowId: setup.id.uuidString,
                baseRevision: setup.serverRevision,
                from: error
            ) {
                return outcome
            }
            throw error
        }
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

    func saveActivityLabourLines(
        _ params: SavePruningActivityLabourLinesParams
    ) async throws -> SavePruningActivityLabourLinesResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("save_pruning_activity_labour_lines", params: params)
            .execute()
            .value
    }

    func fetchActivityLabourLines(vineyardId: UUID) async throws -> [BackendPruningActivityLabourLine] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        // The FULL vineyard slice, never an incremental cursor. Labour lines are
        // also written by the portal, per-vineyard volume is small, and the
        // local apply is a wholesale per-activity replace — so a full fetch is
        // both safe and self-healing.
        let data = try await provider.client
            .from("pruning_activity_labour_lines")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .order("line_index", ascending: true)
            .execute()
            .data
        // Per-row resilient decode — one malformed row must not break sync for
        // the rest of the vineyard's pruning labour.
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let decoder = JSONDecoder()
        var rows: [BackendPruningActivityLabourLine] = []
        rows.reserveCapacity(array.count)
        for row in array {
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                rows.append(try decoder.decode(BackendPruningActivityLabourLine.self, from: rowData))
            } catch {
                #if DEBUG
                print("[PruningLabourSync] decode failed id=\((row["id"] as? String) ?? "<unknown>") error=\(error)")
                #endif
            }
        }
        return rows
    }
}
