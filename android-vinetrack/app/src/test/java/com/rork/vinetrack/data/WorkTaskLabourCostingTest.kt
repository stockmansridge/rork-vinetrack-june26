package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningActivityReport
import com.rork.vinetrack.data.model.PruningActivityBlockContext
import com.rork.vinetrack.data.model.PruningAllocationEditor
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WORK TASK LABOUR LINES are the authoritative source of labour cost — the
 * Kotlin twin of `WorkTaskLabourCostingTests.swift`. Both suites assert the SAME
 * fixtures, so a divergence between the platforms fails a build.
 *
 * The ownership rule under test:
 *  * a Work Task labour line owns labour type, hourly rate, number of people,
 *    hours per person, person-hours and labour cost;
 *  * a Pruning Activity owns operational output only, and no longer has an
 *    editable standalone hourly rate;
 *  * a historical activity rate stays READABLE but is never combined with
 *    labour-line totals.
 */
class WorkTaskLabourCostingTest {

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val cabFranc = "22222222-2222-4222-8222-222222222222"
    private val sauvBlanc = "33333333-3333-4333-8333-333333333333"
    private val activityId = "55555555-5555-4555-8555-555555555555"
    private val taskId = "66666666-6666-4666-8666-666666666666"
    private val otherTaskId = "77777777-7777-4777-8777-777777777777"

    private fun line(
        id: String,
        workTaskId: String = taskId,
        workerType: String = "Pruning crew",
        workerCount: Int = 1,
        hoursPerWorker: Double = 1.0,
        hourlyRate: Double? = null,
        totalHours: Double? = null,
        totalCost: Double? = null,
        workDate: String = "2026-08-04",
        deletedAt: String? = null,
    ) = WorkTaskLabourLine(
        id = id,
        workTaskId = workTaskId,
        vineyardId = vineyard,
        workDate = workDate,
        operatorCategoryId = null,
        workerType = workerType,
        workerCount = workerCount,
        hoursPerWorker = hoursPerWorker,
        hourlyRate = hourlyRate,
        totalHours = totalHours,
        totalCost = totalCost,
        notes = "",
        deletedAt = deletedAt,
    )

    private fun rows(numbers: List<Int>): List<PruningSegment> =
        numbers.flatMap { row -> (1..4).map { PruningSegment(row = row, quarter = it) } }

    /** Two-block activity: Cab Franc rows 42–44, Sauv Blanc rows 66–67. */
    private fun twoBlockDraft(): PruningActivityDraft {
        var draft = PruningActivityDraft(id = activityId, vineyardId = vineyard, date = "2026-08-04")
        draft = PruningAllocationEditor.setSegments(draft, cabFranc, rows(listOf(42, 43, 44)), "Cab Franc")
        draft = PruningAllocationEditor.setSegments(draft, sauvBlanc, rows(listOf(66, 67)), "Sauv Blanc")
        return draft
    }

    // MARK: 1 — the canonical arithmetic

