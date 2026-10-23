import Foundation

/// Per-day, per-worker-type labour entry for a WorkTask.
/// Mirrors public.work_task_labour_lines on Supabase (sql/050).
nonisolated struct WorkTaskLabourLine: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var workTaskId: UUID
    var vineyardId: UUID
    var workDate: Date
    var operatorCategoryId: UUID?
    var workerType: String
    var workerCount: Int { didSet { if workerCount != oldValue { savedTotalHours = nil; savedTotalCost = nil } } }
    var hoursPerWorker: Double { didSet { if hoursPerWorker != oldValue { savedTotalHours = nil; savedTotalCost = nil } } }
    var hourlyRate: Double? { didSet { if hourlyRate != oldValue { savedTotalCost = nil } } }
    /// Read-only historical server totals; never sent in labour write payloads.
    var savedTotalHours: Double?
    var savedTotalCost: Double?
    var notes: String

    init(
        id: UUID = UUID(),
        workTaskId: UUID,
        vineyardId: UUID,
        workDate: Date = Date(),
        operatorCategoryId: UUID? = nil,
        workerType: String = "",
        workerCount: Int = 1,
        hoursPerWorker: Double = 0,
        hourlyRate: Double? = nil,
        notes: String = "",
        savedTotalHours: Double? = nil,
        savedTotalCost: Double? = nil
    ) {
        self.id = id
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.workDate = workDate
        self.operatorCategoryId = operatorCategoryId
        self.workerType = workerType
        self.workerCount = workerCount
        self.hoursPerWorker = hoursPerWorker
        self.hourlyRate = hourlyRate
        self.notes = notes
        self.savedTotalHours = savedTotalHours
        self.savedTotalCost = savedTotalCost
    }

    var totalHours: Double {
        savedTotalHours.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? (Double(workerCount) * hoursPerWorker)
    }

    var totalCost: Double {
        savedTotalCost.flatMap { $0.isFinite ? $0 : nil } ?? (totalHours * (hourlyRate ?? 0))
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, workTaskId, vineyardId, workDate
        case operatorCategoryId, workerType, workerCount
        case hoursPerWorker, hourlyRate, notes, savedTotalHours, savedTotalCost
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        workDate = try c.decodeIfPresent(Date.self, forKey: .workDate) ?? Date()
        operatorCategoryId = try c.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
        workerType = try c.decodeIfPresent(String.self, forKey: .workerType) ?? ""
        workerCount = try c.decodeIfPresent(Int.self, forKey: .workerCount) ?? 1
        hoursPerWorker = try c.decodeIfPresent(Double.self, forKey: .hoursPerWorker) ?? 0
        hourlyRate = try c.decodeIfPresent(Double.self, forKey: .hourlyRate)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        savedTotalHours = try c.decodeIfPresent(Double.self, forKey: .savedTotalHours)
        savedTotalCost = try c.decodeIfPresent(Double.self, forKey: .savedTotalCost)
    }
}
