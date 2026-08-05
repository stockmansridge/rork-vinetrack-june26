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

    func parent(_ activityId: UUID) -> PruningActivityParent? { parentsById[activityId] }

    func parent(of row: PruningActivityRow) -> PruningActivityParent? { parentsById[row.activityKey] }

    func share(_ allocationId: UUID) -> PruningActivityAllocationShare? { sharesById[allocationId] }

    func share(of row: PruningActivityRow) -> PruningActivityAllocationShare? { sharesById[row.id] }

    /// - Parameters:
    ///   - canonicalRows: every allocation of every activity in scope, BEFORE
    ///     the report's filters are applied.
    ///   - includeCost: false for roles without costing visibility; cost is then
    ///     absent from the model itself, not merely hidden when rendered.
    static func build(
        _ canonicalRows: [PruningActivityRow],
        includeCost: Bool
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

        for activityId in order {
            guard let rows = buckets[activityId], !rows.isEmpty else { continue }
            let ordered = canonicalOrder(rows)
            let parent = resolveParent(activityId, ordered, includeCost: includeCost)
            parents[activityId] = parent

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

        return PruningActivityAllocationModel(parentsById: parents, sharesById: shares)
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

    /// Resolves the parent from ALL allocations: the first allocation that
    /// actually recorded a value wins.
    ///
    /// This is the correction to the legacy rule. The primary allocation is only
    /// a mirror, so a report must not go blank just because the primary was
    /// filtered out — the value belongs to the activity, and any allocation that
    /// carries it can supply it.
    private static func resolveParent(
        _ activityId: UUID,
        _ ordered: [PruningActivityRow],
        includeCost: Bool
    ) -> PruningActivityParent {
        let head = ordered[0]

        func first<T>(_ selector: (PruningActivityRow) -> T?) -> T? {
            for row in ordered {
                if let value = selector(row) { return value }
            }
            return nil
        }

        func firstText(_ selector: (PruningActivityRow) -> String?) -> String? {
            first { row in
                guard let value = selector(row)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
        }

        let workTaskTitle = firstText { $0.workTaskTitle }
        let method = firstText { $0.method } ?? head.method

        return PruningActivityParent(
            activityId: activityId,
            label: label(workTaskTitle: workTaskTitle, method: method),
            date: head.date,
            method: method,
            worker: firstText { $0.worker },
            workTaskId: first { $0.workTaskId },
            workTaskTitle: workTaskTitle,
            workTaskStatus: firstText { $0.workTaskStatus },
            startTime: first { $0.startTime },
            finishTime: first { $0.finishTime },
            operationalHours: first { $0.operationalHours },
            durationHours: first { $0.durationHours },
            // Every allocation row carries the SAME task-derived person-hours,
            // so the parent total is one of them — never their sum.
            personHours: first { $0.labourHours },
            labourCost: includeCost ? first { $0.labourCost } : nil,
            notes: firstText { $0.notes },
            isReversed: ordered.allSatisfy(\.isReversed),
            allocationCount: ordered.count,
            rowEquivalents: ordered.reduce(0) { total, row in
                total + (row.rowEquivalents.isFinite && row.rowEquivalents > 0 ? row.rowEquivalents : 0)
            }
        )
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
