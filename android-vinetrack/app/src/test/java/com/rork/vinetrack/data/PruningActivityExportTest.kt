package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityBlockContext
import com.rork.vinetrack.data.model.PruningActivityColumn
import com.rork.vinetrack.data.model.PruningActivityExport
import com.rork.vinetrack.data.model.PruningActivityFilter
import com.rork.vinetrack.data.model.PruningActivityReport
import com.rork.vinetrack.data.model.PruningActivityRow
import com.rork.vinetrack.data.model.PruningActivitySort
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.PruningSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SHARED EXPORT FIXTURE — the same cases and the same numbers exist as
 * `PruningActivityExportTests.swift` in the iOS test target. Both platforms must
 * produce identical allocation breakdowns, identical first-row-only totals and
 * identical column sums from this fixture.
 *
 * The fixture deliberately covers every shape that could double-count labour:
 *
 *  * A — two blocks, Work Task labour lines (18 person-hours, $630)
 *  * B — one block, NO labour lines (legacy activity hours only, 4.0)
 *  * C — three blocks, Work Task labour lines (12 person-hours, $300)
 *  * D — two blocks, REVERSED (10 person-hours, $200 — must never be totalled)
 */
class PruningActivityExportTest {

    private val blockPinot = "block-pinot"
    private val blockCab = "block-cab"
    private val blockChard = "block-chard"

    private val taskA = "task-a"
    private val taskC = "task-c"
    private val taskD = "task-d"

    /** 100 vines per row → one quarter = 25 vines, one full row = 100. */
    private fun rowRefs(numbers: List<Int>): List<PruningRowRef> = numbers.map { number ->
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
        blockPinot to PruningActivityBlockContext("Pinot Noir", "Pinot Noir", rowRefs((90..108).toList())),
        blockCab to PruningActivityBlockContext("Cabernet Franc", "Cabernet Franc", rowRefs((1..12).toList())),
        blockChard to PruningActivityBlockContext("Chardonnay", "Chardonnay", rowRefs((1..4).toList())),
    )

    /** One whole row = four quarters. */
    private fun wholeRow(number: Int): List<PruningSegment> =
        (1..4).map { PruningSegment(number, it) }

    private fun allocation(
        id: String,
        activityId: String,
        allocationIndex: Int,
        paddockId: String,
        day: Int,
        rowNumber: Int,
        worker: String = "Pruning Crew",
        /** Activity-level values exist on the PRIMARY allocation only. */
        operationalHours: Double? = null,
        start: String? = null,
        finish: String? = null,
        notes: String = "",
        workTaskId: String? = null,
        reversedAtMs: Long = 0L,
    ) = PruningEntry(
        id = id,
        vineyardId = "vineyard-1",
        paddockId = paddockId,
        date = "2026-08-%02d".format(day),
        segments = wholeRow(rowNumber),
        worker = worker,
        labourHours = operationalHours,
        startTime = start,
        finishTime = finish,
        notes = notes,
        estimatedVines = 100,
        workTaskId = workTaskId,
        pruningActivityId = activityId,
        allocationIndex = allocationIndex,
        createdAtMs = 1_000L * day,
        reversedAtMs = reversedAtMs,
    )

    /** A — two blocks, Work Task labour lines. The example from the brief. */
    private val activityA = listOf(
        allocation(
            id = "a1", activityId = "act-a", allocationIndex = 0, paddockId = blockPinot,
            day = 3, rowNumber = 90, operationalHours = 6.0,
            start = "07:00", finish = "13:00", notes = "Cold start frost delay",
            workTaskId = taskA,
        ),
        allocation(
            id = "a2", activityId = "act-a", allocationIndex = 1, paddockId = blockCab,
            day = 3, rowNumber = 1,
        ),
    )

    /** B — one block, no labour lines: the legacy activity value is the fallback. */
    private val activityB = listOf(
        allocation(
            id = "b1", activityId = "act-b", allocationIndex = 0, paddockId = blockChard,
            day = 4, rowNumber = 1, worker = "Dave", operationalHours = 4.0,
        ),
    )

