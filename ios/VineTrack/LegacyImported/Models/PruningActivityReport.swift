import Foundation

/// SHARED CONTRACT — the Pruning Activity Report.
///
/// iOS and Android build the SAME rows, from the SAME server-authoritative
/// pruning entries, with the SAME column set, status rules, filter meanings,
/// sort defaults and summary maths. Anything added here must be mirrored in
/// `PruningActivityReport.kt`.
///
/// The report NEVER re-interprets pruning records: rows are projected from
/// the existing `PruningEntry` cache (the same data the tracker, the
/// dashboard and the SQL 115 parity check use) plus the block, Work Task and
/// labour-line context the app already holds.

// MARK: - Status

/// Lifecycle of one pruning record.
///
/// `edited` is derived from the server's own `updated_at` vs `created_at` —
/// never invented. An entry that has not been pulled back from the server yet
/// (no `updatedAt`) is `active`.
nonisolated enum PruningActivityStatus: String, Sendable, CaseIterable, Identifiable {
    case active
    case edited
    case reversed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: return "Active"
        case .edited: return "Edited"
        case .reversed: return "Reversed"
        }
    }

    /// Reversed work is audit history only — never editable, never reversible
    /// again, never part of an active total.
    var countsTowardsTotals: Bool { self != .reversed }

    /// Tolerance (seconds) between `created_at` and `updated_at` below which a
    /// record counts as untouched. A create writes both stamps in the same
    /// statement, so they can differ by microseconds.
    static let editedToleranceSeconds: TimeInterval = 2

    static func resolve(reversedAt: Date?, createdAt: Date?, updatedAt: Date?) -> PruningActivityStatus {
        if reversedAt != nil { return .reversed }
        guard let createdAt, let updatedAt else { return .active }
        return updatedAt.timeIntervalSince(createdAt) > editedToleranceSeconds ? .edited : .active
    }
}

// MARK: - Row

/// Block context the report needs for one paddock — resolved ONCE per block
/// so a large history never triggers per-record lookups (no N+1).
nonisolated struct PruningActivityBlockContext: Sendable {
    let name: String
    let variety: String?
    /// The block's actual rows, used to convert quarters into exact vines.
    let rows: [PruningRowRef]

    init(name: String, variety: String?, rows: [PruningRowRef]) {
        self.name = name
        self.variety = variety
        self.rows = rows
    }
}

/// One fully-resolved report row. Every optional is genuinely unavailable for
/// that record and renders as "—" — never as a misleading zero.
nonisolated struct PruningActivityRow: Identifiable, Sendable, Equatable {
    let id: UUID
    let paddockId: UUID
    let workTaskId: UUID?
    /// The PARENT activity this row is one allocation of (sql/166). A legacy
    /// single-block record is its own activity, so this is never nil and
    /// grouping by it is safe for every record ever written.
    let activityKey: UUID
    /// 0 for the PRIMARY allocation — the one carrying the activity's labour.
    let allocationIndex: Int
    /// Pruning season (calendar year of the entry date).
    let seasonYear: Int
    let date: Date
    let worker: String?
    let blockName: String
    let variety: String?
    /// Distinct row numbers touched by this record, ascending (natural order).
    let rowNumbers: [Int]
    /// Quarters (row sections) completed by this record.
    let quarters: Int
    let rowEquivalents: Double
    /// Exact vines completed — nil when the block's rows can't be resolved.
    let vines: Double?
    /// This allocation's own client vine estimate, as recorded.
    let estimatedVines: Int
    /// The RESOLVED authoritative labour hours: summed Work Task labour lines
    /// when the linked task has any, otherwise the legacy activity value. Never
    /// both — see `PruningActivityReport.rows`.
    let labourHours: Double?
    /// The activity's OWN recorded operational hours, independent of the Work
    /// Task's person-hours. Elapsed operational time is not person-hours and is
    /// never multiplied by the crew size.
    let operationalHours: Double?
    let startTime: Date?
    let finishTime: Date?
    /// Finish − start, in hours.
    let durationHours: Double?
    let vinesPerHour: Double?
    /// Labour cost of the linked Work Task; nil when no rate was recorded or
    /// costing is not visible to this user.
    let labourCost: Double?
    let workTaskTitle: String?
    let workTaskStatus: String?
    let notes: String?
    let enteredBy: String?
    let createdAt: Date?
    let updatedAt: Date?
    let method: String
    let status: PruningActivityStatus

    var isReversed: Bool { status == .reversed }
    var hasWorkTask: Bool { workTaskId != nil }

    /// True when this row carries the activity's own labour/timing/task link —
    /// the PRIMARY allocation. Activity-level values are written to exactly one
    /// allocation, which is why an export can never double-count them.
    var isPrimaryAllocation: Bool { allocationIndex == 0 }

    /// Lowest row number — the natural sort key ("Row 2" before "Row 10").
    var rowSortKey: Int? { rowNumbers.min() }

    /// "5" or "5–12" from the ACTUAL row numbers.
    var rowRangeLabel: String? {
        guard let low = rowNumbers.min(), let high = rowNumbers.max() else { return nil }
        return low == high ? "\(low)" : "\(low)–\(high)"
    }

    /// "3 of 4" style quarter summary — how much of a row was recorded.
    var quartersLabel: String? {
        guard quarters > 0 else { return nil }
        return "\(quarters)"
    }
}

