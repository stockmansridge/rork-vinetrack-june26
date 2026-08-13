import Foundation

/// How a Work Task's labour cost is calculated (sql/188).
///
/// Stored as a stable string on `work_tasks.costing_method`. It is the ONLY
/// switch — piece rate is never inferred from the presence of a rate, and the
/// two costing methods are never summed.
nonisolated enum WorkTaskCostingMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The pre-existing behaviour: Σ `work_task_labour_lines.total_cost`.
    case hourly
    /// Snapshotted vine quantity × agreed rate per vine.
    case pieceRate = "piece_rate"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hourly: return "Hourly"
        case .pieceRate: return "Piece Rate"
        }
    }

    /// Decodes a stored value. EVERY legacy record — and anything unrecognised
    /// written by a future client — resolves to `.hourly`, which is exactly how
    /// those records have always behaved.
    static func resolve(_ raw: String?) -> WorkTaskCostingMethod {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .hourly }
        return WorkTaskCostingMethod(rawValue: raw) ?? .hourly
    }
}

/// One row's HISTORICAL vine-count snapshot behind a piece-rate job.
/// Mirrors `public.work_task_piece_rate_rows` (sql/188).
///
/// This is not a row-selection system: the tracker derives these FROM the
/// existing pruning row selection. They exist so a completed job keeps the
/// quantity it was priced on even after the vineyard setup is edited.
nonisolated struct WorkTaskPieceRateRow: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var workTaskId: UUID
    var vineyardId: UUID
    var paddockId: UUID
    /// Logical reference into `paddocks.rows[].id`. Nil for manual/fallback
    /// rows that have no mapped geometry.
    var paddockRowId: UUID?
    /// Display snapshot of the row number AT COSTING TIME.
    var rowNumber: Int?
    /// THE snapshotted quantity this row was paid on.
    var vineCount: Int

    init(
        id: UUID = UUID(),
        workTaskId: UUID,
        vineyardId: UUID,
        paddockId: UUID,
        paddockRowId: UUID? = nil,
        rowNumber: Int? = nil,
        vineCount: Int = 0
    ) {
        self.id = id
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.paddockRowId = paddockRowId
        self.rowNumber = rowNumber
        self.vineCount = max(vineCount, 0)
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, workTaskId, vineyardId, paddockId, paddockRowId, rowNumber, vineCount
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        paddockId = try c.decode(UUID.self, forKey: .paddockId)
        paddockRowId = try c.decodeIfPresent(UUID.self, forKey: .paddockRowId)
        rowNumber = try c.decodeIfPresent(Int.self, forKey: .rowNumber)
        vineCount = max(try c.decodeIfPresent(Int.self, forKey: .vineCount) ?? 0, 0)
    }
}

