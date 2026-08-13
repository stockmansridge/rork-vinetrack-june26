import Foundation

/// THE authoritative labour contract for PRUNING ACTIVITIES (sql/190) — the
/// Swift twin of the Kotlin `PruningActivityLabourCosting`. Both platforms MUST
/// produce identical numbers from identical inputs; the unit suites on each side
/// assert the same fixtures, and those fixtures match the SQL suite.
///
/// ## Ownership
///
/// Labour is **PRUNING-OWNED**. A linked Work Task never gets a copy of these
/// rows; it resolves *through* to them. One stored set, two readers, identical
/// number — which is what stops the same money existing twice.
///
/// Labour belongs to the ACTIVITY and is counted ONCE regardless of how many
/// blocks the activity covers. Nothing here is ever apportioned per block.
///
/// ## Hours vs cost — two deliberately different rules
///
/// * **Hours** sum EVERY active line, including unrated ones. An unpriced line
///   is still work that was done and still drives vines-per-hour.
/// * **Cost** sums only lines that carry a rate. The SQL `total_cost` column is
///   generated with `coalesce(hourly_rate, 0)`, so summing blindly would turn
///   "nobody entered a rate" into `$0.00`. Unknown is **nil**, never `0`.
nonisolated enum PruningActivityLabourCosting {

    // MARK: Line arithmetic

    /// `workerCount × hoursPerWorker`, floored at zero and never NaN/∞.
    static func personHours(workerCount: Int, hoursPerWorker: Double) -> Double {
        guard hoursPerWorker.isFinite else { return 0 }
        return Double(max(workerCount, 0)) * max(hoursPerWorker, 0)
    }

    /// Person-hours of one stored line.
    static func personHours(_ line: PruningActivityLabourLine) -> Double {
        personHours(workerCount: line.workerCount, hoursPerWorker: line.hoursPerWorker)
    }

    /// Cost of one stored line. nil when the line carries no rate — an absent
    /// rate is "not specified", never `$0.00`.
    static func lineCost(_ line: PruningActivityLabourLine) -> Double? {
        guard let rate = line.hourlyRate, rate.isFinite else { return nil }
        return personHours(line) * max(rate, 0)
    }

    // MARK: Activity totals

    /// The lines of ONE activity, in stable display order.
    ///
    /// Ordered by `lineIndex` first — exactly like
    /// `pruning_activity_labour_lines_json` — so a crew list cannot reshuffle
    /// between devices.
    static func lines(
        _ lines: [PruningActivityLabourLine],
        for activityId: UUID
    ) -> [PruningActivityLabourLine] {
        lines
            .filter { $0.pruningActivityId == activityId }
            .sorted {
                if $0.lineIndex != $1.lineIndex { return $0.lineIndex < $1.lineIndex }
                return $0.workDate < $1.workDate
            }
    }

    /// Σ person-hours across EVERY given line, rated or not — the Swift twin of
    /// `pruning_activity_labour_line_hours`. nil when there is no line at all.
    static func totalHours(_ lines: [PruningActivityLabourLine]) -> Double? {
        guard !lines.isEmpty else { return nil }
        return lines.reduce(0) { $0 + personHours($1) }
    }

    /// Σ costs across the RATED lines only — the Swift twin of
    /// `pruning_activity_labour_line_cost`. nil (never `0.00`) when no line
    /// carries a rate, so "not specified" can never render as zero.
    static func totalCost(_ lines: [PruningActivityLabourLine]) -> Double? {
        var sum: Double = 0
        var sawCost = false
        for line in lines {
            guard let cost = lineCost(line) else { continue }
            sum += cost
            sawCost = true
        }
        return sawCost ? sum : nil
    }

    /// Σ worker counts across the given lines.
    static func totalWorkers(_ lines: [PruningActivityLabourLine]) -> Int {
        lines.reduce(0) { $0 + max($1.workerCount, 0) }
    }

    nonisolated struct LabourTotals: Equatable, Sendable {
        var lineCount: Int
        var workers: Int
        /// Hours of EVERY active line, including unrated ones.
        var personHours: Double
        /// Cost of the RATED lines only. nil means "not specified".
        var cost: Double?

        var isEmpty: Bool { lineCount == 0 }
    }

    /// One activity's own line totals in a single pass.
    static func totals(_ lines: [PruningActivityLabourLine]) -> LabourTotals {
        LabourTotals(
            lineCount: lines.count,
            workers: totalWorkers(lines),
            personHours: totalHours(lines) ?? 0,
            cost: totalCost(lines)
        )
    }

    // MARK: Effective resolution — precedence, never addition

    /// Which source an activity's labour figure came from — the Swift twin of
    /// `pruning_activity_labour_cost_source`.
    ///
    /// The cases are mutually exclusive by construction, which is what stops a
    /// report adding an activity's lines to a linked task's, or a piece-rate
    /// total to an hourly one.
    nonisolated enum Source: String, Sendable {
        /// A linked piece-rate task's snapshot total (sql/188).
        case pieceRate
        /// The activity's OWN labour lines (sql/190).
        case pruningLabourLines
        /// The linked hourly task's labour lines (sql/189).
        case workTaskLines
        /// The activity's legacy `labour_hours` × `hourly_rate` (sql/166).
        case activityHours
        /// Nothing recorded.
        case none
    }

    nonisolated struct Resolved: Equatable, Sendable {
        var source: Source
        /// Total labour hours of the activity. Present even on a piece-rate job,
        /// where hours are operational history that never moves the cost.
        var hours: Double?
        /// THE labour cost of the activity. nil means "not specified".
        var cost: Double?
        /// True when the figures come from pre-SQL-190 history.
        var isLegacy: Bool
        /// How many labour lines the ACTIVITY itself owns. 0 means the activity
        /// is legacy/single-crew and resolved further down the chain.
        var lineCount: Int
    }

    /// Effective HOURS of an activity — the Swift twin of
    /// `pruning_activity_effective_labour_hours`.
    ///
    /// The activity's own lines when it owns any, otherwise the legacy scalar.
    /// Precedence, never addition: the legacy scalar and the lines are two
    /// representations of the SAME hours.
    static func effectiveHours(
        activityLines: [PruningActivityLabourLine],
        legacyHours: Double?
    ) -> Double? {
        if let hours = totalHours(activityLines) { return hours }
        guard let legacyHours, legacyHours.isFinite, legacyHours > 0 else { return nil }
        return legacyHours
    }

    /// **THE** effective labour cost and hours of one pruning activity —
    /// the Swift twin of `pruning_activity_effective_labour_cost`.
    ///
    /// Strict precedence, never addition:
    ///
    /// 1. a linked **piece-rate** task → its snapshot total. No fallback: an
    ///    unpriced piece-rate job is "not specified", and falling back to hours
    ///    would report an HOURLY figure for a piece-rate job.
    /// 2. the activity's **own rated labour lines** (sql/190),
    /// 3. the linked **hourly task's** rated labour lines (sql/189),
    /// 4. the activity's legacy `labour_hours × hourly_rate` (sql/166).
    ///
    /// - Parameters:
    ///   - task: the linked Work Task, when this device has it cached.
    ///   - activityLines: the activity's OWN labour lines (already filtered).
    ///   - taskLines: the LINKED task's labour lines (already filtered).
    ///   - legacyHours: historical `pruning_activities.labour_hours`.
    ///   - legacyRate: historical `pruning_activities.hourly_rate`.
    ///   - includeCost: false hides every monetary value for roles without
    ///     costing visibility. Hours are still returned.
    static func resolve(
        task: WorkTask?,
        activityLines: [PruningActivityLabourLine],
        taskLines: [WorkTaskLabourLine],
        legacyHours: Double?,
        legacyRate: Double?,
        includeCost: Bool = true
    ) -> Resolved {
        let lineCount = activityLines.count
        // Hours are resolved ONCE, independently of the cost branch: a
        // piece-rate job still records hours for productivity, and an unrated
        // line is still work that was done.
        let ownHours = totalHours(activityLines)

        // 1. A linked piece-rate task IS the cost.
        if let task, task.isPieceRate {
            let resolved = PieceRateCosting.resolve(task: task, labourLines: taskLines)
            let hours = ownHours
                ?? (resolved.hours > 0 ? resolved.hours : nil)
                ?? legacyHours.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return Resolved(
                source: .pieceRate,
                hours: hours,
                cost: includeCost ? resolved.cost : nil,
                isLegacy: false,
                lineCount: lineCount
            )
        }

        // 2. The activity's OWN rated labour lines.
        if let cost = totalCost(activityLines) {
            return Resolved(
                source: .pruningLabourLines,
                hours: ownHours,
                cost: includeCost ? cost : nil,
                isLegacy: false,
                lineCount: lineCount
            )
        }

        // The activity owns lines but none of them carry a rate. Hours are real
        // and reported; the cost is genuinely "not specified" — it must NOT fall
        // through to a linked task or a legacy rate, because these lines ARE the
        // labour record for this activity.
        if lineCount > 0 {
            return Resolved(
                source: .pruningLabourLines,
                hours: ownHours,
                cost: nil,
                isLegacy: false,
                lineCount: lineCount
            )
        }

        // 3. The linked hourly task's rated labour lines.
        if task != nil, !taskLines.isEmpty {
            let hours = WorkTaskLabourCosting.totalPersonHours(taskLines)
            return Resolved(
                source: .workTaskLines,
                hours: hours > 0 ? hours : nil,
                cost: includeCost ? WorkTaskLabourCosting.totalCost(taskLines) : nil,
                isLegacy: false,
                lineCount: 0
            )
        }

        // 4. The legacy scalar pair.
        let hours = legacyHours.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let rate = legacyRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if hours == nil && rate == nil {
            return Resolved(source: .none, hours: nil, cost: nil, isLegacy: false, lineCount: 0)
        }
        var cost: Double?
        if includeCost, let hours, let rate { cost = hours * rate }
        return Resolved(
            source: .activityHours,
            hours: hours,
            cost: cost,
            isLegacy: true,
            lineCount: 0
        )
    }

    // MARK: Work task side — read THROUGH, never a copy

    /// Rated labour-line total of the PRUNING ACTIVITY linked to a work task —
    /// the Swift twin of `work_task_pruning_labour_line_cost`.
    ///
    /// Used only as a fallback so a pruning-linked task reports the activity's
    /// labour instead of nil. The rows live in exactly ONE place; this is a
    /// read-through, never a copy.
    static func pruningLineCost(
        forWorkTask workTaskId: UUID,
        activities: [PruningActivityDraft],
        activityLines: [PruningActivityLabourLine]
    ) -> Double? {
        let linkedIds = Set(
            activities
                .filter { $0.workTaskId == workTaskId && !$0.isReversed }
                .map(\.id)
        )
        guard !linkedIds.isEmpty else { return nil }
        return totalCost(activityLines.filter { linkedIds.contains($0.pruningActivityId) })
    }

    /// **THE** effective labour cost of a work task under SQL 189 + SQL 190:
    ///
    /// 1. `piece_rate` → `piece_rate_total_cost`,
    /// 2. else its OWN rated labour lines,
    /// 3. else the rated labour lines of the pruning activity linked to it.
    ///
    /// Rung 3 only ever turns a nil into a value, so no pre-190 record changes.
    /// Never summed. nil means "not specified", never `$0.00`.
    static func effectiveWorkTaskCost(
        task: WorkTask,
        taskLines: [WorkTaskLabourLine],
        activities: [PruningActivityDraft],
        activityLines: [PruningActivityLabourLine]
    ) -> Double? {
        if task.isPieceRate {
            return PieceRateCosting.resolve(task: task, labourLines: taskLines).cost
        }
        if let own = WorkTaskLabourCosting.totalCost(taskLines) { return own }
        return pruningLineCost(
            forWorkTask: task.id,
            activities: activities,
            activityLines: activityLines
        )
    }

    // MARK: Conversion of a legacy activity

    /// Builds the ONE labour line that represents a legacy activity's scalar
    /// crew record, for the explicit "convert to labour lines" action.
    ///
    /// Never called automatically. `worker_or_crew` is free text ("Dave + 2
    /// casuals") and neither the database nor this client can honestly split it
    /// into a worker type and a crew size, so the user confirms the result — the
    /// crew text becomes the worker TYPE and the count defaults to one, which
    /// preserves the recorded hours exactly.
    static func legacyConversionLine(
        activityId: UUID,
        vineyardId: UUID,
        workDate: Date,
        workerOrCrew: String,
        legacyHours: Double?,
        legacyRate: Double?
    ) -> PruningActivityLabourLine? {
        guard let legacyHours, legacyHours.isFinite, legacyHours > 0 else { return nil }
        let trimmed = workerOrCrew.trimmingCharacters(in: .whitespacesAndNewlines)
        return PruningActivityLabourLine(
            pruningActivityId: activityId,
            vineyardId: vineyardId,
            workDate: workDate,
            workerType: trimmed.isEmpty ? "Labour" : trimmed,
            // One "worker" doing all the recorded hours reproduces the legacy
            // total exactly: 1 × 7.5 h × $32 = $240, the pre-190 figure.
            workerCount: 1,
            hoursPerWorker: legacyHours,
            hourlyRate: legacyRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            notes: "Converted from the original crew record.",
            lineIndex: 0
        )
    }

    // MARK: Validation

    /// Validation is IDENTICAL to a Work Task labour line — the two tables
    /// mirror each other, so one rule set serves both and the editors cannot
    /// drift apart.
    static func validate(
        labourType: String,
        workerCount: Int?,
        hoursPerWorker: Double?,
        hourlyRate: Double?,
        rateProvided: Bool? = nil
    ) -> [WorkTaskLabourCosting.LabourLineIssue] {
        WorkTaskLabourCosting.validate(
            labourType: labourType,
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate,
            rateProvided: rateProvided
        )
    }

    static func isValid(
        labourType: String,
        workerCount: Int?,
        hoursPerWorker: Double?,
        hourlyRate: Double?,
        rateProvided: Bool? = nil
    ) -> Bool {
        validate(
            labourType: labourType,
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate,
            rateProvided: rateProvided
        ).isEmpty
    }
}
