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
