package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class WorkTaskWriteParityTest {
    private val day = LocalDate.parse("2026-10-09")
    private val now = Instant.parse("2026-10-09T00:30:00Z")
    private val zone = ZoneId.of("UTC")

    @Test fun `new E-L insert omits date and vintage and accepts server-derived vintage`() {
        val draft = WorkTaskPlanningDraft(null, "vineyard", "author", scheduleBasis = "el_stage", targetStage = 35, date = now.toString(), taskType = "Pruning")
        val intent = WorkTaskWriteContract.planning(draft, "stable-id", day, now, null, "", 0.0)
        assertFalse("date" in intent.payload); assertFalse("vintage_year" in intent.payload)
        assertEquals(JsonNull, intent.payload["start_date"]); assertEquals(JsonNull, intent.payload["end_date"])
        assertEquals(JsonPrimitive(false), intent.payload["is_finalized"])
        val row = JsonObject(intent.payload + mapOf("date" to JsonPrimitive(now.toString()), "vintage_year" to JsonPrimitive(2027)))
        WorkTaskWriteContract.verify(null, intent.payload, row, emptyList())
    }
    @Test fun `mode switches preserve anchor and omit completion`() {
        val stored = JsonPrimitive("2025-07-11T22:31:00Z")
        val stage = WorkTaskWriteContract.schedule("el_stage", 35, day, stored)
        assertEquals(stored, stage["date"]); assertEquals(JsonNull, stage["start_date"]); assertFalse("end_date" in stage)
        val dated = WorkTaskWriteContract.schedule("date", null, day, stored)
        assertEquals(JsonPrimitive("2026-10-09"), dated["date"]); assertEquals(dated["date"], dated["start_date"])
        assertEquals(JsonNull, dated["target_el_stage"]); assertFalse("vintage_year" in dated)
    }
    @Test fun `completion records authenticated person and real press instant not backdated date`() {
        val task = WorkTask("task", "vineyard", assignedTo = "worker", scheduleBasis = "el_stage", targetELStage = 35)
        val payload = WorkTaskWriteContract.completion("complete", task, LocalDate.parse("2026-10-04"), zone, now, "completer")
        assertEquals(JsonPrimitive("completer"), payload["completed_by"])
        assertEquals(JsonPrimitive(now.toString()), payload["completed_at"])
        assertEquals(JsonPrimitive("2026-10-04"), payload["end_date"])
        assertFalse("assigned_to" in payload); assertFalse("status" in payload); assertFalse("target_el_stage" in payload)
    }
    @Test fun `reopen clears audit only and date correction preserves original audit`() {
        val task = WorkTask("task", "vineyard", isFinalized = true, assignedTo = "worker", scheduleBasis = "el_stage", targetELStage = 35, completedBy = "original", completedAt = now.toString())
        val reopen = WorkTaskWriteContract.completion("reopen", task, null, zone, now, "editor")
        listOf("end_date", "completed_by", "completed_at", "finalized_by", "finalized_at").forEach { assertEquals(JsonNull, reopen[it]) }
        val correction = WorkTaskWriteContract.completion("completion_date", task, day, zone, now, "editor")
        assertEquals(setOf("is_finalized", "end_date"), correction.keys)
    }
    @Test fun `business date leading component does not shift but audit fallback uses vineyard timezone`() {
        val task = WorkTask("task", "vineyard", isFinalized = true, completedAt = now.toString())
        val west = ZoneId.of("America/Los_Angeles")
        assertEquals(LocalDate.parse("2026-10-08"), WorkTaskCompletion.completedDate(task, west))
        assertEquals(LocalDate.parse("2026-10-07"), WorkTaskCompletion.completedDate(task.copy(endDate = "2026-10-07T00:00:00Z"), west))
        assertFalse(WorkTaskCompletion.isValid(task, day, west, now))
    }
    @Test fun `stale versions and changed preserved audit cannot acknowledge`() {
        val baseline = buildJsonObject { put("sync_version", 4); put("completed_by", JsonNull) }
        val patch = buildJsonObject { put("sync_version", 5) }
        val stale = buildJsonObject { put("sync_version", 6); put("completed_by", JsonNull); put("vintage_year", 2027) }
        assertThrows(IllegalStateException::class.java) { WorkTaskWriteContract.verify(baseline, patch, stale, baseline.keys.toList()) }
        val changed = JsonObject(stale + mapOf("sync_version" to JsonPrimitive(5), "completed_by" to JsonPrimitive("someone")))
        assertThrows(IllegalStateException::class.java) { WorkTaskWriteContract.verify(baseline, patch, changed, baseline.keys.toList()) }
    }
    @Test fun `conditional predicates preserve original version raw timestamp scope and deliberate nulls`() {
        val baseline = buildJsonObject { put("id", "task"); put("vineyard_id", "vineyard"); put("sync_version", 7); put("updated_at", "2026-10-09T00:00:00.123456+00:00"); put("deleted_at", JsonNull); put("assigned_to", JsonNull) }
        val result = WorkTaskWriteContract.predicates(baseline, baseline.keys.toList())
        assertEquals("eq.7", result["sync_version"]); assertEquals("eq.vineyard", result["vineyard_id"])
        assertEquals("eq.2026-10-09T00:00:00.123456+00:00", result["updated_at"]); assertEquals("is.null", result["assigned_to"])
        assertThrows(IllegalArgumentException::class.java) { WorkTaskWriteContract.predicates(JsonObject(emptyMap()), baseline.keys.toList()) }
    }
    @Test fun `dated completion rejects before work day and E-L rejects unsupported catalogue gaps`() {
        val task = WorkTask("task", "vineyard", date = "2026-10-09T00:00:00Z", startDate = "2026-10-09T00:00:00Z", status = "completed")
        assertThrows(IllegalArgumentException::class.java) { WorkTaskWriteContract.completion("complete", task, day.minusDays(1), zone, now, "author") }
        assertThrows(IllegalArgumentException::class.java) { WorkTaskWriteContract.schedule("el_stage", 6, day, null) }
        assertFalse(task.isComplete)
    }
    @Test fun `lost response persists original intent and restart cannot replay or rebase`() = runTest {
        val disk = mutableMapOf<String, String>()
        val store = WorkTaskPlanningDraftStore({ disk[it] }, { key, value -> disk[key] = value; true })
        val intent = WorkTaskWriteIntent("task", "vineyard", "author", "original", buildJsonObject { put("completed_at", now.toString()) })
        var calls = 0
        try {
            WorkTaskWriteCoordinator(store).submit(intent, { true }) {
                assertEquals(intent, store.loadIntent("author", "vineyard", "task")); calls++
                error("Response lost after server commit")
            }
            fail("Unknown outcome cannot succeed")
        } catch (_: IllegalStateException) {}
        val restarted = WorkTaskPlanningDraftStore({ disk[it] }, { key, value -> disk[key] = value; true })
        try {
            WorkTaskWriteCoordinator(restarted).submit(intent.copy(baselineJson = "newer"), { true }) {
                calls++; WorkTask("task", "vineyard")
            }
            fail("Original unknown request cannot be replaced")
        } catch (_: IllegalStateException) {}
        assertEquals(1, calls); assertEquals(intent, restarted.loadIntent("author", "vineyard", "task"))
    }
    @Test fun `persistence failure prevents network initiation`() = runTest {
        val store = WorkTaskPlanningDraftStore({ null }, { _, _ -> false })
        var calls = 0
        try {
            WorkTaskWriteCoordinator(store).submit(WorkTaskWriteIntent("task", "vineyard", "author", null, JsonObject(emptyMap())), { true }) {
                calls++; WorkTask("task", "vineyard")
            }
            fail("Disk failure must abort")
        } catch (_: IllegalStateException) {}
        assertEquals(0, calls)
    }
    @Test fun `account change after response prevents acknowledgement`() = runTest {
        val disk = mutableMapOf<String, String>()
        val store = WorkTaskPlanningDraftStore({ disk[it] }, { key, value -> disk[key] = value; true })
        val intent = WorkTaskWriteIntent("task", "vineyard", "author", null, JsonObject(emptyMap()))
        var sameAccount = true
        try {
            WorkTaskWriteCoordinator(store).submit(intent, { sameAccount }) { sameAccount = false; WorkTask("task", "vineyard") }
            fail("Account-switched result cannot acknowledge")
        } catch (_: IllegalStateException) {}
        assertEquals(false, store.loadIntent("author", "vineyard", "task")?.acknowledged)
    }
}
