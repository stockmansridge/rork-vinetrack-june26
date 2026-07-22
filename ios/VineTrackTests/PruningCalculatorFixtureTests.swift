import Foundation
import Testing
@testable import VineTrack

/// SHARED PRUNING CALCULATION FIXTURE — the same deterministic fixture exists
/// as `PruningCalculatorFixtureTest.kt` in the Android unit-test source set,
/// and its rules are the documented SQL 115 contract
/// (`get_pruning_vineyard_summary`, docs/pruning-fertiliser-sync.md). All
/// three implementations must produce these exact unrounded values before
/// display formatting.
///
/// Fixture (as of 2026-07-14):
///  * Block A "Cab Franc": 7 configured rows with REAL non-sequential numbers
///    42–47 + 50 (gap preserved), six 200 m rows + one 100 m row, vine count
///    override 1300 → row vines 200/200/200/200/200/200/100.
///    Completed: rows 42–45 full + row 46 Q1+Q2 = 18 quarters = 4.5 row eq,
///    900.0 exact vines, recorded across two entries
///    (13 Jul: 8 quarters / 4 h · 14 Jul: 10 quarters / 8 h person-hours).
///  * Block B "Fallback": no configured rows, manual row count 4, vine count
///    override 400 → four generated fallback rows of 100 vines.
///
/// Expected: block A 64 %, ahead, projected 2026-07-15; vineyard 41 %,
/// 900 / 1700 vines, 450 vines/day, 75 vines/labour-hour.
struct PruningCalculatorFixtureTests {

    // MARK: Fixture

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    private static let asOf = date(2026, 7, 14)

    private static let vineyardId = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
    private static let blockAId = UUID(uuidString: "00000000-0000-0000-0000-0000000000ab")!
    private static let blockBId = UUID(uuidString: "00000000-0000-0000-0000-0000000000ac")!

    private static let metresPerDegreeLat = 111_320.0

