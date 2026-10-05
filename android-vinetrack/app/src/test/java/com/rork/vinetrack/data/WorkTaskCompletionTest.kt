package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class WorkTaskCompletionTest {
    private val zone = ZoneId.of("Australia/Adelaide")
    private val now = Instant.parse("2026-10-05T01:20:30Z")
    private val task = WorkTask(id = "task", vineyardId = "vineyard", date = "2026-09-28T09:00:00+09:30",
        startDate = "2026-09-28T09:00:00+09:30", status = "planned", notes = "Keep me",
        costingMethod = "piece_rate", pieceRatePerVine = 1.27, pieceVineCount = 499, pruningActivityId = "pruning")
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    private class Server : WorkTaskHeaderWriting {
        val creates = mutableListOf<WorkTaskCreateSync.Payload>()
        val updates = mutableListOf<WorkTaskUpdateSync.Payload>()
        var duringUpdate: (() -> Unit)? = null
        var duplicateCreate: Boolean = false
        var rejectUpdate: Boolean = false
        override suspend fun replayCreate(payload: WorkTaskCreateSync.Payload): WorkTask {
            creates.add(payload)
            if (duplicateCreate) throw BackendError.Server(409, "Duplicate client id")
            return WorkTask(payload.id, payload.vineyardId)
        }
        override suspend fun replayUpdate(payload: WorkTaskUpdateSync.Payload): WorkTask {
            updates.add(payload)
            duringUpdate?.invoke()
            if (rejectUpdate) throw BackendError.Server(400, "Rejected old request")
            return WorkTask(payload.id, "vineyard")
        }
    }

    @Test fun `Sydney Work Date selection round trips the UTC picker calendar day`() {
        val sydney = ZoneId.of("Australia/Sydney")
        val selected = Instant.parse("2026-10-05T00:00:00Z").toEpochMilli()
        val stored = WorkTaskCompletion.workDateFromPicker(selected, sydney).toString()
        assertEquals("2026-10-04T13:00:00Z", stored)
        assertEquals(LocalDate.parse("2026-10-05"), WorkTaskCompletion.workDate(task.copy(startDate = stored, date = stored), sydney))
    }

    @Test fun `Los Angeles Work Date selection round trips the UTC picker calendar day`() {
        val la = ZoneId.of("America/Los_Angeles")
        val selected = Instant.parse("2026-10-05T00:00:00Z").toEpochMilli()
        val stored = WorkTaskCompletion.workDateFromPicker(selected, la).toString()
        assertEquals("2026-10-05T07:00:00Z", stored)
        assertEquals(LocalDate.parse("2026-10-05"), WorkTaskCompletion.workDate(task.copy(startDate = stored, date = stored), la))
    }

    @Test fun `legacy UTC midnight Work Date in Los Angeles preserves encoded day without mutation`() {
        val la = ZoneId.of("America/Los_Angeles")
        for (value in listOf("2026-10-05T00:00:00Z", "2026-10-05T00:00:00.000Z", "2026-10-05T00:00:00+00:00")) {
            val decoded = json.decodeFromString<WorkTask>("""{"id":"legacy","vineyard_id":"vineyard","start_date":"$value","date":"$value"}""")
            assertEquals(LocalDate.parse("2026-10-05"), WorkTaskCompletion.workDate(decoded, la))
            assertEquals(value, decoded.startDate)
            assertEquals(value, decoded.date)
            assertEquals(LocalDate.parse("2026-10-05"), WorkTaskCompletion.workDate(decoded.copy(startDate = null), la))
        }
    }

    @Test fun `new local midnight Work Date resolves through vineyard timezone`() {
        val la = ZoneId.of("America/Los_Angeles")
        val stored = "2026-10-05T07:00:00Z"
        assertEquals(LocalDate.parse("2026-10-05"), WorkTaskCompletion.localDate(stored, la))
        assertEquals(LocalDate.parse("2026-10-04"), WorkTaskCompletion.localDate(stored, ZoneId.of("Pacific/Honolulu")))
        assertEquals(LocalDate.parse("2026-10-04"), WorkTaskCompletion.localDate("2026-10-05T00:00:00.001Z", la))
    }

    @Test fun `completion cannot precede correctly resolved legacy or new Work Date`() {
        val la = ZoneId.of("America/Los_Angeles")
        val audit = Instant.parse("2026-10-06T12:00:00Z")
        for (stored in listOf("2026-10-05T00:00:00Z", "2026-10-05T07:00:00Z")) {
            val work = task.copy(startDate = stored, date = stored)
            assertFalse(WorkTaskCompletion.isValid(work, LocalDate.parse("2026-10-04"), la, audit))
            assertTrue(runCatching { WorkTaskCompletion.complete(work, LocalDate.parse("2026-10-04"), la, audit, "user") }.isFailure)
            assertTrue(WorkTaskCompletion.isValid(work, LocalDate.parse("2026-10-05"), la, audit))
        }
    }

    @Test fun `midnight completion audit remains a real instant rather than a legacy business day`() {
        val la = ZoneId.of("America/Los_Angeles")
        val completed = task.copy(isFinalized = true, finalizedAt = "2026-10-05T00:00:00Z", endDate = null)
        assertEquals(LocalDate.parse("2026-10-04"), WorkTaskCompletion.completedDate(completed, la))
    }

    @Test fun `customer A B C keeps work date and separate audit`() {
        val completed = WorkTaskCompletion.complete(task, LocalDate.parse("2026-09-30"), zone, now, "android-user")
        assertEquals(task.date, completed.date)
        assertEquals(task.startDate, completed.startDate)
        assertEquals(LocalDate.parse("2026-09-30"), WorkTaskCompletion.completedDate(completed, zone))
        assertEquals(now.toString(), completed.finalizedAt)
        assertEquals("android-user", completed.finalizedBy)
        assertTrue(completed.isComplete)
        val reopened = WorkTaskCompletion.reopen(completed)
        assertEquals(task, reopened)
        val again = WorkTaskCompletion.complete(reopened, LocalDate.parse("2026-10-01"), zone, now.plusSeconds(90), "android-user")
        assertEquals(LocalDate.parse("2026-10-01"), WorkTaskCompletion.completedDate(again, zone))
        assertEquals(now.plusSeconds(90).toString(), again.finalizedAt)
        assertEquals(task.pieceRateCost, again.pieceRateCost)
    }

    @Test fun `business date correction preserves audit and all other fields`() {
        val completed = WorkTaskCompletion.complete(task, LocalDate.parse("2026-09-30"), zone, now, "user")
        val edited = WorkTaskCompletion.editDate(completed, LocalDate.parse("2026-10-01"), zone, now.plusSeconds(90))
        assertEquals(completed, edited.copy(endDate = completed.endDate))
    }

    @Test fun `vineyard local calendar validates dates and legacy fallback without mutation`() {
        assertFalse(WorkTaskCompletion.isValid(task, LocalDate.parse("2026-09-27"), zone, now))
        assertFalse(WorkTaskCompletion.isValid(task, LocalDate.parse("2026-10-06"), zone, now))
        assertTrue(WorkTaskCompletion.isValid(task, LocalDate.parse("2026-09-28"), zone, now))
        val legacy = task.copy(isFinalized = true, finalizedAt = "2026-10-04T15:00:00Z")
        assertEquals(LocalDate.parse("2026-10-05"), WorkTaskCompletion.completedDate(legacy, zone))
        assertNull(legacy.endDate)
        assertNull(WorkTaskCompletion.completedDate(task.copy(status = "completed"), zone))
        assertNull(WorkTaskCompletion.completedDate(task.copy(isFinalized = true), zone))
    }

    @Test fun `offline update survives restart overlay full refresh and replay with original audit`() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val server = Server()
        val first = PendingWriteRepository(store)
        val completed = WorkTaskCompletion.complete(task, LocalDate.parse("2026-09-30"), zone, now, "original-user")
        WorkTaskUpdateSync(server, first).enqueue(task.id, task.paddockId, task.paddockName, task.date!!, task.taskType ?: "",
            task.durationHours, task.notes, true, completed.finalizedAt, completed.finalizedBy, now.toString(),
            endDate = completed.endDate, completionOnly = true)
        val restarted = PendingWriteRepository(store)
        val restored = PendingWriteOverlay.overlayWorkTaskHeaders(listOf(task), restarted.list(), task.vineyardId).single()
        assertEquals(completed, restored.copy(paddockName = completed.paddockName, taskType = completed.taskType))
        WorkTaskUpdateSync(server, restarted).replayAll {}
        val uploaded = server.updates.single()
        assertEquals(completed.endDate, uploaded.endDate)
        assertEquals(now.toString(), uploaded.finalizedAt)
        assertEquals("original-user", uploaded.finalizedBy)
        assertTrue(uploaded.isFinalized)
        assertTrue(restarted.list().isEmpty())
        val remote = json.decodeFromString<WorkTask>("""{"id":"task","vineyard_id":"vineyard","date":"2026-09-28T09:00:00+09:30","is_finalized":true,"end_date":"${completed.endDate}","finalized_at":"${now}","finalized_by":"original-user"}""")
        assertEquals(LocalDate.parse("2026-09-30"), WorkTaskCompletion.completedDate(remote, zone))
    }

    @Test fun `completion folds into pending create and metadata edit never restamps audit`() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(store)
        val server = Server()
        val creates = WorkTaskCreateSync(server, pending)
        creates.enqueue(task.id, task.vineyardId, null, null, task.date!!, "Pruning", 3.0, task.notes, "original-create", pruningActivityId = "pruning")
        val completed = WorkTaskCompletion.complete(task, LocalDate.parse("2026-09-30"), zone, now, "original-user")
        assertTrue(creates.foldEdit(task.id, null, null, task.date!!, "Pruning", 3.0, task.notes, true, now.toString(), completed.endDate, completed.finalizedAt, completed.finalizedBy))
        assertTrue(creates.foldEdit(task.id, null, null, task.date!!, "Pruning", 3.0, "Later unrelated edit", true, "later-edit"))
        assertEquals(1, pending.list().size)
        val restarted = PendingWriteRepository(store)
        val restored = PendingWriteOverlay.overlayWorkTaskHeaders(emptyList(), restarted.list(), task.vineyardId).single()
        assertEquals(completed.endDate, restored.endDate)
        assertEquals(completed.finalizedAt, restored.finalizedAt)
        assertEquals("original-user", restored.finalizedBy)
        assertEquals("pruning", restored.pruningActivityId)
        WorkTaskCreateSync(server, restarted).replayAll {}
        assertEquals(completed.endDate, server.creates.single().endDate)
        assertEquals(completed.finalizedAt, server.creates.single().finalizedAt)
        assertEquals("original-user", server.creates.single().finalizedBy)
    }

    @Test fun `reopen uses explicit nulls with no unrelated columns`() {
        val patch = WorkTaskRepository.completionPatch(false, null, null, null, now.toString())
        assertEquals(JsonNull, patch["end_date"])
        assertEquals(JsonNull, patch["finalized_at"])
        assertEquals(JsonNull, patch["finalized_by"])
        assertEquals(JsonPrimitive(false), patch["is_finalized"])
        assertEquals(setOf("is_finalized", "end_date", "finalized_at", "finalized_by", "client_updated_at"), patch.keys)
    }

    @Test fun `in flight update cannot erase newer completion date`() = runBlocking {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        val server = Server()
        val sync = WorkTaskUpdateSync(server, pending)
        fun enqueue(end: String) = sync.enqueue(task.id, null, null, task.date!!, "Pruning", 3.0, null, true,
            now.toString(), "user", now.toString(), endDate = end, dateOnly = true)
        enqueue("2026-09-29T14:30:00Z")
        server.duringUpdate = { enqueue("2026-09-30T14:30:00Z") }
        var reconciled = false
        sync.replayAll { reconciled = true }
        assertFalse(reconciled)
        assertEquals(1, pending.list().size)
        assertEquals("2026-09-30T14:30:00Z", json.decodeFromString<WorkTaskUpdateSync.Payload>(pending.list().single().payloadJson).endDate)
    }

    @Test fun `repeated queued date edits stay narrow but an unsynced completion retains its contract`() {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        val sync = WorkTaskUpdateSync(Server(), pending)
        fun enqueue(dateOnly: Boolean) = sync.enqueue(task.id, null, null, task.date!!, "Pruning", 0.0, null,
            true, now.toString(), "user", now.toString(), endDate = "2026-09-30T14:30:00Z", dateOnly = dateOnly, completionOnly = !dateOnly)
        enqueue(true)
        enqueue(true)
        var payload = json.decodeFromString<WorkTaskUpdateSync.Payload>(pending.list().single().payloadJson)
        assertTrue(payload.dateOnly)
        assertFalse(payload.completionOnly)
        enqueue(false)
        enqueue(true)
        payload = json.decodeFromString(pending.list().single().payloadJson)
        assertFalse(payload.dateOnly)
        assertTrue(payload.completionOnly)
    }

    @Test fun `stale rejection cannot block a newer queued completion date`() = runBlocking {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        val server = Server().apply { rejectUpdate = true }
        val sync = WorkTaskUpdateSync(server, pending)
        fun enqueue(end: String) = sync.enqueue(task.id, null, null, task.date!!, "Pruning", 0.0, null,
            true, now.toString(), "user", now.toString(), endDate = end, dateOnly = true)
        enqueue("old")
        server.duringUpdate = { enqueue("new") }
        sync.replayAll {}
        assertEquals(PendingWriteStatus.PENDING, pending.list().single().status)
        assertEquals("new", json.decodeFromString<WorkTaskUpdateSync.Payload>(pending.list().single().payloadJson).endDate)
    }

    @Test fun `interrupted upload restarts retryable with frozen completion audit`() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val first = PendingWriteRepository(store)
        val server = Server()
        val complete = WorkTaskCompletion.complete(task, LocalDate.parse("2026-09-30"), zone, now, "original-user")
        val marker = WorkTaskUpdateSync(server, first).enqueue(task.id, null, null, task.date!!, "Pruning", 0.0, null,
            true, complete.finalizedAt, complete.finalizedBy, now.toString(), endDate = complete.endDate, completionOnly = true)
        first.updateStatus(marker.id, PendingWriteStatus.IN_PROGRESS)
        val restarted = PendingWriteRepository(store)
        assertEquals(PendingWriteStatus.FAILED, restarted.list().single().status)
        WorkTaskUpdateSync(server, restarted).replayAll {}
        assertEquals(complete.endDate, server.updates.single().endDate)
        assertEquals(complete.finalizedAt, server.updates.single().finalizedAt)
        assertEquals("original-user", server.updates.single().finalizedBy)
        assertTrue(restarted.list().isEmpty())
    }

    @Test fun `duplicate pending create patches folded completion before acknowledgement`() = runBlocking {
        val pending = PendingWriteRepository(InMemoryPendingWriteStore())
        val server = Server().apply { duplicateCreate = true }
        val complete = WorkTaskCompletion.complete(task, LocalDate.parse("2026-09-30"), zone, now, "original-user")
        WorkTaskCreateSync(server, pending).enqueue(task.id, task.vineyardId, null, null, task.date!!, "Pruning", 0.0, null,
            now.toString(), true, endDate = complete.endDate, finalizedAt = complete.finalizedAt, finalizedBy = complete.finalizedBy)
        WorkTaskCreateSync(server, pending).replayAll {}
        assertEquals(complete.endDate, server.updates.single().endDate)
        assertEquals(complete.finalizedAt, server.updates.single().finalizedAt)
        assertEquals(complete.finalizedBy, server.updates.single().finalizedBy)
        assertTrue(pending.list().isEmpty())
    }

    @Test fun `queued date correction preserves audit through restart and replay`() = runBlocking {
        val store = InMemoryPendingWriteStore()
        val server = Server()
        val complete = WorkTaskCompletion.complete(task, LocalDate.parse("2026-09-30"), zone, now, "original-user")
        val edited = WorkTaskCompletion.editDate(complete, LocalDate.parse("2026-10-01"), zone, now)
        WorkTaskUpdateSync(server, PendingWriteRepository(store)).enqueue(task.id, null, null, task.date!!, "Pruning", 0.0, null,
            true, edited.finalizedAt, edited.finalizedBy, now.plusSeconds(90).toString(), endDate = edited.endDate, dateOnly = true)
        val restarted = PendingWriteRepository(store)
        WorkTaskUpdateSync(server, restarted).replayAll {}
        assertTrue(server.updates.single().dateOnly)
        assertEquals(edited.endDate, server.updates.single().endDate)
        assertEquals(complete.finalizedAt, server.updates.single().finalizedAt)
        assertEquals(complete.finalizedBy, server.updates.single().finalizedBy)
    }

    @Test fun `failed durable replacement retains original completion payload`() {
        var fail = false
        val memory = InMemoryPendingWriteStore()
        val disk = object : PendingWriteStoring {
            override fun load(): List<PendingWrite> = memory.load()
            override fun save(writes: List<PendingWrite>): Boolean = if (fail) false else memory.save(writes)
            override fun clear(): Boolean = memory.clear()
        }
        val pending = PendingWriteRepository(disk)
        val sync = WorkTaskUpdateSync(Server(), pending)
        sync.enqueue(task.id, null, null, task.date!!, "Pruning", 3.0, null, true, now.toString(), "user", now.toString(), endDate = "old-date")
        fail = true
        assertTrue(runCatching { sync.enqueue(task.id, null, null, task.date!!, "Pruning", 3.0, null, true, now.toString(), "user", "later", endDate = "new-date") }.isFailure)
        assertEquals("old-date", json.decodeFromString<WorkTaskUpdateSync.Payload>(PendingWriteRepository(disk).list().single().payloadJson).endDate)
    }
}
