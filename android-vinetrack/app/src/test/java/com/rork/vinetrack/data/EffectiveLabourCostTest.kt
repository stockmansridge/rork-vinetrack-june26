package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PieceRateCosting
import com.rork.vinetrack.data.model.PruningActivityAllocationModel
import com.rork.vinetrack.data.model.PruningActivityBlockContext
import com.rork.vinetrack.data.model.PruningActivityReport
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.WorkTaskPieceRateRow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * EFFECTIVE WORK TASK LABOUR COST (sql/188) — the Android twin of
 * `EffectiveLabourCostTests.swift`. Both suites assert the SAME fixtures, so
 * any divergence between the platforms fails a build.
 *
 * The rule under test, environment-wide:
 *
 * ```text
 * effectiveTaskLabourCost(task, labourLines) =
 *     costing_method == piece_rate  ->  piece vine count × piece rate per vine
 *     otherwise                     ->  Σ active labour line cost
 * ```
 *
 * The correction this suite locks in: a piece-rate job legitimately has NO
 * labour lines and NO hours, yet still has a real labour cost. Anywhere that
 * asks "what did this task's labour cost?" must return `$137.50` for:
 *
 * ```text
 * 250 vines · $0.55 / vine · no labour lines
 * ```
 *
 * and must NEVER add an hourly total to a piece-rate one.
 */
class EffectiveLabourCostTest {

    // -----------------------------------------------------------------
    // Shared fixture (identical on iOS)
    // -----------------------------------------------------------------

    private val vineyardId = "00000000-0000-0000-0000-0000000eff00"
    private val blockA = "00000000-0000-0000-0000-0000000eff01"
    private val blockB = "00000000-0000-0000-0000-0000000eff02"
    private val pieceTaskId = "00000000-0000-0000-0000-0000000eff03"
    private val hourlyTaskId = "00000000-0000-0000-0000-0000000eff04"
    private val legacyTaskId = "00000000-0000-0000-0000-0000000eff05"

    /** THE worked example: 250 vines at $0.55 each. */
    private val snapshotVines = 250
    private val ratePerVine = 0.55
    private val expectedPieceCost = 137.50

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /**
     * A piece-rate job with NO labour lines — the shape that used to report
     * "No labour recorded · $0.00".
     */
    private fun pieceRateTask() = WorkTask(
        id = pieceTaskId,
        vineyardId = vineyardId,
        paddockId = blockA,
        date = "2026-07-06",
        taskType = "Pruning",
        costingMethod = "piece_rate",
        pieceRatePerVine = ratePerVine,
        pieceVineCount = snapshotVines,
    )

    /** The unchanged hourly shape: 2 workers × 8 h × $30 = $480. */
    private fun hourlyTask() = WorkTask(
        id = hourlyTaskId,
        vineyardId = vineyardId,
        paddockId = blockA,
        date = "2026-07-06",
        taskType = "Pruning",
        costingMethod = "hourly",
    )

    /** A record written before sql/188 existed: no costing method at all. */
    private fun legacyTask() = WorkTask(
        id = legacyTaskId,
        vineyardId = vineyardId,
        paddockId = blockA,
        date = "2026-07-06",
        taskType = "Pruning",
        costingMethod = null,
    )

    private fun line(
        taskId: String,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
    ) = WorkTaskLabourLine(
        id = "line-$taskId-$workerCount-$hoursPerWorker-${hourlyRate ?: 0.0}",
        workTaskId = taskId,
        vineyardId = vineyardId,
        workerCount = workerCount,
        hoursPerWorker = hoursPerWorker,
        hourlyRate = hourlyRate,
    )

    /** 2 workers × 8 h × $30 = $480. */
    private fun hourlyLines(taskId: String) =
        listOf(line(taskId, workerCount = 2, hoursPerWorker = 8.0, hourlyRate = 30.0))

    private fun rowRef(number: Int) = PruningRowRef(
        rowId = null,
        number = number,
        label = "$number",
        lengthMetres = null,
        vines = 100.0,
        isFallback = true,
    )

    private fun contexts(vararg blocks: String): Map<String, PruningActivityBlockContext> =
        blocks.associateWith {
            PruningActivityBlockContext(
                name = if (it == blockA) "Block A" else "Block B",
                variety = if (it == blockA) "Shiraz" else "Riesling",
                rows = listOf(rowRef(1)),
            )
        }

