import Foundation

// MARK: - Canonical activity payload (sql/166 `pruning_activity_json`)

/// The COMPLETE server state of a pruning activity: the parent, every block
/// allocation with its own canonical season and vintage, and the activity
/// totals.
///
/// DETAIL vs SUMMARY. `pruning_activity_json(id, p_include_segments)` serves two
/// shapes from the same contract:
///
/// * DETAIL — `get_pruning_activity` and every create/update/reverse response
///   pass `true`, so each allocation carries its full `segments` array. This is
///   the authoritative record for quarters, progress and the legacy projection.
/// * SUMMARY — `list_pruning_activities` passes `false`, so `segments` comes
///   back as JSON **null**. The allocation SET, block names, row numbers,
///   quarter COUNTS, row equivalents and vines are all still present; only the
///   per-quarter detail is withheld.
///
/// A null `segments` therefore means NOT SUPPLIED — never "this allocation has
/// no completed quarters". Collapsing the two is what silently zeroed the iOS
/// block and vineyard progress on every pull.
nonisolated struct BackendPruningActivityCanonical: Decodable, Sendable {
    nonisolated struct Activity: Decodable, Sendable {
        let id: UUID?
        let vineyardId: UUID?
        let entryDate: String?
        let workerOrCrew: String?
        let method: String?
        let startTime: Date?
        let finishTime: Date?
        let durationHours: Double?
        let labourHours: Double?
        let hourlyRate: Double?
        let labourCost: Double?
        let notes: String?
        let workTaskId: UUID?
        let seasonYear: Int?
        let vintageYear: Int?
        let isReversed: Bool?
        let reversedAt: Date?
        let createdBy: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case vineyardId = "vineyard_id"
            case entryDate = "entry_date"
            case workerOrCrew = "worker_or_crew"
            case method
            case startTime = "start_time"
            case finishTime = "finish_time"
            case durationHours = "duration_hours"
            case labourHours = "labour_hours"
            case hourlyRate = "hourly_rate"
            case labourCost = "labour_cost"
            case notes
            case workTaskId = "work_task_id"
            case seasonYear = "season_year"
            case vintageYear = "vintage_year"
            case isReversed = "is_reversed"
            case reversedAt = "reversed_at"
            case createdBy = "created_by"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    nonisolated struct Segment: Decodable, Sendable {
        let row: Int
        let segment: Int
        let rowId: UUID?
        let label: String?

        enum CodingKeys: String, CodingKey {
            case row
            case segment
            case rowId = "row_id"
            case label
        }
    }

    nonisolated struct Allocation: Decodable, Sendable, Identifiable {
        let id: UUID
        let allocationIndex: Int
        let paddockId: UUID
        let blockName: String
        let pruningSeasonId: UUID?
        let seasonYear: Int?
        let vintageYear: Int?
        let rows: [Int]
        let quarters: Int
        let rowEquivalents: Double
        let estimatedVines: Int
        let isReversed: Bool
        /// Nil when the response OMITTED the per-quarter detail (a summary
        /// feed); an empty array when the server positively stated this
        /// allocation owns no quarters. The two must never be conflated.
        let segments: [Segment]?

        /// True only when this allocation's per-quarter detail was supplied and
        /// may be adopted as authoritative.
        var hasSegmentDetail: Bool { segments != nil }

        enum CodingKeys: String, CodingKey {
            case id
            case allocationIndex = "allocation_index"
            case paddockId = "paddock_id"
            case blockName = "block_name"
            case pruningSeasonId = "pruning_season_id"
            case seasonYear = "season_year"
            case vintageYear = "vintage_year"
            case rows
            case quarters
            case rowEquivalents = "row_equivalents"
            case estimatedVines = "estimated_vines"
            case isReversed = "is_reversed"
            case segments
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            allocationIndex = try c.decodeIfPresent(Int.self, forKey: .allocationIndex) ?? 0
            paddockId = try c.decode(UUID.self, forKey: .paddockId)
            blockName = try c.decodeIfPresent(String.self, forKey: .blockName) ?? ""
            pruningSeasonId = try c.decodeIfPresent(UUID.self, forKey: .pruningSeasonId)
            seasonYear = try c.decodeIfPresent(Int.self, forKey: .seasonYear)
            vintageYear = try c.decodeIfPresent(Int.self, forKey: .vintageYear)
            rows = try c.decodeIfPresent([Int].self, forKey: .rows) ?? []
            quarters = try c.decodeIfPresent(Int.self, forKey: .quarters) ?? 0
            rowEquivalents = try c.decodeIfPresent(Double.self, forKey: .rowEquivalents) ?? 0
            estimatedVines = try c.decodeIfPresent(Int.self, forKey: .estimatedVines) ?? 0
            isReversed = try c.decodeIfPresent(Bool.self, forKey: .isReversed) ?? false
            // decodeIfPresent maps BOTH an absent key and an explicit null to
            // nil, which is exactly the "not supplied" signal required here.
            // It must never be defaulted to [].
            segments = try c.decodeIfPresent([Segment].self, forKey: .segments)
        }
    }

    /// Activity totals. `labourHours` / `hourlyRate` / `labourCost` are the
    /// SHARED values, counted once for the whole activity.
    nonisolated struct Totals: Decodable, Sendable {
        let allocationCount: Int
        let blockSummary: String
        let quarters: Int
        let rowEquivalents: Double
        let estimatedVines: Int
        let labourHours: Double?
        let hourlyRate: Double?
        let labourCost: Double?

        enum CodingKeys: String, CodingKey {
            case allocationCount = "allocation_count"
            case blockSummary = "block_summary"
            case quarters
            case rowEquivalents = "row_equivalents"
            case estimatedVines = "estimated_vines"
            case labourHours = "labour_hours"
            case hourlyRate = "hourly_rate"
            case labourCost = "labour_cost"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            allocationCount = try c.decodeIfPresent(Int.self, forKey: .allocationCount) ?? 0
            blockSummary = try c.decodeIfPresent(String.self, forKey: .blockSummary) ?? ""
            quarters = try c.decodeIfPresent(Int.self, forKey: .quarters) ?? 0
            rowEquivalents = try c.decodeIfPresent(Double.self, forKey: .rowEquivalents) ?? 0
            estimatedVines = try c.decodeIfPresent(Int.self, forKey: .estimatedVines) ?? 0
            labourHours = try c.decodeIfPresent(Double.self, forKey: .labourHours)
            hourlyRate = try c.decodeIfPresent(Double.self, forKey: .hourlyRate)
            labourCost = try c.decodeIfPresent(Double.self, forKey: .labourCost)
        }
    }

    let activity: Activity?
    let allocations: [Allocation]
    let totals: Totals?

    /// True when EVERY allocation carried its per-quarter detail — a
    /// `get_pruning_activity` / create / update response, safe to adopt as the
    /// authoritative detailed record.
    ///
    /// A parent with no allocations counts as detailed: there is no withheld
    /// detail to wait for.
    var hasSegmentDetail: Bool { allocations.allSatisfy(\.hasSegmentDetail) }

    /// True when at least one allocation's detail was withheld. Such a response
    /// may refresh parent metadata but must NEVER replace segments.
    var isSummaryOnly: Bool { !hasSegmentDetail }

    enum CodingKeys: String, CodingKey {
        case activity
        case allocations
        case totals
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activity = try c.decodeIfPresent(Activity.self, forKey: .activity)
        allocations = try c.decodeIfPresent([Allocation].self, forKey: .allocations) ?? []
        totals = try c.decodeIfPresent(Totals.self, forKey: .totals)
    }
}

// MARK: - RPC parameters

/// ACTIVITY-level payload. Labour, timing, rate, notes and the Work Task link
/// appear here EXACTLY ONCE and are never repeated per block.
///
/// Every key is encoded explicitly (nils as JSON null): PostgREST resolves RPCs
/// by the exact argument set, and `update_pruning_activity` distinguishes an
/// absent key ("leave unchanged") from an explicit null ("clear it"), so a
/// full-desired-state edit must always send them all.
nonisolated struct PruningActivityPayload: Encodable, Sendable {
    let entryDate: String
    let workerOrCrew: String
    let method: String
    let startTime: Date?
    let finishTime: Date?
    let labourHours: Double?
    let hourlyRate: Double?
    let notes: String
    let workTaskId: UUID?
    /// True explicitly unlinks the Work Task server-side.
    let clearWorkTask: Bool

    enum CodingKeys: String, CodingKey {
        case entryDate = "entry_date"
        case workerOrCrew = "worker_or_crew"
        case method
        case startTime = "start_time"
        case finishTime = "finish_time"
        case labourHours = "labour_hours"
        case hourlyRate = "hourly_rate"
        case notes
        case workTaskId = "work_task_id"
        case clearWorkTask = "clear_work_task"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entryDate, forKey: .entryDate)
        try c.encode(workerOrCrew, forKey: .workerOrCrew)
        try c.encode(method, forKey: .method)
        if let startTime { try c.encode(startTime, forKey: .startTime) } else { try c.encodeNil(forKey: .startTime) }
        if let finishTime { try c.encode(finishTime, forKey: .finishTime) } else { try c.encodeNil(forKey: .finishTime) }
        if let labourHours { try c.encode(labourHours, forKey: .labourHours) } else { try c.encodeNil(forKey: .labourHours) }
        if let hourlyRate { try c.encode(hourlyRate, forKey: .hourlyRate) } else { try c.encodeNil(forKey: .hourlyRate) }
        try c.encode(notes, forKey: .notes)
        if let workTaskId { try c.encode(workTaskId, forKey: .workTaskId) } else { try c.encodeNil(forKey: .workTaskId) }
        try c.encode(clearWorkTask, forKey: .clearWorkTask)
    }

    init(from draft: PruningActivityDraft) {
        entryDate = PruningSyncDate.ymd(from: draft.date)
        workerOrCrew = draft.worker
        method = draft.method.rawValue
        startTime = draft.startTime
        finishTime = draft.finishTime
        labourHours = draft.labourHours
        hourlyRate = draft.hourlyRate
        notes = draft.notes
        workTaskId = draft.workTaskId
        // A nil link on a full-state edit means the link was removed.
        clearWorkTask = draft.workTaskId == nil
    }
}

