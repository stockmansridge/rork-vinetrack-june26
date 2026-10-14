package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.spray.SprayProgramStepDraft
import com.rork.vinetrack.data.spray.SprayProgramProductDraft
import com.rork.vinetrack.data.spray.SprayProgramLanding
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.http.content.TextContent
import io.ktor.http.encodedPath
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Actual repository POST/GET/PATCH over isolated synthetic transport; never live RLS acceptance. */
@RunWith(AndroidJUnit4::class)
class SprayProgramStepCreationAndroidTest {
    @Test fun normalProgramStepPostsOnlyToCanonicalJobsAndReadsSameUUID() = scenario("normal")
    @Test fun fertigationPostsCanonicalRatesAndImmediatelyMapsToIrrigationStep() = scenario("fertigation")
    @Test fun serverDeniedCreateKeepsDraftAndSameUUIDOnRetry() = scenario("denied")
    @Test fun wrongRowAcknowledgementIsNotSuccess() = scenario("wrongAck")
    @Test fun nonAdminFertigationDoesNotReachInsert() = scenario("notAdmin")
    @Test fun existingSharedEditStillPatchesSameRow() = scenario("edit")

    private fun scenario(kind: String) = runBlocking {
        withTimeout(30_000) {
            val base = InstrumentationRegistry.getInstrumentation().targetContext
            val prefix = "program_create_${UUID.randomUUID()}_"
            val names = linkedSetOf<String>()
            val context = object : ContextWrapper(base) {
                override fun getApplicationContext(): Context = this
                override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                    names.add(name)
                    return base.getSharedPreferences(prefix + name, mode)
                }
            }
            val owner = UUID.randomUUID().toString(); val vineyard = UUID.randomUUID().toString()
            val chemical = UUID.randomUUID().toString()
            val isFertigation = kind in listOf("fertigation", "notAdmin")
            val product = SprayProgramProductDraft(savedChemicalId = chemical, name = "Saved nutrient", rate = 10.0, fertigationRateBasis = if (isFertigation) "per_hectare" else null, fertigationRateUnit = if (isFertigation) "kg/ha" else null)
            val draft = SprayProgramStepDraft.newShared().copy(name = "Synthetic reusable", notes = "Keep unsaved notes", growthStageCode = "EL12", operationType = if (isFertigation) "Fertigation" else "Foliar Spray", products = listOf(product))
            val original = draft.copy()
            val payload = draft.createPayload(vineyard, owner)
            var stored: JsonObject? = if (kind == "edit") payload else null
            var attempts = 0
            var denied = kind == "denied"
            val client = HttpClient(MockEngine { request ->
                val path = request.url.encodedPath
                val contentHeaders = headersOf("Content-Type", "application/json")
                if (path.endsWith("/rpc/is_system_admin")) {
                    assertEquals(HttpMethod.Post, request.method)
                    respond(if (kind == "notAdmin") "false" else "true", HttpStatusCode.OK, contentHeaders)
                } else if (path.endsWith("/rest/v1/spray_jobs")) {
                    when (request.method) {
                        HttpMethod.Post -> {
                            attempts++
                            assertEquals("return=representation", request.headers["Prefer"])
                            val body = SupabaseClient.json.parseToJsonElement((request.body as TextContent).text).jsonObject
                            assertEquals(payload, body)
                            assertEquals(JsonPrimitive(draft.stepId), body["id"])
                            assertEquals(JsonPrimitive(true), body["is_template"])
                            if (isFertigation) {
                                SprayProgramStepDraft.SPRAY_ONLY_CREATE_KEYS.forEach { assertFalse(body.containsKey(it)) }
                                val line = body["chemical_lines"]!!.jsonArray.single().jsonObject
                                assertEquals(JsonPrimitive(chemical), line["chemical_id"])
                                assertEquals(JsonPrimitive("per_hectare"), line["fertigation_rate_basis"])
                                assertEquals(JsonPrimitive("kg/ha"), line["fertigation_rate_unit"])
                                assertFalse(line.containsKey("unit"))
                            }
                            if (denied) respond("{\"message\":\"Synthetic role denial\"}", HttpStatusCode.Forbidden, contentHeaders)
                            else {
                                stored = body
                                val responseRow = if (kind == "wrongAck") JsonObject(body + ("id" to JsonPrimitive(UUID.randomUUID().toString()))) else body
                                respond("[$responseRow]", HttpStatusCode.Created, contentHeaders)
                            }
                        }
                        HttpMethod.Get -> {
                            assertEquals("eq.$vineyard", request.url.parameters["vineyard_id"])
                            assertEquals("eq.true", request.url.parameters["is_template"])
                            respond(stored?.let { "[$it]" } ?: "[]", HttpStatusCode.OK, contentHeaders)
                        }
                        HttpMethod.Patch -> {
                            assertEquals("edit", kind)
                            assertEquals("eq.${draft.stepId}", request.url.parameters["id"])
                            assertEquals("eq.$vineyard", request.url.parameters["vineyard_id"])
                            assertEquals("eq.true", request.url.parameters["is_template"])
                            val patch = SupabaseClient.json.parseToJsonElement((request.body as TextContent).text).jsonObject
                            assertFalse(patch.containsKey("id")); assertFalse(patch.containsKey("is_template"))
                            stored = JsonObject(checkNotNull(stored) + patch)
                            respond("[$stored]", HttpStatusCode.OK, contentHeaders)
                        }
                        else -> error("Unexpected Program Step method")
                    }
                } else error("Unexpected route $path; no live or spray_records fallback")
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            try {
                val session = SessionStore(context)
                session.save("synthetic-access", "synthetic-refresh", owner, null)
                SupabaseClient.installInstrumentationTransport(client)
                val repository = SprayJobTemplateRepository(session)
                if (kind == "edit") {
                    val saved = repository.updateTemplate(draft.stepId, vineyard, draft.copy(notes = "Edited").portalPayload(owner))
                    assertEquals(draft.stepId, saved.id); assertEquals("Edited", saved.notes); assertEquals(0, attempts)
                    return@withTimeout
                }
                if (kind in listOf("denied", "wrongAck", "notAdmin")) {
                    var failed = false
                    try { repository.createTemplate(draft.stepId, vineyard, payload) } catch (_: Exception) { failed = true }
                    assertTrue("Unconfirmed create must fail", failed)
                    assertEquals(original, draft)
                    if (kind == "notAdmin") { assertEquals(0, attempts); assertNull(stored); return@withTimeout }
                    if (kind == "wrongAck") return@withTimeout
                    assertNull(stored)
                    assertTrue(repository.listTemplates(vineyard).isEmpty())
                    denied = false
                }
                val saved = repository.createTemplate(draft.stepId, vineyard, payload)
                assertEquals(draft.stepId, saved.id); assertEquals(vineyard, saved.vineyardId); assertTrue(saved.isTemplate)
                val list = repository.listTemplates(vineyard)
                assertEquals(1, list.size); assertEquals(saved.id, list.single().id)
                val raw = checkNotNull(repository.fetchTemplateRow(saved.id, vineyard))
                val reopened = SprayProgramStepDraft.fromPortalRow(raw)
                assertEquals(chemical, reopened.products.single().savedChemicalId)
                assertEquals(10.0, reopened.products.single().rate, 0.0)
                assertEquals("EL12", reopened.growthStageCode); assertEquals("Keep unsaved notes", reopened.notes)
                if (isFertigation) {
                    assertEquals("Fertigation", saved.operationType)
                    assertEquals("per_hectare", reopened.products.single().fertigationRateBasis)
                    assertEquals("kg/ha", reopened.products.single().fertigationRateUnit)
                    assertFalse(SprayProgramLanding.canPlanSpray(saved.operationType))
                    assertEquals(saved.id, raw.id)
                }
                assertEquals(if (kind == "denied") 2 else 1, attempts)
            } finally {
                SupabaseClient.installInstrumentationTransport(null); client.close()
                names.forEach { base.getSharedPreferences(prefix + it, Context.MODE_PRIVATE).edit().clear().commit() }
            }
        }
    }
}