    private fun entry(
        paddockId: String,
        quarters: Int,
        workTaskId: String?,
        labourHours: Double? = null,
        activityKey: String? = null,
        allocationIndex: Int = 0,
        id: String = "entry-$paddockId-$allocationIndex",
    ) = PruningEntry(
        id = id,
        vineyardId = vineyardId,
        paddockId = paddockId,
        date = "2026-07-06",
        segments = (1..quarters).map { PruningSegment(row = 1, quarter = it) },
        worker = "Sam",
        labourHours = labourHours,
        workTaskId = workTaskId,
        pruningActivityId = activityKey,
        allocationIndex = allocationIndex,
        createdAtMs = 1_780_000_000_000L,
    )

    // -----------------------------------------------------------------
    // 1–2. A piece-rate job has a cost with no labour lines at all
    // -----------------------------------------------------------------

    @Test
    fun `a piece-rate task with zero labour lines still has a valid labour cost`() {
        val cost = PieceRateCosting.effectiveLabourCost(pieceRateTask(), emptyList())
        // Not null, not zero — a real, complete cost record.
        assertNotNull(cost)
        assertTrue(cost!! > 0)
        assertEquals(expectedPieceCost, cost, 0.0001)
    }

    @Test
    fun `250 vines times 55 cents is 137 dollars 50`() {
        val cost = PieceRateCosting.cost(snapshotVines, ratePerVine)!!
        assertEquals(137.50, cost, 0.0001)
        assertEquals("$137.50", PieceRateCosting.currencyLabel(cost))
    }

    // -----------------------------------------------------------------
    // 3. Cost per vine reproduces the agreed rate
    // -----------------------------------------------------------------

    @Test
    fun `piece-rate cost per vine reproduces the agreed rate`() {
        val cost = PieceRateCosting.effectiveLabourCost(pieceRateTask(), emptyList())
        val perVine = PieceRateCosting.costPerVine(cost, snapshotVines)!!
        assertEquals(ratePerVine, perVine, 0.0001)
        assertEquals("$0.55", PieceRateCosting.rateLabel(perVine))
    }

    // -----------------------------------------------------------------
    // 4. Zero hours never zeroes a piece-rate cost
    // -----------------------------------------------------------------

    @Test
    fun `zero hours does not produce a zero piece-rate cost`() {
        val resolved = PieceRateCosting.resolve(pieceRateTask(), emptyList())
        assertEquals(0.0, resolved.hours, 0.0001)
        assertEquals(expectedPieceCost, resolved.cost!!, 0.0001)
        assertFalse(resolved.hoursAreOperationalOnly)
    }

    // -----------------------------------------------------------------
    // 5–6. Recorded hours are operational only, never additive
    // -----------------------------------------------------------------

    @Test
    fun `recorded operational hours do not change the piece-rate cost`() {
        // 6 person-hours recorded for productivity analysis.
        val lines = listOf(line(pieceTaskId, workerCount = 1, hoursPerWorker = 6.0, hourlyRate = null))
        val resolved = PieceRateCosting.resolve(pieceRateTask(), lines)
        assertEquals(6.0, resolved.hours, 0.0001)
        assertEquals(expectedPieceCost, resolved.cost!!, 0.0001)
        // The hours exist and are explicitly flagged as not the cost basis.
        assertTrue(resolved.hoursAreOperationalOnly)
        // Vines per hour remains available for operational analysis.
        assertEquals(41.6666, snapshotVines / resolved.hours, 0.001)
    }

    @Test
    fun `rated labour lines kept for history are never added to the piece-rate total`() {
        // These lines would total $480 on their own.
        val lines = hourlyLines(pieceTaskId)
        assertEquals(480.0, WorkTaskLabourCosting.totalCost(lines)!!, 0.0001)

        val cost = PieceRateCosting.effectiveLabourCost(pieceRateTask(), lines)!!
        // The piece-rate total, NOT $480 and NOT $617.50.
        assertEquals(expectedPieceCost, cost, 0.0001)
        assertNotEquals(480.0, cost)
        assertNotEquals(expectedPieceCost + 480.0, cost)
    }

    // -----------------------------------------------------------------
    // 7–8. Hourly and legacy behaviour is untouched
    // -----------------------------------------------------------------

    @Test
    fun `an hourly task continues to use its labour-line total`() {
        val cost = PieceRateCosting.effectiveLabourCost(hourlyTask(), hourlyLines(hourlyTaskId))!!
        // 2 × 8 × $30 = $480 — the pre-existing rule, byte for byte.
        assertEquals(480.0, cost, 0.0001)
        // An hourly task with no lines is "not specified", never $0.00.
        assertNull(PieceRateCosting.effectiveLabourCost(hourlyTask(), emptyList()))
    }