/// ALLOCATION-level payload — one block, its own rows/quarters and vines.
/// Every segment belongs to an allocation that carries its own `paddock_id`.
nonisolated struct PruningAllocationPayload: Encodable, Sendable {
    typealias Segment = RecordPruningEntryParams.Segment

    let id: UUID
    let paddockId: UUID
    let segments: [Segment]
    let quarters: Int
    let estimatedVines: Int

    enum CodingKeys: String, CodingKey {
        case id
        case paddockId = "paddock_id"
        case segments
        case quarters
        case estimatedVines = "estimated_vines"
    }

    init(activityId: UUID, allocation: BlockPruningSelection) {
        id = allocation.allocationId(for: activityId)
        paddockId = allocation.paddockId
        segments = allocation.segments.map {
            Segment(row: $0.row, segment: $0.quarter, rowId: $0.rowId, label: "\($0.row)")
        }
        quarters = allocation.quarters
        estimatedVines = allocation.estimatedVines
    }
}

/// Parameters for `record_pruning_activity` (sql/166). Idempotent on the stable
/// client activity id: replaying the same draft can never create a second
/// parent or duplicate an allocation, and a failed allocation rolls the WHOLE
/// activity back server-side.
nonisolated struct RecordPruningActivityParams: Encodable, Sendable {
    let activityId: UUID
    let vineyardId: UUID
    let activity: PruningActivityPayload
    let allocations: [PruningAllocationPayload]
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case activityId = "p_activity_id"
        case vineyardId = "p_vineyard_id"
        case activity = "p_activity"
        case allocations = "p_allocations"
        case clientUpdatedAt = "p_client_updated_at"
    }

    init(from draft: PruningActivityDraft, clientUpdatedAt: Date) {
        activityId = draft.id
        vineyardId = draft.vineyardId
        activity = PruningActivityPayload(from: draft)
        allocations = draft.activeAllocations.map {
            PruningAllocationPayload(activityId: draft.id, allocation: $0)
        }
        self.clientUpdatedAt = clientUpdatedAt
    }
}

