import Foundation
import Testing
@testable import VineTrack

/// WORK TASK LABOUR LINES are the authoritative source of labour cost — the iOS
/// twin of `WorkTaskLabourCostingTest.kt`. Both suites assert the SAME fixtures,
/// so a divergence between the platforms fails a build.
///
/// The ownership rule under test:
/// * a Work Task labour line owns labour type, hourly rate, number of people,
///   hours per person, person-hours and labour cost;
/// * a Pruning Activity owns operational output only, and no longer has an
///   editable standalone hourly rate;
/// * a historical activity rate stays READABLE but is never combined with
///   labour-line totals.
struct WorkTaskLabourCostingTests {

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let cabFranc = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let sauvBlanc = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let activityId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let taskId = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let otherTaskId = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 9) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
    }

    /// Deterministic, hex-valid line ids so a fixture is stable across runs.
    private func lineId(_ id: String) -> UUID {
        let digits = id.filter(\.isHexDigit)
        let suffix = digits.isEmpty ? "0" : digits
        let padded = String(repeating: "0", count: max(0, 12 - suffix.count)) + suffix.suffix(12)
        return UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-\(padded)") ?? UUID()
    }

    private func line(
        _ id: String,
        workTaskId: UUID? = nil,
        workerType: String = "Pruning crew",
        workerCount: Int = 1,
        hoursPerWorker: Double = 1,
        hourlyRate: Double? = nil,
        workDate: Date? = nil
    ) -> WorkTaskLabourLine {
        WorkTaskLabourLine(
            id: lineId(id),
            workTaskId: workTaskId ?? taskId,
            vineyardId: vineyard,
            workDate: workDate ?? day(2026, 8, 4),
            operatorCategoryId: nil,
            workerType: workerType,
            workerCount: workerCount,
            hoursPerWorker: hoursPerWorker,
            hourlyRate: hourlyRate,
            notes: ""
        )
    }

    private func rows(_ numbers: [Int]) -> [PruningSegment] {
        numbers.flatMap { row in (1...4).map { PruningSegment(row: row, quarter: $0) } }
    }

    /// Two-block activity: Cab Franc rows 42–44, Sauv Blanc rows 66–67.
    private func twoBlockDraft() -> PruningActivityDraft {
        var draft = PruningActivityDraft(id: activityId, vineyardId: vineyard, date: day(2026, 8, 4))
        draft = PruningAllocationEditor.setSegments(
            draft,
            paddockId: cabFranc,
            segments: rows([42, 43, 44]),
            blockName: "Cab Franc"
        )
        draft = PruningAllocationEditor.setSegments(
            draft,
            paddockId: sauvBlanc,
            segments: rows([66, 67]),
            blockName: "Sauv Blanc"
        )
        return draft
    }

    // MARK: 1 — the canonical arithmetic

    /// 3 people × 6 hours × $35 = 18 person-hours and $630.
    @Test
    func threePeopleSixHoursAtThirtyFive() {
        #expect(WorkTaskLabourCosting.personHours(workerCount: 3, hoursPerWorker: 6) == 18)
        #expect(WorkTaskLabourCosting.lineCost(workerCount: 3, hoursPerWorker: 6, hourlyRate: 35) == 630)

        let stored = line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35)
        #expect(WorkTaskLabourCosting.personHours(stored) == 18)
        #expect(WorkTaskLabourCosting.lineCost(stored) == 630)
    }

    /// An already-aggregated elapsed duration is never multiplied by the crew.
    @Test
    func personHoursAreNeverDerivedFromElapsedDuration() {
        var draft = twoBlockDraft()
        draft.startTime = day(2026, 8, 4, hour: 8)
        draft.finishTime = Self.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 4, hour: 15, minute: 30)
        )!
        let elapsed = draft.durationHours
        #expect(elapsed != nil)
        #expect(abs((elapsed ?? 0) - 7.5) < 0.0001)
        // Person-hours come from the labour line, NOT elapsed × people.
        #expect(WorkTaskLabourCosting.personHours(workerCount: 3, hoursPerWorker: 6) == 18)
        #expect((elapsed ?? 0) * 3 != 18)
    }

    // MARK: 2 — multiple labour lines sum correctly

    @Test
    func multipleLabourLinesSumPersonHoursAndCost() {
        let lines = [
            line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35),   // 18 h, 630
            line("l2", workerCount: 2, hoursPerWorker: 4, hourlyRate: 42),   // 8 h, 336
            line("l3", workerCount: 1, hoursPerWorker: 7.5, hourlyRate: 30)  // 7.5 h, 225
        ]
        let totals = WorkTaskLabourCosting.totals(lines)
        #expect(totals.lineCount == 3)
        #expect(totals.workers == 6)
        #expect(abs(totals.personHours - 33.5) < 0.0001)
        #expect(abs((totals.cost ?? 0) - 1191) < 0.0001)
    }

    @Test
    func linesWithoutARateContributeHoursButNotCost() {
        let lines = [
            line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35),
            line("l2", workerType: "Contractor", workerCount: 4, hoursPerWorker: 5, hourlyRate: nil)
        ]
        let totals = WorkTaskLabourCosting.totals(lines)
        #expect(abs(totals.personHours - 38) < 0.0001)
        #expect(abs((totals.cost ?? 0) - 630) < 0.0001)
        // An unpriced line reports "not specified", never 0.
        #expect(WorkTaskLabourCosting.lineCost(lines[1]) == nil)
        #expect(WorkTaskLabourCosting.totalCost([lines[1]]) == nil)
    }

    // MARK: 3 — recalculation on edit

    @Test
    func editingTheWorkerCountRecalculates() {
        #expect(WorkTaskLabourCosting.lineCost(workerCount: 3, hoursPerWorker: 6, hourlyRate: 35) == 630)
        #expect(WorkTaskLabourCosting.personHours(workerCount: 5, hoursPerWorker: 6) == 30)
        #expect(WorkTaskLabourCosting.lineCost(workerCount: 5, hoursPerWorker: 6, hourlyRate: 35) == 1050)
    }

    @Test
    func editingHoursPerPersonRecalculates() {
        #expect(WorkTaskLabourCosting.personHours(workerCount: 3, hoursPerWorker: 6) == 18)
        #expect(abs(WorkTaskLabourCosting.personHours(workerCount: 3, hoursPerWorker: 7.5) - 22.5) < 0.0001)
        let cost = WorkTaskLabourCosting.lineCost(workerCount: 3, hoursPerWorker: 7.5, hourlyRate: 35)
        #expect(abs((cost ?? 0) - 787.5) < 0.0001)
    }

    // MARK: 4 — the labour type supplies its saved rate

    @Test
    func selectingALabourTypeSuppliesItsSavedRate() {
        let category = OperatorCategory(vineyardId: vineyard, name: "Pruning crew", costPerHour: 35)
        #expect(WorkTaskLabourCosting.defaultRate(category) == 35)
        // A type with no saved rate offers no default rather than 0.
        #expect(WorkTaskLabourCosting.defaultRate(OperatorCategory(vineyardId: vineyard, name: "Unpriced")) == nil)
        #expect(WorkTaskLabourCosting.defaultRate(nil) == nil)
    }

    // MARK: 5 — validation

    @Test
    func validationRequiresTypePositivePeopleAndPositiveHours() {
        #expect(WorkTaskLabourCosting.isValid(
            labourType: "Pruning crew", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35
        ))

        let noType = WorkTaskLabourCosting.validate(
            labourType: "   ", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35
        )
        #expect(WorkTaskLabourCosting.message(noType, for: .labourType) == "Choose a labour type.")

        let zeroPeople = WorkTaskLabourCosting.validate(
            labourType: "Crew", workerCount: 0, hoursPerWorker: 6, hourlyRate: 35
        )
        #expect(WorkTaskLabourCosting.message(zeroPeople, for: .workerCount) != nil)

        let zeroHours = WorkTaskLabourCosting.validate(
            labourType: "Crew", workerCount: 3, hoursPerWorker: 0, hourlyRate: 35
        )
        #expect(WorkTaskLabourCosting.message(zeroHours, for: .hoursPerWorker) != nil)

        // A zero rate is legitimate (unpaid / owner labour); negative is not.
        #expect(WorkTaskLabourCosting.isValid(
            labourType: "Crew", workerCount: 3, hoursPerWorker: 6, hourlyRate: 0
        ))
        let negative = WorkTaskLabourCosting.validate(
            labourType: "Crew", workerCount: 3, hoursPerWorker: 6, hourlyRate: -1
        )
        #expect(WorkTaskLabourCosting.message(negative, for: .hourlyRate) != nil)
    }

    @Test
    func validationRejectsNonFiniteAndOutOfBoundsValues() {
        #expect(!WorkTaskLabourCosting.isValid(
            labourType: "Crew", workerCount: 3, hoursPerWorker: .nan, hourlyRate: 35
        ))
        #expect(!WorkTaskLabourCosting.isValid(
            labourType: "Crew", workerCount: 3, hoursPerWorker: .infinity, hourlyRate: 35
        ))
        #expect(!WorkTaskLabourCosting.isValid(
            labourType: "Crew", workerCount: 3, hoursPerWorker: 6, hourlyRate: .nan, rateProvided: true
        ))
        #expect(!WorkTaskLabourCosting.isValid(
            labourType: "Crew",
            workerCount: WorkTaskLabourCosting.maxWorkerCount + 1,
            hoursPerWorker: 6,
            hourlyRate: 35
        ))
        #expect(!WorkTaskLabourCosting.isValid(
            labourType: "Crew",
            workerCount: 3,
            hoursPerWorker: WorkTaskLabourCosting.maxHoursPerWorker + 1,
            hourlyRate: 35
        ))
        #expect(!WorkTaskLabourCosting.isValid(
            labourType: "Crew",
            workerCount: 3,
            hoursPerWorker: 6,
            hourlyRate: WorkTaskLabourCosting.maxHourlyRate + 1
        ))
        // Every problem is reported, so each field can be marked inline.
        let allBad = WorkTaskLabourCosting.validate(
            labourType: "", workerCount: 0, hoursPerWorker: 0, hourlyRate: -5
        )
        #expect(allBad.count == 4)
        #expect(Set(allBad.map(\.field)) == Set([.labourType, .workerCount, .hoursPerWorker, .hourlyRate]))
        // A blank rate field is simply "not specified" — not a validation error.
        #expect(WorkTaskLabourCosting.isValid(
            labourType: "Crew", workerCount: 3, hoursPerWorker: 6, hourlyRate: nil, rateProvided: false
        ))
    }

    // MARK: 6 — linking an existing task never overwrites its labour lines

    @Test
    func linkingAnExistingTaskKeepsItsLabourLinesUntouched() {
        let existing = [
            line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35),
            line("l2", workerCount: 2, hoursPerWorker: 4, hourlyRate: 42)
        ]
        let linked = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)

        let after = WorkTaskLabourCosting.lines(existing, for: taskId)
        #expect(after == existing)
        #expect(after.count == 2)
        #expect(abs(WorkTaskLabourCosting.totalPersonHours(after) - 26) < 0.0001)
        #expect(abs((WorkTaskLabourCosting.totalCost(after) ?? 0) - 966) < 0.0001)
        #expect(linked.workTaskId == taskId)
    }

    @Test
    func labourLinesOfAnotherTaskAreNeverAttributedHere() {
        let lines = [
            line("l1", workTaskId: taskId, workerCount: 3, hoursPerWorker: 6, hourlyRate: 35),
            line("l2", workTaskId: otherTaskId, workerCount: 9, hoursPerWorker: 9, hourlyRate: 99)
        ]
        let mine = WorkTaskLabourCosting.lines(lines, for: taskId)
        #expect(mine.count == 1)
        #expect(abs(WorkTaskLabourCosting.totalPersonHours(mine) - 18) < 0.0001)
        #expect(abs((WorkTaskLabourCosting.totalCost(mine) ?? 0) - 630) < 0.0001)
    }

    // MARK: 7 — creating a linked task carries task, blocks and duration

    @Test
    func creatingALinkedTaskCarriesEveryBlockAndTheSharedDurationOnce() {
        var draft = twoBlockDraft()
        draft.labourHours = 7.5
        let taskDraft = PruningWorkTaskLink.createDraft(draft)
        #expect(taskDraft.trimmedType == "Pruning")
        #expect(taskDraft.trimmedNotes.contains("Cab Franc"))
        #expect(taskDraft.trimmedNotes.contains("Sauv Blanc"))
        // Both blocks are attached to the ONE task.
        let paddockIds = Set(PruningWorkTaskLink.paddockIds(draft))
        #expect(paddockIds == Set([cabFranc, sauvBlanc]))
        // The shared duration is carried once, never apportioned per block.
        #expect(abs(PruningWorkTaskLink.durationHours(draft) - 7.5) < 0.0001)
    }

    // MARK: 8 — unlinking preserves the task and its labour lines

    @Test
    func unlinkingClearsOnlyTheLinkAndPreservesLabourLines() {
        let lines = [line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35)]
        let linked = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)
        let unlinked = PruningWorkTaskLink.unlink(linked)

        #expect(unlinked.workTaskId == nil)
        // The lines are untouched by unlinking — the task keeps its labour.
        #expect(WorkTaskLabourCosting.lines(lines, for: taskId).count == 1)
        #expect(abs((WorkTaskLabourCosting.totalCost(lines) ?? 0) - 630) < 0.0001)
        // And so is every allocation.
        #expect(linked.allocations == unlinked.allocations)
    }

    // MARK: 9 — allocations are byte-for-byte unchanged through the whole flow

    @Test
    func allocationsUnchangedThroughCreateLinkEditAndUnlink() {
        let base = twoBlockDraft()
        let original = base.allocations

        let created = PruningWorkTaskLink.link(base, taskId: taskId)
        #expect(created.allocations == original)

        let relinked = PruningWorkTaskLink.link(created, taskId: otherTaskId)
        #expect(relinked.allocations == original)

        // Editing ONLY labour-adjacent parent fields cannot disturb allocations.
        var edited = relinked
        edited.worker = "Jon"
        edited.notes = "Finished Cab Franc"
        #expect(edited.allocations == original)

        let unlinked = PruningWorkTaskLink.unlink(edited)
        #expect(unlinked.allocations == original)

        #expect(unlinked.allocations[cabFranc]?.quarters == 12)
        #expect(unlinked.allocations[sauvBlanc]?.quarters == 8)
        #expect(unlinked.totalQuarters == 20)
    }

    // MARK: 10 — offline dependency order: task -> blocks -> labour -> activity

    @Test
    func activityWaitsForTheTaskItsBlockLinksAndItsLabourLines() {
        // The dependency is injected as a predicate: true while ANY link in the
        // chain (task header, its block associations, its labour lines) is still
        // local. The activity is held back with its `work_task_id` intact.
        var headerPending: Set<UUID> = [taskId]
        var blockLinksPending: Set<UUID> = []
        var labourPending: Set<UUID> = []
        let chain: (UUID) -> Bool = { id in
            headerPending.contains(id) || blockLinksPending.contains(id) || labourPending.contains(id)
        }

        // 1. Task header still local -> waits.
        #expect(PruningWorkTaskLink.isWaitingForTask(taskId, isTaskPending: chain))

        // 2. Header acknowledged, block association still queued -> still waits.
        headerPending.removeAll()
        blockLinksPending.insert(taskId)
        #expect(PruningWorkTaskLink.isWaitingForTask(taskId, isTaskPending: chain))

        // 3. Blocks acknowledged, a labour line still queued -> still waits.
        blockLinksPending.removeAll()
        labourPending.insert(taskId)
        #expect(PruningWorkTaskLink.isWaitingForTask(taskId, isTaskPending: chain))

        // 4. Whole chain resolved -> the activity may push.
        labourPending.removeAll()
        #expect(!PruningWorkTaskLink.isWaitingForTask(taskId, isTaskPending: chain))

        // 5. Another task's dependency never holds this activity back.
        labourPending.insert(otherTaskId)
        #expect(!PruningWorkTaskLink.isWaitingForTask(taskId, isTaskPending: chain))

        // 6. An activity with NO task never waits.
        #expect(!PruningWorkTaskLink.isWaitingForTask(nil, isTaskPending: chain))
    }

    /// The waiting activity never has its link stripped to force the upload.
    @Test
    func aWaitingActivityKeepsItsWorkTaskId() {
        let linked = PruningWorkTaskLink.link(twoBlockDraft(), taskId: taskId)
        #expect(linked.workTaskId == taskId)
        #expect(!PruningWorkTaskLink.waitingReason.isEmpty)
    }

    // MARK: 11 — retry never duplicates a labour line

    @Test
    func aRetriedLabourLineUpsertIsIdempotentOnItsStableId() {
        // The same client-minted id is replayed; the store de-duplicates by id.
        let first = line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35)
        var replay = first
        replay.notes = "replayed"
        var merged: [UUID: WorkTaskLabourLine] = [:]
        for item in [first, replay] { merged[item.id] = item }

        #expect(merged.count == 1)
        let totals = WorkTaskLabourCosting.totals(Array(merged.values))
        #expect(abs(totals.personHours - 18) < 0.0001)
        #expect(abs((totals.cost ?? 0) - 630) < 0.0001)
    }

    // MARK: 12 — legacy fallback, used ONLY when no labour lines exist

    @Test
    func labourLinesWinOverTheLegacyActivityRate() {
        let lines = [line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35)]
        let resolved = WorkTaskLabourCosting.resolveLabour(lines: lines, legacyHours: 7.5, legacyRate: 99)
        #expect(resolved.source == .workTaskLines)
        #expect(abs((resolved.hours ?? 0) - 18) < 0.0001)
        #expect(abs((resolved.cost ?? 0) - 630) < 0.0001)
        #expect(!resolved.isLegacy)
        // 630 only — never 630 + (7.5 × 99).
        #expect(resolved.cost != 630 + 7.5 * 99)
    }

    @Test
    func theLegacyRateIsUsedOnlyWhenTheTaskHasNoLabourLines() {
        let resolved = WorkTaskLabourCosting.resolveLabour(lines: [], legacyHours: 7.5, legacyRate: 40)
        #expect(resolved.source == .legacyActivity)
        #expect(abs((resolved.hours ?? 0) - 7.5) < 0.0001)
        #expect(abs((resolved.cost ?? 0) - 300) < 0.0001)
        #expect(resolved.isLegacy)
    }

    @Test
    func nothingRecordedResolvesToNoLabourAtAll() {
        let resolved = WorkTaskLabourCosting.resolveLabour(lines: [], legacyHours: nil, legacyRate: nil)
        #expect(resolved.source == .none)
        #expect(resolved.hours == nil)
        #expect(resolved.cost == nil)
    }

    // MARK: 13 — reports never double-count

    @Test
    func reportRowsUseTaskLabourWithoutDoubleCounting() {
        let lines = [
            line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35),
            line("l2", workerCount: 2, hoursPerWorker: 4, hourlyRate: 42)
        ]
        let costs = WorkTaskLabourCosting.costsByWorkTask(lines)
        let hours = WorkTaskLabourCosting.hoursByWorkTask(lines)
        #expect(abs((costs[taskId] ?? 0) - 966) < 0.0001)
        #expect(abs((hours[taskId] ?? 0) - 26) < 0.0001)

        // A record whose task HAS lines reports the task's figures, not its own.
        let linked = PruningEntry(
            vineyardId: vineyard,
            paddockId: cabFranc,
            date: day(2026, 8, 4),
            segments: rows([42]),
            worker: "Jon",
            labourHours: 7.5,
            workTaskId: taskId
        )
        // A legacy record with no linked task keeps its own hours.
        let legacy = PruningEntry(
            vineyardId: vineyard,
            paddockId: cabFranc,
            date: day(2026, 8, 4),
            segments: rows([43]),
            worker: "Jon",
            labourHours: 5,
            workTaskId: nil
        )

        let reportRows = PruningActivityReport.rows(
            entries: [linked, legacy],
            blocks: [cabFranc: PruningActivityBlockContext(name: "Cab Franc", variety: "Cabernet Franc", rows: [])],
            workTaskTitles: [:],
            labourCosts: costs,
            labourHours: hours,
            accountNames: [:],
            calendar: Self.calendar
        )
        #expect(abs((reportRows[0].labourHours ?? 0) - 26) < 0.0001)
        #expect(abs((reportRows[0].labourCost ?? 0) - 966) < 0.0001)
        #expect(abs((reportRows[1].labourHours ?? 0) - 5) < 0.0001)
        #expect(reportRows[1].labourCost == nil)

        // The report total counts the task's labour ONCE.
        let summary = PruningActivityReport.summary(reportRows, includeCost: true)
        #expect(abs(summary.labourHours - 31) < 0.0001)
        #expect(abs((summary.labourCost ?? 0) - 966) < 0.0001)
    }

    // MARK: 14 — costing permission

    @Test
    func costIsHiddenFromRolesWithoutCostingVisibility() {
        let lines = [line("l1", workerCount: 3, hoursPerWorker: 6, hourlyRate: 35)]

        let allowed = WorkTaskLabourCosting.resolveLabour(
            lines: lines, legacyHours: nil, legacyRate: nil, includeCost: true
        )
        #expect(abs((allowed.cost ?? 0) - 630) < 0.0001)

        let denied = WorkTaskLabourCosting.resolveLabour(
            lines: lines, legacyHours: nil, legacyRate: nil, includeCost: false
        )
        #expect(denied.cost == nil)
        // Hours stay visible — only money is withheld.
        #expect(abs((denied.hours ?? 0) - 18) < 0.0001)

        #expect(WorkTaskLabourCosting.costsByWorkTask(lines, includeCost: false).isEmpty)
        // Legacy rows are equally protected.
        let legacyDenied = WorkTaskLabourCosting.resolveLabour(
            lines: [], legacyHours: 7.5, legacyRate: 40, includeCost: false
        )
        #expect(legacyDenied.cost == nil)
        #expect(abs((legacyDenied.hours ?? 0) - 7.5) < 0.0001)
    }

    // MARK: 15 — cross-platform parity fixtures

    /// The exact fixtures `WorkTaskLabourCostingTest.kt` asserts. Both suites
    /// must agree to the cent, so a platform drift fails a build.
    @Test
    func crossPlatformParityFixtures() {
        let fixtures: [(people: Int, hoursEach: Double, rate: Double, personHours: Double, cost: Double)] = [
            (3, 6, 35, 18, 630),
            (1, 7.5, 42.5, 7.5, 318.75),
            (12, 0.25, 30, 3, 90),
            (4, 8, 0, 32, 0),
            (2, 3.33, 27.5, 6.66, 183.15)
        ]
        for fixture in fixtures {
            let personHours = WorkTaskLabourCosting.personHours(
                workerCount: fixture.people,
                hoursPerWorker: fixture.hoursEach
            )
            let cost = WorkTaskLabourCosting.lineCost(
                workerCount: fixture.people,
                hoursPerWorker: fixture.hoursEach,
                hourlyRate: fixture.rate
            )
            #expect(abs(personHours - fixture.personHours) < 0.0001)
            #expect(abs((cost ?? 0) - fixture.cost) < 0.0001)
        }
    }
}