    @Test
    fun `a legacy task with no costing method continues to use its labour-line total`() {
        val task = legacyTask()
        assertEquals(WorkTaskCostingMethod.HOURLY, task.resolvedCostingMethod)
        assertFalse(task.isPieceRate)
        val cost = PieceRateCosting.effectiveLabourCost(task, hourlyLines(legacyTaskId))!!
        assertEquals(480.0, cost, 0.0001)
        // A legacy task is never given piece-rate figures by inference.
        assertNull(task.pieceRateCost)
    }

    // -----------------------------------------------------------------
    // 9. Work Task LIST shows a piece-rate cost
    // -----------------------------------------------------------------

    @Test
    fun `the work task list cost map includes a piece-rate task that has no labour lines`() {
        val tasks = listOf(pieceRateTask(), hourlyTask(), legacyTask())
        val lines = hourlyLines(hourlyTaskId) + hourlyLines(legacyTaskId)

        val costs = PieceRateCosting.effectiveCostsByWorkTask(tasks, lines)

        // The piece-rate job appears even though it contributed no labour line.
        assertEquals(expectedPieceCost, costs[pieceTaskId]!!, 0.0001)
        assertEquals(480.0, costs[hourlyTaskId]!!, 0.0001)
        assertEquals(480.0, costs[legacyTaskId]!!, 0.0001)

        // The old labour-line-only map is exactly what was wrong: it drops the
        // piece-rate job entirely.
        assertNull(WorkTaskLabourCosting.costsByWorkTask(lines)[pieceTaskId])
    }

    @Test
    fun `costing visibility still hides every money value`() {
        val costs = PieceRateCosting.effectiveCostsByWorkTask(
            tasks = listOf(pieceRateTask()),
            labourLines = emptyList(),
            includeCost = false,
        )
        assertTrue(costs.isEmpty())
    }

    // -----------------------------------------------------------------
    // 10. Work Task DETAIL shows a piece-rate cost
    // -----------------------------------------------------------------

    @Test
    fun `work task detail resolves a piece-rate cost, cost per vine and operational hours`() {
        val lines = listOf(line(pieceTaskId, workerCount = 2, hoursPerWorker = 3.0, hourlyRate = null))
        val resolved = PieceRateCosting.resolve(pieceRateTask(), lines)

        assertEquals(WorkTaskCostingMethod.PIECE_RATE, resolved.method)
        assertEquals(snapshotVines, resolved.vineCount)
        assertEquals(ratePerVine, resolved.ratePerVine!!, 0.0001)
        assertEquals(expectedPieceCost, resolved.cost!!, 0.0001)
        // Labour + machine roll-ups take the labour component from here, so a
        // piece-rate task never contributes zero to a task total.
        val machine = 220.0
        assertEquals(357.50, resolved.cost!! + machine, 0.0001)
    }

    // -----------------------------------------------------------------
    // 11. Pruning Tracker / activity summary
    // -----------------------------------------------------------------

    @Test
    fun `the pruning activity summary reports the piece-rate cost rather than no labour recorded`() {
        val labour = PieceRateCosting.resolveActivityLabour(
            task = pieceRateTask(),
            lines = emptyList(),
            legacyHours = null,
            legacyRate = null,
        )
        // A dedicated source — never NONE, which is what rendered "$0.00".
        assertEquals(WorkTaskLabourCosting.LabourSource.PIECE_RATE, labour.source)
        assertFalse(labour.isLegacy)
        assertEquals(expectedPieceCost, labour.cost!!, 0.0001)
    }

    @Test
    fun `an hourly activity and a legacy activity keep their existing sources`() {
        val hourly = PieceRateCosting.resolveActivityLabour(
            task = hourlyTask(),
            lines = hourlyLines(hourlyTaskId),
            legacyHours = null,
            legacyRate = null,
        )
        assertEquals(WorkTaskLabourCosting.LabourSource.WORK_TASK_LINES, hourly.source)
        assertEquals(480.0, hourly.cost!!, 0.0001)

        // No task at all: the pre-sql/188 legacy fallback is untouched.
        val legacy = PieceRateCosting.resolveActivityLabour(
            task = null,
            lines = emptyList(),
            legacyHours = 7.5,
            legacyRate = 40.0,
        )
        assertEquals(WorkTaskLabourCosting.LabourSource.LEGACY_ACTIVITY, legacy.source)
        assertEquals(300.0, legacy.cost!!, 0.0001)
    }

