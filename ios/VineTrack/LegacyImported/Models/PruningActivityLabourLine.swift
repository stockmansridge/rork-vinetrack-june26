import Foundation

/// Per-day, per-worker-TYPE labour line belonging to a pruning ACTIVITY.
/// Mirrors `public.pruning_activity_labour_lines` on Supabase (sql/190), which
/// in turn mirrors `work_task_labour_lines` (sql/050) column for column.
///
/// Ownership rule this type carries (SQL 190 §2):
///
/// * Labour is **PRUNING-OWNED**. A linked Work Task never receives a copy —
///   it resolves *through* to these rows, so both objects report the SAME
///   number from the SAME record and summing the two modules counts the job
///   once.
/// * Labour belongs to the ACTIVITY and is counted ONCE no matter how many
///   blocks that activity covers. These lines are never apportioned to
///   allocations.
///
/// `id` is CLIENT-generated: it is the offline idempotency key, so replaying a
/// queued create can never duplicate a line.
nonisolated struct PruningActivityLabourLine: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var pruningActivityId: UUID
    var vineyardId: UUID
    var workDate: Date
    /// Optional link to the shared worker-type catalogue (`worker_type_id`).
    var operatorCategoryId: UUID?
    /// A worker CATEGORY ("Contractor"), never a person — same rule as SQL 050.
    var workerType: String
    var workerCount: Int
    var hoursPerWorker: Double
    /// nil means "no rate entered", which is NOT the same as a rate of zero.
    var hourlyRate: Double?
    var notes: String
    /// Stable display order within the activity. Never used for costing.
    var lineIndex: Int

    init(
        id: UUID = UUID(),
        pruningActivityId: UUID,
        vineyardId: UUID,
        workDate: Date = Date(),
        operatorCategoryId: UUID? = nil,
        workerType: String = "",
        workerCount: Int = 1,
        hoursPerWorker: Double = 0,
        hourlyRate: Double? = nil,
        notes: String = "",
        lineIndex: Int = 0
    ) {
        self.id = id
        self.pruningActivityId = pruningActivityId
        self.vineyardId = vineyardId
        self.workDate = workDate
        self.operatorCategoryId = operatorCategoryId
        self.workerType = workerType
        self.workerCount = workerCount
        self.hoursPerWorker = hoursPerWorker
        self.hourlyRate = hourlyRate
        self.notes = notes
        self.lineIndex = lineIndex
    }

    /// `worker_count × hours_per_worker` — the SQL generated `total_hours`.
    var totalHours: Double {
        Double(workerCount) * hoursPerWorker
    }

    /// The SQL generated `total_cost`, which uses `coalesce(hourly_rate, 0)`.
    ///
    /// - Warning: reads `0` on an UNRATED line. Never sum this directly — use
    ///   `PruningActivityLabourCosting.totalCost(_:)`, which skips unrated lines
    ///   so "nobody entered a rate" stays nil instead of becoming `$0.00`.
    var totalCost: Double {
        totalHours * (hourlyRate ?? 0)
    }

    /// True when this line carries a rate and therefore contributes to cost.
    var isRated: Bool {
        guard let hourlyRate, hourlyRate.isFinite else { return false }
        return true
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, pruningActivityId, vineyardId, workDate
        case operatorCategoryId, workerType, workerCount
        case hoursPerWorker, hourlyRate, notes, lineIndex
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pruningActivityId = try c.decode(UUID.self, forKey: .pruningActivityId)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        workDate = try c.decodeIfPresent(Date.self, forKey: .workDate) ?? Date()
        operatorCategoryId = try c.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
        workerType = try c.decodeIfPresent(String.self, forKey: .workerType) ?? ""
        workerCount = try c.decodeIfPresent(Int.self, forKey: .workerCount) ?? 1
        hoursPerWorker = try c.decodeIfPresent(Double.self, forKey: .hoursPerWorker) ?? 0
        hourlyRate = try c.decodeIfPresent(Double.self, forKey: .hourlyRate)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        lineIndex = try c.decodeIfPresent(Int.self, forKey: .lineIndex) ?? 0
    }
}