/// THE piece-rate costing contract (sql/188) — the Swift twin of the Kotlin
/// `PieceRateCosting`. Both platforms MUST produce identical numbers from
/// identical backend data; the unit suites on each side assert the same
/// fixtures.
///
/// ```text
/// labour cost = piece vine count × piece rate per vine
///     2,238 vines × $1.27 = $2,842.26
/// ```
///
/// Rules this type encodes:
/// * The task's labour cost comes from EXACTLY ONE source, chosen by
///   `costing_method`. Hourly lines and the piece-rate total are never summed.
/// * Hours may still be recorded on a piece-rate job for operational history,
///   but they NEVER drive its cost.
/// * A completed piece-rate job is costed from its SNAPSHOT
///   (`piece_vine_count`, `piece_rate_per_vine`), never from today's rows.
nonisolated enum PieceRateCosting {

    /// A rate above this is a typo, not an agreement.
    static let maxRatePerVine: Double = 1_000

    /// A quantity above this is a typo, not a vineyard.
    static let maxVineCount: Int = 10_000_000

    // MARK: - Arithmetic

    /// Rounds a money value to whole cents, half away from zero — the SAME rule
    /// as the database's `round(numeric, 2)` and the Kotlin twin, so no
    /// platform ever reports a cent that another does not.
    static func roundedToCents(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 100).rounded() / 100
    }

    /// `vineCount × ratePerVine`, rounded to cents.
    /// Nil when either side is missing — an absent agreement is "not
    /// specified", never `$0.00`.
    static func cost(vineCount: Int?, ratePerVine: Double?) -> Double? {
        guard let vineCount, let ratePerVine, ratePerVine.isFinite else { return nil }
        return roundedToCents(Double(max(vineCount, 0)) * max(ratePerVine, 0))
    }

    /// Cost per hectare for a piece-rate job. Nil when no positive area is
    /// known — an unknown denominator must never render as a number.
    static func costPerHectare(cost: Double?, hectares: Double?) -> Double? {
        guard let cost, let hectares, hectares.isFinite, hectares > 0 else { return nil }
        return roundedToCents(cost / hectares)
    }

    // MARK: - Quantity derived from the selected rows

    /// The vine quantity a NEW job starts from: Σ `effectiveVineCount` across
    /// the selected rows, so the operator never re-enters a total the app
    /// already knows.
    ///
    /// Uses each row's MANUAL count when one is set, otherwise the calculated
    /// estimate — i.e. exactly `Paddock.effectiveVineCount(for:)`.
    static func vineCount(forSelectedRows rows: [WorkTaskPieceRateRow]) -> Int {
        rows.reduce(0) { $0 + max($1.vineCount, 0) }
    }

    /// Builds the historical snapshot rows for a job from a block's selected
    /// rows. Called at create/update time ONLY — never on read.
    ///
    /// - Parameters:
    ///   - paddock: the block whose rows were worked.
    ///   - selectedRowIds: the stable ids of the rows included in this job.
    ///     Empty means "every row of the block".
    static func snapshotRows(
        workTaskId: UUID,
        vineyardId: UUID,
        paddock: Paddock,
        selectedRowIds: Set<UUID>
    ) -> [WorkTaskPieceRateRow] {
        let selected = selectedRowIds.isEmpty
            ? paddock.rows
            : paddock.rows.filter { selectedRowIds.contains($0.id) }
        return selected
            .sorted { $0.number < $1.number }
            .map { row in
                WorkTaskPieceRateRow(
                    workTaskId: workTaskId,
                    vineyardId: vineyardId,
                    paddockId: paddock.id,
                    paddockRowId: row.id,
                    rowNumber: row.number,
                    vineCount: paddock.effectiveVineCount(for: row) ?? 0
                )
            }
    }

    // MARK: - Resolved labour cost

    nonisolated struct ResolvedCost: Equatable, Sendable {
        var method: WorkTaskCostingMethod
        /// THE task's labour cost under its selected method. Nil = not specified.
        var cost: Double?
        /// Person-hours recorded against the task. Present for BOTH methods —
        /// operational history is kept — but only drives cost when hourly.
        var hours: Double
        /// Snapshotted vine quantity (piece rate only).
        var vineCount: Int?
        /// Agreed rate per vine (piece rate only).
        var ratePerVine: Double?

        /// True when hours exist but are explicitly not the basis of the cost.
        var hoursAreOperationalOnly: Bool {
            method == .pieceRate && hours > 0
        }
    }

    /// Resolves the ONE labour cost of a task. Exactly one source contributes,
    /// which is what stops a report adding an hourly total to a piece-rate one.
    ///
    /// - Parameters:
    ///   - method: `work_tasks.costing_method`.
    ///   - labourLines: the task's live `work_task_labour_lines`.
    ///   - pieceVineCount: `work_tasks.piece_vine_count` (the SNAPSHOT).
    ///   - pieceRatePerVine: `work_tasks.piece_rate_per_vine` (the SNAPSHOT).
    static func resolve(
        method: WorkTaskCostingMethod,
        labourLines: [WorkTaskLabourLine],
        pieceVineCount: Int?,
        pieceRatePerVine: Double?
    ) -> ResolvedCost {
        let hours = WorkTaskLabourCosting.totalPersonHours(labourLines)
        switch method {
        case .hourly:
            return ResolvedCost(
                method: .hourly,
                cost: WorkTaskLabourCosting.totalCost(labourLines),
                hours: hours,
                vineCount: nil,
                ratePerVine: nil
            )
        case .pieceRate:
            return ResolvedCost(
                method: .pieceRate,
                cost: cost(vineCount: pieceVineCount, ratePerVine: pieceRatePerVine),
                hours: hours,
                vineCount: pieceVineCount,
                ratePerVine: pieceRatePerVine
            )
        }
    }

    /// Convenience: resolves straight from a stored task.
    static func resolve(task: WorkTask, labourLines: [WorkTaskLabourLine]) -> ResolvedCost {
        resolve(
            method: task.costingMethod,
            labourLines: WorkTaskLabourCosting.lines(labourLines, for: task.id),
            pieceVineCount: task.pieceVineCount,
            pieceRatePerVine: task.pieceRatePerVine
        )
    }

    // MARK: - Validation

    nonisolated enum PieceRateField: String, Sendable, Hashable {
        case ratePerVine
        case vineCount
    }

    nonisolated struct PieceRateIssue: Equatable, Sendable {
        var field: PieceRateField
        var message: String
    }

    /// Inline validation for the piece-rate form. Returns EVERY problem so the
    /// form can mark each field; an empty array means saveable.
    static func validate(ratePerVine: Double?, vineCount: Int?) -> [PieceRateIssue] {
        var issues: [PieceRateIssue] = []

        if let ratePerVine, ratePerVine.isFinite {
            if ratePerVine <= 0 {
                issues.append(PieceRateIssue(
                    field: .ratePerVine,
                    message: "Enter the agreed rate per vine."
                ))
            } else if ratePerVine > maxRatePerVine {
                issues.append(PieceRateIssue(
                    field: .ratePerVine,
                    message: "That rate per vine looks too high — check the number."
                ))
            }
        } else {
            issues.append(PieceRateIssue(
                field: .ratePerVine,
                message: "Enter the agreed rate per vine."
            ))
        }

        if let vineCount {
            if vineCount <= 0 {
                issues.append(PieceRateIssue(
                    field: .vineCount,
                    message: "Select the rows this job covers so the vine count can be calculated."
                ))
            } else if vineCount > maxVineCount {
                issues.append(PieceRateIssue(
                    field: .vineCount,
                    message: "That vine count looks too high — check the selected rows."
                ))
            }
        } else {
            issues.append(PieceRateIssue(
                field: .vineCount,
                message: "Select the rows this job covers so the vine count can be calculated."
            ))
        }

        return issues
    }

    static func isValid(ratePerVine: Double?, vineCount: Int?) -> Bool {
        validate(ratePerVine: ratePerVine, vineCount: vineCount).isEmpty
    }

    static func message(_ issues: [PieceRateIssue], for field: PieceRateField) -> String? {
        issues.first { $0.field == field }?.message
    }

    // MARK: - Formatting (Australian currency, consistent with the app)

    /// `$1.27` — the agreed rate, always 2 decimals.
    static func rateLabel(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(2)))
    }

    /// `$2,842.26` — a money total, grouped and always 2 decimals.
    static func currencyLabel(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
    }

    /// `2,238` — a vine quantity, grouped.
    static func vineCountLabel(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
