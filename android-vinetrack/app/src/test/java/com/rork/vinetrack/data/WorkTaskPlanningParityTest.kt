package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.LocalDate
import java.io.File

class WorkTaskPlanningParityTest {
    @Test fun `portal order keeps to do first then descending stages and upcoming dates`() {
        val now = Instant.parse("2026-10-08T10:00:00Z")
        val stage35 = WorkTask("stage35", "vineyard", date = "2030-01-01T00:00:00Z", scheduleBasis = "el_stage", targetELStage = 35)
        val stage12 = stage35.copy(id = "stage12", date = "2000-01-01T00:00:00Z", targetELStage = 12)
        val near = WorkTask("near", "vineyard", date = "2026-10-09T10:00:00Z")
        val later = near.copy(id = "later", date = "2026-10-18T10:00:00Z")
        val past = near.copy(id = "past", date = "2026-10-07T10:00:00Z")
        val completed = stage35.copy(id = "completed", targetELStage = 43, isFinalized = true)
        assertEquals(listOf("stage35", "stage12", "near", "later", "past", "completed"), WorkTaskPlanning.ordered(listOf(completed, later, past, stage12, near, stage35), now, ZoneId.of("UTC")).map { it.id })
    }

    @Test fun `inclusive stage range combines search and excludes dated tasks`() {
        val low = WorkTask("low", "vineyard", taskType = "Pruning", scheduleBasis = "el_stage", targetELStage = 12)
        val high = low.copy(id = "high", targetELStage = 35)
        val dated = low.copy(id = "dated", scheduleBasis = "date", targetELStage = null)
        assertEquals(listOf("low", "high"), listOf(low, high, dated).filter { it.matchesStageRange(12, 35) && it.taskType?.contains("Pruning") == true }.map { it.id })
        assertFalse(low.matchesStageRange(35, 12))
        assertTrue(dated.matchesStageRange(null, null))
    }

    @Test fun `draft validates catalogue exclusivity and date range`() {
        val draft = WorkTaskPlanningDraft(null, "vineyard", "author", scheduleBasis = "el_stage", targetStage = 35, date = "2026-10-08T00:00:00Z", taskType = "Pruning")
        assertTrue(draft.isValid)
        assertFalse(draft.copy(targetStage = 44).isValid)
        assertEquals(2 in WorkTaskPlanning.supportedStages, draft.copy(targetStage = 2).isValid)
        assertFalse(draft.copy(assignedTo = "member", externalId = "crew").isValid)
        assertTrue(draft.copy(assignedTo = "member").isValid)
        assertFalse(draft.copy(scheduleBasis = "date", endDate = "2026-10-07T00:00:00Z").isValid)
    }

    @Test fun `real disk restart retains local planning draft and intentional clearing without a sync payload`() {
        val directory = File(System.getProperty("java.io.tmpdir"), java.util.UUID.randomUUID().toString())
        assertTrue(directory.mkdir())
        try {
            val store = WorkTaskPlanningDraftStore({ key -> File(directory, key).takeIf { it.exists() }?.readText() }, { key, value -> File(directory, key).writeText(value); true })
            val draft = WorkTaskPlanningDraft("task", "vineyard", "author", externalId = "crew", assignmentName = "Inactive historical crew", scheduleBasis = "el_stage", targetStage = 35, date = "2026-10-08T00:00:00Z", taskType = "My custom work", blockIds = setOf("block"), durationText = "8", notes = "Unsaved instructions")
            store.save(draft)
            val restarted = WorkTaskPlanningDraftStore({ key -> File(directory, key).takeIf { it.exists() }?.readText() }, { key, value -> File(directory, key).writeText(value); true })
            assertEquals(draft, restarted.load("author", "vineyard", "task"))
            restarted.save(draft.copy(externalId = null, assignmentName = ""))
            assertNull(restarted.load("author", "vineyard", "task")?.externalId)
            assertNull(restarted.load("other-author", "vineyard", "task"))
            assertNull(restarted.load("author", "other-vineyard", "task"))
            val canonical = WorkTask("task", "vineyard")
            assertNull(canonical.assignedExternalResourceId)
            assertFalse(canonical.isStageScheduled)
        } finally { directory.deleteRecursively() }
    }