/// Parameters for `update_pruning_activity` (sql/166) — the FULL desired state:
/// adds a block, removes a block, changes rows/quarters, changes the date
/// (re-resolving EVERY allocation's season) or changes labour without touching
/// allocations. LWW on `clientUpdatedAt`, which must be the timestamp of the
/// EDIT, never the replay time.
nonisolated struct UpdatePruningActivityParams: Encodable, Sendable {
    let activityId: UUID
    let activity: PruningActivityPayload
    let allocations: [PruningAllocationPayload]
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case activityId = "p_activity_id"
        case activity = "p_activity"
        case allocations = "p_allocations"
        case clientUpdatedAt = "p_client_updated_at"
    }

    init(from draft: PruningActivityDraft, clientUpdatedAt: Date) {
        activityId = draft.id
        activity = PruningActivityPayload(from: draft)
        allocations = draft.activeAllocations.map {
            PruningAllocationPayload(activityId: draft.id, allocation: $0)
        }
        self.clientUpdatedAt = clientUpdatedAt
    }
}

/// Parameters for `reverse_pruning_activity` — the whole activity, ONE
/// operation. Every allocation inherits the reversal.
nonisolated struct ReversePruningActivityParams: Encodable, Sendable {
    let activityId: UUID
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case activityId = "p_activity_id"
        case reason = "p_reason"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(activityId, forKey: .activityId)
        if let reason { try c.encode(reason, forKey: .reason) } else { try c.encodeNil(forKey: .reason) }
    }
}

