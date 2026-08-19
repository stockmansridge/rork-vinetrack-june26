package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRUNING COST MODEL REPAIR (sql/200) — the Kotlin twin of
 * `PruningWorkTaskRepairTests.swift`. Both suites assert the SAME fixtures.
 *
 * Canonical model under test:
 *  * a Pruning Activity is OPERATIONAL only and links 0..N Work Tasks;
 *  * Work Tasks own labour cost (labour lines, piece rate);
 *  * activity labour hours / total cost are DERIVED — the SUM of the linked
 *    tasks' canonical totals — never a second stored dataset.
 */
class PruningWorkTaskRepairTest {

    private val eps = 0.0001
    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val activityId = "33333333-3333-4333-8333-333333333333"
    private val taskA = "44444444-4444-4444-8444-444444444444"
    private val taskB = "55555555-5555-4555-8555-555555555555"
    private val taskC = "66666666-6666-4666-8666-666666666666"

    private fun draft(mirror: String? = null): PruningActivityDraft =
        PruningActivityDraft(
            id = activityId,
            vineyardId = vineyard,
            date = "2026-08-04",
            workTaskId = mirror,
        )

    private fun task(
        id: String,
        pruningActivityId: String? = null,
        pieceRate: Boolean = false,
        day: Int = 4,
    ): WorkTask = WorkTask(
        id = id,
        vineyardId = vineyard,
        date = "2026-08-0${day}T09:00:00Z",
        taskType = "Pruning",
        costingMethod = if (pieceRate) "piece_rate" else "hourly",
        pieceRatePerVine = if (pieceRate) 0.5 else null,
        pieceVineCount = if (pieceRate) 200 else null,
        pruningActivityId = pruningActivityId,
    )

    private fun line(taskId: String, workers: Int, hours: Double, rate: Double?): WorkTaskLabourLine =
        WorkTaskLabourLine(
            id = "$taskId-line-$workers-$hours",
            workTaskId = taskId,
            vineyardId = vineyard,
            workDate = "2026-08-04",
            workerType = "Crew",
            workerCount = workers,
            hoursPerWorker = hours,
            hourlyRate = rate,
        )

    // §22 No cost -----------------------------------------------------------

    @Test
    fun `an activity with zero work tasks is valid and records no cost`() {
        val linked = PruningActivityTaskLink.linkedTasks(draft(), emptyList())
        assertTrue(linked.isEmpty())

        val resolved = PruningActivityLabourCosting.resolve(
            task = null, activityLines = emptyList(), taskLines = emptyList(),
            legacyHours = null, legacyRate = null,
        )
        assertEquals(PruningActivityLabourCosting.Source.NONE, resolved.source)
        assertNull(resolved.cost)
        assertNull(resolved.hours)
    }

    // §22 One / Two Work Tasks ----------------------------------------------

    @Test
    fun `one task 2x7x35 derives 14h and 490`() {
        val t = task(taskA, pruningActivityId = activityId)
        val lines = mapOf(taskA to listOf(line(taskA, 2, 7.0, 35.0)))
        val linked = PruningActivityTaskLink.linkedTasks(draft(mirror = taskA), listOf(t))
        assertEquals(1, linked.size)

        val aggregate = PruningActivityTaskLink.aggregate(linked, lines)
        assertEquals(14.0, aggregate.hours!!, eps)
        assertEquals(490.0, aggregate.cost!!, eps)
    }

    @Test
    fun `two tasks sum to 2 work tasks 22h and 810`() {
        val a = task(taskA, pruningActivityId = activityId)
        val b = task(taskB, pruningActivityId = activityId, day = 5)
        val lines = mapOf(
            taskA to listOf(line(taskA, 2, 7.0, 35.0)),
            taskB to listOf(line(taskB, 1, 8.0, 40.0)),
        )
        val linked = PruningActivityTaskLink.linkedTasks(draft(mirror = taskA), listOf(a, b))
        assertEquals(2, linked.size)

        val aggregate = PruningActivityTaskLink.aggregate(linked, lines)
        assertEquals(2, aggregate.taskCount)
        assertEquals(22.0, aggregate.hours!!, eps)
        assertEquals(810.0, aggregate.cost!!, eps)

        val resolved = PruningActivityLabourCosting.resolve(
            task = a, activityLines = emptyList(), taskLines = lines.getValue(taskA),
            legacyHours = null, legacyRate = null,
            linkedTasks = linked, linesByTask = lines,
        )
        assertEquals(PruningActivityLabourCosting.Source.WORK_TASKS, resolved.source)
        assertEquals(2, resolved.taskCount)
        assertEquals(22.0, resolved.hours!!, eps)
        assertEquals(810.0, resolved.cost!!, eps)
    }

