import Foundation
import Testing
@testable import VineTrack

/// PRUNING-OWNED LABOUR LINES (sql/190) — the iOS twin of
/// `PruningActivityLabourLineTest.kt`. Both suites assert the SAME fixtures as
/// the SQL suite, so any divergence between the three fails a build.
///
/// The two rules this suite exists to lock in:
///
/// ```text
/// hours = Σ EVERY active line          (unrated lines included)
/// cost  = Σ RATED lines only           (nil, never $0.00, when none is rated)
/// ```
///
/// and the ownership rule:
///
/// > Labour is PRUNING-OWNED. A linked Work Task never gets a copy; it resolves
/// > THROUGH to the same rows. Never add a task's labour to an activity's.
struct PruningActivityLabourLineTests {

    // MARK: - Shared fixture (identical on Android and in SQL)

    private static let vineyardId = UUID(uuidString: "00000000-0000-0000-0000-000000190a00")!
    private static let otherVineyardId = UUID(uuidString: "00000000-0000-0000-0000-000000190a01")!
    private static let activityId = UUID(uuidString: "00000000-0000-0000-0000-000000190a02")!
    private static let otherActivityId = UUID(uuidString: "00000000-0000-0000-0000-000000190a03")!
    private static let hourlyTaskId = UUID(uuidString: "00000000-0000-0000-0000-000000190a04")!
    private static let pieceTaskId = UUID(uuidString: "00000000-0000-0000-0000-000000190a05")!
    private static let blockA = UUID(uuidString: "00000000-0000-0000-0000-000000190a06")!
    private static let blockB = UUID(uuidString: "00000000-0000-0000-0000-000000190a07")!
    private static let blockC = UUID(uuidString: "00000000-0000-0000-0000-000000190a08")!
    private static let lineOneId = UUID(uuidString: "00000000-0000-0000-0000-000000190b01")!
    private static let lineTwoId = UUID(uuidString: "00000000-0000-0000-0000-000000190b02")!

    /// THE worked example: 2 people × 8 h @ $30 = 16 h, $480.
    private static let expectedOneLineHours = 16.0
    private static let expectedOneLineCost = 480.0
    /// Plus 1 person × 6 h @ $35 = $210 → 22 h, $690.
    private static let expectedTwoLineHours = 22.0
    private static let expectedTwoLineCost = 690.0
    /// The legacy scalar pair: 7.5 h × $32 = $240.
    private static let legacyHours = 7.5
    private static let legacyRate = 32.0
    private static let expectedLegacyCost = 240.0
    /// Piece rate: 250 vines × $0.55 = $137.50.
    private static let snapshotVines = 250
    private static let ratePerVine = 0.55
    private static let expectedPieceCost = 137.50

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    private static func line(
        id: UUID = UUID(),
        activity: UUID = activityId,
        vineyard: UUID = vineyardId,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        lineIndex: Int = 0
    ) -> PruningActivityLabourLine {
        PruningActivityLabourLine(
            id: id,
            pruningActivityId: activity,
            vineyardId: vineyard,
            workDate: date(2026, 8, 3),
            workerType: "Pruner",
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate,
            lineIndex: lineIndex
        )
    }

    /// 2 × 8 h @ $30 = 16 h, $480.
    private static func oneLine() -> [PruningActivityLabourLine] {
        [line(id: lineOneId, workerCount: 2, hoursPerWorker: 8, hourlyRate: 30, lineIndex: 0)]
    }

    /// The above plus 1 × 6 h @ $35 = $210 → 22 h, $690.
    private static func twoLines() -> [PruningActivityLabourLine] {
        oneLine() + [line(id: lineTwoId, workerCount: 1, hoursPerWorker: 6, hourlyRate: 35, lineIndex: 1)]
    }

    private static func hourlyTask() -> WorkTask {
        WorkTask(
            id: hourlyTaskId,
            vineyardId: vineyardId,
            date: date(2026, 8, 3),
            taskType: "Pruning",
            paddockId: blockA,
            costingMethodRaw: "hourly"
        )
    }

