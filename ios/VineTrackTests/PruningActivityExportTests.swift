import Foundation
import Testing
@testable import VineTrack

/// SHARED EXPORT FIXTURE — the same cases and the same numbers exist as
/// `PruningActivityExportTest.kt` in the Android unit-test source set. Both
/// platforms must produce identical allocation breakdowns, identical
/// first-row-only totals and identical column sums from this fixture.
///
/// The fixture deliberately covers every shape that could double-count labour:
///
///  * A — two blocks, Work Task labour lines (18 person-hours, $630)
///  * B — one block, NO labour lines (legacy activity hours only, 4.0)
///  * C — three blocks, Work Task labour lines (12 person-hours, $300)
///  * D — two blocks, REVERSED (10 person-hours, $200 — must never be totalled)
struct PruningActivityExportTests {

    // MARK: Fixture

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private static let vineyardId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae000")!
    private static let blockPinot = UUID(uuidString: "00000000-0000-0000-0000-0000000ae001")!
    private static let blockCab = UUID(uuidString: "00000000-0000-0000-0000-0000000ae002")!
    private static let blockChard = UUID(uuidString: "00000000-0000-0000-0000-0000000ae003")!

    private static let taskA = UUID(uuidString: "00000000-0000-0000-0000-0000000ae011")!
    private static let taskC = UUID(uuidString: "00000000-0000-0000-0000-0000000ae012")!
    private static let taskD = UUID(uuidString: "00000000-0000-0000-0000-0000000ae013")!

    private static let activityAId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0a0")!
    private static let activityBId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0b0")!
    private static let activityCId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0c0")!
    private static let activityDId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0d0")!

    /// 100 vines per row → one quarter = 25 vines, one full row = 100.
    private static func rowRefs(_ numbers: [Int]) -> [PruningRowRef] {
        numbers.map { number in
            PruningRowRef(
                rowId: nil,
                number: number,
                label: "\(number)",
                lengthMetres: nil,
                vines: 100,
                isFallback: true
            )
        }
    }

    private static let contexts: [UUID: PruningActivityBlockContext] = [
        blockPinot: PruningActivityBlockContext(
            name: "Pinot Noir",
            variety: "Pinot Noir",
            rows: rowRefs(Array(90...108))
        ),
        blockCab: PruningActivityBlockContext(
            name: "Cabernet Franc",
            variety: "Cabernet Franc",
            rows: rowRefs(Array(1...12))
        ),
        blockChard: PruningActivityBlockContext(
            name: "Chardonnay",
            variety: "Chardonnay",
            rows: rowRefs(Array(1...4))
        )
    ]

    /// One whole row = four quarters.
    private static func wholeRow(_ number: Int) -> [PruningSegment] {
        (1...4).map { PruningSegment(row: number, quarter: $0) }
    }

    private static func allocation(
        id: UUID,
        activityId: UUID,
        allocationIndex: Int,
        paddock: UUID,
        day: Int,
        rowNumber: Int,
        worker: String = "Pruning Crew",
        /// Activity-level values exist on the PRIMARY allocation only.
        operationalHours: Double? = nil,
        start: Date? = nil,
        finish: Date? = nil,
        notes: String = "",
        workTaskId: UUID? = nil,
        reversedAt: Date? = nil
    ) -> PruningEntry {
        let entryDate = date(day)
        return PruningEntry(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddock,
            date: entryDate,
            segments: wholeRow(rowNumber),
            worker: worker,
            labourHours: operationalHours,
            startTime: start,
            finishTime: finish,
            notes: notes,
            estimatedVines: 100,
            workTaskId: workTaskId,
            createdAt: entryDate,
            reversedAt: reversedAt,
            pruningActivityId: activityId,
            allocationIndex: allocationIndex
        )
    }

