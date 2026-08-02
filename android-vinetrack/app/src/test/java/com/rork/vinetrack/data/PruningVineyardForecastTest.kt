package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningCalculator
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningForecastOutcome
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.PruningVineyardForecast
import com.rork.vinetrack.data.model.PruningVineyardSummary
import com.rork.vinetrack.ui.screens.pruningForecastLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * SHARED VINEYARD FORECAST FIXTURE — the same cases exist as
 * `PruningVineyardForecastTests.swift` in the iOS test target. Both
 * implementations must produce identical elapsed days, average vines/day and
 * outcome.
 *
 * Contract under test:
 *  * elapsed days = calendar days from the FIRST valid entry through today,
 *    INCLUSIVE (days without pruning still count),
 *  * average = exact vines pruned ÷ elapsed days,
 *  * remaining = EVERY configured block's vines − vines pruned,
 *  * days remaining = ceil(remaining ÷ average), rounded UP,
 *  * 100 % → the last valid pruning date, never a future projection,
 *  * anything unusable → NotEnoughData, never an arbitrary date.
 */
class PruningVineyardForecastTest {

    private val asOf: LocalDate = LocalDate.parse("2026-08-02")

    private val metresPerDegreeLat = 111_320.0

    private fun rowId(block: Int, number: Int): String =
        "0000000$block-0000-0000-0000-00000000000$number"

    private fun row(block: Int, number: Int, lengthMetres: Double = 200.0): PaddockRow {
        val lon = 150.0 + block * 0.1 + number * 0.001
        return PaddockRow(
            id = rowId(block, number),
            number = number,
            startPoint = CoordinatePoint(latitude = 0.0, longitude = lon),
            endPoint = CoordinatePoint(latitude = lengthMetres / metresPerDegreeLat, longitude = lon),
        )
    }

    /** 4 rows × 100 vines. */
    private val blockA = Paddock(
        id = "block-a",
        vineyardId = "v",
        name = "A — started",
        vineCountOverride = 400,
        rows = (1..4).map { row(1, it) },
    )

    /** 4 rows × 100 vines — NEVER touched. Still remaining workload. */
    private val blockB = Paddock(
        id = "block-b",
        vineyardId = "v",
        name = "B — untouched",
        vineCountOverride = 400,
        rows = (1..4).map { row(2, it) },
    )

    /** 2 rows × 100 vines — completed. */
    private val blockC = Paddock(
        id = "block-c",
        vineyardId = "v",
        name = "C — complete",
        vineCountOverride = 200,
        rows = (1..2).map { row(3, it) },
    )

    private fun setup(paddockId: String) = PruningBlockSetup(
        id = "season-$paddockId",
        vineyardId = "v",
        paddockId = paddockId,
        seasonYear = 2026,
    )

    private var entrySeq = 0

    private fun entry(
        paddockId: String,
        on: String,
        segments: List<PruningSegment>,
        hours: Double? = null,
    ) = PruningEntry(
        id = "e${entrySeq++}",
        vineyardId = "v",
        paddockId = paddockId,
        seasonId = "season-$paddockId",
        date = on,
        segments = segments,
        labourHours = hours,
    )

    private fun fullRow(block: Int, number: Int): List<PruningSegment> =
        (1..4).map { PruningSegment(row = number, quarter = it, rowId = rowId(block, number)) }

    private fun quarters(block: Int, number: Int, list: List<Int>): List<PruningSegment> =
        list.map { PruningSegment(row = number, quarter = it, rowId = rowId(block, number)) }

    private fun forecast(
        pruned: Double,
        total: Int,
        complete: Boolean = false,
        dates: List<String>,
        on: LocalDate = asOf,
    ): PruningVineyardForecast = PruningCalculator.vineyardForecast(
        vinesPrunedExact = pruned,
        vinesTotal = total,
        isComplete = complete,
        entryDates = dates.map { LocalDate.parse(it) },
        asOf = on,
    )

    private fun summary(
        paddocks: List<Paddock>,
        entries: List<PruningEntry>,
        on: LocalDate = asOf,
    ): PruningVineyardSummary = PruningCalculator.vineyardSummary(
        paddocks = paddocks,
        setups = paddocks.map { setup(it.id) },
        entries = entries,
        asOf = on,
    )

    // MARK: The reported production regression

    /**
     * The exact numbers from the field report: ~51 % done, 11 101 pruned,
     * 10 761 remaining, pruning underway for about a month. The old rate (mean
     * over days-WITH-entries, last 3 days) produced 653 vines/day and "about 8
     * days". The elapsed-calendar-day rule must produce ~370/day.
     */
    @Test
    fun fieldReport_oneMonthUnderway_projectsAboutAMonthNotAWeek() {
        val f = forecast(
            pruned = 11_101.0,
            total = 21_862,
            dates = listOf("2026-07-04", "2026-08-01"),
        )
        assertEquals(30, f.elapsedDays)
        assertEquals(370.0333333, f.averageVinesPerElapsedDay ?: 0.0, 1e-4)
        // ceil(10 761 ÷ 370.03) = 30 — rounded UP so the date is never early.
        assertEquals(30, f.estimatedDaysRemaining)
        assertEquals(PruningForecastOutcome.Projected(LocalDate.parse("2026-09-01")), f.outcome)
        // The old behaviour (≈8 days) must be impossible now.
        assertTrue((f.estimatedDaysRemaining ?: 0) > 20)
    }