    private static func pieceRateTask() -> WorkTask {
        WorkTask(
            id: pieceTaskId,
            vineyardId: vineyardId,
            date: date(2026, 8, 3),
            taskType: "Pruning",
            paddockId: blockA,
            costingMethodRaw: "piece_rate",
            pieceRatePerVine: ratePerVine,
            pieceVineCount: snapshotVines
        )
    }

    private static func taskLine(workerCount: Int, hoursPerWorker: Double, hourlyRate: Double?) -> WorkTaskLabourLine {
        WorkTaskLabourLine(
            workTaskId: hourlyTaskId,
            vineyardId: vineyardId,
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate
        )
    }

    /// An activity spanning THREE blocks — labour must still be counted once.
    private static func multiBlockDraft(workTaskId: UUID? = nil) -> PruningActivityDraft {
        var allocations: [UUID: BlockPruningSelection] = [:]
        for (index, block) in [blockA, blockB, blockC].enumerated() {
            allocations[block] = BlockPruningSelection(
                paddockId: block,
                blockName: "Block \(index + 1)",
                segments: [PruningSegment(rowId: nil, row: index + 1, quarter: 1)],
                estimatedVines: 100
            )
        }
        return PruningActivityDraft(
            id: activityId,
            vineyardId: vineyardId,
            date: date(2026, 8, 3),
            worker: "Crew A",
            workTaskId: workTaskId,
            allocations: allocations
        )
    }

