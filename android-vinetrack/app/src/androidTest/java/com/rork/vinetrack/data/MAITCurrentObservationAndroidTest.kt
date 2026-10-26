package com.rork.vinetrack.data

import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.CleanExitFixtureApplication
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test

/** Real production repository and JWT/body handling; synthetic HTTP and disposable app only. */
class MAITCurrentObservationAndroidTest {
    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val owner = "44444444-4444-4444-8444-444444444444"
    private val row = """[{"source":"mait_intelliweb","station_name":"North station","observed_at":"2026-10-26T01:00:00Z","temperature_c":21,"rain_today_mm":4,"status":"ok","is_stale":true}]"""

    @Test fun memberRefreshUsesJWTExactBodyAndNormalizedReread() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-member-jwt", "synthetic-refresh", owner, null)
            // Read-only status must not suppress permitted weather reads/refreshes.
            requireNotNull(OperationalWrites.authority).handleServerCode("VT_READ_ONLY", vineyard)
            val paths = mutableListOf<String>()
            var reads = 0
            val client = HttpClient(MockEngine { request ->
                val path = request.url.encodedPath
                paths += path
                assertEquals("Bearer synthetic-member-jwt", request.headers["Authorization"])
                assertEquals(owner, request.attributes[SupabaseClient.accountRequestScope].userId)
                assertEquals(SupabaseClient.rpcUrl("get_vineyard_current_weather").substringBefore("/rest/"), "${request.url.protocol.name}://${request.url.host}")
                val body = SupabaseClient.json.parseToJsonElement((request.body as TextContent).text).jsonObject
                val response = when {
                    path.endsWith("get_vineyard_current_observation_provider") -> { assertEquals(vineyard, body["p_vineyard_id"]?.jsonPrimitive?.content); "\"mait_intelliweb\"" }
                    path.endsWith("get_vineyard_current_weather") -> { reads++; if (reads == 1) row else row.replace("21", "23").replace("01:00:00Z", "02:00:00Z") }
                    else -> {
                        assertEquals("/functions/v1/mait-intelliweb-proxy", path)
                        assertEquals(setOf("vineyardId", "action"), body.keys)
                        assertEquals(vineyard, body["vineyardId"]?.jsonPrimitive?.content)
                        assertEquals("current", body["action"]?.jsonPrimitive?.content)
                        "{}"
                    }
                }
                respond(response, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                val repo = CurrentObservationRepository(session)
                assertEquals("ok", repo.refresh(vineyard, force = true))
                assertEquals(listOf("/rest/v1/rpc/get_vineyard_current_observation_provider", "/rest/v1/rpc/get_vineyard_current_weather", "/functions/v1/mait-intelliweb-proxy", "/rest/v1/rpc/get_vineyard_current_weather"), paths)
                assertEquals(23.0, repo.current(vineyard)?.temperatureC)
                assertFalse(requireNotNull(OperationalWrites.authority).canWrite(vineyard))
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun noNewerReadingAndMissingPriorRowHaveNoFallback() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-jwt", "synthetic-refresh", owner, null)
            var empty = false
            var sends = 0
            var reads = 0
            val client = HttpClient(MockEngine { request ->
                val payload = when {
                    request.url.encodedPath.endsWith("get_vineyard_current_observation_provider") -> "\"mait_intelliweb\""
                    request.url.encodedPath.endsWith("get_vineyard_current_weather") -> { reads++; if (empty) "[]" else row }
                    else -> { assertEquals("/functions/v1/mait-intelliweb-proxy", request.url.encodedPath); sends++; "{}" }
                }
                respond(payload, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                val repo = CurrentObservationRepository(session)
                assertEquals("no_newer", repo.refresh(vineyard, true))
                assertEquals(2, reads)
                empty = true
                assertEquals("ok", repo.refresh(vineyard, true))
                assertEquals(4, reads)
                assertEquals(2, sends)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun failedMAITNeverSendsAnotherProviderAndKeepsLastKnown() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-jwt", "synthetic-refresh", owner, null)
            val functions = mutableListOf<String>()
            var status = HttpStatusCode.BadGateway
            val client = HttpClient(MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("get_vineyard_current_observation_provider") -> respond("\"mait_intelliweb\"", HttpStatusCode.OK)
                    path.endsWith("get_vineyard_current_weather") -> respond(row, HttpStatusCode.OK)
                    else -> { functions += path; respond("upstream-private-diagnostic", status) }
                }
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                val repo = CurrentObservationRepository(session)
                val previous = repo.current(vineyard)
                for (code in listOf(HttpStatusCode.BadGateway, HttpStatusCode.Forbidden, HttpStatusCode.Unauthorized)) {
                    status = code
                    try { repo.refresh(vineyard, true); fail("Expected refresh failure") }
                    catch (e: BackendError) { assertFalse(e.message.orEmpty().contains("upstream-private-diagnostic")) }
                }
                assertEquals(List(3) { "/functions/v1/mait-intelliweb-proxy" }, functions)
                val retained = CurrentObservationRepository.retainingLastKnown(null, previous)
                assertEquals(previous, retained)
                assertEquals(21.0, retained?.temperatureC)
                assertEquals("2026-10-26T01:00:00Z", retained?.observedAt)
                assertEquals("Live observations not refreshed — MAIT iNTELLiWeb", retained?.refreshFailureMessage)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun onlyMissingSelectionRPCMayUseLegacyWUAndAuthFailureCannot() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-jwt", "synthetic-refresh", owner, null)
            var missingRPC = true
            var sends = 0
            var reads = 0
            val client = HttpClient(MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("get_vineyard_current_observation_provider") -> respond(if (missingRPC) """{"code":"PGRST202"}""" else """{"code":"42501"}""", if (missingRPC) HttpStatusCode.NotFound else HttpStatusCode.Forbidden)
                    path.endsWith("get_vineyard_current_weather") -> { reads++; respond(row.replace("mait_intelliweb", "wunderground_pws"), HttpStatusCode.OK) }
                    else -> { sends++; assertEquals("/functions/v1/wunderground-proxy", path); respond("{}", HttpStatusCode.OK) }
                }
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                val repo = CurrentObservationRepository(session)
                assertEquals("ok", repo.refresh(vineyard, true))
                assertEquals(1, sends)
                assertEquals(2, reads)
                missingRPC = false
                try { repo.refresh(vineyard, true); fail("Permission failure became legacy automatic selection") }
                catch (_: BackendError) { }
                assertEquals(1, sends)
                assertEquals(2, reads)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }

    @Test fun accountChangeDuringSelectionPreventsCurrentAndProxyCalls() = runBlocking {
        withTimeout(15_000) {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CleanExitFixtureApplication
            app.resetFixture()
            val session = SessionStore(app)
            session.save("synthetic-jwt", "synthetic-refresh", owner, null)
            var requests = 0
            val client = HttpClient(MockEngine { request ->
                requests++
                assertTrue(request.url.encodedPath.endsWith("get_vineyard_current_observation_provider"))
                session.userId = "55555555-5555-4555-8555-555555555555"
                respond("\"mait_intelliweb\"", HttpStatusCode.OK)
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            SupabaseClient.installInstrumentationTransport(client)
            try {
                try { CurrentObservationRepository(session).refresh(vineyard, true); fail("Stale account accepted") }
                catch (_: BackendError.Unauthorized) { }
                assertEquals(1, requests)
            } finally { SupabaseClient.installInstrumentationTransport(null); client.close() }
        }
    }
}
