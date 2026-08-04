package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningActivityCanonical
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningAllocationEditor
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.WorkTask
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ACTIVITY-LEVEL Work Task linkage for the multi-block pruning editor.
 *
 * The regression these tests lock down: the multi-block rebuild kept
 * `workTaskId` in the draft model but dropped the visible create / link / open /
 * unlink workflow, and the offline push had no ordering guarantee between a
 * locally-created task and the activity that references it.
 *
 * Covered here:
 *  * create a pruning activity and create its linked task,
 *  * link an existing task,
 *  * multi-block selections survive task creation, linking and unlinking,
 *  * edit and unlink,
 *  * the offline task -> activity dependency,
 *  * the canonical response restores `work_task_id`,
 *  * a server task conflict / unresolvable link is surfaced, never cleared,
 *  * the Activity Report can resolve the exact linked task.
 */
class PruningActivityWorkTaskLinkTest {

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val cabFranc = "22222222-2222-4222-8222-222222222222"
    private val sauvBlanc = "33333333-3333-4333-8333-333333333333"
    private val activityId = "55555555-5555-4555-8555-555555555555"
    private val taskId = "66666666-6666-4666-8666-666666666666"
    private val otherTaskId = "77777777-7777-4777-8777-777777777777"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun rows(vararg numbers: Int): List<PruningSegment> =
        numbers.flatMap { row -> (1..4).map { PruningSegment(row = row, quarter = it) } }

    /** A two-block activity: Cab Franc rows 42–44, Sauv Blanc rows 66–67. */
    private fun twoBlockDraft(): PruningActivityDraft {
        var draft = PruningActivityDraft(
            id = activityId,
            vineyardId = vineyard,
            date = "2026-08-04",
            worker = "Jon",
            method = "spur",
            labourHours = 7.5,
            hourlyRate = 35.0,
            notes = "Finished Cab Franc and moved into Sauv Blanc",
        )
        draft = PruningAllocationEditor.setSegments(draft, cabFranc, rows(42, 43, 44), "Cab Franc")
        draft = PruningAllocationEditor.setSegments(draft, sauvBlanc, rows(66, 67), "Sauv Blanc")
        return draft
    }

    private fun task(
        id: String = taskId,
        type: String = "Pruning",
        date: String = "2026-08-04",
    ): WorkTask = WorkTask(
        id = id,
        vineyardId = vineyard,
        paddockId = cabFranc,
        paddockName = "Cab Franc",
        date = date,
        taskType = type,
        durationHours = 7.5,
        isFinalized = true,
    )

    private fun write(
        entityType: String,
        opType: String,
        clientId: String,
        status: String = PendingWriteStatus.PENDING,
    ): PendingWrite = PendingWrite(
        id = "write-$clientId-$opType",
        entityType = entityType,
        opType = opType,
        payloadJson = "{}",
        clientId = clientId,
        createdAt = 1_000L,
        updatedAt = 1_000L,
        status = status,
    )

    // ---- create + link -----------------------------------------------------

    @Test
    fun `creating a task for the activity seeds date hours and every block`() {
        val draft = twoBlockDraft()
        val create = PruningActivityTaskLink.createDraft(draft)

        assertEquals("Pruning", create.trimmedType)
        assertTrue(create.isValid)
        assertTrue(create.markCompleted)
        // Shared labour, counted ONCE for the whole job — never per block.
        assertEquals(7.5, PruningActivityTaskLink.durationHours(draft), 0.0001)
        assertEquals(listOf(cabFranc, sauvBlanc).sorted(), PruningActivityTaskLink.paddockIds(draft).sorted())
        // The notes record WHICH blocks the shared labour covered.
        assertTrue(create.notes.contains("Cab Franc"))
        assertTrue(create.notes.contains("Sauv Blanc"))
        assertTrue(create.notes.contains("20 quarters"))
    }

    @Test
    fun `a blank work type cannot create a task`() {
        assertFalse(PruningWorkTaskLinkDraft(taskType = "   ").isValid)
        assertTrue(PruningWorkTaskLinkDraft(taskType = " Winter pruning ").isValid)
        assertEquals("Winter pruning", PruningWorkTaskLinkDraft(taskType = " Winter pruning ").trimmedType)
    }

    @Test
    fun `linking stores the task on the PARENT activity only`() {
        val linked = PruningActivityTaskLink.link(twoBlockDraft(), taskId)

        assertEquals(taskId, linked.workTaskId)
        // Not one copy per allocation — the allocation model has no such field,
        // and the payload sends the link exactly once.
        val payload = PruningSyncRepository.activityPayload(linked)
        assertEquals(taskId, payload.workTaskId)
        assertFalse(payload.clearWorkTask)
        val allocations = PruningSyncRepository.allocationPayloads(linked)
        assertEquals(2, allocations.size)
        assertFalse(json.encodeToString(PruningActivityDraft.serializer(), linked).contains("\"work_task_id\":null"))
    }

