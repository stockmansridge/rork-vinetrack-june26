import Foundation

/// SHARED CONTRACT — Pruning Activity Report EXPORTS (CSV + PDF).
///
/// Anything changed here must be mirrored in `PruningActivityExport.kt`. The
/// regression fixtures in `PruningActivityExportTests.swift` and
/// `PruningActivityExportTest.kt` are byte-for-byte the same.
///
/// ## The model
///
/// A pruning activity is ONE piece of work that may cover MANY blocks, and
/// `pruning_entries` is the allocation table. Every exported row is one
/// ALLOCATION, and it carries three kinds of value:
///
///  * ALLOCATION quantities — block, variety, rows, quarters, row equivalents,
///    vines, allocation share, ALLOCATED person-hours, ALLOCATED cost. Present
///    on EVERY row. These are proportional slices, so they sum correctly across
///    any filtered subset.
///  * PARENT CONTEXT — activity id, worker/crew, method, Work Task, start,
///    finish, allocation counts, partial marker. Present on EVERY row, resolved
///    from the PARENT ACTIVITY via `PruningActivityAllocationModel`.
///  * PARENT TOTALS — whole-activity operational hours, person-hours, labour
///    cost and duration. Present on the DESIGNATED TOTALS ROW only, so a
///    spreadsheet `SUM()` cannot count one activity's labour once per block.
///
/// Suppressed values are BLANK, never `0` — a zero claims a real recorded
/// measurement of nothing.
///
/// ## Parent context is never blanked by a filter
///
/// The `allocation_index = 0` row is a legacy MIRROR of some parent values, not
/// the authority. Filtering to a block that the activity touched second must
/// still show that activity's worker, Work Task and labour. The totals row is
/// therefore the first INCLUDED allocation, not necessarily the primary.
///
/// ## Partial activities
///
/// When the filter admits fewer allocations than the activity really has, the
/// rows are marked `Partial activity = Yes` and carry both counts. The parent
/// totals still describe the WHOLE activity and are labelled as such; the
/// filtered block's proportional figures are the ALLOCATED columns. Confusing
/// the two is exactly the error this file exists to prevent.
///
/// ## Identifiers
///
/// The CSV is a reconciliation artefact, so it carries the FULL activity and
/// allocation ids in their own columns — that is what lets a reader de-duplicate
/// whole-activity totals or match a row back to the portal.
///
/// The PDF is a document people read. It never prints a full UUID in the body:
/// the activity's human-readable name is the label, and an eight-character SHORT
/// REFERENCE (`shortReference`) sits beside it in small type for anyone who needs
/// to quote a record. Full ids appear in the PDF only in its metadata, or in the
/// optional "Include technical references" appendix.
nonisolated enum PruningActivityExport {

    /// One CSV row — one ALLOCATION of one activity.
    ///
    /// Whole-activity totals are optional and populated ONLY when
    /// `isActivityTotalsRow` is true. Allocated values and parent context are
    /// populated on every row.
    nonisolated struct Row: Sendable, Equatable {
        /// Raw chronological `yyyy-MM-dd`, retained for sorting and pivots.
        let dateIso: String
        /// `dd/MM/yyyy`.
        let dateDisplay: String
        /// "Monday".
        let weekday: String
        /// The activity's name — the linked Work Task title, else "Spur pruning".
        let activityLabel: String
        /// The PARENT activity's id, exported so a filtered extract can be
        /// reconciled against the portal and so whole-activity totals can be
        /// de-duplicated by the reader.
        let activityId: String
        /// This allocation's own id — the row's stable key.
        let allocationId: String
        /// 1-based position within the FULL activity, not within the extract.
        let allocationNumber: Int
        /// How many allocations the activity really has.
        let fullAllocationCount: Int
        /// How many of them survived the filter.
        let includedAllocationCount: Int
        /// True when `includedAllocationCount` < `fullAllocationCount`.
        let isPartialActivity: Bool
        /// "block 1 of 2", or "block 2 of 2 (1 shown)" when partial.
        let allocationLabel: String
        let blockName: String
        let variety: String?
        /// "90" or "90–108", from the ACTUAL row numbers.
        let rowRange: String?
        let quarters: Int
        let rowEquivalents: Double
        /// Exact vines when the block's rows resolve, else this allocation's estimate.
        let estimatedVines: Double?
        // --- allocation slice: present on EVERY row -------------------------
        /// 0..1 of the FULL activity's row equivalents.
        let allocationShare: Double?
        /// parent person-hours × share.
        let allocatedPersonHours: Double?
        /// parent labour cost × share; nil when costing is not permitted.
        let allocatedLabourCost: Double?
        // --- parent context: present on EVERY row ---------------------------
        let method: String
        let worker: String?
        let workTaskTitle: String?
        let workTaskStatus: String?
        let startTime: String?
        let finishTime: String?
        // --- whole-activity totals: totals row ONLY -------------------------
        /// The activity's own recorded operational hours.
        let activityOperationalHours: Double?
        /// RESOLVED authoritative person-hours for the WHOLE activity.
        let activityPersonHours: Double?
        /// Whole-activity labour cost; nil when costing is not permitted.
        let activityLabourCost: Double?
        /// Elapsed start→finish duration for the whole activity.
        let activityDurationHours: Double?
        let notes: String?
        // --------------------------------------------------------------------
        let isReversed: Bool
        /// True on the first INCLUDED allocation row of each activity — the one
        /// carrying the whole-activity totals. Exported as a `Yes`/`No` column
        /// so a pivot can aggregate parent values without de-duplicating.
        let isActivityTotalsRow: Bool
    }

    /// One activity and its INCLUDED allocations — the PDF's grouped layout. The
    /// whole-activity labour is stated ONCE in the header; the allocation list
    /// underneath carries each block's proportional slice.
    nonisolated struct Group: Sendable, Identifiable {
        let id: UUID
        let activityLabel: String
        let dateIso: String
        /// "Monday 3 August 2026".
        let dateDisplay: String
        let method: String
        let worker: String?
        let activityOperationalHours: Double?
        let activityPersonHours: Double?
        let activityLabourCost: Double?
        let activityDurationHours: Double?
        let workTaskTitle: String?
        let workTaskStatus: String?
        let startTime: String?
        let finishTime: String?
        let notes: String?
        let isReversed: Bool
        let fullAllocationCount: Int
        let allocations: [Row]

        /// The parent activity's id, as exported in the CSV. Lower-cased to
        /// match both the server's own ids and the Android export exactly.
        var activityId: String { id.uuidString.lowercased() }

        /// The eight-character reference printed in the PDF instead of the full
        /// UUID — enough to quote a record over the phone, short enough not to
        /// dominate the line.
        var shortReference: String { PruningActivityExport.shortReference(activityId) }

        var includedAllocationCount: Int { allocations.count }
        var isPartialActivity: Bool { includedAllocationCount < fullAllocationCount }
        var isMultiBlock: Bool { fullAllocationCount > 1 }

        /// "Partial activity — 1 of 2 blocks shown", or nil for a complete one.
        /// The PDF prints this above the whole-activity totals so nobody reads
        /// those totals as belonging to the filtered block.
        var partialLabel: String? {
            guard isPartialActivity else { return nil }
            return "Partial activity — \(includedAllocationCount) of \(fullAllocationCount) blocks shown"
        }

        /// "Pinot Noir + Cabernet Franc" — the INCLUDED blocks.
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

        /// Person-hours attributable to the SHOWN blocks only.
        var allocatedPersonHours: Double? { Group.sumOrNil(allocations.map(\.allocatedPersonHours)) }

        /// Labour cost attributable to the SHOWN blocks only.
        var allocatedLabourCost: Double? { Group.sumOrNil(allocations.map(\.allocatedLabourCost)) }

        private static func sumOrNil(_ values: [Double?]) -> Double? {
            let present = values.compactMap { $0 }
            return present.isEmpty ? nil : present.reduce(0, +)
        }
    }

    // MARK: - Grouping

    /// Groups the report's ALREADY filtered and sorted rows into parent
    /// activities, preserving each activity as a CONTIGUOUS block.
    ///
    /// Group order follows the report's own visible order: an activity ranks by
    /// the position of its first-appearing row, so changing the report's sort
    /// reorders the groups without ever scattering one activity's allocations
    /// through the file. Allocation order inside a group is the canonical
    /// `allocation_index` order.
    ///
    /// - Parameters:
    ///   - reportRows: the report's filtered + sorted rows, in visible order.
    ///   - includeCost: false for roles without costing visibility; BOTH the
    ///     whole-activity cost and the allocated cost are then dropped from the
    ///     data, not merely hidden in the renderer.
    ///   - canonicalRows: every allocation of every activity BEFORE filtering.
    ///     This supplies the parent context and the allocation-share
    ///     denominator. Defaults to `reportRows` for an unfiltered export.
    ///   - canonicalParents: the `pruning_activities` records, when the caller
    ///     has them. They outrank the allocation mirror for every field they
    ///     fill.
    static func groups(
        _ reportRows: [PruningActivityRow],
        includeCost: Bool,
        canonicalRows: [PruningActivityRow]? = nil,
        canonicalParents: [UUID: PruningActivityParentSource] = [:],
        calendar: Calendar = .current
    ) -> [Group] {
        let model = PruningActivityAllocationModel.build(
            canonicalRows ?? reportRows,
            includeCost: includeCost,
            canonicalParents: canonicalParents
        )
        return groups(reportRows, includeCost: includeCost, model: model, calendar: calendar)
    }

    /// Overload for callers that already built the model (the summary path).
    static func groups(
        _ reportRows: [PruningActivityRow],
        includeCost: Bool,
        model: PruningActivityAllocationModel,
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

        return order.compactMap { activityId -> Group? in
            guard let included = buckets[activityId], !included.isEmpty else { return nil }
            let ordered = PruningActivityAllocationModel.canonicalOrder(included)
            let head = ordered[0]
            let parent = model.parent(activityId)
            let fullCount = parent?.allocationCount ?? ordered.count
            let includedCount = ordered.count
            let partial = includedCount < fullCount
            let label = parent?.label ?? PruningActivityAllocationModel.label(
                workTaskTitle: head.workTaskTitle,
                method: head.method
            )
            let start = time(parent?.startTime, calendar: calendar)
            let finish = time(parent?.finishTime, calendar: calendar)

            let exported: [Row] = ordered.enumerated().map { index, row in
                let share = model.share(of: row)
                // The totals row is the first INCLUDED allocation. When a filter
                // has excluded the legacy primary, the parent's values move to
                // whichever allocation survived — they are never dropped.
                let isTotals = index == 0
                let number = share?.allocationNumber ?? (index + 1)
                return Row(
                    dateIso: isoDate(row.date, calendar: calendar),
                    dateDisplay: auDate(row.date, calendar: calendar),
                    weekday: weekday(row.date, calendar: calendar),
                    activityLabel: label,
                    activityId: activityId.uuidString.lowercased(),
                    allocationId: row.id.uuidString.lowercased(),
                    allocationNumber: number,
                    fullAllocationCount: fullCount,
                    includedAllocationCount: includedCount,
                    isPartialActivity: partial,
                    allocationLabel: allocationLabel(
                        number: number,
                        fullCount: fullCount,
                        includedCount: includedCount
                    ),
                    blockName: row.blockName,
                    variety: row.variety,
                    rowRange: row.rowRangeLabel,
                    quarters: row.quarters,
                    rowEquivalents: row.rowEquivalents,
                    estimatedVines: row.vines ?? (row.estimatedVines > 0 ? Double(row.estimatedVines) : nil),
                    // Proportional slices — on every row, because they are this
                    // block's own share and can be summed safely.
                    allocationShare: share?.share,
                    allocatedPersonHours: share?.personHours,
                    allocatedLabourCost: includeCost ? share?.labourCost : nil,
                    // Parent context — on every row, sourced from the ACTIVITY.
                    method: parent?.method ?? row.method,
                    worker: parent?.worker,
                    workTaskTitle: parent?.workTaskTitle,
                    workTaskStatus: parent?.workTaskStatus,
                    startTime: start,
                    finishTime: finish,
                    // Whole-activity totals — once, on the totals row.
                    activityOperationalHours: isTotals ? parent?.operationalHours : nil,
                    activityPersonHours: isTotals ? parent?.personHours : nil,
                    activityLabourCost: (isTotals && includeCost) ? parent?.labourCost : nil,
                    activityDurationHours: isTotals ? parent?.durationHours : nil,
                    notes: isTotals ? parent?.notes : nil,
                    isReversed: row.isReversed,
                    isActivityTotalsRow: isTotals
                )
            }

            return Group(
                id: activityId,
                activityLabel: label,
                dateIso: isoDate(head.date, calendar: calendar),
                dateDisplay: longDate(head.date, calendar: calendar),
                method: parent?.method ?? head.method,
                worker: parent?.worker,
                activityOperationalHours: parent?.operationalHours,
                activityPersonHours: parent?.personHours,
                activityLabourCost: includeCost ? parent?.labourCost : nil,
                activityDurationHours: parent?.durationHours,
                workTaskTitle: parent?.workTaskTitle,
                workTaskStatus: parent?.workTaskStatus,
                startTime: start,
                finishTime: finish,
                notes: parent?.notes,
                isReversed: ordered.allSatisfy(\.isReversed),
                fullAllocationCount: fullCount,
                allocations: exported
            )
        }
    }

    /// The flat CSV row set — every allocation, activities kept contiguous.
    static func rows(
        _ reportRows: [PruningActivityRow],
        includeCost: Bool,
        canonicalRows: [PruningActivityRow]? = nil,
        canonicalParents: [UUID: PruningActivityParentSource] = [:],
        calendar: Calendar = .current
    ) -> [Row] {
        groups(
            reportRows,
            includeCost: includeCost,
            canonicalRows: canonicalRows,
            canonicalParents: canonicalParents,
            calendar: calendar
        ).flatMap(\.allocations)
    }

    // MARK: - Identifiers

    /// The first eight characters of an id — the first hex group of a UUID.
    ///
    /// Long enough to disambiguate a season's activities in practice, short
    /// enough to read aloud, and a PREFIX of the full id in the CSV, so matching
    /// the two is a simple "starts with" rather than a lookup table.
    static func shortReference(_ id: String) -> String {
        let cleaned = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.count <= 8 ? cleaned : String(cleaned.prefix(8))
    }

    /// The PDF's small-type reference line, or nil when short references are
    /// switched off. Never the full UUID.
    static func referenceLine(_ group: Group, includeShortReferences: Bool) -> String? {
        guard includeShortReferences else { return nil }
        let reference = shortReference(group.activityId)
        return reference.isEmpty ? nil : "Ref \(reference)"
    }

    /// The full ids for ONE activity — rendered only in the optional "Include
    /// technical references" appendix, never in the body of the report.
    static func technicalReferenceLines(_ group: Group) -> [String] {
        var lines = [
            "\(group.activityLabel) — \(group.dateDisplay)",
            "Activity ID: \(group.activityId)"
        ]
        for allocation in group.allocations {
            lines.append(
                "Allocation \(allocation.allocationNumber) (\(allocation.blockName)): \(allocation.allocationId)"
            )
        }
        return lines
    }

    /// The appendix heading, kept identical on both platforms.
    static let technicalReferencesHeading = "Technical references"

    /// The PDF's data-quality notice. Printed when the allocation model found
    /// activities whose source records disagree, so a reader is told before they
    /// act on a figure that one of its sources is wrong.
    static func conflictNotice(conflictedActivities: Int) -> String? {
        guard conflictedActivities > 0 else { return nil }
        let activities = conflictedActivities == 1 ? "activity has" : "activities have"
        return "\(conflictedActivities) \(activities) conflicting source records — verify against the portal"
    }

    /// "block 1 of 2"; a single-allocation activity says "whole activity". A
    /// partial extract appends the included count so the row is self-describing
    /// even when read on its own.
    static func allocationLabel(number: Int, fullCount: Int, includedCount: Int) -> String {
        let base = fullCount <= 1 ? "whole activity" : "block \(number) of \(fullCount)"
        return includedCount < fullCount ? "\(base) (\(includedCount) shown)" : base
    }

    // MARK: - CSV

    /// Column headings, in export order. BOTH cost columns are absent entirely
    /// when `includeCost` is false, so a supervisor's export has no empty cost
    /// column hinting at withheld data.
    static func headers(includeCost: Bool) -> [String] {
        var headers: [String] = [
            "Date (ISO)",
            "Activity Date",
            "Weekday",
            "Activity",
            "Activity ID",
            "Allocation ID",
            "Allocation Number",
            "Full Allocation Count",
            "Included Allocation Count",
            "Partial Activity",
            "Allocation Label",
            "Block",
            "Variety",
            "Rows",
            "Quarters",
            "Row Equivalents",
            "Estimated Vines",
            "Allocation Share (%)",
            "Allocated Person-Hours"
        ]
        if includeCost { headers.append("Allocated Labour Cost") }
        headers.append(contentsOf: [
            "Pruning Method",
            "Worker or Crew",
            "Work Task",
            "Work Task Status",
            "Start Time",
            "Finish Time",
            "Activity Operational Hours",
            "Activity Person-Hours"
        ])
        if includeCost { headers.append("Activity Total Labour Cost") }
        headers.append(contentsOf: [
            "Activity Duration (h)",
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
            row.activityId,
            row.allocationId,
            String(row.allocationNumber),
            String(row.fullAllocationCount),
            String(row.includedAllocationCount),
            row.isPartialActivity ? "Yes" : "No",
            row.allocationLabel,
            row.blockName,
            row.variety ?? "",
            row.rowRange ?? "",
            row.quarters > 0 ? String(row.quarters) : "",
            number(row.rowEquivalents > 0 ? row.rowEquivalents : nil, decimals: 2),
            number(row.estimatedVines, decimals: 0),
            number(row.allocationShare.map { $0 * 100 }, decimals: 2),
            number(row.allocatedPersonHours, decimals: 2)
        ]
        if includeCost { cells.append(number(row.allocatedLabourCost, decimals: 2)) }
        cells.append(contentsOf: [
            row.method,
            row.worker ?? "",
            row.workTaskTitle ?? "",
            row.workTaskStatus ?? "",
            row.startTime ?? "",
            row.finishTime ?? "",
            number(row.activityOperationalHours, decimals: 2),
            number(row.activityPersonHours, decimals: 2)
        ])
        if includeCost { cells.append(number(row.activityLabourCost, decimals: 2)) }
        cells.append(contentsOf: [
            number(row.activityDurationHours, decimals: 2),
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
        canonicalRows: [PruningActivityRow]? = nil,
        canonicalParents: [UUID: PruningActivityParentSource] = [:],
        calendar: Calendar = .current
    ) -> String {
        let exported = rows(
            reportRows,
            includeCost: includeCost,
            canonicalRows: canonicalRows,
            canonicalParents: canonicalParents,
            calendar: calendar
        )
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

    /// Sums a WHOLE-ACTIVITY column, de-duplicating by activity id the way a
    /// reader must. Only the totals rows carry these values, so this is really a
    /// guard that no second row ever starts carrying them too.
    static func activityTotal(_ rows: [Row], _ selector: (Row) -> Double?) -> Double {
        var seen = Set<String>()
        var total = 0.0
        for row in rows where !row.isReversed {
            guard seen.insert(row.activityId).inserted else { continue }
            total += selector(row) ?? 0
        }
        return total
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
