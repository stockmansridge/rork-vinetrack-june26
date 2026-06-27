import Foundation

protocol PaddockSyncRepositoryProtocol: Sendable {
    func fetchPaddocks(vineyardId: UUID, since: Date?) async throws -> [BackendPaddock]
    func fetchAllPaddocks(vineyardId: UUID) async throws -> [BackendPaddock]
    /// Fetch every non-deleted paddock the current user can see across all
    /// vineyards (RLS gates the result). Used by the admin trip audit tool to
    /// resolve `paddock_id` -> `vineyard_id` across vineyards.
    func fetchAllAccessiblePaddocks() async throws -> [BackendPaddock]
    /// Lightweight reconciliation fetch: returns id + deleted_at for every
    /// paddock row currently in Supabase for the given vineyard. Used to
    /// detect hard-deletes (rows that no longer exist remotely) which the
    /// incremental `fetchPaddocks(since:)` pull cannot surface.
    func fetchPaddockIds(vineyardId: UUID) async throws -> [BackendPaddockIdRow]
    func upsertPaddock(_ paddock: BackendPaddockUpsert) async throws
    func upsertPaddocks(_ paddocks: [BackendPaddockUpsert]) async throws
    func softDeletePaddock(id: UUID) async throws
    /// Returns active-row reference counts for the paddock across every
    /// linked table. Used to decide whether a permanent delete is safe.
    func paddockReferenceCounts(id: UUID) async throws -> PaddockReferenceCounts
    /// Permanently deletes a paddock. Server enforces that
    /// `total_references == 0`.
    func hardDeletePaddock(id: UUID) async throws
    /// Clears `deleted_at` on a soft-deleted paddock.
    func restorePaddock(id: UUID) async throws
}

nonisolated struct PaddockReferenceCounts: Decodable, Sendable, Equatable {
    let pins: Int
    let trips: Int
    let tripCostAllocations: Int
    let workTasks: Int
    let workTaskPaddocks: Int
    let damageRecords: Int
    let growthStageRecords: Int
    let sprayJobPaddocks: Int
    let paddockSoilProfiles: Int
    let totalReferences: Int

    enum CodingKeys: String, CodingKey {
        case pins
        case trips
        case tripCostAllocations  = "trip_cost_allocations"
        case workTasks            = "work_tasks"
        case workTaskPaddocks     = "work_task_paddocks"
        case damageRecords        = "damage_records"
        case growthStageRecords   = "growth_stage_records"
        case sprayJobPaddocks     = "spray_job_paddocks"
        case paddockSoilProfiles  = "paddock_soil_profiles"
        case totalReferences      = "total_references"
    }

    var isEmpty: Bool { totalReferences == 0 }

    /// Human-readable breakdown, omitting zero counts.
    var summaryLines: [String] {
        var lines: [String] = []
        func add(_ n: Int, _ singular: String, _ plural: String) {
            guard n > 0 else { return }
            lines.append("\(n) \(n == 1 ? singular : plural)")
        }
        add(pins,                "pin",                "pins")
        add(trips,               "trip",               "trips")
        add(tripCostAllocations, "trip cost allocation", "trip cost allocations")
        add(workTasks,           "work/task log",      "work/task logs")
        add(workTaskPaddocks,    "work-task link",     "work-task links")
        add(damageRecords,       "damage record",      "damage records")
        add(growthStageRecords,  "growth-stage record", "growth-stage records")
        add(sprayJobPaddocks,    "spray job link",     "spray job links")
        add(paddockSoilProfiles, "soil profile",       "soil profiles")
        return lines
    }
}

/// Lightweight row used by `fetchPaddockIds` for hard-delete reconciliation.
nonisolated struct BackendPaddockIdRow: Decodable, Sendable, Equatable {
    let id: UUID
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case deletedAt = "deleted_at"
    }
}
