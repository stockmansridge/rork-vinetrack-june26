import Foundation
import Testing
@testable import VineTrack

/// SHARED ACTIVITY REPORT FIXTURE — the same cases exist as
/// `PruningActivityReportTest.kt` in the Android unit-test source set. Both
/// implementations must produce identical rows, statuses, filter results,
/// sort orders and summary totals.
struct PruningActivityReportTests {

    // MARK: Fixture

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private static let vineyardId = UUID(uuidString: "00000000-0000-0000-0000-00000000ac00")!
    private static let blockA = UUID(uuidString: "00000000-0000-0000-0000-00000000ac01")!
    private static let blockB = UUID(uuidString: "00000000-0000-0000-0000-00000000ac02")!
    private static let taskId = UUID(uuidString: "00000000-0000-0000-0000-00000000ac03")!
    private static let userId = UUID(uuidString: "00000000-0000-0000-0000-00000000ac04")!

    /// 10 rows of 100 vines each → one quarter = 25 vines.
    private static func rows(_ numbers: [Int]) -> [PruningRowRef] {
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
        blockA: PruningActivityBlockContext(name: "Block A", variety: "Shiraz", rows: rows([1, 2, 9, 10])),
        blockB: PruningActivityBlockContext(name: "Block B", variety: "Riesling", rows: rows([1, 2]))
    ]

    private static func entry(
        id: UUID = UUID(),
        paddock: UUID = blockA,
        day: Int,
        worker: String = "Sam",
        segments: [PruningSegment] = [PruningSegment(row: 1, quarter: 1), PruningSegment(row: 1, quarter: 2)],
        hours: Double? = 2,
        start: Date? = nil,
        finish: Date? = nil,
        notes: String = "",
        workTaskId: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        reversedAt: Date? = nil,
        enteredBy: UUID? = nil
    ) -> PruningEntry {
        let entryDate = date(2026, 7, day)
        return PruningEntry(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddock,
            date: entryDate,
            segments: segments,
            worker: worker,
            labourHours: hours,
            startTime: start,
            finishTime: finish,
            notes: notes,
            workTaskId: workTaskId,
            createdAt: createdAt ?? entryDate,
            updatedAt: updatedAt,
            enteredBy: enteredBy,
            reversedAt: reversedAt
        )
    }

    private static func build(_ entries: [PruningEntry]) -> [PruningActivityRow] {
        PruningActivityReport.rows(
            entries: entries,
            blocks: contexts,
            workTaskTitles: [taskId: "Pruning — Block A"],
            labourCosts: [taskId: 240],
            accountNames: [userId: "Jonathan"],
            calendar: calendar
        )
    }

    // MARK: Status

