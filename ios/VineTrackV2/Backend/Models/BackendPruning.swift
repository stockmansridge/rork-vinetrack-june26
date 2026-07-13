import Foundation

/// Date helpers for `date`-typed Postgres columns (plain "yyyy-MM-dd" strings).
nonisolated enum PruningSyncDate {
    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func ymd(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(fromYmd value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return formatter().date(from: String(value.prefix(10)))
    }
}

// MARK: - pruning_seasons

nonisolated struct BackendPruningSeason: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let seasonYear: Int
    let startDate: String?
    let dueDate: String?
    let pruningMethod: String?
    let assignedCrew: String?
    let workingDays: [Int]?
    let manualRowCount: Int?
    let estimatedLabourHours: Double?
    let notes: String?
    let status: String?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case seasonYear = "season_year"
        case startDate = "start_date"
        case dueDate = "due_date"
        case pruningMethod = "pruning_method"
        case assignedCrew = "assigned_crew"
        case workingDays = "working_days"
        case manualRowCount = "manual_row_count"
        case estimatedLabourHours = "estimated_labour_hours"
        case notes
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendPruningSeasonUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let seasonYear: Int
    let startDate: String?
    let dueDate: String?
    let pruningMethod: String
    let assignedCrew: String
    let workingDays: [Int]
    let manualRowCount: Int?
    let estimatedLabourHours: Double?
    let notes: String
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case seasonYear = "season_year"
        case startDate = "start_date"
        case dueDate = "due_date"
        case pruningMethod = "pruning_method"
        case assignedCrew = "assigned_crew"
        case workingDays = "working_days"
        case manualRowCount = "manual_row_count"
        case estimatedLabourHours = "estimated_labour_hours"
        case notes
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendPruningSeason {
    static func upsert(from setup: PruningBlockSetup, createdBy: UUID?, clientUpdatedAt: Date) -> BackendPruningSeasonUpsert {
        BackendPruningSeasonUpsert(
            id: setup.id,
            vineyardId: setup.vineyardId,
            paddockId: setup.paddockId,
            seasonYear: setup.seasonYear,
            startDate: setup.startDate.map { PruningSyncDate.ymd(from: $0) },
            dueDate: setup.dueDate.map { PruningSyncDate.ymd(from: $0) },
            pruningMethod: setup.method.rawValue,
            assignedCrew: setup.crew,
            workingDays: setup.workingDays,
            manualRowCount: setup.rowCountOverride,
            estimatedLabourHours: setup.estimatedLabourHours,
            notes: setup.notes,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toPruningBlockSetup() -> PruningBlockSetup {
        PruningBlockSetup(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddockId,
            seasonYear: seasonYear,
            startDate: PruningSyncDate.date(fromYmd: startDate),
            dueDate: PruningSyncDate.date(fromYmd: dueDate),
            method: PruningMethod(rawValue: pruningMethod ?? "") ?? .spur,
            crew: assignedCrew ?? "",
            workingDays: workingDays ?? [1, 2, 3, 4, 5],
            rowCountOverride: manualRowCount,
            estimatedLabourHours: estimatedLabourHours,
            notes: notes ?? ""
        )
    }
}

// MARK: - pruning_entries

nonisolated struct BackendPruningEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let pruningSeasonId: UUID
    let paddockId: UUID
    let entryDate: String?
    let workerOrCrew: String?
    let labourHours: Double?
    let startTime: Date?
    let finishTime: Date?
    let pruningMethod: String?
    let notes: String?
    let rowEquivalentsCompleted: Double?
    let estimatedVinesCompleted: Int?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case pruningSeasonId = "pruning_season_id"
        case paddockId = "paddock_id"
        case entryDate = "entry_date"
        case workerOrCrew = "worker_or_crew"
        case labourHours = "labour_hours"
        case startTime = "start_time"
        case finishTime = "finish_time"
        case pruningMethod = "pruning_method"
        case notes
        case rowEquivalentsCompleted = "row_equivalents_completed"
        case estimatedVinesCompleted = "estimated_vines_completed"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    /// Segments are attributed separately from `pruning_row_segments`.
    func toPruningEntry() -> PruningEntry {
        PruningEntry(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddockId,
            seasonId: pruningSeasonId,
            date: PruningSyncDate.date(fromYmd: entryDate) ?? createdAt ?? Date(),
            segments: [],
            worker: workerOrCrew ?? "",
            labourHours: labourHours,
            startTime: startTime,
            finishTime: finishTime,
            method: PruningMethod(rawValue: pruningMethod ?? "") ?? .spur,
            notes: notes ?? "",
            estimatedVines: estimatedVinesCompleted ?? 0,
            createdAt: createdAt ?? Date()
        )
    }
}

/// Parameters for the idempotent `record_pruning_entry` RPC.
nonisolated struct RecordPruningEntryParams: Encodable, Sendable {
    nonisolated struct Segment: Encodable, Sendable {
        let row: Int
        let segment: Int
    }

    let id: UUID
    let vineyardId: UUID
    let seasonId: UUID
    let paddockId: UUID
    let seasonYear: Int
    let entryDate: String
    let worker: String
    let labourHours: Double?
    let startTime: Date?
    let finishTime: Date?
    let method: String
    let notes: String
    let estimatedVines: Int
    let clientUpdatedAt: Date
    let segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case vineyardId = "p_vineyard_id"
        case seasonId = "p_season_id"
        case paddockId = "p_paddock_id"
        case seasonYear = "p_season_year"
        case entryDate = "p_entry_date"
        case worker = "p_worker"
        case labourHours = "p_labour_hours"
        case startTime = "p_start_time"
        case finishTime = "p_finish_time"
        case method = "p_method"
        case notes = "p_notes"
        case estimatedVines = "p_estimated_vines"
        case clientUpdatedAt = "p_client_updated_at"
        case segments = "p_segments"
    }

    init(from entry: PruningEntry, clientUpdatedAt: Date) {
        self.id = entry.id
        self.vineyardId = entry.vineyardId
        self.seasonId = entry.seasonId
        self.paddockId = entry.paddockId
        self.seasonYear = PruningSeasonId.currentSeasonYear
        self.entryDate = PruningSyncDate.ymd(from: entry.date)
        self.worker = entry.worker
        self.labourHours = entry.labourHours
        self.startTime = entry.startTime
        self.finishTime = entry.finishTime
        self.method = entry.method.rawValue
        self.notes = entry.notes
        self.estimatedVines = entry.estimatedVines
        self.clientUpdatedAt = clientUpdatedAt
        self.segments = entry.segments.map { Segment(row: $0.row, segment: $0.quarter) }
    }
}

// MARK: - pruning_row_segments

nonisolated struct BackendPruningSegment: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let pruningSeasonId: UUID
    let paddockId: UUID
    let rowNumber: Int
    let segmentNumber: Int
    let completed: Bool?
    let completedAt: Date?
    let completedBy: String?
    let pruningEntryId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case pruningSeasonId = "pruning_season_id"
        case paddockId = "paddock_id"
        case rowNumber = "row_number"
        case segmentNumber = "segment_number"
        case completed
        case completedAt = "completed_at"
        case completedBy = "completed_by"
        case pruningEntryId = "pruning_entry_id"
    }
}
