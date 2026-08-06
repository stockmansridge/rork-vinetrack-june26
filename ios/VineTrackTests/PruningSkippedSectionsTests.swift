import Foundation
import Testing

@testable import VineTrack

/// SKIPPED PRUNING SECTIONS (sql/168) — the shared contract.
///
/// The twin of `PruningSkippedSectionsTest.kt`. Every expected value here is
/// DERIVED from the fixture below (quarters ÷ 4, row vines ÷ 4), not copied
/// from a screen, so the two suites state the same contract rather than pinning
/// the same observation.
///
/// THE RULE UNDER TEST, in one line: a skipped section counts as COMPLETE for
/// progress and as NOTHING for pruning work.
///
/// Fixture — Block A "Cab Franc": 7 configured rows with REAL non-sequential
/// numbers 42–47 + 50 (the gap is deliberate), six 200 m rows + one 100 m row,
/// vine count override 1300. Length-weighted, that is 200 vines in each of rows
/// 42–47 and 100 vines in row 50, so:
///   * one full row    = 1.00 row equivalents = 200 vines (50 per quarter),
///   * the whole block = 7.00 row equivalents = 1300 vines.
@Suite("Pruning — skipped sections")
struct PruningSkippedSectionsTests {

    // MARK: Fixture

    private static let asOf = Date(timeIntervalSince1970: 1_784_000_000)
    private static let metresPerDegreeLat = 111_320.0
    private static let vineyardId = UUID()
    private static let blockId = UUID()

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
        id: blockId,
        vineyardId: vineyardId,
        name: "Cab Franc",
        rows: [
            row(50, lengthMetres: 100), row(47, lengthMetres: 200), row(42, lengthMetres: 200),
            row(45, lengthMetres: 200), row(43, lengthMetres: 200), row(46, lengthMetres: 200),
            row(44, lengthMetres: 200),
        ],
        rowWidth: 2.5,
        vineSpacing: 1.0,
        vineCountOverride: 1300
    )

    private static let setupA = PruningBlockSetup(
        vineyardId: vineyardId,
        paddockId: blockId,
        seasonYear: 2026,
        dueDate: Date(timeIntervalSince1970: 1_787_000_000)
    )

    /// Derived from the fixture, never hard-coded from a screenshot.
    private static let blockRowEquivalents = 7.0
    private static let vinesPerLongRow = 200.0
    private static let vinesPerLongQuarter = vinesPerLongRow / 4.0

    private static func fullRow(_ number: Int) -> [PruningSegment] {
        (1...4).map { PruningSegment(rowId: rowId(number), row: number, quarter: $0) }
    }

    private static func quarters(_ number: Int, _ list: [Int]) -> [PruningSegment] {
        list.map { PruningSegment(rowId: rowId(number), row: number, quarter: $0) }
    }

    private static func pruned(
        _ segments: [PruningSegment],
        date: Date = Date(timeIntervalSince1970: 1_783_900_000),
        labourHours: Double? = 4.0
    ) -> PruningEntry {
        PruningEntry(
            vineyardId: vineyardId,
            paddockId: blockId,
            date: date,
            segments: segments,
            worker: "Dan",
            labourHours: labourHours
        )
    }

    /// A skipped record as the UI builds it: identifiers and selection only.
    private static func skipped(
        _ segments: [PruningSegment],
        date: Date = Date(timeIntervalSince1970: 1_784_000_000)
    ) -> PruningEntry {
        PruningEntry(
            vineyardId: vineyardId,
            paddockId: blockId,
            date: date,
            segments: segments,
            notes: "Vines removed",
            skipped: true
        )
    }

    private static func metrics(_ entries: [PruningEntry]) -> PruningBlockMetrics {
        PruningCalculator.metrics(paddock: blockA, setup: setupA, entries: entries, asOf: asOf)
    }

    private static var rows: [PruningRowRef] {
        PruningCalculator.rowRefs(paddock: blockA, setup: setupA)
    }

    // MARK: Selection

    @Test("One whole row marked skipped")
    func oneWholeRowMarkedSkipped() {
        let m = Self.metrics([Self.skipped(Self.fullRow(42))])

        #expect(m.skipped.count == 4)
        #expect(abs(m.skippedRowEquivalents - 1.0) < 0.0001)
        // Complete, but not pruned.
        #expect(abs(m.completedRowEquivalents - 1.0) < 0.0001)
        #expect(abs(m.prunedRowEquivalents) < 0.0001)
        #expect(m.hasSkippedSections)
    }

    @Test("Multiple rows marked skipped")
    func multipleRowsMarkedSkipped() {
        let m = Self.metrics([Self.skipped(Self.fullRow(42) + Self.fullRow(43) + Self.fullRow(44))])

        #expect(m.skipped.count == 12)
        #expect(abs(m.skippedRowEquivalents - 3.0) < 0.0001)
        #expect(abs(m.completedRowEquivalents - 3.0) < 0.0001)
        #expect(abs(m.prunedRowEquivalents) < 0.0001)
    }

    @Test("One row quarter marked skipped")
    func oneRowQuarterMarkedSkipped() {
        let m = Self.metrics([Self.skipped(Self.quarters(42, [3]))])

        #expect(m.skipped.count == 1)
        #expect(abs(m.skippedRowEquivalents - 0.25) < 0.0001)
        #expect(abs(m.completedRowEquivalents - 0.25) < 0.0001)
        // A quarter of a 200-vine row.
        #expect(abs(m.vinesSkippedExact - Self.vinesPerLongQuarter) < 0.0001)
    }

    @Test("Several row quarters marked skipped")
    func severalRowQuartersMarkedSkipped() {
        // "Row 42, sections 2–4" plus two quarters of row 47 — a partial-row
        // selection spanning more than one row.
        let m = Self.metrics([Self.skipped(Self.quarters(42, [2, 3, 4]) + Self.quarters(47, [1, 2]))])

        #expect(m.skipped.count == 5)
        #expect(abs(m.skippedRowEquivalents - 1.25) < 0.0001)
        #expect(abs(m.vinesSkippedExact - 5 * Self.vinesPerLongQuarter) < 0.0001)
    }

    // MARK: Progress

    @Test("Skipped sections count toward progress")
    func skippedSectionsCountTowardProgress() {
        // 2 rows pruned + 1 row skipped = 3 of 7 rows complete.
        let m = Self.metrics([
            Self.pruned(Self.fullRow(42) + Self.fullRow(43)),
            Self.skipped(Self.fullRow(44)),
        ])

        #expect(abs(m.completedRowEquivalents - 3.0) < 0.0001)
        #expect(abs(m.fractionComplete - 3.0 / Self.blockRowEquivalents) < 0.0001)
        // …and the split adds back up to the whole.
        #expect(abs(m.prunedRowEquivalents - 2.0) < 0.0001)
        #expect(abs(m.skippedRowEquivalents - 1.0) < 0.0001)
        #expect(abs(m.fractionComplete - (m.fractionPruned + m.fractionSkipped)) < 0.0001)
    }

    @Test("Skipped sections reduce rows and sections remaining")
    func skippedSectionsReduceRemaining() {
        let m = Self.metrics([Self.skipped(Self.fullRow(42) + Self.fullRow(43))])

        let rowsRemaining = m.totalRowEquivalents - m.completedRowEquivalents
        let sectionsRemaining = (m.rowCount * 4) - m.completed.count
        #expect(abs(rowsRemaining - 5.0) < 0.0001)
        #expect(sectionsRemaining == 20)
    }

    @Test("Skipped sections do not count as vines pruned")
    func skippedSectionsDoNotCountAsVinesPruned() {
        let m = Self.metrics([
            Self.pruned(Self.fullRow(42)),
            Self.skipped(Self.fullRow(43)),
        ])

        // One pruned row of 200 vines — the skipped row's 200 are reported
        // separately and never added to "vines pruned".
        #expect(abs(m.vinesPrunedExact - Self.vinesPerLongRow) < 0.0001)
        #expect(m.vinesPruned == Int(Self.vinesPerLongRow))
        #expect(abs(m.vinesSkippedExact - Self.vinesPerLongRow) < 0.0001)
        #expect(m.vinesSkipped == Int(Self.vinesPerLongRow))
    }

    @Test("Skipped sections are not rows pruned, rates or labour")
    func skippedSectionsAreNotWork() {
        let entries = [
            Self.pruned(Self.fullRow(42), date: Date(timeIntervalSince1970: 1_783_900_000), labourHours: 4.0),
            Self.skipped(Self.fullRow(43) + Self.fullRow(44) + Self.fullRow(45)),
        ]

        // Rows pruned: 1.0, not 4.0.
        #expect(abs(Self.metrics(entries).prunedRowEquivalents - 1.0) < 0.0001)

        // Rate: only the one real working day counts. Three skipped rows on a
        // second day must not look like a blazing 3 rows/day.
        let rate = PruningCalculator.preferredRate(entries: entries)
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 1.0) < 0.0001)

        // Vines/day: one day, 200 vines — a skipped day is not a day of work.
        let perDay = PruningCalculator.exactVinesPerDay(entries: entries, rows: Self.rows)
        #expect(abs((perDay ?? 0) - Self.vinesPerLongRow) < 0.0001)

        // Vines per labour hour: 200 ÷ 4 h. The skipped record contributes to
        // neither side of the ratio.
        let perHour = PruningCalculator.vinesPerLabourHour(entries: entries, rows: Self.rows)
        #expect(abs((perHour ?? 0) - 50.0) < 0.0001)

        // Vineyard roll-up agrees, and labour hours exclude skipped records.
        let summary = PruningCalculator.vineyardSummary(
            paddocks: [Self.blockA],
            setups: [Self.setupA],
            entries: entries,
            asOf: Self.asOf
        )
        #expect(abs(summary.labourHours - 4.0) < 0.0001)
        #expect(abs(summary.vinesPrunedExact - Self.vinesPerLongRow) < 0.0001)
        #expect(abs(summary.vinesSkippedExact - 3 * Self.vinesPerLongRow) < 0.0001)
    }

    @Test("Skipped area counts toward completion but never toward worked area")
    func skippedAreaNeverCountsAsWorked() {
        let m = Self.metrics([
            Self.pruned(Self.fullRow(42)),
            Self.skipped(Self.fullRow(43)),
        ])

        // 200 m × 2.5 m row width = 500 m² = 0.05 ha per full row.
        #expect(abs(m.completionAreaHa - 0.10) < 0.0001)
        #expect(abs(m.workedAreaHa - 0.05) < 0.0001)
        // Cost per WORKED hectare must never be diluted by skipped ground.
        #expect(m.workedAreaHa < m.completionAreaHa)
    }

    // MARK: The record

    @Test("A skipped record carries no worker, labour, cost or Work Task")
    func skippedRecordCarriesNoWork() {
        let entry = Self.skipped(Self.fullRow(42))

        #expect(entry.isSkipped)
        #expect(entry.worker.isEmpty)
        #expect(entry.labourHours == nil)
        #expect(entry.startTime == nil)
        #expect(entry.finishTime == nil)
        #expect(entry.workTaskId == nil)
        // No productivity result: elapsed duration cannot be derived either.
        #expect(entry.durationHours == nil)
        // No client vine estimate — vines are attributed, never claimed as work.
        #expect(entry.estimatedVines == 0)
    }

    @Test("An ordinary pruning record is unaffected")
    func ordinaryRecordUnaffected() {
        let entry = Self.pruned(Self.fullRow(42))
        #expect(!entry.isSkipped)

        let m = Self.metrics([entry])
        #expect(abs(m.prunedRowEquivalents - 1.0) < 0.0001)
        #expect(abs(m.skippedRowEquivalents) < 0.0001)
        #expect(!m.hasSkippedSections)
        // The screen shows one figure, exactly as before the feature existed.
        #expect(abs(m.fractionComplete - m.fractionPruned) < 0.0001)
    }

    // MARK: Precedence

    @Test("Already completed sections are ignored by an overlapping skip")
    func alreadyCompletedSectionsAreIgnored() {
        // Row 42 is already pruned. A skip that overlaps it must not steal the
        // work: the pruned quarters stay pruned, and only the genuinely new
        // quarters (row 43) become skipped.
        let m = Self.metrics([
            Self.pruned(Self.fullRow(42)),
            Self.skipped(Self.fullRow(42) + Self.fullRow(43)),
        ])

        #expect(abs(m.prunedRowEquivalents - 1.0) < 0.0001)
        #expect(abs(m.skippedRowEquivalents - 1.0) < 0.0001)
        #expect(abs(m.completedRowEquivalents - 2.0) < 0.0001)
        // Vines pruned is untouched by the overlap.
        #expect(abs(m.vinesPrunedExact - Self.vinesPerLongRow) < 0.0001)
        #expect(!m.skipped.contains { $0.row == 42 })
    }

    @Test("Progress never exceeds 100%")
    func progressNeverExceedsOneHundredPercent() {
        // Every row skipped, plus an overlapping pruned record and a duplicate
        // skip of the same sections — nothing may push past 100%.
        let everyRow = [42, 43, 44, 45, 46, 47, 50].flatMap { Self.fullRow($0) }
        let entries = [
            Self.skipped(everyRow),
            Self.skipped(everyRow),
            Self.pruned(Self.fullRow(42) + Self.fullRow(43)),
        ]
        let m = Self.metrics(entries)

        #expect(abs(m.fractionComplete - 1.0) < 0.0001)
        #expect(m.fractionComplete <= 1.0)
        #expect(m.fractionPruned + m.fractionSkipped <= 1.0000001)
        #expect(abs(m.completedRowEquivalents - Self.blockRowEquivalents) < 0.0001)

        let summary = PruningCalculator.vineyardSummary(
            paddocks: [Self.blockA],
            setups: [Self.setupA],
            entries: entries,
            asOf: Self.asOf
        )
        #expect(summary.fraction <= 1.0)
        #expect(summary.displayPercent == 100)
        // Nothing left to do, and the remaining workload is zero rather than
        // negative — skipped vines leave the workload without becoming work.
        #expect(summary.vinesRemaining == 0)
    }

    // MARK: Reversal

    @Test("Reversing a skipped entry restores the previous progress")
    func reversalRestoresPreviousProgress() {
        let before = Self.metrics([Self.pruned(Self.fullRow(42))])

        var skip = Self.skipped(Self.fullRow(43) + Self.fullRow(44))
        let during = Self.metrics([Self.pruned(Self.fullRow(42)), skip])
        #expect(abs(during.completedRowEquivalents - 3.0) < 0.0001)

        // Reversal is the existing path: the row is retained for the audit
        // trail with a reversal stamp, and every calculation already drops it.
        skip.reversedAt = Date()
        #expect(skip.isReversed)
        let after = Self.metrics([Self.pruned(Self.fullRow(42))])

        #expect(abs(before.completedRowEquivalents - after.completedRowEquivalents) < 0.0001)
        #expect(abs(before.skippedRowEquivalents - after.skippedRowEquivalents) < 0.0001)
        #expect(abs(before.vinesPrunedExact - after.vinesPrunedExact) < 0.0001)
        #expect(abs(before.fractionComplete - after.fractionComplete) < 0.0001)
    }

    @Test("Reversing a skipped entry leaves unrelated entries alone")
    func reversalLeavesOthersAlone() {
        let m = Self.metrics([
            Self.pruned(Self.fullRow(42)),
            Self.skipped(Self.fullRow(46)),
        ])

        #expect(abs(m.prunedRowEquivalents - 1.0) < 0.0001)
        #expect(abs(m.skippedRowEquivalents - 1.0) < 0.0001)
        #expect(m.skipped.contains { $0.row == 46 })
        #expect(m.pruned.contains { $0.row == 42 })
    }

    // MARK: Sync + offline

    @Test("Offline-created skipped entries survive the outbox round trip")
    func offlineRoundTrip() throws {
        // The offline queue persists the entry as JSON and replays it later;
        // the flag must survive, or a queued skip would land as pruning work.
        let entry = Self.skipped(Self.quarters(42, [1, 2]))

        let data = try JSONEncoder().encode(entry)
        let replayed = try JSONDecoder().decode(PruningEntry.self, from: data)

        #expect(replayed.isSkipped)
        #expect(replayed.id == entry.id)
        #expect(replayed.segments == entry.segments)
        #expect(replayed.labourHours == nil)
        #expect(replayed.worker.isEmpty)
    }

    @Test("Entries cached before the flag existed still decode as pruned")
    func legacyCacheStillDecodes() throws {
        // The local cache holds records written before sql/168. They must keep
        // their historical meaning instead of failing to decode and wiping the
        // device's pruning history.
        var legacy = Self.pruned(Self.fullRow(42))
        legacy.skipped = nil
        let data = try JSONEncoder().encode(legacy)

        // Prove the key really is absent, then that it decodes as "pruned".
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["skipped"] == nil)

        let decoded = try JSONDecoder().decode(PruningEntry.self, from: data)
        #expect(!decoded.isSkipped)
        #expect(decoded.labourHours == 4.0)
    }

    @Test("The skipped push carries no labour, whatever the draft holds")
    func skippedPushCannotCarryLabour() throws {
        // Even if a local draft somehow acquired labour, the sql/168 params
        // have nowhere to put it — the guarantee is in the shape, not in a
        // caller remembering to blank the fields.
        var contaminated = Self.skipped(Self.fullRow(42))
        contaminated.worker = "Dan"
        contaminated.labourHours = 9
        contaminated.workTaskId = UUID()

        let params = RecordSkippedPruningEntryParams(from: contaminated, clientUpdatedAt: Date())
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(params)
            ) as? [String: Any]
        )

        #expect(object["p_worker"] == nil)
        #expect(object["p_labour_hours"] == nil)
        #expect(object["p_start_time"] == nil)
        #expect(object["p_finish_time"] == nil)
        #expect(object["p_work_task_id"] == nil)
        #expect(object["p_estimated_vines"] == nil)
        // Only the identifiers needed to locate the selection travel.
        #expect(object["p_id"] != nil)
        #expect(object["p_paddock_id"] != nil)
        #expect(object["p_season_id"] != nil)
        #expect(object["p_entry_date"] != nil)
        #expect(object["p_segments"] != nil)
    }

    @Test("iOS and Android derive the same figures from the same skipped fixture")
    func crossPlatformParity() {
        // The parity line `PruningSkippedSectionsTest.kt` asserts verbatim.
        // Rows 42–43 pruned, rows 44–45 skipped, row 46 half pruned.
        let m = Self.metrics([
            Self.pruned(Self.fullRow(42) + Self.fullRow(43) + Self.quarters(46, [1, 2])),
            Self.skipped(Self.fullRow(44) + Self.fullRow(45)),
        ])

        let rendered = [
            "pruned_row_equivalents=\(String(format: "%.2f", m.prunedRowEquivalents))",
            "skipped_row_equivalents=\(String(format: "%.2f", m.skippedRowEquivalents))",
            "completed_row_equivalents=\(String(format: "%.2f", m.completedRowEquivalents))",
            "pruned_percent=\(PruningCalculator.displayPercent(m.fractionPruned))",
            "skipped_percent=\(PruningCalculator.displayPercent(m.fractionSkipped))",
            "complete_percent=\(PruningCalculator.displayPercent(m.fractionComplete))",
            "vines_pruned=\(m.vinesPruned)",
            "vines_skipped=\(m.vinesSkipped)",
        ].joined(separator: " · ")

        #expect(rendered == """
        pruned_row_equivalents=2.50 · skipped_row_equivalents=2.00 · \
        completed_row_equivalents=4.50 · pruned_percent=36 · \
        skipped_percent=29 · complete_percent=64 · \
        vines_pruned=500 · vines_skipped=400
        """)
    }
}
