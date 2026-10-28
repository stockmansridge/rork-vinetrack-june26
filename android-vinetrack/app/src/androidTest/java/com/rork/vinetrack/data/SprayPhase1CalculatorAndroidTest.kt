package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.screens.SprayCalculatorScreen
import com.rork.vinetrack.ui.LocalRegionFormatter
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import org.junit.After
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

/** Actual calculator, actual remembered state and engine, isolated disk and blocked network.
 * All decisions are made through production UI; no configured canopy or replacement controls.
 */
class SprayPhase1CalculatorAndroidTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    private var client: HttpClient? = null
    private var root: File? = null
    private var namespace: String? = null
    private val preferences = java.util.Collections.synchronizedSet(linkedSetOf<String>())

    @After fun cleanUp() {
        compose.runOnUiThread { models.clear() }
        SupabaseClient.installInstrumentationTransport(null)
        client?.close()
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        namespace?.let { prefix -> preferences.forEach { base.getSharedPreferences(prefix + it, Context.MODE_PRIVATE).edit().clear().commit() } }
        root?.deleteRecursively()
    }

    @Test fun newOneOffRecommendedCarrierUnlocksProducts() = runCalculator(custom = false)
    @Test fun newOneOffCustomCarrierUnlocksProducts() = runCalculator(custom = true)

    private fun click(text: String) {
        val matcher = hasText(text) and hasClickAction()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(matcher)
        compose.onNode(matcher).performClick()
        compose.waitForIdle()
    }

    private fun runCalculator(custom: Boolean) {
        openCalculator()
        compose.onNodeWithText("Spray name (optional)").assertExists() // Application starts expanded.
        compose.onNode(hasText("Blocks") and hasClickAction()).assertIsNotEnabled()
        compose.onNodeWithText("Continue to Blocks →").assertDoesNotExist()
        compose.onNodeWithText("Operation type").performClick()
        compose.onNode(hasText("Foliar Spray") and hasAnyAncestor(isPopup())).performClick()
        compose.onNodeWithText("Spray name (optional)").assertExists() // No auto-collapse.
        click("Continue to Blocks →")
        compose.onNodeWithText("Spray name (optional)").assertDoesNotExist()
        click("Select All")
        click("Target")
        click("Powdery Mildew")
        click("Full Canopy")
        val stageHeader = hasText("Growth Stage") and hasText("4") and hasClickAction()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(stageHeader)
        compose.onNode(stageHeader).performClick()
        val stageBody = hasText("Growth Stage") and hasClickAction() and !hasText("4")
        compose.onNode(stageBody).performClick()
        click("Not Set")
        click("Equipment")
        // Production auto-selects a sole unit; open its summary, then explicitly select it.
        val unitSummary = hasText("Synthetic 1000 L unit") and hasText("1000.0 L tank") and hasClickAction()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(unitSummary)
        compose.onNode(unitSummary).performClick()
        // The header, summary and expanded option contain the name: select the last (option) row.
        compose.onAllNodes(hasText("Synthetic 1000 L unit") and hasClickAction()).onLast().performClick()
        click("  Confirm equipment")
        click("Canopy & Spray Volume")
        click("VSP")
        compose.onAllNodesWithText("Confirm Canopy — VSP · Medium · Low").assertCountEquals(1)
        // A composed header may name the blocker, but there must be no separate warning panel.
        val duplicateCanopyWarning = hasText("Confirm canopy") and !hasAnyAncestor(hasClickAction()) and !hasClickAction()
        compose.onAllNodes(duplicateCanopyWarning).assertCountEquals(0)
        compose.onNodeWithText("Continue to Products →").assertDoesNotExist()
        click("Confirm Canopy — VSP · Medium · Low")
        compose.onNodeWithText("RECOMMENDED SPRAY VOLUME — CF 1.00").assertExists()
        compose.onNodeWithText("Spray at the recommended volume?").assertExists()
        compose.onAllNodesWithText("Confirm canopy").assertCountEquals(0)
        compose.onNodeWithText("Continue to Products →").assertDoesNotExist()
        click(if (custom) "Set my own rate" else "Use recommended rate")
        if (custom) {
            compose.onNodeWithText("Enter sprayer output").assertExists()
            compose.onNodeWithText("Continue to Products →").assertDoesNotExist()
            val rate = hasSetTextAction() and hasText("Custom sprayer rate", substring = true)
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(rate)
            compose.onNode(rate).performTextInput("600")
            compose.waitForIdle()
        }
        click("Continue to Products →")
        val addChemical = hasText("  Add Chemical") and hasClickAction()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(addChemical)
        compose.onNode(addChemical).assertIsDisplayed()
    }

    private fun openCalculator() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val prefix = "spray_phase1_${UUID.randomUUID()}_"
        namespace = prefix
        val isolatedRoot = File(base.cacheDir, prefix).apply { mkdirs() }; root = isolatedRoot
        val wrapped = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                preferences.add(name)
                return base.getSharedPreferences(prefix + name, mode)
            }
            override fun getFilesDir(): File = File(isolatedRoot, "files").apply { mkdirs() }
            override fun getCacheDir(): File = File(isolatedRoot, "cache").apply { mkdirs() }
        }
        val app = object : Application() {
            init { attachBaseContext(wrapped) }
            override fun getApplicationContext(): Context = this
        }
        client = HttpClient(MockEngine { respond("Synthetic UI: no live fallback", HttpStatusCode.ServiceUnavailable) })
        SupabaseClient.installInstrumentationTransport(client)
        lateinit var vm: AppViewModel
        compose.runOnUiThread { vm = AppViewModel(app); models.put("phase1", vm) }
        val vineyard = UUID.randomUUID().toString()
        val block = Paddock(id = UUID.randomUUID().toString(), vineyardId = vineyard, name = "Synthetic block", rowWidth = 2.8,
            polygonPoints = listOf(CoordinatePoint(-35.0, 149.0), CoordinatePoint(-35.0, 149.002),
                CoordinatePoint(-35.002, 149.002), CoordinatePoint(-35.002, 149.0)),
            rows = listOf(PaddockRow(number = 1, startPoint = CoordinatePoint(-35.0, 149.0), endPoint = CoordinatePoint(-35.001, 149.0))))
        val state = AppUiState(selectedVineyardId = vineyard, currentUserId = UUID.randomUUID().toString(), isOnline = false,
            paddocks = listOf(block), sprayEquipment = listOf(SprayEquipment(UUID.randomUUID().toString(), vineyard, "Synthetic 1000 L unit", 1000.0)))
        compose.setContent {
            CompositionLocalProvider(LocalRegionFormatter provides RegionFormatter(RegionCountry.Australia.recommendedPreset)) {
                MaterialTheme { SprayCalculatorScreen(vm, state) }
            }
        }
        compose.waitForIdle()
    }
}