    private static func rowId(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private static func row(_ number: Int, lengthMetres: Double) -> PaddockRow {
        let lon = 150.0 + Double(number) * 0.001
        return PaddockRow(
            id: rowId(number),
            number: number,
            startPoint: CoordinatePoint(latitude: 0, longitude: lon),
            endPoint: CoordinatePoint(latitude: lengthMetres / metresPerDegreeLat, longitude: lon)
        )
    }

    private static let blockA = Paddock(
        id: blockAId,
        vineyardId: vineyardId,
        name: "Cab Franc",
        // Stored intentionally out of order — rowRefs must sort ascending by number.
        rows: [
            row(50, lengthMetres: 100), row(47, lengthMetres: 200), row(42, lengthMetres: 200),
            row(45, lengthMetres: 200), row(43, lengthMetres: 200), row(46, lengthMetres: 200),
            row(44, lengthMetres: 200)
        ],
        vineSpacing: 1.0,
        vineCountOverride: 1300
    )

    private static let blockB = Paddock(
        id: blockBId,
        vineyardId: vineyardId,
        name: "Fallback",
        rows: [],
        vineCountOverride: 400
    )

    private static let setupA = PruningBlockSetup(
        vineyardId: vineyardId,
        paddockId: blockAId,
        seasonYear: 2026,
        startDate: date(2026, 7, 1),
        dueDate: date(2026, 8, 15),
        workingDays: [1, 2, 3, 4, 5]
    )

    private static let setupB = PruningBlockSetup(
        vineyardId: vineyardId,
        paddockId: blockBId,
        seasonYear: 2026,
        rowCountOverride: 4
    )

    private static func fullRow(_ number: Int) -> [PruningSegment] {
        (1...4).map { PruningSegment(rowId: rowId(number), row: number, quarter: $0) }
    }

    private static let entry1 = PruningEntry(
        vineyardId: vineyardId,
        paddockId: blockAId,
        seasonId: setupA.id,
        date: date(2026, 7, 13),
        segments: fullRow(42) + fullRow(43),
        labourHours: 4.0
    )

    private static let entry2 = PruningEntry(
        vineyardId: vineyardId,
        paddockId: blockAId,
        seasonId: setupA.id,
        date: date(2026, 7, 14),
        segments: fullRow(44) + fullRow(45) + [
            PruningSegment(rowId: rowId(46), row: 46, quarter: 1),
            PruningSegment(rowId: rowId(46), row: 46, quarter: 2)
        ],
        labourHours: 8.0
    )

    private static let entries = [entry1, entry2]

    // MARK: Row identity

    @Test func rowRefs_sortAscendingAndPreserveActualNonSequentialNumbers() {
        let rows = PruningCalculator.rowRefs(paddock: Self.blockA, setup: Self.setupA)
        // Input is stored out of order; refs must come back lowest → highest.
        #expect(rows.map(\.number) == [42, 43, 44, 45, 46, 47, 50])
        #expect(rows.allSatisfy { !$0.isFallback })
        // Row 48/49 must NOT be invented; row vines follow each row's length.
        #expect(abs((rows.first { $0.number == 42 }?.vines ?? 0) - 200.0) < 1e-6)
        #expect(abs((rows.first { $0.number == 50 }?.vines ?? 0) - 100.0) < 1e-6)
        #expect(abs(rows.reduce(0) { $0 + $1.vines } - 1300.0) < 1e-6)
    }

    @Test func rowRefs_manualFallbackOnlyWhenNoConfiguredRows() {
        let rows = PruningCalculator.rowRefs(paddock: Self.blockB, setup: Self.setupB)
        #expect(rows.map(\.number) == [1, 2, 3, 4])
        #expect(rows.allSatisfy(\.isFallback))
        #expect(abs((rows.first?.vines ?? 0) - 100.0) < 1e-6)
    }

    // MARK: Block metrics (SQL 115 contract)

    @Test func blockA_metricsMatchSharedContract() {
        let m = PruningCalculator.metrics(
            paddock: Self.blockA, setup: Self.setupA, entries: Self.entries,
            calendar: Self.calendar, asOf: Self.asOf
        )
        #expect(m.rowCount == 7)
        #expect(abs(m.completedRowEquivalents - 4.5) < 1e-9)
        #expect(abs(m.totalRowEquivalents - 7.0) < 1e-9)
        // displayPercent = round(fraction × 100) half up — 64.28… → 64.
        #expect(PruningCalculator.displayPercent(m.fractionComplete) == 64)
        // Exact quarter vines summed at full precision, rounded ONCE: 900.
        #expect(abs(m.vinesPrunedExact - 900.0) < 1e-6)
        #expect(m.vinesPruned == 900)
        #expect(m.vinesTotal == 1300)
        // Rolling rate: mean row-eq/day over the 3 most recent days-with-entries.
        #expect(abs((m.ratePerWorkday ?? 0) - 2.25) < 1e-9)
        // ceil(2.5 / 2.25) = 2 working days from 14 Jul (Tue counts) → 15 Jul.
        #expect(m.projectedFinish == Self.date(2026, 7, 15))
        // Projected > 3 days before the 15 Aug due date → Ahead.
        #expect(m.status == .ahead)
    }

    @Test func blockB_noEntries_isNotStartedWithoutRate() {
        let m = PruningCalculator.metrics(
            paddock: Self.blockB, setup: Self.setupB, entries: [],
            calendar: Self.calendar, asOf: Self.asOf
        )
        #expect(m.rowCount == 4)
        #expect(m.completedRowEquivalents == 0)
        #expect(m.status == .notStarted)
        #expect(m.ratePerWorkday == nil)
        #expect(m.projectedFinish == nil)
    }

    // MARK: Vineyard summary (SQL 115 contract)

    @Test func vineyardSummary_matchesSharedContract() {
        let s = PruningCalculator.vineyardSummary(
            paddocks: [Self.blockA, Self.blockB],
            setups: [Self.setupA, Self.setupB],
            entries: Self.entries,
            calendar: Self.calendar,
            asOf: Self.asOf
        )
        #expect(s.blockCount == 2)
        #expect(abs(s.completedRowEquivalents - 4.5) < 1e-9)
        #expect(abs(s.totalRowEquivalents - 11.0) < 1e-9)
        // Row-equivalent progress, NOT vine-weighted: 4.5 / 11 → 41 %.
        #expect(s.displayPercent == 41)
        #expect(s.vinesTotal == 1700)
        #expect(s.vinesPruned == 900)
        #expect(s.vinesRemaining == 800)
        // Mean of per-day exact totals over days-with-entries: (400+500)/2.
        #expect(abs((s.vinesPerDay ?? 0) - 450.0) < 1e-6)
        // Person-hours: 900 exact vines ÷ (4 + 8) h.
        #expect(abs((s.vinesPerLabourHour ?? 0) - 75.0) < 1e-6)
        #expect(abs(s.labourHours - 12.0) < 1e-9)
        #expect(s.blocksComplete == 0)
        #expect(s.blocksAtRisk == 0)
        #expect(s.projectedFinish == Self.date(2026, 7, 15))
    }

    @Test func vineyardSummary_liveValuesRoundLikeSql115() {
        // Same rounding rules the live JH Testing values follow:
        // round(exact) half up for vines, round(fraction × 100) for percent.
        let s = PruningCalculator.vineyardSummary(
            paddocks: [Self.blockA, Self.blockB],
            setups: [Self.setupA, Self.setupB],
            entries: Self.entries,
            calendar: Self.calendar,
            asOf: Self.asOf
        )
        #expect(s.vinesPruned == Int(s.vinesPrunedExact.rounded()))
        #expect(s.displayPercent == Int((s.fraction * 100).rounded()))
    }

    // MARK: Duplicate + legacy segment handling

    @Test func duplicateQuarterAcrossEntries_isNeverCountedTwice() {
        let duplicate = PruningEntry(
            vineyardId: Self.vineyardId,
            paddockId: Self.blockAId,
            seasonId: Self.setupA.id,
            date: Self.date(2026, 7, 14),
            // Row 42 Q1 was already completed by entry 1.
            segments: [PruningSegment(rowId: Self.rowId(42), row: 42, quarter: 1)]
        )
        let m = PruningCalculator.metrics(
            paddock: Self.blockA, setup: Self.setupA, entries: Self.entries + [duplicate],
            calendar: Self.calendar, asOf: Self.asOf
        )
        #expect(abs(m.completedRowEquivalents - 4.5) < 1e-9)
        #expect(m.vinesPruned == 900)
    }

    @Test func legacySegmentWithoutRowId_matchesRowByStoredNumber() {
        let legacy = PruningEntry(
            vineyardId: Self.vineyardId,
            paddockId: Self.blockAId,
            seasonId: Self.setupA.id,
            date: Self.date(2026, 7, 14),
            segments: [PruningSegment(rowId: nil, row: 47, quarter: 1)]
        )
        let m = PruningCalculator.metrics(
            paddock: Self.blockA, setup: Self.setupA, entries: Self.entries + [legacy],
            calendar: Self.calendar, asOf: Self.asOf
        )
        #expect(abs(m.completedRowEquivalents - 4.75) < 1e-9)
        // Quarter of row 47 (200 vines) adds exactly 50 exact vines.
        #expect(abs(m.vinesPrunedExact - 950.0) < 1e-6)
    }

    @Test func reversingAnEntry_reopensItsQuartersExactly() {
        let m = PruningCalculator.metrics(
            paddock: Self.blockA, setup: Self.setupA, entries: [Self.entry1],
            calendar: Self.calendar, asOf: Self.asOf
        )
        #expect(abs(m.completedRowEquivalents - 2.0) < 1e-9)
        #expect(m.vinesPruned == 400)
    }

    // MARK: Rate edge cases

    @Test func daysWithoutEntries_neverReduceTheRate() {
        // Two working days recorded across a gap — rate divides by 2, not by
        // the calendar span.
        var gapEntry = Self.entry2
        gapEntry = PruningEntry(
            vineyardId: gapEntry.vineyardId,
            paddockId: gapEntry.paddockId,
            seasonId: gapEntry.seasonId,
            date: Self.date(2026, 7, 20),
            segments: gapEntry.segments,
            labourHours: gapEntry.labourHours
        )
        let rate = PruningCalculator.rowEquivalentsPerDay(
            entries: [Self.entry1, gapEntry], lastDays: nil, calendar: Self.calendar
        )
        #expect(abs((rate ?? 0) - 2.25) < 1e-9)
    }

    @Test func zeroLabourHours_excludedFromBothSidesOfTheRate() {
        let unpaid = PruningEntry(
            vineyardId: Self.vineyardId,
            paddockId: Self.blockAId,
            seasonId: Self.setupA.id,
            date: Self.date(2026, 7, 14),
            segments: Self.entry2.segments,
            labourHours: nil
        )
        let rows = PruningCalculator.rowRefs(paddock: Self.blockA, setup: Self.setupA)
        let perHour = PruningCalculator.vinesPerLabourHour(entries: [Self.entry1, unpaid], rows: rows)
        // Only entry 1 carries hours: 400 vines ÷ 4 h.
        #expect(abs((perHour ?? 0) - 100.0) < 1e-6)
    }

    @Test func noWork_returnsEmptyRatesWithoutFailing() {
        let rows = PruningCalculator.rowRefs(paddock: Self.blockA, setup: Self.setupA)
        #expect(PruningCalculator.rowEquivalentsPerDay(entries: [], lastDays: nil, calendar: Self.calendar) == nil)
        #expect(PruningCalculator.exactVinesPerDay(entries: [], rows: rows, calendar: Self.calendar) == nil)
        #expect(PruningCalculator.vinesPerLabourHour(entries: [], rows: rows) == nil)
        let s = PruningCalculator.vineyardSummary(
            paddocks: [Self.blockA],
            setups: [Self.setupA],
            entries: [],
            calendar: Self.calendar,
            asOf: Self.asOf
        )
        #expect(s.displayPercent == 0)
        #expect(s.vinesPruned == 0)
    }
}
