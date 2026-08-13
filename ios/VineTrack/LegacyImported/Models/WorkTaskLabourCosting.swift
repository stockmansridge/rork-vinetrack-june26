import Foundation

/// THE authoritative labour-costing contract for Work Tasks — the Swift twin of
/// the Kotlin `WorkTaskLabourCosting`. Both platforms MUST produce identical
/// numbers from identical inputs; the unit suites on each side assert the same
/// fixtures.
///
/// Ownership rule this type encodes:
///
/// * A **Work Task labour line** owns labour type, hourly rate, worker count,
///   hours per worker, person-hours and labour cost. These are the ONLY
///   authoritative source of labour cost.
/// * A **Pruning Activity** owns operational output (date, blocks, rows,
///   quarters, method, crew reference, vines, start/finish, elapsed duration,
///   notes, `work_task_id`). It no longer offers an editable hourly rate.
///
/// Legacy `pruning_activities.hourly_rate` / `labour_hours` values stay READABLE
/// for compatibility, but they are never combined with Work Task labour totals —
/// see `resolveLabour(...)`, which returns exactly one source.
///
/// Arithmetic (mirrored in Kotlin):
///
///     person-hours = workerCount × hoursPerWorker
///     line cost    = person-hours × hourlyRate
///     task totals  = Σ line person-hours, Σ line costs
///
/// An already-aggregated activity duration is NEVER multiplied again: elapsed
/// activity duration, hours per worker, and total person-hours are three
/// distinct quantities.
nonisolated enum WorkTaskLabourCosting {

    // MARK: Bounds (shared with the standard Work Task form)

    /// A crew larger than this is a typo, not a vineyard.
    static let maxWorkerCount: Int = 500

    /// More than a full day per worker on one line is a typo.
    static let maxHoursPerWorker: Double = 24

    /// Defensive upper bound on an hourly rate.
    static let maxHourlyRate: Double = 100_000

    // MARK: Line arithmetic

    /// `workerCount × hoursPerWorker`, floored at zero and never NaN/∞.
    static func personHours(workerCount: Int, hoursPerWorker: Double) -> Double {
        guard hoursPerWorker.isFinite else { return 0 }
        return Double(max(workerCount, 0)) * max(hoursPerWorker, 0)
    }

    /// `person-hours × hourlyRate`. A nil rate means "cost not specified".
    static func lineCost(workerCount: Int, hoursPerWorker: Double, hourlyRate: Double?) -> Double? {
        guard let hourlyRate, hourlyRate.isFinite else { return nil }
        return personHours(workerCount: workerCount, hoursPerWorker: hoursPerWorker) * max(hourlyRate, 0)
    }

    /// Person-hours of one stored line, preferring the DB-generated value.
    static func personHours(_ line: WorkTaskLabourLine) -> Double {
        personHours(workerCount: line.workerCount, hoursPerWorker: line.hoursPerWorker)
    }

    /// Cost of one stored line. Nil when no rate exists — an absent rate is
    /// "not specified", never `$0.00`.
    static func lineCost(_ line: WorkTaskLabourLine) -> Double? {
        guard let rate = line.hourlyRate, rate.isFinite else { return nil }
        return personHours(line) * max(rate, 0)
    }

    // MARK: Task totals

    /// Live lines of one task, oldest first.
    static func lines(_ lines: [WorkTaskLabourLine], for workTaskId: UUID) -> [WorkTaskLabourLine] {
        lines
            .filter { $0.workTaskId == workTaskId }
            .sorted { $0.workDate < $1.workDate }
    }

    /// Σ person-hours across the given lines.
    static func totalPersonHours(_ lines: [WorkTaskLabourLine]) -> Double {
        lines.reduce(0) { $0 + personHours($1) }
    }

    /// Σ costs across the given lines. Nil when NO line carries a cost at all,
    /// so "not specified" never renders as zero. Lines without a rate contribute
    /// nothing rather than blocking the total.
    static func totalCost(_ lines: [WorkTaskLabourLine]) -> Double? {
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
    static func totalWorkers(_ lines: [WorkTaskLabourLine]) -> Int {
        lines.reduce(0) { $0 + max($1.workerCount, 0) }
    }

    nonisolated struct LabourTotals: Equatable, Sendable {
        var lineCount: Int
        var workers: Int
        var personHours: Double
        var cost: Double?

        var isEmpty: Bool { lineCount == 0 }
    }

    /// One task's totals in a single pass.
    static func totals(_ lines: [WorkTaskLabourLine]) -> LabourTotals {
        LabourTotals(
            lineCount: lines.count,
            workers: totalWorkers(lines),
            personHours: totalPersonHours(lines),
            cost: totalCost(lines)
        )
    }

    // MARK: Legacy fallback (never double-counted)

    /// Which source a pruning report must use for one activity's labour.
    ///
    /// * `pieceRate` — the linked task is costed per vine (sql/188). Its own
    ///   snapshot IS the labour-cost record, so it wins outright and labour
    ///   lines on the same task are operational history only.
    /// * `workTaskLines` — the linked task has labour lines. Authoritative.
    /// * `legacyActivity` — no labour lines exist; the activity's own historical
    ///   `labour_hours` / `hourly_rate` are shown as legacy data.
    /// * `none` — nothing recorded.
    ///
    /// The value sources are mutually exclusive by construction, which is what
    /// stops a report summing an activity rate AND its task's lines — or a
    /// piece-rate total AND an hourly one.
    nonisolated enum LabourSource: String, Sendable {
        case pieceRate
        case workTaskLines
        case legacyActivity
        case none
    }

    nonisolated struct ResolvedLabour: Equatable, Sendable {
        var source: LabourSource
        /// Person-hours from labour lines, or the legacy activity hours.
        var hours: Double?
        /// Cost from labour lines, or the legacy activity hours × rate.
        var cost: Double?
        /// True when `hours`/`cost` come from pre-labour-line history.
        var isLegacy: Bool
    }

    /// Resolves ONE activity's labour, preferring Work Task labour lines and
    /// falling back to the legacy activity-level values only when the task has
    /// no lines at all. Exactly one source contributes, so no total can count
    /// labour twice.
    ///
    /// - Parameters:
    ///   - lines: every live labour line of the LINKED task (empty when the
    ///     activity has no task, or the task has no lines).
    ///   - legacyHours: historical `pruning_activities.labour_hours`.
    ///   - legacyRate: historical `pruning_activities.hourly_rate`.
    ///   - includeCost: false hides every monetary value for roles without
    ///     costing visibility (hours are still returned).
    static func resolveLabour(
        lines: [WorkTaskLabourLine],
        legacyHours: Double?,
        legacyRate: Double?,
        includeCost: Bool = true
    ) -> ResolvedLabour {
        if !lines.isEmpty {
            let hours = totalPersonHours(lines)
            return ResolvedLabour(
                source: .workTaskLines,
                hours: hours > 0 ? hours : nil,
                cost: includeCost ? totalCost(lines) : nil,
                isLegacy: false
            )
        }
        let hours: Double? = (legacyHours?.isFinite == true && (legacyHours ?? 0) > 0) ? legacyHours : nil
        let rate: Double? = (legacyRate?.isFinite == true && (legacyRate ?? 0) > 0) ? legacyRate : nil
        if hours == nil && rate == nil {
            return ResolvedLabour(source: .none, hours: nil, cost: nil, isLegacy: false)
        }
        var cost: Double?
        if includeCost, let hours, let rate { cost = hours * rate }
        return ResolvedLabour(source: .legacyActivity, hours: hours, cost: cost, isLegacy: true)
    }

    /// Per-task labour cost map from labour lines ONLY.
    ///
    /// - Warning: this answers "what do this task's labour lines cost?", NOT
    ///   "what is this task's labour cost?". A piece-rate task legitimately has
    ///   no labour lines, so any caller that means the latter must use
    ///   `PieceRateCosting.effectiveCostsByWorkTask(tasks:labourLines:includeCost:)`,
    ///   which applies the `costing_method` switch first.
    static func costsByWorkTask(_ lines: [WorkTaskLabourLine], includeCost: Bool = true) -> [UUID: Double] {
        guard includeCost else { return [:] }
        var grouped: [UUID: [WorkTaskLabourLine]] = [:]
        for line in lines { grouped[line.workTaskId, default: []].append(line) }
        var costs: [UUID: Double] = [:]
        for (taskId, group) in grouped {
            if let cost = totalCost(group) { costs[taskId] = cost }
        }
        return costs
    }

    /// Per-task person-hours map for the Activity Report, built in ONE pass.
    static func hoursByWorkTask(_ lines: [WorkTaskLabourLine]) -> [UUID: Double] {
        var hours: [UUID: Double] = [:]
        for line in lines { hours[line.workTaskId, default: 0] += personHours(line) }
        return hours.filter { $0.value > 0 }
    }

    // MARK: Defaults

    /// The rate a newly selected labour type supplies. The saved worker-type
    /// cost is the default; an explicit edit always wins.
    static func defaultRate(_ category: OperatorCategory?) -> Double? {
        guard let cost = category?.costPerHour, cost.isFinite, cost > 0 else { return nil }
        return cost
    }

    // MARK: Validation

    nonisolated enum LabourLineField: String, Sendable, Hashable {
        case labourType
        case workerCount
        case hoursPerWorker
        case hourlyRate
    }

    nonisolated struct LabourLineIssue: Equatable, Sendable {
        var field: LabourLineField
        var message: String
    }

    /// Inline validation for one labour line. Returns EVERY problem so the form
    /// can mark each field; an empty array means saveable. The caller must keep
    /// the entered values on failure — nothing here discards input.
    ///
    /// Rules (identical on Android):
    /// * a labour type is required (a linked worker type or a typed name),
    /// * worker count > 0 and ≤ `maxWorkerCount`,
    /// * hours per worker > 0 and ≤ `maxHoursPerWorker`,
    /// * hourly rate, when given, ≥ 0 and ≤ `maxHourlyRate`,
    /// * every numeric value must be finite.
    static func validate(
        labourType: String,
        workerCount: Int?,
        hoursPerWorker: Double?,
        hourlyRate: Double?,
        rateProvided: Bool? = nil
    ) -> [LabourLineIssue] {
        var issues: [LabourLineIssue] = []

        if labourType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(LabourLineIssue(field: .labourType, message: "Choose a labour type."))
        }

        if let workerCount {
            if workerCount <= 0 {
                issues.append(LabourLineIssue(field: .workerCount, message: "At least one person is needed."))
            } else if workerCount > maxWorkerCount {
                issues.append(LabourLineIssue(
                    field: .workerCount,
                    message: "That is more than \(maxWorkerCount) people — check the number."
                ))
            }
        } else {
            issues.append(LabourLineIssue(field: .workerCount, message: "Enter how many people worked."))
        }

        if let hoursPerWorker, hoursPerWorker.isFinite {
            if hoursPerWorker <= 0 {
                issues.append(LabourLineIssue(field: .hoursPerWorker, message: "Hours must be more than zero."))
            } else if hoursPerWorker > maxHoursPerWorker {
                issues.append(LabourLineIssue(
                    field: .hoursPerWorker,
                    message: "One person cannot work more than \(Int(maxHoursPerWorker)) hours in a day."
                ))
            }
        } else {
            issues.append(LabourLineIssue(
                field: .hoursPerWorker,
                message: "Enter the hours each person worked."
            ))
        }

        if rateProvided ?? (hourlyRate != nil) {
            if let hourlyRate, hourlyRate.isFinite {
                if hourlyRate < 0 {
                    issues.append(LabourLineIssue(field: .hourlyRate, message: "An hourly rate cannot be negative."))
                } else if hourlyRate > maxHourlyRate {
                    issues.append(LabourLineIssue(field: .hourlyRate, message: "That hourly rate looks too high."))
                }
            } else {
                issues.append(LabourLineIssue(field: .hourlyRate, message: "Enter a valid hourly rate."))
            }
        }

        return issues
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

    static func message(_ issues: [LabourLineIssue], for field: LabourLineField) -> String? {
        issues.first { $0.field == field }?.message
    }
}