    @Test("An untouched record is Active, a server-updated record is Edited, a reversed record is Reversed")
    func statusRules() {
        let created = Self.date(2026, 7, 1, 8, 0)
        #expect(PruningActivityStatus.resolve(reversedAt: nil, createdAt: created, updatedAt: nil) == .active)
        #expect(PruningActivityStatus.resolve(reversedAt: nil, createdAt: created, updatedAt: created) == .active)
        // Same statement writes both stamps — microsecond drift is not an edit.
        #expect(PruningActivityStatus.resolve(
            reversedAt: nil,
            createdAt: created,
            updatedAt: created.addingTimeInterval(1)
        ) == .active)
        #expect(PruningActivityStatus.resolve(
            reversedAt: nil,
            createdAt: created,
            updatedAt: created.addingTimeInterval(600)
        ) == .edited)
        #expect(PruningActivityStatus.resolve(
            reversedAt: Self.date(2026, 7, 5),
            createdAt: created,
            updatedAt: created.addingTimeInterval(600)
        ) == .reversed)
    }

    // MARK: Row projection

    @Test("A row carries exact vines, duration and vines per hour from the record itself")
    func rowProjection() {
        let row = Self.build([
            Self.entry(
                day: 3,
                segments: [
                    PruningSegment(row: 1, quarter: 1),
                    PruningSegment(row: 1, quarter: 2),
                    PruningSegment(row: 2, quarter: 1)
                ],
                hours: 3,
                start: Self.date(2026, 7, 3, 7, 30),
                finish: Self.date(2026, 7, 3, 11, 0),
                workTaskId: Self.taskId,
                enteredBy: Self.userId
            )
        ])[0]

        // 3 quarters × 25 vines.
        #expect(row.vines == 75)
        #expect(row.quarters == 3)
        #expect(row.rowNumbers == [1, 2])
        #expect(row.rowRangeLabel == "1–2")
        #expect(row.vinesPerHour == 25)
        #expect(row.durationHours == 3.5)
        #expect(row.labourCost == 240)
        #expect(row.workTaskTitle == "Pruning — Block A")
        #expect(row.enteredBy == "Jonathan")
        #expect(row.variety == "Shiraz")
        #expect(row.seasonYear == 2026)
        #expect(row.status == .active)
    }

    @Test("Missing values stay nil — never a misleading zero")
    func missingValuesAreNil() {
        let row = Self.build([Self.entry(day: 4, hours: nil, notes: "")])[0]
        #expect(row.labourHours == nil)
        #expect(row.vinesPerHour == nil)
        #expect(row.durationHours == nil)
        #expect(row.labourCost == nil)
        #expect(row.notes == nil)
        #expect(row.workTaskTitle == nil)
        #expect(row.enteredBy == nil)
    }

    @Test("An empty history produces no rows and an empty summary")
    func emptyHistory() {
        let rows = Self.build([])
        #expect(rows.isEmpty)
        let summary = PruningActivityReport.summary(rows, includeCost: true)
        #expect(summary.jobs == 0)
        #expect(summary.vines == 0)
        #expect(summary.averageVinesPerHour == nil)
        #expect(summary.labourCost == nil)
    }

    // MARK: Filters

    @Test("Every filter facet narrows the result, and an empty facet means no restriction")
    func filters() {
        let rows = Self.build([
            Self.entry(day: 1, worker: "Sam", notes: "wet morning"),
            Self.entry(day: 5, paddock: Self.blockB, worker: "Ana", workTaskId: Self.taskId),
            Self.entry(day: 9, worker: "Sam", reversedAt: Self.date(2026, 7, 10))
        ])

        var filter = PruningActivityFilter(seasonYear: 2026)
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count == 3)

        filter.seasonYear = 2025
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).isEmpty)

        filter = PruningActivityFilter(seasonYear: 2026)
        filter.workers = ["Ana"]
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count == 1)

        filter = PruningActivityFilter(seasonYear: 2026)
        filter.blocks = [Self.blockB]
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count == 1)

        filter = PruningActivityFilter(seasonYear: 2026)
        filter.varieties = ["Shiraz"]
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count == 2)

        filter = PruningActivityFilter(seasonYear: 2026)
        filter.statuses = [.reversed]
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count == 1)

        filter = PruningActivityFilter(seasonYear: 2026)
        filter.taskLink = .linked
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count == 1)
        filter.taskLink = .notLinked
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count == 2)

        filter = PruningActivityFilter(seasonYear: 2026)
        filter.dateFrom = Self.date(2026, 7, 5)
        filter.dateTo = Self.date(2026, 7, 9)
        #expect(PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count == 2)
    }

    @Test("Search matches worker, block, variety, row, Work Task and notes")
    func search() {
        let rows = Self.build([
            Self.entry(day: 1, worker: "Sam", notes: "wet morning"),
            Self.entry(day: 5, paddock: Self.blockB, worker: "Ana", workTaskId: Self.taskId)
        ])

        func hits(_ needle: String) -> Int {
            var filter = PruningActivityFilter(seasonYear: 2026)
            filter.search = needle
            return PruningActivityReport.filtered(rows, with: filter, calendar: Self.calendar).count
        }

        #expect(hits("ana") == 1)
        #expect(hits("Block B") == 1)
        #expect(hits("riesling") == 1)
        #expect(hits("wet") == 1)
        #expect(hits("Pruning — Block A") == 1)
        #expect(hits("nothing here") == 0)
    }

    // MARK: Sorting

    @Test("The default order is date descending, then created descending")
    func defaultOrder() {
        let older = Self.entry(day: 2)
        let newer = Self.entry(day: 8)
        let sameDayLater = Self.entry(day: 8, createdAt: Self.date(2026, 7, 8, 18, 0))
        let rows = PruningActivityReport.sorted(
            Self.build([older, newer, sameDayLater]),
            by: .default
        )
        #expect(rows[0].id == sameDayLater.id)
        #expect(rows[1].id == newer.id)
        #expect(rows[2].id == older.id)
    }

    @Test("Rows sort naturally — row 2 before row 10")
    func naturalRowOrder() {
        let low = Self.entry(day: 1, segments: [PruningSegment(row: 2, quarter: 1)])
        let high = Self.entry(day: 2, segments: [PruningSegment(row: 10, quarter: 1)])
        let ascending = PruningActivityReport.sorted(
            Self.build([high, low]),
            by: PruningActivitySort(column: .rows, ascending: true)
        )
        #expect(ascending[0].id == low.id)
        #expect(ascending[1].id == high.id)
    }

    @Test("Numbers sort numerically and blanks sort last in both directions")
    func numericAndBlankOrder() {
        let big = Self.entry(day: 1, segments: [
            PruningSegment(row: 1, quarter: 1),
            PruningSegment(row: 1, quarter: 2),
            PruningSegment(row: 1, quarter: 3),
            PruningSegment(row: 1, quarter: 4)
        ], hours: 4)
        let small = Self.entry(day: 2, hours: 1)
        let blank = Self.entry(day: 3, hours: nil)
        let built = Self.build([blank, small, big])

        let ascending = PruningActivityReport.sorted(built, by: PruningActivitySort(column: .hours, ascending: true))
        #expect(ascending.map(\.labourHours) == [1, 4, nil])

        let descending = PruningActivityReport.sorted(built, by: PruningActivitySort(column: .hours, ascending: false))
        #expect(descending.map(\.labourHours) == [4, 1, nil])
    }

    @Test("Times sort as times, not as display strings")
    func timeOrder() {
        let late = Self.entry(day: 1, start: Self.date(2026, 7, 1, 13, 0))
        let early = Self.entry(day: 2, start: Self.date(2026, 7, 2, 6, 45))
        let sorted = PruningActivityReport.sorted(
            Self.build([late, early]),
            by: PruningActivitySort(column: .start, ascending: true)
        )
        #expect(sorted[0].id == early.id)
    }

    @Test("Tapping a heading cycles unsorted → ascending → descending → unsorted")
    func sortCycle() {
        var sort = PruningActivitySort.default
        sort = sort.cycled(.vines)
        #expect(sort.column == .vines && sort.ascending)
        sort = sort.cycled(.vines)
        #expect(sort.column == .vines && !sort.ascending)
        sort = sort.cycled(.vines)
        #expect(sort.column == nil)
        // Tapping a different heading starts that column ascending.
        sort = sort.cycled(.worker).cycled(.block)
        #expect(sort.column == .block && sort.ascending)
    }

    // MARK: Summary

    @Test("Reversed records are counted but never contribute vines, hours, productivity or cost")
    func summaryExcludesReversed() {
        let rows = Self.build([
            // 4 quarters = 100 vines over 4 h.
            Self.entry(day: 1, segments: [
                PruningSegment(row: 1, quarter: 1),
                PruningSegment(row: 1, quarter: 2),
                PruningSegment(row: 1, quarter: 3),
                PruningSegment(row: 1, quarter: 4)
            ], hours: 4, workTaskId: Self.taskId),
            // 2 quarters = 50 vines over 1 h.
            Self.entry(day: 2, hours: 1),
            // Reversed — must not move a single total.
            Self.entry(day: 3, segments: [
                PruningSegment(row: 9, quarter: 1),
                PruningSegment(row: 9, quarter: 2)
            ], hours: 5, workTaskId: Self.taskId, reversedAt: Self.date(2026, 7, 4))
        ])

        let summary = PruningActivityReport.summary(rows, includeCost: true)
        #expect(summary.jobs == 3)
        #expect(summary.activeRecords == 2)
        #expect(summary.reversedRecords == 1)
        #expect(summary.vines == 150)
        #expect(summary.labourHours == 5)
        #expect(summary.averageVinesPerHour == 30)
        #expect(summary.labourCost == 240)
    }

    @Test("Costing totals are omitted when the role can't see costing")
    func summaryHidesCostWithoutPermission() {
        let rows = Self.build([Self.entry(day: 1, workTaskId: Self.taskId)])
        #expect(PruningActivityReport.summary(rows, includeCost: false).labourCost == nil)
        #expect(PruningActivityReport.summary(rows, includeCost: true).labourCost == 240)
    }

    @Test("Records without labour hours are excluded from productivity on both sides")
    func productivityIgnoresHourlessRecords() {
        let rows = Self.build([
            Self.entry(day: 1, hours: 2),
            Self.entry(day: 2, hours: nil)
        ])
        let summary = PruningActivityReport.summary(rows, includeCost: true)
        // Both records' vines count towards the vine total…
        #expect(summary.vines == 100)
        // …but only the hour-carrying record drives vines per hour (50 ÷ 2).
        #expect(summary.averageVinesPerHour == 25)
    }
}
