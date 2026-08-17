import Foundation
import Supabase

/// The `public.resistance_plans` row shape (sql/196).
///
/// A FLAT projection of the plan: the ordered `positions` document goes across as JSONB
/// exactly as both clients serialise it, and every other field is a column. Column names
/// match the domain model's wire keys, so the row and the document never disagree about
/// what a field is called.
///
/// Epoch milliseconds are converted to ISO-8601 at this boundary and nowhere else — the
/// domain model stays in epoch ms on both platforms so plan arithmetic never depends on a
/// timezone.
nonisolated struct BackendResistancePlan: Codable, Sendable {
    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case seasonId = "season_id"
        case seasonStartYear = "season_start_year"
        case disease
        case jurisdiction
        case crop
        case blockIds = "block_ids"
        case positions
        case notes
        case rulesetId = "ruleset_id"
        case rulesetVersion = "ruleset_version"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case serverRevision = "server_revision"
    }

    nonisolated var id: String
    nonisolated var vineyardId: String
    nonisolated var seasonId: String
    nonisolated var seasonStartYear: Int?
    nonisolated var disease: String
    nonisolated var jurisdiction: String
    nonisolated var crop: String
    nonisolated var blockIds: [String]?
    nonisolated var positions: [ResistancePlannedPosition]
    nonisolated var notes: String?
    nonisolated var rulesetId: String?
    nonisolated var rulesetVersion: String?
    nonisolated var createdBy: String?
    nonisolated var createdAt: Date?
    nonisolated var updatedAt: Date?
    nonisolated var deletedAt: Date?
    nonisolated var clientUpdatedAt: Date?
    /// Server-issued revision (sql/198). Optional for tolerance, not because the column is:
    /// a row from a path that did not project it, or a response from a pre-198 environment,
    /// must decode rather than throw.
    nonisolated var serverRevision: Int64?

    nonisolated func toPlan() -> ResistancePlan {
        ResistancePlan(
            id: id,
            vineyardId: vineyardId,
            seasonId: seasonId,
            seasonStartYear: seasonStartYear ?? Int(seasonId.prefix(4)) ?? 0,
            disease: ResistanceDisease(rawValue: disease) ?? .powderyMildew,
            jurisdiction: ResistanceJurisdiction(rawValue: jurisdiction) ?? .unknown,
            crop: ResistanceCrop(rawValue: crop) ?? .grape,
            blockIds: blockIds ?? [],
            positions: positions,
            notes: notes,
            rulesetId: rulesetId,
            rulesetVersion: rulesetVersion,
            createdBy: createdBy,
            createdAtEpochMs: Self.epoch(createdAt) ?? 0,
            // The grower's edit time, for display and ordering in the list. No longer a
            // concurrency signal — `serverRevision` is.
            updatedAtEpochMs: Self.epoch(clientUpdatedAt) ?? Self.epoch(updatedAt) ?? 0,
            deletedAtEpochMs: Self.epoch(deletedAt),
            serverRevision: serverRevision
        )
    }

    nonisolated static func epoch(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

/// Upsert payload.
///
/// Server-owned columns (`created_at`, `updated_at`, `deleted_at`, `server_revision`) are
/// deliberately absent. Two fields carry timing/version information and they do different
/// jobs — conflating them is the bug sql/198 exists to remove:
///
///   * `base_revision` — the `server_revision` this edit was based on. THE CONCURRENCY
///     AUTHORITY. Sent only for a plan the server has already issued a revision for.
///   * `client_updated_at` — when the grower edited. Metadata for display and audit. Still
///     sent (the legacy trigger path needs it) but it no longer decides anything, and the
///     server now clamps it to `now()` so a fast device clock cannot lock other writers out.
nonisolated struct BackendResistancePlanUpsert: Encodable, Sendable {
    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case seasonId = "season_id"
        case seasonStartYear = "season_start_year"
        case disease
        case jurisdiction
        case crop
        case blockIds = "block_ids"
        case positions
        case notes
        case rulesetId = "ruleset_id"
        case rulesetVersion = "ruleset_version"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
        case baseRevision = "base_revision"
    }

    nonisolated var id: String
    nonisolated var vineyardId: String
    nonisolated var seasonId: String
    nonisolated var seasonStartYear: Int?
    nonisolated var disease: String
    nonisolated var jurisdiction: String
    nonisolated var crop: String
    nonisolated var blockIds: [String]?
    nonisolated var positions: [ResistancePlannedPosition]
    nonisolated var notes: String?
    nonisolated var rulesetId: String?
    nonisolated var rulesetVersion: String?
    nonisolated var createdBy: String?
    nonisolated var clientUpdatedAt: Date
    /// The version this edit was based on, or nil for a plan the server has never seen.
    ///
    /// Nil is meaningful, not missing: sql/198 reads an absent `base_revision` as a create.
    /// Inventing a number here (0, or 1, or "probably 1") would assert a version this device
    /// never read, and would either be refused forever or match by luck and overwrite an
    /// edit nobody here has seen.
    nonisolated var baseRevision: Int64?

    nonisolated init(from plan: ResistancePlan, createdBy fallbackCreatedBy: String?) {
        self.id = plan.id
        self.vineyardId = plan.vineyardId
        self.seasonId = plan.seasonId
        self.seasonStartYear = plan.seasonStartYear
        self.disease = plan.disease.rawValue
        self.jurisdiction = plan.jurisdiction.rawValue
        self.crop = plan.crop.rawValue
        self.blockIds = plan.blockIds.isEmpty ? nil : plan.blockIds
        self.positions = plan.positions
        self.notes = plan.notes
        self.rulesetId = plan.rulesetId
        self.rulesetVersion = plan.rulesetVersion
        self.createdBy = plan.createdBy ?? fallbackCreatedBy
        self.clientUpdatedAt = Date(timeIntervalSince1970: Double(plan.updatedAtEpochMs) / 1000)
        self.baseRevision = plan.serverRevision
    }

    /// Explicit encoding so `base_revision` is OMITTED rather than sent as JSON null when
    /// this device has no revision.
    ///
    /// The distinction matters under `merge-duplicates`: an omitted column keeps its stored
    /// value, while an explicit null would write null. sql/198 stores `base_revision` as null
    /// anyway, so both happen to be safe today — but relying on that would make this payload
    /// silently wrong the moment the column's semantics change.
    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(seasonId, forKey: .seasonId)
        try c.encodeIfPresent(seasonStartYear, forKey: .seasonStartYear)
        try c.encode(disease, forKey: .disease)
        try c.encode(jurisdiction, forKey: .jurisdiction)
        try c.encode(crop, forKey: .crop)
        try c.encodeIfPresent(blockIds, forKey: .blockIds)
        try c.encode(positions, forKey: .positions)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(rulesetId, forKey: .rulesetId)
        try c.encodeIfPresent(rulesetVersion, forKey: .rulesetVersion)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
        try c.encodeIfPresent(baseRevision, forKey: .baseRevision)
    }
}

