package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.BlockPruningSelection
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningActivityLabourLine
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRUNING-OWNED LABOUR LINES (sql/190) — the Android twin of
 * `PruningActivityLabourLineTests.swift`. Both suites assert the SAME fixtures
 * as the SQL suite, so any divergence between the three fails a build.
 *
 * The two rules this suite exists to lock in:
 *
 * ```text
 * hours = Σ EVERY active line          (unrated lines included)
 * cost  = Σ RATED lines only           (null, never $0.00, when none is rated)
 * ```
 *
 * and the ownership rule:
 *
 * > Labour is PRUNING-OWNED. A linked Work Task never gets a copy; it resolves
 * > THROUGH to the same rows. Never add a task's labour to an activity's.
 */
class PruningActivityLabourLineTest {

    // ---- Shared fixture (identical on iOS and in SQL) --------------------

    private val vineyardId = "00000000-0000-0000-0000-000000190a00"
    private val otherVineyardId = "00000000-0000-0000-0000-000000190a01"
    private val activityId = "00000000-0000-0000-0000-000000190a02"
    private val otherActivityId = "00000000-0000-0000-0000-000000190a03"
    private val hourlyTaskId = "00000000-0000-0000-0000-000000190a04"
    private val pieceTaskId = "00000000-0000-0000-0000-000000190a05"
    private val blockA = "00000000-0000-0000-0000-000000190a06"
    private val blockB = "00000000-0000-0000-0000-000000190a07"
    private val blockC = "00000000-0000-0000-0000-000000190a08"
    private val lineOneId = "00000000-0000-0000-0000-000000190b01"
    private val lineTwoId = "00000000-0000-0000-0000-000000190b02"

    /** THE worked example: 2 people × 8 h @ $30 = 16 h, $480. */
    private val expectedOneLineHours = 16.0
    private val expectedOneLineCost = 480.0

    /** Plus 1 person × 6 h @ $35 = $210 → 22 h, $690. */
    private val expectedTwoLineHours = 22.0
    private val expectedTwoLineCost = 690.0

    /** The legacy scalar pair: 7.5 h × $32 = $240. */
    private val legacyHours = 7.5
    private val legacyRate = 32.0
    private val expectedLegacyCost = 240.0

    /** Piece rate: 250 vines × $0.55 = $137.50. */
    private val snapshotVines = 250
    private val ratePerVine = 0.55
    private val expectedPieceCost = 137.50

    private val eps = 0.0001

    private fun line(
        id: String = "line-${System.nanoTime()}",
        activity: String = activityId,
        vineyard: String = vineyardId,
        workerCount: Int,
        hoursPerWorker: Double,
        hourlyRate: Double?,
        lineIndex: Int = 0,
    ) = PruningActivityLabourLine(
        id = id,
        pruningActivityId = activity,
        vineyardId = vineyard,
        workDate = "2026-08-03",
        workerType = "Pruner",
        workerCount = workerCount,
        hoursPerWorker = hoursPerWorker,
        hourlyRate = hourlyRate,
        lineIndex = lineIndex,
    )

    /** 2 × 8 h @ $30 = 16 h, $480. */
    private fun oneLine() = listOf(
        line(id = lineOneId, workerCount = 2, hoursPerWorker = 8.0, hourlyRate = 30.0, lineIndex = 0),
    )

    /** The above plus 1 × 6 h @ $35 = $210 → 22 h, $690. */
    private fun twoLines() = oneLine() + listOf(
        line(id = lineTwoId, workerCount = 1, hoursPerWorker = 6.0, hourlyRate = 35.0, lineIndex = 1),
    )

    private fun hourlyTask() = WorkTask(
        id = hourlyTaskId,
        vineyardId = vineyardId,
        paddockId = blockA,
        date = "2026-08-03",
        taskType = "Pruning",
        costingMethod = "hourly",
    )

    private fun pieceRateTask() = WorkTask(
        id = pieceTaskId,
        vineyardId = vineyardId,
        paddockId = blockA,
        date = "2026-08-03",
        taskType = "Pruning",
        costingMethod = "piece_rate",
        pieceRatePerVine = ratePerVine,
        pieceVineCount = snapshotVines,
    )

    private fun taskLine(workerCount: Int, hoursPerWorker: Double, hourlyRate: Double?) =
        WorkTaskLabourLine(
            id = "task-line-$workerCount-$hoursPerWorker",
            workTaskId = hourlyTaskId,
            vineyardId = vineyardId,
            workerCount = workerCount,
            hoursPerWorker = hoursPerWorker,
            hourlyRate = hourlyRate,
        )

