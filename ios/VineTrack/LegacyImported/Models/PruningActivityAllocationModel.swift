import Foundation

/// SHARED CONTRACT — the ALLOCATED labour model for pruning activities.
///
/// Anything changed here must be mirrored in `PruningActivityAllocationModel.kt`.
///
/// ## Why this exists
///
/// A pruning activity is ONE piece of work covering MANY blocks. The
/// authoritative activity values — worker, method, Work Task, start, finish,
/// person-hours, cost — belong to the PARENT ACTIVITY. `pruning_entries` is the
/// allocation table and stores a legacy MIRROR of some of those values on the
/// `allocation_index = 0` row.
///
/// That mirror must never be treated as the source of truth for a report:
///
///  * Filtering to a block that the activity touched as its SECOND allocation
///    would blank the labour, the worker and the Work Task, even though the
///    activity plainly has them.
///  * Summing a per-allocation copy of the parent's person-hours counts the same
///    labour once per block.
///
/// So this model resolves each parent ONCE from ALL of its canonical
/// allocations, then divides the parent's labour proportionally across them.
///
/// ## Allocation maths
///
///     share            = allocation row equivalents / FULL activity row equivalents
///     allocated hours  = parent person-hours × share
///     allocated cost   = parent labour cost   × share
///
/// The denominator is always the FULL canonical activity, never the filtered
/// subset. Filtering a two-block activity to one block must not hand 100% of the
/// cost to the surviving block.
///
/// ## Rounding
///
/// Allocated values are produced by CUMULATIVE rounding: each allocation's value
/// is the difference between successive rounded running totals. The final
/// running total is the rounded parent total, so summing every allocation
/// reconciles to the parent EXACTLY — the rounding remainder lands on the last
/// canonical allocation, deterministically, on both platforms.
///
/// ## Labour authority
///
/// Unchanged from `WorkTaskLabourCosting`: summed Work Task labour lines win
/// outright and the legacy activity value is the fallback used only when the
/// task has no lines. This model divides whichever value won; it never combines
/// the two and never re-derives labour from elapsed duration.
///
/// ## Parent authority and conflicts
///
/// Resolution order for every parent field is:
///
///  1. the CANONICAL `pruning_activities` parent, when one was supplied;
///  2. otherwise the first allocation, in canonical order, that recorded a value.
///
/// Step 2 exists for legacy projected rows, where only the mirror carries the
/// value. It is a fallback, never a merge: if two allocations of one activity
/// disagree on the worker, the Work Task, the labour or the timing, that is
/// corrupt data — an incompletely reconciled sync or a stale mirror — and one of
/// the two values is wrong. The model still has to return something, but it
/// records a `PruningActivityParentConflict` so the disagreement is visible in
/// diagnostics instead of being silently resolved by sort order.

/// The authoritative values of ONE pruning activity, resolved from all of its
/// allocations rather than from the legacy primary-allocation mirror.
nonisolated struct PruningActivityParent: Sendable, Equatable {
    let activityId: UUID
    /// Work Task title when linked, else a method-derived name. Never a UUID.
    let label: String
    let date: Date
    let method: String
    let worker: String?
    let workTaskId: UUID?
    let workTaskTitle: String?
    let workTaskStatus: String?
    let startTime: Date?
    let finishTime: Date?
    /// The activity's own recorded operational hours — NOT person-hours.
    let operationalHours: Double?
    /// Elapsed start→finish duration. Never multiplied by the crew size.
    let durationHours: Double?
    /// RESOLVED authoritative person-hours for the WHOLE activity.
    let personHours: Double?
    /// Whole-activity labour cost; nil when not recorded or not permitted.
    let labourCost: Double?
    let notes: String?
    let isReversed: Bool
    /// How many allocations the activity has in total, before any filtering.
    let allocationCount: Int
    /// The FULL activity's row equivalents — the allocation-share denominator.
    let rowEquivalents: Double
    /// True when a canonical `pruning_activities` parent supplied these values.
    /// False means they were reconstructed from the allocation mirror.
    var resolvedFromCanonicalParent: Bool = false
    /// True when the allocations (or the canonical parent and its mirror)
    /// disagreed on at least one parent field. The chosen value is still
    /// returned, but it must not be trusted without checking the portal.
    var hasContextConflict: Bool = false
}