private nonisolated struct ResistancePlanSoftDeleteRequest: Encodable, Sendable {
    nonisolated let pId: String
    nonisolated enum CodingKeys: String, CodingKey { case pId = "p_id" }
}

/// Supabase implementation of `ResistancePlanRemote` against `public.resistance_plans`
/// (sql/196). Mirrors `SupabaseResistancePlanRemote.kt` on Android.
final class SupabaseResistancePlanRepository: ResistancePlanRemote {
    private let provider: SupabaseClientProvider
    private let currentUserId: @Sendable () -> String?

    init(
        provider: SupabaseClientProvider = .shared,
        currentUserId: @escaping @Sendable () -> String? = { nil }
    ) {
        self.provider = provider
        self.currentUserId = currentUserId
    }

    func fetchAll(vineyardId: String) async throws -> [ResistancePlan] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        // Tombstones included on purpose — see `ResistancePlanRemote.fetchAll`. A delete
        // performed elsewhere is only observable here as a tombstone arriving in a pull.
        let rows: [BackendResistancePlan] = try await provider.client
            .from("resistance_plans")
            .select()
            .eq("vineyard_id", value: vineyardId)
            .order("updated_at", ascending: true)
            .execute()
            .value
        return rows.map { $0.toPlan() }
    }

    /// One request PER PLAN, deliberately.
    ///
    /// A multi-row upsert is a single transaction, so one REVISION_CONFLICT would abort the
    /// write of every other plan in the batch — edits that were perfectly valid would be
    /// stranded because an unrelated plan lost a race. Plans are a handful per vineyard per
    /// season, so the extra round trips cost little and buy per-row conflict isolation.
    func upsert(_ plans: [ResistancePlan]) async throws -> [VersionedWriteOutcome<ResistancePlan>] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !plans.isEmpty else { return [] }
        let userId = currentUserId()
        var outcomes: [VersionedWriteOutcome<ResistancePlan>] = []
        for plan in plans {
            outcomes.append(try await write(plan, createdBy: userId))
        }
        return outcomes
    }

    private func write(
        _ plan: ResistancePlan,
        createdBy userId: String?
    ) async throws -> VersionedWriteOutcome<ResistancePlan> {
        let payload = BackendResistancePlanUpsert(from: plan, createdBy: userId)
        do {
            // `.select()` asks for the representation back. It is NOT decoration: the
            // response body is the only place the new `server_revision` appears. Without it
            // this device could never learn what version its own edit became, would resend
            // the previous `base_revision` on the next edit, and would be refused forever.
            let rows: [BackendResistancePlan] = try await provider.client
                .from("resistance_plans")
                .upsert(payload, onConflict: "id")
                .select()
                .execute()
                .value
            guard let row = rows.first else {
                // A success with NO row is the legacy silent-skip signature (a BEFORE UPDATE
                // trigger returning NULL). Under sql/198 a versioned write cannot land here
                // — it raises instead — but an old-path write still can, and reporting it as
                // success is precisely the bug that lost growers' edits. Surfaced as a
                // conflict so the local copy is kept.
                return .conflict(rowId: plan.id, baseRevision: plan.serverRevision, serverRevision: nil)
            }
            return .applied(row.toPlan())
        } catch {
            guard SyncRevisionContract.isRevisionConflict(error) else { throw error }
            return .conflict(
                rowId: plan.id,
                baseRevision: SyncRevisionContract.baseRevision(from: error) ?? plan.serverRevision,
                serverRevision: SyncRevisionContract.serverRevision(from: error)
            )
        }
    }

    func softDelete(planId: String) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_resistance_plan", params: ResistancePlanSoftDeleteRequest(pId: planId))
            .execute()
    }
}