    /** C — three blocks, Work Task labour lines. */
    private val activityC = listOf(
        allocation(
            id = "c1", activityId = "act-c", allocationIndex = 0, paddockId = blockPinot,
            day = 5, rowNumber = 91, operationalHours = 2.0, workTaskId = taskC,
        ),
        allocation(
            id = "c2", activityId = "act-c", allocationIndex = 1, paddockId = blockCab,
            day = 5, rowNumber = 2,
        ),
        allocation(
            id = "c3", activityId = "act-c", allocationIndex = 2, paddockId = blockChard,
            day = 5, rowNumber = 3,
        ),
    )

    /** D — two blocks, REVERSED. Audit history that must never be totalled. */
    private val activityD = listOf(
        allocation(
            id = "d1", activityId = "act-d", allocationIndex = 0, paddockId = blockPinot,
            day = 6, rowNumber = 92, operationalHours = 5.0, workTaskId = taskD,
            reversedAtMs = 9_000L,
        ),
        allocation(
            id = "d2", activityId = "act-d", allocationIndex = 1, paddockId = blockCab,
            day = 6, rowNumber = 3, reversedAtMs = 9_000L,
        ),
    )

    private val titles = mapOf(
        taskA to "Winter pruning",
        taskC to "Spur pruning block sweep",
        taskD to "Reversed pruning",
    )

    private val statuses = mapOf(
        taskA to "Completed",
        taskC to "In progress",
        taskD to "Completed",
    )

    /** Summed Work Task labour lines — the AUTHORITATIVE labour source. */
    private val taskHours = mapOf(taskA to 18.0, taskC to 12.0, taskD to 10.0)
    private val taskCosts = mapOf(taskA to 630.0, taskC to 300.0, taskD to 200.0)

    private fun build(entries: List<PruningEntry>): List<PruningActivityRow> =
        PruningActivityReport.rows(
            entries = entries,
            blocks = contexts,
            workTaskTitles = titles,
            workTaskStatuses = statuses,
            labourCosts = taskCosts,
            labourHours = taskHours,
        )

    private val allEntries = activityA + activityB + activityC + activityD

    private fun sorted(entries: List<PruningEntry> = allEntries): List<PruningActivityRow> =
        PruningActivityReport.sorted(build(entries), PruningActivitySort.DEFAULT)

    // ------------------------------------------------------------------
    // 1. A two-block activity produces two allocation rows
    // ------------------------------------------------------------------

    @Test
    fun `a two block activity exports two allocation rows`() {
        val exported = PruningActivityExport.rows(sorted(activityA), includeCost = true)

        assertEquals(2, exported.size)
        assertEquals(listOf(1, 2), exported.map { it.allocationNumber })
        assertEquals(listOf(2, 2), exported.map { it.allocationCount })
        assertEquals(listOf("Pinot Noir", "Cabernet Franc"), exported.map { it.blockName })
        assertEquals(listOf("block 1 of 2", "block 2 of 2"), exported.map { it.allocationLabel })
        // The activity label is the linked Work Task title, never an id.
        assertTrue(exported.all { it.activityLabel == "Winter pruning" })
    }

    // ------------------------------------------------------------------
    // 2. Person-hours and labour cost appear only on the first row
    // ------------------------------------------------------------------

    @Test
    fun `activity totals appear on the first allocation row only`() {
        val exported = PruningActivityExport.rows(sorted(activityA), includeCost = true)
        val first = exported[0]
        val second = exported[1]

        assertTrue(first.isActivityTotalsRow)
        assertFalse(second.isActivityTotalsRow)

        assertEquals(6.0, first.operationalHours!!, 0.0001)
        assertEquals(18.0, first.personHours!!, 0.0001)
        assertEquals(630.0, first.labourCost!!, 0.0001)
        assertEquals("Pruning Crew", first.worker)
        assertEquals("07:00", first.startTime)
        assertEquals("13:00", first.finishTime)
        assertEquals(6.0, first.durationHours!!, 0.0001)
        assertEquals("Cold start frost delay", first.notes)

        // BLANK, not zero — a zero would claim a real recorded measurement.
        assertNull(second.operationalHours)
        assertNull(second.personHours)
        assertNull(second.labourCost)
        assertNull(second.worker)
        assertNull(second.startTime)
        assertNull(second.finishTime)
        assertNull(second.durationHours)
        assertNull(second.notes)

        // And the CSV cells for those columns are empty strings, not "0.00".
        val headers = PruningActivityExport.headers(includeCost = true)
        val cells = PruningActivityExport.cells(second, includeCost = true)
        for (column in listOf("Operational Hours", "Work Task Person-Hours", "Labour Cost", "Duration (h)")) {
            assertEquals("", cells[headers.indexOf(column)])
        }
    }

