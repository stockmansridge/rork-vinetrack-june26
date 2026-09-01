import Foundation
import Testing
@testable import VineTrack

/// EFFECTIVE WORK TASK LABOUR COST (sql/188) — the iOS twin of
/// `EffectiveLabourCostTest.kt`. Both suites assert the SAME fixtures, so any
/// divergence between the platforms fails a build.
///
/// The rule under test, environment-wide:
///
/// ```text
/// effectiveTaskLabourCost(task, labourLines) =
///     costing_method == piece_rate  ->  piece vine count × piece rate per vine
///     otherwise                     ->  Σ active labour line cost
/// ```
///
/// The correction this suite locks in: a piece-rate job legitimately has NO
/// labour lines and NO hours, yet still has a real labour cost. Anywhere that
/// asks "what did this task's labour cost?" must return `$137.50` for:
///
/// ```text
/// 250 vines · $0.55 / vine · no labour lines
/// ```
///
/// and must NEVER add an hourly total to a piece-rate one.
struct EffectiveLabourCostTests {

    // MARK: - Shared fixture (identical on Android)

    private static let vineyardId = UUID(uuidString: "00000000-0000-0000-0000-0000000eff00")!
    private static let blockA = UUID(uuidString: "00000000-0000-0000-0000-0000000eff01")!
    private static let blockB = UUID(uuidString: "00000000-0000-0000-0000-0000000eff02")!
    private static let pieceTaskId = UUID(uuidString: "00000000-0000-0000-0000-0000000eff03")!
    private static let hourlyTaskId = UUID(uuidString: "00000000-0000-0000-0000-0000000eff04")!
    private static let legacyTaskId = UUID(uuidString: "00000000-0000-0000-0000-0000000eff05")!

    /// THE worked example: 250 vines at $0.55 each.
    private static let snapshotVines = 250
    private static let ratePerVine = 0.55
    private static let expectedPieceCost = 137.50

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    /// A piece-rate job with NO labour lines — the shape that used to report
    /// "No labour recorded · $0.00".
    private static func pieceRateTask() -> WorkTask {
        WorkTask(
            id: pieceTaskId,
            vineyardId: vineyardId,
            date: date(2026, 7, 6),
            taskType: "Pruning",
            paddockId: blockA,
            costingMethodRaw: "piece_rate",
            pieceRatePerVine: ratePerVine,
            pieceVineCount: snapshotVines
        )
    }

    /// The unchanged hourly shape: 2 workers × 8 h × $30 = $480.
    private static func hourlyTask() -> WorkTask {
        WorkTask(
            id: hourlyTaskId,
            vineyardId: vineyardId,
            date: date(2026, 7, 6),
            taskType: "Pruning",
            paddockId: blockA,
            costingMethodRaw: "hourly"
        )
    }

    /// A record written before sql/188 existed: no costing method at all.
    private static func legacyTask() -> WorkTask {
        WorkTask(
            id: legacyTaskId,
            vineyardId: vineyardId,
            date: date(2026, 7, 6),
            taskType: "Pruning",
            paddockId: blockA,
            costingMethodRaw: nil
        )
    }

    private static func line(
        task: UUID,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?
    ) -> WorkTaskLabourLine {
        WorkTaskLabourLine(
            workTaskId: task,
            vineyardId: vineyardId,
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate
        )
    }

    /// 2 workers × 8 h × $30 = $480.
    private static func hourlyLines(for task: UUID) -> [WorkTaskLabourLine] {
        [line(task: task, workerCount: 2, hoursPerWorker: 8, hourlyRate: 30)]
    }