    private static func close(_ lhs: Double?, _ rhs: Double?, _ tolerance: Double = 0.0001) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs - rhs) < tolerance
    }

    /// The local twin of the DESIRED-STATE save: the payload IS the whole set,
    /// deduplicated on the client id, renumbered by position. Replaying the same
    /// payload must therefore be a no-op.
    private static func applyDesiredState(
        _ desired: [PruningActivityLabourLine],
        into existing: [PruningActivityLabourLine],
        activity: UUID = activityId
    ) -> [PruningActivityLabourLine] {
        var kept = existing.filter { $0.pruningActivityId != activity }
        var seen = Set<UUID>()
        for (index, line) in desired.enumerated() where seen.insert(line.id).inserted {
            var copy = line
            copy.pruningActivityId = activity
            copy.lineIndex = index
            kept.append(copy)
        }
        return kept
    }

    // MARK: - 1. ONE line

    @Test("One labour line: 2 × 8 h @ $30 = 16 h and $480")
    func oneLineTotals() throws {
        let lines = Self.oneLine()
        #expect(Self.close(PruningActivityLabourCosting.totalHours(lines), Self.expectedOneLineHours))
        #expect(Self.close(PruningActivityLabourCosting.totalCost(lines), Self.expectedOneLineCost))

        let totals = PruningActivityLabourCosting.totals(lines)
        #expect(totals.lineCount == 1)
        #expect(totals.workers == 2)
        #expect(Self.close(totals.personHours, Self.expectedOneLineHours))
        #expect(Self.close(totals.cost, Self.expectedOneLineCost))
    }

    // MARK: - 2. MULTIPLE lines

    @Test("Multiple labour lines sum to 22 h and $690 — two crews, two rates")
    func multipleLinesTotals() throws {
        let lines = Self.twoLines()
        #expect(Self.close(PruningActivityLabourCosting.totalHours(lines), Self.expectedTwoLineHours))
        #expect(Self.close(PruningActivityLabourCosting.totalCost(lines), Self.expectedTwoLineCost))

        // Resolution must pick the activity's OWN lines, and say so.
        let resolved = PruningActivityLabourCosting.resolve(
            task: nil,
            activityLines: lines,
            taskLines: [],
            legacyHours: nil,
            legacyRate: nil
        )
        #expect(resolved.source == .pruningLabourLines)
        #expect(resolved.lineCount == 2)
        #expect(Self.close(resolved.hours, Self.expectedTwoLineHours))
        #expect(Self.close(resolved.cost, Self.expectedTwoLineCost))
    }

    @Test("Lines are ordered by line_index, so a crew list cannot reshuffle between devices")
    func linesAreOrderedByIndex() throws {
        let shuffled = [Self.twoLines()[1], Self.twoLines()[0]]
        let ordered = PruningActivityLabourCosting.lines(shuffled, for: Self.activityId)
        #expect(ordered.map(\.id) == [Self.lineOneId, Self.lineTwoId])
    }

    // MARK: - 3. ADD / EDIT / REMOVE

    @Test("Add, edit and remove a labour line through the desired-state set")
    func addEditRemove() throws {
        // ADD the first line.
        var set = Self.applyDesiredState(Self.oneLine(), into: [])
        #expect(set.count == 1)
        #expect(Self.close(PruningActivityLabourCosting.totalCost(set), Self.expectedOneLineCost))

        // ADD a second.
        set = Self.applyDesiredState(Self.twoLines(), into: set)
        #expect(set.count == 2)
        #expect(Self.close(PruningActivityLabourCosting.totalHours(set), Self.expectedTwoLineHours))
        #expect(Self.close(PruningActivityLabourCosting.totalCost(set), Self.expectedTwoLineCost))

        // EDIT the first: the rate rises to $40 → 2 × 8 × 40 = $640, + $210 = $850.
        var edited = Self.twoLines()
        edited[0].hourlyRate = 40
        set = Self.applyDesiredState(edited, into: set)
        #expect(set.count == 2)
        #expect(Self.close(PruningActivityLabourCosting.totalHours(set), Self.expectedTwoLineHours))
        #expect(Self.close(PruningActivityLabourCosting.totalCost(set), 850))

        // REMOVE the second: absent from the desired set means deleted.
        set = Self.applyDesiredState([edited[0]], into: set)
        #expect(set.count == 1)
        #expect(Self.close(PruningActivityLabourCosting.totalHours(set), Self.expectedOneLineHours))
        #expect(Self.close(PruningActivityLabourCosting.totalCost(set), 640))

        // REMOVE the last: an EMPTY set is a legitimate instruction, and the
        // totals become nil — "not specified", never zero.
        set = Self.applyDesiredState([], into: set)
        #expect(set.isEmpty)
        #expect(PruningActivityLabourCosting.totalHours(set) == nil)
        #expect(PruningActivityLabourCosting.totalCost(set) == nil)
    }

    // MARK: - 4. UNRATED line — hours count, cost does not

    @Test("An unrated line counts in hours but is NEVER costed as $0.00")
    func unratedLineCountsHoursOnly() throws {
        let unrated = [Self.line(workerCount: 1, hoursPerWorker: 5, hourlyRate: nil)]
        // Hours are real work; the cost is genuinely unknown.
        #expect(Self.close(PruningActivityLabourCosting.totalHours(unrated), 5))
        #expect(PruningActivityLabourCosting.totalCost(unrated) == nil)
        #expect(PruningActivityLabourCosting.lineCost(unrated[0]) == nil)

        // Mixed: 2 × 9 h rated + 1 × 5 h unrated → 23 h, but only the rated
        // line contributes to the money.
        let mixed = [
            Self.line(workerCount: 2, hoursPerWorker: 9, hourlyRate: 30, lineIndex: 0),
            Self.line(workerCount: 1, hoursPerWorker: 5, hourlyRate: nil, lineIndex: 1),
        ]
        #expect(Self.close(PruningActivityLabourCosting.totalHours(mixed), 23))
        #expect(Self.close(PruningActivityLabourCosting.totalCost(mixed), 540))

        // An activity whose lines are ALL unrated must not fall through to a
        // legacy rate: its own lines ARE the labour record.
        let resolved = PruningActivityLabourCosting.resolve(
            task: nil,
            activityLines: unrated,
            taskLines: [],
            legacyHours: Self.legacyHours,
            legacyRate: Self.legacyRate
        )
        #expect(resolved.source == .pruningLabourLines)
        #expect(Self.close(resolved.hours, 5))
        #expect(resolved.cost == nil)
    }

    // MARK: - 5. LEGACY activity — never back-filled

    @Test("A legacy activity with no lines still resolves to 7.5 h × $32 = $240")
    func legacyActivityUnchanged() throws {
        let resolved = PruningActivityLabourCosting.resolve(
            task: nil,
            activityLines: [],
            taskLines: [],
            legacyHours: Self.legacyHours,
            legacyRate: Self.legacyRate
        )
        #expect(resolved.source == .activityHours)
        #expect(resolved.isLegacy)
        #expect(resolved.lineCount == 0)
        #expect(Self.close(resolved.hours, Self.legacyHours))
        #expect(Self.close(resolved.cost, Self.expectedLegacyCost))

        // Effective HOURS fall back to the same scalar.
        #expect(Self.close(
            PruningActivityLabourCosting.effectiveHours(activityLines: [], legacyHours: Self.legacyHours),
            Self.legacyHours
        ))
    }

    @Test("Adding a line to a legacy activity takes over — the two are never summed")
    func legacyIsSupersededNotAdded() throws {
        let resolved = PruningActivityLabourCosting.resolve(
            task: nil,
            activityLines: Self.oneLine(),
            taskLines: [],
            legacyHours: Self.legacyHours,
            legacyRate: Self.legacyRate
        )
        #expect(resolved.source == .pruningLabourLines)
        // $480, NOT $480 + $240 = $720.
        #expect(Self.close(resolved.cost, Self.expectedOneLineCost))
        #expect(Self.close(resolved.hours, Self.expectedOneLineHours))
    }

    @Test("Legacy conversion reproduces the original figure exactly and is opt-in")
    func legacyConversionPreservesTheFigure() throws {
        let converted = PruningActivityLabourCosting.legacyConversionLine(
            activityId: Self.activityId,
            vineyardId: Self.vineyardId,
            workDate: Self.date(2026, 8, 3),
            workerOrCrew: "Dave + 2 casuals",
            legacyHours: Self.legacyHours,
            legacyRate: Self.legacyRate
        )
        let line = try #require(converted)
        // The free-text crew becomes the worker TYPE — never split into a count.
        #expect(line.workerType == "Dave + 2 casuals")
        #expect(line.workerCount == 1)
        #expect(Self.close(PruningActivityLabourCosting.lineCost(line), Self.expectedLegacyCost))
        #expect(Self.close(PruningActivityLabourCosting.totalHours([line]), Self.legacyHours))

        // Nothing to convert when there are no recorded hours.
        #expect(PruningActivityLabourCosting.legacyConversionLine(
            activityId: Self.activityId,
            vineyardId: Self.vineyardId,
            workDate: Self.date(2026, 8, 3),
            workerOrCrew: "Crew",
            legacyHours: nil,
            legacyRate: nil
        ) == nil)
    }

    // MARK: - 6. MULTI-BLOCK — labour counted ONCE

    @Test("A three-block activity still reports 22 h and $690 — never ×3")
    func multiBlockCountsLabourOnce() throws {
        let draft = Self.multiBlockDraft()
        #expect(draft.blockCount == 3)

        let resolved = PruningActivityLabourCosting.resolve(
            task: nil,
            activityLines: Self.twoLines(),
            taskLines: [],
            legacyHours: nil,
            legacyRate: nil
        )
        // The labour figure is a property of the ACTIVITY, so the block count
        // cannot enter the arithmetic: $690, never $2,070.
        #expect(Self.close(resolved.cost, Self.expectedTwoLineCost))
        #expect(Self.close(resolved.hours, Self.expectedTwoLineHours))
        #expect(resolved.cost != Self.expectedTwoLineCost * 3)
    }

    // MARK: - 7. LINKED WORK TASK — read through, never a second copy

    @Test("A linked hourly task reports the activity's $480 — never $960")
    func linkedHourlyTaskReadsThrough() throws {
        let task = Self.hourlyTask()
        let draft = Self.multiBlockDraft(workTaskId: Self.hourlyTaskId)

        // The task holds NO labour lines of its own, so it resolves through to
        // the pruning activity's rows (SQL 190 rung 3).
        let taskCost = PruningActivityLabourCosting.effectiveWorkTaskCost(
            task: task,
            taskLines: [],
            activities: [draft],
            activityLines: Self.oneLine()
        )
        #expect(Self.close(taskCost, Self.expectedOneLineCost))
        // The SAME rows, so the two modules cannot double-count.
        #expect(taskCost != Self.expectedOneLineCost * 2)

        // The task's OWN lines outrank the read-through when it has them.
        let ownCost = PruningActivityLabourCosting.effectiveWorkTaskCost(
            task: task,
            taskLines: [Self.taskLine(workerCount: 1, hoursPerWorker: 10, hourlyRate: 25)],
            activities: [draft],
            activityLines: Self.oneLine()
        )
        #expect(Self.close(ownCost, 250))
    }

    @Test("An activity's own lines outrank the linked task's lines — precedence, not addition")
    func activityLinesOutrankTaskLines() throws {
        let resolved = PruningActivityLabourCosting.resolve(
            task: Self.hourlyTask(),
            activityLines: Self.oneLine(),
            taskLines: [Self.taskLine(workerCount: 1, hoursPerWorker: 10, hourlyRate: 25)],
            legacyHours: nil,
            legacyRate: nil
        )
        #expect(resolved.source == .pruningLabourLines)
        // $480, NOT $480 + $250 = $730.
        #expect(Self.close(resolved.cost, Self.expectedOneLineCost))
    }

    @Test("With no lines of its own, the activity falls back to the linked task's lines")
    func fallsBackToTaskLines() throws {
        let resolved = PruningActivityLabourCosting.resolve(
            task: Self.hourlyTask(),
            activityLines: [],
            taskLines: [Self.taskLine(workerCount: 2, hoursPerWorker: 8, hourlyRate: 30)],
            legacyHours: Self.legacyHours,
            legacyRate: Self.legacyRate
        )
        #expect(resolved.source == .workTaskLines)
        #expect(Self.close(resolved.cost, Self.expectedOneLineCost))
    }

    @Test("A linked piece-rate task is $137.50 — never added to the hourly lines")
    func linkedPieceRateWins() throws {
        let resolved = PruningActivityLabourCosting.resolve(
            task: Self.pieceRateTask(),
            // Hours recorded on a piece-rate job are operational history.
            activityLines: [Self.line(workerCount: 1, hoursPerWorker: 6, hourlyRate: nil)],
            taskLines: [],
            legacyHours: nil,
            legacyRate: nil
        )
        #expect(resolved.source == .pieceRate)
        #expect(Self.close(resolved.cost, Self.expectedPieceCost))
        // 137.50, never 137.50 + 480 = 617.50.
        #expect(resolved.cost != Self.expectedPieceCost + Self.expectedOneLineCost)
        // Hours are still reported — they drive vines-per-hour, not the cost.
        #expect(Self.close(resolved.hours, 6))
    }

    @Test("Costing visibility hides money but never hours")
    func costingVisibilityHidesMoneyOnly() throws {
        let resolved = PruningActivityLabourCosting.resolve(
            task: nil,
            activityLines: Self.twoLines(),
            taskLines: [],
            legacyHours: nil,
            legacyRate: nil,
            includeCost: false
        )
        #expect(resolved.cost == nil)
        #expect(Self.close(resolved.hours, Self.expectedTwoLineHours))
    }

    // MARK: - 8. OFFLINE REPLAY — idempotent

    @Test("Replaying the same desired-state payload three times changes nothing")
    func offlineReplayIsIdempotent() throws {
        var set = Self.applyDesiredState(Self.twoLines(), into: [])
        for _ in 0..<3 {
            set = Self.applyDesiredState(Self.twoLines(), into: set)
        }
        // The client ids are the idempotency keys, so a replay upserts.
        #expect(set.count == 2)
        #expect(Self.close(PruningActivityLabourCosting.totalHours(set), Self.expectedTwoLineHours))
        #expect(Self.close(PruningActivityLabourCosting.totalCost(set), Self.expectedTwoLineCost))
    }

    @Test("A re-sent removed line is restored, not duplicated")
    func replayRestoresWithoutDuplicating() throws {
        var set = Self.applyDesiredState(Self.twoLines(), into: [])
        set = Self.applyDesiredState([], into: set)
        #expect(set.isEmpty)

        // Re-sending the SAME client id restores exactly one row.
        set = Self.applyDesiredState(Self.oneLine(), into: set)
        #expect(set.count == 1)
        #expect(set.filter { $0.id == Self.lineOneId }.count == 1)
        #expect(Self.close(PruningActivityLabourCosting.totalCost(set), Self.expectedOneLineCost))
    }

    // MARK: - 9. CROSS-VINEYARD / CROSS-ACTIVITY ISOLATION

    @Test("Another activity's labour never leaks into this activity's totals")
    func crossActivityIsolation() throws {
        let foreign = Self.line(
            activity: Self.otherActivityId,
            vineyard: Self.otherVineyardId,
            workerCount: 5,
            hoursPerWorker: 10,
            hourlyRate: 99
        )
        let mixed = Self.twoLines() + [foreign]

        let scoped = PruningActivityLabourCosting.lines(mixed, for: Self.activityId)
        #expect(scoped.count == 2)
        #expect(Self.close(PruningActivityLabourCosting.totalHours(scoped), Self.expectedTwoLineHours))
        #expect(Self.close(PruningActivityLabourCosting.totalCost(scoped), Self.expectedTwoLineCost))

        // The other activity keeps its own figure: 5 × 10 × $99 = $4,950.
        let otherScoped = PruningActivityLabourCosting.lines(mixed, for: Self.otherActivityId)
        #expect(Self.close(PruningActivityLabourCosting.totalCost(otherScoped), 4950))
    }

    @Test("A work task only reads through to the activities actually linked to it")
    func workTaskReadThroughIsScoped() throws {
        let linked = Self.multiBlockDraft(workTaskId: Self.hourlyTaskId)
        let unlinked = PruningActivityDraft(
            id: Self.otherActivityId,
            vineyardId: Self.otherVineyardId,
            date: Self.date(2026, 8, 3)
        )
        let lines = Self.oneLine() + [
            Self.line(
                activity: Self.otherActivityId,
                vineyard: Self.otherVineyardId,
                workerCount: 5,
                hoursPerWorker: 10,
                hourlyRate: 99
            )
        ]
        let cost = PruningActivityLabourCosting.pruningLineCost(
            forWorkTask: Self.hourlyTaskId,
            activities: [linked, unlinked],
            activityLines: lines
        )
        // Only the LINKED activity's $480 — the unlinked $4,950 is excluded.
        #expect(Self.close(cost, Self.expectedOneLineCost))

        // A task nothing links to reads through to nothing at all.
        #expect(PruningActivityLabourCosting.pruningLineCost(
            forWorkTask: Self.pieceTaskId,
            activities: [linked, unlinked],
            activityLines: lines
        ) == nil)
    }

    @Test("A reversed activity's labour is never read through to its work task")
    func reversedActivityIsExcluded() throws {
        var reversed = Self.multiBlockDraft(workTaskId: Self.hourlyTaskId)
        reversed.reversedAt = Self.date(2026, 8, 4)
        #expect(PruningActivityLabourCosting.pruningLineCost(
            forWorkTask: Self.hourlyTaskId,
            activities: [reversed],
            activityLines: Self.oneLine()
        ) == nil)
    }
}
