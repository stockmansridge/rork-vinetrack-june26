import Foundation

/// THE authoritative labour contract for PRUNING ACTIVITIES (sql/190) — the
/// Swift twin of the Kotlin `PruningActivityLabourCosting`. Both platforms MUST
/// produce identical numbers from identical inputs; the unit suites on each side
/// assert the same fixtures, and those fixtures match the SQL suite.
///
/// ## Ownership — REPAIRED (sql/200)
///
/// **WORK TASKS own labour cost.** A pruning activity is an operational record
/// that may link 0..N Work Tasks; its labour figures are DERIVED — the sum of
/// the linked tasks' canonical totals. The activity-owned lines below are the
/// DEPRECATED sql/190 legacy model: still readable (and still resolved for
/// activities that have no task-owned cost), but never written by new UI.
///
/// Labour is counted ONCE per activity regardless of how many blocks it
/// covers. Nothing here is ever apportioned per block.
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
        /// Σ of MULTIPLE linked Work Tasks' canonical totals (sql/200).
        case workTasks
        /// A linked piece-rate task's snapshot total (sql/188).
        case pieceRate
        /// The activity's OWN labour lines (sql/190) — DEPRECATED legacy read.
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
        /// How many LIVE Work Tasks are linked (sql/200). The derived totals
        /// sum exactly these tasks when `source == .workTasks` /
        /// `.pieceRate` / `.workTaskLines`.
        var taskCount: Int = 0
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
    /// the Swift twin of `pruning_activity_effective_labour_cost` as REPAIRED
    /// by sql/200.
    ///
    /// Strict precedence, never addition:
    ///
    /// 1. the linked **Work Tasks'** canonical totals (sql/200) — Σ across the
    ///    0..N linked tasks; each task contributes its OWN record only
    ///    (piece-rate snapshot or its own labour lines),
    /// 2. the activity's **own labour lines** (sql/190) — DEPRECATED legacy
    ///    read for pre-repair records,
    /// 3. the activity's legacy `labour_hours × hourly_rate` (sql/166).
    ///
    /// - Parameters:
    ///   - task: the legacy PRIMARY linked task (`draft.workTaskId` mirror).
    ///   - activityLines: the activity's OWN legacy lines (already filtered).
    ///   - taskLines: the PRIMARY task's labour lines (already filtered).
    ///   - legacyHours: historical `pruning_activities.labour_hours`.
    ///   - legacyRate: historical `pruning_activities.hourly_rate`.
    ///   - includeCost: false hides every monetary value for roles without
    ///     costing visibility. Hours are still returned.
    ///   - linkedTasks: EVERY linked task (sql/200). When empty, the legacy
    ///     single `task` is used so pre-repair callers keep working.
    ///   - linesByTask: live labour lines grouped by task id for `linkedTasks`.
    static func resolve(
        task: WorkTask?,
        activityLines: [PruningActivityLabourLine],
        taskLines: [WorkTaskLabourLine],
        legacyHours: Double?,
        legacyRate: Double?,
        includeCost: Bool = true,
        linkedTasks: [WorkTask] = [],
        linesByTask: [UUID: [WorkTaskLabourLine]] = [:]
    ) -> Resolved {
        let lineCount = activityLines.count
        let ownHours = totalHours(activityLines)

        // The task SET: every linked task when supplied, else the legacy
        // single mirror task.
        var taskSet: [WorkTask] = linkedTasks
        if taskSet.isEmpty, let task { taskSet = [task] }
        var effectiveLines = linesByTask
        if let task, effectiveLines[task.id] == nil, !taskLines.isEmpty {
            effectiveLines[task.id] = taskLines
        }

        // 1. WORK TASKS FIRST (sql/200): the sum of the linked tasks' canonical
        //    totals. Resolves whenever any linked task carries its own hours or
        //    cost, so a legacy task that owns nothing still falls through to
        //    the legacy rungs below.
        let aggregate = PruningWorkTaskLink.aggregate(taskSet, linesByTask: effectiveLines)
        if aggregate.cost != nil || aggregate.hours != nil {
            let source: Source
            if taskSet.count == 1, let only = taskSet.first {
                source = only.isPieceRate ? .pieceRate : .workTaskLines
            } else {
                source = .workTasks
            }
            let hours = aggregate.hours
                ?? ownHours
                ?? legacyHours.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return Resolved(
                source: source,
                hours: hours,
                cost: includeCost ? aggregate.cost : nil,
                isLegacy: false,
                lineCount: lineCount,
                taskCount: taskSet.count
            )
        }

        // A single linked piece-rate task with NO agreed rate yet: the job is
        // piece-priced and "not specified" — it must never fall back to an
        // hourly figure.
        if taskSet.count == 1, let only = taskSet.first, only.isPieceRate {
            let hours = ownHours ?? legacyHours.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return Resolved(
                source: .pieceRate,
                hours: hours,
                cost: nil,
                isLegacy: false,
                lineCount: lineCount,
                taskCount: 1
            )
        }

        // 2. DEPRECATED legacy read: the activity's OWN rated labour lines.
        if let cost = totalCost(activityLines) {
            return Resolved(
                source: .pruningLabourLines,
                hours: ownHours,
                cost: includeCost ? cost : nil,
                isLegacy: true,
                lineCount: lineCount,
                taskCount: taskSet.count
            )
        }

        // The activity owns lines but none carry a rate: hours are real, the
        // cost is genuinely "not specified" — never $0.00 and never a fallback.
        if lineCount > 0 {
            return Resolved(
                source: .pruningLabourLines,
                hours: ownHours,
                cost: nil,
                isLegacy: true,
                lineCount: lineCount,
                taskCount: taskSet.count
            )
        }

        // 3. The legacy scalar pair.
        let hours = legacyHours.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let rate = legacyRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if hours == nil && rate == nil {
            return Resolved(
                source: .none, hours: nil, cost: nil, isLegacy: false,
                lineCount: 0, taskCount: taskSet.count
            )
        }
        var cost: Double?
        if includeCost, let hours, let rate { cost = hours * rate }
        return Resolved(
            source: .activityHours,
            hours: hours,
            cost: cost,
            isLegacy: true,
            lineCount: 0,
            taskCount: taskSet.count
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