    // ------------------------------------------------------------------
    // 3. Allocation-specific quantities stay on every row
    // ------------------------------------------------------------------

    @Test
    fun `allocation quantities are present on every allocation row`() {
        val exported = PruningActivityExport.rows(sorted(activityA), includeCost = true)

        for (row in exported) {
            assertEquals(4, row.quarters)
            assertEquals(1.0, row.rowEquivalents, 0.0001)
            assertEquals(100.0, row.estimatedVines!!, 0.0001)
            assertTrue(row.blockName.isNotBlank())
            assertTrue(row.variety!!.isNotBlank())
            assertTrue(row.rowRange!!.isNotBlank())
            // Work Task title/status repeat: they are text and cannot be summed.
            assertEquals("Winter pruning", row.workTaskTitle)
            assertEquals("Completed", row.workTaskStatus)
        }
        assertEquals("90", exported[0].rowRange)
        assertEquals("1", exported[1].rowRange)
    }

    // ------------------------------------------------------------------
    // 4 + 5. Exported column sums equal the report summary
    // ------------------------------------------------------------------

    @Test
    fun `summing the exported labour cost column equals the report summary total`() {
        val rows = sorted()
        val summary = PruningActivityReport.summary(rows, includeCost = true)
        val exported = PruningActivityExport.rows(rows, includeCost = true)

        val exportedCost = PruningActivityExport.columnTotal(exported) { it.labourCost }
        assertEquals(930.0, summary.labourCost!!, 0.0001)
        assertEquals(summary.labourCost!!, exportedCost, 0.0001)
    }

    @Test
    fun `summing the exported person hours column equals the report summary total`() {
        val rows = sorted()
        val summary = PruningActivityReport.summary(rows, includeCost = true)
        val exported = PruningActivityExport.rows(rows, includeCost = true)

        val exportedHours = PruningActivityExport.columnTotal(exported) { it.personHours }
        // 18 (task lines) + 4 (legacy fallback) + 12 (task lines); reversed excluded.
        assertEquals(34.0, summary.labourHours, 0.0001)
        assertEquals(summary.labourHours, exportedHours, 0.0001)
    }

    // ------------------------------------------------------------------
    // 6. Single-allocation activities retain all activity totals
    // ------------------------------------------------------------------

    @Test
    fun `a single allocation activity keeps every activity total`() {
        val exported = PruningActivityExport.rows(sorted(activityB), includeCost = true)

        assertEquals(1, exported.size)
        val only = exported.single()
        assertTrue(only.isActivityTotalsRow)
        assertEquals(1, only.allocationNumber)
        assertEquals(1, only.allocationCount)
        assertEquals("whole activity", only.allocationLabel)
        assertEquals(4.0, only.operationalHours!!, 0.0001)
        assertEquals(4.0, only.personHours!!, 0.0001)
        assertEquals("Dave", only.worker)
    }

    // ------------------------------------------------------------------
    // 7. Three or more allocations still output totals once
    // ------------------------------------------------------------------

    @Test
    fun `a three allocation activity outputs totals exactly once`() {
        val exported = PruningActivityExport.rows(sorted(activityC), includeCost = true)

        assertEquals(3, exported.size)
        assertEquals(1, exported.count { it.isActivityTotalsRow })
        assertEquals(1, exported.count { it.personHours != null })
        assertEquals(1, exported.count { it.labourCost != null })
        assertEquals(1, exported.count { it.operationalHours != null })
        assertEquals(listOf("block 1 of 3", "block 2 of 3", "block 3 of 3"), exported.map { it.allocationLabel })
        assertEquals(12.0, exported[0].personHours!!, 0.0001)
        assertEquals(300.0, exported[0].labourCost!!, 0.0001)

        // Every allocation still carries its own block quantities.
        assertEquals(3.0, exported.sumOf { it.rowEquivalents }, 0.0001)
    }

