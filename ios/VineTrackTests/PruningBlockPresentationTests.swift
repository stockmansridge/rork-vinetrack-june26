import Foundation
import Testing
@testable import VineTrack

@Suite("Pruning block presentation")
struct PruningBlockPresentationTests {
    private static let vineyardID = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
    private static let blockID = UUID(uuidString: "00000000-0000-0000-0000-0000000000ab")!
    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    private static func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day))!
    }

    private static func rowID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private static func row(_ number: Int, originalNumber: Int? = nil, metres: Double) -> PaddockRow {
        let longitude = 150.0 + Double(originalNumber ?? number) * 0.001
        return PaddockRow(
            id: rowID(originalNumber ?? number),
            number: number,
            startPoint: CoordinatePoint(latitude: 0, longitude: longitude),
            endPoint: CoordinatePoint(latitude: metres / 111_320.0, longitude: longitude)
        )
    }

    private static var block: Paddock {
        Paddock(
            id: blockID,
            vineyardId: vineyardID,
            name: "Cab Franc",
            rows: [row(50, metres: 100), row(47, metres: 200), row(42, metres: 200)],
            rowWidth: 2.5,
            vineSpacing: 1,
            vineCountOverride: 500
        )
    }

    private static var setup: PruningBlockSetup {
        PruningBlockSetup(
            vineyardId: vineyardID,
            paddockId: blockID,
            seasonYear: 2026,
            startDate: date(1),
            dueDate: date(31),
            crew: "Crew A"
        )
    }

    private static func segment(_ row: Int, _ quarter: Int, legacy: Bool = false) -> PruningSegment {
        PruningSegment(rowId: legacy ? nil : rowID(row), row: row, quarter: quarter)
    }

    private static func entry(
        _ number: Int,
        day: Int,
        segments: [PruningSegment],
        skipped: Bool = false,
        reversed: Bool = false,
        paddockID: UUID = PruningBlockPresentationTests.blockID
    ) -> PruningEntry {
        PruningEntry(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", number))!,
            vineyardId: vineyardID,
            paddockId: paddockID,
            seasonId: setup.id,
            date: date(day),
            segments: segments,
            worker: skipped ? "" : "Crew A",
            labourHours: skipped ? nil : 4,
            createdAt: date(1),
            reversedAt: reversed ? date(15) : nil,
            skipped: skipped
        )
    }

    private static var entries: [PruningEntry] {
        [
            entry(1, day: 14, segments: [segment(42, 3), segment(47, 2)]),
            entry(2, day: 14, segments: [segment(47, 1), segment(47, 2)], skipped: true),
            entry(3, day: 13, segments: [segment(42, 1), segment(42, 2)]),
            entry(4, day: 12, segments: [segment(50, 4, legacy: true)])
        ]
    }

    private static func prepare(
        block: Paddock = PruningBlockPresentationTests.block,
        setup: PruningBlockSetup? = PruningBlockPresentationTests.setup,
        entries: [PruningEntry] = PruningBlockPresentationTests.entries,
        editingEntry: PruningEntry? = nil,
        asOf: Date = PruningBlockPresentationTests.date(14)
    ) -> PruningBlockPresentation {
        PruningBlockPresentation.prepare(
            paddock: block,
            setup: setup,
            entries: entries,
            editingEntry: editingEntry,
            calendar: calendar,
            asOf: asOf
        )
    }

    /// Compare every field of the existing metric contract; the view change
    /// must not replace the calculator or silently omit one of its results.
    private static func expectSameMetrics(_ actual: PruningBlockMetrics, _ expected: PruningBlockMetrics) {
        #expect(actual.rows == expected.rows)
        #expect(actual.rowCount == expected.rowCount)
        #expect(actual.completed == expected.completed)
        #expect(actual.pruned == expected.pruned)
        #expect(actual.skipped == expected.skipped)
        #expect(actual.vinesPruned == expected.vinesPruned)
        #expect(actual.vinesSkipped == expected.vinesSkipped)
        #expect(actual.vinesTotal == expected.vinesTotal)
        #expect(actual.projectedFinish == expected.projectedFinish)
        #expect(actual.status == expected.status)
        #expect(actual.hasSkippedSections == expected.hasSkippedSections)

        let actualScalars = [
            actual.completedRowEquivalents, actual.prunedRowEquivalents,
            actual.skippedRowEquivalents, actual.totalRowEquivalents,
            actual.fractionComplete, actual.fractionPruned, actual.fractionSkipped,
            actual.vinesPerRow, actual.vinesPrunedExact, actual.vinesSkippedExact,
            actual.averageRowLength, actual.completionAreaHa, actual.workedAreaHa
        ]
        let expectedScalars = [
            expected.completedRowEquivalents, expected.prunedRowEquivalents,
            expected.skippedRowEquivalents, expected.totalRowEquivalents,
            expected.fractionComplete, expected.fractionPruned, expected.fractionSkipped,
            expected.vinesPerRow, expected.vinesPrunedExact, expected.vinesSkippedExact,
            expected.averageRowLength, expected.completionAreaHa, expected.workedAreaHa
        ]
        for (actualValue, expectedValue) in zip(actualScalars, expectedScalars) {
            #expect(abs(actualValue - expectedValue) < 1e-9)
        }
        for (actualValue, expectedValue) in zip(
            [actual.ratePerWorkday, actual.timeElapsedFraction],
            [expected.ratePerWorkday, expected.timeElapsedFraction]
        ) {
            if let actualValue, let expectedValue {
                #expect(abs(actualValue - expectedValue) < 1e-9)
            } else {
                #expect(actualValue == nil && expectedValue == nil)
            }
        }
    }

    private static func expectMatchesExistingPreparation(
        _ result: PruningBlockPresentation,
        block: Paddock = PruningBlockPresentationTests.block,
        setup: PruningBlockSetup? = PruningBlockPresentationTests.setup,
        entries: [PruningEntry] = PruningBlockPresentationTests.entries,
        editingEntry: PruningEntry? = nil,
        asOf: Date = PruningBlockPresentationTests.date(14)
    ) {
        let original = PruningCalculator.metrics(
            paddock: block, setup: setup, entries: entries, calendar: calendar, asOf: asOf
        )
        expectSameMetrics(result.metrics, original)
        #expect(result.setup == setup)
        #expect(result.entries == entries)
        let unlocked = editingEntry.map {
            PruningCalculator.completedSegments(entries: [$0], rows: original.rows)
        } ?? []
        #expect(result.lockedSegments == original.completed.subtracting(unlocked))
        #expect(result.completionDates == PruningCalculator.segmentCompletionDates(entries: entries, rows: original.rows))
    }

    @Test("One presentation retains the complete existing metric and date contract")
    func completeMetricsAndCompletionDatesMatchExistingCalculations() {
        let result = Self.prepare()
        Self.expectMatchesExistingPreparation(result)
        #expect(result.metrics.rows.map(\.number) == [42, 47, 50])
        #expect(result.metrics.completed.count == 6)
        #expect(result.metrics.pruned.count == 5)
        #expect(result.metrics.skipped == [Self.segment(47, 1)])
        #expect(abs(result.metrics.vinesPrunedExact - 225) < 1e-9)
        #expect(abs(result.metrics.vinesSkippedExact - 50) < 1e-9)
        #expect(result.completionDates[Self.segment(42, 1)] == Self.date(13))
        #expect(result.completionDates[Self.segment(47, 2)] == Self.date(14))
    }

    @Test("Editing unlocks the entry's canonical quarters and retains other locks")
    func editingUnlockingMatchesTheExistingRule() {
        let editing = Self.entries[2]
        let result = Self.prepare(editingEntry: editing)
        Self.expectMatchesExistingPreparation(result, editingEntry: editing)
        #expect(!result.lockedSegments.contains(Self.segment(42, 1)))
        #expect(!result.lockedSegments.contains(Self.segment(42, 2)))
        #expect(result.lockedSegments.contains(Self.segment(42, 3)))
        #expect(result.lockedSegments.contains(Self.segment(47, 1)))

        let cancelled = Self.prepare()
        #expect(cancelled.lockedSegments.contains(Self.segment(42, 1)))
        #expect(cancelled.lockedSegments == cancelled.metrics.completed)
    }

    @Test("Stable row identity survives renumbering and removed rows stay absent")
    func renamedReorderedAndDeletedRowsUseExistingCanonicalisation() {
        let changedBlock = Paddock(
            id: Self.blockID,
            vineyardId: Self.vineyardID,
            name: "Renamed block",
            rows: [Self.row(100, originalNumber: 42, metres: 200), Self.row(50, metres: 100)],
            rowWidth: 2.5,
            vineSpacing: 1,
            vineCountOverride: 500
        )
        let result = Self.prepare(block: changedBlock, editingEntry: Self.entries[2])
        Self.expectMatchesExistingPreparation(result, block: changedBlock, editingEntry: Self.entries[2])
        #expect(result.metrics.rows.map(\.number) == [50, 100])
        #expect(result.metrics.rows.map(\.id) == [Self.rowID(50), Self.rowID(42)].map { $0.uuidString.lowercased() })
        #expect(result.metrics.completed.filter { $0.rowId == Self.rowID(42) }.allSatisfy { $0.row == 100 })
        #expect(!result.metrics.completed.contains { $0.rowId == Self.rowID(47) })
        #expect(!result.lockedSegments.contains(Self.segment(42, 1)))
        #expect(result.metrics.completed.contains(Self.segment(50, 4)))
    }

    @Test("Fallback row-count updates and missing setup rebuild the current display")
    func fallbackAndMissingSetupRemainDistinct() {
        let block = Paddock(id: Self.blockID, vineyardId: Self.vineyardID, name: "Fallback", rows: [], vineCountOverride: 400)
        var setup = Self.setup
        setup.rowCountOverride = 4
        let entries = [Self.entry(5, day: 14, segments: [Self.segment(3, 1, legacy: true)])]
        let initial = Self.prepare(block: block, setup: setup, entries: entries)
        Self.expectMatchesExistingPreparation(initial, block: block, setup: setup, entries: entries)
        #expect(initial.metrics.rows.map(\.number) == [1, 2, 3, 4])
        #expect(initial.metrics.rows.allSatisfy(\.isFallback))
        #expect(initial.metrics.completed.count == 1)

        setup.rowCountOverride = 2
        let changed = Self.prepare(block: block, setup: setup, entries: entries)
        Self.expectMatchesExistingPreparation(changed, block: block, setup: setup, entries: entries)
        #expect(changed.metrics.rowCount == 2)
        #expect(changed.metrics.completed.isEmpty)

        let unconfigured = Self.prepare(block: block, setup: nil, entries: entries)
        Self.expectMatchesExistingPreparation(unconfigured, block: block, setup: nil, entries: entries)
        #expect(unconfigured.metrics.rows.isEmpty)
        #expect(unconfigured.completionDates.isEmpty)
    }

    @Test("The production store still excludes reversed and other-block records")
    @MainActor
    func currentStoreSelectionPreservesReversalAndBlockScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pruning-presentation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let reversed = Self.entry(6, day: 15, segments: [Self.segment(50, 1)], reversed: true)
        let otherBlock = Self.entry(7, day: 15, segments: [Self.segment(50, 2)], paddockID: UUID())
        try persistence.saveOrThrow(Self.entries + [reversed, otherBlock], key: "vinetrack_pruning_entries_v2")
        let store = PruningStore(persistence: persistence)
        let currentEntries = store.entries(for: Self.blockID)
        let result = Self.prepare(entries: currentEntries)
        Self.expectMatchesExistingPreparation(result, entries: currentEntries)
        #expect(result.entries.map(\.id) == currentEntries.map(\.id))
        #expect(!result.entries.contains { $0.id == reversed.id || $0.id == otherBlock.id })
        #expect(!result.metrics.completed.contains(Self.segment(50, 1)))
        #expect(!result.metrics.completed.contains(Self.segment(50, 2)))
    }

    @Test("New inputs and a new current time replace earlier presentation values")
    func subsequentPreparationUsesCurrentEntriesSetupAndTime() {
        let initial = Self.prepare()
        let added = Self.entry(8, day: 15, segments: [Self.segment(50, 1)])
        var setup = Self.setup
        setup.crew = "Crew B"
        let entries = [added] + Self.entries
        let refreshed = Self.prepare(setup: setup, entries: entries, asOf: Self.date(15))
        Self.expectMatchesExistingPreparation(refreshed, setup: setup, entries: entries, asOf: Self.date(15))
        #expect(refreshed.setup?.crew == "Crew B")
        #expect(!initial.lockedSegments.contains(Self.segment(50, 1)))
        #expect(refreshed.lockedSegments.contains(Self.segment(50, 1)))
        #expect(refreshed.completionDates[Self.segment(50, 1)] == Self.date(15))
        #expect((refreshed.metrics.timeElapsedFraction ?? 0) > (initial.metrics.timeElapsedFraction ?? 0))

        // The live action getter supplies fresh rows/completions to this same
        // rule, so it does not use the earlier render's unlocked set.
        let currentRows = PruningCalculator.rowRefs(paddock: Self.block, setup: setup)
        let currentCompleted = PruningCalculator.completedSegments(entries: entries, rows: currentRows)
        let liveLocks = PruningBlockPresentation.lockedSegments(completed: currentCompleted, editingEntry: nil, rows: currentRows)
        #expect(liveLocks == refreshed.lockedSegments)
        #expect(liveLocks != initial.lockedSegments)
    }
}
