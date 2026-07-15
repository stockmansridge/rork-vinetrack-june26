package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningCalculator
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.PruningStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import kotlin.math.roundToInt

/**
 * SHARED PRUNING CALCULATION FIXTURE — the same deterministic fixture exists
 * as `PruningCalculatorFixtureTests.swift` in the iOS test target, and its
 * rules are the documented SQL 115 contract (`get_pruning_vineyard_summary`,
 * docs/pruning-fertiliser-sync.md). All three implementations must produce
 * these exact unrounded values before display formatting.
 *
 * Fixture (as of 2026-07-14):
 *  * Block A "Cab Franc": 7 configured rows with REAL non-sequential numbers
 *    42–47 + 50 (gap preserved), six 200 m rows + one 100 m row, vine count
 *    override 1300 → row vines 200/200/200/200/200/200/100.
 *    Completed: rows 42–45 full + row 46 Q1+Q2 = 18 quarters = 4.5 row eq,
 *    900.0 exact vines, recorded across two entries
 *    (13 Jul: 8 quarters / 4 h · 14 Jul: 10 quarters / 8 h person-hours).
 *  * Block B "Fallback": no configured rows, manual row count 4, vine count
 *    override 400 → four generated fallback rows of 100 vines.
 *
 * Expected: block A 64 %, ahead, projected 2026-07-15; vineyard 41 %,
 * 900 / 1700 vines, 450 vines/day, 75 vines/labour-hour.
 */
class PruningCalculatorFixtureTest {

    private val asOf: LocalDate = LocalDate.parse("2026-07-14")

    private val metresPerDegreeLat = 111_320.0

    private fun rowId(number: Int): String =
        "00000000-0000-0000-0000-0000000000${number}"

    private fun row(number: Int, lengthMetres: Double): PaddockRow {
        val lon = 150.0 + number * 0.001
        return PaddockRow(
            id = rowId(number),
            number = number,
            startPoint = CoordinatePoint(latitude = 0.0, longitude = lon),
            endPoint = CoordinatePoint(latitude = lengthMetres / metresPerDegreeLat, longitude = lon),
        )
    }

    private val blockA = Paddock(
        id = "block-a",
        vineyardId = "v",
        name = "Cab Franc",
        vineSpacing = 1.0,
        vineCountOverride = 1300,
        // Stored intentionally out of order — rowRefs must sort ascending by number.
        rows = listOf(
            row(50, 100.0), row(47, 200.0), row(42, 200.0),
            row(45, 200.0), row(43, 200.0), row(46, 200.0),
            row(44, 200.0),
        ),
    )

    private val blockB = Paddock(
        id = "block-b",
        vineyardId = "v",
        name = "Fallback",
        vineCountOverride = 400,
        rows = null,
    )

    private val setupA = PruningBlockSetup(
        id = "season-a",
        vineyardId = "v",
        paddockId = "block-a",
        seasonYear = 2026,
        startDate = "2026-07-01",
        dueDate = "2026-08-15",
        workingDays = listOf(1, 2, 3, 4, 5),
    )

    private val setupB = PruningBlockSetup(
        id = "season-b",
        vineyardId = "v",
        paddockId = "block-b",
        seasonYear = 2026,
        rowCountOverride = 4,
    )

    private fun fullRow(number: Int): List<PruningSegment> =
        (1..4).map { PruningSegment(row = number, quarter = it, rowId = rowId(number)) }

    private val entry1 = PruningEntry(
        id = "e1",
        vineyardId = "v",
        paddockId = "block-a",
        seasonId = "season-a",
        date = "2026-07-13",
        segments = fullRow(42) + fullRow(43),
        labourHours = 4.0,
    )

    private val entry2 = PruningEntry(
        id = "e2",
        vineyardId = "v",
        paddockId = "block-a",
        seasonId = "season-a",
        date = "2026-07-14",
        segments = fullRow(44) + fullRow(45) + listOf(
            PruningSegment(row = 46, quarter = 1, rowId = rowId(46)),
            PruningSegment(row = 46, quarter = 2, rowId = rowId(46)),
        ),
        labourHours = 8.0,
    )