    /** An activity spanning THREE blocks — labour must still be counted once. */
    private fun multiBlockDraft(workTaskId: String? = null) = PruningActivityDraft(
        id = activityId,
        vineyardId = vineyardId,
        date = "2026-08-03",
        worker = "Crew A",
        workTaskId = workTaskId,
        allocations = listOf(blockA, blockB, blockC).mapIndexed { index, block ->
            block to BlockPruningSelection(
                paddockId = block,
                blockName = "Block ${index + 1}",
                segments = listOf(PruningSegment(row = index + 1, quarter = 1)),
                estimatedVines = 100,
            )
        }.toMap(),
    )

    /**
     * The local twin of the DESIRED-STATE save: the payload IS the whole set,
     * deduplicated on the client id, renumbered by position. Replaying the same
     * payload must therefore be a no-op.
     */
    private fun applyDesiredState(
        desired: List<PruningActivityLabourLine>,
        into: List<PruningActivityLabourLine>,
        activity: String = activityId,
    ): List<PruningActivityLabourLine> {
        val kept = into.filterNot { it.pruningActivityId == activity }.toMutableList()
        val seen = mutableSetOf<String>()
        desired.forEachIndexed { index, line ->
            if (seen.add(line.id)) {
                kept += line.copy(pruningActivityId = activity, lineIndex = index)
            }
        }
        return kept
    }

    // ---- 1. ONE line ----------------------------------------------------

    @Test
    fun `one labour line is 16 hours and 480 dollars`() {
        val lines = oneLine()
        assertEquals(expectedOneLineHours, PruningActivityLabourCosting.totalHours(lines)!!, eps)
        assertEquals(expectedOneLineCost, PruningActivityLabourCosting.totalCost(lines)!!, eps)

        val totals = PruningActivityLabourCosting.totals(lines)
        assertEquals(1, totals.lineCount)
        assertEquals(2, totals.workers)
        assertEquals(expectedOneLineHours, totals.personHours, eps)
        assertEquals(expectedOneLineCost, totals.cost!!, eps)
    }

    // ---- 2. MULTIPLE lines ----------------------------------------------

    @Test
    fun `multiple labour lines sum to 22 hours and 690 dollars`() {
        val lines = twoLines()
        assertEquals(expectedTwoLineHours, PruningActivityLabourCosting.totalHours(lines)!!, eps)
        assertEquals(expectedTwoLineCost, PruningActivityLabourCosting.totalCost(lines)!!, eps)

        // Resolution must pick the activity's OWN lines, and say so.
        val resolved = PruningActivityLabourCosting.resolve(
            task = null,
            activityLines = lines,
            taskLines = emptyList(),
            legacyHours = null,
            legacyRate = null,
        )
        assertEquals(PruningActivityLabourCosting.Source.PRUNING_LABOUR_LINES, resolved.source)
        assertEquals(2, resolved.lineCount)
        assertEquals(expectedTwoLineHours, resolved.hours!!, eps)
        assertEquals(expectedTwoLineCost, resolved.cost!!, eps)
    }

    @Test
    fun `lines are ordered by line index so a crew list cannot reshuffle`() {
        val shuffled = listOf(twoLines()[1], twoLines()[0])
        val ordered = PruningActivityLabourCosting.linesFor(shuffled, activityId)
        assertEquals(listOf(lineOneId, lineTwoId), ordered.map { it.id })
    }

    // ---- 3. ADD / EDIT / REMOVE -----------------------------------------

    @Test
    fun `add edit and remove a labour line through the desired state set`() {
        // ADD the first line.
        var set = applyDesiredState(oneLine(), emptyList())
        assertEquals(1, set.size)
        assertEquals(expectedOneLineCost, PruningActivityLabourCosting.totalCost(set)!!, eps)

        // ADD a second.
        set = applyDesiredState(twoLines(), set)
        assertEquals(2, set.size)
        assertEquals(expectedTwoLineHours, PruningActivityLabourCosting.totalHours(set)!!, eps)
        assertEquals(expectedTwoLineCost, PruningActivityLabourCosting.totalCost(set)!!, eps)

        // EDIT the first: the rate rises to $40 → 2 × 8 × 40 = $640, + $210 = $850.
        val edited = twoLines().toMutableList()
        edited[0] = edited[0].copy(hourlyRate = 40.0)
        set = applyDesiredState(edited, set)
        assertEquals(2, set.size)
        assertEquals(expectedTwoLineHours, PruningActivityLabourCosting.totalHours(set)!!, eps)
        assertEquals(850.0, PruningActivityLabourCosting.totalCost(set)!!, eps)

        // REMOVE the second: absent from the desired set means deleted.
        set = applyDesiredState(listOf(edited[0]), set)
        assertEquals(1, set.size)
        assertEquals(expectedOneLineHours, PruningActivityLabourCosting.totalHours(set)!!, eps)
        assertEquals(640.0, PruningActivityLabourCosting.totalCost(set)!!, eps)

        // REMOVE the last: an EMPTY set is a legitimate instruction, and the
        // totals become null — "not specified", never zero.
        set = applyDesiredState(emptyList(), set)
        assertTrue(set.isEmpty())
        assertNull(PruningActivityLabourCosting.totalHours(set))
        assertNull(PruningActivityLabourCosting.totalCost(set))
    }

