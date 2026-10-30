package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import java.util.UUID

class YieldMasterWeightCacheAndroidTest {
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefix = "yield_master_test_${UUID.randomUUID()}_"
    private val names = mutableSetOf<String>()
    private val root = java.io.File(base.cacheDir, prefix)
    private val context = object : ContextWrapper(base) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): java.io.File = java.io.File(root, "files").apply { mkdirs() }
        override fun getCacheDir(): java.io.File = java.io.File(root, "cache").apply { mkdirs() }
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences { names.add(name); return base.getSharedPreferences(prefix + name, mode) }
    }
    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val block = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val actor = "22222222-2222-4222-8222-222222222222"
    private val paddock = Paddock(block, vineyard, "Synthetic", varietyAllocations = listOf(PaddockVarietyAllocation(varietyKey = "shiraz", name = "Renamed", percent = 100.0)))
    private var client: HttpClient? = null
    private fun install(response: suspend () -> Pair<String, HttpStatusCode>) {
        client?.close()
        client = HttpClient(MockEngine { request ->
            if (request.url.encodedPath.endsWith("/vineyards")) {
                respond("""[{"id":"$vineyard"}]""", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            } else {
                assertTrue(request.url.encodedPath.endsWith("/yield_bunch_weights"))
                assertEquals("count=exact", request.headers["Prefer"])
                val (body, status) = response()
                val count = if (body.startsWith("[")) (SupabaseClient.json.parseToJsonElement(body) as kotlinx.serialization.json.JsonArray).size else 0
                respond(body, status, headersOf(HttpHeaders.ContentType to listOf("application/json"), "Content-Range" to listOf("0-199/$count")))
            }
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        SupabaseClient.installInstrumentationTransport(client)
    }
    private fun available(vineyardId: String = vineyard, grams: Int = 120) = """[{"id":"$block","vineyard_id":"$vineyardId","paddock_id":"$block","variety_key":"shiraz","variety_name":"Shiraz","bunch_weight_grams":$grams}]"""

    private fun repository(): YieldMasterWeightRepository = YieldMasterWeightRepository(context).also { it.session.save("synthetic-access", "synthetic-refresh", actor, null) }
    @After fun cleanup() { SupabaseClient.installInstrumentationTransport(null); client?.close(); names.forEach { base.deleteSharedPreferences(prefix + it) }; root.deleteRecursively() }
    @Test fun confirmedWeightSurvivesRecreatedCacheAndOfflineRead() = runBlocking {
        val repo = repository(); install { available() to HttpStatusCode.OK }; repo.refresh(vineyard, listOf(paddock))
        install { "offline" to HttpStatusCode.ServiceUnavailable }
        val recreated = YieldMasterWeightRepository(context); recreated.refresh(vineyard, listOf(paddock))
        assertEquals(0.12, recreated.cached(vineyard).values.single().kg!!, 0.0)
        assertNotNull(recreated.syncError(vineyard))
        install { available(grams = 130) to HttpStatusCode.OK }
        val before = recreated.changes.value
        recreated.refresh(vineyard, listOf(paddock))
        assertNull(recreated.syncError(vineyard))
        assertTrue(recreated.changes.value > before)
        assertEquals(0.13, recreated.cached(vineyard).values.single().kg!!, 0.0)
    }
    @Test fun confirmedAbsenceReplacesAvailableWeightOnDisk() = runBlocking {
        val repo = repository(); install { available() to HttpStatusCode.OK }; repo.refresh(vineyard, listOf(paddock))
        install { "[]" to HttpStatusCode.OK }
        repo.refresh(vineyard, listOf(paddock)); val cached = YieldMasterWeightRepository(context).cached(vineyard).values.single()
        assertEquals("not_configured", cached.source); assertNull(cached.kg)
    }
    @Test fun accountVineyardBlockAndVarietyScopesCannotLeak() = runBlocking {
        val repo = repository(); install { available() to HttpStatusCode.OK }; repo.refresh(vineyard, listOf(paddock))
        assertTrue(repo.cached(UUID.randomUUID().toString()).isEmpty())
        assertNull(repo.cached(vineyard)[CurrentYieldEstimate.key(UUID.randomUUID().toString(), "shiraz")])
        assertNull(repo.cached(vineyard)[CurrentYieldEstimate.key(block, "merlot")])
        // Direct account replacement is deliberately denied by production retention safety.
        assertThrows(IllegalStateException::class.java) {
            repo.session.save("b", "b", "33333333-3333-4333-8333-333333333333", null)
        }
        assertTrue(repo.cached(vineyard).isEmpty())
        // A separately admitted account shares the master cache disk, but not A's auth store.
        val otherContext = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                context.getSharedPreferences(if (name == "vinetrack_session") "session_b" else name, mode)
        }
        val other = YieldMasterWeightRepository(otherContext)
        other.session.save("b", "b", "33333333-3333-4333-8333-333333333333", null)
        assertTrue(other.cached(vineyard).isEmpty())
    }
    @Test fun sameAccountNewIncarnationCannotCommitOldResponse() = runBlocking {
        val repo = repository()
        install { repo.session.clear(); repo.session.save("new", "new", actor, null); available() to HttpStatusCode.OK }
        repo.refresh(vineyard, listOf(paddock)); assertTrue(repo.cached(vineyard).isEmpty())
    }
    @Test fun mismatchedOrMalformedResponseNeverEntersConfirmedCache() = runBlocking {
        val repo = repository(); install { available(vineyardId = UUID.randomUUID().toString()) to HttpStatusCode.OK }; repo.refresh(vineyard, listOf(paddock)); assertTrue(repo.cached(vineyard).isEmpty())
        install { available(grams = -1) to HttpStatusCode.OK }; repo.refresh(vineyard, listOf(paddock)); assertTrue(repo.cached(vineyard).isEmpty())
    }
    @Test fun completeReadRefreshUsesRemovedOverrideFallbackAndOriginalUnits() = runBlocking {
        val repo = repository()
        install { available(grams = 90) to HttpStatusCode.OK }
        repo.refresh(vineyard, listOf(paddock))
        assertEquals(0.09, repo.cached(vineyard).values.single().kg!!, 0.0)
        install { """[{"id":"$actor","vineyard_id":"$vineyard","paddock_id":null,"variety_key":"shiraz","variety_name":"Shiraz","bunch_weight_grams":140}]""" to HttpStatusCode.OK }
        repo.refresh(vineyard, listOf(paddock))
        val weight=repo.cached(vineyard).values.single()
        assertEquals("variety_default", weight.source)
        assertEquals(0.14, weight.kg!!, 0.0)
    }

}