/// A canonical `pruning_activities` parent record.
///
/// When the caller can supply this — the activity row itself rather than its
/// allocation mirror — it OUTRANKS every allocation for the fields it fills.
/// Fields left nil fall back to the allocations as before, so a partially
/// populated canonical parent is still useful.
nonisolated struct PruningActivityParentSource: Sendable, Equatable {
    let activityId: UUID
    var worker: String?
    var method: String?
    var workTaskId: UUID?
    var workTaskTitle: String?
    var workTaskStatus: String?
    var startTime: Date?
    var finishTime: Date?
    var operationalHours: Double?
    var durationHours: Double?
    var personHours: Double?
    var labourCost: Double?
    var notes: String?

    init(
        activityId: UUID,
        worker: String? = nil,
        method: String? = nil,
        workTaskId: UUID? = nil,
        workTaskTitle: String? = nil,
        workTaskStatus: String? = nil,
        startTime: Date? = nil,
        finishTime: Date? = nil,
        operationalHours: Double? = nil,
        durationHours: Double? = nil,
        personHours: Double? = nil,
        labourCost: Double? = nil,
        notes: String? = nil
    ) {
        self.activityId = activityId
        self.worker = worker
        self.method = method
        self.workTaskId = workTaskId
        self.workTaskTitle = workTaskTitle
        self.workTaskStatus = workTaskStatus
        self.startTime = startTime
        self.finishTime = finishTime
        self.operationalHours = operationalHours
        self.durationHours = durationHours
        self.personHours = personHours
        self.labourCost = labourCost
        self.notes = notes
    }
}

/// The parent fields whose disagreement is worth reporting.
nonisolated enum PruningActivityParentField: String, Sendable, CaseIterable {
    case worker
    case method
    case workTask
    case workTaskTitle
    case workTaskStatus
    case startTime
    case finishTime
    case operationalHours
    case durationHours
    case personHours
    case labourCost

    var label: String {
        switch self {
        case .worker: return "Worker"
        case .method: return "Method"
        case .workTask: return "Work Task"
        case .workTaskTitle: return "Work Task title"
        case .workTaskStatus: return "Work Task status"
        case .startTime: return "Start time"
        case .finishTime: return "Finish time"
        case .operationalHours: return "Operational hours"
        case .durationHours: return "Duration"
        case .personHours: return "Person-hours"
        case .labourCost: return "Labour cost"
        }
    }
}

/// Where the value that WON came from.
nonisolated enum PruningActivityConflictResolution: String, Sendable {
    /// The canonical `pruning_activities` parent decided it.
    case canonicalParent
    /// No canonical parent was available, so the first allocation carrying a
    /// value decided it. This is a guess and is reported as such.
    case firstAllocation
}

/// One parent field on which the sources disagreed.
///
/// A conflict is DIAGNOSTIC. It never changes the exported figures — the report
/// still has to render something — but it says plainly that the underlying
/// records are inconsistent, which is the difference between a stale mirror
/// quietly winning and a data problem someone can go and fix.
nonisolated struct PruningActivityParentConflict: Sendable, Equatable {
    let activityId: UUID
    let field: PruningActivityParentField
    /// Every distinct value seen, canonical parent first when it had one.
    let values: [String]
    let resolution: PruningActivityConflictResolution
    /// The value the model actually used.
    let resolvedValue: String?

    /// Log-ready one-liner.
    var description: String {
        let source = resolution == .canonicalParent
            ? " (canonical activity record)"
            : " (first allocation — unverified)"
        return "\(field.label) conflict on activity \(activityId.uuidString): "
            + values.joined(separator: " vs ")
            + " — using \(resolvedValue ?? "none")\(source)"
    }
}

/// One allocation's proportional slice of its parent activity.
nonisolated struct PruningActivityAllocationShare: Sendable, Equatable {
    let allocationId: UUID
    let activityId: UUID
    /// 1-based position within the FULL canonical activity.
    let allocationNumber: Int
    let fullAllocationCount: Int
    /// 0..1 fraction of the full activity's row equivalents.
    let share: Double
    /// parent person-hours × share, or nil when the parent has none.
    let personHours: Double?
    /// parent labour cost × share, or nil when absent / not permitted.
    let labourCost: Double?
}

