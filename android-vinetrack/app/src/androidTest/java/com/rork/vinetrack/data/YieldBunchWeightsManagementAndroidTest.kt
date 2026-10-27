package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.*
import io.ktor.http.content.OutgoingContent
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*
import java.util.UUID

class YieldBunchWeightsManagementAndroidTest {
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefix = "yield_management_test_${UUID.randomUUID()}_"
    private val names = mutableSetOf<String>()
    private val root = java.io.File(base.cacheDir, prefix)
    private val originalAuthority = OperationalWrites.authority
    private val context = object : ContextWrapper(base) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir() = java.io.File(root, "files").apply { mkdirs() }
        override fun getCacheDir() = java.io.File(root, "cache").apply { mkdirs() }
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names.add(name); return base.getSharedPreferences(prefix + name, mode)
        }
    }
    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val block = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val actor = "22222222-2222-4222-8222-222222222222"
    private var client: HttpClient? = null
    private fun repository() = YieldBunchWeightsRepository(context).also { it.session.save("synthetic-access", "synthetic-refresh", actor, null) }
    private fun row(blockId: String? = null, grams: Double = 120.0, vineyardId: String = vineyard, key: String = "shiraz") =
        YieldBunchWeightRow(UUID.randomUUID().toString(), vineyardId, blockId, key, "Renamed Shiraz", grams)
    private fun install(handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData) {
        client?.close()
        client = HttpClient(MockEngine(handler)) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        SupabaseClient.installInstrumentationTransport(client)
    }
    private fun headers(count: Int) = headersOf(HttpHeaders.ContentType to listOf("application/json"), "Content-Range" to listOf("0-199/$count"))
    @After fun cleanup() {
        SupabaseClient.installInstrumentationTransport(null); client?.close()
        OperationalWrites.authority = originalAuthority
        names.forEach { base.deleteSharedPreferences(prefix + it) }; root.deleteRecursively()
    }
    @Test fun overrideRemovalRestoresMasterAndNeverUsesOtherScopes() {
        val master = row()
        val blockOverride = row(block, 180.0)
        assertEquals(blockOverride.id, YieldBunchWeightRow.resolved(listOf(master, blockOverride), vineyard, block, "shiraz").recordId)
        assertEquals(0.12, YieldBunchWeightRow.resolved(listOf(master), vineyard, block, "shiraz").kg!!, 0.0)
        assertNull(YieldBunchWeightRow.resolved(emptyList(), vineyard, block, "shiraz").kg)
        assertNull(YieldBunchWeightRow.resolved(listOf(row(vineyardId = UUID.randomUUID().toString()), row(key = "merlot")), vineyard, block, "shiraz").kg)
        listOf(0.0, -1.0, 5000.1, Double.POSITIVE_INFINITY, Double.NaN).forEach { assertFalse(row(grams = it).isValid) }
    }
    @Test fun completePagingAndFailedReadRetainLastConfirmedList() = runBlocking {
        val repo = repository(); val first = row(); val second = row(block); val offsets = mutableListOf<String?>()
        install { request ->
            assertEquals("count=exact", request.headers["Prefer"])
            offsets.add(request.url.parameters["offset"])
            val page = if (request.url.parameters["offset"] == "0") listOf(first) else listOf(second)
            respond(SupabaseClient.json.encodeToString(page), HttpStatusCode.OK, headers(2))
        }
        val confirmed = repo.fetch(vineyard)
        assertEquals(listOf("0", "1"), offsets); assertEquals(2, confirmed.size)
        install { respond("offline", HttpStatusCode.ServiceUnavailable) }
        assertTrue(runCatching { repo.fetch(vineyard) }.isFailure)
        assertEquals(confirmed, repo.cached(vineyard))
        assertNull(repo.cached(UUID.randomUUID().toString()))
    }
    @Test fun missingCountDuplicatePageAndWrongVineyardCannotConfirmAbsence() = runBlocking {
        val repo = repository(); val item = row()
        install { respond("[]", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }
        assertTrue(runCatching { repo.fetch(vineyard) }.isFailure); assertNull(repo.cached(vineyard))
        install { respond(SupabaseClient.json.encodeToString(listOf(item)), HttpStatusCode.OK, headers(2)) }
        assertTrue(runCatching { repo.fetch(vineyard) }.isFailure); assertNull(repo.cached(vineyard))
        install { respond(SupabaseClient.json.encodeToString(listOf(row(vineyardId = UUID.randomUUID().toString()))), HttpStatusCode.OK, headers(1)) }
        assertTrue(runCatching { repo.fetch(vineyard) }.isFailure); assertNull(repo.cached(vineyard))
    }
    @Test fun saveUsesExactRPCBodyAndNeverSpeculatesConfirmedCache() = runBlocking {
        val repo = repository(); var requests = 0
        install { request ->
            requests++
            assertTrue(request.url.encodedPath.endsWith("/rpc/upsert_yield_bunch_weight"))
            assertEquals(vineyard, request.attributes[SupabaseClient.operationalWriteVineyard])
            val body = SupabaseClient.json.parseToJsonElement(String((request.body as OutgoingContent.ByteArrayContent).bytes())).jsonObject
            assertEquals(JsonNull, body["p_paddock_id"])
            assertEquals("shiraz", body["p_variety_key"]?.jsonPrimitive?.content)
            assertEquals(123.456, body["p_bunch_weight_grams"]!!.jsonPrimitive.double, 0.0)
            respond("{}", HttpStatusCode.OK, headers(0))
        }
        repo.save(vineyard, null, "shiraz", "Renamed Shiraz", 123.456)
        assertEquals(1, requests); assertNull(repo.cached(vineyard))
        listOf(0.0, -1.0, 5000.1, Double.NaN).forEach {
            assertTrue(runCatching { repo.save(vineyard, null, "shiraz", "Shiraz", it) }.isFailure)
        }
        assertEquals(1, requests)
    }
    @Test fun heldSaveAndWrongOwningVineyardDeleteNeverSendMutation() = runBlocking {
        val repo = repository(); val target = row(block); var mutations = 0
        install { request ->
            if (request.method == HttpMethod.Post) mutations++
            respond(SupabaseClient.json.encodeToString(listOf(target.copy(vineyardId = UUID.randomUUID().toString()))), HttpStatusCode.OK, headers(1))
        }
        assertTrue(runCatching { repo.remove(target) }.isFailure)
        OperationalWrites.authority!!.handleServerCode("VT_READ_ONLY", vineyard)
        assertTrue(runCatching { repo.save(vineyard, null, "shiraz", "Shiraz", 120.0) }.isFailure)
        assertEquals(0, mutations)
    }
    @Test fun expiryDuringOwnershipReadStopsDelete() = runBlocking {
        val repo = repository(); val target = row(); var mutations = 0
        install { request ->
            if (request.method == HttpMethod.Post) mutations++
            OperationalWrites.authority!!.handleServerCode("VT_READ_ONLY", vineyard)
            respond(SupabaseClient.json.encodeToString(listOf(target)), HttpStatusCode.OK, headers(1))
        }
        assertTrue(runCatching { repo.remove(target) }.isFailure)
        assertEquals(0, mutations)
    }
    @Test fun sameAccountNewIncarnationCannotPublishReadOrSendDelete() = runBlocking {
        val repo = repository(); val target = row(); var mutations = 0
        install { request ->
            if (request.method == HttpMethod.Post) mutations++
            repo.session.clear(); repo.session.save("new", "new", actor, null)
            respond(SupabaseClient.json.encodeToString(listOf(target)), HttpStatusCode.OK, headers(1))
        }
        assertTrue(runCatching { repo.fetch(vineyard) }.isFailure); assertNull(repo.cached(vineyard))
        assertTrue(runCatching { repo.remove(target) }.isFailure); assertEquals(0, mutations)
    }
    @Test fun ordinaryPermissionFailureDoesNotHoldButStructuredReadOnlyDoes() = runBlocking {
        val repo = repository()
        for (code in listOf("42501", "VT_READ_ONLY")) {
            install { respond("""{"code":"$code","message":"Denied"}""", HttpStatusCode.Forbidden, headers(0)) }
            assertTrue(runCatching { repo.save(vineyard, null, "shiraz", "Shiraz", 120.0) }.isFailure)
            assertEquals(code == "42501", OperationalWrites.canWrite(vineyard))
            assertNull(repo.cached(vineyard))
        }
    }
}
