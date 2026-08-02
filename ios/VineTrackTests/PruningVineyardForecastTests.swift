import Foundation
import Testing
@testable import VineTrack

/// SHARED VINEYARD FORECAST FIXTURE — the same cases exist as
/// `PruningVineyardForecastTest.kt` in the Android unit-test source set. Both
/// implementations must produce identical elapsed days, average vines/day and
/// outcome.
///
/// Contract under test:
///  * elapsed days = calendar days from the FIRST valid entry through today,
///    INCLUSIVE (days without pruning still count),
///  * average = exact vines pruned ÷ elapsed days,
///  * remaining = EVERY configured block's vines − vines pruned,
///  * days remaining = ceil(remaining ÷ average), rounded UP,
///  * 100 % → the last valid pruning date, never a future projection,
///  * anything unusable → `.notEnoughData`, never an arbitrary date.
struct PruningVineyardForecastTests {

    // MARK: Fixture

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    private static let asOf = date(2026, 8, 2)

    private static let vineyardId = UUID(uuidString: "00000000-0000-0000-0000-0000000000ba")!
    private static let blockAId = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
    private static let blockBId = UUID(uuidString: "00000000-0000-0000-0000-0000000000bc")!
    private static let blockCId = UUID(uuidString: "00000000-0000-0000-0000-0000000000bd")!

    private static let metresPerDegreeLat = 111_320.0

    private static func rowId(_ block: Int, _ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-%04d-%012d", block, number))!
    }

    private static func row(_ block: Int, _ number: Int, lengthMetres: Double = 200) -> PaddockRow {
        let lon = 150.0 + Double(block) * 0.1 + Double(number) * 0.001
        return PaddockRow(
            id: rowId(block, number),
            number: number,
            startPoint: CoordinatePoint(latitude: 0, longitude: lon),
            endPoint: CoordinatePoint(latitude: lengthMetres / metresPerDegreeLat, longitude: lon)
        )
    }

    /// 4 rows × 100 vines.
    private static let blockA = Paddock(
        id: blockAId,
        vineyardId: vineyardId,
        name: "A — started",
        rows: (1...4).map { row(1, $0) },
        vineCountOverride: 400
    )

    /// 4 rows × 100 vines — NEVER touched. Still remaining workload.
    private static let blockB = Paddock(
        id: blockBId,
        vineyardId: vineyardId,
        name: "B — untouched",
        rows: (1...4).map { row(2, $0) },
        vineCountOverride: 400
    )

    /// 2 rows × 100 vines — completed.
    private static let blockC = Paddock(
        id: blockCId,
        vineyardId: vineyardId,
        name: "C — complete",
        rows: (1...2).map { row(3, $0) },
        vineCountOverride: 200
    )

    private static func setup(_ paddockId: UUID) -> PruningBlockSetup {
        PruningBlockSetup(vineyardId: vineyardId, paddockId: paddockId, seasonYear: 2026)
    }

    private static func entry(
        _ paddockId: UUID,
        block: Int,
        on day: Date,
        segments: [PruningSegment],
        hours: Double? = nil
    ) -> PruningEntry {
        PruningEntry(
            vineyardId: vineyardId,
            paddockId: paddockId,
            date: day,
            segments: segments,
            labourHours: hours
        )
    }

    private static func fullRow(_ block: Int, _ number: Int) -> [PruningSegment] {
        (1...4).map { PruningSegment(rowId: rowId(block, number), row: number, quarter: $0) }
    }

    private static func quarters(_ block: Int, _ number: Int, _ quarters: [Int]) -> [PruningSegment] {
        quarters.map { PruningSegment(rowId: rowId(block, number), row: number, quarter: $0) }
    }

    private static func forecast(
        pruned: Double,
        total: Int,
        complete: Bool = false,
        dates: [Date],
        asOf: Date = asOf
    ) -> PruningVineyardForecast {
        PruningCalculator.vineyardForecast(
            vinesPrunedExact: pruned,
            vinesTotal: total,
            isComplete: complete,
            entryDates: dates,
            asOf: asOf,
            calendar: calendar
        )
    }