    @Test fun `failed durable draft write cannot report success`() {
        val store = WorkTaskPlanningDraftStore({ null }, { _, _ -> false })
        val draft = WorkTaskPlanningDraft(null, "vineyard", "author", date = "2026-10-08T00:00:00Z", taskType = "Pruning")
        assertThrows(IllegalStateException::class.java) { store.save(draft) }
    }

    @Test fun `recorded completer is distinct from assignee and linked operator`() {
        val task = WorkTask("task", "vineyard", isFinalized = true, assignedTo = "assignee", completedBy = "completer")
        val trip = Trip("trip", "vineyard", endTime = "2026-10-08T00:00:00Z", operatorUserId = "operator", workTaskId = "task")
        assertEquals("completer", WorkTaskPlanning.completingUser(task, listOf(trip), emptySet()))
        assertEquals("assignee", task.assignedTo)
    }

    @Test fun `only unambiguous finished same vineyard trips attribute historical completion`() {
        val task = WorkTask("task", "vineyard", isFinalized = true, finalizedBy = "Free text")
        val trip = Trip("trip", "vineyard", endTime = "2026-10-08T00:00:00Z", operatorUserId = "operator", workTaskId = "task")
        assertEquals("operator", WorkTaskPlanning.completingUser(task, listOf(trip), emptySet()))
        assertNull(WorkTaskPlanning.completingUser(task, listOf(trip, trip.copy(id = "second", operatorUserId = "other")), emptySet()))
        assertNull(WorkTaskPlanning.completingUser(task, listOf(trip, trip.copy(id = "second", operatorUserId = null)), emptySet()))
        assertNull(WorkTaskPlanning.completingUser(task, listOf(trip.copy(vineyardId = "other-vineyard")), emptySet()))
        assertNull(WorkTaskPlanning.completingUser(task, listOf(trip.copy(isActive = true)), emptySet()))
    }

    @Test fun `canonical completion instant displays vineyard day across UTC midnight`() {
        val task = WorkTask("task", "vineyard", isFinalized = true, completedAt = "2026-10-08T00:30:00Z", completedBy = "member")
        assertEquals(LocalDate.parse("2026-10-07"), WorkTaskCompletion.completedDate(task, ZoneId.of("America/Los_Angeles")))
        assertEquals(LocalDate.parse("2026-10-08"), WorkTaskCompletion.completedDate(task, ZoneId.of("Pacific/Auckland")))
        assertEquals("2026-10-08T00:30:00Z", task.completedAt)
    }

    @Test fun `draft permissions and selectable resource scope fail closed`() {
        val draft = WorkTaskPlanningDraft(null, "vineyard", "author", date = "2026-10-08T00:00:00Z", taskType = "Pruning")
        assertTrue(WorkTaskPlanning.canSaveDraft(draft, "author", "vineyard", "operator"))
        assertFalse(WorkTaskPlanning.canSaveDraft(draft, "author", "vineyard", "admin"))
        assertFalse(WorkTaskPlanning.canSaveDraft(draft, null, "vineyard", "owner"))
        assertFalse(WorkTaskPlanning.canSaveDraft(draft, "author", "other-vineyard", "owner"))
        val resource = VineyardExternalResource("resource", "vineyard", "Historical crew", "crew")
        assertTrue(WorkTaskPlanning.canSelect(resource, "vineyard"))
        assertFalse(WorkTaskPlanning.canSelect(resource, "other-vineyard"))
        assertFalse(WorkTaskPlanning.canSelect(resource.copy(isActive = false), "vineyard"))
        assertEquals("Historical crew", resource.copy(isActive = false).name)
    }

    @Test fun `directory payload explicitly clears contacts but cannot write audit or cost fields`() {
        val resource = VineyardExternalResource("resource", "vineyard", "Crew", "crew")
        val payload = ExternalResourceRepository.payload(resource)
        assertEquals(JsonNull, payload["phone"])
        assertEquals(JsonNull, payload["contact_name"])
        assertFalse(payload.containsKey("updated_at"))
        assertFalse(payload.containsKey("created_by"))
        assertFalse(payload.containsKey("hourly_rate"))
        assertNotEquals(payload, ExternalResourceRepository.payload(resource.copy(isActive = false)))
    }
}