    // ---- 4. UNRATED line — hours count, cost does not --------------------

    @Test
    fun `an unrated line counts in hours but is never costed as zero`() {
        val unrated = listOf(line(workerCount = 1, hoursPerWorker = 5.0, hourlyRate = null))
        // Hours are real work; the cost is genuinely unknown.
        assertEquals(5.0, PruningActivityLabourCosting.totalHours(unrated)!!, eps)
        assertNull(PruningActivityLabourCosting.totalCost(unrated))
        assertNull(PruningActivityLabourCosting.lineCost(unrated[0]))

        // Mixed: 2 × 9 h rated + 1 × 5 h unrated → 23 h, but only the rated
        // line contributes to the money.
        val mixed = listOf(
            line(workerCount = 2, hoursPerWorker = 9.0, hourlyRate = 30.0, lineIndex = 0),
            line(workerCount = 1, hoursPerWorker = 5.0, hourlyRate = null, lineIndex = 1),
        )
        assertEquals(23.0, PruningActivityLabourCosting.totalHours(mixed)!!, eps)
        assertEquals(540.0, PruningActivityLabourCosting.totalCost(mixed)!!, eps)

        // An activity whose lines are ALL unrated must not fall through to a
        // legacy rate: its own lines ARE the labour record.
        val resolved = PruningActivityLabourCosting.resolve(
            task = null,
            activityLines = unrated,
            taskLines = emptyList(),
            legacyHours = legacyHours,
            legacyRate = legacyRate,
        )
        assertEquals(PruningActivityLabourCosting.Source.PRUNING_LABOUR_LINES, resolved.source)
        assertEquals(5.0, resolved.hours!!, eps)
        assertNull(resolved.cost)
    }

    // ---- 5. LEGACY activity — never back-filled --------------------------

    @Test
    fun `a legacy activity with no lines still resolves to 240 dollars`() {
        val resolved = PruningActivityLabourCosting.resolve(
            task = null,
            activityLines = emptyList(),
            taskLines = emptyList(),
            legacyHours = legacyHours,
            legacyRate = legacyRate,
        )
        assertEquals(PruningActivityLabourCosting.Source.ACTIVITY_HOURS, resolved.source)
        assertTrue(resolved.isLegacy)
        assertEquals(0, resolved.lineCount)
        assertEquals(legacyHours, resolved.hours!!, eps)
        assertEquals(expectedLegacyCost, resolved.cost!!, eps)

        // Effective HOURS fall back to the same scalar.
        assertEquals(
            legacyHours,
            PruningActivityLabourCosting.effectiveHours(emptyList(), legacyHours)!!,
            eps,
        )
    }

    @Test
    fun `adding a line to a legacy activity takes over and is never summed`() {
        val resolved = PruningActivityLabourCosting.resolve(
            task = null,
            activityLines = oneLine(),
            taskLines = emptyList(),
            legacyHours = legacyHours,
            legacyRate = legacyRate,
        )
        assertEquals(PruningActivityLabourCosting.Source.PRUNING_LABOUR_LINES, resolved.source)
        // $480, NOT $480 + $240 = $720.
        assertEquals(expectedOneLineCost, resolved.cost!!, eps)
        assertEquals(expectedOneLineHours, resolved.hours!!, eps)
    }

