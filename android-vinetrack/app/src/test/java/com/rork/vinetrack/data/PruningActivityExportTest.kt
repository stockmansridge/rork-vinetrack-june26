package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityAllocationModel
import com.rork.vinetrack.data.model.PruningActivityBlockContext
import com.rork.vinetrack.data.model.PruningActivityColumn
import com.rork.vinetrack.data.model.PruningActivityExport
import com.rork.vinetrack.data.model.PruningActivityConflictResolution
import com.rork.vinetrack.data.model.PruningActivityFilter
import com.rork.vinetrack.data.model.PruningActivityParentField
import com.rork.vinetrack.data.model.PruningActivityParentSource
import com.rork.vinetrack.data.model.PruningActivityReport
import com.rork.vinetrack.data.model.PruningActivityRow
import com.rork.vinetrack.data.model.PruningActivitySort
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.PruningSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SHARED EXPORT FIXTURE — the same cases and the same numbers exist as
 * `PruningActivityExportTests.swift` in the iOS test target. Both platforms must
 * produce identical allocation shares, identical allocated labour and identical
 * partial-activity markers from this fixture.
 *
 * The fixture covers every shape that could mis-attribute labour:
 *
 *  * A — two blocks, equal size, Work Task labour lines (18 person-hours, $630)
 *  * B — one block, NO labour lines (legacy activity hours only, 4.0)
 *  * C — three blocks, equal size, Work Task labour lines (12 person-hours, $300)
 *  * D — two blocks, REVERSED (10 person-hours, $200 — must never be totalled)
 *  * E — two blocks, UNEQUAL (0.50 + 2.00 row equivalents), 13 person-hours,
 *        $455. This is the worked example from the brief: filtering to the
 *        0.50-row-equivalent block must yield a 20% share, 2.60 person-hours
 *        and $91.00 — never the whole $455.
 */
class PruningActivityExportTest {

    private val blockPinot = "block-pinot"
    private val blockCab = "block-cab"
    private val blockChard = "block-chard"
    private val blockPrim = "block-prim"