    @Test
    fun `multi-block selections survive task creation linking and change`() {
        val before = twoBlockDraft()
        var after = PruningActivityTaskLink.link(before, taskId)
        after = PruningActivityTaskLink.link(after, otherTaskId)

        assertEquals(otherTaskId, after.workTaskId)
        assertEquals(before.allocations, after.allocations)
        assertEquals(before.totalQuarters, after.totalQuarters)
        assertEquals(before.labourHours, after.labourHours)
        assertEquals(before.focusedPaddockId, after.focusedPaddockId)
        assertEquals(12, after.allocations.getValue(cabFranc).quarters)
        assertEquals(8, after.allocations.getValue(sauvBlanc).quarters)
    }

    // ---- edit + unlink -----------------------------------------------------

    @Test
    fun `unlinking clears only the parent link and asks the server to clear it`() {
        val linked = PruningActivityTaskLink.link(twoBlockDraft(), taskId)
        val unlinked = PruningActivityTaskLink.unlink(linked)

        assertNull(unlinked.workTaskId)
        assertEquals(linked.allocations, unlinked.allocations)
        assertEquals(7.5, unlinked.labourHours!!, 0.0001)
        val payload = PruningSyncRepository.activityPayload(unlinked)
        assertNull(payload.workTaskId)
        assertTrue(payload.clearWorkTask)
    }

    @Test
    fun `editing labour or blocks never disturbs the task link`() {
        var draft = PruningActivityTaskLink.link(twoBlockDraft(), taskId)
        draft = draft.copy(labourHours = 9.25)
        draft = PruningAllocationEditor.removeBlock(draft, cabFranc)
        draft = PruningAllocationEditor.setSegments(draft, sauvBlanc, rows(66, 67, 68), "Sauv Blanc")

        assertEquals(taskId, draft.workTaskId)
        assertEquals(9.25, draft.labourHours!!, 0.0001)
        assertEquals(setOf(sauvBlanc), draft.allocations.keys)
    }

    // ---- offline dependency ------------------------------------------------

    @Test
    fun `an activity waits for a Work Task created offline`() {
        val queue = listOf(
            write(PendingEntityType.WORK_TASK, PendingOpType.CREATE, taskId),
            write(PendingEntityType.PRUNING_ACTIVITY, PendingOpType.CREATE, activityId),
        )
        val unresolved = PruningActivityTaskLink.unresolvedTaskCreateIds(queue)

        assertEquals(setOf(taskId), unresolved)
        assertTrue(PruningActivityTaskLink.isWaitingForTask(taskId, unresolved))
        // An activity with no link, or one linked to an already-synced task,
        // never waits.
        assertFalse(PruningActivityTaskLink.isWaitingForTask(null, unresolved))
        assertFalse(PruningActivityTaskLink.isWaitingForTask(otherTaskId, unresolved))
    }

    @Test
    fun `once the task create is acknowledged the activity is free to push`() {
        val queue = listOf(
            write(PendingEntityType.WORK_TASK, PendingOpType.CREATE, taskId, PendingWriteStatus.SYNCED),
        )
        val unresolved = PruningActivityTaskLink.unresolvedTaskCreateIds(queue)

        assertTrue(unresolved.isEmpty())
        assertFalse(PruningActivityTaskLink.isWaitingForTask(taskId, unresolved))
    }

    @Test
    fun `a blocked or failed task create still holds the activity back`() {
        listOf(PendingWriteStatus.FAILED, PendingWriteStatus.BLOCKED, PendingWriteStatus.IN_PROGRESS)
            .forEach { status ->
                val unresolved = PruningActivityTaskLink.unresolvedTaskCreateIds(
                    listOf(write(PendingEntityType.WORK_TASK, PendingOpType.CREATE, taskId, status)),
                )
                assertTrue(
                    "status $status must hold the activity",
                    PruningActivityTaskLink.isWaitingForTask(taskId, unresolved),
                )
            }
    }

    @Test
    fun `the link is never dropped to make the pruning upload succeed`() {
        val linked = PruningActivityTaskLink.link(twoBlockDraft(), taskId)
        val queued = json.encodeToString(PruningActivityDraft.serializer(), linked)
        val replayed = json.decodeFromString(PruningActivityDraft.serializer(), queued)

        // The queued payload — the exact bytes the replay sends — still carries
        // the link, and a wait is a wait, not a strip.
        assertEquals(taskId, replayed.workTaskId)
        assertEquals(taskId, PruningSyncRepository.activityPayload(replayed).workTaskId)
    }