    @Test
    fun `legacy conversion reproduces the original figure exactly and is opt in`() {
        val converted = PruningActivityLabourCosting.legacyConversionLine(
            lineId = "converted-1",
            activityId = activityId,
            vineyardId = vineyardId,
            workDate = "2026-08-03",
            workerOrCrew = "Dave + 2 casuals",
            legacyHours = legacyHours,
            legacyRate = legacyRate,
        )
        assertNotNull(converted)
        // The free-text crew becomes the worker TYPE — never split into a count.
        assertEquals("Dave + 2 casuals", converted!!.workerType)
        assertEquals(1, converted.workerCount)
        assertEquals(expectedLegacyCost, PruningActivityLabourCosting.lineCost(converted)!!, eps)
        assertEquals(
            legacyHours,
            PruningActivityLabourCosting.totalHours(listOf(converted))!!,
            eps,
        )

        // Nothing to convert when there are no recorded hours.
        assertNull(
            PruningActivityLabourCosting.legacyConversionLine(
                lineId = "converted-2",
                activityId = activityId,
                vineyardId = vineyardId,
                workDate = "2026-08-03",
                workerOrCrew = "Crew",
                legacyHours = null,
                legacyRate = null,
            ),
        )
    }

    // ---- 6. MULTI-BLOCK — labour counted ONCE ----------------------------

    @Test
    fun `a three block activity still reports 22 hours and 690 dollars`() {
        val draft = multiBlockDraft()
        assertEquals(3, draft.blockCount)

        val resolved = PruningActivityLabourCosting.resolve(
            task = null,
            activityLines = twoLines(),
            taskLines = emptyList(),
            legacyHours = null,
            legacyRate = null,
        )
        // The labour figure is a property of the ACTIVITY, so the block count
        // cannot enter the arithmetic: $690, never $2,070.
        assertEquals(expectedTwoLineCost, resolved.cost!!, eps)
        assertEquals(expectedTwoLineHours, resolved.hours!!, eps)
        assertTrue(resolved.cost != expectedTwoLineCost * 3)
    }

    // ---- 7. LINKED WORK TASK — read through, never a second copy ---------

    @Test
    fun `a linked hourly task reports the activity 480 dollars and never 960`() {
        val task = hourlyTask()
        val draft = multiBlockDraft(workTaskId = hourlyTaskId)

        // The task holds NO labour lines of its own, so it resolves through to
        // the pruning activity's rows (SQL 190 rung 3).
        val taskCost = PruningActivityLabourCosting.effectiveWorkTaskCost(
            task = task,
            taskLines = emptyList(),
            activities = listOf(draft),
            activityLines = oneLine(),
        )
        assertEquals(expectedOneLineCost, taskCost!!, eps)
        // The SAME rows, so the two modules cannot double-count.
        assertTrue(taskCost != expectedOneLineCost * 2)

        // The task's OWN lines outrank the read-through when it has them.
        val ownCost = PruningActivityLabourCosting.effectiveWorkTaskCost(
            task = task,
            taskLines = listOf(taskLine(1, 10.0, 25.0)),
            activities = listOf(draft),
            activityLines = oneLine(),
        )
        assertEquals(250.0, ownCost!!, eps)
    }

    @Test
    fun `an activity own lines outrank the linked task lines`() {
        val resolved = PruningActivityLabourCosting.resolve(
            task = hourlyTask(),
            activityLines = oneLine(),
            taskLines = listOf(taskLine(1, 10.0, 25.0)),
            legacyHours = null,
            legacyRate = null,
        )
        assertEquals(PruningActivityLabourCosting.Source.PRUNING_LABOUR_LINES, resolved.source)
        // $480, NOT $480 + $250 = $730.
        assertEquals(expectedOneLineCost, resolved.cost!!, eps)
    }

    @Test
    fun `with no lines of its own the activity falls back to the task lines`() {
        val resolved = PruningActivityLabourCosting.resolve(
            task = hourlyTask(),
            activityLines = emptyList(),
            taskLines = listOf(taskLine(2, 8.0, 30.0)),
            legacyHours = legacyHours,
            legacyRate = legacyRate,
        )
        assertEquals(PruningActivityLabourCosting.Source.WORK_TASK_LINES, resolved.source)
        assertEquals(expectedOneLineCost, resolved.cost!!, eps)
    }

    @Test
    fun `a linked piece rate task is 137 dollars 50 and never added to hourly lines`() {
        val resolved = PruningActivityLabourCosting.resolve(
            task = pieceRateTask(),
            // Hours recorded on a piece-rate job are operational history.
            activityLines = listOf(line(workerCount = 1, hoursPerWorker = 6.0, hourlyRate = null)),
            taskLines = emptyList(),
            legacyHours = null,
            legacyRate = null,
        )
        assertEquals(PruningActivityLabourCosting.Source.PIECE_RATE, resolved.source)
        assertEquals(expectedPieceCost, resolved.cost!!, eps)
        // 137.50, never 137.50 + 480 = 617.50.
        assertTrue(resolved.cost != expectedPieceCost + expectedOneLineCost)
        // Hours are still reported — they drive vines-per-hour, not the cost.
        assertEquals(6.0, resolved.hours!!, eps)
    }

