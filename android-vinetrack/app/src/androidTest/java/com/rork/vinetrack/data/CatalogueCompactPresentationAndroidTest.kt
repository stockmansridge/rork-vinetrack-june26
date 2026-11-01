package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.screens.CatalogueSavedChemical
import com.rork.vinetrack.ui.theme.AppTheme
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

/** Shipping catalogue summary/details at narrow handset width, synthetic GET-only backend. */
class CatalogueCompactPresentationAndroidTest {
    @get:Rule val compose = createComposeRule()
    @Test fun lightCompactSummaryAndFullLongDetails() = verify(false, 1f)
    @Test fun darkLargeTextCompactSummaryAndFullLongDetails() = verify(true, 1.5f)

    private fun verify(dark: Boolean, scale: Float) {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val prefix = "pr35_cards_${UUID.randomUUID()}_"
        val names = linkedSetOf<String>()
        val context = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                names.add(name)
                return base.getSharedPreferences(prefix + name, mode)
            }
        }
        val product = "35000000-0000-4000-8000-000000000011"
        val old = "35000000-0000-4000-8000-000000000012"
        val current = "35000000-0000-4000-8000-000000000013"
        val targets = (1..16).map { "Synthetic grapevine target $it with extended label description" }
        val usedFor = "Used for: ${targets.joinToString(" · ")}"
        val revision = buildJsonObject {
            put("id", current); put("product_id", product); put("review_status", "approved")
            putJsonArray("vineyard_uses") { add(buildJsonObject { put("targets", JsonArray(targets.map(::JsonPrimitive))) }) }
            putJsonObject("default_rate_options") {
                putJsonArray("per_100_litres") {
                    add(buildJsonObject { put("min_value", 200); put("max_value", 600); put("unit", "g"); put("condition", "Synthetic range condition — choose an exact operator dose") })
                    add(buildJsonObject { put("value", 400); put("unit", "g"); put("condition", "Synthetic separate option") })
                }
            }
        }
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Get, request.method)
            val response = when {
                request.url.encodedPath.endsWith("/chemical_v3_products") -> """[{"id":"$product","status":"approved","approved_revision_id":"$current"}]"""
                request.url.encodedPath.endsWith("/chemical_v3_product_revisions") && request.url.parameters["id"] == "eq.$old" ->
                    """[{"id":"$old","product_id":"$product","review_status":"superseded","product_name":"Synthetic long catalogue product title for narrow handset rendering","manufacturer":"Synthetic Australia Pty Ltd"}]"""
                request.url.encodedPath.endsWith("/chemical_v3_product_revisions") && request.url.parameters["id"] == "eq.$current" -> "[$revision]"
                else -> error("Unexpected synthetic route; no live fallback")
            }
            respond(response, HttpStatusCode.OK, headersOf("Content-Type", "application/json"))
        })
        try {
            SessionStore(context).save("synthetic-access", "synthetic-refresh", product, null)
            SupabaseClient.installInstrumentationTransport(client)
            val chemical = SavedChemical(id = product, vineyardId = product, name = "Synthetic product", chemicalV3ProductId = product, chemicalV3RevisionId = old)
            compose.setContent {
                val density = LocalDensity.current
                CompositionLocalProvider(LocalContext provides context, LocalDensity provides Density(density.density, scale)) {
                    AppTheme(darkTheme = dark) {
                        var details by remember { mutableStateOf(false) }
                        Column(Modifier.width(320.dp).verticalScroll(rememberScrollState()).padding(8.dp)) {
                            Button(onClick = { details = !details }) { Text("Open full fixture details") }
                            CatalogueSavedChemical(chemical, showsDetails = details)
                        }
                    }
                }
            }
            compose.waitUntil(10_000) { compose.onAllNodesWithText(usedFor).fetchSemanticsNodes().isNotEmpty() }
            val compact = mutableListOf<TextLayoutResult>()
            compose.onNodeWithText(usedFor).performScrollTo()
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(compact) }
            assertEquals(1, compact.size)
            assertEquals("Summary target text must stay compact", 2, compact.single().lineCount)
            assertTrue("Compact truncation must be visible", compact.single().isLineEllipsized(1))
            compose.onNodeWithText("Registered grapevine rates").assertDoesNotExist()
            compose.onNodeWithText("Open full fixture details").performScrollTo().performClick()
            val full = mutableListOf<TextLayoutResult>()
            compose.onNodeWithText(usedFor).performScrollTo()
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(full) }
            assertEquals(1, full.size)
            assertTrue("Full details must retain the complete target list", full.single().lineCount > 2)
            assertFalse("Full text must not truncate", full.single().isLineEllipsized(full.single().lineCount - 1))
            compose.onNodeWithText("Registered grapevine rates").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("200–600 g/100 L", substring = true).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("400 g/100 L", substring = true).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Choose the exact dose when planning the spray. Follow the applicable label conditions.").performScrollTo().assertIsDisplayed()
            assertEquals(old, chemical.chemicalV3RevisionId)
            assertNull(chemical.ratePerHa)
            assertNull(chemical.vineyardPreferredRate)
        } finally {
            SupabaseClient.installInstrumentationTransport(null)
            client.close()
            names.forEach { base.deleteSharedPreferences(prefix + it) }
        }
    }
}
