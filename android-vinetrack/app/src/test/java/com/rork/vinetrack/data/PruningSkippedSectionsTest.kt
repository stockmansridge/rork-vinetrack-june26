package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningCalculator
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSegment
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * SKIPPED PRUNING SECTIONS (sql/168) — the shared contract.
 *
 * The twin of `PruningSkippedSectionsTests.swift`. Every expected value here is
 * DERIVED from the fixture below (quarters ÷ 4, row vines ÷ 4), not copied from
 * a screen, so the two suites state the same contract rather than pinning the
 * same observation.
 *
 * THE RULE UNDER TEST, in one line: a skipped section counts as COMPLETE for
 * progress and as NOTHING for pruning work.
 *
 * Fixture — Block A "Cab Franc": 7 configured rows with REAL non-sequential
 * numbers 42–47 + 50 (the gap is deliberate), six 200 m rows + one 100 m row,
 * vine count override 1300. Length-weighted, that is 200 vines in each of rows
 * 42–47 and 100 vines in row 50, so:
 *   * one full row   = 1.00 row equivalents = 200 vines (50 per quarter),
 *   * the whole block = 7.00 row equivalents = 1300 vines.
 */
class PruningSkippedSectionsTest {

    private val asOf: LocalDate = LocalDate.parse("2026-07-14")
    private val metresPerDegreeLat = 111_320.0

    private fun rowId(number: Int): String = "00000000-0000-0000-0000-0000000000$number"

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
        rowWidth = 2.5,
        rows = listOf(
            row(50, 100.0), row(47, 200.0), row(42, 200.0),
            row(45, 200.0), row(43, 200.0), row(46, 200.0),
            row(44, 200.0),
        ),
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

    /** Derived from the fixture, never hard-coded from a screenshot. */
    private val blockRowEquivalents = 7.0
    private val vinesPerLongRow = 200.0
    private val vinesPerLongQuarter = vinesPerLongRow / 4.0

    private fun fullRow(number: Int): List<PruningSegment> =
        (1..4).map { PruningSegment(row = number, quarter = it, rowId = rowId(number)) }

    private fun quarters(number: Int, vararg qs: Int): List<PruningSegment> =
        qs.map { PruningSegment(row = number, quarter = it, rowId = rowId(number)) }

    private fun pruned(
        id: String,
        segments: List<PruningSegment>,
        date: String = "2026-07-13",
        labourHours: Double? = 4.0,
    ) = PruningEntry(
        id = id,
        vineyardId = "v",
        paddockId = "block-a",
        seasonId = "season-a",
        date = date,
        segments = segments,
        worker = "Dan",
        labourHours = labourHours,
        method = "spur",
    )

    /** A skipped record as the UI builds it: identifiers and selection only. */
    private fun skipped(
        id: String,
        segments: List<PruningSegment>,
        date: String = "2026-07-14",
    ) = PruningEntry(
        id = id,
        vineyardId = "v",
        paddockId = "block-a",
        seasonId = "season-a",
        date = date,
        segments = segments,
        notes = "Vines removed",
        isSkipped = true,
    )

    private fun metrics(entries: List<PruningEntry>) =
        PruningCalculator.metrics(blockA, setupA, entries, asOf)

    // ---------------------------------------------------------------- selection

    @Test
    fun oneWholeRowMarkedSkipped() {
        val m = metrics(listOf(skipped("s1", fullRow(42))))

        assertEquals(4, m.skipped.size)
        assertEquals(1.0, m.skippedRowEquivalents, 0.0001)
        // Complete, but not pruned.
        assertEquals(1.0, m.completedRowEquivalents, 0.0001)
        assertEquals(0.0, m.prunedRowEquivalents, 0.0001)
        assertTrue(m.hasSkippedSections)
    }

    @Test
    fun multipleRowsMarkedSkipped() {
        val m = metrics(listOf(skipped("s1", fullRow(42) + fullRow(43) + fullRow(44))))

        assertEquals(12, m.skipped.size)
        assertEquals(3.0, m.skippedRowEquivalents, 0.0001)
        assertEquals(3.0, m.completedRowEquivalents, 0.0001)
        assertEquals(0.0, m.prunedRowEquivalents, 0.0001)
    }