/// Parents and allocation shares for a set of CANONICAL (unfiltered) report
/// rows. Build this from the full row set, then look up the filtered rows
/// against it so every figure keeps its whole-activity context.
nonisolated struct PruningActivityAllocationModel: Sendable {

    /// Money and hours are both reported to two decimals.
    static let decimals = 2

    private let parentsById: [UUID: PruningActivityParent]
    private let sharesById: [UUID: PruningActivityAllocationShare]

    /// Every parent-context disagreement found while building the model, in
    /// activity order. Surfaced in diagnostics — logs, the PDF's data-quality
    /// notice — never used to alter a figure.
    let conflicts: [PruningActivityParentConflict]

    func parent(_ activityId: UUID) -> PruningActivityParent? { parentsById[activityId] }

    func parent(of row: PruningActivityRow) -> PruningActivityParent? { parentsById[row.activityKey] }

    func share(_ allocationId: UUID) -> PruningActivityAllocationShare? { sharesById[allocationId] }

    func share(of row: PruningActivityRow) -> PruningActivityAllocationShare? { sharesById[row.id] }

    var hasConflicts: Bool { !conflicts.isEmpty }

    func conflicts(_ activityId: UUID) -> [PruningActivityParentConflict] {
        conflicts.filter { $0.activityId == activityId }
    }

    /// Activity ids with at least one conflicting parent field.
    var conflictedActivityIds: Set<UUID> { Set(conflicts.map(\.activityId)) }

    /// - Parameters:
    ///   - canonicalRows: every allocation of every activity in scope, BEFORE
    ///     the report's filters are applied.
    ///   - includeCost: false for roles without costing visibility; cost is then
    ///     absent from the model itself, not merely hidden when rendered.
    ///   - canonicalParents: the `pruning_activities` records keyed by activity
    ///     id, when the caller has them. These OUTRANK the allocation mirror.
    ///     Supplying them is what turns "first allocation wins" from a
    ///     resolution rule into a fallback.
    static func build(
        _ canonicalRows: [PruningActivityRow],
        includeCost: Bool,
        canonicalParents: [UUID: PruningActivityParentSource] = [:]
    ) -> PruningActivityAllocationModel {
        var order: [UUID] = []
        var buckets: [UUID: [PruningActivityRow]] = [:]
        for row in canonicalRows {
            if buckets[row.activityKey] == nil {
                order.append(row.activityKey)
                buckets[row.activityKey] = []
            }
            buckets[row.activityKey]?.append(row)
        }

        var parents: [UUID: PruningActivityParent] = [:]
        var shares: [UUID: PruningActivityAllocationShare] = [:]
        var conflicts: [PruningActivityParentConflict] = []

        for activityId in order {
            guard let rows = buckets[activityId], !rows.isEmpty else { continue }
            let ordered = canonicalOrder(rows)
            let resolution = ParentResolution(
                activityId: activityId,
                ordered: ordered,
                canonical: canonicalParents[activityId]
            )
            let parent = resolveParent(activityId, ordered, includeCost: includeCost, resolution: resolution)
            parents[activityId] = parent
            conflicts.append(contentsOf: resolution.conflicts)

            // Row equivalents are the natural measure of how much of the
            // activity each block represents. When none were recorded the
            // allocations split the labour evenly rather than losing it.
            let recorded = ordered.map { $0.rowEquivalents.isFinite && $0.rowEquivalents > 0 ? $0.rowEquivalents : 0 }
            let weights = recorded.reduce(0, +) > 0 ? recorded : Array(repeating: 1.0, count: ordered.count)
            let denominator = weights.reduce(0, +)

            let hours = allocatedSeries(parent.personHours, weights: weights, denominator: denominator)
            let costs = allocatedSeries(parent.labourCost, weights: weights, denominator: denominator)

            for (index, row) in ordered.enumerated() {
                shares[row.id] = PruningActivityAllocationShare(
                    allocationId: row.id,
                    activityId: activityId,
                    allocationNumber: index + 1,
                    fullAllocationCount: ordered.count,
                    share: denominator > 0 ? weights[index] / denominator : 0,
                    personHours: hours[index],
                    labourCost: costs[index]
                )
            }
        }

        return PruningActivityAllocationModel(
            parentsById: parents,
            sharesById: shares,
            conflicts: conflicts
        )
    }

    /// The stable allocation order: the server's `allocation_index` first, so
    /// the legacy primary leads, then block name, then id. Every derived
    /// number — allocation number, share, rounding remainder — depends on this
    /// order, so it must be identical on both platforms.
    static func canonicalOrder(_ rows: [PruningActivityRow]) -> [PruningActivityRow] {
        rows.sorted { lhs, rhs in
            if lhs.allocationIndex != rhs.allocationIndex {
                return lhs.allocationIndex < rhs.allocationIndex
            }
            let byBlock = lhs.blockName.localizedStandardCompare(rhs.blockName)
            if byBlock != .orderedSame { return byBlock == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Resolves the parent: the canonical `pruning_activities` record when the
    /// caller supplied one, otherwise the first allocation, in canonical order,
    /// that actually recorded a value.
    ///
    /// The allocation fallback is the correction to the legacy rule. The primary
    /// allocation is only a mirror, so a report must not go blank just because
    /// the primary was filtered out — the value belongs to the activity, and any
    /// allocation that carries it can supply it.
    ///
    /// Where the sources DISAGREE, `resolution` records a conflict. The export
    /// still renders the chosen value, because a blank cell would be a worse
    /// answer than a flagged one, but nothing about the disagreement is hidden.
    private static func resolveParent(
        _ activityId: UUID,
        _ ordered: [PruningActivityRow],
        includeCost: Bool,
        resolution: ParentResolution
    ) -> PruningActivityParent {
        let head = ordered[0]
        let canonical = resolution.canonical

        let workTaskTitle = resolution.text(.workTaskTitle, canonical?.workTaskTitle) { $0.workTaskTitle }
        let method = resolution.text(.method, canonical?.method) { $0.method } ?? head.method

        return PruningActivityParent(
            activityId: activityId,
            label: label(workTaskTitle: workTaskTitle, method: method),
            date: head.date,
            method: method,
            worker: resolution.text(.worker, canonical?.worker) { $0.worker },
            workTaskId: resolution.value(
                .workTask,
                canonical?.workTaskId,
                selector: { $0.workTaskId },
                format: { $0.uuidString }
            ),
            workTaskTitle: workTaskTitle,
            workTaskStatus: resolution.text(.workTaskStatus, canonical?.workTaskStatus) { $0.workTaskStatus },
            startTime: resolution.date(.startTime, canonical?.startTime) { $0.startTime },
            finishTime: resolution.date(.finishTime, canonical?.finishTime) { $0.finishTime },
            operationalHours: resolution.number(.operationalHours, canonical?.operationalHours) {
                $0.operationalHours
            },
            durationHours: resolution.number(.durationHours, canonical?.durationHours) { $0.durationHours },
            // Every allocation row carries the SAME task-derived person-hours,
            // so the parent total is one of them — never their sum.
            personHours: resolution.number(.personHours, canonical?.personHours) { $0.labourHours },
            labourCost: includeCost
                ? resolution.number(.labourCost, canonical?.labourCost) { $0.labourCost }
                : nil,
            // Notes are free text and legitimately differ per allocation, so
            // they are resolved without conflict reporting.
            notes: PruningActivityAllocationModel.cleaned(canonical?.notes)
                ?? ordered.compactMap { PruningActivityAllocationModel.cleaned($0.notes) }.first,
            isReversed: ordered.allSatisfy(\.isReversed),
            allocationCount: ordered.count,
            rowEquivalents: ordered.reduce(0) { total, row in
                total + (row.rowEquivalents.isFinite && row.rowEquivalents > 0 ? row.rowEquivalents : 0)
            },
            resolvedFromCanonicalParent: canonical != nil,
            hasContextConflict: !resolution.conflicts.isEmpty
        )
    }

    static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Picks one value per parent field and records every disagreement.
    ///
    /// Two allocations of the same activity should never carry different
    /// non-nil worker, Work Task, labour or timing values. When they do, the
    /// data is wrong — a corrupted legacy mirror or a half-applied sync — and
    /// choosing quietly by sort order would bury it.
    private final class ParentResolution {
        let activityId: UUID
        let ordered: [PruningActivityRow]
        let canonical: PruningActivityParentSource?
        private(set) var conflicts: [PruningActivityParentConflict] = []

        init(activityId: UUID, ordered: [PruningActivityRow], canonical: PruningActivityParentSource?) {
            self.activityId = activityId
            self.ordered = ordered
            self.canonical = canonical
        }

        func text(
            _ field: PruningActivityParentField,
            _ canonicalValue: String?,
            _ selector: @escaping (PruningActivityRow) -> String?
        ) -> String? {
            value(
                field,
                PruningActivityAllocationModel.cleaned(canonicalValue),
                selector: { PruningActivityAllocationModel.cleaned(selector($0)) },
                format: { $0 }
            )
        }

        func number(
            _ field: PruningActivityParentField,
            _ canonicalValue: Double?,
            _ selector: @escaping (PruningActivityRow) -> Double?
        ) -> Double? {
            value(
                field,
                canonicalValue.flatMap { $0.isFinite ? $0 : nil },
                selector: { selector($0).flatMap { value in value.isFinite ? value : nil } },
                // Compared at four decimals so float noise is not a "conflict".
                format: { String(format: "%.4f", $0) }
            )
        }

        func date(
            _ field: PruningActivityParentField,
            _ canonicalValue: Date?,
            _ selector: @escaping (PruningActivityRow) -> Date?
        ) -> Date? {
            value(
                field,
                canonicalValue,
                selector: selector,
                format: { String(format: "%.0f", $0.timeIntervalSince1970) }
            )
        }

        func value<T>(
            _ field: PruningActivityParentField,
            _ canonicalValue: T?,
            selector: (PruningActivityRow) -> T?,
            format: (T) -> String
        ) -> T? {
            let recorded = ordered.compactMap(selector)
            let chosen = canonicalValue ?? recorded.first
            var distinct: [String] = []
            if let canonicalValue {
                distinct.append(format(canonicalValue))
            }
            for value in recorded {
                let text = format(value)
                if !distinct.contains(text) { distinct.append(text) }
            }
            if distinct.count > 1 {
                conflicts.append(
                    PruningActivityParentConflict(
                        activityId: activityId,
                        field: field,
                        values: distinct,
                        resolution: canonicalValue != nil ? .canonicalParent : .firstAllocation,
                        resolvedValue: chosen.map(format)
                    )
                )
            }
            return chosen
        }
    }

    /// Activity name. There is no free-text activity title in the schema, so the
    /// linked Work Task's title is used when there is one and a method-derived
    /// label otherwise — never "Activity 3f2a…".
    static func label(workTaskTitle: String?, method: String) -> String {
        if let title = workTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let cleaned = method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Pruning" }
        return cleaned.lowercased().contains("prun") ? cleaned : "\(cleaned) pruning"
    }

    /// Splits `total` across `weights` with CUMULATIVE rounding, so the parts
    /// always add back up to the rounded total. The remainder falls on the last
    /// weight — the same one on iOS and Android.
    private static func allocatedSeries(
        _ total: Double?,
        weights: [Double],
        denominator: Double
    ) -> [Double?] {
        guard let total, total.isFinite, denominator > 0 else {
            return Array(repeating: nil, count: weights.count)
        }
        var running = 0.0
        var previous = 0.0
        return weights.map { weight in
            running += weight
            let cumulative = roundTo(total * (running / denominator), decimals: decimals)
            let value = roundTo(cumulative - previous, decimals: decimals)
            previous = cumulative
            return value
        }
    }

    /// Half-away-from-zero rounding, matching Kotlin's `round`.
    static func roundTo(_ value: Double, decimals: Int) -> Double {
        guard value.isFinite else { return value }
        var factor = 1.0
        for _ in 0..<decimals { factor *= 10 }
        return (value * factor).rounded() / factor
    }
}