// MARK: - Columns

/// The report's column set. Identical labels and order on both platforms.
nonisolated enum PruningActivityColumn: String, Sendable, CaseIterable, Identifiable {
    case date
    case worker
    case block
    case variety
    case rows
    case quarters
    case vines
    case hours
    case start
    case finish
    case duration
    case vinesPerHour
    case labourCost
    case workTask
    case notes
    case enteredBy
    case created
    case updated
    case status

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: return "Date"
        case .worker: return "Worker"
        case .block: return "Block"
        case .variety: return "Variety"
        case .rows: return "Rows"
        case .quarters: return "Quarters"
        case .vines: return "Vines"
        case .hours: return "Hours"
        case .start: return "Start"
        case .finish: return "Finish"
        case .duration: return "Duration"
        case .vinesPerHour: return "Vines / hr"
        case .labourCost: return "Labour cost"
        case .workTask: return "Work Task"
        case .notes: return "Notes"
        case .enteredBy: return "Entered by"
        case .created: return "Created"
        case .updated: return "Updated"
        case .status: return "Status"
        }
    }

    /// Notes is free text with no meaningful order — everything else sorts.
    var isSortable: Bool { self != .notes }

    /// Costing columns are hidden from roles without costing visibility.
    var isCosting: Bool { self == .labourCost }

    /// The first columns are the most useful operational fields; the rest
    /// continue horizontally in this order.
    static let displayOrder: [PruningActivityColumn] = [
        .date, .worker, .block, .rows, .vines, .hours, .status,
        .variety, .quarters, .start, .finish, .duration, .vinesPerHour,
        .labourCost, .workTask, .enteredBy, .created, .updated, .notes
    ]
}

/// Tri-state sort: unsorted → ascending → descending → unsorted.
nonisolated struct PruningActivitySort: Sendable, Equatable {
    /// Nil = the default order (date descending, then created descending).
    var column: PruningActivityColumn?
    var ascending: Bool

    static let `default` = PruningActivitySort(column: nil, ascending: false)

    /// Cycles the state for a tapped heading.
    func cycled(_ tapped: PruningActivityColumn) -> PruningActivitySort {
        guard column == tapped else {
            return PruningActivitySort(column: tapped, ascending: true)
        }
        return ascending
            ? PruningActivitySort(column: tapped, ascending: false)
            : .default
    }

    func direction(for candidate: PruningActivityColumn) -> PruningActivitySortDirection {
        guard column == candidate else { return .none }
        return ascending ? .ascending : .descending
    }
}

nonisolated enum PruningActivitySortDirection: Sendable {
    case none
    case ascending
    case descending
}

// MARK: - Filters

nonisolated enum PruningActivityTaskLink: String, Sendable, CaseIterable, Identifiable {
    case all
    case linked
    case notLinked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .linked: return "Linked"
        case .notLinked: return "Not linked"
        }
    }
}