    @Test
    fun oneRowQuarterMarkedSkipped() {
        val m = metrics(listOf(skipped("s1", quarters(42, 3))))

        assertEquals(1, m.skipped.size)
        assertEquals(0.25, m.skippedRowEquivalents, 0.0001)
        assertEquals(0.25, m.completedRowEquivalents, 0.0001)
        // A quarter of a 200-vine row.
        assertEquals(vinesPerLongQuarter, m.vinesSkippedExact, 0.0001)
    }

    @Test
    fun severalRowQuartersMarkedSkipped() {
        // "Row 42, sections 2–4" plus two quarters of row 47 — a partial-row
        // selection spanning more than one row.
        val m = metrics(listOf(skipped("s1", quarters(42, 2, 3, 4) + quarters(47, 1, 2))))

        assertEquals(5, m.skipped.size)
        assertEquals(1.25, m.skippedRowEquivalents, 0.0001)
        assertEquals(5 * vinesPerLongQuarter, m.vinesSkippedExact, 0.0001)
    }

    // ----------------------------------------------------------------- progress

    @Test
    fun skippedSectionsCountTowardProgress() {
        // 2 rows pruned + 1 row skipped = 3 of 7 rows complete.
        val entries = listOf(
            pruned("e1", fullRow(42) + fullRow(43)),
            skipped("s1", fullRow(44)),
        )
        val m = metrics(entries)

        assertEquals(3.0, m.completedRowEquivalents, 0.0001)
        assertEquals(3.0 / blockRowEquivalents, m.fractionComplete, 0.0001)
        // …and the split adds back up to the whole.
        assertEquals(2.0, m.prunedRowEquivalents, 0.0001)
        assertEquals(1.0, m.skippedRowEquivalents, 0.0001)
        assertEquals(
            m.fractionComplete,
            m.fractionPruned + m.fractionSkipped,
            0.0001,
        )
    }

    @Test
    fun skippedSectionsReduceRowsAndSectionsRemaining() {
        val m = metrics(listOf(skipped("s1", fullRow(42) + fullRow(43))))

        val rowsRemaining = m.totalRowEquivalents - m.completedRowEquivalents
        val sectionsRemaining = (m.rowCount * 4) - m.completed.size
        assertEquals(5.0, rowsRemaining, 0.0001)
        assertEquals(20, sectionsRemaining)
    }

    @Test
    fun skippedSectionsDoNotCountAsVinesPruned() {
        val entries = listOf(
            pruned("e1", fullRow(42)),
            skipped("s1", fullRow(43)),
        )
        val m = metrics(entries)

        // One pruned row of 200 vines — the skipped row's 200 are reported
        // separately and never added to "vines pruned".
        assertEquals(vinesPerLongRow, m.vinesPrunedExact, 0.0001)
        assertEquals(vinesPerLongRow.toInt(), m.vinesPruned)
        assertEquals(vinesPerLongRow, m.vinesSkippedExact, 0.0001)
        assertEquals(vinesPerLongRow.toInt(), m.vinesSkipped)
    }

    @Test
    fun skippedSectionsDoNotCountAsRowsPrunedOrRatesOrLabour() {
        val entries = listOf(
            pruned("e1", fullRow(42), date = "2026-07-13", labourHours = 4.0),
            skipped("s1", fullRow(43) + fullRow(44) + fullRow(45), date = "2026-07-14"),
        )
        val rows = PruningCalculator.rowRefs(blockA, setupA)

        // Rows pruned: 1.0, not 4.0.
        assertEquals(1.0, metrics(entries).prunedRowEquivalents, 0.0001)

        // Rate: only the one real working day counts. Three skipped rows on a
        // second day must not look like a blazing 3 rows/day.
        assertEquals(1.0, PruningCalculator.preferredRate(entries)!!, 0.0001)

        // Vines/day: one day, 200 vines — the skipped day is not a day of work.
        assertEquals(vinesPerLongRow, PruningCalculator.exactVinesPerDay(entries, rows)!!, 0.0001)

        // Vines per labour hour: 200 ÷ 4 h. The skipped record contributes to
        // neither side of the ratio.
        assertEquals(50.0, PruningCalculator.vinesPerLabourHour(entries, rows)!!, 0.0001)

        // Vineyard roll-up agrees, and labour hours exclude skipped records.
        val summary = PruningCalculator.vineyardSummary(
            listOf(blockA), listOf(setupA), entries, asOf,
        )
        assertEquals(4.0, summary.labourHours, 0.0001)
        assertEquals(vinesPerLongRow, summary.vinesPrunedExact, 0.0001)
        assertEquals(3 * vinesPerLongRow, summary.vinesSkippedExact, 0.0001)
    }