    @Test
    fun `costing visibility hides money but never hours`() {
        val resolved = PruningActivityLabourCosting.resolve(
            task = null,
            activityLines = twoLines(),
            taskLines = emptyList(),
            legacyHours = null,
            legacyRate = null,
            includeCost = false,
        )
        assertNull(resolved.cost)
        assertEquals(expectedTwoLineHours, resolved.hours!!, eps)
    }

    // ---- 8. OFFLINE REPLAY — idempotent ----------------------------------

    @Test
    fun `replaying the same desired state payload three times changes nothing`() {
        var set = applyDesiredState(twoLines(), emptyList())
        repeat(3) { set = applyDesiredState(twoLines(), set) }
        // The client ids are the idempotency keys, so a replay upserts.
        assertEquals(2, set.size)
        assertEquals(expectedTwoLineHours, PruningActivityLabourCosting.totalHours(set)!!, eps)
        assertEquals(expectedTwoLineCost, PruningActivityLabourCosting.totalCost(set)!!, eps)
    }

    @Test
    fun `a re-sent removed line is restored and never duplicated`() {
        var set = applyDesiredState(twoLines(), emptyList())
        set = applyDesiredState(emptyList(), set)
        assertTrue(set.isEmpty())

        // Re-sending the SAME client id restores exactly one row.
        set = applyDesiredState(oneLine(), set)
        assertEquals(1, set.size)
        assertEquals(1, set.count { it.id == lineOneId })
        assertEquals(expectedOneLineCost, PruningActivityLabourCosting.totalCost(set)!!, eps)
    }

    // ---- 9. CROSS-VINEYARD / CROSS-ACTIVITY ISOLATION --------------------

    @Test
    fun `another activity labour never leaks into this activity totals`() {
        val foreign = line(
            id = "foreign-1",
            activity = otherActivityId,
            vineyard = otherVineyardId,
            workerCount = 5,
            hoursPerWorker = 10.0,
            hourlyRate = 99.0,
        )
        val mixed = twoLines() + foreign

        val scoped = PruningActivityLabourCosting.linesFor(mixed, activityId)
        assertEquals(2, scoped.size)
        assertEquals(expectedTwoLineHours, PruningActivityLabourCosting.totalHours(scoped)!!, eps)
        assertEquals(expectedTwoLineCost, PruningActivityLabourCosting.totalCost(scoped)!!, eps)

        // The other activity keeps its own figure: 5 × 10 × $99 = $4,950.
        val otherScoped = PruningActivityLabourCosting.linesFor(mixed, otherActivityId)
        assertEquals(4950.0, PruningActivityLabourCosting.totalCost(otherScoped)!!, eps)
    }

    @Test
    fun `a work task only reads through to the activities actually linked to it`() {
        val linked = multiBlockDraft(workTaskId = hourlyTaskId)
        val unlinked = PruningActivityDraft(
            id = otherActivityId,
            vineyardId = otherVineyardId,
            date = "2026-08-03",
        )
        val lines = oneLine() + line(
            id = "foreign-2",
            activity = otherActivityId,
            vineyard = otherVineyardId,
            workerCount = 5,
            hoursPerWorker = 10.0,
            hourlyRate = 99.0,
        )
        val cost = PruningActivityLabourCosting.pruningLineCostForWorkTask(
            workTaskId = hourlyTaskId,
            activities = listOf(linked, unlinked),
            activityLines = lines,
        )
        // Only the LINKED activity's $480 — the unlinked $4,950 is excluded.
        assertEquals(expectedOneLineCost, cost!!, eps)

        // A task nothing links to reads through to nothing at all.
        assertNull(
            PruningActivityLabourCosting.pruningLineCostForWorkTask(
                workTaskId = pieceTaskId,
                activities = listOf(linked, unlinked),
                activityLines = lines,
            ),
        )
    }

    @Test
    fun `a reversed activity labour is never read through to its work task`() {
        val reversed = multiBlockDraft(workTaskId = hourlyTaskId)
            .copy(reversedAtMs = System.currentTimeMillis())
        assertNull(
            PruningActivityLabourCosting.pruningLineCostForWorkTask(
                workTaskId = hourlyTaskId,
                activities = listOf(reversed),
                activityLines = oneLine(),
            ),
        )
    }
}