/// Report filters. An EMPTY set means "no restriction" for that facet.
nonisolated struct PruningActivityFilter: Sendable, Equatable {
    var seasonYear: Int?
    var dateFrom: Date?
    var dateTo: Date?
    var workers: Set<String> = []
    var blocks: Set<UUID> = []
    var varieties: Set<String> = []
    var statuses: Set<PruningActivityStatus> = []
    var taskLink: PruningActivityTaskLink = .all
    var search: String = ""

    init(seasonYear: Int? = nil) {
        self.seasonYear = seasonYear
    }

    /// True when anything other than the default season is applied — drives
    /// the "Clear filters" affordance.
    var hasRestrictions: Bool {
        dateFrom != nil || dateTo != nil || !workers.isEmpty || !blocks.isEmpty
            || !varieties.isEmpty || !statuses.isEmpty || taskLink != .all
            || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Summary

/// Totals for the CURRENT filtered result. Reversed rows never contribute to
/// vines, hours, productivity or cost — they are counted separately.
///
/// There are TWO labour figures and they answer different questions:
///
///  * `labourHours` / `labourCost` are ALLOCATED — the proportional share of
///    each included allocation. These are the totals that match the rows on
///    screen, and they stay correct when a multi-block activity is filtered to
///    one of its blocks.
///  * `wholeActivityLabourHours` / `wholeActivityLabourCost` are the totals of
///    the FULL parent activities that the result touches, de-duplicated by
///    activity id. When `partialActivities` is greater than zero these describe
///    work that reaches beyond the filtered blocks.
///
/// They are equal only when every activity in the result is complete.
nonisolated struct PruningActivitySummary: Sendable, Equatable {
    var jobs: Int = 0
    var activeRecords: Int = 0
    var reversedRecords: Int = 0
    var vines: Double = 0
    /// ALLOCATED person-hours for the included allocations.
    var labourHours: Double = 0
    var averageVinesPerHour: Double?
    /// ALLOCATED labour cost for the included allocations.
    var labourCost: Double?
    /// Distinct parent activities represented in the result.
    var activities: Int = 0
    /// Whole-activity person-hours, de-duplicated by activity id.
    var wholeActivityLabourHours: Double = 0
    /// Whole-activity labour cost, de-duplicated by activity id.
    var wholeActivityLabourCost: Double?
    /// Activities represented by only SOME of their allocations.
    var partialActivities: Int = 0

    /// True when the result shows part of at least one multi-block activity.
    var hasPartialActivities: Bool { partialActivities > 0 }

    static let empty = PruningActivitySummary()
}

// MARK: - Report engine

nonisolated enum PruningActivityReport {

    /// Projects pruning entries into report rows.
    ///
    /// All related entities are passed in pre-indexed — the caller resolves
    /// blocks, Work Tasks, labour costs and account names ONCE, so building a
    /// large history never performs a per-record lookup.
    ///
    /// LABOUR AUTHORITY: `labourHours` / `labourCosts` come from the linked Work
    /// Task's labour lines and win outright. The entry's own
    /// `labourHours`/legacy rate are used ONLY when the task has no lines, so a
    /// row never mixes the two sources and no total can count labour twice.
    static func rows(
        entries: [PruningEntry],
        blocks: [UUID: PruningActivityBlockContext],
        workTaskTitles: [UUID: String],
        workTaskStatuses: [UUID: String] = [:],
        labourCosts: [UUID: Double],
        labourHours: [UUID: Double] = [:],
        accountNames: [UUID: String],
        calendar: Calendar = .current
    ) -> [PruningActivityRow] {
        entries.map { entry in
            let context = blocks[entry.paddockId]
            let rows = context?.rows ?? []
            let vines: Double? = rows.isEmpty
                ? nil
                : PruningCalculator.exactVines(for: entry.segments, rows: rows)
            // Work Task person-hours are authoritative; the legacy activity
            // hours are the fallback for records with no labour lines.
            let taskHours = entry.workTaskId.flatMap { labourHours[$0] }
            let hours = taskHours ?? entry.labourHours.flatMap { $0 > 0 ? $0 : nil }
            let vinesPerHour: Double? = {
                guard let vines, let hours, hours > 0 else { return nil }
                return vines / hours
            }()
            let rowNumbers = Array(Set(entry.segments.map(\.row))).sorted()
            let notes = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let worker = entry.worker.trimmingCharacters(in: .whitespacesAndNewlines)

            return PruningActivityRow(
                id: entry.id,
                paddockId: entry.paddockId,
                workTaskId: entry.workTaskId,
                activityKey: entry.activityKey,
                allocationIndex: entry.allocationOrder,
                seasonYear: calendar.component(.year, from: entry.date),
                date: entry.date,
                worker: worker.isEmpty ? nil : worker,
                blockName: context?.name ?? "Unknown block",
                variety: context?.variety,
                rowNumbers: rowNumbers,
                quarters: entry.segments.count,
                rowEquivalents: entry.rowEquivalents,
                vines: vines,
                estimatedVines: entry.estimatedVines,
                labourHours: hours,
                operationalHours: entry.labourHours.flatMap { $0 > 0 ? $0 : nil },
                startTime: entry.startTime,
                finishTime: entry.finishTime,
                durationHours: entry.durationHours,
                vinesPerHour: vinesPerHour,
                labourCost: entry.workTaskId.flatMap { labourCosts[$0] },
                workTaskTitle: entry.workTaskId.flatMap { workTaskTitles[$0] },
                workTaskStatus: entry.workTaskId.flatMap { workTaskStatuses[$0] },
                notes: notes.isEmpty ? nil : notes,
                enteredBy: entry.enteredBy.flatMap { accountNames[$0] },
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                method: PruningMethod(rawValue: entry.method.rawValue)?.label ?? entry.method.label,
                status: PruningActivityStatus.resolve(
                    reversedAt: entry.reversedAt,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt
                )
            )
        }
    }

    /// Applies the filter set. Search matches worker, block, variety, row
    /// number, Work Task title and notes.
    static func filtered(
        _ rows: [PruningActivityRow],
        with filter: PruningActivityFilter,
        calendar: Calendar = .current
    ) -> [PruningActivityRow] {
        let needle = filter.search
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let from = filter.dateFrom.map { calendar.startOfDay(for: $0) }
        let to = filter.dateTo.map { calendar.startOfDay(for: $0) }

        return rows.filter { row in
            if let season = filter.seasonYear, row.seasonYear != season { return false }
            let day = calendar.startOfDay(for: row.date)
            if let from, day < from { return false }
            if let to, day > to { return false }
            if !filter.workers.isEmpty, !filter.workers.contains(row.worker ?? "") { return false }
            if !filter.blocks.isEmpty, !filter.blocks.contains(row.paddockId) { return false }
            if !filter.varieties.isEmpty, !filter.varieties.contains(row.variety ?? "") { return false }
            if !filter.statuses.isEmpty, !filter.statuses.contains(row.status) { return false }
            switch filter.taskLink {
            case .all: break
            case .linked: if !row.hasWorkTask { return false }
            case .notLinked: if row.hasWorkTask { return false }
            }
            guard !needle.isEmpty else { return true }
            return matches(row, needle: needle)
        }
    }

    private static func matches(_ row: PruningActivityRow, needle: String) -> Bool {
        let haystack: [String?] = [
            row.worker,
            row.blockName,
            row.variety,
            row.workTaskTitle,
            row.notes,
            row.rowRangeLabel,
            row.rowNumbers.map(String.init).joined(separator: " ")
        ]
        return haystack.contains { value in
            guard let value, !value.isEmpty else { return false }
            return value.lowercased().contains(needle)
        }
    }

    /// Sorts by the TYPED value of a column. Blank values always sort last,
    /// in both directions; ties fall back to the default order (date
    /// descending, then created descending) so the result is deterministic.
    static func sorted(_ rows: [PruningActivityRow], by sort: PruningActivitySort) -> [PruningActivityRow] {
        guard let column = sort.column, column.isSortable else {
            return rows.sorted(by: defaultOrder)
        }
        let ascending = sort.ascending
        return rows.sorted { lhs, rhs in
            if let decision = compare(lhs, rhs, column: column, ascending: ascending) {
                return decision
            }
            return defaultOrder(lhs, rhs)
        }
    }

    private static func defaultOrder(_ lhs: PruningActivityRow, _ rhs: PruningActivityRow) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        let left = lhs.createdAt ?? .distantPast
        let right = rhs.createdAt ?? .distantPast
        if left != right { return left > right }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func compare(
        _ lhs: PruningActivityRow,
        _ rhs: PruningActivityRow,
        column: PruningActivityColumn,
        ascending: Bool
    ) -> Bool? {
        switch column {
        case .date:
            return order(lhs.date, rhs.date, ascending)
        case .worker:
            return orderText(lhs.worker, rhs.worker, ascending)
        case .block:
            return orderText(lhs.blockName, rhs.blockName, ascending)
        case .variety:
            return orderText(lhs.variety, rhs.variety, ascending)
        case .rows:
            return order(lhs.rowSortKey, rhs.rowSortKey, ascending)
        case .quarters:
            return order(lhs.quarters, rhs.quarters, ascending)
        case .vines:
            return order(lhs.vines, rhs.vines, ascending)
        case .hours:
            return order(lhs.labourHours, rhs.labourHours, ascending)
        case .start:
            return order(minutes(lhs.startTime), minutes(rhs.startTime), ascending)
        case .finish:
            return order(minutes(lhs.finishTime), minutes(rhs.finishTime), ascending)
        case .duration:
            return order(lhs.durationHours, rhs.durationHours, ascending)
        case .vinesPerHour:
            return order(lhs.vinesPerHour, rhs.vinesPerHour, ascending)
        case .labourCost:
            return order(lhs.labourCost, rhs.labourCost, ascending)
        case .workTask:
            return orderText(lhs.workTaskTitle, rhs.workTaskTitle, ascending)
        case .enteredBy:
            return orderText(lhs.enteredBy, rhs.enteredBy, ascending)
        case .created:
            return order(lhs.createdAt, rhs.createdAt, ascending)
        case .updated:
            return order(lhs.updatedAt, rhs.updatedAt, ascending)
        case .status:
            return orderText(lhs.status.label, rhs.status.label, ascending)
        case .notes:
            return nil
        }
    }

    /// Minutes since midnight — times sort as times, never as strings.
    private static func minutes(_ date: Date?, calendar: Calendar = .current) -> Int? {
        guard let date else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        return hour * 60 + minute
    }

    /// nil-last comparison for any comparable value. Returns nil on a tie.
    private static func order<T: Comparable>(_ lhs: T?, _ rhs: T?, _ ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?):
            if left == right { return nil }
            return ascending ? left < right : left > right
        }
    }

    /// Case- and locale-aware text order with natural number handling, blanks
    /// last ("Row 2" before "Row 10", "block 9" before "Block 10").
    private static func orderText(_ lhs: String?, _ rhs: String?, _ ascending: Bool) -> Bool? {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (left?.isEmpty == false ? left : nil, right?.isEmpty == false ? right : nil) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case let (a?, b?):
            let result = a.localizedStandardCompare(b)
            if result == .orderedSame { return nil }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// Totals for the filtered result. Reversed rows are counted but never
    /// contribute vines, hours, productivity or cost.
    ///
    /// Labour is ALLOCATED per allocation, so a multi-block activity contributes
    /// its person-hours ONCE across its blocks instead of once per block. The
    /// whole-activity figures are reported separately, de-duplicated by activity
    /// id, so a partly-filtered activity can still be reconciled to its parent.
    ///
    /// - Parameter canonicalRows: every allocation of every activity BEFORE
    ///   filtering, supplying the parent totals and the allocation-share
    ///   denominator. Defaults to `rows` for an unfiltered summary.
    static func summary(
        _ rows: [PruningActivityRow],
        includeCost: Bool,
        canonicalRows: [PruningActivityRow]? = nil
    ) -> PruningActivitySummary {
        let model = PruningActivityAllocationModel.build(canonicalRows ?? rows, includeCost: includeCost)

        var summary = PruningActivitySummary()
        summary.jobs = rows.count
        var vinesWithHours = 0.0
        var hoursWithVines = 0.0
        var cost = 0.0
        var sawCost = false
        var includedPerActivity: [UUID: Int] = [:]
        var activityOrder: [UUID] = []

        for row in rows {
            guard row.status.countsTowardsTotals else {
                summary.reversedRecords += 1
                continue
            }
            summary.activeRecords += 1
            summary.vines += row.vines ?? 0
            if includedPerActivity[row.activityKey] == nil { activityOrder.append(row.activityKey) }
            includedPerActivity[row.activityKey, default: 0] += 1

            let share = model.share(of: row)
            if let hours = share?.personHours, hours > 0 {
                summary.labourHours += hours
                if let vines = row.vines {
                    vinesWithHours += vines
                    hoursWithVines += hours
                }
            }
            if includeCost, let rowCost = share?.labourCost {
                cost += rowCost
                sawCost = true
            }
        }

        // Whole-activity totals count each parent ONCE, however many of its
        // allocations the filter admitted.
        var wholeHours = 0.0
        var wholeCost = 0.0
        var sawWholeCost = false
        var partial = 0
        for activityId in activityOrder {
            guard let parent = model.parent(activityId) else { continue }
            wholeHours += parent.personHours ?? 0
            if includeCost, let parentCost = parent.labourCost {
                wholeCost += parentCost
                sawWholeCost = true
            }
            if (includedPerActivity[activityId] ?? 0) < parent.allocationCount { partial += 1 }
        }

        summary.averageVinesPerHour = hoursWithVines > 0 ? vinesWithHours / hoursWithVines : nil
        summary.labourCost = sawCost ? cost : nil
        summary.activities = activityOrder.count
        summary.wholeActivityLabourHours = wholeHours
        summary.wholeActivityLabourCost = sawWholeCost ? wholeCost : nil
        summary.partialActivities = partial
        return summary
    }
}