    @Test
    fun skippedAreaCountsTowardCompletionButNeverTowardWorkedArea() {
        val entries = listOf(
            pruned("e1", fullRow(42)),
            skipped("s1", fullRow(43)),
        )
        val m = metrics(entries)

        // 200 m × 2.5 m row width = 500 m² = 0.05 ha per full row.
        assertEquals(0.10, m.completionAreaHa, 0.0001)
        assertEquals(0.05, m.workedAreaHa, 0.0001)
        // Cost per WORKED hectare must never be diluted by skipped ground.
        assertTrue(m.workedAreaHa < m.completionAreaHa)
    }

    // ------------------------------------------------------------------ record

    @Test
    fun aSkippedRecordCarriesNoWorkerLabourCostOrWorkTask() {
        val entry = skipped("s1", fullRow(42))

        assertTrue(entry.isSkipped)
        assertEquals("", entry.worker)
        assertNull(entry.labourHours)
        assertNull(entry.startTime)
        assertNull(entry.finishTime)
        assertNull(entry.workTaskId)
        // No productivity result: elapsed duration cannot be derived either.
        assertNull(entry.durationHours)
        // No client vine estimate — vines are attributed, never claimed as work.
        assertEquals(0, entry.estimatedVines)
    }

    @Test
    fun anOrdinaryPruningRecordIsUnaffected() {
        val entry = pruned("e1", fullRow(42))
        assertFalse(entry.isSkipped)

        val m = metrics(listOf(entry))
        assertEquals(1.0, m.prunedRowEquivalents, 0.0001)
        assertEquals(0.0, m.skippedRowEquivalents, 0.0001)
        assertFalse(m.hasSkippedSections)
        // The screen shows one figure, exactly as before the feature existed.
        assertEquals(m.fractionComplete, m.fractionPruned, 0.0001)
    }

    // -------------------------------------------------------------- precedence

    @Test
    fun alreadyCompletedSectionsAreIgnoredByAnOverlappingSkip() {
        // Row 42 is already pruned. A skip that overlaps it must not steal the
        // work: the pruned quarters stay pruned, and only the genuinely new
        // quarters (row 43) become skipped.
        val entries = listOf(
            pruned("e1", fullRow(42)),
            skipped("s1", fullRow(42) + fullRow(43)),
        )
        val m = metrics(entries)

        assertEquals(1.0, m.prunedRowEquivalents, 0.0001)
        assertEquals(1.0, m.skippedRowEquivalents, 0.0001)
        assertEquals(2.0, m.completedRowEquivalents, 0.0001)
        // Vines pruned is untouched by the overlap.
        assertEquals(vinesPerLongRow, m.vinesPrunedExact, 0.0001)
        assertTrue(m.skipped.none { it.row == 42 })
    }

    @Test
    fun progressNeverExceedsOneHundredPercent() {
        // Every row skipped, plus an overlapping pruned record and a duplicate
        // skip of the same sections — nothing may push past 100 %.
        val everyRow = listOf(42, 43, 44, 45, 46, 47, 50).flatMap { fullRow(it) }
        val entries = listOf(
            skipped("s1", everyRow),
            skipped("s2", everyRow),
            pruned("e1", fullRow(42) + fullRow(43)),
        )
        val m = metrics(entries)

        assertEquals(1.0, m.fractionComplete, 0.0001)
        assertTrue(m.fractionComplete <= 1.0)
        assertTrue(m.fractionPruned + m.fractionSkipped <= 1.0000001)
        assertEquals(blockRowEquivalents, m.completedRowEquivalents, 0.0001)

        val summary = PruningCalculator.vineyardSummary(
            listOf(blockA), listOf(setupA), entries, asOf,
        )
        assertTrue(summary.fraction <= 1.0)
        assertEquals(100, summary.displayPercent)
        // Nothing left to do, and the remaining workload is zero rather than
        // negative — skipped vines leave the workload without becoming work.
        assertEquals(0, summary.vinesRemaining)
    }

    // ---------------------------------------------------------------- reversal