    private val entries = listOf(entry1, entry2)

    // MARK: Row identity

    @Test
    fun rowRefs_sortAscendingAndPreserveActualNonSequentialNumbers() {
        val rows = PruningCalculator.rowRefs(blockA, setupA)
        // Input is stored out of order; refs must come back lowest → highest.
        assertEquals(listOf(42, 43, 44, 45, 46, 47, 50), rows.map { it.number })
        assertTrue(rows.none { it.isFallback })
        // Row 48/49 must NOT be invented; row vines follow each row's length.
        assertEquals(200.0, rows.first { it.number == 42 }.vines, 1e-6)
        assertEquals(100.0, rows.first { it.number == 50 }.vines, 1e-6)
        assertEquals(1300.0, rows.sumOf { it.vines }, 1e-6)
    }

    @Test
    fun rowRefs_manualFallbackOnlyWhenNoConfiguredRows() {
        val rows = PruningCalculator.rowRefs(blockB, setupB)
        assertEquals(listOf(1, 2, 3, 4), rows.map { it.number })
        assertTrue(rows.all { it.isFallback })
        assertEquals(100.0, rows[0].vines, 1e-6)
    }

    // MARK: Block metrics (SQL 115 contract)

    @Test
    fun blockA_metricsMatchSharedContract() {
        val m = PruningCalculator.metrics(blockA, setupA, entries, asOf)
        assertEquals(7, m.rowCount)
        assertEquals(4.5, m.completedRowEquivalents, 1e-9)
        assertEquals(7.0, m.totalRowEquivalents, 1e-9)
        // displayPercent = round(fraction × 100) half up — 64.28… → 64.
        assertEquals(64, PruningCalculator.displayPercent(m.fractionComplete))
        // Exact quarter vines summed at full precision, rounded ONCE: 900.
        assertEquals(900.0, m.vinesPrunedExact, 1e-6)
        assertEquals(900, m.vinesPruned)
        assertEquals(1300, m.vinesTotal)
        // Rolling rate: mean row-eq/day over the 3 most recent days-with-entries.
        assertEquals(2.25, m.ratePerWorkday ?: 0.0, 1e-9)
        // ceil(2.5 / 2.25) = 2 working days from 14 Jul (Tue counts) → 15 Jul.
        assertEquals(LocalDate.parse("2026-07-15"), m.projectedFinish)
        // Projected > 3 days before the 15 Aug due date → Ahead.
        assertEquals(PruningStatus.Ahead, m.status)
    }

    @Test
    fun blockB_noEntries_isNotStartedWithoutRate() {
        val m = PruningCalculator.metrics(blockB, setupB, emptyList(), asOf)
        assertEquals(4, m.rowCount)
        assertEquals(0.0, m.completedRowEquivalents, 1e-9)
        assertEquals(PruningStatus.NotStarted, m.status)
        assertNull(m.ratePerWorkday)
        assertNull(m.projectedFinish)
    }

    // MARK: Vineyard summary (SQL 115 contract)

    @Test
    fun vineyardSummary_matchesSharedContract() {
        val s = PruningCalculator.vineyardSummary(
            paddocks = listOf(blockA, blockB),
            setups = listOf(setupA, setupB),
            entries = entries,
            asOf = asOf,
        )
        assertEquals(2, s.blockCount)
        assertEquals(4.5, s.completedRowEquivalents, 1e-9)
        assertEquals(11.0, s.totalRowEquivalents, 1e-9)
        // Row-equivalent progress, NOT vine-weighted: 4.5 / 11 → 41 %.
        assertEquals(41, s.displayPercent)
        assertEquals(1700, s.vinesTotal)
        assertEquals(900, s.vinesPruned)
        assertEquals(800, s.vinesRemaining)
        // Mean of per-day exact totals over days-with-entries: (400+500)/2.
        assertEquals(450.0, s.vinesPerDay ?: 0.0, 1e-6)
        // Person-hours: 900 exact vines ÷ (4 + 8) h.
        assertEquals(75.0, s.vinesPerLabourHour ?: 0.0, 1e-6)
        assertEquals(12.0, s.labourHours, 1e-9)
        assertEquals(0, s.blocksComplete)
        assertEquals(0, s.blocksAtRisk)
        assertEquals(LocalDate.parse("2026-07-15"), s.projectedFinish)
    }