    // MARK: Elapsed-day rule

    @Test
    fun firstEntryToday_countsAsOneElapsedDay() {
        val f = forecast(pruned = 200.0, total = 1_000, dates = listOf("2026-08-02"))
        assertEquals(1, f.elapsedDays)
        assertEquals(200.0, f.averageVinesPerElapsedDay ?: 0.0, 1e-9)
        assertEquals(4, f.estimatedDaysRemaining)
        assertEquals(PruningForecastOutcome.Projected(LocalDate.parse("2026-08-06")), f.outcome)
    }

    @Test
    fun daysWithoutEntries_stillCountAsElapsedTime() {
        // Work on 2 days only, spread over 10 calendar days.
        val f = forecast(pruned = 1_000.0, total = 3_000, dates = listOf("2026-07-24", "2026-07-30"))
        assertEquals(10, f.elapsedDays)
        // NOT 500/day (mean of active days) — 100/day across the calendar.
        assertEquals(100.0, f.averageVinesPerElapsedDay ?: 0.0, 1e-9)
        assertEquals(20, f.estimatedDaysRemaining)
    }

    @Test
    fun entryDatesOutOfOrder_useTheEarliestAsTheAnchor() {
        val f = forecast(
            pruned = 500.0,
            total = 900,
            dates = listOf("2026-07-30", "2026-07-24", "2026-07-28"),
        )
        assertEquals(10, f.elapsedDays)
    }

    @Test
    fun futureDatedFirstEntry_clampsToASingleElapsedDay() {
        val f = forecast(pruned = 100.0, total = 500, dates = listOf("2026-08-09"))
        assertEquals(1, f.elapsedDays)
        assertEquals(100.0, f.averageVinesPerElapsedDay ?: 0.0, 1e-9)
    }

    // MARK: Insufficient data

    @Test
    fun noEntries_isNotEnoughData() {
        val f = forecast(pruned = 0.0, total = 1_000, dates = emptyList())
        assertEquals(PruningForecastOutcome.NotEnoughData, f.outcome)
        assertNull(f.averageVinesPerElapsedDay)
        assertNull(f.estimatedDaysRemaining)
    }

    @Test
    fun zeroConfiguredVines_isNotEnoughData() {
        val f = forecast(pruned = 0.0, total = 0, dates = listOf("2026-07-20"))
        assertEquals(PruningForecastOutcome.NotEnoughData, f.outcome)
    }

    @Test
    fun entriesButNoVines_isNotEnoughData() {
        val f = forecast(pruned = 0.0, total = 1_000, dates = listOf("2026-07-20"))
        assertEquals(PruningForecastOutcome.NotEnoughData, f.outcome)
        assertNull(f.averageVinesPerElapsedDay)
    }

    // MARK: Completion

    @Test
    fun vineyardAtOneHundredPercent_showsTheLastActivityDate() {
        val f = forecast(
            pruned = 1_000.0,
            total = 1_000,
            complete = true,
            dates = listOf("2026-07-04", "2026-08-02"),
        )
        assertEquals(PruningForecastOutcome.Completed(LocalDate.parse("2026-08-02")), f.outcome)
        assertEquals(0, f.estimatedDaysRemaining)
        assertEquals(0.0, f.vinesRemainingExact, 1e-9)
    }

    @Test
    fun remainingBelowOneVine_completesWithoutProjecting() {
        val f = forecast(pruned = 999.7, total = 1_000, dates = listOf("2026-07-31"))
        assertEquals(PruningForecastOutcome.Completed(LocalDate.parse("2026-07-31")), f.outcome)
    }

    // MARK: End-to-end through the dashboard summary

    @Test
    fun blocksWithZeroProgress_stayInTheRemainingWorkload() {
        val entries = listOf(
            entry("block-a", "2026-07-30", fullRow(1, 1)),
            entry("block-a", "2026-08-02", fullRow(1, 2)),
        )
        val s = summary(listOf(blockA, blockB), entries)

        assertEquals(800, s.vinesTotal)
        assertEquals(200, s.vinesPruned)
        assertEquals(600, s.vinesRemaining)
        assertEquals(4, s.forecast.elapsedDays)
        // 200 ÷ 4 elapsed days = 50/day (NOT 100/day over active days only).
        assertEquals(50.0, s.averageVinesPerElapsedDay ?: 0.0, 1e-9)
        // 600 remaining includes untouched block B → 12 days.
        assertEquals(12, s.forecast.estimatedDaysRemaining)
        assertEquals(PruningForecastOutcome.Projected(LocalDate.parse("2026-08-14")), s.forecast.outcome)
    }