    private val taskA = "task-a"
    private val taskC = "task-c"
    private val taskD = "task-d"
    private val taskE = "task-e"

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
        blockPrim to PruningActivityBlockContext("Primitivo", "Primitivo", rowRefs((20..24).toList())),
    )

    /** One whole row = four quarters = 1.00 row equivalents. */
    private fun wholeRow(number: Int): List<PruningSegment> =
        (1..4).map { PruningSegment(number, it) }

    /** A part row — two quarters = 0.50 row equivalents. */
    private fun halfRow(number: Int): List<PruningSegment> =
        (1..2).map { PruningSegment(number, it) }

    private fun allocation(
        id: String,
        activityId: String,
        allocationIndex: Int,
        paddockId: String,
        day: Int,
        rowNumber: Int = 0,
        segments: List<PruningSegment>? = null,
        worker: String = "Pruning Crew",
        /**
         * The legacy MIRROR of the activity's own values, stored on the primary
         * allocation. The report must never depend on this row surviving a
         * filter to know the activity has labour.
         */
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
        segments = segments ?: wholeRow(rowNumber),
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

    /** A — two equal blocks, Work Task labour lines. */
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

    /** C — three equal blocks, Work Task labour lines. */
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

    /**
     * E — the worked example. Cabernet Franc 0.50 row equivalents (PRIMARY),
     * Primitivo 2.00 (SECONDARY), 2.50 total, 13 person-hours, $455.
     */
    private val activityE = listOf(
        allocation(
            id = "e1", activityId = "act-e", allocationIndex = 0, paddockId = blockCab,
            day = 7, segments = halfRow(5), operationalHours = 7.0,
            start = "06:30", finish = "13:30", notes = "Two block sweep",
            workTaskId = taskE,
        ),
        allocation(
            id = "e2", activityId = "act-e", allocationIndex = 1, paddockId = blockPrim,
            day = 7, segments = wholeRow(20) + wholeRow(21),
        ),
    )

    /**
     * X — a CORRUPTED activity. Its two allocations disagree about the worker,
     * the Work Task, the labour and the timing. This cannot happen through the
     * app; it happens through a half-applied sync or a stale legacy mirror.
     */
    private val activityX = listOf(
        allocation(
            id = "x1", activityId = "act-x", allocationIndex = 0, paddockId = blockPinot,
            day = 3, rowNumber = 93, worker = "Dan", operationalHours = 6.0,
            start = "07:00", finish = "13:00", workTaskId = taskA,
        ),
        allocation(
            id = "x2", activityId = "act-x", allocationIndex = 1, paddockId = blockCab,
            day = 3, rowNumber = 4, worker = "Sam", operationalHours = 9.0,
            start = "08:30", finish = "17:00", workTaskId = taskC,
        ),
    )

    /** A UUID-shaped record, for the identifier tests. */
    private val uuidActivityId = "3f2a1b7c-9d4e-4c11-8f0a-1b2c3d4e5f60"
    private val uuidAllocationId = "8c7b6a59-4d3e-4210-9f8e-7d6c5b4a3921"
    private val activityU = listOf(
        allocation(
            id = uuidAllocationId, activityId = uuidActivityId, allocationIndex = 0,
            paddockId = blockPinot, day = 3, rowNumber = 94, operationalHours = 3.0,
            workTaskId = taskA,
        ),
    )

    private val titles = mapOf(
        taskA to "Winter pruning",
        taskC to "Spur pruning block sweep",
        taskD to "Reversed pruning",
        taskE to "Vineyard block pruning",
    )

    private val statuses = mapOf(
        taskA to "Completed",
        taskC to "In progress",
        taskD to "Completed",
        taskE to "Completed",
    )

    /** Summed Work Task labour lines — the AUTHORITATIVE labour source. */
    private val taskHours = mapOf(taskA to 18.0, taskC to 12.0, taskD to 10.0, taskE to 13.0)
    private val taskCosts = mapOf(taskA to 630.0, taskC to 300.0, taskD to 200.0, taskE to 455.0)

    private fun build(entries: List<PruningEntry>): List<PruningActivityRow> =
        PruningActivityReport.rows(
            entries = entries,
            blocks = contexts,
            workTaskTitles = titles,
            workTaskStatuses = statuses,
            labourCosts = taskCosts,
            labourHours = taskHours,
        )

    private val allEntries = activityA + activityB + activityC + activityD + activityE

    private fun sorted(entries: List<PruningEntry> = allEntries): List<PruningActivityRow> =
        PruningActivityReport.sorted(build(entries), PruningActivitySort.DEFAULT)

    /** The canonical (unfiltered) rows for one activity. */
    private fun canonicalE(): List<PruningActivityRow> = sorted(activityE)

    /** Filters a canonical set down to one block, as the report's filter does. */
    private fun onlyBlock(
        canonical: List<PruningActivityRow>,
        paddockId: String,
    ): List<PruningActivityRow> = PruningActivityReport.sorted(
        PruningActivityReport.filtered(canonical, PruningActivityFilter(blocks = setOf(paddockId))),
        PruningActivitySort.DEFAULT,
    )

    // ------------------------------------------------------------------
    // 1. Two-block activity filtered to the PRIMARY block
    // ------------------------------------------------------------------

    @Test
    fun `a two block activity filtered to the primary block reports a partial activity`() {
        val canonical = canonicalE()
        val filtered = onlyBlock(canonical, blockCab)
        val exported = PruningActivityExport.rows(filtered, includeCost = true, canonicalRows = canonical)

        val row = exported.single()
        assertEquals("Cabernet Franc", row.blockName)
        assertEquals(1, row.allocationNumber)
        assertEquals(2, row.fullAllocationCount)
        assertEquals(1, row.includedAllocationCount)
        assertTrue(row.isPartialActivity)
        assertEquals("block 1 of 2 (1 shown)", row.allocationLabel)

        // The brief's worked example, exactly.
        assertEquals(0.20, row.allocationShare!!, 0.000001)
        assertEquals(2.60, row.allocatedPersonHours!!, 0.0001)
        assertEquals(91.00, row.allocatedLabourCost!!, 0.0001)

        // The WHOLE activity's totals are still stated, and still whole.
        assertTrue(row.isActivityTotalsRow)
        assertEquals(13.0, row.activityPersonHours!!, 0.0001)
        assertEquals(455.0, row.activityLabourCost!!, 0.0001)
    }

    // ------------------------------------------------------------------
    // 2. Two-block activity filtered to the SECONDARY block
    // ------------------------------------------------------------------

    @Test
    fun `a two block activity filtered to the secondary block keeps its parent context`() {
        val canonical = canonicalE()
        val filtered = onlyBlock(canonical, blockPrim)
        val exported = PruningActivityExport.rows(filtered, includeCost = true, canonicalRows = canonical)

        val row = exported.single()
        assertEquals("Primitivo", row.blockName)
        // The allocation keeps its TRUE position in the parent — it is still the
        // second allocation, even though it is the only one shown.
        assertEquals(2, row.allocationNumber)
        assertEquals(2, row.fullAllocationCount)
        assertEquals(1, row.includedAllocationCount)
        assertTrue(row.isPartialActivity)
        assertEquals("block 2 of 2 (1 shown)", row.allocationLabel)

        assertEquals(0.80, row.allocationShare!!, 0.000001)
        assertEquals(10.40, row.allocatedPersonHours!!, 0.0001)
        assertEquals(364.00, row.allocatedLabourCost!!, 0.0001)

        // The legacy primary allocation was filtered out, and the whole-activity
        // totals are STILL present. This is the regression that matters most:
        // the parent owns these values, not the primary allocation row.
        assertTrue(row.isActivityTotalsRow)
        assertEquals(13.0, row.activityPersonHours!!, 0.0001)
        assertEquals(455.0, row.activityLabourCost!!, 0.0001)
        assertEquals(7.0, row.activityOperationalHours!!, 0.0001)
        assertEquals(7.0, row.activityDurationHours!!, 0.0001)
        assertEquals("Two block sweep", row.notes)
    }

    // ------------------------------------------------------------------
    // 3. A secondary-only result still carries allocated hours and cost
    // ------------------------------------------------------------------

    @Test
    fun `a secondary only result still reports allocated hours and cost`() {
        val canonical = canonicalE()
        val filtered = onlyBlock(canonical, blockPrim)
        val exported = PruningActivityExport.rows(filtered, includeCost = true, canonicalRows = canonical)
        val row = exported.single()

        assertNotNull(row.allocatedPersonHours)
        assertNotNull(row.allocatedLabourCost)

        // And they reach the CSV as real numbers, not blanks.
        val headers = PruningActivityExport.headers(includeCost = true)
        val cells = PruningActivityExport.cells(row, includeCost = true)
        assertEquals("10.40", cells[headers.indexOf("Allocated Person-Hours")])
        assertEquals("364.00", cells[headers.indexOf("Allocated Labour Cost")])
        assertEquals("80.00", cells[headers.indexOf("Allocation Share (%)")])
    }

    // ------------------------------------------------------------------
    // 4. Parent Work Task and worker survive the filter
    // ------------------------------------------------------------------

    @Test
    fun `the parent work task and worker remain available on a secondary allocation`() {
        val canonical = canonicalE()
        val filtered = onlyBlock(canonical, blockPrim)
        val exported = PruningActivityExport.rows(filtered, includeCost = true, canonicalRows = canonical)
        val row = exported.single()

        assertEquals("Vineyard block pruning", row.workTaskTitle)
        assertEquals("Completed", row.workTaskStatus)
        assertEquals("Vineyard block pruning", row.activityLabel)
        assertEquals("Pruning Crew", row.worker)
        assertEquals("06:30", row.startTime)
        assertEquals("13:30", row.finishTime)
        assertTrue(row.method.isNotBlank())

        // The same is true in the grouped PDF layout.
        val group = PruningActivityExport.groups(filtered, includeCost = true, canonicalRows = canonical).single()
        assertEquals("Vineyard block pruning", group.workTaskTitle)
        assertEquals("Pruning Crew", group.worker)
        assertEquals("Partial activity — 1 of 2 blocks shown", group.partialLabel)
    }

    // ------------------------------------------------------------------
    // 5. The allocation share uses the FULL activity denominator
    // ------------------------------------------------------------------

    @Test
    fun `the allocation share uses the full activity denominator not the filtered subset`() {
        val canonical = canonicalE()

        // Filtered to the 2.00-row-equivalent block. Its OWN row equivalents are
        // the only ones in the result, so a subset denominator would give 100%.
        val filtered = onlyBlock(canonical, blockPrim)
        val row = PruningActivityExport
            .rows(filtered, includeCost = true, canonicalRows = canonical)
            .single()

        assertEquals(2.0, row.rowEquivalents, 0.0001)
        assertEquals(0.80, row.allocationShare!!, 0.000001)

        // The denominator is the parent's 2.50, not the surviving 2.00.
        val parent = PruningActivityAllocationModel.build(canonical, includeCost = true).parent("act-e")!!
        assertEquals(2.5, parent.rowEquivalents, 0.0001)
        assertEquals(row.rowEquivalents / parent.rowEquivalents, row.allocationShare!!, 0.000001)
    }

    // ------------------------------------------------------------------
    // 6. The partial marker is present, and absent when complete
    // ------------------------------------------------------------------

    @Test
    fun `the partial activity marker is present only when allocations are missing`() {
        val canonical = canonicalE()
        val headers = PruningActivityExport.headers(includeCost = true)

        val partial = PruningActivityExport
            .rows(onlyBlock(canonical, blockPrim), includeCost = true, canonicalRows = canonical)
            .single()
        assertTrue(partial.isPartialActivity)
        assertEquals("Yes", PruningActivityExport.cells(partial, includeCost = true)[headers.indexOf("Partial Activity")])

        val complete = PruningActivityExport.rows(canonical, includeCost = true, canonicalRows = canonical)
        assertEquals(2, complete.size)
        assertTrue(complete.none { it.isPartialActivity })
        for (row in complete) {
            assertEquals("No", PruningActivityExport.cells(row, includeCost = true)[headers.indexOf("Partial Activity")])
            assertEquals(2, row.includedAllocationCount)
        }
    }

    // ------------------------------------------------------------------
    // 7. An included allocation's cost never inflates to 100%
    // ------------------------------------------------------------------

    @Test
    fun `an included allocation cost never inflates to the whole activity`() {
        val canonical = canonicalE()

        for ((paddockId, expectedCost) in listOf(blockCab to 91.00, blockPrim to 364.00)) {
            val row = PruningActivityExport
                .rows(onlyBlock(canonical, paddockId), includeCost = true, canonicalRows = canonical)
                .single()
            assertEquals(expectedCost, row.allocatedLabourCost!!, 0.0001)
            assertTrue(
                "an allocated cost must never equal the whole activity's",
                row.allocatedLabourCost!! < 455.0,
            )
        }

        // The two filtered slices add back up to the parent exactly.
        assertEquals(455.0, 91.00 + 364.00, 0.0001)
    }

    // ------------------------------------------------------------------
    // 8. Parent totals appear exactly once
    // ------------------------------------------------------------------

    @Test
    fun `whole activity totals appear on exactly one row per activity`() {
        val rows = sorted()
        val exported = PruningActivityExport.rows(rows, includeCost = true)

        // One totals row per activity, and only totals rows carry parent values.
        val totalsRows = exported.filter { it.isActivityTotalsRow }
        assertEquals(exported.map { it.activityId }.distinct().size, totalsRows.size)
        assertEquals(totalsRows.map { it.activityId }, totalsRows.map { it.activityId }.distinct())

        for (row in exported.filterNot { it.isActivityTotalsRow }) {
            assertNull(row.activityPersonHours)
            assertNull(row.activityLabourCost)
            assertNull(row.activityOperationalHours)
            assertNull(row.activityDurationHours)
            assertNull(row.notes)
        }

        // De-duplicating by activity id gives the true whole-activity total;
        // 18 + 4 + 12 + 13, with the reversed activity excluded.
        assertEquals(47.0, PruningActivityExport.activityTotal(exported) { it.activityPersonHours }, 0.0001)
        assertEquals(1385.0, PruningActivityExport.activityTotal(exported) { it.activityLabourCost }, 0.0001)
    }

    // ------------------------------------------------------------------
    // 9. Allocated totals equal the filtered summary
    // ------------------------------------------------------------------

    @Test
    fun `allocated column totals equal the filtered summary`() {
        val canonical = sorted()

        // Cabernet Franc appears in A (1.00 of 2.00), C (1.00 of 3.00),
        // D (reversed) and E (0.50 of 2.50).
        val filtered = onlyBlock(canonical, blockCab)
        val summary = PruningActivityReport.summary(filtered, includeCost = true, canonicalRows = canonical)
        val exported = PruningActivityExport.rows(filtered, includeCost = true, canonicalRows = canonical)

        val hours = PruningActivityExport.columnTotal(exported) { it.allocatedPersonHours }
        val cost = PruningActivityExport.columnTotal(exported) { it.allocatedLabourCost }

        // 9.00 (A) + 4.00 (C) + 2.60 (E); D is reversed and excluded.
        assertEquals(15.60, summary.labourHours, 0.0001)
        assertEquals(summary.labourHours, hours, 0.0001)
        // 315.00 (A) + 100.00 (C) + 91.00 (E).
        assertEquals(506.00, summary.labourCost!!, 0.0001)
        assertEquals(summary.labourCost!!, cost, 0.0001)

        // The whole-activity figures are larger, and de-duplicated by activity.
        assertEquals(43.0, summary.wholeActivityLabourHours, 0.0001)
        assertEquals(1385.0, summary.wholeActivityLabourCost!!, 0.0001)
        assertEquals(3, summary.activities)
        assertEquals(3, summary.partialActivities)
        assertTrue(summary.hasPartialActivities)
    }

    // ------------------------------------------------------------------
    // 10. Unfiltered allocated totals reconcile exactly to the parents
    // ------------------------------------------------------------------

    @Test
    fun `unfiltered allocated totals reconcile exactly to the parent totals`() {
        val rows = sorted()
        val exported = PruningActivityExport.rows(rows, includeCost = true)
        val summary = PruningActivityReport.summary(rows, includeCost = true)

        val allocatedHours = PruningActivityExport.columnTotal(exported) { it.allocatedPersonHours }
        val allocatedCost = PruningActivityExport.columnTotal(exported) { it.allocatedLabourCost }
        val parentHours = PruningActivityExport.activityTotal(exported) { it.activityPersonHours }
        val parentCost = PruningActivityExport.activityTotal(exported) { it.activityLabourCost }

        assertEquals(parentHours, allocatedHours, 0.0001)
        assertEquals(parentCost, allocatedCost, 0.0001)
        assertEquals(47.0, allocatedHours, 0.0001)
        assertEquals(1385.0, allocatedCost, 0.0001)

        // With nothing filtered out, the two summary figures agree and nothing
        // is marked partial.
        assertEquals(summary.wholeActivityLabourHours, summary.labourHours, 0.0001)
        assertEquals(summary.wholeActivityLabourCost!!, summary.labourCost!!, 0.0001)
        assertEquals(0, summary.partialActivities)

        // Per activity, too — never just in aggregate.
        for (group in PruningActivityExport.groups(rows, includeCost = true)) {
            group.activityPersonHours?.let { parent ->
                assertEquals(parent, group.allocatedPersonHours!!, 0.0001)
            }
            group.activityLabourCost?.let { parent ->
                assertEquals(parent, group.allocatedLabourCost!!, 0.0001)
            }
        }
    }

    // ------------------------------------------------------------------
    // 11. The rounding remainder is assigned deterministically
    // ------------------------------------------------------------------

    @Test
    fun `the rounding remainder is assigned deterministically and always reconciles`() {
        // Three equal blocks sharing 10 person-hours and $100 — neither divides
        // evenly into cents, so a naive split would lose or gain a cent.
        val entries = (0..2).map { index ->
            allocation(
                id = "r$index", activityId = "act-r", allocationIndex = index,
                paddockId = listOf(blockPinot, blockCab, blockChard)[index],
                day = 8, rowNumber = index + 1,
                operationalHours = if (index == 0) 3.0 else null,
                workTaskId = "task-r",
            )
        }
        val rows = PruningActivityReport.sorted(
            PruningActivityReport.rows(
                entries = entries,
                blocks = contexts,
                workTaskTitles = mapOf("task-r" to "Rounding sweep"),
                labourCosts = mapOf("task-r" to 100.0),
                labourHours = mapOf("task-r" to 10.0),
            ),
            PruningActivitySort.DEFAULT,
        )
        val exported = PruningActivityExport.rows(rows, includeCost = true)

        // The remainder lands on the SAME allocation every run, on both
        // platforms: cumulative rounding puts it on the middle share here.
        assertEquals(
            listOf(3.33, 3.34, 3.33),
            exported.map { PruningActivityAllocationModel.roundTo(it.allocatedPersonHours!!, 2) },
        )
        assertEquals(
            listOf(33.33, 33.34, 33.33),
            exported.map { PruningActivityAllocationModel.roundTo(it.allocatedLabourCost!!, 2) },
        )

        // And the parts reconcile to the parent to the cent.
        assertEquals(10.0, PruningActivityExport.columnTotal(exported) { it.allocatedPersonHours }, 0.0000001)
        assertEquals(100.0, PruningActivityExport.columnTotal(exported) { it.allocatedLabourCost }, 0.0000001)
    }

    // ------------------------------------------------------------------
    // 12. Removing costing permission strips BOTH cost fields
    // ------------------------------------------------------------------

    @Test
    fun `removing costing permission strips both the parent and the allocated cost`() {
        val rows = sorted()

        val headers = PruningActivityExport.headers(includeCost = false)
        assertFalse(headers.contains("Allocated Labour Cost"))
        assertFalse(headers.contains("Activity Total Labour Cost"))
        // Hours survive — only money is withheld.
        assertTrue(headers.contains("Allocated Person-Hours"))
        assertTrue(headers.contains("Activity Person-Hours"))

        val exported = PruningActivityExport.rows(rows, includeCost = false)
        assertTrue(exported.all { it.allocatedLabourCost == null })
        assertTrue(exported.all { it.activityLabourCost == null })
        assertTrue(exported.any { it.allocatedPersonHours != null })

        // The values are absent from the FILE, not merely hidden in a renderer.
        val csv = PruningActivityExport.csv(rows, includeCost = false)
        for (amount in listOf("455.00", "364.00", "630.00", "315.00", "91.00")) {
            assertFalse("cost $amount leaked into a cost-blind export", csv.contains(amount))
        }

        val groups = PruningActivityExport.groups(rows, includeCost = false)
        assertTrue(groups.all { it.activityLabourCost == null && it.allocatedLabourCost == null })
        // The report's own summary withholds it too.
        assertNull(PruningActivityReport.summary(rows, includeCost = false).labourCost)
        assertNull(PruningActivityReport.summary(rows, includeCost = false).wholeActivityLabourCost)
    }

    // ------------------------------------------------------------------
    // 13. Allocation quantities stay on every row
    // ------------------------------------------------------------------

    @Test
    fun `allocation quantities are present on every allocation row`() {
        val exported = PruningActivityExport.rows(sorted(activityA), includeCost = true)

        assertEquals(2, exported.size)
        for (row in exported) {
            assertEquals(4, row.quarters)
            assertEquals(1.0, row.rowEquivalents, 0.0001)
            assertEquals(100.0, row.estimatedVines!!, 0.0001)
            assertTrue(row.blockName.isNotBlank())
            assertTrue(row.variety!!.isNotBlank())
            assertTrue(row.rowRange!!.isNotBlank())
            // Parent context repeats: it is text, it cannot be summed, and
            // repeating it keeps a wide spreadsheet readable when scrolled.
            assertEquals("Winter pruning", row.workTaskTitle)
            assertEquals("Completed", row.workTaskStatus)
            assertEquals("Pruning Crew", row.worker)
            assertEquals("07:00", row.startTime)
            // Equal blocks, so an even split of the activity's labour.
            assertEquals(0.5, row.allocationShare!!, 0.000001)
            assertEquals(9.0, row.allocatedPersonHours!!, 0.0001)
            assertEquals(315.0, row.allocatedLabourCost!!, 0.0001)
        }
        assertEquals("90", exported[0].rowRange)
        assertEquals("1", exported[1].rowRange)
    }

    // ------------------------------------------------------------------
    // 14. The labour authority order is unchanged
    // ------------------------------------------------------------------

    @Test
    fun `work task labour lines win and the legacy value is only a fallback`() {
        // A has BOTH 6.0 legacy operational hours and 18.0 task person-hours.
        // The task wins for person-hours; the legacy value stays visible as the
        // separate operational figure and is never added to it.
        val a = PruningActivityExport.rows(sorted(activityA), includeCost = true).first()
        assertEquals(18.0, a.activityPersonHours!!, 0.0001)
        assertEquals(6.0, a.activityOperationalHours!!, 0.0001)
        // Never 24.0 — the two sources are reported side by side, never summed.
        assertEquals(9.0, a.allocatedPersonHours!!, 0.0001)

        // B has no task at all, so the legacy activity value IS the labour.
        val b = PruningActivityExport.rows(sorted(activityB), includeCost = true).single()
        assertEquals(4.0, b.activityPersonHours!!, 0.0001)
        assertEquals(4.0, b.allocatedPersonHours!!, 0.0001)
        assertNull(b.activityLabourCost)
        assertNull(b.allocatedLabourCost)
        assertEquals("whole activity", b.allocationLabel)
    }

    // ------------------------------------------------------------------
    // 15. Reversed activities are visible but never totalled
    // ------------------------------------------------------------------

    @Test
    fun `reversed activities are exported but excluded from every total`() {
        val rows = sorted()
        val exported = PruningActivityExport.rows(rows, includeCost = true)
        val reversed = exported.filter { it.isReversed }

        assertEquals(2, reversed.size)
        assertTrue(reversed.all { it.activityLabel == "Reversed pruning" })
        // Their allocated values still exist on the row — the audit trail is
        // complete — they are simply never summed.
        assertTrue(reversed.all { it.allocatedPersonHours != null })
        assertEquals(47.0, PruningActivityExport.columnTotal(exported) { it.allocatedPersonHours }, 0.0001)
        assertEquals(1385.0, PruningActivityExport.columnTotal(exported) { it.allocatedLabourCost }, 0.0001)

        val headers = PruningActivityExport.headers(includeCost = true)
        val cells = PruningActivityExport.cells(reversed[0], includeCost = true)
        assertEquals("Yes", cells[headers.indexOf("Reversed")])
    }

    // ------------------------------------------------------------------
    // 16. Identifiers are exported, but never as the human-readable name
    // ------------------------------------------------------------------

    @Test
    fun `identifiers are exported for reconciliation but never as the activity name`() {
        val exported = PruningActivityExport.rows(sorted(), includeCost = true)

        for (row in exported) {
            assertTrue(row.activityId.isNotBlank())
            assertTrue(row.allocationId.isNotBlank())
            // The readable label is a Work Task title or a method — never an id.
            assertFalse(row.activityLabel.contains(row.activityId))
            assertFalse(row.activityLabel.contains(row.allocationId))
        }

        // Every allocation of one activity shares its activity id, and each
        // allocation id is unique across the file.
        val a = exported.filter { it.activityLabel == "Winter pruning" }
        assertEquals(1, a.map { it.activityId }.distinct().size)
        assertEquals(exported.size, exported.map { it.allocationId }.distinct().size)
    }

    // ------------------------------------------------------------------
    // 17. The export respects the active filter and sort
    // ------------------------------------------------------------------

    @Test
    fun `the export respects the active filter`() {
        val canonical = sorted()
        val filtered = onlyBlock(canonical, blockChard)
        val exported = PruningActivityExport.rows(filtered, includeCost = true, canonicalRows = canonical)

        // Chardonnay appears in B (whole activity) and C (one of three).
        assertEquals(2, exported.size)
        assertTrue(exported.all { it.blockName == "Chardonnay" })

        val b = exported.first { it.dateIso == "2026-08-04" }
        assertFalse(b.isPartialActivity)
        assertEquals(4.0, b.activityPersonHours!!, 0.0001)

        val c = exported.first { it.dateIso == "2026-08-05" }
        assertTrue(c.isPartialActivity)
        assertEquals(3, c.allocationNumber)
        assertEquals(3, c.fullAllocationCount)
        assertEquals(1, c.includedAllocationCount)
        // Parent context survives even though C's primary was filtered out.
        assertEquals("Spur pruning block sweep", c.workTaskTitle)
        assertEquals(12.0, c.activityPersonHours!!, 0.0001)
        // But only a third of the labour is attributed to this block.
        assertEquals(4.0, c.allocatedPersonHours!!, 0.0001)
        assertEquals(100.0, c.allocatedLabourCost!!, 0.0001)
    }

    @Test
    fun `the export follows the report sort direction`() {
        val rows = build(allEntries)
        val ascending = PruningActivityReport.sorted(
            rows,
            PruningActivitySort(PruningActivityColumn.Date, ascending = true),
        )
        val descending = PruningActivityReport.sorted(
            rows,
            PruningActivitySort(PruningActivityColumn.Date, ascending = false),
        )

        val first = PruningActivityExport.rows(ascending, includeCost = true).first()
        val last = PruningActivityExport.rows(descending, includeCost = true).first()
        assertEquals("2026-08-03", first.dateIso)
        assertEquals("2026-08-07", last.dateIso)
    }

    // ------------------------------------------------------------------
    // 18. Allocations of one activity stay contiguous under any sort
    // ------------------------------------------------------------------

    @Test
    fun `allocations of one activity stay contiguous whatever the sort`() {
        val byBlock = PruningActivityReport.sorted(
            build(allEntries),
            PruningActivitySort(PruningActivityColumn.Block, ascending = true),
        )
        val exported = PruningActivityExport.rows(byBlock, includeCost = true)
        val groups = PruningActivityExport.groups(byBlock, includeCost = true)

        // Group ORDER follows the report's own visible order.
        assertEquals(byBlock.map { it.activityKey }.distinct(), groups.map { it.activityId })

        // Every activity is ONE contiguous run of rows — never scattered.
        val runs = exported.fold(mutableListOf<String>()) { acc, row ->
            if (acc.lastOrNull() != row.activityId) acc.add(row.activityId)
            acc
        }
        assertEquals(runs.size, runs.distinct().size)
        assertEquals(groups.size, runs.size)

        // Within a group the canonical order holds, so the totals row is row 1.
        for (group in groups) {
            assertEquals(
                group.allocations.map { it.allocationNumber }.sorted(),
                group.allocations.map { it.allocationNumber },
            )
            assertTrue(group.allocations.first().isActivityTotalsRow)
            assertTrue(group.allocations.drop(1).none { it.isActivityTotalsRow })
        }
    }

    // ------------------------------------------------------------------
    // 19. CSV shape, quoting and numeric formatting
    // ------------------------------------------------------------------

    @Test
    fun `the csv has one header row and one row per allocation`() {
        val csv = PruningActivityExport.csv(sorted(), includeCost = true)
        val lines = csv.trimEnd('\r', '\n').split("\r\n")

        assertEquals(10 + 1, lines.size)
        assertTrue(csv.endsWith("\r\n"))
        assertEquals(
            PruningActivityExport.headers(includeCost = true).size,
            lines[0].split(",").size,
        )
    }

    @Test
    fun `csv values are quoted only when they contain a delimiter`() {
        val withComma = listOf(
            allocation(
                id = "q1", activityId = "act-q", allocationIndex = 0, paddockId = blockPinot,
                day = 3, rowNumber = 90, operationalHours = 2.0,
                notes = "Rain, then hail",
            ),
        )
        val csv = PruningActivityExport.csv(sorted(withComma), includeCost = true)

        assertTrue(csv.contains("\"Rain, then hail\""))
        // Numbers are never quoted, so a spreadsheet reads them as numbers.
        assertTrue(csv.contains(",2.00,"))
        assertFalse(csv.contains("\"2.00\""))
    }

    @Test
    fun `the csv keeps a raw iso date an australian display date and a totals flag`() {
        val csv = PruningActivityExport.csv(sorted(activityA), includeCost = true)
        val lines = csv.trimEnd('\r', '\n').split("\r\n")
        val headers = lines[0].split(",")
        val first = lines[1].split(",")
        val second = lines[2].split(",")

        assertEquals("2026-08-03", first[headers.indexOf("Date (ISO)")])
        assertEquals("03/08/2026", first[headers.indexOf("Activity Date")])
        assertEquals("Monday", first[headers.indexOf("Weekday")])
        assertEquals("Yes", first[headers.indexOf("Activity Totals Row")])
        assertEquals("No", second[headers.indexOf("Activity Totals Row")])
        // The parent totals column is blank on the second row, not "0.00".
        assertEquals("", second[headers.indexOf("Activity Person-Hours")])
        // But its allocated share is populated.
        assertEquals("9.00", second[headers.indexOf("Allocated Person-Hours")])
    }

    // ------------------------------------------------------------------
    // 20. The PDF grouping states the labour once
    // ------------------------------------------------------------------

    @Test
    fun `the pdf groups allocations under one activity heading`() {
        val groups = PruningActivityExport.groups(sorted(), includeCost = true)

        assertEquals(5, groups.size)
        assertEquals(10, groups.sumOf { it.includedAllocationCount })

        val a = groups.first { it.activityLabel == "Winter pruning" }
        assertEquals(2, a.includedAllocationCount)
        assertFalse(a.isPartialActivity)
        assertNull(a.partialLabel)
        assertEquals("Pinot Noir + Cabernet Franc", a.blockSummary)
        assertEquals(2.0, a.totalRowEquivalents, 0.0001)
        // Stated ONCE for the whole activity, whatever the allocation count.
        assertEquals(18.0, a.activityPersonHours!!, 0.0001)
        assertEquals(630.0, a.activityLabourCost!!, 0.0001)
        assertEquals(18.0, a.allocatedPersonHours!!, 0.0001)

        val e = groups.first { it.activityLabel == "Vineyard block pruning" }
        assertEquals("Cabernet Franc + Primitivo", e.blockSummary)
        assertEquals(listOf(2.60, 10.40), e.allocations.map { it.allocatedPersonHours })
    }

    // ------------------------------------------------------------------
    // 21. The PDF names the activity and never prints a full UUID
    // ------------------------------------------------------------------

    @Test
    fun `the pdf uses the activity name and a short reference never a full id`() {
        val group = PruningActivityExport.groups(sorted(activityU), includeCost = true).single()

        // The label is the human-readable Work Task title.
        assertEquals("Winter pruning", group.activityLabel)

        // The short reference is the first eight characters — and a PREFIX of
        // the full id, so matching the PDF to the CSV is a "starts with".
        assertEquals("3f2a1b7c", group.shortReference)
        assertEquals(8, group.shortReference.length)
        assertTrue(uuidActivityId.startsWith(group.shortReference))
        assertEquals("Ref 3f2a1b7c", PruningActivityExport.referenceLine(group, includeShortReferences = true))
        assertNull(PruningActivityExport.referenceLine(group, includeShortReferences = false))

        // Nothing a reader sees in the body carries the full UUID.
        val body = listOf(
            group.activityLabel,
            group.dateDisplay,
            group.blockSummary,
            PruningActivityExport.referenceLine(group, includeShortReferences = true).orEmpty(),
        ) + group.allocations.map { "${it.allocationLabel} ${it.blockName}" }
        for (line in body) {
            assertFalse("a full activity id leaked into the PDF body", line.contains(uuidActivityId))
            assertFalse("a full allocation id leaked into the PDF body", line.contains(uuidAllocationId))
        }
    }

    @Test
    fun `full ids stay in the csv and in the optional technical references`() {
        val rows = sorted(activityU)

        // The CSV keeps them — it is the reconciliation artefact.
        val csv = PruningActivityExport.csv(rows, includeCost = true)
        assertTrue(csv.contains(uuidActivityId))
        assertTrue(csv.contains(uuidAllocationId))

        // The PDF keeps them only in the opt-in appendix.
        val group = PruningActivityExport.groups(rows, includeCost = true).single()
        val technical = PruningActivityExport.technicalReferenceLines(group)
        assertEquals("Winter pruning — ${group.dateDisplay}", technical.first())
        assertTrue(technical.contains("Activity ID: $uuidActivityId"))
        assertTrue(technical.contains("Allocation 1 (Pinot Noir): $uuidAllocationId"))
        assertEquals("Technical references", PruningActivityExport.TECHNICAL_REFERENCES_HEADING)
    }

    @Test
    fun `a short reference tolerates short and empty ids`() {
        assertEquals("act-e", PruningActivityExport.shortReference("act-e"))
        assertEquals("", PruningActivityExport.shortReference("   "))
        assertEquals("3f2a1b7c", PruningActivityExport.shortReference(uuidActivityId))
    }

    // ------------------------------------------------------------------
    // 22. Conflicting parent values are FLAGGED, never silently chosen
    // ------------------------------------------------------------------

    @Test
    fun `allocations that disagree about their parent raise a context conflict`() {
        val canonical = sorted(activityX)
        val model = PruningActivityAllocationModel.build(canonical, includeCost = true)

        assertTrue("a corrupted mirror must not resolve silently", model.hasConflicts)
        assertEquals(setOf("act-x"), model.conflictedActivityIds)

        val fields = model.conflicts("act-x").map { it.field }.toSet()
        // Worker, Work Task, labour and timing — the four the brief names.
        assertTrue(fields.contains(PruningActivityParentField.WORKER))
        assertTrue(fields.contains(PruningActivityParentField.WORK_TASK))
        assertTrue(fields.contains(PruningActivityParentField.PERSON_HOURS))
        assertTrue(fields.contains(PruningActivityParentField.LABOUR_COST))
        assertTrue(fields.contains(PruningActivityParentField.START_TIME))
        assertTrue(fields.contains(PruningActivityParentField.OPERATIONAL_HOURS))

        // BOTH competing values are reported, not just the winner.
        val worker = model.conflicts("act-x").first { it.field == PruningActivityParentField.WORKER }
        assertEquals(listOf("Dan", "Sam"), worker.values)
        assertEquals("Dan", worker.resolvedValue)
        // With no canonical parent the choice is an unverified guess, and says so.
        assertEquals(PruningActivityConflictResolution.FIRST_ALLOCATION, worker.resolution)
        assertTrue(worker.description.contains("act-x"))
        assertTrue(worker.description.contains("Dan vs Sam"))
        assertTrue(worker.description.contains("unverified"))

        val hours = model.conflicts("act-x").first { it.field == PruningActivityParentField.PERSON_HOURS }
        assertEquals(listOf("18.0000", "12.0000"), hours.values)

        // The parent still renders — a blank report would be worse — but it is
        // marked, and the export still balances against whatever it chose.
        val parent = model.parent("act-x")!!
        assertTrue(parent.hasContextConflict)
        assertFalse(parent.resolvedFromCanonicalParent)
        assertEquals("Dan", parent.worker)
        assertEquals(18.0, parent.personHours!!, 0.0001)

        val exported = PruningActivityExport.rows(canonical, includeCost = true)
        assertEquals(18.0, PruningActivityExport.columnTotal(exported) { it.allocatedPersonHours }, 0.0001)

        // And the reader is told, in the PDF, before they act on the number.
        assertEquals(
            "1 activity has conflicting source records — verify against the portal",
            PruningActivityExport.conflictNotice(1),
        )
        assertEquals(
            "2 activities have conflicting source records — verify against the portal",
            PruningActivityExport.conflictNotice(2),
        )
        assertNull(PruningActivityExport.conflictNotice(0))
    }

    // ------------------------------------------------------------------
    // 23. The canonical parent outranks the allocation mirror
    // ------------------------------------------------------------------

    @Test
    fun `the canonical activity parent wins whenever it is available`() {
        val canonical = sorted(activityX)
        val parents = mapOf(
            "act-x" to PruningActivityParentSource(
                activityId = "act-x",
                worker = "Site Crew",
                personHours = 20.0,
                labourCost = 500.0,
                startTime = "05:45",
            ),
        )
        val model = PruningActivityAllocationModel.build(canonical, includeCost = true, canonicalParents = parents)
        val parent = model.parent("act-x")!!

        // The canonical record decides — not the first allocation.
        assertTrue(parent.resolvedFromCanonicalParent)
        assertEquals("Site Crew", parent.worker)
        assertEquals(20.0, parent.personHours!!, 0.0001)
        assertEquals(500.0, parent.labourCost!!, 0.0001)
        assertEquals("05:45", parent.startTime)

        // The disagreement is still REPORTED — preferring the parent fixes the
        // reading, not the underlying data.
        assertTrue(parent.hasContextConflict)
        val worker = model.conflicts("act-x").first { it.field == PruningActivityParentField.WORKER }
        assertEquals(PruningActivityConflictResolution.CANONICAL_PARENT, worker.resolution)
        assertEquals(listOf("Site Crew", "Dan", "Sam"), worker.values)
        assertEquals("Site Crew", worker.resolvedValue)
        assertTrue(worker.description.contains("canonical activity record"))

        // And the allocated shares divide the CANONICAL labour, not the mirror's.
        val exported = PruningActivityExport.rows(
            canonical,
            includeCost = true,
            canonicalRows = canonical,
            canonicalParents = parents,
        )
        assertEquals(listOf(10.0, 10.0), exported.map { it.allocatedPersonHours })
        assertEquals(listOf(250.0, 250.0), exported.map { it.allocatedLabourCost })
        assertEquals(20.0, exported.first().activityPersonHours!!, 0.0001)
    }

    // ------------------------------------------------------------------
    // 24. A legacy mirror is NOT a conflict
    // ------------------------------------------------------------------

    @Test
    fun `legacy projected rows with a single populated allocation raise no conflict`() {
        // The whole fixture is legacy-shaped: allocation 0 carries the activity
        // values, the rest carry none. That is expected, not corrupt.
        val model = PruningActivityAllocationModel.build(sorted(), includeCost = true)
        assertFalse(model.hasConflicts)
        assertTrue(model.conflicts.isEmpty())
        for (activityId in listOf("act-a", "act-b", "act-c", "act-d", "act-e")) {
            assertFalse(model.parent(activityId)!!.hasContextConflict)
        }

        // A canonical parent that AGREES with the mirror is not a conflict either.
        val agreeing = PruningActivityAllocationModel.build(
            canonicalE(),
            includeCost = true,
            canonicalParents = mapOf(
                "act-e" to PruningActivityParentSource(
                    activityId = "act-e",
                    worker = "Pruning Crew",
                    personHours = 13.0,
                    labourCost = 455.0,
                ),
            ),
        )
        assertFalse(agreeing.hasConflicts)
        assertTrue(agreeing.parent("act-e")!!.resolvedFromCanonicalParent)
    }

    // ------------------------------------------------------------------
    // 25. Cross-platform parity fixture — iOS must produce this exactly
    // ------------------------------------------------------------------

    @Test
    fun `the parity fixture matches the ios export byte for byte`() {
        val canonical = canonicalE()
        val exported = PruningActivityExport.rows(canonical, includeCost = true)

        val rendered = exported.joinToString("\n") { row ->
            listOf(
                row.dateIso,
                row.dateDisplay,
                row.weekday,
                row.activityLabel,
                row.allocationNumber.toString(),
                row.fullAllocationCount.toString(),
                row.includedAllocationCount.toString(),
                if (row.isPartialActivity) "partial" else "complete",
                row.allocationLabel,
                row.blockName,
                row.variety.orEmpty(),
                PruningActivityExport.number(row.rowEquivalents, 2),
                PruningActivityExport.number(row.allocationShare?.let { it * 100.0 }, 2),
                PruningActivityExport.number(row.allocatedPersonHours, 2),
                PruningActivityExport.number(row.allocatedLabourCost, 2),
                PruningActivityExport.number(row.activityPersonHours, 2),
                PruningActivityExport.number(row.activityLabourCost, 2),
                if (row.isActivityTotalsRow) "Yes" else "No",
            ).joinToString("|")
        }

        assertEquals(
            "2026-08-07|07/08/2026|Friday|Vineyard block pruning|1|2|2|complete|block 1 of 2|" +
                "Cabernet Franc|Cabernet Franc|0.50|20.00|2.60|91.00|13.00|455.00|Yes\n" +
                "2026-08-07|07/08/2026|Friday|Vineyard block pruning|2|2|2|complete|block 2 of 2|" +
                "Primitivo|Primitivo|2.00|80.00|10.40|364.00|||No",
            rendered,
        )
    }
}