    // -----------------------------------------------------------------
    // 12. Pruning report / summary
    // -----------------------------------------------------------------

    @Test
    fun `a pruning report row for a piece-rate job carries its cost and cost per vine`() {
        val task = pieceRateTask()
        val rows = PruningActivityReport.rows(
            entries = listOf(entry(blockA, quarters = 2, workTaskId = pieceTaskId)),
            blocks = contexts(blockA),
            workTaskTitles = mapOf(pieceTaskId to "Pruning — Block A"),
            labourCosts = PieceRateCosting.effectiveCostsByWorkTask(listOf(task), emptyList()),
            labourHours = emptyMap(),
            pieceRateVines = PieceRateCosting.snapshotVinesByWorkTask(listOf(task)),
            accountNames = emptyMap(),
        )

        val row = rows.first()
        assertEquals(expectedPieceCost, row.labourCost!!, 0.0001)
        assertEquals(snapshotVines, row.pieceRateVines)
        assertEquals(ratePerVine, row.costPerVine!!, 0.0001)
        // Zero hours does not blank the cost.
        assertNull(row.labourHours)

        // The summary carries the same money through.
        val summary = PruningActivityReport.summary(rows, includeCost = true)
        assertEquals(expectedPieceCost, summary.labourCost!!, 0.0001)
    }

    @Test
    fun `an hourly report row keeps its labour-line cost and reports no cost per vine`() {
        val task = hourlyTask()
        val lines = hourlyLines(hourlyTaskId)
        val rows = PruningActivityReport.rows(
            entries = listOf(entry(blockA, quarters = 1, workTaskId = hourlyTaskId, labourHours = 4.0)),
            blocks = contexts(blockA),
            workTaskTitles = emptyMap(),
            labourCosts = PieceRateCosting.effectiveCostsByWorkTask(listOf(task), lines),
            labourHours = WorkTaskLabourCosting.hoursByWorkTask(lines),
            pieceRateVines = PieceRateCosting.snapshotVinesByWorkTask(listOf(task)),
            accountNames = emptyMap(),
        )

        val row = rows.first()
        assertEquals(480.0, row.labourCost!!, 0.0001)
        assertNull(row.pieceRateVines)
        assertNull(row.costPerVine)
        assertEquals(16.0, row.labourHours!!, 0.0001)
    }

    // -----------------------------------------------------------------
    // 13. Multi-block allocation adds back to the task total
    // -----------------------------------------------------------------

    @Test
    fun `a multi-block piece-rate activity allocates the task total and adds back exactly`() {
        // A $1,000.00 piece-rate job split 60/40 by row equivalents.
        val bigTask = WorkTask(
            id = pieceTaskId,
            vineyardId = vineyardId,
            date = "2026-07-06",
            taskType = "Pruning",
            costingMethod = "piece_rate",
            pieceRatePerVine = 0.50,
            pieceVineCount = 2_000,
        )
        assertEquals(1_000.0, bigTask.pieceRateCost!!, 0.0001)

        val activityKey = "activity-multi-block"
        // 3 quarters + 2 quarters → 0.75 / 0.50 row equivalents (60% / 40%).
        val rows = PruningActivityReport.rows(
            entries = listOf(
                entry(blockA, quarters = 3, workTaskId = pieceTaskId, activityKey = activityKey, allocationIndex = 0),
                entry(blockB, quarters = 2, workTaskId = pieceTaskId, activityKey = activityKey, allocationIndex = 1),
            ),
            blocks = contexts(blockA, blockB),
            workTaskTitles = emptyMap(),
            labourCosts = PieceRateCosting.effectiveCostsByWorkTask(listOf(bigTask), emptyList()),
            labourHours = emptyMap(),
            pieceRateVines = PieceRateCosting.snapshotVinesByWorkTask(listOf(bigTask)),
            accountNames = emptyMap(),
        )
        assertEquals(2, rows.size)

        val model = PruningActivityAllocationModel.build(rows, includeCost = true)
        val parent = model.parent(activityKey)!!
        // The amount being allocated is the task's EFFECTIVE labour cost.
        assertEquals(1_000.0, parent.labourCost!!, 0.0001)

        val allocated = rows.mapNotNull { model.share(it.id)?.labourCost }
        assertEquals(2, allocated.size)
        assertEquals(1_000.0, allocated.sum(), 0.0001)
        // 60 / 40 of $1,000.00, and the split never invents or loses a cent.
        assertEquals(600.0, allocated.maxOrNull()!!, 0.0001)
        assertEquals(400.0, allocated.minOrNull()!!, 0.0001)
    }

