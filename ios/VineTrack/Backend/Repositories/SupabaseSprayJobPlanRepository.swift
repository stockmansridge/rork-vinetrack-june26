import Foundation
import Supabase

/// Reads and creates `spray_jobs` rows linked to resistance plans (sql/201).
///
/// Distinct from `SupabaseSprayJobTemplateRepository` (read-only templates,
/// `is_template = true`): this repository handles PLANNED jobs created from
/// resistance plan positions. Creation is idempotent — the client mints the
/// job UUID, so a duplicate-key rejection on replay means "already synced".
final class SupabaseSprayJobPlanRepository {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    var isConfigured: Bool { provider.isConfigured }

    /// Live (non-archived) jobs linked to a plan, oldest first. Filtered by
    /// vineyard as well so a cross-vineyard link can never surface — the same
    /// vineyard-equality rule the sql/201 resolution functions apply.
    func fetchJobs(vineyardId: UUID, planId: String) async throws -> [BackendPlanSprayJob] {
        try await provider.client
            .from("spray_jobs")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .eq("resistance_plan_id", value: planId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Inserts the job and its paddock links. Safe to replay: a duplicate job
    /// insert is treated as already-synced, and paddock links upsert with
    /// duplicates ignored.
    func createJob(_ payload: BackendPlanSprayJobInsert, paddockIds: [UUID]) async throws {
        do {
            try await provider.client
                .from("spray_jobs")
                .insert(payload)
                .execute()
        } catch {
            guard Self.isDuplicate(error) else { throw error }
        }

        guard !paddockIds.isEmpty else { return }
        let links = paddockIds.map { SprayJobPaddockLinkInsert(sprayJobId: payload.id, paddockId: $0) }
        try await provider.client
            .from("spray_job_paddocks")
            .upsert(links, onConflict: "spray_job_id,paddock_id", ignoreDuplicates: true)
            .execute()
    }

    private static func isDuplicate(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("23505") || text.contains("duplicate key")
    }
}

/// One `spray_job_paddocks` join row (proposed coverage for derived progress).
nonisolated struct SprayJobPaddockLinkInsert: Codable, Sendable {
    let sprayJobId: UUID
    let paddockId: UUID

    nonisolated enum CodingKeys: String, CodingKey {
        case sprayJobId = "spray_job_id"
        case paddockId = "paddock_id"
    }
}