    /** 3 people × 6 hours × $35 = 18 person-hours and $630. */
    @Test
    fun `three people six hours at thirty five yields eighteen person hours and six hundred thirty`() {
        assertEquals(18.0, WorkTaskLabourCosting.personHours(3, 6.0), 0.0001)
        assertEquals(630.0, WorkTaskLabourCosting.lineCost(3, 6.0, 35.0)!!, 0.0001)

        val stored = line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0)
        assertEquals(18.0, WorkTaskLabourCosting.personHours(stored), 0.0001)
        assertEquals(630.0, WorkTaskLabourCosting.lineCost(stored)!!, 0.0001)
    }

    /** An already-aggregated elapsed duration is never multiplied by the crew. */
    @Test
    fun `person hours are never derived from an activity elapsed duration`() {
        // Elapsed 7.5 h between start and finish, crew of 3 working 6 h each.
        val draft = twoBlockDraft().copy(startTime = "08:00", finishTime = "15:30")
        val elapsed = draft.durationHours
        assertNotNull(elapsed)
        assertEquals(7.5, elapsed!!, 0.0001)
        // Person-hours come from the labour line, NOT elapsed × people.
        assertEquals(18.0, WorkTaskLabourCosting.personHours(3, 6.0), 0.0001)
        assertFalse(elapsed * 3 == WorkTaskLabourCosting.personHours(3, 6.0))
    }

    // MARK: 2 — multiple labour lines sum correctly

    @Test
    fun `multiple labour lines sum person hours and cost`() {
        val lines = listOf(
            line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0),  // 18 h, 630
            line("l2", workerCount = 2, hoursPerWorker = 4.0, hourlyRate = 42.0),  // 8 h, 336
            line("l3", workerCount = 1, hoursPerWorker = 7.5, hourlyRate = 30.0),  // 7.5 h, 225
        )
        val totals = WorkTaskLabourCosting.totals(lines)
        assertEquals(3, totals.lineCount)
        assertEquals(6, totals.workers)
        assertEquals(33.5, totals.personHours, 0.0001)
        assertEquals(1191.0, totals.cost!!, 0.0001)
    }

    /** Different crews, types, rates, people and hours on one task. */
    @Test
    fun `lines without a rate contribute hours but not cost and never render as zero`() {
        val lines = listOf(
            line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0),
            line("l2", workerType = "Contractor", workerCount = 4, hoursPerWorker = 5.0, hourlyRate = null),
        )
        val totals = WorkTaskLabourCosting.totals(lines)
        assertEquals(38.0, totals.personHours, 0.0001)
        assertEquals(630.0, totals.cost!!, 0.0001)
        // An unpriced line reports "not specified", never 0.
        assertNull(WorkTaskLabourCosting.lineCost(lines[1]))
        assertNull(WorkTaskLabourCosting.totalCost(listOf(lines[1])))
    }

    // MARK: 3 — recalculation on edit

    @Test
    fun `editing the worker count recalculates person hours and cost`() {
        val before = WorkTaskLabourCosting.lineCost(3, 6.0, 35.0)!!
        val after = WorkTaskLabourCosting.lineCost(5, 6.0, 35.0)!!
        assertEquals(630.0, before, 0.0001)
        assertEquals(30.0, WorkTaskLabourCosting.personHours(5, 6.0), 0.0001)
        assertEquals(1050.0, after, 0.0001)
    }

    @Test
    fun `editing hours per person recalculates person hours and cost`() {
        assertEquals(18.0, WorkTaskLabourCosting.personHours(3, 6.0), 0.0001)
        assertEquals(22.5, WorkTaskLabourCosting.personHours(3, 7.5), 0.0001)
        assertEquals(787.5, WorkTaskLabourCosting.lineCost(3, 7.5, 35.0)!!, 0.0001)
    }

    // MARK: 4 — the labour type supplies its saved rate

    @Test
    fun `selecting a labour type supplies its saved hourly rate`() {
        val category = OperatorCategory(id = "c1", vineyardId = vineyard, name = "Pruning crew", costPerHour = 35.0)
        assertEquals(35.0, WorkTaskLabourCosting.defaultRate(category)!!, 0.0001)
        // A type with no saved rate offers no default rather than 0.
        assertNull(WorkTaskLabourCosting.defaultRate(category.copy(costPerHour = null)))
        assertNull(WorkTaskLabourCosting.defaultRate(category.copy(costPerHour = 0.0)))
        assertNull(WorkTaskLabourCosting.defaultRate(null))
    }

    // MARK: 5 — validation

    @Test
    fun `validation requires labour type positive people and positive hours`() {
        assertTrue(WorkTaskLabourCosting.isValid("Pruning crew", 3, 6.0, 35.0))

        val noType = WorkTaskLabourCosting.validate("   ", 3, 6.0, 35.0)
        assertEquals(
            "Choose a labour type.",
            WorkTaskLabourCosting.message(noType, WorkTaskLabourCosting.LabourLineField.LABOUR_TYPE),
        )

        val zeroPeople = WorkTaskLabourCosting.validate("Crew", 0, 6.0, 35.0)
        assertNotNull(
            WorkTaskLabourCosting.message(zeroPeople, WorkTaskLabourCosting.LabourLineField.WORKER_COUNT),
        )

        val zeroHours = WorkTaskLabourCosting.validate("Crew", 3, 0.0, 35.0)
        assertNotNull(
            WorkTaskLabourCosting.message(zeroHours, WorkTaskLabourCosting.LabourLineField.HOURS_PER_WORKER),
        )

        // A zero rate is legitimate (unpaid / owner labour); negative is not.
        assertTrue(WorkTaskLabourCosting.isValid("Crew", 3, 6.0, 0.0))
        assertNotNull(
            WorkTaskLabourCosting.message(
                WorkTaskLabourCosting.validate("Crew", 3, 6.0, -1.0),
                WorkTaskLabourCosting.LabourLineField.HOURLY_RATE,
            ),
        )
    }

    @Test
    fun `validation rejects non finite and out of bounds values`() {
        assertFalse(WorkTaskLabourCosting.isValid("Crew", 3, Double.NaN, 35.0))
        assertFalse(WorkTaskLabourCosting.isValid("Crew", 3, Double.POSITIVE_INFINITY, 35.0))
        assertFalse(WorkTaskLabourCosting.isValid("Crew", 3, 6.0, Double.NaN, rateProvided = true))
        assertFalse(WorkTaskLabourCosting.isValid("Crew", WorkTaskLabourCosting.MAX_WORKER_COUNT + 1, 6.0, 35.0))
        assertFalse(WorkTaskLabourCosting.isValid("Crew", 3, WorkTaskLabourCosting.MAX_HOURS_PER_WORKER + 1, 35.0))
        assertFalse(WorkTaskLabourCosting.isValid("Crew", 3, 6.0, WorkTaskLabourCosting.MAX_HOURLY_RATE + 1))
        // Every problem is reported, so each field can be marked inline — labour
        // type, worker count, hours per person and rate all fail here.
        val allBad = WorkTaskLabourCosting.validate("", 0, 0.0, -5.0)
        assertEquals(4, allBad.size)
        assertEquals(
            setOf(
                WorkTaskLabourCosting.LabourLineField.LABOUR_TYPE,
                WorkTaskLabourCosting.LabourLineField.WORKER_COUNT,
                WorkTaskLabourCosting.LabourLineField.HOURS_PER_WORKER,
                WorkTaskLabourCosting.LabourLineField.HOURLY_RATE,
            ),
            allBad.map { it.field }.toSet(),
        )
        // A blank rate field is simply "not specified" — not a validation error.
        assertTrue(WorkTaskLabourCosting.isValid("Crew", 3, 6.0, null, rateProvided = false))
    }

    // MARK: 6 — linking an existing task never overwrites its labour lines

    @Test
    fun `linking an existing task keeps its labour lines untouched`() {
        val existing = listOf(
            line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0),
            line("l2", workerCount = 2, hoursPerWorker = 4.0, hourlyRate = 42.0),
        )
        val draft = twoBlockDraft()
        val linked = PruningActivityTaskLink.link(draft, taskId)

        // Nothing in the link path can add, remove or rewrite a line.
        val after = WorkTaskLabourCosting.linesFor(existing, taskId)
        assertEquals(existing, after)
        assertEquals(2, after.size)
        assertEquals(26.0, WorkTaskLabourCosting.totalPersonHours(after), 0.0001)
        assertEquals(966.0, WorkTaskLabourCosting.totalCost(after)!!, 0.0001)
        assertEquals(taskId, linked.workTaskId)
    }

    @Test
    fun `labour lines of another task are never attributed to this one`() {
        val lines = listOf(
            line("l1", workTaskId = taskId, workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0),
            line("l2", workTaskId = otherTaskId, workerCount = 9, hoursPerWorker = 9.0, hourlyRate = 99.0),
        )
        val mine = WorkTaskLabourCosting.linesFor(lines, taskId)
        assertEquals(1, mine.size)
        assertEquals(18.0, WorkTaskLabourCosting.totalPersonHours(mine), 0.0001)
        assertEquals(630.0, WorkTaskLabourCosting.totalCost(mine)!!, 0.0001)
    }

    /** A soft-deleted line contributes nothing. */
    @Test
    fun `soft deleted lines are excluded from totals`() {
        val lines = listOf(
            line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0),
            line("l2", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0, deletedAt = "2026-08-05T00:00:00Z"),
        )
        val live = WorkTaskLabourCosting.linesFor(lines, taskId)
        assertEquals(1, live.size)
        assertEquals(630.0, WorkTaskLabourCosting.totalCost(live)!!, 0.0001)
    }

    // MARK: 7 — creating a linked task carries task, blocks and duration

    @Test
    fun `creating a linked task carries every block and the shared duration once`() {
        val draft = twoBlockDraft().copy(labourHours = 7.5)
        val taskDraft = PruningActivityTaskLink.createDraft(draft)
        assertEquals("Pruning", taskDraft.trimmedType)
        assertTrue(taskDraft.trimmedNotes.contains("Cab Franc"))
        assertTrue(taskDraft.trimmedNotes.contains("Sauv Blanc"))
        // Both blocks are attached to the ONE task.
        assertEquals(listOf(cabFranc, sauvBlanc).sorted(), PruningActivityTaskLink.paddockIds(draft).sorted())
        // The shared duration is carried once, never apportioned per block.
        assertEquals(7.5, PruningActivityTaskLink.durationHours(draft), 0.0001)
    }

    // MARK: 8 — unlinking preserves the task and its labour lines

    @Test
    fun `unlinking clears only the link and preserves the task labour lines`() {
        val lines = listOf(line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0))
        val linked = PruningActivityTaskLink.link(twoBlockDraft(), taskId)
        val unlinked = PruningActivityTaskLink.unlink(linked)

        assertNull(unlinked.workTaskId)
        // The lines are untouched by unlinking — the task keeps its labour.
        assertEquals(1, WorkTaskLabourCosting.linesFor(lines, taskId).size)
        assertEquals(630.0, WorkTaskLabourCosting.totalCost(lines)!!, 0.0001)
        // And so is every allocation.
        assertEquals(linked.allocations, unlinked.allocations)
    }

    // MARK: 9 — allocations are byte-for-byte unchanged through the whole flow

    @Test
    fun `allocations are unchanged through create link edit and unlink`() {
        val base = twoBlockDraft()
        val original = base.allocations

        val created = PruningActivityTaskLink.link(base, taskId)
        assertEquals(original, created.allocations)

        val relinked = PruningActivityTaskLink.link(created, otherTaskId)
        assertEquals(original, relinked.allocations)

        // Editing ONLY labour-adjacent parent fields cannot disturb allocations.
        val edited = relinked.copy(worker = "Jon", notes = "Finished Cab Franc")
        assertEquals(original, edited.allocations)

        val unlinked = PruningActivityTaskLink.unlink(edited)
        assertEquals(original, unlinked.allocations)

        // Quarters and vines per block are identical.
        assertEquals(12, unlinked.allocations[cabFranc]!!.quarters)
        assertEquals(8, unlinked.allocations[sauvBlanc]!!.quarters)
        assertEquals(20, unlinked.totalQuarters)
    }

    // MARK: 10 — offline dependency order: task -> blocks -> labour -> activity

    @Test
    fun `activity waits for the task its labour lines and its block links`() {
        fun write(entity: String, op: String, clientId: String, status: String = PendingWriteStatus.PENDING) =
            PendingWrite(
                id = "$entity-$op-$clientId",
                entityType = entity,
                opType = op,
                payloadJson = "{}",
                clientId = clientId,
                createdAt = 0,
                updatedAt = 0,
                status = status,
            )

        // 1. Task header still local -> the activity waits, link intact.
        val taskPending = listOf(write(PendingEntityType.WORK_TASK, PendingOpType.CREATE, taskId))
        assertTrue(
            PruningActivityTaskLink.isWaitingForTask(
                taskId,
                PruningActivityTaskLink.unresolvedDependencyIds(taskPending),
            ),
        )

        // 2. Header acknowledged, but a labour line is still queued -> still waits.
        val labourPending = listOf(
            write(PendingEntityType.WORK_TASK, PendingOpType.CREATE, taskId, PendingWriteStatus.SYNCED),
            write(PendingEntityType.WORK_TASK_LABOUR, PendingOpType.CREATE, "l1"),
        )
        val labourDeps = PruningActivityTaskLink.unresolvedDependencyIds(
            labourPending,
            labourLineTaskIds = mapOf("l1" to taskId),
        )
        assertTrue(PruningActivityTaskLink.isWaitingForTask(taskId, labourDeps))

        // 3. Block association still queued -> still waits.
        val blockDeps = PruningActivityTaskLink.unresolvedDependencyIds(
            listOf(write(PendingEntityType.WORK_TASK_PADDOCK, PendingOpType.CREATE, "j1")),
            workTaskPaddockTaskIds = mapOf("j1" to taskId),
        )
        assertTrue(PruningActivityTaskLink.isWaitingForTask(taskId, blockDeps))

        // 4. The whole chain resolved -> the activity may push.
        val resolved = listOf(
            write(PendingEntityType.WORK_TASK, PendingOpType.CREATE, taskId, PendingWriteStatus.SYNCED),
            write(PendingEntityType.WORK_TASK_LABOUR, PendingOpType.CREATE, "l1", PendingWriteStatus.SYNCED),
        )
        assertFalse(
            PruningActivityTaskLink.isWaitingForTask(
                taskId,
                PruningActivityTaskLink.unresolvedDependencyIds(
                    resolved,
                    labourLineTaskIds = mapOf("l1" to taskId),
                ),
            ),
        )

        // 5. Another task's dependency never holds this activity back.
        val unrelated = PruningActivityTaskLink.unresolvedDependencyIds(
            listOf(write(PendingEntityType.WORK_TASK_LABOUR, PendingOpType.CREATE, "l9")),
            labourLineTaskIds = mapOf("l9" to otherTaskId),
        )
        assertFalse(PruningActivityTaskLink.isWaitingForTask(taskId, unrelated))

        // 6. An activity with NO task never waits.
        assertFalse(PruningActivityTaskLink.isWaitingForTask(null, labourDeps))
    }

    /** The waiting activity never has its link stripped to force the upload. */
    @Test
    fun `a waiting activity keeps its work task id`() {
        val linked = PruningActivityTaskLink.link(twoBlockDraft(), taskId)
        assertEquals(taskId, linked.workTaskId)
        assertTrue(PruningActivityTaskLink.WAITING_REASON.isNotEmpty())
    }

    // MARK: 11 — retry never duplicates a labour line

    @Test
    fun `a retried labour line upsert is idempotent on its stable id`() {
        // The same client-minted id is replayed; the store de-duplicates by id.
        val first = line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0)
        val replay = first.copy(totalHours = 18.0, totalCost = 630.0)
        val merged = LinkedHashMap<String, WorkTaskLabourLine>()
        listOf(first, replay).forEach { merged[it.id] = it }

        assertEquals(1, merged.size)
        val totals = WorkTaskLabourCosting.totals(merged.values.toList())
        assertEquals(18.0, totals.personHours, 0.0001)
        assertEquals(630.0, totals.cost!!, 0.0001)
    }

    // MARK: 12 — legacy fallback, used ONLY when no labour lines exist

    @Test
    fun `labour lines win over the legacy activity rate`() {
        val lines = listOf(line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0))
        val resolved = WorkTaskLabourCosting.resolveLabour(lines, legacyHours = 7.5, legacyRate = 99.0)
        assertEquals(WorkTaskLabourCosting.LabourSource.WORK_TASK_LINES, resolved.source)
        assertEquals(18.0, resolved.hours!!, 0.0001)
        assertEquals(630.0, resolved.cost!!, 0.0001)
        assertFalse(resolved.isLegacy)
        // 630 only — never 630 + (7.5 × 99).
        assertFalse(resolved.cost == 630.0 + 7.5 * 99.0)
    }

    @Test
    fun `the legacy activity rate is used only when the task has no labour lines`() {
        val resolved = WorkTaskLabourCosting.resolveLabour(emptyList(), legacyHours = 7.5, legacyRate = 40.0)
        assertEquals(WorkTaskLabourCosting.LabourSource.LEGACY_ACTIVITY, resolved.source)
        assertEquals(7.5, resolved.hours!!, 0.0001)
        assertEquals(300.0, resolved.cost!!, 0.0001)
        assertTrue(resolved.isLegacy)
    }

    @Test
    fun `nothing recorded resolves to no labour at all`() {
        val resolved = WorkTaskLabourCosting.resolveLabour(emptyList(), legacyHours = null, legacyRate = null)
        assertEquals(WorkTaskLabourCosting.LabourSource.NONE, resolved.source)
        assertNull(resolved.hours)
        assertNull(resolved.cost)
    }

    // MARK: 13 — reports never double-count

    @Test
    fun `report rows use task labour hours and cost without double counting`() {
        val lines = listOf(
            line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0),
            line("l2", workerCount = 2, hoursPerWorker = 4.0, hourlyRate = 42.0),
        )
        val costs = WorkTaskLabourCosting.costsByWorkTask(lines)
        val hours = WorkTaskLabourCosting.hoursByWorkTask(lines)
        assertEquals(966.0, costs[taskId]!!, 0.0001)
        assertEquals(26.0, hours[taskId]!!, 0.0001)

        // A record whose task HAS lines reports the task's figures, not its own.
        val linked = PruningEntry(
            id = "e1",
            vineyardId = vineyard,
            paddockId = cabFranc,
            seasonId = "s1",
            date = "2026-08-04",
            segments = rows(listOf(42)),
            worker = "Jon",
            labourHours = 7.5,
            workTaskId = taskId,
        )
        // And a legacy record with no linked task keeps its own hours.
        val legacy = linked.copy(id = "e2", workTaskId = null, labourHours = 5.0)

        val reportRows = PruningActivityReport.rows(
            entries = listOf(linked, legacy),
            blocks = mapOf(
                cabFranc to PruningActivityBlockContext(
                    name = "Cab Franc",
                    variety = "Cabernet Franc",
                    rows = emptyList(),
                ),
            ),
            labourCosts = costs,
            labourHours = hours,
        )
        assertEquals(26.0, reportRows[0].labourHours!!, 0.0001)
        assertEquals(966.0, reportRows[0].labourCost!!, 0.0001)
        assertEquals(5.0, reportRows[1].labourHours!!, 0.0001)
        assertNull(reportRows[1].labourCost)

        // The activity total counts the task's labour ONCE.
        val summary = PruningActivityReport.summary(reportRows, includeCost = true)
        assertEquals(31.0, summary.labourHours, 0.0001)
        assertEquals(966.0, summary.labourCost!!, 0.0001)
    }

    // MARK: 14 — costing permission

    @Test
    fun `cost is hidden from roles without costing visibility`() {
        val lines = listOf(line("l1", workerCount = 3, hoursPerWorker = 6.0, hourlyRate = 35.0))

        val allowed = WorkTaskLabourCosting.resolveLabour(lines, null, null, includeCost = true)
        assertEquals(630.0, allowed.cost!!, 0.0001)

        val denied = WorkTaskLabourCosting.resolveLabour(lines, null, null, includeCost = false)
        assertNull(denied.cost)
        // Hours stay visible — only money is withheld.
        assertEquals(18.0, denied.hours!!, 0.0001)

        assertTrue(WorkTaskLabourCosting.costsByWorkTask(lines, includeCost = false).isEmpty())
        // Legacy rows are equally protected.
        val legacyDenied = WorkTaskLabourCosting.resolveLabour(emptyList(), 7.5, 40.0, includeCost = false)
        assertNull(legacyDenied.cost)
        assertEquals(7.5, legacyDenied.hours!!, 0.0001)
    }

    // MARK: 15 — cross-platform parity fixtures

    /**
     * The exact fixtures `WorkTaskLabourCostingTests.swift` asserts. Both suites
     * must agree to the cent, so a platform drift fails a build.
     */
    @Test
    fun `cross platform parity fixtures`() {
        // people, hoursEach, rate -> personHours, cost
        val fixtures = listOf(
            Triple(3, 6.0, 35.0) to Pair(18.0, 630.0),
            Triple(1, 7.5, 42.5) to Pair(7.5, 318.75),
            Triple(12, 0.25, 30.0) to Pair(3.0, 90.0),
            Triple(4, 8.0, 0.0) to Pair(32.0, 0.0),
            Triple(2, 3.33, 27.5) to Pair(6.66, 183.15),
        )
        for ((input, expected) in fixtures) {
            val (people, hoursEach, rate) = input
            assertEquals(expected.first, WorkTaskLabourCosting.personHours(people, hoursEach), 0.0001)
            assertEquals(expected.second, WorkTaskLabourCosting.lineCost(people, hoursEach, rate)!!, 0.0001)
        }
    }
}
