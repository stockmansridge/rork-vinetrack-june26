package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityBlockContext
import com.rork.vinetrack.data.model.PruningActivityColumn
import com.rork.vinetrack.data.model.PruningActivityFilter
import com.rork.vinetrack.data.model.PruningActivityReport
import com.rork.vinetrack.data.model.PruningActivityRow
import com.rork.vinetrack.data.model.PruningActivitySort
import com.rork.vinetrack.data.model.PruningActivityStatus
import com.rork.vinetrack.data.model.PruningActivityTaskLink
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.PruningSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SHARED ACTIVITY REPORT FIXTURE — the same cases exist as
 * `PruningActivityReportTests.swift` in the iOS test target. Both
 * implementations must produce identical rows, statuses, filter results, sort
 * orders and summary totals.
 */
class PruningActivityReportTest {

    private val blockA = "block-a"
    private val blockB = "block-b"
    private val taskId = "task-1"
    private val userId = "user-1"

    /** 100 vines per row → one quarter = 25 vines. */
    private fun rows(numbers: List<Int>): List<PruningRowRef> = numbers.map { number ->
        PruningRowRef(
            rowId = null,
            number = number,
            label = "$number",
            lengthMetres = null,
            vines = 100.0,
            isFallback = true,
        )
    }

    private val contexts = mapOf(
        blockA to PruningActivityBlockContext("Block A", "Shiraz", rows(listOf(1, 2, 9, 10))),
        blockB to PruningActivityBlockContext("Block B", "Riesling", rows(listOf(1, 2))),
    )

    private fun dayMs(day: Int, hour: Int = 8): Long =
        java.time.LocalDate.of(2026, 7, day)
            .atTime(hour, 0)
            .atZone(java.time.ZoneId.of("UTC"))
            .toInstant()
            .toEpochMilli()

    private var counter = 0

    private fun entry(
        id: String = "entry-${++counter}",
        paddockId: String = blockA,
        day: Int,
        worker: String = "Sam",
        segments: List<PruningSegment> = listOf(PruningSegment(1, 1), PruningSegment(1, 2)),
        hours: Double? = 2.0,
        start: String? = null,
        finish: String? = null,
        notes: String = "",
        workTaskId: String? = null,
        createdAtMs: Long? = null,
        updatedAtMs: Long = 0L,
        reversedAtMs: Long = 0L,
        enteredBy: String? = null,
    ) = PruningEntry(
        id = id,
        vineyardId = "vineyard-1",
        paddockId = paddockId,
        date = "2026-07-%02d".format(day),
        segments = segments,
        worker = worker,
        labourHours = hours,
        startTime = start,
        finishTime = finish,
        notes = notes,
        workTaskId = workTaskId,
        createdAtMs = createdAtMs ?: dayMs(day),
        updatedAtMs = updatedAtMs,
        enteredBy = enteredBy,
        reversedAtMs = reversedAtMs,
    )

    private fun build(entries: List<PruningEntry>): List<PruningActivityRow> =
        PruningActivityReport.rows(
            entries = entries,
            blocks = contexts,
            workTaskTitles = mapOf(taskId to "Pruning — Block A"),
            labourCosts = mapOf(taskId to 240.0),
            accountNames = mapOf(userId to "Jonathan"),
        )

    // MARK: Status

    @Test
    fun `status is active edited or reversed from the server stamps only`() {
        val created = dayMs(1)
        assertEquals(PruningActivityStatus.Active, PruningActivityStatus.resolve(0, created, 0))
        assertEquals(PruningActivityStatus.Active, PruningActivityStatus.resolve(0, created, created))
        // Same statement writes both stamps — a second of drift is not an edit.
        assertEquals(PruningActivityStatus.Active, PruningActivityStatus.resolve(0, created, created + 1_000))
        assertEquals(PruningActivityStatus.Edited, PruningActivityStatus.resolve(0, created, created + 600_000))
        assertEquals(
            PruningActivityStatus.Reversed,
            PruningActivityStatus.resolve(dayMs(5), created, created + 600_000),
        )
    }

    // MARK: Row projection

    @Test
    fun `a row carries exact vines duration and vines per hour`() {
        val row = build(
            listOf(
                entry(
                    day = 3,
                    segments = listOf(PruningSegment(1, 1), PruningSegment(1, 2), PruningSegment(2, 1)),
                    hours = 3.0,
                    start = "07:30",
                    finish = "11:00",
                    workTaskId = taskId,
                    enteredBy = userId,
                )
            )
        ).first()

        assertEquals(75.0, row.vines!!, 0.0001)
        assertEquals(3, row.quarters)
        assertEquals(listOf(1, 2), row.rowNumbers)
        assertEquals("1–2", row.rowRangeLabel)
        assertEquals(25.0, row.vinesPerHour!!, 0.0001)
        assertEquals(3.5, row.durationHours!!, 0.0001)
        assertEquals(240.0, row.labourCost!!, 0.0001)
        assertEquals("Pruning — Block A", row.workTaskTitle)
        assertEquals("Jonathan", row.enteredBy)
        assertEquals("Shiraz", row.variety)
        assertEquals(2026, row.seasonYear)
        assertEquals(PruningActivityStatus.Active, row.status)
    }