    // MARK: The reported production regression

    /// The exact numbers from the field report: ~51 % done, 11 101 pruned,
    /// 10 761 remaining, pruning underway for about a month. The old rate
    /// (mean over days-WITH-entries, last 3 days) produced 653 vines/day and
    /// "about 8 days". The elapsed-calendar-day rule must produce ~370/day.
    @Test func fieldReport_oneMonthUnderway_projectsAboutAMonthNotAWeek() {
        let first = Self.date(2026, 7, 4) // 30 inclusive days through 2 Aug
        let f = Self.forecast(pruned: 11_101, total: 21_862, dates: [first, Self.date(2026, 8, 1)])

        #expect(f.elapsedDays == 30)
        #expect(abs((f.averageVinesPerElapsedDay ?? 0) - 370.0333333) < 1e-4)
        // ceil(10 761 ÷ 370.03) = 30 — rounded UP so the date is never early.
        #expect(f.estimatedDaysRemaining == 30)
        #expect(f.outcome == .projected(Self.date(2026, 9, 1)))
        // The old behaviour (≈8 days) must be impossible now.
        #expect((f.estimatedDaysRemaining ?? 0) > 20)
    }

    // MARK: Elapsed-day rule

    @Test func firstEntryToday_countsAsOneElapsedDay() {
        let f = Self.forecast(pruned: 200, total: 1_000, dates: [Self.asOf])
        #expect(f.elapsedDays == 1)
        #expect(abs((f.averageVinesPerElapsedDay ?? 0) - 200.0) < 1e-9)
        #expect(f.estimatedDaysRemaining == 4)
        #expect(f.outcome == .projected(Self.date(2026, 8, 6)))
    }

    @Test func daysWithoutEntries_stillCountAsElapsedTime() {
        // Work on 2 days only, spread over 10 calendar days.
        let dates = [Self.date(2026, 7, 24), Self.date(2026, 7, 30)]
        let f = Self.forecast(pruned: 1_000, total: 3_000, dates: dates)
        #expect(f.elapsedDays == 10)
        // NOT 500/day (mean of active days) — 100/day across the calendar.
        #expect(abs((f.averageVinesPerElapsedDay ?? 0) - 100.0) < 1e-9)
        #expect(f.estimatedDaysRemaining == 20)
    }

    @Test func entryDatesOutOfOrder_useTheEarliestAsTheAnchor() {
        let dates = [Self.date(2026, 7, 30), Self.date(2026, 7, 24), Self.date(2026, 7, 28)]
        #expect(Self.forecast(pruned: 500, total: 900, dates: dates).elapsedDays == 10)
    }

    @Test func futureDatedFirstEntry_clampsToASingleElapsedDay() {
        let f = Self.forecast(pruned: 100, total: 500, dates: [Self.date(2026, 8, 9)])
        #expect(f.elapsedDays == 1)
        #expect(abs((f.averageVinesPerElapsedDay ?? 0) - 100.0) < 1e-9)
    }

    // MARK: Insufficient data

    @Test func noEntries_isNotEnoughData() {
        let f = Self.forecast(pruned: 0, total: 1_000, dates: [])
        #expect(f.outcome == .notEnoughData)
        #expect(f.averageVinesPerElapsedDay == nil)
        #expect(f.estimatedDaysRemaining == nil)
    }

    @Test func zeroConfiguredVines_isNotEnoughData() {
        let f = Self.forecast(pruned: 0, total: 0, dates: [Self.date(2026, 7, 20)])
        #expect(f.outcome == .notEnoughData)
    }

    @Test func entriesButNoVines_isNotEnoughData() {
        // Entries exist but resolve to zero vines (missing vine counts).
        let f = Self.forecast(pruned: 0, total: 1_000, dates: [Self.date(2026, 7, 20)])
        #expect(f.outcome == .notEnoughData)
        #expect(f.averageVinesPerElapsedDay == nil)
    }