    @Test
    fun vineyardSummary_liveValuesRoundLikeSql115() {
        // Same rounding rules the live JH Testing values follow:
        // round(exact) half up for vines, round(fraction × 100) for percent.
        val s = PruningCalculator.vineyardSummary(
            paddocks = listOf(blockA, blockB),
            setups = listOf(setupA, setupB),
            entries = entries,
            asOf = asOf,
        )
        assertEquals(s.vinesPruned, s.vinesPrunedExact.roundToInt())
        assertEquals(s.displayPercent, (s.fraction * 100).roundToInt())
    }

    // MARK: Duplicate + legacy segment handling

    @Test
    fun duplicateQuarterAcrossEntries_isNeverCountedTwice() {
        val duplicate = PruningEntry(
            id = "e3",
            vineyardId = "v",
            paddockId = "block-a",
            seasonId = "season-a",
            date = "2026-07-14",
            // Row 42 Q1 was already completed by entry e1.
            segments = listOf(PruningSegment(row = 42, quarter = 1, rowId = rowId(42))),
        )
        val m = PruningCalculator.metrics(blockA, setupA, entries + duplicate, asOf)
        assertEquals(4.5, m.completedRowEquivalents, 1e-9)
        assertEquals(900, m.vinesPruned)
    }

    @Test
    fun legacySegmentWithoutRowId_matchesRowByStoredNumber() {
        val legacy = PruningEntry(
            id = "e4",
            vineyardId = "v",
            paddockId = "block-a",
            seasonId = "season-a",
            date = "2026-07-14",
            segments = listOf(PruningSegment(row = 47, quarter = 1, rowId = null)),
        )
        val m = PruningCalculator.metrics(blockA, setupA, entries + legacy, asOf)
        assertEquals(4.75, m.completedRowEquivalents, 1e-9)
        // Quarter of row 47 (200 vines) adds exactly 50 exact vines.
        assertEquals(950.0, m.vinesPrunedExact, 1e-6)
    }

    @Test
    fun reversingAnEntry_reopensItsQuartersExactly() {
        val m = PruningCalculator.metrics(blockA, setupA, listOf(entry1), asOf)
        assertEquals(2.0, m.completedRowEquivalents, 1e-9)
        assertEquals(400, m.vinesPruned)
    }

    // MARK: Rate edge cases

    @Test
    fun daysWithoutEntries_neverReduceTheRate() {
        // Two working days recorded across a gap — rate divides by 2, not by
        // the calendar span.
        val gapEntry = entry2.copy(id = "e5", date = "2026-07-20")
        val rate = PruningCalculator.rowEquivalentsPerDay(listOf(entry1, gapEntry), null)
        assertEquals(2.25, rate ?: 0.0, 1e-9)
    }

    @Test
    fun zeroLabourHours_excludedFromBothSidesOfTheRate() {
        val unpaid = entry2.copy(id = "e6", labourHours = null)
        val rows = PruningCalculator.rowRefs(blockA, setupA)
        val perHour = PruningCalculator.vinesPerLabourHour(listOf(entry1, unpaid), rows)
        // Only entry1 carries hours: 400 vines ÷ 4 h.
        assertEquals(100.0, perHour ?: 0.0, 1e-6)
    }

    @Test
    fun noWork_returnsEmptyRatesWithoutFailing() {
        val rows = PruningCalculator.rowRefs(blockA, setupA)
        assertNull(PruningCalculator.rowEquivalentsPerDay(emptyList(), null))
        assertNull(PruningCalculator.exactVinesPerDay(emptyList(), rows))
        assertNull(PruningCalculator.vinesPerLabourHour(emptyList(), rows))
        val s = PruningCalculator.vineyardSummary(
            paddocks = listOf(blockA),
            setups = listOf(setupA),
            entries = emptyList(),
            asOf = asOf,
        )
        assertEquals(0, s.displayPercent)
        assertEquals(0, s.vinesPruned)
        assertNotNull(s)
    }
}