    @Test
    fun `missing values stay null - never a misleading zero`() {
        val row = build(listOf(entry(day = 4, hours = null))).first()
        assertNull(row.labourHours)
        assertNull(row.vinesPerHour)
        assertNull(row.durationHours)
        assertNull(row.labourCost)
        assertNull(row.notes)
        assertNull(row.workTaskTitle)
        assertNull(row.enteredBy)
    }

    @Test
    fun `an empty history produces no rows and an empty summary`() {
        val rows = build(emptyList())
        assertTrue(rows.isEmpty())
        val summary = PruningActivityReport.summary(rows, includeCost = true)
        assertEquals(0, summary.jobs)
        assertEquals(0.0, summary.vines, 0.0001)
        assertNull(summary.averageVinesPerHour)
        assertNull(summary.labourCost)
    }

    // MARK: Filters

    @Test
    fun `every filter facet narrows the result and an empty facet means no restriction`() {
        val rows = build(
            listOf(
                entry(day = 1, worker = "Sam", notes = "wet morning"),
                entry(day = 5, paddockId = blockB, worker = "Ana", workTaskId = taskId),
                entry(day = 9, worker = "Sam", reversedAtMs = dayMs(10)),
            )
        )

        fun count(filter: PruningActivityFilter) = PruningActivityReport.filtered(rows, filter).size

        assertEquals(3, count(PruningActivityFilter(seasonYear = 2026)))
        assertEquals(0, count(PruningActivityFilter(seasonYear = 2025)))
        assertEquals(1, count(PruningActivityFilter(seasonYear = 2026, workers = setOf("Ana"))))
        assertEquals(1, count(PruningActivityFilter(seasonYear = 2026, blocks = setOf(blockB))))
        assertEquals(2, count(PruningActivityFilter(seasonYear = 2026, varieties = setOf("Shiraz"))))
        assertEquals(
            1,
            count(PruningActivityFilter(seasonYear = 2026, statuses = setOf(PruningActivityStatus.Reversed))),
        )
        assertEquals(1, count(PruningActivityFilter(seasonYear = 2026, taskLink = PruningActivityTaskLink.Linked)))
        assertEquals(2, count(PruningActivityFilter(seasonYear = 2026, taskLink = PruningActivityTaskLink.NotLinked)))
        assertEquals(
            2,
            count(PruningActivityFilter(seasonYear = 2026, dateFrom = "2026-07-05", dateTo = "2026-07-09")),
        )
    }

    @Test
    fun `search matches worker block variety row work task and notes`() {
        val rows = build(
            listOf(
                entry(day = 1, worker = "Sam", notes = "wet morning"),
                entry(day = 5, paddockId = blockB, worker = "Ana", workTaskId = taskId),
            )
        )

        fun hits(needle: String) =
            PruningActivityReport.filtered(rows, PruningActivityFilter(seasonYear = 2026, search = needle)).size

        assertEquals(1, hits("ana"))
        assertEquals(1, hits("Block B"))
        assertEquals(1, hits("riesling"))
        assertEquals(1, hits("wet"))
        assertEquals(1, hits("Pruning — Block A"))
        assertEquals(0, hits("nothing here"))
    }

    // MARK: Sorting

    @Test
    fun `the default order is date descending then created descending`() {
        val older = entry(day = 2)
        val newer = entry(day = 8)
        val sameDayLater = entry(day = 8, createdAtMs = dayMs(8, hour = 18))
        val sorted = PruningActivityReport.sorted(
            build(listOf(older, newer, sameDayLater)),
            PruningActivitySort.DEFAULT,
        )
        assertEquals(sameDayLater.id, sorted[0].id)
        assertEquals(newer.id, sorted[1].id)
        assertEquals(older.id, sorted[2].id)
    }

    @Test
    fun `rows sort naturally - row 2 before row 10`() {
        val low = entry(day = 1, segments = listOf(PruningSegment(2, 1)))
        val high = entry(day = 2, segments = listOf(PruningSegment(10, 1)))
        val sorted = PruningActivityReport.sorted(
            build(listOf(high, low)),
            PruningActivitySort(PruningActivityColumn.Rows, ascending = true),
        )
        assertEquals(low.id, sorted[0].id)
        assertEquals(high.id, sorted[1].id)
    }