    // MARK: Completion

    @Test func vineyardAtOneHundredPercent_showsTheLastActivityDate() {
        let last = Self.date(2026, 8, 2)
        let f = Self.forecast(
            pruned: 1_000, total: 1_000, complete: true,
            dates: [Self.date(2026, 7, 4), last]
        )
        #expect(f.outcome == .completed(last))
        #expect(f.estimatedDaysRemaining == 0)
        #expect(f.vinesRemainingExact == 0)
    }

    @Test func remainingBelowOneVine_completesWithoutProjecting() {
        let last = Self.date(2026, 7, 31)
        let f = Self.forecast(pruned: 999.7, total: 1_000, dates: [last])
        #expect(f.outcome == .completed(last))
    }

    // MARK: End-to-end through the dashboard summary

    private static func summary(
        paddocks: [Paddock],
        entries: [PruningEntry],
        asOf: Date = asOf
    ) -> PruningVineyardSummary {
        PruningCalculator.vineyardSummary(
            paddocks: paddocks,
            setups: paddocks.map { setup($0.id) },
            entries: entries,
            calendar: calendar,
            asOf: asOf
        )
    }

    @Test func blocksWithZeroProgress_stayInTheRemainingWorkload() {
        // Block A: 2 of 4 rows done over 4 inclusive calendar days.
        // Block B: never started — 400 vines still to prune.
        let entries = [
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 7, 30), segments: Self.fullRow(1, 1)),
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 8, 2), segments: Self.fullRow(1, 2))
        ]
        let s = Self.summary(paddocks: [Self.blockA, Self.blockB], entries: entries)

        #expect(s.vinesTotal == 800)
        #expect(s.vinesPruned == 200)
        #expect(s.vinesRemaining == 600)
        #expect(s.forecast.elapsedDays == 4)
        // 200 ÷ 4 elapsed days = 50/day (NOT 100/day over active days only).
        #expect(abs((s.averageVinesPerElapsedDay ?? 0) - 50.0) < 1e-9)
        // 600 remaining includes untouched block B → 12 days.
        #expect(s.forecast.estimatedDaysRemaining == 12)
        #expect(s.forecast.outcome == .projected(Self.date(2026, 8, 14)))
    }

    @Test func completedBlockPlusUnstartedBlocks_stillProjectsTheWholeVineyard() {
        let entries = [
            Self.entry(Self.blockCId, block: 3, on: Self.date(2026, 8, 1), segments: Self.fullRow(3, 1)),
            Self.entry(Self.blockCId, block: 3, on: Self.date(2026, 8, 2), segments: Self.fullRow(3, 2))
        ]
        let s = Self.summary(paddocks: [Self.blockA, Self.blockB, Self.blockC], entries: entries)

        #expect(s.blocksComplete == 1)
        #expect(s.vinesTotal == 1_000)
        #expect(s.vinesPruned == 200)
        // 2 elapsed days → 100/day; 800 remaining → 8 days.
        #expect(s.forecast.elapsedDays == 2)
        #expect(s.forecast.estimatedDaysRemaining == 8)
    }

    @Test func partialRowsAndQuarterEntries_countTowardsTheAverage() {
        // Row 1 fully + row 2 Q1 only = 125 vines over 2 elapsed days.
        let entries = [
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 8, 1), segments: Self.fullRow(1, 1)),
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 8, 2), segments: Self.quarters(1, 2, [1]))
        ]
        let s = Self.summary(paddocks: [Self.blockA], entries: entries)
        #expect(abs(s.vinesPrunedExact - 125.0) < 1e-6)
        #expect(abs((s.averageVinesPerElapsedDay ?? 0) - 62.5) < 1e-9)
    }

    @Test func reversedEntry_removesItsWorkAndItsElapsedAnchor() {
        // The only entry of 24 Jul was reversed (its quarters removed); the
        // period must now start at the 1 Aug entry, not 24 Jul.
        let reversed = Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 7, 24), segments: [])
        let entries = [
            reversed,
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 8, 1), segments: Self.fullRow(1, 1))
        ]
        let s = Self.summary(paddocks: [Self.blockA], entries: entries)
        #expect(s.forecast.firstEntryDate == Self.date(2026, 8, 1))
        #expect(s.forecast.elapsedDays == 2)
        #expect(abs((s.averageVinesPerElapsedDay ?? 0) - 50.0) < 1e-9)
    }

    @Test func segmentsOnDeletedRows_neverAnchorTheElapsedPeriod() {
        // An entry recorded against a row that no longer exists on the block.
        let orphan = Self.entry(
            Self.blockAId, block: 1, on: Self.date(2026, 6, 1),
            segments: [PruningSegment(rowId: Self.rowId(9, 99), row: 99, quarter: 1)]
        )
        let entries = [
            orphan,
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 8, 1), segments: Self.fullRow(1, 1))
        ]
        let s = Self.summary(paddocks: [Self.blockA], entries: entries)
        #expect(s.forecast.firstEntryDate == Self.date(2026, 8, 1))
    }

    @Test func editedHistoricalEntry_movesTheElapsedAnchorBack() {
        // The 1 Aug entry was corrected to its real date of 20 Jul.
        let entries = [
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 7, 20), segments: Self.fullRow(1, 1))
        ]
        let s = Self.summary(paddocks: [Self.blockA], entries: entries)
        #expect(s.forecast.elapsedDays == 14)
        #expect(abs((s.averageVinesPerElapsedDay ?? 0) - (100.0 / 14.0)) < 1e-9)
    }

    @Test func duplicateQuartersAcrossEntries_neverInflateTheAverage() {
        let entries = [
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 8, 1), segments: Self.fullRow(1, 1)),
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 8, 2), segments: Self.fullRow(1, 1))
        ]
        let s = Self.summary(paddocks: [Self.blockA], entries: entries)
        #expect(abs(s.vinesPrunedExact - 100.0) < 1e-6)
        #expect(abs((s.averageVinesPerElapsedDay ?? 0) - 50.0) < 1e-9)
    }

    @Test func fullyPrunedVineyard_showsCompletedNotAProjection() {
        let entries = (1...4).map { number in
            Self.entry(Self.blockAId, block: 1, on: Self.date(2026, 7, 29 + (number - 1)), segments: Self.fullRow(1, number))
        }
        let s = Self.summary(paddocks: [Self.blockA], entries: entries)
        #expect(s.displayPercent == 100)
        #expect(s.forecast.outcome == .completed(Self.date(2026, 8, 1)))
    }

    @Test func vineyardWithoutVineCounts_isNotEnoughData() {
        let noVines = Paddock(
            id: Self.blockAId,
            vineyardId: Self.vineyardId,
            name: "No vine counts",
            rows: [],
            vineCountOverride: 0
        )
        let s = Self.summary(paddocks: [noVines], entries: [])
        #expect(s.forecast.outcome == .notEnoughData)
    }

    // MARK: Display line (identical wording on both platforms)

    @Test func forecastLine_matchesTheSharedWording() {
        let projected = PruningVineyardForecast(
            firstEntryDate: nil, lastEntryDate: nil, elapsedDays: 30,
            averageVinesPerElapsedDay: 370, vinesRemainingExact: 10_761,
            estimatedDaysRemaining: 30, outcome: .projected(Self.date(2026, 8, 29))
        )
        #expect(PruningTrackerView.forecastLine(projected) == "Projected vineyard completion: 29 Aug 2026")

        var completed = projected
        completed.outcome = .completed(Self.date(2026, 8, 2))
        #expect(PruningTrackerView.forecastLine(completed) == "Vineyard completed: 2 Aug 2026")

        var unknown = projected
        unknown.outcome = .notEnoughData
        #expect(PruningTrackerView.forecastLine(unknown) == "Projected vineyard completion: Not enough data")
    }
}