nonisolated struct PruningActivityIdParams: Encodable, Sendable {
    let activityId: UUID

    enum CodingKeys: String, CodingKey {
        case activityId = "p_activity_id"
    }
}

/// Parameters for `list_pruning_activities` — one element per PARENT activity,
/// reversed records included so the report keeps its audit trail.
nonisolated struct ListPruningActivitiesParams: Encodable, Sendable {
    let vineyardId: UUID
    var includeReversed: Bool = true
    var limit: Int = 500

    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case includeReversed = "p_include_reversed"
        case limit = "p_limit"
    }
}

// MARK: - RPC result

/// Structured response of every activity RPC (sql/166). `canonical` is the
/// COMPLETE server state the client adopts wholesale.
nonisolated struct PruningActivityResult: Decodable, Sendable {
    nonisolated struct Conflict: Decodable, Sendable {
        let paddockId: UUID?
        let row: Int?
        let segment: Int?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case paddockId = "paddock_id"
            case row
            case segment
            case reason
        }
    }

    nonisolated struct AllocationOutcome: Decodable, Sendable {
        let allocationId: UUID?
        let paddockId: UUID?
        let allocationIndex: Int?
        let pruningSeasonId: UUID?
        let seasonYear: Int?
        let vintageYear: Int?
        let seasonChanged: Bool?
        let requested: Int?
        let attributed: Int?
        let removed: Int?
        let duplicatesRemoved: Int?
        let conflicts: [Conflict]?

        enum CodingKeys: String, CodingKey {
            case allocationId = "allocation_id"
            case paddockId = "paddock_id"
            case allocationIndex = "allocation_index"
            case pruningSeasonId = "pruning_season_id"
            case seasonYear = "season_year"
            case vintageYear = "vintage_year"
            case seasonChanged = "season_changed"
            case requested
            case attributed
            case removed
            case duplicatesRemoved = "duplicates_removed"
            case conflicts
        }
    }

    nonisolated struct RemovedAllocation: Decodable, Sendable {
        let allocationId: UUID?
        let paddockId: UUID?

        enum CodingKeys: String, CodingKey {
            case allocationId = "allocation_id"
            case paddockId = "paddock_id"
        }
    }

    let activityId: UUID?
    let created: Bool?
    let reversed: Bool?
    let alreadyReversed: Bool?
    let allocationsReversed: Int?
    let quartersReleased: Int?
    let allocationResults: [AllocationOutcome]?
    let removedAllocations: [RemovedAllocation]?
    let conflicts: [Conflict]?
    let workTaskConflict: Bool?
    /// "activity_not_found" (the create hasn't landed — retry) or
    /// "activity_reversed" (drop the edit).
    let error: String?
    /// True when a newer edit already applied — this edit is obsolete.
    let stale: Bool?
    let canonical: BackendPruningActivityCanonical?

    enum CodingKeys: String, CodingKey {
        case activityId = "activity_id"
        case created
        case reversed
        case alreadyReversed = "already_reversed"
        case allocationsReversed = "allocations_reversed"
        case quartersReleased = "quarters_released"
        case allocationResults = "allocation_results"
        case removedAllocations = "removed_allocations"
        case conflicts
        case workTaskConflict = "work_task_conflict"
        case error
        case stale
        case canonical
    }
}
