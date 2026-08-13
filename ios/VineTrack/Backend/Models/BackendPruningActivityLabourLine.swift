import Foundation

// MARK: - Canonical row (sql/190 `pruning_activity_labour_lines`)

/// One labour line of a pruning activity as the server reports it — either from
/// the table directly or from `pruning_activity_labour_lines_json`.
///
/// `total_cost` arrives as NULL (not `0.00`) on an unrated line, matching the
/// costing rule: "nobody entered a rate" is not the same as "this cost zero".
nonisolated struct BackendPruningActivityLabourLine: Decodable, Sendable, Identifiable {
    let id: UUID
    let pruningActivityId: UUID
    let vineyardId: UUID
    let workDate: Date?
    let workerTypeId: UUID?
    let workerType: String?
    let workerCount: Int?
    let hoursPerWorker: Double?
    let hourlyRate: Double?
    let totalHours: Double?
    let totalCost: Double?
    let notes: String?
    let lineIndex: Int?
    let deletedAt: Date?
    let clientUpdatedAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case pruningActivityId = "pruning_activity_id"
        case vineyardId = "vineyard_id"
        case workDate = "work_date"
        case workerTypeId = "worker_type_id"
        case workerType = "worker_type"
        case workerCount = "worker_count"
        case hoursPerWorker = "hours_per_worker"
        case hourlyRate = "hourly_rate"
        case totalHours = "total_hours"
        case totalCost = "total_cost"
        case notes
        case lineIndex = "line_index"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case updatedAt = "updated_at"
    }

    // Per-row resilient decode: tolerate missing optional fields and
    // string-encoded dates from PostgREST so one malformed row cannot break
    // sync for the rest of the vineyard's pruning labour.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pruningActivityId = try c.decode(UUID.self, forKey: .pruningActivityId)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        workDate = Self.flexibleDate(c, .workDate)
        workerTypeId = try? c.decodeIfPresent(UUID.self, forKey: .workerTypeId)
        workerType = try c.decodeIfPresent(String.self, forKey: .workerType)
        workerCount = try c.decodeIfPresent(Int.self, forKey: .workerCount)
        hoursPerWorker = try c.decodeIfPresent(Double.self, forKey: .hoursPerWorker)
        hourlyRate = try c.decodeIfPresent(Double.self, forKey: .hourlyRate)
        totalHours = try c.decodeIfPresent(Double.self, forKey: .totalHours)
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        lineIndex = try c.decodeIfPresent(Int.self, forKey: .lineIndex)
        deletedAt = Self.flexibleDate(c, .deletedAt)
        clientUpdatedAt = Self.flexibleDate(c, .clientUpdatedAt)
        updatedAt = Self.flexibleDate(c, .updatedAt)
    }

    private static func flexibleDate(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendDamageRecordDateParser.parse(s)
    }

    /// Maps into the local model. The generated `total_hours` / `total_cost`
    /// columns are deliberately NOT stored locally — they are re-derived from
    /// the same inputs by `PruningActivityLabourCosting`, so the two platforms
    /// and the database cannot drift apart on rounding.
    func toLabourLine() -> PruningActivityLabourLine {
        PruningActivityLabourLine(
            id: id,
            pruningActivityId: pruningActivityId,
            vineyardId: vineyardId,
            workDate: workDate ?? Date(),
            operatorCategoryId: workerTypeId,
            workerType: workerType ?? "",
            workerCount: workerCount ?? 1,
            hoursPerWorker: hoursPerWorker ?? 0,
            hourlyRate: hourlyRate,
            notes: notes ?? "",
            lineIndex: lineIndex ?? 0
        )
    }
}

// MARK: - Desired-state write (sql/190 `save_pruning_activity_labour_lines`)

/// ONE line inside the desired-state payload.
///
/// `id` is always sent: it is the client-generated idempotency key, and sending
/// it is what makes an offline replay upsert the same row instead of inserting
/// a duplicate.
nonisolated struct BackendPruningActivityLabourLinePayload: Encodable, Sendable {
    let id: UUID
    let workDate: Date
    let workerTypeId: UUID?
    let workerType: String
    let workerCount: Int
    let hoursPerWorker: Double
    let hourlyRate: Double?
    let notes: String
    let lineIndex: Int

    enum CodingKeys: String, CodingKey {
        case id
        case workDate = "work_date"
        case workerTypeId = "worker_type_id"
        case workerType = "worker_type"
        case workerCount = "worker_count"
        case hoursPerWorker = "hours_per_worker"
        case hourlyRate = "hourly_rate"
        case notes
        case lineIndex = "line_index"
    }

    /// `work_date` is encoded as `yyyy-MM-dd` to match the SQL `date` column.
    private static let workDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(Self.workDateFormatter.string(from: workDate), forKey: .workDate)
        try c.encodeIfPresent(workerTypeId, forKey: .workerTypeId)
        try c.encode(workerType, forKey: .workerType)
        try c.encode(workerCount, forKey: .workerCount)
        try c.encode(hoursPerWorker, forKey: .hoursPerWorker)
        // An UNRATED line must send SQL NULL, never 0 — that distinction is the
        // whole reason "not specified" does not collapse into "$0.00".
        if let hourlyRate {
            try c.encode(hourlyRate, forKey: .hourlyRate)
        } else {
            try c.encodeNil(forKey: .hourlyRate)
        }
        try c.encode(notes, forKey: .notes)
        try c.encode(lineIndex, forKey: .lineIndex)
    }

    init(from line: PruningActivityLabourLine, lineIndex: Int) {
        self.id = line.id
        self.workDate = line.workDate
        self.workerTypeId = line.operatorCategoryId
        self.workerType = line.workerType
        self.workerCount = line.workerCount
        self.hoursPerWorker = line.hoursPerWorker
        self.hourlyRate = line.hourlyRate
        self.notes = line.notes
        self.lineIndex = lineIndex
    }
}

/// Parameters for `save_pruning_activity_labour_lines(uuid, jsonb, timestamptz)`.
///
/// The payload is the COMPLETE desired set for the activity: lines present are
/// upserted on their client id, lines absent are soft-deleted, and a re-sent
/// soft-deleted line is restored. An empty array is therefore a legitimate
/// instruction meaning "this activity has no labour lines" — never a no-op.
nonisolated struct SavePruningActivityLabourLinesParams: Encodable, Sendable {
    let activityId: UUID
    let lines: [BackendPruningActivityLabourLinePayload]
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case activityId = "p_activity_id"
        case lines = "p_lines"
        case clientUpdatedAt = "p_client_updated_at"
    }
}

/// The canonical answer from `save_pruning_activity_labour_lines`: the full
/// server-side set plus the activity's effective hours and cost, so the client
/// can replace its local set wholesale instead of guessing what landed.
nonisolated struct SavePruningActivityLabourLinesResult: Decodable, Sendable {
    let activityId: UUID?
    let saved: Int?
    let removed: Int?
    let labourLines: [BackendPruningActivityLabourLine]?
    let totalLabourHours: Double?
    let labourCost: Double?
    let labourCostSource: String?

    enum CodingKeys: String, CodingKey {
        case activityId = "activity_id"
        case saved
        case removed
        case labourLines = "labour_lines"
        case totalLabourHours = "total_labour_hours"
        case labourCost = "labour_cost"
        case labourCostSource = "labour_cost_source"
    }
}