    // ------------------------------------------------------------------
    // 8 + 9. Labour authority: task lines win; legacy only without lines
    // ------------------------------------------------------------------

    @Test
    fun `work task labour values take precedence over legacy activity values`() {
        val exported = PruningActivityExport.rows(sorted(activityA), includeCost = true).first()

        // The activity recorded 6 operational hours; the Work Task's labour
        // lines total 18 person-hours. Both are exported, in their OWN columns,
        // and the authoritative person-hours figure is the task's.
        assertEquals(6.0, exported.operationalHours!!, 0.0001)
        assertEquals(18.0, exported.personHours!!, 0.0001)
        assertEquals(630.0, exported.labourCost!!, 0.0001)
    }

    @Test
    fun `legacy activity values are used only when the task has no labour lines`() {
        val exported = PruningActivityExport.rows(sorted(activityB), includeCost = true).single()

        // No linked task, so the activity's own hours ARE the resolved value —
        // and there is no cost, because a legacy rate was never recorded.
        assertEquals(4.0, exported.operationalHours!!, 0.0001)
        assertEquals(4.0, exported.personHours!!, 0.0001)
        assertNull(exported.labourCost)
        assertNull(exported.workTaskTitle)
    }

    @Test
    fun `no allocation row ever combines both labour sources`() {
        val exported = PruningActivityExport.rows(sorted(), includeCost = true)

        // Exactly one totals row per activity, and the person-hours column has
        // one value per activity — never one per block.
        assertEquals(4, exported.count { it.isActivityTotalsRow })
        assertEquals(4, exported.count { it.personHours != null })
        // 2 + 1 + 3 + 2 allocations across the four activities.
        assertEquals(8, exported.size)
    }

    // ------------------------------------------------------------------
    // 10. Reversed activities stay visible but never inflate totals
    // ------------------------------------------------------------------

    @Test
    fun `reversed activities are exported marked and excluded from totals`() {
        val rows = sorted()
        val exported = PruningActivityExport.rows(rows, includeCost = true)
        val reversed = exported.filter { it.isReversed }

        // Both allocations of the reversed activity are still exported.
        assertEquals(2, reversed.size)
        assertEquals(listOf("Pinot Noir", "Cabernet Franc"), reversed.map { it.blockName })
        assertTrue(reversed.all { it.isReversed })
        // Its historical values are retained on the detail row, matching the
        // on-screen report...
        assertEquals(10.0, reversed[0].personHours!!, 0.0001)
        // ...but they never reach a total.
        val summary = PruningActivityReport.summary(rows, includeCost = true)
        assertEquals(2, summary.reversedRecords)
        assertEquals(930.0, summary.labourCost!!, 0.0001)
        assertEquals(
            summary.labourCost!!,
            PruningActivityExport.columnTotal(exported) { it.labourCost },
            0.0001,
        )
        // The Reversed column is what makes that filterable in a spreadsheet.
        val headers = PruningActivityExport.headers(includeCost = true)
        val cells = PruningActivityExport.cells(reversed[0], includeCost = true)
        assertEquals("Yes", cells[headers.indexOf("Reversed")])
    }

    // ------------------------------------------------------------------
    // 11. No internal identifier is ever exported
    // ------------------------------------------------------------------

    @Test
    fun `no work task allocation or activity identifier is exported`() {
        val csv = PruningActivityExport.csv(sorted(), includeCost = true)

        for (id in listOf("act-a", "act-b", "act-c", "act-d", "a1", "a2", "b1", "c1", "c2", "c3", "d1", "d2")) {
            assertFalse("CSV leaked the internal id $id", csv.contains(id))
        }
        for (id in listOf(taskA, taskC, taskD, blockPinot, blockCab, blockChard, "vineyard-1")) {
            assertFalse("CSV leaked the internal id $id", csv.contains(id))
        }
        // And no UUID-shaped value of any kind.
        val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        assertFalse(uuid.containsMatchIn(csv))
    }

    // ------------------------------------------------------------------
    // 12. Costing permission
    // ------------------------------------------------------------------

