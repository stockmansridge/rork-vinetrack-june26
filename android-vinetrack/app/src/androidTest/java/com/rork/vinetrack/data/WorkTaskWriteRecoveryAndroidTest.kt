package com.rork.vinetrack.data

import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.CleanExitFixtureApplication
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.WorkTaskPlanningDraft
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

/** Real repository/session/preferences; synthetic HTTP only. Not customer-device or shared-refresh certification. */
class WorkTaskWriteRecoveryAndroidTest {
    private val owner = "44444444-4444-4444-8444-444444444444"
    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val task = "22222222-2222-4222-8222-222222222222"
    private val greg = "33333333-3333-4333-8333-333333333333"
    private val draft get() = WorkTaskPlanningDraft(null, vineyard, owner, assignedTo = greg, assignmentName = "Greg Horner", date = "2026-11-05", taskType = "Vine work", durationText = "1", notes = "Need bamboo and loose tie onto it", creationId = task)
    private val intent get() = WorkTaskWriteContract.planning(draft, task, LocalDate.parse("2026-11-05"), Instant.parse("2026-10-30T05:00:00Z"), null, "", 0.0)
    private val row get() = JsonObject(intent.payload + ("vintage_year" to JsonPrimitive(2027)))

    private suspend fun fixture(block: suspend (SessionStore, WorkTaskPlanningDraftStore) -> Unit) {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
        app.resetFixture()
        val session = SessionStore(app)
        session.save("synthetic-task-jwt", "synthetic-refresh", owner, null)
        session.selectedVineyardId = vineyard
        try { block(session, WorkTaskPlanningDraftStore(app)) }
        finally { SupabaseClient.installInstrumentationTransport(null); app.resetFixture() }
    }
    private suspend fun failure(block: suspend () -> Unit): TaskWriteFailure {
        try { block(); fail("Expected protected failure") } catch (error: TaskWriteFailure) { return error }
        error("unreachable")
    }
    private fun scope(request: io.ktor.client.request.HttpRequestData) {
        assertEquals("Bearer synthetic-task-jwt", request.headers[HttpHeaders.Authorization])
        assertEquals(owner, request.attributes[SupabaseClient.accountRequestScope].userId)
        if (request.method == HttpMethod.Get) assertEquals("eq.$vineyard", request.url.parameters["vineyard_id"])
        else {
            val body = Json.parseToJsonElement((request.body as io.ktor.http.content.TextContent).text).jsonObject
            assertEquals(vineyard, body["vineyard_id"]?.jsonPrimitive?.content)
            assertEquals(task, body["id"]?.jsonPrimitive?.content)
        }
    }

    @Test fun membership403IsUnsentAndDeliberateRetryUsesOriginalTask() = runBlocking { fixture { session, store ->
        store.save(draft)
        var rejected = true; var writes = 0
        val client = HttpClient(MockEngine { request ->
            scope(request)
            if (request.url.encodedPath.endsWith("vineyard_members")) {
                if (rejected) respond("""{"code":"42501","message":"membership rejected"}""", HttpStatusCode.Forbidden, headersOf("Content-Type", "application/json"))
                else respond(if (request.url.parameters["select"] == "role") """[{"role":"operator"}]""" else """[{"user_id":"$greg"}]""", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            } else {
                // Simulated final send boundary; production performs this after its session refresh.
                request.attributes[SupabaseClient.taskWriteDispatch].invoke(); writes++
                respond("[$row]", HttpStatusCode.Created, headersOf("Content-Type", "application/json"))
            }
        })
        SupabaseClient.installInstrumentationTransport(client)
        try {
            val error = failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { original, dispatch, progress -> WorkTaskPlanningRepository(session).write(original, dispatch, progress) } }
            assertEquals(TaskWritePhase.UNSENT, error.phase); assertEquals(403, error.status); assertEquals("42501", error.code)
            assertEquals(0, writes)
            rejected = false
            val original = store.loadIntent(owner, vineyard, task)!!
            val saved = WorkTaskWriteCoordinator(store).submitTracked(original, { true }, true) { retained, dispatch, progress -> WorkTaskPlanningRepository(session).write(retained, dispatch, progress) }
            assertEquals(task, saved.id); assertEquals(1, writes)
            assertEquals(draft, WorkTaskPlanningDraftStore(InstrumentationRegistry.getInstrumentation().targetContext).load(owner, vineyard, null))
        } finally { client.close() }
    } }

