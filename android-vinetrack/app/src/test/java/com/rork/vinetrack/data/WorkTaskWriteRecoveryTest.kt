package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

class WorkTaskWriteRecoveryTest {
    private val disk = mutableMapOf<String, String>()
    private var failKey: String? = null
    private val store get() = WorkTaskPlanningDraftStore({ disk[it] }, { key, value -> if (key == failKey) false else { disk[key] = value; true } })
    private val draft = WorkTaskPlanningDraft(null, "vineyard", "author", assignedTo = "greg", assignmentName = "Greg Horner", date = "2026-11-05", taskType = "Vine work", durationText = "1", notes = "Need bamboo and loose tie onto it", creationId = "original-task")
    private val intent get() = WorkTaskWriteContract.planning(draft, "original-task", LocalDate.parse("2026-11-05"), Instant.parse("2026-10-30T05:00:00Z"), null, "", 0.0)
    private val saved get() = WorkTask("original-task", "vineyard", syncVersion = 1)
    private fun row(original: WorkTaskWriteIntent = intent) = JsonObject(original.payload + mapOf("vintage_year" to JsonPrimitive(2027)))
    private suspend fun failure(block: suspend () -> Unit): TaskWriteFailure {
        try { block(); fail("Expected retained failure") } catch (error: TaskWriteFailure) { return error }
        error("unreachable")
    }
    @Test fun `preflight fails unsent then deliberate retry uses identical request`() = runTest {
        store.save(draft)
        val original = intent
        val result = failure { WorkTaskWriteCoordinator(store).submitTracked(original, { true }) { _, _, progress -> progress(TaskWriteStage.MEMBERSHIP); error("Connection failed before task write") } }
        assertEquals(TaskWritePhase.UNSENT, result.phase); assertEquals(TaskWriteStage.MEMBERSHIP, result.stage)
        val bytes = disk.getValue(original.persistenceKey)
        val restored = store.loadIntent("author", "vineyard", "original-task")!!
        WorkTaskWriteCoordinator(store).submitTracked(restored, { true }, retryOriginal = true) { request, dispatch, _ ->
            assertEquals(original, request); assertEquals(bytes, disk[original.persistenceKey]); dispatch(); saved
        }
        assertTrue(store.loadIntent("author", "vineyard", "original-task")!!.acknowledged)
        assertEquals(draft, store.load("author", "vineyard", null))
    }
    @Test fun `unsent request never automatically retries`() = runTest {
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, _, _ -> error("Offline") } }
        var sent = false
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, _, _ -> sent = true; saved } }
        assertFalse(sent)
    }
    @Test fun `rejected session before dispatch remains unsent with authentication diagnostics`() = runTest {
        val error = failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, _, progress ->
            progress(TaskWriteStage.SESSION)
            throw TaskWriteFailure(TaskWriteStage.SESSION, TaskWritePhase.UNSENT, 401, "invalid_grant", IllegalStateException("Refresh rejected"))
        } }
        assertEquals(401, error.status); assertEquals("invalid_grant", error.code)
        assertTrue(error.userMessage.contains("original account")); assertEquals(TaskWritePhase.UNSENT, store.recovery(intent)!!.phase)
    }
    @Test fun `task write rejection records HTTP and database code`() = runTest {
        val error = failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ ->
            dispatch(); throw TaskWriteFailure(TaskWriteStage.SERVER_REJECTION, TaskWritePhase.REJECTED, 403, "42501", IllegalStateException("RLS rejection"))
        } }
        assertEquals(403, error.status); assertEquals("42501", store.recovery(intent)!!.code)
        assertEquals(TaskWritePhase.REJECTED, store.recovery(intent)!!.phase)
    }
    @Test fun `server success lost response recovers by positive read without another creation`() = runTest {
        var writes = 0
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ -> dispatch(); writes++; error("Response lost after commit") } }
        val bytes = disk.getValue(intent.persistenceKey)
        val recovered = WorkTaskWriteCoordinator(store).recover(intent, { true }) { WorkTaskRecoveryProof.verify(it, row(it)) }
        assertEquals("original-task", recovered.id); assertEquals(1, writes)
        assertEquals(1L, recovered.syncVersion); assertTrue(store.loadIntent("author", "vineyard", "original-task")!!.acknowledged)
        assertNotEquals(bytes, disk[intent.persistenceKey]) // Only acknowledgement changed; payload is identical.
        assertEquals(intent.payload, store.loadIntent("author", "vineyard", "original-task")!!.payload)
    }
    @Test fun `unknown dispatch cannot be deliberately resent`() = runTest {
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ -> dispatch(); error("Timeout") } }
        var calls = 0
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }, true) { _, _, _ -> calls++; saved } }
        assertEquals(0, calls)
    }
    @Test fun `old intent with no lifecycle remains unknown after restart`() = runTest {
        store.saveIntent(intent)
        assertNull(store.recovery(intent))
        val error = failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }, true) { _, _, _ -> fail("Do not send old ambiguous request"); saved } }
        assertEquals(TaskWritePhase.UNKNOWN, error.phase)
        WorkTaskWriteCoordinator(store).recover(intent, { true }) { WorkTaskRecoveryProof.verify(it, row(it)) }
        assertTrue(store.loadIntent("author", "vineyard", "original-task")!!.acknowledged)
    }
    @Test fun `hidden row leaves original ambiguous request intact`() = runTest {
        store.saveIntent(intent)
        val bytes = disk.getValue(intent.persistenceKey)
        val error = failure { WorkTaskWriteCoordinator(store).recover(intent, { true }) {
            throw TaskWriteFailure(TaskWriteStage.SERVER_REVIEW, TaskWritePhase.UNKNOWN, code = "ABSENCE_OR_ACCESS_UNVERIFIED")
        } }
        assertEquals("ABSENCE_OR_ACCESS_UNVERIFIED", error.code); assertEquals(bytes, disk[intent.persistenceKey])
        assertFalse(store.loadIntent("author", "vineyard", "original-task")!!.acknowledged)
    }
    @Test fun `genuine different server version is not acknowledged or overwritten`() = runTest {
        store.saveIntent(intent)
        val conflict = JsonObject(row() + ("sync_version" to JsonPrimitive(2)))
        val error = failure { WorkTaskWriteCoordinator(store).recover(intent, { true }) {
            try { WorkTaskRecoveryProof.verify(it, conflict) } catch (cause: Exception) { throw TaskWriteFailure(TaskWriteStage.SERVER_REVIEW, TaskWritePhase.UNKNOWN, code = "VERSION_CONFLICT", cause = cause) }
        } }
        assertEquals("VERSION_CONFLICT", error.code); assertFalse(store.loadIntent("author", "vineyard", "original-task")!!.acknowledged)
    }
    @Test fun `intent persistence failure sends nothing`() = runTest {
        failKey = intent.persistenceKey
        var calls = 0
        val error = failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, _, _ -> calls++; saved } }
        assertEquals(0, calls); assertEquals(TaskWriteStage.INTENT_PERSISTENCE, error.stage)
    }
    @Test fun `dispatch lifecycle persistence failure never sends and cannot erase original`() = runTest {
        var writes = 0
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ ->
            failKey = "${intent.persistenceKey}-lifecycle"; dispatch(); writes++; saved
        } }
        assertEquals(0, writes); assertEquals(intent, store.loadIntent("author", "vineyard", "original-task"))
    }
    @Test fun `acknowledgement disk failure reports confirmed header and recovery does not resend`() = runTest {
        val error = failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ ->
            dispatch(); failKey = intent.persistenceKey; saved
        } }
        assertEquals(TaskWritePhase.CONFIRMED, error.phase); assertEquals(saved, error.savedTask)
        assertFalse(store.loadIntent("author", "vineyard", "original-task")!!.acknowledged)
        failKey = null
        WorkTaskWriteCoordinator(store).recover(intent, { true }) { WorkTaskRecoveryProof.verify(it, row(it)) }
        assertTrue(store.loadIntent("author", "vineyard", "original-task")!!.acknowledged)
    }
    @Test fun `repeated taps across coordinators cannot overlap dispatch or recovery`() = runTest {
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val first = async { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ -> dispatch(); entered.complete(Unit); release.await(); saved } }
        entered.await()
        val error = failure { WorkTaskWriteCoordinator(store).recover(intent, { true }) { fail("Concurrent read cannot race acknowledgement"); saved } }
        assertEquals("REQUEST_IN_PROGRESS", error.code)
        release.complete(Unit); first.await()
    }
    @Test fun `restart preserves dispatch marker and original named draft`() = runTest {
        store.save(draft)
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ -> dispatch(); error("Process ended") } }
        val restarted = store
        assertEquals(TaskWritePhase.DISPATCHED, restarted.recovery(intent)!!.phase)
        assertEquals("Need bamboo and loose tie onto it", restarted.load("author", "vineyard", null)!!.notes)
        assertEquals("Greg Horner", restarted.load("author", "vineyard", null)!!.assignmentName)
        assertEquals("2026-11-05", restarted.load("author", "vineyard", null)!!.date)
    }
    @Test fun `recovery account change does not acknowledge`() = runTest {
        store.saveIntent(intent)
        var current = true
        failure { WorkTaskWriteCoordinator(store).recover(intent, { current }) { current = false; saved } }
        assertFalse(store.loadIntent("author", "vineyard", "original-task")!!.acknowledged)
    }
    @Test fun `recovery verifies all written fields including assignment duration and notes`() {
        listOf("assigned_to", "duration_hours", "notes", "date", "client_updated_at").forEach { key ->
            assertThrows(IllegalStateException::class.java) { WorkTaskRecoveryProof.verify(intent, JsonObject(row() + (key to JsonPrimitive("different")))) }
        }
    }
    @Test fun `wrong vineyard wrong task or tombstone cannot confirm parent`() {
        listOf("id", "vineyard_id", "deleted_at").forEach { key ->
            assertThrows(IllegalStateException::class.java) { WorkTaskRecoveryProof.verify(intent, JsonObject(row() + (key to JsonPrimitive("other")))) }
        }
    }
    @Test fun `unchanged preserved completion costing links survive update verification`() {
        val baseline = buildJsonObject {
            WorkTaskPlanningRepository.observedKeys.forEach { put(it, JsonNull) }
            put("id", "original-task"); put("vineyard_id", "vineyard"); put("sync_version", 5); put("vintage_year", 2027)
            put("is_finalized", true); put("completed_by", "original-person"); put("costing_method", "piece_rate"); put("piece_rate_per_vine", 2.5); put("pruning_activity_id", "original-link")
        }
        val patch = buildJsonObject { put("sync_version", 6); put("notes", "changed note") }
        val changed = JsonObject(baseline + patch)
        WorkTaskWriteContract.verify(baseline, patch, changed, WorkTaskPlanningRepository.observedKeys)
        assertThrows(IllegalStateException::class.java) { WorkTaskWriteContract.verify(baseline, patch, JsonObject(changed + ("completed_by" to JsonPrimitive("different"))), WorkTaskPlanningRepository.observedKeys) }
        assertFalse("resources" in patch); assertFalse("trips" in patch)
    }
    @Test fun `old 318 record decodes unchanged and no revision is fabricated`() {
        val old = Json { ignoreUnknownKeys = true }.decodeFromString<WorkTask>("""{"id":"old","vineyard_id":"vineyard","notes":"Historical","duration_hours":1} """)
        assertNull(old.syncVersion); assertEquals("Historical", old.notes)
        assertThrows(IllegalStateException::class.java) { WorkTaskRecoveryProof.verify(intent, JsonObject(row() - "sync_version")) }
    }
    @Test fun `stale retry tap after acknowledgement cannot write the header twice`() = runTest {
        var writes = 0
        WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ -> dispatch(); writes++; saved }
        val error = failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }, true) { _, _, _ -> writes++; saved } }
        assertEquals(1, writes); assertEquals("ALREADY_ACKNOWLEDGED", error.code)
    }
    @Test fun `different request cannot replace original lifecycle or draft`() = runTest {
        store.save(draft)
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ -> dispatch(); error("Lost response") } }
        val bytes = disk.toMap()
        failure { WorkTaskWriteCoordinator(store).submitTracked(intent.copy(payload = JsonObject(intent.payload + ("notes" to JsonPrimitive("overwrite")))), { true }, true) { _, _, _ -> fail("Must not send"); saved } }
        assertEquals(bytes, disk)
    }
    @Test fun `failed draft cleanup preserves original and archived identity after header success`() = runTest {
        store.save(draft)
        WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ -> dispatch(); saved }
        assertThrows(IllegalStateException::class.java) { store.archiveCreatedDraft(draft, saved.id) }
        assertEquals(draft, store.load("author", "vineyard", null))
        assertEquals(draft.copy(taskId = saved.id), store.load("author", "vineyard", saved.id))
        assertTrue(store.loadIntent("author", "vineyard", saved.id)!!.acknowledged)
    }
    @Test fun `new successful edit archives previous intent instead of destroying evidence`() = runTest {
        WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { _, dispatch, _ -> dispatch(); saved }
        val original = store.loadIntent("author", "vineyard", saved.id)!!
        val next = intent.copy(payload = JsonObject(intent.payload + ("notes" to JsonPrimitive("deliberate next edit"))))
        WorkTaskWriteCoordinator(store).submitTracked(next, { true }) { _, dispatch, _ -> dispatch(); saved }
        val archived = disk.filterKeys { it.contains("-history-") && !it.endsWith("-lifecycle") }.values.single()
        assertEquals(original, Json.decodeFromString<WorkTaskWriteIntent>(archived))
    }
    @Test fun `diagnostic retains underlying error instead of generic wrapper`() {
        val error = TaskWriteFailure(TaskWriteStage.ASSIGNMENT, TaskWritePhase.UNSENT, 403, "42501", IllegalStateException("Assignee access rejected"))
        assertTrue(error.diagnostic().contains("Assignee access rejected")); assertTrue(error.diagnostic().contains("http=403"))
    }
    @Test fun `HTTP diagnostic includes response body hidden by generic backend exception message`() {
        val error = TaskWriteFailure(TaskWriteStage.SESSION, TaskWritePhase.UNSENT, 401, "PGRST301", BackendError.Server(401, "{\"code\":\"PGRST301\",\"message\":\"JWT expired\"}"))
        assertTrue(error.diagnostic().contains("JWT expired"))
    }
    @Test fun `cleanup failure message never claims the task save failed`() {
        val error = TaskWriteFailure(TaskWriteStage.CLEANUP, TaskWritePhase.CONFIRMED, cause = IllegalStateException("Disk full"), savedTask = saved)
        assertTrue(error.userMessage.startsWith("Task saved online")); assertEquals(TaskWriteStage.CLEANUP, error.stage)
    }
}