    // ---- canonical adoption ------------------------------------------------

    @Test
    fun `the canonical response restores work_task_id`() {
        val local = PruningActivityTaskLink.link(twoBlockDraft(), taskId)
        val canonical = json.decodeFromString(
            PruningActivityCanonical.serializer(),
            """
            {
              "activity": {
                "id": "$activityId",
                "vineyard_id": "$vineyard",
                "entry_date": "2026-08-04",
                "worker_or_crew": "Jon",
                "method": "spur",
                "labour_hours": 7.5,
                "hourly_rate": 35,
                "notes": "Finished Cab Franc and moved into Sauv Blanc",
                "work_task_id": "$otherTaskId",
                "season_year": 2026,
                "vintage_year": 2027,
                "is_reversed": false
              },
              "allocations": [
                {
                  "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                  "paddock_id": "$cabFranc",
                  "block_name": "Cab Franc",
                  "quarters": 12,
                  "estimated_vines": 240,
                  "pruning_season_id": "season-2026",
                  "season_year": 2026,
                  "segments": [{ "row": 42, "segment": 1 }]
                }
              ]
            }
            """.trimIndent(),
        )

        val adopted = PruningAllocationEditor.adoptCanonical(local, canonical)

        // The SERVER's link wins wholesale — including a task the server
        // resolved differently from this device's optimistic value.
        assertEquals(otherTaskId, adopted.workTaskId)
        assertTrue(adopted.serverAcknowledged)
        assertEquals(2026, adopted.serverSeasonYear)
        assertEquals(2027, adopted.vintageYear)
        assertEquals(setOf(cabFranc), adopted.allocations.keys)
    }

    @Test
    fun `a canonical response with no task clears the local link`() {
        val local = PruningActivityTaskLink.link(twoBlockDraft(), taskId)
        val canonical = json.decodeFromString(
            PruningActivityCanonical.serializer(),
            """
            {
              "activity": {
                "id": "$activityId",
                "vineyard_id": "$vineyard",
                "entry_date": "2026-08-04",
                "season_year": 2026,
                "is_reversed": false
              },
              "allocations": []
            }
            """.trimIndent(),
        )

        assertNull(PruningAllocationEditor.adoptCanonical(local, canonical).workTaskId)
    }

    // ---- surfacing + deep link ---------------------------------------------

    @Test
    fun `a link this device cannot resolve is surfaced not cleared`() {
        val draft = PruningActivityTaskLink.link(twoBlockDraft(), taskId)

        assertTrue(PruningActivityTaskLink.hasUnresolvableLink(draft, emptyList()))
        assertNull(PruningActivityTaskLink.linkedTask(draft, emptyList()))
        // Still linked — the editor warns instead of silently dropping it.
        assertEquals(taskId, draft.workTaskId)
        assertFalse(PruningActivityTaskLink.hasUnresolvableLink(draft, listOf(task())))
        assertFalse(PruningActivityTaskLink.hasUnresolvableLink(PruningActivityTaskLink.unlink(draft), emptyList()))
    }

    @Test
    fun `the Activity Report resolves the exact linked task`() {
        val draft = PruningActivityTaskLink.link(twoBlockDraft(), otherTaskId)
        val tasks = listOf(task(), task(id = otherTaskId, type = "Winter pruning", date = "2026-08-02"))

        val resolved = PruningActivityTaskLink.linkedTask(draft, tasks)
        assertEquals(otherTaskId, resolved?.id)
        assertEquals("Winter pruning", resolved?.taskType)
        assertEquals("Winter pruning · Cab Franc · 2026-08-02", PruningActivityTaskLink.label(resolved!!))
    }

    @Test
    fun `the task picker searches type block date and notes and hides dead tasks`() {
        val tasks = listOf(
            task(id = taskId, type = "Winter pruning", date = "2026-08-04"),
            task(id = otherTaskId, type = "Spur pruning", date = "2026-07-29"),
            task(id = "88888888-8888-4888-8888-888888888888").copy(isArchived = true),
            task(id = "99999999-9999-4999-8999-999999999999").copy(deletedAt = "2026-08-01T00:00:00Z"),
        )

        // Newest first, dead rows never offered.
        val all = PruningActivityTaskLink.search(tasks, "")
        assertEquals(listOf(taskId, otherTaskId), all.map { it.id })
        assertEquals(listOf(otherTaskId), PruningActivityTaskLink.search(tasks, "spur").map { it.id })
        assertEquals(listOf(taskId), PruningActivityTaskLink.search(tasks, "2026-08-04").map { it.id })
        assertEquals(2, PruningActivityTaskLink.search(tasks, "cab franc").size)
        assertTrue(PruningActivityTaskLink.search(tasks, "harvest").isEmpty())
    }
}
