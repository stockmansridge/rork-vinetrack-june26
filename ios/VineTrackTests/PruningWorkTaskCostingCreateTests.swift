import Foundation
import Testing
@testable import VineTrack

/// CREATING A PRUNING WORK TASK **WITH ITS COSTING** (sql/188) — the iOS twin of
/// `PruningWorkTaskCostingCreateTest.kt`. Both suites assert the SAME fixtures,
/// so any divergence between the platforms fails a build.
///
/// The regression these tests lock down: "Create Work Task" in the pruning
/// activity editor opened a generic sheet with only a title, notes and a
/// completed toggle. It had no costing method, no hourly inputs and no piece
/// rate, so the operator created an incomplete task and had to go and price it
/// somewhere else.
///
/// The fixture is the one from the field report:
/// ```text
/// Merlot · rows 45–46 · 8 quarters · 499 vines
/// 499 × $1.27 = $633.73
/// ```
struct PruningWorkTaskCostingCreateTests {

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let merlot = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let activityId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let taskId = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let row45 = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let row46 = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 9))!
    }

    /// Merlot's two rows. Different vine counts on purpose, so a quarter
    /// selection cannot be faked by averaging.
    private var merlotRows: [PruningRowRef] {
        [
            PruningRowRef(rowId: row45, number: 45, label: "45", lengthMetres: 500, vines: 250, isFallback: false),
            PruningRowRef(rowId: row46, number: 46, label: "46", lengthMetres: 498, vines: 249, isFallback: false)
        ]
    }

    private func segment(_ rowId: UUID, _ number: Int, _ quarter: Int) -> PruningSegment {
        PruningSegment(rowId: rowId, row: number, quarter: quarter)
    }

    /// Every quarter of rows 45 and 46 — the screenshot's 8 quarters / 499 vines.
    private var wholeRowSegments: [PruningSegment] {
        (1...4).map { segment(row45, 45, $0) } + (1...4).map { segment(row46, 46, $0) }
    }

    /// A PARTIAL selection: half of row 45, three quarters of row 46.
    private var partialSegments: [PruningSegment] {
        (1...2).map { segment(row45, 45, $0) } + (1...3).map { segment(row46, 46, $0) }
    }

    /// The activity exactly as the editor builds it: segments chosen, then the
    /// vine estimate re-derived from THOSE segments.
    private func activity(segments: [PruningSegment], labourHours: Double? = nil) -> PruningActivityDraft {
        var draft = PruningActivityDraft(
            id: activityId,
            vineyardId: vineyard,
            date: day(2026, 8, 13),
            worker: "Crew",
            method: .spur,
            labourHours: labourHours
        )
        draft = PruningAllocationEditor.setSegments(
            draft, paddockId: merlot, segments: segments, blockName: "Merlot"
        )
        draft = PruningAllocationEditor.setEstimatedVines(
            draft,
            paddockId: merlot,
            vines: PruningCalculator.vines(for: segments, rows: merlotRows)
        )
        return draft
    }

    // MARK: - The activity's own quantity feeds the costing

    @Test func theActivitySummaryQuantityIsExactlyWhatPieceRateCosts() {
        let draft = activity(segments: wholeRowSegments)

        // The number the Activity Summary shows…
        #expect(draft.totalQuarters == 8)
        #expect(draft.totalEstimatedVines == 499)
        // …is the number the create sheet prices, with nothing re-entered.
        #expect(PruningWorkTaskLink.vineCount(draft) == 499)
        #expect(PruningWorkTaskLink.createDraft(draft).vineCount == 499)
    }

    @Test func creatingFromAPruningActivityDefaultsToHourly() {
        let create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments))

        #expect(create.costingMethod == .hourly)
        #expect(create.isPieceRate == false)
        // Existing behaviour is untouched: a task with no costing entered is
        // still creatable, exactly as it always was.
        #expect(create.isValid)
        #expect(create.trimmedType == "Pruning")
        #expect(create.markCompleted)
    }

    @Test func theActivityHoursSeedTheHourlyForm() {
        let create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments, labourHours: 8))

        #expect(create.hoursPerWorker == 8)
        #expect(create.workerCount == 1)
        // No hours recorded on the activity leaves the field empty rather than
        // inventing a zero.
        #expect(PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments)).hoursPerWorker == nil)
    }

    // MARK: - Piece rate arithmetic

    @Test func pieceRateCostIsQuantityTimesRate() {
        var create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments))
        create.costingMethod = .pieceRate
        create.ratePerVine = 1.27

        // 499 × $1.27 = $633.73 — the exact figure the sheet previews.
        #expect(create.estimatedCost == 633.73)
        #expect(create.isValid)
        #expect(PieceRateCosting.currencyLabel(create.estimatedCost ?? 0) == "$633.73")
    }

    @Test func aPieceRateJobCannotBeCreatedWithoutACompleteAgreement() {
        var create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments))
        create.costingMethod = .pieceRate

        // No rate agreed yet — the cost has no other source, so Create is refused.
        #expect(create.isValid == false)
        #expect(create.estimatedCost == nil)

        create.ratePerVine = 0
        #expect(create.isValid == false)

        create.ratePerVine = 1.27
        #expect(create.isValid)

        // A quantity of zero means no rows were selected — never priced as $0.
        create.vineCount = 0
        #expect(create.isValid == false)
    }

    @Test func anHourlyJobCanBeCreatedBeforeTheCrewsHoursAreKnown() {
        var create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments))
        create.hoursPerWorker = nil

        // Hourly labour is optional at creation: the task is real, its labour
        // lines land later. This is the pre-existing behaviour.
        #expect(create.isValid)
        #expect(create.recordsHourlyLabour == false)
        #expect(create.estimatedCost == nil)
    }

    @Test func hourlyCostUsesTheStandardLabourArithmetic() {
        var create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments))
        create.workerCount = 1
        create.hoursPerWorker = 8
        create.hourlyRate = 32.50

        // 1 person × 8 h × $32.50 = $260.00, straight through
        // WorkTaskLabourCosting — never a second hourly calculation.
        #expect(create.personHours == 8)
        #expect(create.estimatedCost == 260)
        #expect(create.recordsHourlyLabour)
    }

    @Test func theTwoCostingBasesAreNeverSummed() {
        var create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments))
        create.workerCount = 3
        create.hoursPerWorker = 8
        create.hourlyRate = 32.50
        create.ratePerVine = 1.27

        // Hourly selected: the piece rate sitting in the draft contributes nothing.
        #expect(create.estimatedCost == 780)

        // Piece rate selected: the hours are kept as operational history, and
        // the cost is the agreement alone — not $780 + $633.73.
        create.costingMethod = .pieceRate
        #expect(create.estimatedCost == 633.73)
        #expect(create.personHours == 24)
    }

    // MARK: - Quarter-row handling

    @Test func quarterSelectionsPriceQuartersNotWholeRows() {
        let draft = activity(segments: partialSegments)

        // 250 × 2/4 + 249 × 3/4 = 125 + 186.75 = 311.75 → 312 vines.
        // Emphatically NOT the 499 vines of two whole rows.
        #expect(draft.totalQuarters == 5)
        #expect(draft.totalEstimatedVines == 312)

        var create = PruningWorkTaskLink.createDraft(draft)
        create.costingMethod = .pieceRate
        create.ratePerVine = 1.27
        #expect(create.vineCount == 312)
        #expect(create.estimatedCost == 396.24)
    }

    @Test func theSnapshotBreaksTheQuantityDownByRow() {
        let draft = activity(segments: partialSegments)
        let snapshot = PruningWorkTaskLink.pieceRateRows(
            activity: draft,
            workTaskId: taskId,
            vineyardId: vineyard,
            rowsByPaddock: [merlot: merlotRows]
        )

        #expect(snapshot.count == 2)
        #expect(snapshot.map(\.rowNumber) == [45, 46])
        // Each row is snapshotted at ITS OWN quarter share.
        #expect(snapshot.map(\.vineCount) == [125, 187])
        #expect(snapshot.allSatisfy { $0.workTaskId == taskId })
        #expect(snapshot.allSatisfy { $0.paddockId == merlot })
        #expect(snapshot.map(\.paddockRowId) == [row45, row46])
    }

    @Test func wholeRowSelectionsSnapshotEveryVineOfEachRow() {
        let snapshot = PruningWorkTaskLink.pieceRateRows(
            activity: activity(segments: wholeRowSegments),
            workTaskId: taskId,
            vineyardId: vineyard,
            rowsByPaddock: [merlot: merlotRows]
        )

        #expect(snapshot.map(\.vineCount) == [250, 249])
        // The breakdown reconciles to the priced quantity.
        #expect(snapshot.reduce(0) { $0 + $1.vineCount } == 499)
    }

    @Test func rowsWithNoSelectedQuartersAreNeverSnapshotted() {
        let onlyRow46 = (1...4).map { segment(row46, 46, $0) }
        let snapshot = PruningWorkTaskLink.pieceRateRows(
            activity: activity(segments: onlyRow46),
            workTaskId: taskId,
            vineyardId: vineyard,
            rowsByPaddock: [merlot: merlotRows]
        )

        #expect(snapshot.map(\.rowNumber) == [46])
        #expect(snapshot.map(\.vineCount) == [249])
    }

    @Test func vineRoundingIsHalfAwayFromZero() {
        // The same rule as the per-row vine-count calculation, so no platform
        // ever reports a vine another does not.
        #expect(PruningWorkTaskLink.roundVines(186.75) == 187)
        #expect(PruningWorkTaskLink.roundVines(0.5) == 1)
        #expect(PruningWorkTaskLink.roundVines(1.5) == 2)
        #expect(PruningWorkTaskLink.roundVines(2.5) == 3)
        #expect(PruningWorkTaskLink.roundVines(-2.5) == -3)
        #expect(PruningWorkTaskLink.roundVines(0) == 0)
        #expect(PruningWorkTaskLink.roundVines(Double.nan) == 0)
    }

    // MARK: - What the created task carries

    @Test func aPieceRateTaskIsBornWithItsSnapshotAndCostsFromIt() {
        var create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments))
        create.costingMethod = .pieceRate
        create.ratePerVine = 1.27

        // The task the create flow writes.
        let task = WorkTask(
            id: taskId,
            vineyardId: vineyard,
            date: day(2026, 8, 13),
            taskType: create.trimmedType,
            costingMethodRaw: create.costingMethod.rawValue,
            pieceRatePerVine: create.ratePerVine,
            pieceVineCount: create.vineCount
        )

        #expect(task.isPieceRate)
        #expect(task.pieceRateCost == 633.73)

        // Reopening it later resolves from the SNAPSHOT — hours recorded
        // afterwards never re-cost it.
        let resolved = PieceRateCosting.resolve(
            task: task,
            labourLines: [WorkTaskLabourLine(
                workTaskId: taskId,
                vineyardId: vineyard,
                workerCount: 3,
                hoursPerWorker: 8,
                hourlyRate: 32.50
            )]
        )
        #expect(resolved.method == .pieceRate)
        #expect(resolved.cost == 633.73)
        #expect(resolved.vineCount == 499)
        #expect(resolved.ratePerVine == 1.27)
        #expect(resolved.hours == 24)
        #expect(resolved.hoursAreOperationalOnly)
    }

    @Test func anHourlyTaskIsBornWithNoPieceRateColumns() {
        var create = PruningWorkTaskLink.createDraft(activity(segments: wholeRowSegments))
        create.hoursPerWorker = 8
        create.hourlyRate = 32.50

        let isPieceRate = create.isPieceRate
        let task = WorkTask(
            id: taskId,
            vineyardId: vineyard,
            date: day(2026, 8, 13),
            taskType: create.trimmedType,
            costingMethodRaw: create.costingMethod.rawValue,
            pieceRatePerVine: isPieceRate ? create.ratePerVine : nil,
            pieceVineCount: isPieceRate ? create.vineCount : nil
        )

        #expect(task.costingMethod == .hourly)
        #expect(task.pieceRatePerVine == nil)
        #expect(task.pieceVineCount == nil)
        #expect(task.pieceRateCost == nil)

        // Its cost comes from the labour line the create flow wrote alongside it.
        let resolved = PieceRateCosting.resolve(
            task: task,
            labourLines: [WorkTaskLabourLine(
                workTaskId: taskId,
                vineyardId: vineyard,
                workerCount: create.workerCount,
                hoursPerWorker: create.hoursPerWorker ?? 0,
                hourlyRate: create.hourlyRate
            )]
        )
        #expect(resolved.method == .hourly)
        #expect(resolved.cost == 260)
        #expect(resolved.hours == 8)
    }

    @Test func aFreshlyCreatedTaskResolvesImmediatelyOnThisDevice() {
        var draft = activity(segments: wholeRowSegments)
        let created = WorkTask(
            id: taskId,
            vineyardId: vineyard,
            date: day(2026, 8, 13),
            taskType: "Pruning"
        )
        draft = PruningWorkTaskLink.link(draft, taskId: created.id)

        // With the task present in the store, the editor resolves it — the
        // "hasn't reached this device yet" warning is for a link this device
        // genuinely does not have, never for one it just created.
        #expect(PruningWorkTaskLink.hasUnresolvableLink(draft, tasks: [created]) == false)
        #expect(PruningWorkTaskLink.linkedTask(draft, tasks: [created])?.id == taskId)
        // The link never disturbs the block selection it was created from.
        #expect(draft.totalQuarters == 8)
        #expect(draft.totalEstimatedVines == 499)
    }
}
