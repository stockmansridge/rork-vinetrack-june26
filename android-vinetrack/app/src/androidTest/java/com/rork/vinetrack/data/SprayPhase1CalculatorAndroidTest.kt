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
    @Test fun bandedContinuesToReview() = runCalculator(custom = false, operation = "Banded Spray")
    @Test fun spreaderContinuesToReview() = runCalculator(custom = false, operation = "Spreader")
    @Test fun editingBlocksRetainsAnswersAndLocksDownstream() = runCalculator(custom = false, editBlocks = true)
    @Test fun programPrefillRetainsAnsweredSteps() = runCalculator(custom = false, prefilled = true)

    private fun checkPrefill() {
        if (compose.onAllNodesWithText("Spray name (optional)").fetchSemanticsNodes().isEmpty()) click("Application")
        val name = hasSetTextAction() and hasText("Synthetic program")
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(name)
        compose.onNode(name).assertExists()
        click("Continue to Blocks →")
        click("Continue to Target →")
        compose.onNode(hasText("Target") and hasText("Powdery Mildew", substring = true) and hasClickAction()).assertExists()
        click("Full Canopy") // Head target was not supplied by this historical prefill.
        click("Continue to Growth Stage →")
        click("Continue to Equipment →")
        compose.onNode(hasText("Synthetic 1000 L unit") and hasText("1000.0 L tank") and hasClickAction()).assertExists()
    }

    private fun click(text: String) {
        val matcher = hasText(text) and hasClickAction()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(matcher)
        compose.onNode(matcher).assertIsEnabled().performClick()
        compose.waitForIdle()
        if (text.startsWith("Continue to ")) {
            val title = text.removePrefix("Continue to ").removeSuffix(" →")
            // The expanded Growth Stage body also has a selector with this title;
            // the first matching clickable node is the existing card header.
            compose.onAllNodes(hasText(if (title == "Spray Volume") "Canopy & Spray Volume" else title) and hasClickAction()).onFirst().assertIsDisplayed()
        }
    }

    private fun runCalculator(custom: Boolean, operation: String = "Foliar Spray", editBlocks: Boolean = false, prefilled: Boolean = false) {
        openCalculator(prefilled)
        if (prefilled) checkPrefill() else {
        compose.onNodeWithText("Spray name (optional)").assertExists() // Application starts expanded.
        compose.onNode(hasText("Blocks") and hasClickAction()).assertIsNotEnabled()
        compose.onNodeWithText("Continue to Blocks →").assertIsNotEnabled()
        compose.onNodeWithText("Operation type").performClick()
        compose.onNode(hasText(operation) and hasAnyAncestor(isPopup())).performClick()
        compose.onNodeWithText("Spray name (optional)").assertExists() // No auto-collapse.
        click("Continue to Blocks →")
        compose.onNodeWithText("Spray name (optional)").assertDoesNotExist()
        compose.onNodeWithText("Continue to Target →").assertIsNotEnabled()
        click("Select All")
        click("Continue to Target →")
        click("Powdery Mildew")
        if (operation == "Banded Spray") {
            click("Undervine")
            val width = hasSetTextAction() and hasText("Band width", substring = true)
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(width)
            compose.onNode(width).performTextInput("0.8")
        } else if (operation == "Foliar Spray") click("Full Canopy")
        click("Continue to Growth Stage →")
        val stageBody = hasText("Growth Stage") and hasClickAction() and !hasText("4")
        compose.onNode(stageBody).performClick()
        click("Not Set")
        click("Continue to Equipment →")
        }
        if (editBlocks) {
            click("Blocks")
            click("Deselect All")
            compose.onNodeWithText("Continue to Target →").assertIsNotEnabled()
            val equipment = hasText("Equipment") and hasText("5") and hasClickAction()
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(equipment)
            compose.onNode(equipment).assertIsNotEnabled()
            click("Select All")
            click("Continue to Target →")
            compose.onNode(hasText("Powdery Mildew") and hasClickAction()).assertExists()
            click("Continue to Growth Stage →")
            compose.onNode(hasText("Target") and hasText("Powdery Mildew", substring = true) and hasClickAction()).assertExists()
            click("Continue to Equipment →")
        }
        // Production auto-selects a sole unit; open its summary, then explicitly select it.
        val unitSummary = hasText("Synthetic 1000 L unit") and hasText("1000.0 L tank") and hasClickAction()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(unitSummary)
        compose.onNode(unitSummary).performClick()
        // The header, summary and expanded option contain the name: select the last (option) row.
        compose.onAllNodes(hasText("Synthetic 1000 L unit") and hasClickAction()).onLast().performClick()
        click("  Confirm equipment")
        click("Continue to Spray Volume →")
        if (operation == "Banded Spray") {
            compose.onNodeWithText("Canopy Type").assertDoesNotExist()
            val rate = hasSetTextAction() and hasText("Application rate (", substring = true)
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(rate)
            compose.onNode(rate).performTextInput("200")
        } else if (operation == "Spreader") {
            compose.onNodeWithText("Canopy Type").assertDoesNotExist()
            // Spreader retains its existing carrier inputs, with no canopy decision.
        } else {
        click("VSP")
        compose.onAllNodesWithText("Confirm Canopy — VSP · Medium · Low").assertCountEquals(1)
        // A composed header may name the blocker, but there must be no separate warning panel.
        val duplicateCanopyWarning = hasText("Confirm canopy") and !hasAnyAncestor(hasClickAction()) and !hasClickAction()
        compose.onAllNodes(duplicateCanopyWarning).assertCountEquals(0)
        compose.onNodeWithText("Continue to Products →").assertIsNotEnabled()
        click("Confirm Canopy — VSP · Medium · Low")
        compose.onNodeWithText("RECOMMENDED SPRAY VOLUME — CF 1.00").assertExists()
        compose.onNodeWithText("Spray at the recommended volume?").assertExists()
        compose.onAllNodesWithText("Confirm canopy").assertCountEquals(0)
        compose.onNodeWithText("Continue to Products →").assertIsNotEnabled()
        click(if (custom) "Set my own rate" else "Use recommended rate")
        if (custom) {
            compose.onNodeWithText("Enter sprayer output").assertExists()
            compose.onNodeWithText("Continue to Products →").assertIsNotEnabled()
            val rate = hasSetTextAction() and hasText("Custom sprayer rate", substring = true)
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(rate)
            compose.onNode(rate).performTextInput("600")
            compose.waitForIdle()
        }
        }
        click("Continue to Products →")
        val addChemical = hasText("  Add Chemical") and hasClickAction()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(addChemical)
        compose.onNode(addChemical).assertIsDisplayed()
        compose.onNode(addChemical).performClick()
        compose.onNode(hasText("Synthetic product") and hasClickAction()).performClick()
        if (operation == "Banded Spray") click("Treated Band Area")
        click("Continue to Review →")
        compose.onNode(hasText("Review") and hasClickAction()).assertIsDisplayed()
    }

    private fun openCalculator(prefilled: Boolean = false) {
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
            paddocks = listOf(block), sprayEquipment = listOf(SprayEquipment(UUID.randomUUID().toString(), vineyard, "Synthetic 1000 L unit", 1000.0)),
            savedChemicals = listOf(SavedChemical(UUID.randomUUID().toString(), vineyard, name = "Synthetic product", rates = listOf(ChemicalRate(label = "Synthetic rate", value = 1.0)))))
        val prefill = if (prefilled) SprayRecord(UUID.randomUUID().toString(), vineyard,
            sprayReference = "Synthetic program", isTemplate = true, operationType = "Foliar Spray",
            sprayEquipmentId = state.sprayEquipment.single().id, targets = listOf("powdery_mildew"), templateGrowthStageCode = "EL12") else null
        compose.setContent {
            CompositionLocalProvider(LocalRegionFormatter provides RegionFormatter(RegionCountry.Australia.recommendedPreset)) {
                MaterialTheme { SprayCalculatorScreen(vm, state, prefillJobRecord = prefill,
                    prefillPaddockIds = if (prefilled) listOf(block.id) else emptyList()) }
            }
        }
        compose.waitForIdle()
    }
}