    @Test
    fun `labour cost is absent for roles without costing visibility`() {
        val rows = sorted()
        val headers = PruningActivityExport.headers(includeCost = false)
        assertFalse(headers.contains("Labour Cost"))
        // Hours stay visible — only money is withheld.
        assertTrue(headers.contains("Operational Hours"))
        assertTrue(headers.contains("Work Task Person-Hours"))

        val exported = PruningActivityExport.rows(rows, includeCost = false)
        assertTrue(exported.all { it.labourCost == null })
        assertTrue(exported.any { it.personHours != null })

        val csv = PruningActivityExport.csv(rows, includeCost = false)
        assertFalse(csv.contains("Labour Cost"))
        assertFalse(csv.contains("630"))
        // Every data line has exactly the same number of cells as the header.
        val lines = csv.trim().lines()
        assertEquals(rows.size + 1, lines.size)
        assertTrue(lines.all { it.split(",").size >= headers.size - 1 })
    }

    // ------------------------------------------------------------------
    // 13. Filters and sorting are preserved; groups stay contiguous
    // ------------------------------------------------------------------

    @Test
    fun `the export respects the active filter`() {
        val filter = PruningActivityFilter(blocks = setOf(blockChard))
        val filtered = PruningActivityReport.sorted(
            PruningActivityReport.filtered(build(allEntries), filter),
            PruningActivitySort.DEFAULT,
        )
        val exported = PruningActivityExport.rows(filtered, includeCost = true)

        assertEquals(2, exported.size)
        assertTrue(exported.all { it.blockName == "Chardonnay" })
        // Activity C's Chardonnay allocation is NOT the primary, so the activity
        // values — and even the linked Work Task's title — are genuinely absent
        // from this result. They stay blank rather than being borrowed from an
        // excluded sibling row.
        val cRow = exported.first { it.dateIso == "2026-08-05" }
        assertEquals(1, cRow.allocationNumber)
        assertEquals(1, cRow.allocationCount)
        assertNull(cRow.personHours)
        assertNull(cRow.labourCost)
        assertNull(cRow.workTaskTitle)
        // Activity B's only allocation IS the primary, so its totals survive.
        val bRow = exported.first { it.dateIso == "2026-08-04" }
        assertEquals(4.0, bRow.personHours!!, 0.0001)
        assertEquals("Dave", bRow.worker)
    }

    @Test
    fun `allocations of one activity are never scattered through the export`() {
        // Sorting by Block would interleave allocations from different
        // activities in the table; the export keeps each activity contiguous.
        val byBlock = PruningActivityReport.sorted(
            build(allEntries),
            PruningActivitySort(PruningActivityColumn.Block, ascending = true),
        )
        val exported = PruningActivityExport.rows(byBlock, includeCost = true)

        val groups = PruningActivityExport.groups(byBlock, includeCost = true)

        // Group ORDER follows the report's own visible order: each activity
        // ranks by where its first row appears in the sorted table.
        assertEquals(byBlock.map { it.activityKey }.distinct(), groups.map { it.activityKey })

        // Every activity is ONE contiguous run of rows — never scattered.
        val runs = exported.fold(mutableListOf<String>()) { acc, row ->
            val key = "${row.activityLabel}|${row.dateIso}"
            if (acc.lastOrNull() != key) acc.add(key)
            acc
        }
        assertEquals(runs.size, runs.distinct().size)
        assertEquals(groups.size, runs.size)

        // Within a group the PRIMARY allocation is always first, so the totals
        // row is row 1 regardless of the table's sort.
        for (group in groups) {
            assertEquals(1, group.allocations.first().allocationNumber)
            assertTrue(group.allocations.first().isActivityTotalsRow)
            assertEquals(1, group.allocations.count { it.isActivityTotalsRow })
        }
    }

    @Test
    fun `the export honours the sort direction of the table`() {
        val ascending = PruningActivityReport.sorted(
            build(allEntries),
            PruningActivitySort(PruningActivityColumn.Date, ascending = true),
        )
        val descending = PruningActivityReport.sorted(
            build(allEntries),
            PruningActivitySort(PruningActivityColumn.Date, ascending = false),
        )

        val first = PruningActivityExport.rows(ascending, includeCost = true).first()
        val last = PruningActivityExport.rows(descending, includeCost = true).first()
        assertEquals("2026-08-03", first.dateIso)
        assertEquals("2026-08-06", last.dateIso)
    }

    // ------------------------------------------------------------------
    // 14. CSV shape
    // ------------------------------------------------------------------