    @Test
    fun completedBlockPlusUnstartedBlocks_stillProjectsTheWholeVineyard() {
        val entries = listOf(
            entry("block-c", "2026-08-01", fullRow(3, 1)),
            entry("block-c", "2026-08-02", fullRow(3, 2)),
        )
        val s = summary(listOf(blockA, blockB, blockC), entries)

        assertEquals(1, s.blocksComplete)
        assertEquals(1_000, s.vinesTotal)
        assertEquals(200, s.vinesPruned)
        // 2 elapsed days → 100/day; 800 remaining → 8 days.
        assertEquals(2, s.forecast.elapsedDays)
        assertEquals(8, s.forecast.estimatedDaysRemaining)
    }

    @Test
    fun partialRowsAndQuarterEntries_countTowardsTheAverage() {
        val entries = listOf(
            entry("block-a", "2026-08-01", fullRow(1, 1)),
            entry("block-a", "2026-08-02", quarters(1, 2, listOf(1))),
        )
        val s = summary(listOf(blockA), entries)
        assertEquals(125.0, s.vinesPrunedExact, 1e-6)
        assertEquals(62.5, s.averageVinesPerElapsedDay ?: 0.0, 1e-9)
    }

    @Test
    fun reversedEntry_removesItsWorkAndItsElapsedAnchor() {
        val entries = listOf(
            entry("block-a", "2026-07-24", emptyList()),
            entry("block-a", "2026-08-01", fullRow(1, 1)),
        )
        val s = summary(listOf(blockA), entries)
        assertEquals(LocalDate.parse("2026-08-01"), s.forecast.firstEntryDate)
        assertEquals(2, s.forecast.elapsedDays)
        assertEquals(50.0, s.averageVinesPerElapsedDay ?: 0.0, 1e-9)
    }

    @Test
    fun segmentsOnDeletedRows_neverAnchorTheElapsedPeriod() {
        val entries = listOf(
            entry("block-a", "2026-06-01", listOf(PruningSegment(row = 99, quarter = 1, rowId = rowId(9, 9)))),
            entry("block-a", "2026-08-01", fullRow(1, 1)),
        )
        val s = summary(listOf(blockA), entries)
        assertEquals(LocalDate.parse("2026-08-01"), s.forecast.firstEntryDate)
    }

    @Test
    fun editedHistoricalEntry_movesTheElapsedAnchorBack() {
        val s = summary(listOf(blockA), listOf(entry("block-a", "2026-07-20", fullRow(1, 1))))
        assertEquals(14, s.forecast.elapsedDays)
        assertEquals(100.0 / 14.0, s.averageVinesPerElapsedDay ?: 0.0, 1e-9)
    }

    @Test
    fun duplicateQuartersAcrossEntries_neverInflateTheAverage() {
        val entries = listOf(
            entry("block-a", "2026-08-01", fullRow(1, 1)),
            entry("block-a", "2026-08-02", fullRow(1, 1)),
        )
        val s = summary(listOf(blockA), entries)
        assertEquals(100.0, s.vinesPrunedExact, 1e-6)
        assertEquals(50.0, s.averageVinesPerElapsedDay ?: 0.0, 1e-9)
    }

    @Test
    fun fullyPrunedVineyard_showsCompletedNotAProjection() {
        val entries = (1..4).map { number ->
            entry("block-a", LocalDate.parse("2026-07-29").plusDays((number - 1).toLong()).toString(), fullRow(1, number))
        }
        val s = summary(listOf(blockA), entries)
        assertEquals(100, s.displayPercent)
        assertEquals(PruningForecastOutcome.Completed(LocalDate.parse("2026-08-01")), s.forecast.outcome)
    }

    @Test
    fun vineyardWithoutVineCounts_isNotEnoughData() {
        val noVines = Paddock(
            id = "block-a",
            vineyardId = "v",
            name = "No vine counts",
            vineCountOverride = 0,
            rows = null,
        )
        val s = summary(listOf(noVines), emptyList())
        assertEquals(PruningForecastOutcome.NotEnoughData, s.forecast.outcome)
    }

    // MARK: Display line (identical wording on both platforms)

    @Test
    fun forecastLine_matchesTheSharedWording() {
        val projected = PruningVineyardForecast(
            firstEntryDate = null,
            lastEntryDate = null,
            elapsedDays = 30,
            averageVinesPerElapsedDay = 370.0,
            vinesRemainingExact = 10_761.0,
            estimatedDaysRemaining = 30,
            outcome = PruningForecastOutcome.Projected(LocalDate.parse("2026-08-29")),
        )
        assertEquals(
            "Projected vineyard completion: 29 Aug 2026",
            pruningForecastLine(projected),
        )
        assertEquals(
            "Vineyard completed: 2 Aug 2026",
            pruningForecastLine(
                projected.copy(outcome = PruningForecastOutcome.Completed(LocalDate.parse("2026-08-02"))),
            ),
        )
        assertEquals(
            "Projected vineyard completion: Not enough data",
            pruningForecastLine(projected.copy(outcome = PruningForecastOutcome.NotEnoughData)),
        )
    }
}