    private static func close(_ lhs: Double?, _ rhs: Double?, _ tolerance: Double = 0.0001) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs - rhs) < tolerance
    }

    // MARK: - 1–2. A piece-rate job has a cost with no labour lines at all

    @Test("A piece-rate task with zero labour lines still has a valid labour cost")
    func pieceRateWithoutLabourLinesIsStillCosted() throws {
        let cost = PieceRateCosting.effectiveLabourCost(task: Self.pieceRateTask(), labourLines: [])
        // Not nil, not zero — a real, complete cost record.
        let resolved = try #require(cost)
        #expect(resolved > 0)
        #expect(Self.close(resolved, Self.expectedPieceCost))
    }

    @Test("250 vines × $0.55 = $137.50")
    func theWorkedExample() throws {
        let cost = try #require(
            PieceRateCosting.cost(vineCount: Self.snapshotVines, ratePerVine: Self.ratePerVine)
        )
        #expect(Self.close(cost, 137.50))
        #expect(PieceRateCosting.currencyLabel(cost) == "$137.50")
    }

    // MARK: - 3. Cost per vine reproduces the agreed rate

    @Test("Piece-rate cost per vine reproduces the agreed rate")
    func costPerVineReproducesTheRate() throws {
        let cost = PieceRateCosting.effectiveLabourCost(task: Self.pieceRateTask(), labourLines: [])
        let perVine = try #require(
            PieceRateCosting.costPerVine(cost: cost, vineCount: Self.snapshotVines)
        )
        #expect(Self.close(perVine, Self.ratePerVine))
        #expect(PieceRateCosting.rateLabel(perVine) == "$0.55")
    }

    // MARK: - 4. Zero hours never zeroes a piece-rate cost

    @Test("Zero hours does not produce a zero piece-rate cost")
    func zeroHoursDoesNotZeroTheCost() throws {
        let resolved = PieceRateCosting.resolve(task: Self.pieceRateTask(), labourLines: [])
        #expect(resolved.hours == 0)
        #expect(Self.close(resolved.cost, Self.expectedPieceCost))
        #expect(resolved.hoursAreOperationalOnly == false)
    }

    // MARK: - 5–6. Recorded hours are operational only, never additive

    @Test("Recorded operational hours do not change the piece-rate cost")
    func operationalHoursDoNotChangeTheCost() throws {
        // 6 person-hours recorded for productivity analysis.
        let lines = [Self.line(task: Self.pieceTaskId, workerCount: 1, hoursPerWorker: 6, hourlyRate: nil)]
        let resolved = PieceRateCosting.resolve(task: Self.pieceRateTask(), labourLines: lines)
        #expect(Self.close(resolved.hours, 6))
        #expect(Self.close(resolved.cost, Self.expectedPieceCost))
        // The hours exist and are explicitly flagged as not the cost basis.
        #expect(resolved.hoursAreOperationalOnly)
        // Vines per hour remains available for operational analysis.
        #expect(Self.close(Double(Self.snapshotVines) / resolved.hours, 41.6666, 0.001))
    }

    @Test("Rated labour lines kept for history are never added to the piece-rate total")
    func ratedHistoryLinesAreNotAddedToThePieceRateTotal() throws {
        // These lines would total $480 on their own.
        let lines = Self.hourlyLines(for: Self.pieceTaskId)
        #expect(Self.close(WorkTaskLabourCosting.totalCost(lines), 480))

        let cost = try #require(
            PieceRateCosting.effectiveLabourCost(task: Self.pieceRateTask(), labourLines: lines)
        )
        // The piece-rate total, NOT $480 and NOT $617.50.
        #expect(Self.close(cost, Self.expectedPieceCost))
        #expect(!Self.close(cost, 480))
        #expect(!Self.close(cost, Self.expectedPieceCost + 480))
    }

    // MARK: - 7–8. Hourly and legacy behaviour is untouched

    @Test("An hourly task continues to use its labour-line total")
    func hourlyIsUnchanged() throws {
        let lines = Self.hourlyLines(for: Self.hourlyTaskId)
        let cost = try #require(
            PieceRateCosting.effectiveLabourCost(task: Self.hourlyTask(), labourLines: lines)
        )
        // 2 × 8 × $30 = $480 — the pre-existing rule, byte for byte.
        #expect(Self.close(cost, 480))
        // An hourly task with no lines is "not specified", never $0.00.
        #expect(PieceRateCosting.effectiveLabourCost(task: Self.hourlyTask(), labourLines: []) == nil)
    }

    @Test("A legacy task with no costing method continues to use its labour-line total")
    func legacyIsUnchanged() throws {
        let lines = Self.hourlyLines(for: Self.legacyTaskId)
        let task = Self.legacyTask()
        #expect(task.costingMethod == .hourly)
        #expect(task.isPieceRate == false)
        let cost = try #require(PieceRateCosting.effectiveLabourCost(task: task, labourLines: lines))
        #expect(Self.close(cost, 480))
        // A legacy task is never given piece-rate figures by inference.
        #expect(task.pieceRateCost == nil)
    }

    // MARK: - 9. Work Task LIST shows a piece-rate cost

    @Test("The Work Task list cost map includes a piece-rate task that has no labour lines")
    func listMapIncludesPieceRateTasks() throws {
        let tasks = [Self.pieceRateTask(), Self.hourlyTask(), Self.legacyTask()]
        let lines = Self.hourlyLines(for: Self.hourlyTaskId) + Self.hourlyLines(for: Self.legacyTaskId)

        let costs = PieceRateCosting.effectiveCostsByWorkTask(tasks: tasks, labourLines: lines)

        // The piece-rate job appears even though it contributed no labour line.
        #expect(Self.close(costs[Self.pieceTaskId], Self.expectedPieceCost))
        #expect(Self.close(costs[Self.hourlyTaskId], 480))
        #expect(Self.close(costs[Self.legacyTaskId], 480))

        // The old labour-line-only map is exactly what was wrong: it drops the
        // piece-rate job entirely.
        let lineOnly = WorkTaskLabourCosting.costsByWorkTask(lines)
        #expect(lineOnly[Self.pieceTaskId] == nil)
    }

    @Test("Costing visibility still hides every money value")
    func costingVisibilityIsRespected() {
        let costs = PieceRateCosting.effectiveCostsByWorkTask(
            tasks: [Self.pieceRateTask()],
            labourLines: [],
            includeCost: false
        )
        #expect(costs.isEmpty)
    }

    // MARK: - 10. Work Task DETAIL shows a piece-rate cost

    @Test("Work Task detail resolves a piece-rate cost, cost per vine and operational hours")
    func detailShowsThePieceRateCost() throws {
        let task = Self.pieceRateTask()
        let lines = [Self.line(task: Self.pieceTaskId, workerCount: 2, hoursPerWorker: 3, hourlyRate: nil)]
        let resolved = PieceRateCosting.resolve(task: task, labourLines: lines)

        #expect(resolved.method == .pieceRate)
        #expect(resolved.vineCount == Self.snapshotVines)
        #expect(Self.close(resolved.ratePerVine, Self.ratePerVine))
        #expect(Self.close(resolved.cost, Self.expectedPieceCost))
        // Labour + machine roll-ups take the labour component from here, so a
        // piece-rate task never contributes zero to a task total.
        let machine = 220.0
        #expect(Self.close((resolved.cost ?? 0) + machine, 357.50))
    }

    // MARK: - 11. Pruning Tracker / activity summary

    @Test("The pruning activity summary reports the piece-rate cost, not 'No labour recorded'")
    func activitySummaryUsesThePieceRateCost() throws {
        let labour = PieceRateCosting.resolveActivityLabour(
            task: Self.pieceRateTask(),
            lines: [],
            legacyHours: nil,
            legacyRate: nil
        )
        // A dedicated source — never `.none`, which is what rendered "$0.00".
        #expect(labour.source == .pieceRate)
        #expect(labour.isLegacy == false)
        #expect(Self.close(labour.cost, Self.expectedPieceCost))
    }

    @Test("An hourly activity and a legacy activity keep their existing sources")
    func activitySummaryKeepsExistingSources() {
        let hourly = PieceRateCosting.resolveActivityLabour(
            task: Self.hourlyTask(),
            lines: Self.hourlyLines(for: Self.hourlyTaskId),
            legacyHours: nil,
            legacyRate: nil
        )
        #expect(hourly.source == .workTaskLines)
        #expect(Self.close(hourly.cost, 480))

        // No task at all: the pre-sql/188 legacy fallback is untouched.
        let legacy = PieceRateCosting.resolveActivityLabour(
            task: nil,
            lines: [],
            legacyHours: 7.5,
            legacyRate: 40
        )
        #expect(legacy.source == .legacyActivity)
        #expect(Self.close(legacy.cost, 300))
    }

    // MARK: - 12. Pruning report / summary

    @Test("A pruning report row for a piece-rate job carries its cost and cost per vine")
    func reportRowUsesTheEffectiveCost() throws {
        let task = Self.pieceRateTask()
        let entry = PruningEntry(
            vineyardId: Self.vineyardId,
            paddockId: Self.blockA,
            date: Self.date(2026, 7, 6),
            segments: [PruningSegment(row: 1, quarter: 1), PruningSegment(row: 1, quarter: 2)],
            worker: "Sam",
            labourHours: nil,
            workTaskId: Self.pieceTaskId,
            createdAt: Self.date(2026, 7, 6)
        )
        let contexts: [UUID: PruningActivityBlockContext] = [
            Self.blockA: PruningActivityBlockContext(
                name: "Block A",
                variety: "Shiraz",
                rows: [PruningRowRef(rowId: nil, number: 1, label: "1", lengthMetres: nil, vines: 100, isFallback: true)]
            )
        ]

        let rows = PruningActivityReport.rows(
            entries: [entry],
            blocks: contexts,
            workTaskTitles: [Self.pieceTaskId: "Pruning — Block A"],
            labourCosts: PieceRateCosting.effectiveCostsByWorkTask(tasks: [task], labourLines: []),
            labourHours: [:],
            pieceRateVines: PieceRateCosting.snapshotVinesByWorkTask([task]),
            accountNames: [:],
            calendar: Self.calendar
        )

        let row = try #require(rows.first)
        #expect(Self.close(row.labourCost, Self.expectedPieceCost))
        #expect(row.pieceRateVines == Self.snapshotVines)
        #expect(Self.close(row.costPerVine, Self.ratePerVine))
        // Zero hours does not blank the cost.
        #expect(row.labourHours == nil)

        // The summary carries the same money through.
        let summary = PruningActivityReport.summary(rows, includeCost: true)
        #expect(Self.close(summary.labourCost, Self.expectedPieceCost))
    }

    @Test("An hourly report row keeps its labour-line cost and reports no cost per vine")
    func hourlyReportRowIsUnchanged() throws {
        let task = Self.hourlyTask()
        let lines = Self.hourlyLines(for: Self.hourlyTaskId)
        let entry = PruningEntry(
            vineyardId: Self.vineyardId,
            paddockId: Self.blockA,
            date: Self.date(2026, 7, 6),
            segments: [PruningSegment(row: 1, quarter: 1)],
            worker: "Sam",
            labourHours: 4,
            workTaskId: Self.hourlyTaskId,
            createdAt: Self.date(2026, 7, 6)
        )
        let contexts: [UUID: PruningActivityBlockContext] = [
            Self.blockA: PruningActivityBlockContext(
                name: "Block A",
                variety: "Shiraz",
                rows: [PruningRowRef(rowId: nil, number: 1, label: "1", lengthMetres: nil, vines: 100, isFallback: true)]
            )
        ]

        let rows = PruningActivityReport.rows(
            entries: [entry],
            blocks: contexts,
            workTaskTitles: [:],
            labourCosts: PieceRateCosting.effectiveCostsByWorkTask(tasks: [task], labourLines: lines),
            labourHours: WorkTaskLabourCosting.hoursByWorkTask(lines),
            pieceRateVines: PieceRateCosting.snapshotVinesByWorkTask([task]),
            accountNames: [:],
            calendar: Self.calendar
        )

        let row = try #require(rows.first)
        #expect(Self.close(row.labourCost, 480))
        #expect(row.pieceRateVines == nil)
        #expect(row.costPerVine == nil)
        #expect(Self.close(row.labourHours, 16))
    }

    // MARK: - 13. Multi-block allocation adds back to the task total

    @Test("A multi-block piece-rate activity allocates the task total and adds back exactly")
    func multiBlockAllocationAddsBackToThePieceRateTotal() throws {
        // A $1,000.00 piece-rate job split 60/40 by row equivalents.
        let bigTask = WorkTask(
            id: Self.pieceTaskId,
            vineyardId: Self.vineyardId,
            date: Self.date(2026, 7, 6),
            taskType: "Pruning",
            costingMethodRaw: "piece_rate",
            pieceRatePerVine: 0.50,
            pieceVineCount: 2_000
        )
        #expect(Self.close(bigTask.pieceRateCost, 1_000))

        let activityKey = UUID()
        let costs = PieceRateCosting.effectiveCostsByWorkTask(tasks: [bigTask], labourLines: [])
        let contexts: [UUID: PruningActivityBlockContext] = [
            Self.blockA: PruningActivityBlockContext(
                name: "Block A",
                variety: "Shiraz",
                rows: [PruningRowRef(rowId: nil, number: 1, label: "1", lengthMetres: nil, vines: 100, isFallback: true)]
            ),
            Self.blockB: PruningActivityBlockContext(
                name: "Block B",
                variety: "Riesling",
                rows: [PruningRowRef(rowId: nil, number: 1, label: "1", lengthMetres: nil, vines: 100, isFallback: true)]
            )
        ]

        func allocation(_ paddock: UUID, index: Int, quarters: Int) -> PruningEntry {
            PruningEntry(
                vineyardId: Self.vineyardId,
                paddockId: paddock,
                date: Self.date(2026, 7, 6),
                segments: (1...quarters).map { PruningSegment(row: 1, quarter: $0) },
                worker: "Sam",
                labourHours: nil,
                workTaskId: Self.pieceTaskId,
                createdAt: Self.date(2026, 7, 6),
                pruningActivityId: activityKey,
                allocationIndex: index
            )
        }

        // 3 quarters + 2 quarters → 0.75 / 0.50 row equivalents (60% / 40%).
        let rows = PruningActivityReport.rows(
            entries: [allocation(Self.blockA, index: 0, quarters: 3), allocation(Self.blockB, index: 1, quarters: 2)],
            blocks: contexts,
            workTaskTitles: [:],
            labourCosts: costs,
            labourHours: [:],
            pieceRateVines: PieceRateCosting.snapshotVinesByWorkTask([bigTask]),
            accountNames: [:],
            calendar: Self.calendar
        )
        #expect(rows.count == 2)

        let model = PruningActivityAllocationModel.build(rows, includeCost: true)
        let parent = try #require(model.parent(activityKey))
        // The amount being allocated is the task's EFFECTIVE labour cost.
        #expect(Self.close(parent.labourCost, 1_000))

        let shares = rows.compactMap { model.share(of: $0) }
        #expect(shares.count == 2)
        let allocated = shares.compactMap(\.labourCost)
        #expect(allocated.count == 2)
        #expect(Self.close(allocated.reduce(0, +), 1_000))
        // 60 / 40 of $1,000.00, and the split never invents or loses a cent.
        #expect(Self.close(allocated.max(), 600))
        #expect(Self.close(allocated.min(), 400))
    }

    // MARK: - 14. Cost per hectare uses the effective cost

    @Test("Cost per hectare divides the effective labour cost by the area")
    func costPerHectareUsesTheEffectiveCost() throws {
        let cost = PieceRateCosting.effectiveLabourCost(task: Self.pieceRateTask(), labourLines: [])
        let perHa = try #require(PieceRateCosting.costPerHectare(effectiveCost: cost, hectares: 0.4911))
        // $137.50 / 0.4911 ha ≈ $279.98 / ha.
        #expect(Self.close(perHa, 279.98, 0.01))
        // An unknown denominator never renders as a number.
        #expect(PieceRateCosting.costPerHectare(effectiveCost: cost, hectares: 0) == nil)
        #expect(PieceRateCosting.costPerHectare(effectiveCost: cost, hectares: nil) == nil)
    }

    // MARK: - 15. Cost per vine uses the HISTORICAL snapshot

    @Test("Cost per vine uses the snapshot quantity, never today's vineyard geometry")
    func costPerVineUsesTheSnapshot() throws {
        let task = Self.pieceRateTask()
        let cost = PieceRateCosting.effectiveLabourCost(task: task, labourLines: [])

        // The block is later re-mapped and now carries 900 vines. The finished
        // job's cost per vine must not move.
        let todaysGeometry = 900
        let historical = try #require(PieceRateCosting.costPerVine(cost: cost, vineCount: task.pieceVineCount))
        let wrong = try #require(PieceRateCosting.costPerVine(cost: cost, vineCount: todaysGeometry))
        #expect(Self.close(historical, Self.ratePerVine))
        #expect(!Self.close(wrong, Self.ratePerVine))
        #expect(task.pieceVineCount == Self.snapshotVines)
    }

    // MARK: - 16. Offline / cache round trip

    @Test("An offline cache round trip preserves the effective piece-rate cost")
    func offlineRoundTripPreservesTheCost() throws {
        let original = Self.pieceRateTask()
        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(WorkTask.self, from: encoded)

        // Every field the cost depends on survives the round trip…
        #expect(restored.costingMethod == .pieceRate)
        #expect(restored.pieceVineCount == Self.snapshotVines)
        #expect(Self.close(restored.pieceRatePerVine, Self.ratePerVine))
        // …so the cost is available from the LOCAL record alone: no portal, no
        // labour line, no second fetch.
        #expect(Self.close(
            PieceRateCosting.effectiveLabourCost(task: restored, labourLines: []),
            Self.expectedPieceCost
        ))

        // The row snapshots survive too, and still reconcile to the quantity.
        let snapshot = [
            WorkTaskPieceRateRow(
                workTaskId: Self.pieceTaskId,
                vineyardId: Self.vineyardId,
                paddockId: Self.blockA,
                rowNumber: 1,
                vineCount: 125
            ),
            WorkTaskPieceRateRow(
                workTaskId: Self.pieceTaskId,
                vineyardId: Self.vineyardId,
                paddockId: Self.blockA,
                rowNumber: 2,
                vineCount: 125
            )
        ]
        let restoredRows = try JSONDecoder().decode(
            [WorkTaskPieceRateRow].self,
            from: try JSONEncoder().encode(snapshot)
        )
        #expect(PieceRateCosting.vineCount(forSelectedRows: restoredRows) == Self.snapshotVines)
    }

    // MARK: - 17. Cross-platform parity anchors

    @Test("The parity anchors both platforms must reproduce exactly")
    func crossPlatformParityAnchors() throws {
        // These five numbers are asserted identically in the Kotlin twin.
        #expect(Self.close(PieceRateCosting.cost(vineCount: 250, ratePerVine: 0.55), 137.50))
        #expect(Self.close(PieceRateCosting.costPerVine(cost: 137.50, vineCount: 250), 0.55))
        #expect(Self.close(PieceRateCosting.costPerHectare(cost: 137.50, hectares: 0.4911), 279.98, 0.01))
        #expect(Self.close(
            PieceRateCosting.effectiveLabourCost(
                task: Self.pieceRateTask(),
                labourLines: Self.hourlyLines(for: Self.pieceTaskId)
            ),
            137.50
        ))
        #expect(Self.close(
            PieceRateCosting.effectiveLabourCost(
                task: Self.hourlyTask(),
                labourLines: Self.hourlyLines(for: Self.hourlyTaskId)
            ),
            480
        ))
    }
}