    @Test
    fun `csv keeps a raw iso date an australian display date and a totals flag`() {
        val csv = PruningActivityExport.csv(sorted(activityA), includeCost = true)
        val lines = csv.trim().lines()
        val headers = lines.first().split(",")
        val first = lines[1].split(",")
        val second = lines[2].split(",")

        assertEquals("Date (ISO)", headers[0])
        assertEquals("2026-08-03", first[0])
        assertEquals("03/08/2026", first[headers.indexOf("Activity Date")])
        assertEquals("Monday", first[headers.indexOf("Weekday")])
        assertEquals("Yes", first[headers.indexOf("Activity Totals Row")])
        assertEquals("No", second[headers.indexOf("Activity Totals Row")])
        // Hours and costs are NUMERIC, not quoted text.
        assertEquals("18.00", first[headers.indexOf("Work Task Person-Hours")])
        assertEquals("630.00", first[headers.indexOf("Labour Cost")])
    }

    @Test
    fun `csv quotes only values that need it`() {
        val withComma = activityA.map { entry ->
            if (entry.allocationIndex == 0) entry.copy(notes = "Frost delay, restarted 09:00") else entry
        }
        val csv = PruningActivityExport.csv(sorted(withComma), includeCost = true)

        assertTrue(csv.contains("\"Frost delay, restarted 09:00\""))
        // The plain values around it stay unquoted.
        assertTrue(csv.contains(",Pinot Noir,"))
    }

    // ------------------------------------------------------------------
    // 15. PDF grouped layout
    // ------------------------------------------------------------------

    @Test
    fun `pdf groups state activity labour once and list every allocation`() {
        val groups = PruningActivityExport.groups(sorted(), includeCost = true)

        assertEquals(4, groups.size)
        val a = groups.first { it.activityLabel == "Winter pruning" }
        assertEquals("Monday 3 August 2026", a.dateDisplay)
        assertEquals(2, a.allocationCount)
        assertTrue(a.isMultiBlock)
        assertEquals("Pinot Noir + Cabernet Franc", a.blockSummary)
        assertEquals(18.0, a.personHours!!, 0.0001)
        assertEquals(6.0, a.operationalHours!!, 0.0001)
        assertEquals(630.0, a.labourCost!!, 0.0001)
        assertEquals(2.0, a.totalRowEquivalents, 0.0001)
        assertEquals(200.0, a.totalVines, 0.0001)

        // Costing-blind roles get the same document with no money in it.
        val blind = PruningActivityExport.groups(sorted(), includeCost = false)
        assertTrue(blind.all { it.labourCost == null })
        assertTrue(blind.any { it.personHours != null })
    }

    // ------------------------------------------------------------------
    // 16. Cross-platform parity fixture
    // ------------------------------------------------------------------

    @Test
    fun `parity fixture produces the exact rows ios must also produce`() {
        val exported = PruningActivityExport.rows(sorted(activityA), includeCost = true)

        // These five tuples are asserted verbatim in the iOS twin.
        assertEquals(
            listOf(
                "2026-08-03|03/08/2026|Monday|Winter pruning|1|2|block 1 of 2|Pinot Noir|90|4|1.00|100|6.00|18.00|630.00|Yes|No",
                "2026-08-03|03/08/2026|Monday|Winter pruning|2|2|block 2 of 2|Cabernet Franc|1|4|1.00|100||||No|No",
            ),
            exported.map { row ->
                listOf(
                    row.dateIso,
                    row.dateDisplay,
                    row.weekday,
                    row.activityLabel,
                    row.allocationNumber.toString(),
                    row.allocationCount.toString(),
                    row.allocationLabel,
                    row.blockName,
                    row.rowRange.orEmpty(),
                    row.quarters.toString(),
                    PruningActivityExport.number(row.rowEquivalents, 2),
                    PruningActivityExport.number(row.estimatedVines, 0),
                    PruningActivityExport.number(row.operationalHours, 2),
                    PruningActivityExport.number(row.personHours, 2),
                    PruningActivityExport.number(row.labourCost, 2),
                    if (row.isActivityTotalsRow) "Yes" else "No",
                    if (row.isReversed) "Yes" else "No",
                ).joinToString("|")
            },
        )
    }
}