    @Test
    fun `numbers sort numerically and blanks sort last in both directions`() {
        val big = entry(
            day = 1,
            segments = listOf(PruningSegment(1, 1), PruningSegment(1, 2), PruningSegment(1, 3), PruningSegment(1, 4)),
            hours = 4.0,
        )
        val small = entry(day = 2, hours = 1.0)
        val blank = entry(day = 3, hours = null)
        val built = build(listOf(blank, small, big))

        assertEquals(
            listOf(1.0, 4.0, null),
            PruningActivityReport
                .sorted(built, PruningActivitySort(PruningActivityColumn.Hours, ascending = true))
                .map { it.labourHours },
        )
        assertEquals(
            listOf(4.0, 1.0, null),
            PruningActivityReport
                .sorted(built, PruningActivitySort(PruningActivityColumn.Hours, ascending = false))
                .map { it.labourHours },
        )
    }

    @Test
    fun `times sort as times not as display strings`() {
        val late = entry(day = 1, start = "13:00")
        val early = entry(day = 2, start = "06:45")
        val sorted = PruningActivityReport.sorted(
            build(listOf(late, early)),
            PruningActivitySort(PruningActivityColumn.Start, ascending = true),
        )
        assertEquals(early.id, sorted[0].id)
    }

    @Test
    fun `tapping a heading cycles unsorted ascending descending unsorted`() {
        var sort = PruningActivitySort.DEFAULT
        sort = sort.cycled(PruningActivityColumn.Vines)
        assertEquals(PruningActivityColumn.Vines, sort.column)
        assertTrue(sort.ascending)
        sort = sort.cycled(PruningActivityColumn.Vines)
        assertTrue(!sort.ascending)
        sort = sort.cycled(PruningActivityColumn.Vines)
        assertNull(sort.column)
        sort = sort.cycled(PruningActivityColumn.Worker).cycled(PruningActivityColumn.Block)
        assertEquals(PruningActivityColumn.Block, sort.column)
        assertTrue(sort.ascending)
    }

    // MARK: Summary

    @Test
    fun `reversed records are counted but never contribute vines hours productivity or cost`() {
        val rows = build(
            listOf(
                entry(
                    day = 1,
                    segments = listOf(
                        PruningSegment(1, 1), PruningSegment(1, 2), PruningSegment(1, 3), PruningSegment(1, 4),
                    ),
                    hours = 4.0,
                    workTaskId = taskId,
                ),
                entry(day = 2, hours = 1.0),
                entry(
                    day = 3,
                    segments = listOf(PruningSegment(9, 1), PruningSegment(9, 2)),
                    hours = 5.0,
                    workTaskId = taskId,
                    reversedAtMs = dayMs(4),
                ),
            )
        )

        val summary = PruningActivityReport.summary(rows, includeCost = true)
        assertEquals(3, summary.jobs)
        assertEquals(2, summary.activeRecords)
        assertEquals(1, summary.reversedRecords)
        assertEquals(150.0, summary.vines, 0.0001)
        assertEquals(5.0, summary.labourHours, 0.0001)
        assertEquals(30.0, summary.averageVinesPerHour!!, 0.0001)
        assertEquals(240.0, summary.labourCost!!, 0.0001)
    }

    @Test
    fun `costing totals are omitted when the role cannot see costing`() {
        val rows = build(listOf(entry(day = 1, workTaskId = taskId)))
        assertNull(PruningActivityReport.summary(rows, includeCost = false).labourCost)
        assertEquals(240.0, PruningActivityReport.summary(rows, includeCost = true).labourCost!!, 0.0001)
    }

    @Test
    fun `records without labour hours are excluded from productivity on both sides`() {
        val rows = build(listOf(entry(day = 1, hours = 2.0), entry(day = 2, hours = null)))
        val summary = PruningActivityReport.summary(rows, includeCost = true)
        assertEquals(100.0, summary.vines, 0.0001)
        assertEquals(25.0, summary.averageVinesPerHour!!, 0.0001)
    }

    // MARK: Reversal retention

    @Test
    fun `a reversed entry stays in the audit list but never counts as work done`() {
        val active = entry(day = 1)
        val reversed = entry(day = 2, reversedAtMs = dayMs(3))
        val all = listOf(active, reversed)

        assertEquals(2, all.size)
        assertEquals(listOf(active.id), all.filterNot { it.isReversed }.map { it.id })
        assertTrue(reversed.isReversed)
        assertEquals(
            PruningActivityStatus.Reversed,
            build(all).first { it.id == reversed.id }.status,
        )
    }
}