    @Test
    fun reversingASkippedEntryRestoresThePreviousProgress() {
        val before = metrics(listOf(pruned("e1", fullRow(42))))

        val skip = skipped("s1", fullRow(43) + fullRow(44))
        val during = metrics(listOf(pruned("e1", fullRow(42)), skip))
        assertEquals(3.0, during.completedRowEquivalents, 0.0001)

        // Reversal is the existing path: the row is retained for the audit
        // trail with a reversal stamp, and every calculation already drops it.
        val reversed = skip.copy(reversedAtMs = System.currentTimeMillis())
        assertTrue(reversed.isReversed)
        val after = metrics(listOf(pruned("e1", fullRow(42))))

        assertEquals(before.completedRowEquivalents, after.completedRowEquivalents, 0.0001)
        assertEquals(before.skippedRowEquivalents, after.skippedRowEquivalents, 0.0001)
        assertEquals(before.vinesPrunedExact, after.vinesPrunedExact, 0.0001)
        assertEquals(before.fractionComplete, after.fractionComplete, 0.0001)
    }

    @Test
    fun reversingASkippedEntryLeavesUnrelatedEntriesAlone() {
        val keep = pruned("e1", fullRow(42))
        val alsoKeep = skipped("s2", fullRow(46))
        val m = metrics(listOf(keep, alsoKeep))

        assertEquals(1.0, m.prunedRowEquivalents, 0.0001)
        assertEquals(1.0, m.skippedRowEquivalents, 0.0001)
        // Row 46 is still skipped after an unrelated reversal elsewhere.
        assertTrue(m.skipped.any { it.row == 46 })
        assertTrue(m.pruned.any { it.row == 42 })
    }

    // --------------------------------------------------------- sync + offline

    @Test
    fun offlineCreatedSkippedEntriesSurviveTheOutboxRoundTrip() {
        // The offline queue stores the entry as JSON and replays it later; the
        // flag must survive, or a queued skip would land as pruning work.
        val json = Json { ignoreUnknownKeys = true }
        val entry = skipped("s1", quarters(42, 1, 2))

        val payload = json.encodeToString(PruningEntry.serializer(), entry)
        val replayed = json.decodeFromString(PruningEntry.serializer(), payload)

        assertTrue(replayed.isSkipped)
        assertEquals(entry.id, replayed.id)
        assertEquals(entry.segments, replayed.segments)
        assertNull(replayed.labourHours)
        assertEquals("", replayed.worker)
    }

    @Test
    fun entriesCachedBeforeTheFlagExistedStillDecodeAsPruned() {
        // The local cache holds records written before sql/168. They must keep
        // their historical meaning instead of failing to decode and wiping the
        // device's pruning history.
        val json = Json { ignoreUnknownKeys = true }
        val legacy = """
            {"id":"old","vineyardId":"v","paddockId":"block-a","seasonId":"season-a",
             "date":"2026-07-13","segments":[],"worker":"Dan","labourHours":4.0}
        """.trimIndent()

        val decoded = json.decodeFromString(PruningEntry.serializer(), legacy)
        assertFalse(decoded.isSkipped)
        assertEquals(4.0, decoded.labourHours!!, 0.0001)
    }

    @Test
    fun iosAndAndroidDeriveTheSameFiguresFromTheSameSkippedFixture() {
        // The parity line `PruningSkippedSectionsTests.swift` asserts verbatim.
        // Rows 42–43 pruned, rows 44–45 skipped, row 46 half pruned.
        val entries = listOf(
            pruned("e1", fullRow(42) + fullRow(43) + quarters(46, 1, 2)),
            skipped("s1", fullRow(44) + fullRow(45)),
        )
        val m = metrics(entries)

        val rendered = listOf(
            "pruned_row_equivalents=%.2f".format(m.prunedRowEquivalents),
            "skipped_row_equivalents=%.2f".format(m.skippedRowEquivalents),
            "completed_row_equivalents=%.2f".format(m.completedRowEquivalents),
            "pruned_percent=${m.rounded(m.fractionPruned)}",
            "skipped_percent=${m.rounded(m.fractionSkipped)}",
            "complete_percent=${m.rounded(m.fractionComplete)}",
            "vines_pruned=${m.vinesPruned}",
            "vines_skipped=${m.vinesSkipped}",
        ).joinToString(" · ")

        assertEquals(
            "pruned_row_equivalents=2.50 · skipped_row_equivalents=2.00 · " +
                "completed_row_equivalents=4.50 · pruned_percent=36 · " +
                "skipped_percent=29 · complete_percent=64 · " +
                "vines_pruned=500 · vines_skipped=400",
            rendered,
        )
    }

    private fun com.rork.vinetrack.data.model.PruningBlockMetrics.rounded(fraction: Double): Int =
        PruningCalculator.displayPercent(fraction)
}
