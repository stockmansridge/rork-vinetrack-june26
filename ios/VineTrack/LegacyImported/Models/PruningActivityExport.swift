import Foundation

/// SHARED CONTRACT — Pruning Activity Report EXPORTS (CSV + PDF).
///
/// Anything changed here must be mirrored in `PruningActivityExport.kt`. The
/// regression fixtures in `PruningActivityExportTests.swift` and
/// `PruningActivityExportTest.kt` are byte-for-byte the same.
///
/// ## Why this exists
///
/// A pruning activity is ONE piece of work that may cover MANY blocks (sql/166).
/// `pruning_entries` is the allocation table, so a two-block activity is two
/// rows in the report — and naively exporting both rows with the activity's
/// labour on each would make every spreadsheet `SUM()` count that labour twice.
///
/// The rule this file enforces:
///
///  * ALLOCATION-level quantities (block, variety, rows, quarters, row
///    equivalents, vines) appear on EVERY allocation row.
///  * ACTIVITY-level values (operational hours, Work Task person-hours, labour
///    cost, worker/crew, start, finish, duration, notes) appear on the FIRST
///    allocation row only.
///  * Suppressed values are BLANK, never `0` — a zero claims a real recorded
///    measurement of nothing.
///
/// This is not a presentation trick: the activity's labour and timing are stored
/// on exactly one allocation (`allocation_index = 0`, the PRIMARY), so the first
/// allocation row is the only row that ever holds them. The export makes that
/// storage invariant visible instead of fighting it.
///
/// ## Labour authority
///
/// Unchanged from `WorkTaskLabourCosting`: summed Work Task labour lines win
/// outright, and the legacy activity-level value is used ONLY when the linked
/// task has no lines. The two sources are never combined, so the exported
/// person-hours and labour-cost columns sum to the report summary exactly.
nonisolated enum PruningActivityExport {

    /// One CSV row — one ALLOCATION of one activity.
    ///
    /// Every activity-level field is optional and populated ONLY when
    /// `isActivityTotalsRow` is true. No field carries a UUID: internal ids are
    /// used for grouping and then dropped, so an exported file never leaks a
    /// database identifier.
    nonisolated struct Row: Sendable, Equatable {
        /// Raw chronological `yyyy-MM-dd`, retained for sorting and pivots.
        let dateIso: String
        /// `dd/MM/yyyy`.
        let dateDisplay: String
        /// "Monday".
        let weekday: String
        /// The activity's name — the linked Work Task title, else "Spur pruning".
        let activityLabel: String
        let allocationNumber: Int
        let allocationCount: Int
        /// "block 1 of 2".
        let allocationLabel: String
        let blockName: String
        let variety: String?
        /// "90" or "90–108", from the ACTUAL row numbers.
        let rowRange: String?
        let quarters: Int
        let rowEquivalents: Double
        /// Exact vines when the block's rows resolve, else this allocation's estimate.
        let estimatedVines: Double?
        let method: String
        // --- activity level: first allocation row only ---------------------
        let worker: String?
        /// The activity's own recorded operational hours.
        let operationalHours: Double?
        /// RESOLVED authoritative person-hours (task labour lines, else legacy).
        let personHours: Double?
        /// Nil when costing is not visible to this role, or none was recorded.
        let labourCost: Double?
        let workTaskTitle: String?
        let workTaskStatus: String?
        let startTime: String?
        let finishTime: String?
        let durationHours: Double?
        let notes: String?
        // ------------------------------------------------------------------
        let isReversed: Bool
        /// True on the first allocation row of each activity — the one carrying
        /// the activity-level totals. Exported as a `Yes`/`No` column so pivot
        /// tables can aggregate activity values with no de-duplication.
        let isActivityTotalsRow: Bool
    }

    /// One activity and all of its exported allocations — the PDF's grouped
    /// layout. The activity's labour and timing are stated ONCE in the header,
    /// so the allocation list underneath is pure block detail.
    nonisolated struct Group: Sendable, Identifiable {
        let id: UUID
        let activityLabel: String
        let dateIso: String
        /// "Monday 3 August 2026".
        let dateDisplay: String
        let method: String
        let worker: String?
        let operationalHours: Double?
        let personHours: Double?
        let labourCost: Double?
        let workTaskTitle: String?
        let workTaskStatus: String?
        let startTime: String?
        let finishTime: String?
        let durationHours: Double?
        let notes: String?
        let isReversed: Bool
        let allocations: [Row]

        var allocationCount: Int { allocations.count }
        var isMultiBlock: Bool { allocations.count > 1 }

        /// "Pinot Noir + Cabernet Franc".
        var blockSummary: String {
            var seen = Set<String>()
            return allocations
                .map(\.blockName)
                .filter { seen.insert($0).inserted }
                .joined(separator: " + ")
        }

        var totalQuarters: Int { allocations.reduce(0) { $0 + $1.quarters } }
        var totalRowEquivalents: Double { allocations.reduce(0) { $0 + $1.rowEquivalents } }
        var totalVines: Double { allocations.reduce(0) { $0 + ($1.estimatedVines ?? 0) } }
    }

    // MARK: - Grouping

    /// Groups the report's ALREADY filtered and sorted rows into parent
    /// activities, preserving each activity as a CONTIGUOUS block.
    ///
    /// Group order follows the report's own visible order: an activity ranks by
    /// the position of its first-appearing row, so changing the report's sort
    /// reorders the groups without ever scattering one activity's allocations
    /// through the file.
    ///
    /// Allocation order inside a group is the server's `allocation_index`, which
    /// puts the PRIMARY allocation — the one holding the activity's labour and
    /// timing — first. That is what makes "totals on row 1" true rather than
    /// hopeful.
    ///
    /// - Parameters:
    ///   - reportRows: the report's filtered + sorted rows, in visible order.
    ///   - includeCost: false for roles without costing visibility; the labour
    ///     cost is then dropped from the data, not merely hidden in the renderer.
    static func groups(
        _ reportRows: [PruningActivityRow],
        includeCost: Bool,
        calendar: Calendar = .current
    ) -> [Group] {
        var order: [UUID] = []
        var buckets: [UUID: [PruningActivityRow]] = [:]
        for row in reportRows {
            if buckets[row.activityKey] == nil {
                order.append(row.activityKey)
                buckets[row.activityKey] = []
            }
            buckets[row.activityKey]?.append(row)
        }

        return order.compactMap { key -> Group? in
            guard let activityRows = buckets[key], !activityRows.isEmpty else { return nil }
            let allocations = activityRows.sorted { lhs, rhs in
                if lhs.allocationIndex != rhs.allocationIndex {
                    return lhs.allocationIndex < rhs.allocationIndex
                }
                let byBlock = lhs.blockName.localizedStandardCompare(rhs.blockName)
                if byBlock != .orderedSame { return byBlock == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            // The activity's own values live on the PRIMARY allocation. When a
            // filter has excluded that allocation the values are genuinely not
            // in this result, and every activity-level field stays blank rather
            // than being invented from a sibling row.
            let head = allocations[0]
            let count = allocations.count
            let label = activityLabel(head)

            let exported: [Row] = allocations.enumerated().map { index, row in
                let isTotals = index == 0
                return Row(
                    dateIso: isoDate(row.date, calendar: calendar),
                    dateDisplay: auDate(row.date, calendar: calendar),
                    weekday: weekday(row.date, calendar: calendar),
                    activityLabel: label,
                    allocationNumber: index + 1,
                    allocationCount: count,
                    allocationLabel: allocationLabel(number: index + 1, count: count),
                    blockName: row.blockName,
                    variety: row.variety,
                    rowRange: row.rowRangeLabel,
                    quarters: row.quarters,
                    rowEquivalents: row.rowEquivalents,
                    estimatedVines: row.vines ?? (row.estimatedVines > 0 ? Double(row.estimatedVines) : nil),
                    method: row.method,
                    // Everything below is numeric or activity-level narrative
                    // and appears exactly once per activity.
                    worker: isTotals ? head.worker : nil,
                    operationalHours: isTotals ? head.operationalHours : nil,
                    personHours: isTotals ? head.labourHours : nil,
                    labourCost: (isTotals && includeCost) ? head.labourCost : nil,
                    // Work Task title and status repeat on every allocation:
                    // they are text, they cannot be summed, and repeating them
                    // keeps a wide spreadsheet readable when scrolled.
                    workTaskTitle: row.workTaskTitle ?? head.workTaskTitle,
                    workTaskStatus: row.workTaskStatus ?? head.workTaskStatus,
                    startTime: isTotals ? time(head.startTime, calendar: calendar) : nil,
                    finishTime: isTotals ? time(head.finishTime, calendar: calendar) : nil,
                    durationHours: isTotals ? head.durationHours : nil,
                    notes: isTotals ? head.notes : nil,
                    isReversed: row.isReversed,
                    isActivityTotalsRow: isTotals
                )
            }

            return Group(
                id: key,
                activityLabel: label,
                dateIso: isoDate(head.date, calendar: calendar),
                dateDisplay: longDate(head.date, calendar: calendar),
                method: head.method,
                worker: head.worker,
                operationalHours: head.operationalHours,
                personHours: head.labourHours,
                labourCost: includeCost ? head.labourCost : nil,
                workTaskTitle: head.workTaskTitle,
                workTaskStatus: head.workTaskStatus,
                startTime: time(head.startTime, calendar: calendar),
                finishTime: time(head.finishTime, calendar: calendar),
                durationHours: head.durationHours,
                notes: head.notes,
                isReversed: head.isReversed,
                allocations: exported
            )
        }
    }

    /// The flat CSV row set — every allocation, activities kept contiguous.
    static func rows(
        _ reportRows: [PruningActivityRow],
        includeCost: Bool,
        calendar: Calendar = .current
    ) -> [Row] {
        groups(reportRows, includeCost: includeCost, calendar: calendar).flatMap(\.allocations)
    }

    /// Activity name. There is no free-text activity title in the schema, so the
    /// linked Work Task's title is used when there is one and a method-derived
    /// label otherwise — never a UUID, never "Activity 3f2a…".
    private static func activityLabel(_ head: PruningActivityRow) -> String {
        if let title = head.workTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        let method = head.method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !method.isEmpty else { return "Pruning" }
        return method.lowercased().contains("prun") ? method : "\(method) pruning"
    }

    /// "block 1 of 2"; a single-allocation activity says "whole activity".
    static func allocationLabel(number: Int, count: Int) -> String {
        count <= 1 ? "whole activity" : "block \(number) of \(count)"
    }

    // MARK: - CSV

    /// Column headings, in export order. The labour cost column is absent
    /// entirely when `includeCost` is false, so a supervisor's export has no
    /// empty cost column hinting at withheld data.
    static func headers(includeCost: Bool) -> [String] {
        var headers: [String] = [
            "Date (ISO)",
            "Activity Date",
            "Weekday",
            "Activity",
            "Allocation Number",
            "Allocation Count",
            "Allocation Label",
            "Block",
            "Variety",
            "Rows",
            "Quarters",
            "Row Equivalents",
            "Estimated Vines",
            "Pruning Method",
            "Worker or Crew",
            "Operational Hours",
            "Work Task Person-Hours"
        ]
        if includeCost { headers.append("Labour Cost") }
        headers.append(contentsOf: [
            "Work Task",
            "Work Task Status",
            "Start Time",
            "Finish Time",
            "Duration (h)",
            "Notes",
            "Reversed",
            "Activity Totals Row"
        ])
        return headers
    }

    /// One row's cells, aligned with `headers(includeCost:)`.
    static func cells(_ row: Row, includeCost: Bool) -> [String] {
        var cells: [String] = [
            row.dateIso,
            row.dateDisplay,
            row.weekday,
            row.activityLabel,
            String(row.allocationNumber),
            String(row.allocationCount),
            row.allocationLabel,
            row.blockName,
            row.variety ?? "",
            row.rowRange ?? "",
            row.quarters > 0 ? String(row.quarters) : "",
            number(row.rowEquivalents > 0 ? row.rowEquivalents : nil, decimals: 2),
            number(row.estimatedVines, decimals: 0),
            row.method,
            row.worker ?? "",
            number(row.operationalHours, decimals: 2),
            number(row.personHours, decimals: 2)
        ]
        if includeCost { cells.append(number(row.labourCost, decimals: 2)) }
        cells.append(contentsOf: [
            row.workTaskTitle ?? "",
            row.workTaskStatus ?? "",
            row.startTime ?? "",
            row.finishTime ?? "",
            number(row.durationHours, decimals: 2),
            row.notes ?? "",
            row.isReversed ? "Yes" : "No",
            row.isActivityTotalsRow ? "Yes" : "No"
        ])
        return cells
    }

    /// The complete CSV. Values are quoted only when they need it, so hours and
    /// costs stay NUMERIC for a spreadsheet rather than arriving as text.
    static func csv(
        _ reportRows: [PruningActivityRow],
        includeCost: Bool,
        calendar: Calendar = .current
    ) -> String {
        let exported = rows(reportRows, includeCost: includeCost, calendar: calendar)
        var lines: [String] = [headers(includeCost: includeCost).map(escape).joined(separator: ",")]
        for row in exported {
            lines.append(cells(row, includeCost: includeCost).map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Fixed-decimal numeric text, or "" for a value that was never recorded.
    /// BLANK is deliberate: `0` would claim a measured zero.
    static func number(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    /// Minimal RFC 4180 escaping — quote only when the value forces it.
    private static func escape(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Dates

    /// Raw chronological `yyyy-MM-dd`, matching the Android `dateIso`.
    static func isoDate(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `dd/MM/yyyy`.
    static func auDate(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d/%02d/%04d", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
    }

    /// "Monday 3 August 2026" — the PDF's group heading.
    static func longDate(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = parts.day ?? 0
        let month = monthNames[safe: (parts.month ?? 1) - 1] ?? ""
        return "\(weekday(date, calendar: calendar)) \(day) \(month) \(parts.year ?? 0)"
    }

    /// "Monday". Fixed English names so both platforms emit the same text
    /// regardless of the device locale.
    static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        // Calendar weekday is 1 = Sunday.
        let index = calendar.component(.weekday, from: date) - 1
        return weekdayNames[safe: index] ?? ""
    }

    /// HH:mm, as the report displays it.
    static func time(_ date: Date?, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static let weekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
    ]

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]

    // MARK: - Totals validation

    /// Sums an exported column the way a spreadsheet would, skipping reversed
    /// rows exactly as `PruningActivityReport.summary` does. Used by the
    /// regression tests to prove the export and the on-screen summary agree.
    static func columnTotal(_ rows: [Row], _ selector: (Row) -> Double?) -> Double {
        rows.filter { !$0.isReversed }.reduce(0) { $0 + (selector($1) ?? 0) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
