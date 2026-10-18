package com.rork.vinetrack.data

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.screens.TargetNutrientPreview
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/** Real production Compose preview, synthetic inputs only. No auth, ViewModel or transport. */
class TargetNutrientPreviewAndroidTest {
    @get:Rule val compose = createComposeRule()
    private val blocks = listOf(Paddock(id = "a", vineyardId = "fixture", name = "Synthetic A", vineSpacing = 2.0, vineCountOverride = 4200, rowLengthOverride = 10000.0))
    private fun mount(admin: Boolean = true, products: List<SavedChemical> = emptyList()) {
        compose.setContent { MaterialTheme { TargetNutrientPreview(products, blocks, RegionFormatter(), admin) } }
    }
    private fun enter(tag: String, value: String) { compose.onNodeWithTag(tag).performScrollTo().performTextReplacement(value) }
    private fun choose(label: String, option: String) {
        compose.onNodeWithTag("nutrient.choice.$label").performScrollTo().performClick()
        compose.onNodeWithText(option, useUnmergedTree = true).performClick()
    }
    @Test fun phoneResultsFollowInputsAndNutrientSwitchRetainsDraft() {
        mount()
        enter("nutrient.percent", "16"); enter("nutrient.target", "2"); enter("nutrient.vines", "1000")
        compose.onNodeWithTag("nutrient.rate").performScrollTo().assertTextEquals("12.5 g/vine")
        compose.onNodeWithTag("nutrient.total").assertTextEquals("12.5 kg")
        compose.onNodeWithTag("nutrient.delivered").assertTextEquals("2 kg")
        val resultY = compose.onNodeWithTag("nutrient.results").fetchSemanticsNode().positionInRoot.y
        val blockY = compose.onNodeWithTag("nutrient.blockDetails").fetchSemanticsNode().positionInRoot.y
        assertTrue(resultY < blockY)
        choose("Nutrient", "Ca — Calcium")
        compose.onNodeWithTag("nutrient.percent").assertTextContains("16")
        compose.onNodeWithTag("nutrient.target").assertTextContains("2")
        compose.onNodeWithTag("nutrient.rate").assertDoesNotExist()
        choose("Percentage declared as", "Elemental — actual nutrient")
        enter("nutrient.percent", "20")
        compose.onNodeWithTag("nutrient.rate").performScrollTo().assertTextEquals("10 g/vine")
        compose.onNodeWithTag("nutrient.saveDisabled").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("Add Nutrient").assertDoesNotExist()
    }
    @Test fun liquidRequiresExplicitConcentrationAndDocumentedDensity() {
        mount()
        compose.onNodeWithText("Liquid product").performScrollTo()
        compose.onAllNodes(isToggleable()).filterToOne(hasAnySibling(hasText("Liquid product"))).performClick()
        enter("nutrient.percent", "16"); enter("nutrient.target", "2"); enter("nutrient.vines", "1000")
        compose.onNodeWithTag("nutrient.rate").assertDoesNotExist()
        choose("Concentration basis", "w/v — weight / volume")
        compose.onNodeWithTag("nutrient.rate").performScrollTo().assertTextEquals("12.5 mL/vine")
        choose("Concentration basis", "w/w — weight / weight")
        compose.onNodeWithTag("nutrient.rate").assertDoesNotExist()
        enter("Density (kg/L)", "1.25")
        compose.onNodeWithTag("nutrient.rate").assertDoesNotExist()
        enter("Density source — label / technical sheet", "Synthetic sheet")
        compose.onNodeWithTag("nutrient.rate").performScrollTo().assertTextEquals("10 mL/vine")
    }
    @Test fun draftAndBlockSelectionSurviveSavedStateRestoration() {
        val restoration = StateRestorationTester(compose)
        restoration.setContent { MaterialTheme { TargetNutrientPreview(emptyList(), blocks, RegionFormatter(), true) } }
        enter("nutrient.percent", "16"); enter("nutrient.target", "2")
        compose.onNodeWithTag("nutrient.block.a").performScrollTo().performClick()
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithTag("nutrient.total").performScrollTo().assertTextEquals("52.5 kg")
        choose("Nutrient", "Ca — Calcium")
        compose.onNodeWithTag("nutrient.percent").assertTextContains("16")
        compose.onNodeWithTag("nutrient.target").assertTextContains("2")
        compose.onNodeWithTag("nutrient.block.a").performScrollTo().assertIsOn()
    }
    @Test fun blockSelectionAndCountBasisImmediatelyChangeTotals() {
        mount(); enter("nutrient.percent", "16"); enter("nutrient.target", "2")
        compose.onNodeWithTag("nutrient.block.a").performScrollTo().performClick()
        compose.onNodeWithTag("nutrient.total").performScrollTo().assertTextEquals("52.5 kg")
        choose("Vine count basis", "Assumed full")
        compose.onNodeWithTag("nutrient.total").performScrollTo().assertTextEquals("62.5 kg")
        compose.onNodeWithTag("nutrient.delivered").assertTextEquals("10 kg")
    }
    @Test fun nonAdminCannotMountInputsOrResults() {
        mount(admin = false)
        compose.onNodeWithText("Target Nutrient is a System Admin-only preview.").assertIsDisplayed()
        compose.onNodeWithTag("nutrient.percent").assertDoesNotExist()
        compose.onNodeWithTag("nutrient.results").assertDoesNotExist()
    }
    @Test fun unsupportedLocalRecordAndOriginalOutboxSurviveRejectedMutationsAndReplay() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val session = SessionStore(context)
        session.save("synthetic-access", "synthetic-refresh", UUID.randomUUID().toString(), null)
        val vineyard = UUID.randomUUID().toString()
        val record = FertiliserRecord(id = UUID.randomUUID().toString(), vineyardId = vineyard, date = "2026-10-18", mode = "nutrientTarget", rate = 12.5, totalProduct = 12.5)
        val store = FertiliserStore(context); store.saveRecords(vineyard, listOf(record))
        val pending = PendingWriteRepository(context)
        pending.enqueue(PendingEntityType.FERTILISER_RECORD, PendingOpType.UPDATE, Json.encodeToString(record), record.id)
        val original = pending.list()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val coordinator = FertiliserSyncCoordinator(store, FertiliserSyncRepository(session), pending, scope) { true }
            coordinator.markCompleted(vineyard, record.id); coordinator.deleteRecord(vineyard, record.id)
            coordinator.addRecord(vineyard, record.copy(mode = "perHectare"))
            coordinator.addRecord(vineyard, record)
            coordinator.replayAll()
            assertEquals(listOf(record), FertiliserStore(context).loadRecords(vineyard))
            assertEquals(original, pending.list())
            assertEquals(original, PendingWriteRepository(context).list())
            listOf("perVine", "perHectare").forEach { mode ->
                val legacy = record.copy(id = UUID.randomUUID().toString(), mode = mode)
                store.addRecord(vineyard, legacy)
                store.markCompleted(vineyard, legacy.id, "2026-10-19")
                val completed = store.loadRecords(vineyard).single { it.id == legacy.id }
                assertEquals("completed", completed.status); assertEquals(12.5, completed.totalProduct, 0.0)
                store.deleteRecord(vineyard, legacy.id)
                assertEquals(listOf(record), store.loadRecords(vineyard))
            }
        } finally { scope.cancel() }
    }
    @Test fun legacySavedProductNeverSeedsVerifiedPercentage() {
        mount(products = listOf(SavedChemical(id = "product", vineyardId = "fixture", name = "Legacy fertiliser", unit = "kg", nitrogenPercent = 16.0)))
        choose("Product", "Legacy fertiliser")
        compose.onNodeWithTag("nutrient.percent").assert(hasSetTextAction() and hasText("", substring = false))
        enter("nutrient.target", "2"); enter("nutrient.vines", "1000")
        compose.onNodeWithTag("nutrient.rate").assertDoesNotExist()
        enter("nutrient.percent", "16")
        compose.onNodeWithTag("nutrient.rate").performScrollTo().assertTextEquals("12.5 g/vine")
    }
}
