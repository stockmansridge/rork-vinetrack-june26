import Foundation
import Testing
@testable import VineTrack

/// SHARED EXPORT FIXTURE — the same cases and the same numbers exist as
/// `PruningActivityExportTest.kt` in the Android unit-test source set. Both
/// platforms must produce identical allocation shares, identical allocated
/// labour and identical partial-activity markers from this fixture.
///
/// The fixture covers every shape that could mis-attribute labour:
///
///  * A — two blocks, equal size, Work Task labour lines (18 person-hours, $630)
///  * B — one block, NO labour lines (legacy activity hours only, 4.0)
///  * C — three blocks, equal size, Work Task labour lines (12 person-hours, $300)
///  * D — two blocks, REVERSED (10 person-hours, $200 — must never be totalled)
///  * E — two blocks, UNEQUAL (0.50 + 2.00 row equivalents), 13 person-hours,
///        $455. This is the worked example from the brief: filtering to the
///        0.50-row-equivalent block must yield a 20% share, 2.60 person-hours
///        and $91.00 — never the whole $455.
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

    /// Tolerant comparison — the maths is exact to the cent, not to the bit.
    private static func close(_ value: Double?, _ expected: Double, _ tolerance: Double = 0.0001) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    private static let vineyardId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae000")!
    private static let blockPinot = UUID(uuidString: "00000000-0000-0000-0000-0000000ae001")!
    private static let blockCab = UUID(uuidString: "00000000-0000-0000-0000-0000000ae002")!
    private static let blockChard = UUID(uuidString: "00000000-0000-0000-0000-0000000ae003")!
    private static let blockPrim = UUID(uuidString: "00000000-0000-0000-0000-0000000ae004")!

    private static let taskA = UUID(uuidString: "00000000-0000-0000-0000-0000000ae011")!
    private static let taskC = UUID(uuidString: "00000000-0000-0000-0000-0000000ae012")!
    private static let taskD = UUID(uuidString: "00000000-0000-0000-0000-0000000ae013")!
    private static let taskE = UUID(uuidString: "00000000-0000-0000-0000-0000000ae014")!
    private static let taskR = UUID(uuidString: "00000000-0000-0000-0000-0000000ae015")!

    private static let activityAId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0a0")!
    private static let activityBId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0b0")!
    private static let activityCId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0c0")!
    private static let activityDId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0d0")!
    private static let activityEId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0e0")!
    private static let activityRId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0f0")!
    private static let activityXId = UUID(uuidString: "00000000-0000-0000-0000-0000000ae0f1")!
    /// A deliberately "real looking" id, for the identifier tests.
    private static let activityUId = UUID(uuidString: "3f2a1b7c-9d4e-4c11-8f0a-1b2c3d4e5f60")!
    private static let allocationUId = UUID(uuidString: "8c7b6a59-4d3e-4210-9f8e-7d6c5b4a3921")!

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
        ),
        blockPrim: PruningActivityBlockContext(
            name: "Primitivo",
            variety: "Primitivo",
            rows: rowRefs(Array(20...24))
        )
    ]

    /// One whole row = four quarters = 1.00 row equivalents.
    private static func wholeRow(_ number: Int) -> [PruningSegment] {
        (1...4).map { PruningSegment(row: number, quarter: $0) }
    }

    /// A part row — two quarters = 0.50 row equivalents.
    private static func halfRow(_ number: Int) -> [PruningSegment] {
        (1...2).map { PruningSegment(row: number, quarter: $0) }
    }

    private static func allocation(
        id: UUID,
        activityId: UUID,
        allocationIndex: Int,
        paddock: UUID,
        day: Int,
        rowNumber: Int = 0,
        segments: [PruningSegment]? = nil,
        worker: String = "Pruning Crew",
        /// The legacy MIRROR of the activity's own values, stored on the primary
        /// allocation. The report must never depend on this row surviving a
        /// filter to know the activity has labour.
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
            segments: segments ?? wholeRow(rowNumber),
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

    /// A — two equal blocks, Work Task labour lines.
    private static let activityA: [PruningEntry] = [
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0a1")!,
            activityId: activityAId, allocationIndex: 0, paddock: blockPinot,
            day: 3, rowNumber: 90, operationalHours: 6,
            start: date(3, 7, 0), finish: date(3, 13, 0),
            notes: "Cold start frost delay", workTaskId: taskA
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

    /// C — three equal blocks, Work Task labour lines.
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

    /// E — the worked example. Cabernet Franc 0.50 row equivalents (PRIMARY),
    /// Primitivo 2.00 (SECONDARY), 2.50 total, 13 person-hours, $455.
    private static let activityE: [PruningEntry] = [
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0e1")!,
            activityId: activityEId, allocationIndex: 0, paddock: blockCab,
            day: 7, segments: halfRow(5), operationalHours: 7,
            start: date(7, 6, 30), finish: date(7, 13, 30),
            notes: "Two block sweep", workTaskId: taskE
        ),
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0e2")!,
            activityId: activityEId, allocationIndex: 1, paddock: blockPrim,
            day: 7, segments: wholeRow(20) + wholeRow(21)
        )
    ]

    /// X — a CORRUPTED activity. Its two allocations disagree about the worker,
    /// the Work Task, the labour and the timing. This cannot happen through the
    /// app; it happens through a half-applied sync or a stale legacy mirror.
    private static let activityX: [PruningEntry] = [
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0f2")!,
            activityId: activityXId, allocationIndex: 0, paddock: blockPinot,
            day: 3, rowNumber: 93, worker: "Dan", operationalHours: 6,
            start: date(3, 7, 0), finish: date(3, 13, 0), workTaskId: taskA
        ),
        allocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0f3")!,
            activityId: activityXId, allocationIndex: 1, paddock: blockCab,
            day: 3, rowNumber: 4, worker: "Sam", operationalHours: 9,
            start: date(3, 8, 30), finish: date(3, 17, 0), workTaskId: taskC
        )
    ]

    /// U — one allocation with UUID-shaped ids, for the identifier tests.
    private static let activityU: [PruningEntry] = [
        allocation(
            id: allocationUId,
            activityId: activityUId, allocationIndex: 0, paddock: blockPinot,
            day: 3, rowNumber: 94, operationalHours: 3, workTaskId: taskA
        )
    ]

    private static let titles: [UUID: String] = [
        taskA: "Winter pruning",
        taskC: "Spur pruning block sweep",
        taskD: "Reversed pruning",
        taskE: "Vineyard block pruning"
    ]

    private static let statuses: [UUID: String] = [
        taskA: "Completed",
        taskC: "In progress",
        taskD: "Completed",
        taskE: "Completed"
    ]

    /// Summed Work Task labour lines — the AUTHORITATIVE labour source.
    private static let taskHours: [UUID: Double] = [taskA: 18, taskC: 12, taskD: 10, taskE: 13]
    private static let taskCosts: [UUID: Double] = [taskA: 630, taskC: 300, taskD: 200, taskE: 455]

    private static var allEntries: [PruningEntry] {
        activityA + activityB + activityC + activityD + activityE
    }

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

    /// The canonical (unfiltered) rows for one activity.
    private static func canonicalE() -> [PruningActivityRow] { sorted(activityE) }

    /// Filters a canonical set down to one block, as the report's filter does.
    private static func onlyBlock(_ canonical: [PruningActivityRow], _ paddock: UUID) -> [PruningActivityRow] {
        var filter = PruningActivityFilter()
        filter.blocks = [paddock]
        return PruningActivityReport.sorted(
            PruningActivityReport.filtered(canonical, with: filter),
            by: .default
        )
    }

    private static func rows(
        _ reportRows: [PruningActivityRow],
        includeCost: Bool = true,
        canonical: [PruningActivityRow]? = nil
    ) -> [PruningActivityExport.Row] {
        PruningActivityExport.rows(
            reportRows,
            includeCost: includeCost,
            canonicalRows: canonical,
            calendar: calendar
        )
    }

    private static func exported(
        _ entries: [PruningEntry]? = nil,
        includeCost: Bool = true
    ) -> [PruningActivityExport.Row] {
        rows(sorted(entries), includeCost: includeCost)
    }

    // MARK: 1. Two-block activity filtered to the PRIMARY block

    @Test("A two-block activity filtered to the primary block reports a partial activity")
    func filteredToPrimaryBlock() throws {
        let canonical = Self.canonicalE()
        let exported = Self.rows(Self.onlyBlock(canonical, Self.blockCab), canonical: canonical)

        let row = try #require(exported.first)
        #expect(exported.count == 1)
        #expect(row.blockName == "Cabernet Franc")
        #expect(row.allocationNumber == 1)
        #expect(row.fullAllocationCount == 2)
        #expect(row.includedAllocationCount == 1)
        #expect(row.isPartialActivity)
        #expect(row.allocationLabel == "block 1 of 2 (1 shown)")

        // The brief's worked example, exactly.
        #expect(Self.close(row.allocationShare, 0.20, 0.000001))
        #expect(Self.close(row.allocatedPersonHours, 2.60))
        #expect(Self.close(row.allocatedLabourCost, 91.00))

        // The WHOLE activity's totals are still stated, and still whole.
        #expect(row.isActivityTotalsRow)
        #expect(Self.close(row.activityPersonHours, 13.0))
        #expect(Self.close(row.activityLabourCost, 455.0))
    }

    // MARK: 2. Two-block activity filtered to the SECONDARY block

    @Test("A two-block activity filtered to the secondary block keeps its parent context")
    func filteredToSecondaryBlock() throws {
        let canonical = Self.canonicalE()
        let exported = Self.rows(Self.onlyBlock(canonical, Self.blockPrim), canonical: canonical)

        let row = try #require(exported.first)
        #expect(exported.count == 1)
        #expect(row.blockName == "Primitivo")
        // The allocation keeps its TRUE position in the parent — it is still the
        // second allocation, even though it is the only one shown.
        #expect(row.allocationNumber == 2)
        #expect(row.fullAllocationCount == 2)
        #expect(row.includedAllocationCount == 1)
        #expect(row.isPartialActivity)
        #expect(row.allocationLabel == "block 2 of 2 (1 shown)")

        #expect(Self.close(row.allocationShare, 0.80, 0.000001))
        #expect(Self.close(row.allocatedPersonHours, 10.40))
        #expect(Self.close(row.allocatedLabourCost, 364.00))

        // The legacy primary allocation was filtered out, and the whole-activity
        // totals are STILL present. This is the regression that matters most:
        // the parent owns these values, not the primary allocation row.
        #expect(row.isActivityTotalsRow)
        #expect(Self.close(row.activityPersonHours, 13.0))
        #expect(Self.close(row.activityLabourCost, 455.0))
        #expect(Self.close(row.activityOperationalHours, 7.0))
        #expect(Self.close(row.activityDurationHours, 7.0))
        #expect(row.notes == "Two block sweep")
    }

    // MARK: 3. A secondary-only result still carries allocated hours and cost

    @Test("A secondary-only result still reports allocated hours and cost")
    func secondaryOnlyKeepsAllocatedValues() throws {
        let canonical = Self.canonicalE()
        let exported = Self.rows(Self.onlyBlock(canonical, Self.blockPrim), canonical: canonical)
        let row = try #require(exported.first)

        #expect(row.allocatedPersonHours != nil)
        #expect(row.allocatedLabourCost != nil)

        // And they reach the CSV as real numbers, not blanks.
        let headers = PruningActivityExport.headers(includeCost: true)
        let cells = PruningActivityExport.cells(row, includeCost: true)
        #expect(cells[try #require(headers.firstIndex(of: "Allocated Person-Hours"))] == "10.40")
        #expect(cells[try #require(headers.firstIndex(of: "Allocated Labour Cost"))] == "364.00")
        #expect(cells[try #require(headers.firstIndex(of: "Allocation Share (%)"))] == "80.00")
    }

    // MARK: 4. Parent Work Task and worker survive the filter

    @Test("The parent Work Task and worker remain available on a secondary allocation")
    func parentContextSurvivesFilter() throws {
        let canonical = Self.canonicalE()
        let filtered = Self.onlyBlock(canonical, Self.blockPrim)
        let row = try #require(Self.rows(filtered, canonical: canonical).first)

        #expect(row.workTaskTitle == "Vineyard block pruning")
        #expect(row.workTaskStatus == "Completed")
        #expect(row.activityLabel == "Vineyard block pruning")
        #expect(row.worker == "Pruning Crew")
        #expect(row.startTime == "06:30")
        #expect(row.finishTime == "13:30")
        #expect(!row.method.isEmpty)

        // The same is true in the grouped PDF layout.
        let group = try #require(
            PruningActivityExport.groups(
                filtered,
                includeCost: true,
                canonicalRows: canonical,
                calendar: Self.calendar
            ).first
        )
        #expect(group.workTaskTitle == "Vineyard block pruning")
        #expect(group.worker == "Pruning Crew")
        #expect(group.partialLabel == "Partial activity — 1 of 2 blocks shown")
    }

    // MARK: 5. The allocation share uses the FULL activity denominator

    @Test("The allocation share uses the full activity denominator, not the filtered subset")
    func shareUsesFullDenominator() throws {
        let canonical = Self.canonicalE()

        // Filtered to the 2.00-row-equivalent block. Its OWN row equivalents are
        // the only ones in the result, so a subset denominator would give 100%.
        let row = try #require(Self.rows(Self.onlyBlock(canonical, Self.blockPrim), canonical: canonical).first)
        #expect(Self.close(row.rowEquivalents, 2.0))
        #expect(Self.close(row.allocationShare, 0.80, 0.000001))

        // The denominator is the parent's 2.50, not the surviving 2.00.
        let model = PruningActivityAllocationModel.build(canonical, includeCost: true)
        let parent = try #require(model.parent(Self.activityEId))
        #expect(Self.close(parent.rowEquivalents, 2.5))
        #expect(Self.close(row.allocationShare, row.rowEquivalents / parent.rowEquivalents, 0.000001))
    }

    // MARK: 6. The partial marker is present, and absent when complete

    @Test("The partial activity marker is present only when allocations are missing")
    func partialMarker() throws {
        let canonical = Self.canonicalE()
        let headers = PruningActivityExport.headers(includeCost: true)
        let partialIndex = try #require(headers.firstIndex(of: "Partial Activity"))

        let partial = try #require(Self.rows(Self.onlyBlock(canonical, Self.blockPrim), canonical: canonical).first)
        #expect(partial.isPartialActivity)
        #expect(PruningActivityExport.cells(partial, includeCost: true)[partialIndex] == "Yes")

        let complete = Self.rows(canonical, canonical: canonical)
        #expect(complete.count == 2)
        #expect(complete.allSatisfy { !$0.isPartialActivity })
        for row in complete {
            #expect(PruningActivityExport.cells(row, includeCost: true)[partialIndex] == "No")
            #expect(row.includedAllocationCount == 2)
        }
    }

    // MARK: 7. An included allocation's cost never inflates to 100%

    @Test("An included allocation cost never inflates to the whole activity")
    func allocatedCostNeverInflates() throws {
        let canonical = Self.canonicalE()

        for (paddock, expected) in [(Self.blockCab, 91.00), (Self.blockPrim, 364.00)] {
            let row = try #require(Self.rows(Self.onlyBlock(canonical, paddock), canonical: canonical).first)
            #expect(Self.close(row.allocatedLabourCost, expected))
            // An allocated cost must never equal the whole activity's.
            #expect(try #require(row.allocatedLabourCost) < 455.0)
        }

        // The two filtered slices add back up to the parent exactly.
        #expect(Self.close(91.00 + 364.00, 455.0))
    }

    // MARK: 8. Parent totals appear exactly once

    @Test("Whole-activity totals appear on exactly one row per activity")
    func parentTotalsAppearOnce() {
        let exported = Self.exported()

        // One totals row per activity, and only totals rows carry parent values.
        let totalsRows = exported.filter(\.isActivityTotalsRow)
        var distinctActivities = Set<String>()
        for row in exported { distinctActivities.insert(row.activityId) }
        #expect(totalsRows.count == distinctActivities.count)
        #expect(Set(totalsRows.map(\.activityId)).count == totalsRows.count)

        for row in exported where !row.isActivityTotalsRow {
            #expect(row.activityPersonHours == nil)
            #expect(row.activityLabourCost == nil)
            #expect(row.activityOperationalHours == nil)
            #expect(row.activityDurationHours == nil)
            #expect(row.notes == nil)
        }

        // De-duplicating by activity id gives the true whole-activity total;
        // 18 + 4 + 12 + 13, with the reversed activity excluded.
        #expect(Self.close(PruningActivityExport.activityTotal(exported) { $0.activityPersonHours }, 47.0))
        #expect(Self.close(PruningActivityExport.activityTotal(exported) { $0.activityLabourCost }, 1385.0))
    }

    // MARK: 9. Allocated totals equal the filtered summary

    @Test("Allocated column totals equal the filtered summary")
    func allocatedTotalsMatchFilteredSummary() throws {
        let canonical = Self.sorted()

        // Cabernet Franc appears in A (1.00 of 2.00), C (1.00 of 3.00),
        // D (reversed) and E (0.50 of 2.50).
        let filtered = Self.onlyBlock(canonical, Self.blockCab)
        let summary = PruningActivityReport.summary(filtered, includeCost: true, canonicalRows: canonical)
        let exported = Self.rows(filtered, canonical: canonical)

        let hours = PruningActivityExport.columnTotal(exported) { $0.allocatedPersonHours }
        let cost = PruningActivityExport.columnTotal(exported) { $0.allocatedLabourCost }

        // 9.00 (A) + 4.00 (C) + 2.60 (E); D is reversed and excluded.
        #expect(Self.close(summary.labourHours, 15.60))
        #expect(Self.close(hours, summary.labourHours))
        // 315.00 (A) + 100.00 (C) + 91.00 (E).
        #expect(Self.close(summary.labourCost, 506.00))
        #expect(Self.close(cost, try #require(summary.labourCost)))

        // The whole-activity figures are larger, and de-duplicated by activity.
        #expect(Self.close(summary.wholeActivityLabourHours, 43.0))
        #expect(Self.close(summary.wholeActivityLabourCost, 1385.0))
        #expect(summary.activities == 3)
        #expect(summary.partialActivities == 3)
        #expect(summary.hasPartialActivities)
    }

    // MARK: 10. Unfiltered allocated totals reconcile exactly to the parents

    @Test("Unfiltered allocated totals reconcile exactly to the parent totals")
    func unfilteredTotalsReconcile() throws {
        let reportRows = Self.sorted()
        let exported = Self.rows(reportRows)
        let summary = PruningActivityReport.summary(reportRows, includeCost: true)

        let allocatedHours = PruningActivityExport.columnTotal(exported) { $0.allocatedPersonHours }
        let allocatedCost = PruningActivityExport.columnTotal(exported) { $0.allocatedLabourCost }
        let parentHours = PruningActivityExport.activityTotal(exported) { $0.activityPersonHours }
        let parentCost = PruningActivityExport.activityTotal(exported) { $0.activityLabourCost }

        #expect(Self.close(allocatedHours, parentHours))
        #expect(Self.close(allocatedCost, parentCost))
        #expect(Self.close(allocatedHours, 47.0))
        #expect(Self.close(allocatedCost, 1385.0))

        // With nothing filtered out, the two summary figures agree and nothing
        // is marked partial.
        #expect(Self.close(summary.labourHours, summary.wholeActivityLabourHours))
        #expect(Self.close(summary.labourCost, try #require(summary.wholeActivityLabourCost)))
        #expect(summary.partialActivities == 0)

        // Per activity, too — never just in aggregate.
        for group in PruningActivityExport.groups(reportRows, includeCost: true, calendar: Self.calendar) {
            if let parent = group.activityPersonHours {
                #expect(Self.close(group.allocatedPersonHours, parent))
            }
            if let parent = group.activityLabourCost {
                #expect(Self.close(group.allocatedLabourCost, parent))
            }
        }
    }

    // MARK: 11. The rounding remainder is assigned deterministically

    @Test("The rounding remainder is assigned deterministically and always reconciles")
    func roundingRemainderIsDeterministic() {
        // Three equal blocks sharing 10 person-hours and $100 — neither divides
        // evenly into cents, so a naive split would lose or gain a cent.
        let paddocks = [Self.blockPinot, Self.blockCab, Self.blockChard]
        let entries: [PruningEntry] = (0..<3).map { index in
            Self.allocation(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000af00\(index)")!,
                activityId: Self.activityRId,
                allocationIndex: index,
                paddock: paddocks[index],
                day: 8,
                rowNumber: index + 1,
                operationalHours: index == 0 ? 3 : nil,
                workTaskId: Self.taskR
            )
        }
        let reportRows = PruningActivityReport.sorted(
            PruningActivityReport.rows(
                entries: entries,
                blocks: Self.contexts,
                workTaskTitles: [Self.taskR: "Rounding sweep"],
                labourCosts: [Self.taskR: 100],
                labourHours: [Self.taskR: 10],
                accountNames: [:],
                calendar: Self.calendar
            ),
            by: .default
        )
        let exported = Self.rows(reportRows)

        // The remainder lands on the SAME allocation every run, on both
        // platforms: cumulative rounding puts it on the middle share here.
        #expect(
            exported.map { PruningActivityAllocationModel.roundTo($0.allocatedPersonHours ?? 0, decimals: 2) }
                == [3.33, 3.34, 3.33]
        )
        #expect(
            exported.map { PruningActivityAllocationModel.roundTo($0.allocatedLabourCost ?? 0, decimals: 2) }
                == [33.33, 33.34, 33.33]
        )

        // And the parts reconcile to the parent to the cent.
        #expect(Self.close(PruningActivityExport.columnTotal(exported) { $0.allocatedPersonHours }, 10.0, 0.0000001))
        #expect(Self.close(PruningActivityExport.columnTotal(exported) { $0.allocatedLabourCost }, 100.0, 0.0000001))
    }

    // MARK: 12. Removing costing permission strips BOTH cost fields

    @Test("Removing costing permission strips both the parent and the allocated cost")
    func costPermissionStripsBothCosts() {
        let reportRows = Self.sorted()

        let headers = PruningActivityExport.headers(includeCost: false)
        #expect(!headers.contains("Allocated Labour Cost"))
        #expect(!headers.contains("Activity Total Labour Cost"))
        // Hours survive — only money is withheld.
        #expect(headers.contains("Allocated Person-Hours"))
        #expect(headers.contains("Activity Person-Hours"))

        let exported = Self.rows(reportRows, includeCost: false)
        #expect(exported.allSatisfy { $0.allocatedLabourCost == nil })
        #expect(exported.allSatisfy { $0.activityLabourCost == nil })
        #expect(exported.contains { $0.allocatedPersonHours != nil })

        // The values are absent from the FILE, not merely hidden in a renderer.
        let csv = PruningActivityExport.csv(reportRows, includeCost: false, calendar: Self.calendar)
        for amount in ["455.00", "364.00", "630.00", "315.00", "91.00"] {
            #expect(!csv.contains(amount), "cost \(amount) leaked into a cost-blind export")
        }

        let groups = PruningActivityExport.groups(reportRows, includeCost: false, calendar: Self.calendar)
        #expect(groups.allSatisfy { $0.activityLabourCost == nil && $0.allocatedLabourCost == nil })
        // The report's own summary withholds it too.
        let summary = PruningActivityReport.summary(reportRows, includeCost: false)
        #expect(summary.labourCost == nil)
        #expect(summary.wholeActivityLabourCost == nil)
    }

    // MARK: 13. Allocation quantities stay on every row

    @Test("Allocation quantities are present on every allocation row")
    func allocationQuantitiesOnEveryRow() {
        let exported = Self.exported(Self.activityA)

        #expect(exported.count == 2)
        for row in exported {
            #expect(row.quarters == 4)
            #expect(Self.close(row.rowEquivalents, 1.0))
            #expect(Self.close(row.estimatedVines, 100.0))
            #expect(!row.blockName.isEmpty)
            #expect(!(row.variety ?? "").isEmpty)
            #expect(!(row.rowRange ?? "").isEmpty)
            // Parent context repeats: it is text, it cannot be summed, and
            // repeating it keeps a wide spreadsheet readable when scrolled.
            #expect(row.workTaskTitle == "Winter pruning")
            #expect(row.workTaskStatus == "Completed")
            #expect(row.worker == "Pruning Crew")
            #expect(row.startTime == "07:00")
            // Equal blocks, so an even split of the activity's labour.
            #expect(Self.close(row.allocationShare, 0.5, 0.000001))
            #expect(Self.close(row.allocatedPersonHours, 9.0))
            #expect(Self.close(row.allocatedLabourCost, 315.0))
        }
        #expect(exported[0].rowRange == "90")
        #expect(exported[1].rowRange == "1")
    }

    // MARK: 14. The labour authority order is unchanged

    @Test("Work Task labour lines win and the legacy value is only a fallback")
    func labourAuthorityUnchanged() throws {
        // A has BOTH 6.0 legacy operational hours and 18.0 task person-hours.
        // The task wins for person-hours; the legacy value stays visible as the
        // separate operational figure and is never added to it.
        let a = try #require(Self.exported(Self.activityA).first)
        #expect(Self.close(a.activityPersonHours, 18.0))
        #expect(Self.close(a.activityOperationalHours, 6.0))

        // B has no task at all, so the legacy activity value IS the labour.
        let b = try #require(Self.exported(Self.activityB).first)
        #expect(Self.close(b.activityPersonHours, 4.0))
        #expect(Self.close(b.allocatedPersonHours, 4.0))
        #expect(b.activityLabourCost == nil)
        #expect(b.allocatedLabourCost == nil)
        #expect(b.allocationLabel == "whole activity")
    }

    // MARK: 15. Reversed activities are visible but never totalled

    @Test("Reversed activities are exported but excluded from every total")
    func reversedExcludedFromTotals() throws {
        let exported = Self.exported()
        let reversed = exported.filter(\.isReversed)

        #expect(reversed.count == 2)
        #expect(reversed.allSatisfy { $0.activityLabel == "Reversed pruning" })
        // Their allocated values still exist on the row — the audit trail is
        // complete — they are simply never summed.
        #expect(reversed.allSatisfy { $0.allocatedPersonHours != nil })
        #expect(Self.close(PruningActivityExport.columnTotal(exported) { $0.allocatedPersonHours }, 47.0))
        #expect(Self.close(PruningActivityExport.columnTotal(exported) { $0.allocatedLabourCost }, 1385.0))

        let headers = PruningActivityExport.headers(includeCost: true)
        let cells = PruningActivityExport.cells(reversed[0], includeCost: true)
        #expect(cells[try #require(headers.firstIndex(of: "Reversed"))] == "Yes")
    }

    // MARK: 16. Identifiers are exported, but never as the human-readable name

    @Test("Identifiers are exported for reconciliation but never as the activity name")
    func identifiersExportedButNotAsName() {
        let exported = Self.exported()

        for row in exported {
            #expect(!row.activityId.isEmpty)
            #expect(!row.allocationId.isEmpty)
            // The readable label is a Work Task title or a method — never an id.
            #expect(!row.activityLabel.contains(row.activityId))
            #expect(!row.activityLabel.contains(row.allocationId))
        }

        // Every allocation of one activity shares its activity id, and each
        // allocation id is unique across the file.
        let a = exported.filter { $0.activityLabel == "Winter pruning" }
        #expect(Set(a.map(\.activityId)).count == 1)
        #expect(Set(exported.map(\.allocationId)).count == exported.count)
    }

    // MARK: 17. The export respects the active filter and sort

    @Test("The export respects the active filter")
    func exportRespectsFilter() throws {
        let canonical = Self.sorted()
        let exported = Self.rows(Self.onlyBlock(canonical, Self.blockChard), canonical: canonical)

        // Chardonnay appears in B (whole activity) and C (one of three).
        #expect(exported.count == 2)
        #expect(exported.allSatisfy { $0.blockName == "Chardonnay" })

        let b = try #require(exported.first { $0.dateIso == "2026-08-04" })
        #expect(!b.isPartialActivity)
        #expect(Self.close(b.activityPersonHours, 4.0))

        let c = try #require(exported.first { $0.dateIso == "2026-08-05" })
        #expect(c.isPartialActivity)
        #expect(c.allocationNumber == 3)
        #expect(c.fullAllocationCount == 3)
        #expect(c.includedAllocationCount == 1)
        // Parent context survives even though C's primary was filtered out.
        #expect(c.workTaskTitle == "Spur pruning block sweep")
        #expect(Self.close(c.activityPersonHours, 12.0))
        // But only a third of the labour is attributed to this block.
        #expect(Self.close(c.allocatedPersonHours, 4.0))
        #expect(Self.close(c.allocatedLabourCost, 100.0))
    }

    @Test("The export follows the report sort direction")
    func exportFollowsSortDirection() {
        let base = Self.build(Self.allEntries)
        let ascending = PruningActivityReport.sorted(
            base,
            by: PruningActivitySort(column: .date, ascending: true)
        )
        let descending = PruningActivityReport.sorted(
            base,
            by: PruningActivitySort(column: .date, ascending: false)
        )

        #expect(Self.rows(ascending).first?.dateIso == "2026-08-03")
        #expect(Self.rows(descending).first?.dateIso == "2026-08-07")
    }

    // MARK: 18. Allocations of one activity stay contiguous under any sort

    @Test("Allocations of one activity stay contiguous whatever the sort")
    func allocationsStayContiguous() {
        let byBlock = PruningActivityReport.sorted(
            Self.build(Self.allEntries),
            by: PruningActivitySort(column: .block, ascending: true)
        )
        let exported = Self.rows(byBlock)
        let groups = PruningActivityExport.groups(byBlock, includeCost: true, calendar: Self.calendar)

        // Group ORDER follows the report's own visible order.
        var visibleOrder: [UUID] = []
        for row in byBlock where !visibleOrder.contains(row.activityKey) {
            visibleOrder.append(row.activityKey)
        }
        #expect(groups.map(\.id) == visibleOrder)

        // Every activity is ONE contiguous run of rows — never scattered.
        var runs: [String] = []
        for row in exported where runs.last != row.activityId {
            runs.append(row.activityId)
        }
        #expect(Set(runs).count == runs.count)
        #expect(runs.count == groups.count)

        // Within a group the canonical order holds, so the totals row is row 1.
        for group in groups {
            #expect(group.allocations.map(\.allocationNumber) == group.allocations.map(\.allocationNumber).sorted())
            #expect(group.allocations.first?.isActivityTotalsRow == true)
            #expect(group.allocations.dropFirst().allSatisfy { !$0.isActivityTotalsRow })
        }
    }

    // MARK: 19. CSV shape, quoting and numeric formatting

    @Test("The CSV has one header row and one row per allocation")
    func csvShape() {
        let csv = PruningActivityExport.csv(Self.sorted(), includeCost: true, calendar: Self.calendar)
        let lines = csv.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            .components(separatedBy: "\r\n")

        #expect(lines.count == 10 + 1)
        #expect(csv.hasSuffix("\r\n"))
        #expect(lines[0].components(separatedBy: ",").count
            == PruningActivityExport.headers(includeCost: true).count)
    }

    @Test("CSV values are quoted only when they contain a delimiter")
    func csvQuoting() {
        let withComma = [
            Self.allocation(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0aa")!,
                activityId: UUID(uuidString: "00000000-0000-0000-0000-0000000ae0ab")!,
                allocationIndex: 0, paddock: Self.blockPinot,
                day: 3, rowNumber: 90, operationalHours: 2,
                notes: "Rain, then hail"
            )
        ]
        let csv = PruningActivityExport.csv(Self.sorted(withComma), includeCost: true, calendar: Self.calendar)

        #expect(csv.contains("\"Rain, then hail\""))
        // Numbers are never quoted, so a spreadsheet reads them as numbers.
        #expect(csv.contains(",2.00,"))
        #expect(!csv.contains("\"2.00\""))
    }

    @Test("The CSV keeps a raw ISO date, an Australian display date and a totals flag")
    func csvDatesAndTotalsFlag() throws {
        let csv = PruningActivityExport.csv(Self.sorted(Self.activityA), includeCost: true, calendar: Self.calendar)
        let lines = csv.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            .components(separatedBy: "\r\n")
        let headers = lines[0].components(separatedBy: ",")
        let first = lines[1].components(separatedBy: ",")
        let second = lines[2].components(separatedBy: ",")

        #expect(first[try #require(headers.firstIndex(of: "Date (ISO)"))] == "2026-08-03")
        #expect(first[try #require(headers.firstIndex(of: "Activity Date"))] == "03/08/2026")
        #expect(first[try #require(headers.firstIndex(of: "Weekday"))] == "Monday")
        #expect(first[try #require(headers.firstIndex(of: "Activity Totals Row"))] == "Yes")
        #expect(second[try #require(headers.firstIndex(of: "Activity Totals Row"))] == "No")
        // The parent totals column is blank on the second row, not "0.00".
        #expect(second[try #require(headers.firstIndex(of: "Activity Person-Hours"))] == "")
        // But its allocated share is populated.
        #expect(second[try #require(headers.firstIndex(of: "Allocated Person-Hours"))] == "9.00")
    }

    // MARK: 20. The PDF grouping states the labour once

    @Test("The PDF groups allocations under one activity heading")
    func pdfGrouping() throws {
        let groups = PruningActivityExport.groups(Self.sorted(), includeCost: true, calendar: Self.calendar)

        #expect(groups.count == 5)
        #expect(groups.reduce(0) { $0 + $1.includedAllocationCount } == 10)

        let a = try #require(groups.first { $0.activityLabel == "Winter pruning" })
        #expect(a.includedAllocationCount == 2)
        #expect(!a.isPartialActivity)
        #expect(a.partialLabel == nil)
        #expect(a.blockSummary == "Pinot Noir + Cabernet Franc")
        #expect(Self.close(a.totalRowEquivalents, 2.0))
        // Stated ONCE for the whole activity, whatever the allocation count.
        #expect(Self.close(a.activityPersonHours, 18.0))
        #expect(Self.close(a.activityLabourCost, 630.0))
        #expect(Self.close(a.allocatedPersonHours, 18.0))

        let e = try #require(groups.first { $0.activityLabel == "Vineyard block pruning" })
        #expect(e.blockSummary == "Cabernet Franc + Primitivo")
        #expect(e.allocations.map { $0.allocatedPersonHours ?? 0 } == [2.60, 10.40])
    }

    // MARK: 21. The PDF names the activity and never prints a full UUID

    @Test("The PDF uses the activity name and a short reference, never a full id")
    func pdfUsesShortReference() throws {
        let group = try #require(
            PruningActivityExport.groups(Self.sorted(Self.activityU), includeCost: true, calendar: Self.calendar).first
        )

        // The label is the human-readable Work Task title.
        #expect(group.activityLabel == "Winter pruning")

        // The short reference is the first eight characters — and a PREFIX of
        // the full id, so matching the PDF to the CSV is a "starts with".
        #expect(group.shortReference == "3f2a1b7c")
        #expect(group.shortReference.count == 8)
        #expect(group.activityId.hasPrefix(group.shortReference))
        #expect(PruningActivityExport.referenceLine(group, includeShortReferences: true) == "Ref 3f2a1b7c")
        #expect(PruningActivityExport.referenceLine(group, includeShortReferences: false) == nil)

        // Nothing a reader sees in the body carries the full UUID.
        let fullActivityId = Self.activityUId.uuidString.lowercased()
        let fullAllocationId = Self.allocationUId.uuidString.lowercased()
        var body = [
            group.activityLabel,
            group.dateDisplay,
            group.blockSummary,
            PruningActivityExport.referenceLine(group, includeShortReferences: true) ?? ""
        ]
        body.append(contentsOf: group.allocations.map { "\($0.allocationLabel) \($0.blockName)" })
        for line in body {
            #expect(!line.localizedCaseInsensitiveContains(fullActivityId))
            #expect(!line.localizedCaseInsensitiveContains(fullAllocationId))
        }
    }

    @Test("Full ids stay in the CSV and in the optional technical references")
    func fullIdsStayInCsvAndAppendix() throws {
        let reportRows = Self.sorted(Self.activityU)
        let fullActivityId = Self.activityUId.uuidString.lowercased()
        let fullAllocationId = Self.allocationUId.uuidString.lowercased()

        // The CSV keeps them — it is the reconciliation artefact.
        let csv = PruningActivityExport.csv(reportRows, includeCost: true, calendar: Self.calendar)
        #expect(csv.contains(fullActivityId))
        #expect(csv.contains(fullAllocationId))

        // The PDF keeps them only in the opt-in appendix.
        let group = try #require(
            PruningActivityExport.groups(reportRows, includeCost: true, calendar: Self.calendar).first
        )
        let technical = PruningActivityExport.technicalReferenceLines(group)
        #expect(technical.first == "Winter pruning — \(group.dateDisplay)")
        #expect(technical.contains("Activity ID: \(fullActivityId)"))
        #expect(technical.contains("Allocation 1 (Pinot Noir): \(fullAllocationId)"))
        #expect(PruningActivityExport.technicalReferencesHeading == "Technical references")
    }

    @Test("A short reference tolerates short and empty ids")
    func shortReferenceEdgeCases() {
        #expect(PruningActivityExport.shortReference("act-e") == "act-e")
        #expect(PruningActivityExport.shortReference("   ") == "")
        #expect(PruningActivityExport.shortReference(Self.activityUId.uuidString.lowercased()) == "3f2a1b7c")
    }

    // MARK: 22. Conflicting parent values are FLAGGED, never silently chosen

    @Test("Allocations that disagree about their parent raise a context conflict")
    func conflictingAllocationsAreFlagged() throws {
        let canonical = Self.sorted(Self.activityX)
        let model = PruningActivityAllocationModel.build(canonical, includeCost: true)

        #expect(model.hasConflicts)
        #expect(model.conflictedActivityIds == [Self.activityXId])

        let fields = Set(model.conflicts(Self.activityXId).map(\.field))
        // Worker, Work Task, labour and timing — the four the brief names.
        #expect(fields.contains(.worker))
        #expect(fields.contains(.workTask))
        #expect(fields.contains(.personHours))
        #expect(fields.contains(.labourCost))
        #expect(fields.contains(.startTime))
        #expect(fields.contains(.operationalHours))

        // BOTH competing values are reported, not just the winner.
        let worker = try #require(model.conflicts(Self.activityXId).first { $0.field == .worker })
        #expect(worker.values == ["Dan", "Sam"])
        #expect(worker.resolvedValue == "Dan")
        // With no canonical parent the choice is an unverified guess, and says so.
        #expect(worker.resolution == .firstAllocation)
        #expect(worker.description.contains(Self.activityXId.uuidString))
        #expect(worker.description.contains("Dan vs Sam"))
        #expect(worker.description.contains("unverified"))

        let hours = try #require(model.conflicts(Self.activityXId).first { $0.field == .personHours })
        #expect(hours.values == ["18.0000", "12.0000"])

        // The parent still renders — a blank report would be worse — but it is
        // marked, and the export still balances against whatever it chose.
        let parent = try #require(model.parent(Self.activityXId))
        #expect(parent.hasContextConflict)
        #expect(!parent.resolvedFromCanonicalParent)
        #expect(parent.worker == "Dan")
        #expect(Self.close(parent.personHours, 18.0))

        let exported = Self.rows(canonical)
        #expect(Self.close(PruningActivityExport.columnTotal(exported) { $0.allocatedPersonHours }, 18.0))

        // And the reader is told, in the PDF, before they act on the number.
        #expect(
            PruningActivityExport.conflictNotice(conflictedActivities: 1)
                == "1 activity has conflicting source records — verify against the portal"
        )
        #expect(
            PruningActivityExport.conflictNotice(conflictedActivities: 2)
                == "2 activities have conflicting source records — verify against the portal"
        )
        #expect(PruningActivityExport.conflictNotice(conflictedActivities: 0) == nil)
    }

    // MARK: 23. The canonical parent outranks the allocation mirror

    @Test("The canonical activity parent wins whenever it is available")
    func canonicalParentWins() throws {
        let canonical = Self.sorted(Self.activityX)
        let parents: [UUID: PruningActivityParentSource] = [
            Self.activityXId: PruningActivityParentSource(
                activityId: Self.activityXId,
                worker: "Site Crew",
                startTime: Self.date(3, 5, 45),
                personHours: 20,
                labourCost: 500
            )
        ]
        let model = PruningActivityAllocationModel.build(
            canonical,
            includeCost: true,
            canonicalParents: parents
        )
        let parent = try #require(model.parent(Self.activityXId))

        // The canonical record decides — not the first allocation.
        #expect(parent.resolvedFromCanonicalParent)
        #expect(parent.worker == "Site Crew")
        #expect(Self.close(parent.personHours, 20.0))
        #expect(Self.close(parent.labourCost, 500.0))
        #expect(parent.startTime == Self.date(3, 5, 45))

        // The disagreement is still REPORTED — preferring the parent fixes the
        // reading, not the underlying data.
        #expect(parent.hasContextConflict)
        let worker = try #require(model.conflicts(Self.activityXId).first { $0.field == .worker })
        #expect(worker.resolution == .canonicalParent)
        #expect(worker.values == ["Site Crew", "Dan", "Sam"])
        #expect(worker.resolvedValue == "Site Crew")
        #expect(worker.description.contains("canonical activity record"))

        // And the allocated shares divide the CANONICAL labour, not the mirror's.
        let exported = PruningActivityExport.rows(
            canonical,
            includeCost: true,
            canonicalRows: canonical,
            canonicalParents: parents,
            calendar: Self.calendar
        )
        #expect(exported.map { $0.allocatedPersonHours ?? 0 } == [10.0, 10.0])
        #expect(exported.map { $0.allocatedLabourCost ?? 0 } == [250.0, 250.0])
        #expect(Self.close(exported.first?.activityPersonHours, 20.0))
        #expect(exported.first?.startTime == "05:45")
    }

    // MARK: 24. A legacy mirror is NOT a conflict

    @Test("Legacy projected rows with a single populated allocation raise no conflict")
    func legacyMirrorIsNotAConflict() throws {
        // The whole fixture is legacy-shaped: allocation 0 carries the activity
        // values, the rest carry none. That is expected, not corrupt.
        let model = PruningActivityAllocationModel.build(Self.sorted(), includeCost: true)
        #expect(!model.hasConflicts)
        #expect(model.conflicts.isEmpty)
        for activityId in [Self.activityAId, Self.activityBId, Self.activityCId, Self.activityDId, Self.activityEId] {
            #expect(model.parent(activityId)?.hasContextConflict == false)
        }

        // A canonical parent that AGREES with the mirror is not a conflict either.
        let agreeing = PruningActivityAllocationModel.build(
            Self.canonicalE(),
            includeCost: true,
            canonicalParents: [
                Self.activityEId: PruningActivityParentSource(
                    activityId: Self.activityEId,
                    worker: "Pruning Crew",
                    personHours: 13,
                    labourCost: 455
                )
            ]
        )
        #expect(!agreeing.hasConflicts)
        #expect(agreeing.parent(Self.activityEId)?.resolvedFromCanonicalParent == true)
    }

    // MARK: 25. Cross-platform parity fixture — Android must produce this exactly

    @Test("The parity fixture matches the Android export byte for byte")
    func crossPlatformParityFixture() {
        let exported = Self.rows(Self.canonicalE())

        let rendered = exported.map { row in
            [
                row.dateIso,
                row.dateDisplay,
                row.weekday,
                row.activityLabel,
                String(row.allocationNumber),
                String(row.fullAllocationCount),
                String(row.includedAllocationCount),
                row.isPartialActivity ? "partial" : "complete",
                row.allocationLabel,
                row.blockName,
                row.variety ?? "",
                PruningActivityExport.number(row.rowEquivalents, decimals: 2),
                PruningActivityExport.number(row.allocationShare.map { $0 * 100 }, decimals: 2),
                PruningActivityExport.number(row.allocatedPersonHours, decimals: 2),
                PruningActivityExport.number(row.allocatedLabourCost, decimals: 2),
                PruningActivityExport.number(row.activityPersonHours, decimals: 2),
                PruningActivityExport.number(row.activityLabourCost, decimals: 2),
                row.isActivityTotalsRow ? "Yes" : "No"
            ].joined(separator: "|")
        }.joined(separator: "\n")

        #expect(rendered == """
        2026-08-07|07/08/2026|Friday|Vineyard block pruning|1|2|2|complete|block 1 of 2|\
        Cabernet Franc|Cabernet Franc|0.50|20.00|2.60|91.00|13.00|455.00|Yes
        2026-08-07|07/08/2026|Friday|Vineyard block pruning|2|2|2|complete|block 2 of 2|\
        Primitivo|Primitivo|2.00|80.00|10.40|364.00|||No
        """)
    }
}