    @Test fun positiveOriginalRowRecoversLostAcknowledgementUsingReadOnlyRequest() = runBlocking { fixture { session, store ->
        store.saveIntent(intent)
        var reads = 0
        val client = HttpClient(MockEngine { request ->
            scope(request); assertEquals(HttpMethod.Get, request.method); assertEquals("eq.$task", request.url.parameters["id"])
            reads++; respond("[$row]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
        })
        SupabaseClient.installInstrumentationTransport(client)
        try {
            val saved = WorkTaskWriteCoordinator(store).recover(intent, { true }) { WorkTaskPlanningRepository(session).recover(it) }
            assertEquals(task, saved.id); assertEquals("Need bamboo and loose tie onto it", saved.notes)
            assertEquals(1, reads); assertTrue(store.loadIntent(owner, vineyard, task)!!.acknowledged)
        } finally { client.close() }
    } }

    @Test fun emptyScopedReadCannotAcknowledgeOrAllowDuplicateCreate() = runBlocking { fixture { session, store ->
        store.saveIntent(intent)
        val client = HttpClient(MockEngine { request -> scope(request); assertEquals(HttpMethod.Get, request.method); respond("[]", HttpStatusCode.OK, headersOf("Content-Type", "application/json")) })
        SupabaseClient.installInstrumentationTransport(client)
        try {
            val error = failure { WorkTaskWriteCoordinator(store).recover(intent, { true }) { WorkTaskPlanningRepository(session).recover(it) } }
            assertEquals("ABSENCE_OR_ACCESS_UNVERIFIED", error.code); assertFalse(store.loadIntent(owner, vineyard, task)!!.acknowledged)
            failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }, true) { _, _, _ -> fail("Never create again"); WorkTaskRecoveryProof.verify(intent, row) } }
        } finally { client.close() }
    } }

    @Test fun differentServerRevisionIsHeldWithoutPatch() = runBlocking { fixture { session, store ->
        store.saveIntent(intent)
        val different = JsonObject(row + ("sync_version" to JsonPrimitive(2)))
        val client = HttpClient(MockEngine { request -> assertEquals(HttpMethod.Get, request.method); respond("[$different]", HttpStatusCode.OK, headersOf("Content-Type", "application/json")) })
        SupabaseClient.installInstrumentationTransport(client)
        try {
            val error = failure { WorkTaskWriteCoordinator(store).recover(intent, { true }) { WorkTaskPlanningRepository(session).recover(it) } }
            assertEquals("VERSION_CONFLICT", error.code); assertFalse(store.loadIntent(owner, vineyard, task)!!.acknowledged)
        } finally { client.close() }
    } }

    @Test fun authentication401RetainsOriginalStatusAndCode() = runBlocking { fixture { session, store ->
        val client = HttpClient(MockEngine { respond("""{"code":"PGRST301","message":"JWT expired"}""", HttpStatusCode.Unauthorized, headersOf("Content-Type", "application/json")) })
        SupabaseClient.installInstrumentationTransport(client)
        try {
            val error = failure { WorkTaskWriteCoordinator(store).submitTracked(intent, { true }) { original, dispatch, progress -> WorkTaskPlanningRepository(session).write(original, dispatch, progress) } }
            assertEquals(TaskWriteStage.SESSION, error.stage); assertEquals(TaskWritePhase.UNSENT, error.phase)
            assertEquals(401, error.status); assertEquals("PGRST301", error.code)
            assertTrue(store.recovery(intent)!!.detail!!.contains("JWT expired"))
        } finally { client.close() }
    } }

    @Test fun selectedVineyardChangeDuringReadCannotAcknowledge() = runBlocking { fixture { session, store ->
        store.saveIntent(intent)
        val client = HttpClient(MockEngine { session.selectedVineyardId = "other"; respond("[$row]", HttpStatusCode.OK, headersOf("Content-Type", "application/json")) })
        SupabaseClient.installInstrumentationTransport(client)
        try {
            failure { WorkTaskWriteCoordinator(store).recover(intent, { true }) { WorkTaskPlanningRepository(session).recover(it) } }
            assertFalse(store.loadIntent(owner, vineyard, task)!!.acknowledged)
        } finally { client.close() }
    } }
}