    // -----------------------------------------------------------------
    // 14. Cost per hectare uses the effective cost
    // -----------------------------------------------------------------

    @Test
    fun `cost per hectare divides the effective labour cost by the area`() {
        val cost = PieceRateCosting.effectiveLabourCost(pieceRateTask(), emptyList())
        val perHa = PieceRateCosting.costPerHectare(cost, 0.4911)!!
        // $137.50 / 0.4911 ha ~ $279.98 / ha.
        assertEquals(279.98, perHa, 0.01)
        // An unknown denominator never renders as a number.
        assertNull(PieceRateCosting.costPerHectare(cost, 0.0))
        assertNull(PieceRateCosting.costPerHectare(cost, null))
    }

    // -----------------------------------------------------------------
    // 15. Cost per vine uses the HISTORICAL snapshot
    // -----------------------------------------------------------------

    @Test
    fun `cost per vine uses the snapshot quantity, never today's vineyard geometry`() {
        val task = pieceRateTask()
        val cost = PieceRateCosting.effectiveLabourCost(task, emptyList())

        // The block is later re-mapped and now carries 900 vines. The finished
        // job's cost per vine must not move.
        val todaysGeometry = 900
        val historical = PieceRateCosting.costPerVine(cost, task.pieceVineCount)!!
        val wrong = PieceRateCosting.costPerVine(cost, todaysGeometry)!!
        assertEquals(ratePerVine, historical, 0.0001)
        assertNotEquals(ratePerVine, wrong)
        assertEquals(snapshotVines, task.pieceVineCount)
    }

    // -----------------------------------------------------------------
    // 16. Offline / cache round trip
    // -----------------------------------------------------------------

    @Test
    fun `an offline cache round trip preserves the effective piece-rate cost`() {
        val original = pieceRateTask()
        val restored = json.decodeFromString(WorkTask.serializer(), json.encodeToString(WorkTask.serializer(), original))

        // Every field the cost depends on survives the round trip…
        assertEquals(WorkTaskCostingMethod.PIECE_RATE, restored.resolvedCostingMethod)
        assertEquals(snapshotVines, restored.pieceVineCount)
        assertEquals(ratePerVine, restored.pieceRatePerVine!!, 0.0001)
        // …so the cost is available from the LOCAL record alone: no portal, no
        // labour line, no second fetch.
        assertEquals(
            expectedPieceCost,
            PieceRateCosting.effectiveLabourCost(restored, emptyList())!!,
            0.0001,
        )

        // The row snapshots survive too, and still reconcile to the quantity.
        val snapshot = listOf(
            WorkTaskPieceRateRow(
                id = "snap-1",
                workTaskId = pieceTaskId,
                vineyardId = vineyardId,
                paddockId = blockA,
                rowNumber = 1,
                vineCount = 125,
            ),
            WorkTaskPieceRateRow(
                id = "snap-2",
                workTaskId = pieceTaskId,
                vineyardId = vineyardId,
                paddockId = blockA,
                rowNumber = 2,
                vineCount = 125,
            ),
        )
        val serializer = ListSerializer(WorkTaskPieceRateRow.serializer())
        val restoredRows = json.decodeFromString(serializer, json.encodeToString(serializer, snapshot))
        assertEquals(snapshotVines, PieceRateCosting.vineCountForSelectedRows(restoredRows))
    }

    // -----------------------------------------------------------------
    // 17. Cross-platform parity anchors
    // -----------------------------------------------------------------

    @Test
    fun `the parity anchors both platforms must reproduce exactly`() {
        // These five numbers are asserted identically in the Swift twin.
        assertEquals(137.50, PieceRateCosting.cost(250, 0.55)!!, 0.0001)
        assertEquals(0.55, PieceRateCosting.costPerVine(137.50, 250)!!, 0.0001)
        assertEquals(279.98, PieceRateCosting.costPerHectare(137.50, 0.4911)!!, 0.01)
        assertEquals(
            137.50,
            PieceRateCosting.effectiveLabourCost(pieceRateTask(), hourlyLines(pieceTaskId))!!,
            0.0001,
        )
        assertEquals(
            480.0,
            PieceRateCosting.effectiveLabourCost(hourlyTask(), hourlyLines(hourlyTaskId))!!,
            0.0001,
        )
    }

    private fun assertNotEquals(unexpected: Double, actual: Double) {
        assertTrue("expected $actual to differ from $unexpected", kotlin.math.abs(actual - unexpected) > 0.0001)
    }
}