    // §22 Multiple labour lines stay inside the task -------------------------

    @Test
    fun `a task with two lines is consumed canonically as 21h and 805`() {
        val t = task(taskA, pruningActivityId = activityId)
        val lines = listOf(line(taskA, 2, 7.0, 35.0), line(taskA, 1, 7.0, 45.0))
        assertEquals(805.0, WorkTaskLabourCosting.totalCost(lines)!!, eps)
        assertEquals(21.0, WorkTaskLabourCosting.totalPersonHours(lines), eps)

        val aggregate = PruningActivityTaskLink.aggregate(listOf(t), mapOf(taskA to lines))
        assertEquals(21.0, aggregate.hours!!, eps)
        assertEquals(805.0, aggregate.cost!!, eps)
    }

    // §22 Piece-rate + hourly mix --------------------------------------------

    @Test
    fun `hourly 490 plus piece rate 100 totals 590 never blended`() {
        val hourly = task(taskA, pruningActivityId = activityId)
        val piece = task(taskC, pruningActivityId = activityId, pieceRate = true, day = 6)
        val lines = mapOf(taskA to listOf(line(taskA, 2, 7.0, 35.0)))
        val aggregate = PruningActivityTaskLink.aggregate(listOf(hourly, piece), lines)
        assertEquals(590.0, aggregate.cost!!, eps)
        assertEquals(14.0, aggregate.hours!!, eps)
    }

    // §22 Unlink --------------------------------------------------------------

    @Test
    fun `unlinking one task decreases the aggregate and keeps the task standalone`() {
        val a = task(taskA, pruningActivityId = activityId)
        val b = task(taskB, pruningActivityId = null, day = 5) // unlinked
        val lines = mapOf(
            taskA to listOf(line(taskA, 2, 7.0, 35.0)),
            taskB to listOf(line(taskB, 1, 8.0, 40.0)),
        )
        val linked = PruningActivityTaskLink.linkedTasks(draft(mirror = taskA), listOf(a, b))
        assertEquals(listOf(taskA), linked.map { it.id })

        val aggregate = PruningActivityTaskLink.aggregate(linked, lines)
        assertEquals(490.0, aggregate.cost!!, eps)
        assertEquals(14.0, aggregate.hours!!, eps)

        // The unlinked task remains a valid standalone completed-work record.
        assertEquals(320.0, PruningActivityTaskLink.canonicalCost(b, lines.getValue(taskB))!!, eps)
    }

    // §22 Cross-platform round trip -------------------------------------------

    @Test
    fun `pruning activity id survives serialization and mirror plus origin dedupe`() {
        val json = Json { ignoreUnknownKeys = true }
        val t = task(taskA, pruningActivityId = activityId)
        val decoded = json.decodeFromString<WorkTask>(json.encodeToString(WorkTask.serializer(), t))
        assertEquals(activityId, decoded.pruningActivityId)

        // A task linked BOTH ways (origin + legacy mirror) appears once.
        val linked = PruningActivityTaskLink.linkedTasks(
            draft(mirror = taskA),
            listOf(t, task(taskB)),
        )
        assertEquals(listOf(taskA), linked.map { it.id })

        // A pre-repair payload without the field decodes as unlinked.
        val legacy = json.decodeFromString<WorkTask>(
            """{"id":"$taskB","vineyard_id":"$vineyard"}""",
        )
        assertNull(legacy.pruningActivityId)
    }
}
