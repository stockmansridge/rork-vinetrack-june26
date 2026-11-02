package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.HttpClient
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.forms.*
import io.ktor.http.*
import io.ktor.http.content.TextContent
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*
import java.util.UUID
import java.io.File
import android.content.pm.ApplicationInfo

/** Production repository through synthetic-only HTTP. No production mutation or live fallback. */
class Issue49ChemicalReadbackAndroidTest {
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefix = "issue49_readback_${UUID.randomUUID()}_"
    private val names = linkedSetOf<String>()
    private val root = File(base.cacheDir, prefix)
    private val owner = "49000000-0000-4000-8000-000000000001"
    private val vineyard = "49000000-0000-4000-8000-000000000002"
    private val chemical = "49000000-0000-4000-8000-000000000003"
    private lateinit var session: SessionStore
    private var client: HttpClient? = null
    private var priorAuthority: VineyardWriteAuthority? = null
    @Before fun setup() {
        val context = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
            override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
            override fun getApplicationInfo(): ApplicationInfo = ApplicationInfo(base.applicationInfo).apply { dataDir = root.path }
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                names.add(name); return base.getSharedPreferences(prefix + name, mode)
            }
        }
        priorAuthority = OperationalWrites.authority; OperationalWrites.authority = null
        session = SessionStore(context)
        session.save("synthetic-access", "synthetic-refresh", owner, null)
        session.selectedVineyardId = vineyard
    }
    @After fun cleanup() {
        SupabaseClient.installInstrumentationTransport(null); client?.close()
        OperationalWrites.authority = priorAuthority
        names.forEach { base.deleteSharedPreferences(prefix + it) }
        check(root.canonicalPath.startsWith(base.cacheDir.canonicalPath + File.separator))
        root.deleteRecursively()
    }
    private fun mock(handler: suspend (io.ktor.client.request.HttpRequestData) -> String) {
        client = HttpClient(MockEngine { request ->
            respond(handler(request), HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
        }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
        SupabaseClient.installInstrumentationTransport(client)
    }
    @Test fun emptyReadRequiresFreshAuthorisedMembershipBeforeDeletionProof() = runBlocking {
        val routes = mutableListOf<String>()
        mock { request ->
            assertEquals(HttpMethod.Get, request.method)
            assertEquals("eq.$vineyard", request.url.parameters["vineyard_id"])
            routes.add(request.url.encodedPath)
            when {
                request.url.encodedPath.endsWith("/saved_chemicals") -> {
                    assertEquals("eq.$chemical", request.url.parameters["id"])
                    assertNull(request.url.parameters["deleted_at"]); "[]"
                }
                request.url.encodedPath.endsWith("/vineyard_members") -> {
                    assertEquals("eq.$owner", request.url.parameters["user_id"])
                    """[{"user_id":"$owner","vineyard_id":"$vineyard","role":"manager"}]"""
                }
                else -> error("No live fallback")
            }
        }
        assertNull(SavedChemicalRepository(session).findByIdScoped(chemical, vineyard, session.accountAccess()!!))
        assertEquals(listOf("/rest/v1/saved_chemicals", "/rest/v1/vineyard_members"), routes)
    }
    @Test fun rlsFilteredEmptyMembershipNeverConfirmsDeletion() = runBlocking {
        mock { request -> assertEquals(HttpMethod.Get, request.method); "[]" }
        assertTrue(runCatching { SavedChemicalRepository(session).findByIdScoped(chemical, vineyard, session.accountAccess()!!) }.isFailure)
    }
    @Test fun accountRevocationDuringReadRejectsResult() = runBlocking {
        val access = session.accountAccess()!!
        var reads = 0
        var revokedAccount = false
        mock { request ->
            assertEquals(HttpMethod.Get, request.method)
            reads++
            session.clear() // Revoke only this disposable synthetic session during its response.
            revokedAccount = !session.isAccountAccessCurrent(access)
            "[]"
        }
        val result = runCatching { SavedChemicalRepository(session).findByIdScoped(chemical, vineyard, access) }
        assertTrue(result.isFailure)
        assertTrue("Synthetic account revocation must execute, not merely fail HTTP decoding", revokedAccount)
        assertEquals("No membership proof may follow a revoked chemical read", 1, reads)
    }
    @Test fun reactivatePatchesOnlyActivityAndTombstoneOnOriginalScopedId() = runBlocking {
        var patches = 0
        mock { request ->
            assertEquals(HttpMethod.Patch, request.method)
            assertEquals("eq.$chemical", request.url.parameters["id"])
            assertEquals("eq.$vineyard", request.url.parameters["vineyard_id"])
            val body = Json.parseToJsonElement((request.body as TextContent).text).jsonObject
            assertEquals(setOf("is_active", "deleted_at"), body.keys)
            assertEquals(JsonPrimitive(true), body["is_active"]); assertEquals(JsonNull, body["deleted_at"])
            patches++; ""
        }
        SavedChemicalRepository(session).restoreArchived(chemical, vineyard, session.accountAccess()!!)
        assertEquals(1, patches)
    }
}
