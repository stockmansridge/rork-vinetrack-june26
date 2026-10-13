package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.http.encodedPath
import io.ktor.http.content.TextContent
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Real scoped preferences and production REST PATCH, exclusively over synthetic transport. */
@RunWith(AndroidJUnit4::class)
class ChemicalConditionPersistenceAndroidTest {
    @Test fun capturedThreeStructuresSurviveRESTDiskEditAndFrozenReplay() = runBlocking {
        withTimeout(30_000) {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val rows = instrumentation.context.assets.open("production_chemical_registered_uses.json").bufferedReader().use { it.readText() }
            val originals = SupabaseClient.json.decodeFromString<List<SavedChemical>>(rows)
            val base = instrumentation.targetContext
            val prefix = "captured_chemicals_${UUID.randomUUID()}_"
            val names = linkedSetOf<String>()
            val context = object : ContextWrapper(base) {
                override fun getApplicationContext(): Context = this
                override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                    names.add(name)
                    return base.getSharedPreferences(prefix + name, mode)
                }
            }
            val vineyard = originals.first().vineyardId
            val owner = "22222222-2222-4222-8222-222222222222"
            var chemicalPatch: JsonObject? = null
            var offline = true
            var sprayPatchCount = 0
            var sprayAttempts = 0
            val capturedTanks = mutableListOf<com.rork.vinetrack.data.model.SprayTank>()
            val client = HttpClient(MockEngine { request ->
                val path = request.url.encodedPath
                if (path.endsWith("/rest/v1/saved_chemicals")) {
                    when (request.method) {
                        HttpMethod.Get -> respond(rows, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
                        HttpMethod.Patch -> {
                            val id = request.url.parameters["id"]!!.removePrefix("eq.")
                            chemicalPatch = SupabaseClient.json.parseToJsonElement((request.body as TextContent).text).jsonObject
                            val original = Json.parseToJsonElement(rows).jsonArray.single { it.jsonObject["id"]!!.jsonPrimitive.content == id }.jsonObject
                            val merged = JsonObject(original + chemicalPatch!!)
                            respond("[$merged]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
                        }
                        else -> error("Unexpected chemical method; no live fallback")
                    }
                } else if (path.endsWith("/rest/v1/spray_records") && request.method == HttpMethod.Patch) {
                    sprayAttempts++
                    if (offline) throw java.io.IOException("Synthetic offline transport")
                    val body = SupabaseClient.json.parseToJsonElement((request.body as TextContent).text).jsonObject
                    assertEquals(capturedTanks, SupabaseClient.json.decodeFromJsonElement(ListSerializer(com.rork.vinetrack.data.model.SprayTank.serializer()), body["tanks"]!!))
                    sprayPatchCount++
                    respond("[{\"id\":\"71000000-0000-4000-8000-000000000003\",\"vineyard_id\":\"$vineyard\",\"date\":\"2026-10-13\",\"start_time\":\"2026-10-13\",\"tanks\":${body["tanks"]}}]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
                } else error("Unexpected synthetic route; no live fallback")
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            try {
                val session = SessionStore(context)
                session.save("synthetic-access", "synthetic-refresh", owner, null)
                SupabaseClient.installInstrumentationTransport(client)
                val chemicals = VineyardRepository(session).listSavedChemicals(vineyard)
                assertEquals(originals, chemicals)
                assertTrue(SavedChemicalLocalStore(context).save(owner, vineyard, chemicals))
                for (chemical in chemicals) {
                    val originalUses = chemical.registeredUses!!
                    val reopened = SavedChemicalLocalStore(context).load(owner, vineyard).single { it.id == chemical.id }
                    assertEquals(originalUses, reopened.registeredUses)
                    assertTrue(SavedChemicalLocalStore(context).load("other-account", vineyard).isEmpty())
                    val draft = ChemicalManualEntry.draft(reopened, "AU").copy(productName = "Unrelated display edit")
                    val intelligence = ChemicalManualEntry.intelligenceForManualSave(draft)
                    assertEquals(originalUses, intelligence.registeredUses)
                    val input = SavedChemicalRepository.ChemicalInput(name = chemical.name, unit = chemical.unit,
                        ratePerHa = null, rates = emptyList(), activeIngredient = null, chemicalGroup = null,
                        use = null, problem = null, manufacturer = null, notes = "Unrelated note",
                        modeOfAction = null, labelUrl = null, productUrl = null, purchase = null, intelligence = intelligence)
                    val response = SavedChemicalRepository(session).update(chemical.id, input)
                    assertEquals(originalUses, SupabaseClient.json.decodeFromJsonElement(ListSerializer(ChemicalRegisteredUse.serializer()), chemicalPatch!!["registered_uses"]!!))
                    assertEquals(originalUses, response.registeredUses)
                    assertEquals("Litres", response.unit)
                    if (chemical.id == "ae9a8166-a052-41d4-af07-d7bc4de01c9a") {
                        assertEquals(listOf("% (±1%)", "%", null, null), response.activeIngredients!!.map { it.unresolvedConcentrationUnit })
                        assertEquals(listOf("% (±1%)", "%", null, null), chemical.activeIngredients!!.map { it.unresolvedConcentrationUnit })
                        assertEquals("% (±1%)", chemicalPatch!!["active_ingredients"]!!.jsonArray[0].jsonObject["concentration_unit"]!!.jsonPrimitive.content)
                        assertEquals("%", chemicalPatch!!["active_ingredients"]!!.jsonArray[1].jsonObject["concentration_unit"]!!.jsonPrimitive.content)
                        assertNotNull(SprayRegisteredUseRates.concentrationUnitReviewMessage(response))
                    }
                    assertTrue(SavedChemicalLocalStore(context).save(owner, vineyard, chemicals.map { if (it.id == response.id) response else it }))
                    assertEquals(originalUses, SavedChemicalLocalStore(context).load(owner, vineyard).single { it.id == chemical.id }.registeredUses)
                    val offered = SprayRegisteredUseRates.vineyardRates(response)
                    if (chemical.id == "f0244e28-c065-4124-a48f-a19994c7f236") {
                        assertTrue(SprayRegisteredUseRates.hasInvalidStructuredRates(response))
                        assertEquals(3, offered.size)
                        assertTrue(offered.none { it.isSelectable })
                        assertEquals(listOf("kg/ha", "g/100 L", "g/100L"), originalUses.single().rates.map { it.unit })
                        continue // Never fabricate an executable dose/snapshot for incompatible evidence.
                    }
                    val choices = offered.filter { it.appliedValue != null && (it.preset == SprayRatePreset.MIDPOINT || it.preset == null) }
                    for (chosen in choices) {
                        val basis = if (chosen.basis == SprayCalculator.RateBasis.PER_HECTARE) com.rork.vinetrack.data.spray.SprayProductRateBasis.WHOLE_BLOCK_AREA else com.rork.vinetrack.data.spray.SprayProductRateBasis.PER_100_LITRES
                        val frozen = SprayConfirmedRateSeeding.snapshotWithProvenance(null, response, basis, chosen.appliedValue!!,
                            chosen.unit, false, "2026-10-13T00:00:00Z", selectedRate = chosen)!!
                        assertEquals(chosen.registeredRate, frozen.registeredRate)
                        assertEquals(chosen.registeredUse, frozen.registeredUse)
                        assertEquals(chosen.condition, frozen.rateCondition)
                        val quantity = com.rork.vinetrack.data.spray.SprayProductQuantityCalculator.totalQuantity(chosen.appliedValue!!, basis,
                            com.rork.vinetrack.data.spray.SprayQuantityContext(grossAreaHectares = 6.0, carrierLitres = 1200.0, concentrationFactor = 1.0))!!
                        val litres = if (chosen.unit == "mL") quantity / 1000.0 else quantity
                        capturedTanks.add(com.rork.vinetrack.data.model.SprayTank(id = UUID.randomUUID().toString(), waterVolume = 1200.0, concentrationFactor = 1.0,
                            chemicals = listOf(com.rork.vinetrack.data.model.SprayChemical(id = UUID.randomUUID().toString(), name = response.name,
                                savedChemicalId = response.id, rateBasis = basis.raw, volumePerTank = litres, chemicalSnapshot = frozen))))
                    }
                }
                assertEquals(4, capturedTanks.size) // Two Crop Sil bases and both explicit REVUS choices.
                val queue = PendingWriteRepository(PendingWriteStore(context))
                val payload = SprayRecordUpdateSync.Payload("71000000-0000-4000-8000-000000000003", "2026-10-13", "2026-10-13",
                    tanks = capturedTanks, clientUpdatedAt = "2026-10-13T00:00:00Z")
                val bytes = SupabaseClient.json.encodeToString(SprayRecordUpdateSync.Payload.serializer(), payload)
                val original = queue.enqueue(com.rork.vinetrack.data.model.PendingEntityType.SPRAY_RECORD, com.rork.vinetrack.data.model.PendingOpType.UPDATE, bytes, payload.id)
                var publications = 0
                SprayRecordUpdateSync(SprayRecordRepository(session), queue).replayAll { publications++ }
                assertEquals(0, publications)
                val failed = PendingWriteRepository(PendingWriteStore(context)).list().single()
                assertEquals(original.id, failed.id)
                assertEquals(original.clientId, failed.clientId)
                assertEquals(original.createdAt, failed.createdAt)
                assertEquals(original.payloadJson, failed.payloadJson)
                assertEquals(1, failed.attemptCount)
                offline = false
                val recreated = PendingWriteRepository(PendingWriteStore(context))
                SprayRecordUpdateSync(SprayRecordRepository(SessionStore(context)), recreated).replayAll { record ->
                    assertEquals(capturedTanks, record.tanks)
                    publications++
                }
                assertEquals(1, publications)
                assertTrue(PendingWriteRepository(PendingWriteStore(context)).list().isEmpty())
                SprayRecordUpdateSync(SprayRecordRepository(session), recreated).replayAll { publications++ }
                assertEquals(1, publications)
                assertEquals(1, sprayPatchCount)
                assertEquals(2, sprayAttempts)
            } finally {
                SupabaseClient.installInstrumentationTransport(null)
                client.close()
                names.forEach { base.deleteSharedPreferences(prefix + it) }
            }
        }
    }

    @Test fun suppliedConditionPayloadSurvivesDiskRecreationAndMockedEditSync() = runBlocking {
        withTimeout(20_000) {
            val base = InstrumentationRegistry.getInstrumentation().targetContext
            val prefix = "chemical_condition_${UUID.randomUUID()}_"
            val names = linkedSetOf<String>()
            val context = object : ContextWrapper(base) {
                override fun getApplicationContext(): Context = this
                override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                    names.add(name)
                    return base.getSharedPreferences(prefix + name, mode)
                }
            }
            val vineyard = "11111111-1111-4111-8111-111111111111"
            val owner = "22222222-2222-4222-8222-222222222222"
            // User-supplied rate fields, not a captured complete live use.
            val row = """{"id":"ae9a8166-a052-41d4-af07-d7bc4de01c9a","vineyard_id":"$vineyard","name":"Crop Sil","unit":"Litres","registered_uses":[{"crop":"Grapevines (viticulture)","target_raw":"","future_use":{"original":true},"rates":[{"basis":"range_per_hectare","unit":"L/ha","min_value":3,"max_value":5,"raw_text":"3-5L","condition":"Monthly as required"},{"basis":"range_per_100_litres","unit":"mL/100 L water","min_value":500,"max_value":1000,"raw_text":"500-1000mls/100L water","condition":"If using high volumes of water for foliar sprays"}]}]}"""
            var patch: JsonObject? = null
            val client = HttpClient(MockEngine { request ->
                assertTrue(request.url.encodedPath.endsWith("/rest/v1/saved_chemicals"))
                when (request.method) {
                    HttpMethod.Get -> respond("[$row]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
                    HttpMethod.Patch -> {
                        patch = SupabaseClient.json.parseToJsonElement((request.body as TextContent).text).jsonObject
                        respond("[$row]", HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
                    }
                    else -> error("Unexpected synthetic request; no live fallback")
                }
            }) { install(ContentNegotiation) { json(SupabaseClient.json) } }
            try {
                val session = SessionStore(context)
                session.save("synthetic-access", "synthetic-refresh", owner, null)
                SupabaseClient.installInstrumentationTransport(client)
                val chemical = VineyardRepository(session).listSavedChemicals(vineyard).single()
                val original = chemical.registeredUses!!
                assertTrue(SavedChemicalLocalStore(context).save(owner, vineyard, listOf(chemical)))
                val reopened = SavedChemicalLocalStore(context).load(owner, vineyard).single()
                assertEquals(original, reopened.registeredUses)
                assertTrue(SavedChemicalLocalStore(context).load("other-account", vineyard).isEmpty())
                val draft = ChemicalManualEntry.draft(reopened, "NZ").copy(productName = "Unrelated name edit")
                val intelligence = ChemicalManualEntry.intelligenceForManualSave(draft)
                val input = SavedChemicalRepository.ChemicalInput(
                    name = chemical.name, unit = chemical.unit, ratePerHa = null, rates = emptyList(),
                    activeIngredient = null, chemicalGroup = null, use = null, problem = null,
                    manufacturer = null, notes = "Unrelated notes edit", modeOfAction = null,
                    labelUrl = null, productUrl = null, purchase = null, intelligence = intelligence,
                )
                val response = SavedChemicalRepository(session).update(chemical.id, input)
                val transmitted = SupabaseClient.json.decodeFromJsonElement(ListSerializer(ChemicalRegisteredUse.serializer()), requireNotNull(patch)["registered_uses"]!!)
                assertEquals(original, transmitted)
                assertEquals(original, response.registeredUses)
                assertTrue(SavedChemicalLocalStore(context).save(owner, vineyard, listOf(response)))
                assertEquals(original, SavedChemicalLocalStore(context).load(owner, vineyard).single().registeredUses)
                val offered = SprayRegisteredUseRates.vineyardRates(response)
                assertTrue(offered.any { it.displayText == "4 L/ha" && it.condition == "Monthly as required" })
                assertTrue(offered.any { it.displayText == "750 mL/100 L" && it.condition == "If using high volumes of water for foliar sprays" })
            } finally {
                SupabaseClient.installInstrumentationTransport(null)
                client.close()
                names.forEach { base.deleteSharedPreferences(prefix + it) }
            }
        }
    }
}
