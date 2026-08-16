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
            // The plan's authoritative edit time is the CLIENT stamp when present: it is
            // what the next conflict comparison uses, so falling back to the server's
            // `updated_at` (which moves on every unrelated server-side touch) would make a
            // remote row look newer than the edit it actually represents.
            updatedAtEpochMs: Self.epoch(clientUpdatedAt) ?? Self.epoch(updatedAt) ?? 0,
            deletedAtEpochMs: Self.epoch(deletedAt)
        )
    }

    nonisolated static func epoch(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

/// Upsert payload. Server-owned columns (`created_at`, `updated_at`, `deleted_at`) are
/// deliberately absent: only the client's own edit stamp is sent, and it carries the plan's
/// real edit time so a late offline replay is honestly dated and correctly rejected by the
/// sql/185 stale-write guard.
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

    func upsert(_ plans: [ResistancePlan]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !plans.isEmpty else { return }
        let userId = currentUserId()
        let payload = plans.map { BackendResistancePlanUpsert(from: $0, createdBy: userId) }
        try await provider.client
            .from("resistance_plans")
            .upsert(payload, onConflict: "id")
            .execute()
    }

    func softDelete(planId: String) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_resistance_plan", params: ResistancePlanSoftDeleteRequest(pId: planId))
            .execute()
    }
}