    /// A — two blocks, Work Task labour lines. The example from the brief.
    private static let activityA: [PruningEntry] = [
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0a1")!,
            activityId: activityAId, allocationIndex: 0, paddock: blockPinot,
            day: 3, rowNumber: 90, operationalHours: 6,
            start: date(3, 7, 0), finish: date(3, 13, 0),
            notes: "Cold start, frost delay", workTaskId: taskA
        ),
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0a2")!,
            activityId: activityAId, allocationIndex: 1, paddock: blockCab,
            day: 3, rowNumber: 1
        )
    ]

    /// B — one block, no labour lines: the legacy activity value is the fallback.
    private static let activityB: [PruningEntry] = [
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0b1")!,
            activityId: activityBId, allocationIndex: 0, paddock: blockChard,
            day: 4, rowNumber: 1, worker: "Dave", operationalHours: 4
        )
    ]

    /// C — three blocks, Work Task labour lines.
    private static let activityC: [PruningEntry] = [
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0c1")!,
            activityId: activityCId, allocationIndex: 0, paddock: blockPinot,
            day: 5, rowNumber: 91, operationalHours: 2, workTaskId: taskC
        ),
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0c2")!,
            activityId: activityCId, allocationIndex: 1, paddock: blockCab,
            day: 5, rowNumber: 2
        ),
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0c3")!,
            activityId: activityCId, allocationIndex: 2, paddock: blockChard,
            day: 5, rowNumber: 3
        )
    ]

    /// D — two blocks, REVERSED. Audit history that must never be totalled.
    private static let activityD: [PruningEntry] = [
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0d1")!,
            activityId: activityDId, allocationIndex: 0, paddock: blockPinot,
            day: 6, rowNumber: 92, operationalHours: 5, workTaskId: taskD,
            reversedAt: date(7)
        ),
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0d2")!,
            activityId: activityDId, allocationIndex: 1, paddock: blockCab,
            day: 6, rowNumber: 3, reversedAt: date(7)
        )
    ]

    private static let titles: [UUID: String] = [
        taskA: "Winter pruning",
        taskC: "Spur pruning block sweep",
        taskD: "Reversed pruning"
    ]

    private static let statuses: [UUID: String] = [
        taskA: "Completed",
        taskC: "In progress",
        taskD: "Completed"
    ]

    /// Summed Work Task labour lines — the AUTHORITATIVE labour source.
    private static let taskHours: [UUID: Double] = [taskA: 18, taskC: 12, taskD: 10]
    private static let taskCosts: [UUID: Double] = [taskA: 630, taskC: 300, taskD: 200]

    private static var allEntries: [PruningEntry] { activityA + activityB + activityC + activityD }

    private static func build(_ entries: [PruningEntry]) -> [PruningActivityRow] {
        PruningActivityReport.rows(
            entries: entries,
            blocks: contexts,
            workTaskTitles: titles,
            workTaskStatuses: statuses,
            labourCosts: taskCosts,
            labourHours: taskHours,
            accountNames: [:],
            calendar: calendar
        )
    }

    private static func sorted(_ entries: [PruningEntry]? = nil) -> [PruningActivityRow] {
        PruningActivityReport.sorted(build(entries ?? allEntries), by: .default)
    }

    private static func exported(
        _ entries: [PruningEntry]? = nil,
        includeCost: Bool = true
    ) -> [PruningActivityExport.Row] {
        PruningActivityExport.rows(sorted(entries), includeCost: includeCost, calendar: calendar)
    }

    // MARK: 1. A two-block activity produces two allocation rows

    @Test("A two-block activity exports two allocation rows")
    func twoBlockActivityExportsTwoRows() {
        let rows = Self.exported(Self.activityA)

        #expect(rows.count == 2)
        #expect(rows.map(\.allocationNumber) == [1, 2])
        #expect(rows.map(\.allocationCount) == [2, 2])
        #expect(rows.map(\.blockName) == ["Pinot Noir", "Cabernet Franc"])
        #expect(rows.map(\.allocationLabel) == ["block 1 of 2", "block 2 of 2"])
        // The activity label is the linked Work Task title, never an id.
        #expect(rows.allSatisfy { $0.activityLabel == "Winter pruning" })
    }

    // MARK: 2. Person-hours and labour cost appear only on the first row

    @Test("Activity totals appear on the first allocation row only, blank elsewhere")
    func activityTotalsOnFirstRowOnly() {
        let rows = Self.exported(Self.activityA)
        let first = rows[0]
        let second = rows[1]

        #expect(first.isActivityTotalsRow)
        #expect(!second.isActivityTotalsRow)

        #expect(first.operationalHours == 6)
        #expect(first.personHours == 18)
        #expect(first.labourCost == 630)
        #expect(first.worker == "Pruning Crew")
        #expect(first.startTime == "07:00")
        #expect(first.finishTime == "13:00")
        #expect(first.durationHours == 6)
        #expect(first.notes == "Cold start, frost delay")

        // BLANK, not zero — a zero would claim a real recorded measurement.
        #expect(second.operationalHours == nil)
        #expect(second.personHours == nil)
        #expect(second.labourCost == nil)
        #expect(second.worker == nil)
        #expect(second.startTime == nil)
        #expect(second.finishTime == nil)
        #expect(second.durationHours == nil)
        #expect(second.notes == nil)

        // And the CSV cells for those columns are empty strings, not "0.00".
        let headers = PruningActivityExport.headers(includeCost: true)
        let cells = PruningActivityExport.cells(second, includeCost: true)
        for column in ["Operational Hours", "Work Task Person-Hours", "Labour Cost", "Duration (h)"] {
            let index = headers.firstIndex(of: column)
            #expect(index != nil)
            #expect(cells[index ?? 0] == "")
        }
    }

    // MARK: 3. Allocation-specific quantities stay on every row

    @Test("Allocation quantities are present on every allocation row")
    func allocationQuantitiesOnEveryRow() {
        let rows = Self.exported(Self.activityA)

        for row in rows {
            #expect(row.quarters == 4)
            #expect(row.rowEquivalents == 1)
            #expect(row.estimatedVines == 100)
            #expect(!row.blockName.isEmpty)
            #expect(row.variety?.isEmpty == false)
            #expect(row.rowRange?.isEmpty == false)
            // Work Task title/status repeat: they are text and cannot be summed.
            #expect(row.workTaskTitle == "Winter pruning")
            #expect(row.workTaskStatus == "Completed")
        }
        #expect(rows[0].rowRange == "90")
        #expect(rows[1].rowRange == "1")
    }

    // MARK: 4 + 5. Exported column sums equal the report summary

    @Test("Summing the exported labour-cost column equals the report summary total")
    func labourCostColumnMatchesSummary() {
        let rows = Self.sorted()
        let summary = PruningActivityReport.summary(rows, includeCost: true)
        let exportRows = PruningActivityExport.rows(rows, includeCost: true, calendar: Self.calendar)

        let total = PruningActivityExport.columnTotal(exportRows) { $0.labourCost }
        #expect(summary.labourCost == 930)
        #expect(abs((summary.labourCost ?? 0) - total) < 0.0001)
    }

    @Test("Summing the exported person-hours column equals the report summary total")
    func personHoursColumnMatchesSummary() {
        let rows = Self.sorted()
        let summary = PruningActivityReport.summary(rows, includeCost: true)
        let exportRows = PruningActivityExport.rows(rows, includeCost: true, calendar: Self.calendar)

        let total = PruningActivityExport.columnTotal(exportRows) { $0.personHours }
        // 18 (task lines) + 4 (legacy fallback) + 12 (task lines); reversed excluded.
        #expect(summary.labourHours == 34)
        #expect(abs(summary.labourHours - total) < 0.0001)
    }

    // MARK: 6. Single-allocation activities retain all activity totals

    @Test("A single-allocation activity keeps every activity total")
    func singleAllocationKeepsTotals() {
        let rows = Self.exported(Self.activityB)

        #expect(rows.count == 1)
        let only = rows[0]
        #expect(only.isActivityTotalsRow)
        #expect(only.allocationNumber == 1)
        #expect(only.allocationCount == 1)
        #expect(only.allocationLabel == "whole activity")
        #expect(only.operationalHours == 4)
        #expect(only.personHours == 4)
        #expect(only.worker == "Dave")
    }

    // MARK: 7. Three or more allocations still output totals once

    @Test("A three-allocation activity outputs totals exactly once")
    func threeAllocationsOutputTotalsOnce() {
        let rows = Self.exported(Self.activityC)

        #expect(rows.count == 3)
        #expect(rows.filter(\.isActivityTotalsRow).count == 1)
        #expect(rows.filter { $0.personHours != nil }.count == 1)
        #expect(rows.filter { $0.labourCost != nil }.count == 1)
        #expect(rows.filter { $0.operationalHours != nil }.count == 1)
        #expect(rows.map(\.allocationLabel) == ["block 1 of 3", "block 2 of 3", "block 3 of 3"])
        #expect(rows[0].personHours == 12)
        #expect(rows[0].labourCost == 300)

        // Every allocation still carries its own block quantities.
        #expect(rows.reduce(0) { $0 + $1.rowEquivalents } == 3)
    }

    // MARK: 8 + 9. Labour authority

    @Test("Work Task labour values take precedence over legacy activity values")
    func taskLabourWinsOverLegacy() {
        let row = Self.exported(Self.activityA)[0]

        // The activity recorded 6 operational hours; the Work Task's labour
        // lines total 18 person-hours. Both are exported, in their OWN columns,
        // and the authoritative person-hours figure is the task's.
        #expect(row.operationalHours == 6)
        #expect(row.personHours == 18)
        #expect(row.labourCost == 630)
    }

    @Test("Legacy activity values are used only when the task has no labour lines")
    func legacyUsedOnlyWithoutLines() {
        let row = Self.exported(Self.activityB)[0]

        // No linked task, so the activity's own hours ARE the resolved value —
        // and there is no cost, because a legacy rate was never recorded.
        #expect(row.operationalHours == 4)
        #expect(row.personHours == 4)
        #expect(row.labourCost == nil)
        #expect(row.workTaskTitle == nil)
    }

    @Test("No allocation row ever combines both labour sources")
    func neverCombinesBothSources() {
        let rows = Self.exported()

        // Exactly one totals row per activity, and the person-hours column has
        // one value per activity — never one per block.
        #expect(rows.filter(\.isActivityTotalsRow).count == 4)
        #expect(rows.filter { $0.personHours != nil }.count == 4)
        #expect(rows.count == 9)
    }

    // MARK: 10. Reversed activities stay visible but never inflate totals

    @Test("Reversed activities are exported, marked, and excluded from totals")
    func reversedActivitiesExcludedFromTotals() {
        let rows = Self.sorted()
        let exportRows = PruningActivityExport.rows(rows, includeCost: true, calendar: Self.calendar)
        let reversed = exportRows.filter(\.isReversed)

        // Both allocations of the reversed activity are still exported.
        #expect(reversed.count == 2)
        #expect(reversed.map(\.blockName) == ["Pinot Noir", "Cabernet Franc"])
        // Its historical values are retained on the detail row, matching the
        // on-screen report...
        #expect(reversed[0].personHours == 10)
        // ...but they never reach a total.
        let summary = PruningActivityReport.summary(rows, includeCost: true)
        #expect(summary.reversedRecords == 2)
        #expect(summary.labourCost == 930)
        let total = PruningActivityExport.columnTotal(exportRows) { $0.labourCost }
        #expect(abs((summary.labourCost ?? 0) - total) < 0.0001)
        // The Reversed column is what makes that filterable in a spreadsheet.
        let headers = PruningActivityExport.headers(includeCost: true)
        let cells = PruningActivityExport.cells(reversed[0], includeCost: true)
        #expect(cells[headers.firstIndex(of: "Reversed") ?? 0] == "Yes")
    }

    // MARK: 11. No internal identifier is ever exported

    @Test("No Work Task, allocation or activity identifier is exported")
    func noIdentifiersExported() {
        let csv = PruningActivityExport.csv(Self.sorted(), includeCost: true, calendar: Self.calendar)

        for id in [
            Self.activityAId, Self.activityBId, Self.activityCId, Self.activityDId,
            Self.taskA, Self.taskC, Self.taskD,
            Self.blockPinot, Self.blockCab, Self.blockChard, Self.vineyardId
        ] {
            #expect(!csv.localizedCaseInsensitiveContains(id.uuidString))
        }
        // And no UUID-shaped value of any kind.
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        #expect(csv.range(of: pattern, options: .regularExpression) == nil)
    }

    // MARK: 12. Costing permission

    @Test("Labour cost is absent for roles without costing visibility")
    func costingPermissionEnforced() {
        let rows = Self.sorted()
        let headers = PruningActivityExport.headers(includeCost: false)
        #expect(!headers.contains("Labour Cost"))
        // Hours stay visible — only money is withheld.
        #expect(headers.contains("Operational Hours"))
        #expect(headers.contains("Work Task Person-Hours"))

        let exportRows = PruningActivityExport.rows(rows, includeCost: false, calendar: Self.calendar)
        #expect(exportRows.allSatisfy { $0.labourCost == nil })
        #expect(exportRows.contains { $0.personHours != nil })

        let csv = PruningActivityExport.csv(rows, includeCost: false, calendar: Self.calendar)
        #expect(!csv.contains("Labour Cost"))
        #expect(!csv.contains("630"))
    }

    // MARK: 13. Filters and sorting are preserved; groups stay contiguous

    @Test("The export respects the active filter")
    func exportRespectsFilter() {
        var filter = PruningActivityFilter()
        filter.blocks = [Self.blockChard]
        let filtered = PruningActivityReport.sorted(
            PruningActivityReport.filtered(Self.build(Self.allEntries), with: filter, calendar: Self.calendar),
            by: .default
        )
        let rows = PruningActivityExport.rows(filtered, includeCost: true, calendar: Self.calendar)

        #expect(rows.allSatisfy { $0.blockName == "Chardonnay" })
        // Activity C's Chardonnay allocation is NOT the primary, so the activity
        // values are genuinely absent from this result — blank, never borrowed
        // from an excluded sibling row.
        let cRow = rows.first { $0.activityLabel == "Spur pruning block sweep" }
        #expect(cRow?.allocationNumber == 1)
        #expect(cRow?.allocationCount == 1)
        #expect(cRow?.personHours == nil)
        #expect(cRow?.labourCost == nil)
        // Activity B's only allocation IS the primary, so its totals survive.
        let bRow = rows.first { $0.activityLabel != "Spur pruning block sweep" }
        #expect(bRow?.personHours == 4)
    }

    @Test("Allocations of one activity are never scattered through the export")
    func allocationsStayContiguous() {
        // Sorting by Block would interleave allocations from different
        // activities in the table; the export keeps each activity contiguous.
        let byBlock = PruningActivityReport.sorted(
            Self.build(Self.allEntries),
            by: PruningActivitySort(column: .block, ascending: true)
        )
        let rows = PruningActivityExport.rows(byBlock, includeCost: true, calendar: Self.calendar)

        var runs: [String] = []
        for label in rows.map(\.activityLabel) where runs.last != label {
            runs.append(label)
        }
        #expect(runs.count == Set(runs).count)

        // Group order follows the report's own visible order.
        #expect(byBlock.first?.blockName == "Cabernet Franc")
        #expect(rows.first?.blockName == byBlock.first?.blockName)

        // Within a group the PRIMARY allocation is always first, so the totals
        // row is row 1 regardless of the table's sort.
        for group in PruningActivityExport.groups(byBlock, includeCost: true, calendar: Self.calendar) {
            #expect(group.allocations.first?.allocationNumber == 1)
            #expect(group.allocations.first?.isActivityTotalsRow == true)
            #expect(group.allocations.filter(\.isActivityTotalsRow).count == 1)
        }
    }

    @Test("The export honours the sort direction of the table")
    func exportHonoursSortDirection() {
        let ascending = PruningActivityReport.sorted(
            Self.build(Self.allEntries),
            by: PruningActivitySort(column: .date, ascending: true)
        )
        let descending = PruningActivityReport.sorted(
            Self.build(Self.allEntries),
            by: PruningActivitySort(column: .date, ascending: false)
        )

        let first = PruningActivityExport.rows(ascending, includeCost: true, calendar: Self.calendar).first
        let last = PruningActivityExport.rows(descending, includeCost: true, calendar: Self.calendar).first
        #expect(first?.dateIso == "2026-08-03")
        #expect(last?.dateIso == "2026-08-06")
    }

    // MARK: 14. CSV shape

    @Test("CSV keeps a raw ISO date, an Australian display date, and a totals flag")
    func csvShape() {
        let csv = PruningActivityExport.csv(Self.sorted(Self.activityA), includeCost: true, calendar: Self.calendar)
        let lines = csv.split(separator: "\r\n", omittingEmptySubsequences: true).map(String.init)
        let headers = lines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let first = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let second = lines[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        #expect(headers[0] == "Date (ISO)")
        #expect(first[0] == "2026-08-03")
        #expect(first[headers.firstIndex(of: "Activity Date") ?? 0] == "03/08/2026")
        #expect(first[headers.firstIndex(of: "Weekday") ?? 0] == "Monday")
        #expect(first[headers.firstIndex(of: "Activity Totals Row") ?? 0] == "Yes")
        #expect(second[headers.firstIndex(of: "Activity Totals Row") ?? 0] == "No")
        // Hours and costs are NUMERIC, not quoted text.
        #expect(first[headers.firstIndex(of: "Work Task Person-Hours") ?? 0] == "18.00")
        #expect(first[headers.firstIndex(of: "Labour Cost") ?? 0] == "630.00")
    }

    @Test("CSV quotes only values that need it")
    func csvQuotingIsMinimal() {
        var withComma = Self.activityA
        withComma[0].notes = "Frost delay, restarted 09:00"
        let csv = PruningActivityExport.csv(Self.sorted(withComma), includeCost: true, calendar: Self.calendar)

        #expect(csv.contains("\"Frost delay, restarted 09:00\""))
        // The plain values around it stay unquoted.
        #expect(csv.contains(",Pinot Noir,"))
    }

    // MARK: 15. PDF grouped layout

    @Test("PDF groups state activity labour once and list every allocation")
    func pdfGroupedLayout() {
        let groups = PruningActivityExport.groups(Self.sorted(), includeCost: true, calendar: Self.calendar)

        #expect(groups.count == 4)
        let a = groups.first { $0.activityLabel == "Winter pruning" }
        #expect(a?.dateDisplay == "Monday 3 August 2026")
        #expect(a?.allocationCount == 2)
        #expect(a?.isMultiBlock == true)
        #expect(a?.blockSummary == "Pinot Noir + Cabernet Franc")
        #expect(a?.personHours == 18)
        #expect(a?.operationalHours == 6)
        #expect(a?.labourCost == 630)
        #expect(a?.totalRowEquivalents == 2)
        #expect(a?.totalVines == 200)

        // Costing-blind roles get the same document with no money in it.
        let blind = PruningActivityExport.groups(Self.sorted(), includeCost: false, calendar: Self.calendar)
        #expect(blind.allSatisfy { $0.labourCost == nil })
        #expect(blind.contains { $0.personHours != nil })
    }

    // MARK: 16. Cross-platform parity fixture

    @Test("Parity fixture produces the exact rows Android must also produce")
    func parityFixture() {
        let rows = Self.exported(Self.activityA)

        let encoded = rows.map { row in
            [
                row.dateIso,
                row.dateDisplay,
                row.weekday,
                row.activityLabel,
                String(row.allocationNumber),
                String(row.allocationCount),
                row.allocationLabel,
                row.blockName,
                row.rowRange ?? "",
                String(row.quarters),
                PruningActivityExport.number(row.rowEquivalents, decimals: 2),
                PruningActivityExport.number(row.estimatedVines, decimals: 0),
                PruningActivityExport.number(row.operationalHours, decimals: 2),
                PruningActivityExport.number(row.personHours, decimals: 2),
                PruningActivityExport.number(row.labourCost, decimals: 2),
                row.isActivityTotalsRow ? "Yes" : "No",
                row.isReversed ? "Yes" : "No"
            ].joined(separator: "|")
        }

        // These two lines are asserted verbatim in the Android twin.
        #expect(encoded == [
            "2026-08-03|03/08/2026|Monday|Winter pruning|1|2|block 1 of 2|Pinot Noir|90|4|1.00|100|6.00|18.00|630.00|Yes|No",
            "2026-08-03|03/08/2026|Monday|Winter pruning|2|2|block 2 of 2|Cabernet Franc|1|4|1.00|100||||No|No"
        ])
    }
}
