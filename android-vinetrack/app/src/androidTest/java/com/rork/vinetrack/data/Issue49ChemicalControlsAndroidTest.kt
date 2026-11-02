package com.rork.vinetrack.data

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.components.ChemicalRemovalConfirmation
import com.rork.vinetrack.ui.components.ChemicalRemovalProgress
import com.rork.vinetrack.ui.components.ChemicalVerificationBadge
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Shipping confirmation/progress and badge, synthetic state only. No customer files or HTTP. */
class Issue49ChemicalControlsAndroidTest {
    @get:Rule val compose = createComposeRule()
    private val chemical = SavedChemical("original", "vineyard", name = "CHATEAU Herbicide with a very long product name")

    @Test fun archiveIsDefaultPermanentDeleteRequiresExactName() {
        val actions = mutableListOf<ChemicalRemovalGuard.Action>()
        compose.setContent { MaterialTheme { ChemicalRemovalConfirmation(chemical, false, {}, { actions.add(it) }) } }
        compose.onNodeWithText("Archive", substring = false).assertIsEnabled()
        compose.onNodeWithText("Chemical ID: original").assertExists()
        compose.onNodeWithText("Delete Permanently…").performClick()
        compose.onNodeWithText("Confirm permanent deletion").assertIsNotEnabled()
        compose.onNodeWithText("Product name").performTextInput("Wrong chemical")
        compose.onNodeWithText("Confirm permanent deletion").assertIsNotEnabled()
        compose.onNodeWithText("Product name").performTextReplacement(chemical.displayName)
        compose.onNodeWithText("Confirm permanent deletion").performClick()
        compose.runOnIdle { assertEquals(listOf(ChemicalRemovalGuard.Action.DELETE), actions) }
    }
    @Test fun knownInUseNeverOffersPermanentDelete() {
        compose.setContent { MaterialTheme { ChemicalRemovalConfirmation(chemical, true, {}, {}) } }
        compose.onNodeWithText("Archive", substring = false).assertIsEnabled()
        compose.onNodeWithText("Delete Permanently…").assertDoesNotExist()
    }
    @Test fun tenSecondBusyProgressPreventsAdjacentActionAndRepeatedChecks() {
        val guard = ChemicalRemovalGuard({ null }, { true })
        var dispatches = 0
        compose.setContent {
            MaterialTheme {
                val state by guard.state.collectAsState()
                val scope = rememberCoroutineScope()
                var pending by remember { mutableStateOf(true) }
                if (pending && state.target == null) ChemicalRemovalConfirmation(chemical, false, {}, { action ->
                    val target = ChemicalRemovalGuard.Target("owner", chemical.vineyardId, chemical.id, chemical.displayName, action)
                    if (guard.begin(target)) {
                        pending = false; dispatches++
                        scope.launch { delay(10_000); guard.finish(target, "Synthetic readback confirmed") }
                    }
                })
                Button(enabled = state.target == null, onClick = { dispatches++ }) { Text("Adjacent chemical action") }
                ChemicalRemovalProgress(state, { error("Busy checks must be disabled") }, guard::dismissMessage)
            }
        }
        compose.onNodeWithText("Archive", substring = false).performClick()
        compose.onNodeWithText("Please wait…").assertIsNotEnabled()
        compose.onNodeWithText("Archive", substring = false).assertDoesNotExist()
        compose.runOnIdle { assertEquals(1, dispatches); assertEquals("original", guard.state.value.target?.id) }
        compose.runOnIdle { assertNotNull(guard.state.value.target); assertEquals(1, dispatches) }
        compose.waitUntil(15_000) { guard.state.value.target == null }
        compose.onNodeWithText("Synthetic readback confirmed").assertExists()
        compose.runOnIdle { assertEquals(1, dispatches) }
    }
    @Test fun uncertainPermanentRetryRequiresOriginalNameAndKeepsFrozenId() {
        var bytes: String? = null
        val initial = ChemicalRemovalGuard({ bytes }, { bytes = it; true })
        val target = ChemicalRemovalGuard.Target("owner", chemical.vineyardId, chemical.id, chemical.displayName, ChemicalRemovalGuard.Action.DELETE)
        initial.begin(target)
        val reopened = ChemicalRemovalGuard({ bytes }, { bytes = it; true })
        var retries = 0
        compose.setContent { MaterialTheme {
            val state by reopened.state.collectAsState()
            ChemicalRemovalProgress(state, {}, {}, {
                if (reopened.checking(target)) retries++
            })
        } }
        compose.onNodeWithText("Retry original action…").assertIsDisplayed().performClick()
        compose.onNodeWithText("Retry original delete?").assertIsDisplayed()
        compose.onNodeWithText("Retry this original action").assertIsNotEnabled()
        compose.onNodeWithText("Original product name").performTextInput(chemical.displayName)
        compose.onNodeWithText("Retry this original action").performClick()
        compose.runOnIdle { assertEquals(1, retries); assertEquals(target, reopened.state.value.target); assertTrue(reopened.state.value.busy) }
    }
    @Test fun basicDetailsStaysOneReadableLineAtNarrowWidthAndLargeFont() {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 1.6f)) {
                MaterialTheme {
                    Row(Modifier.width(280.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(chemical.displayName)
                            ChemicalVerificationBadge(chemical, storeTitle = "Basic details")
                        }
                        IconButton(onClick = {}) { Text("×") }
                    }
                }
            }
        }
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText("Basic details").performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertEquals(1, layouts.single().lineCount)
        val layout = layouts.single()
        // With softWrap=false Compose's paragraph width can retain the larger incoming
        // constraint (354px), flagging didOverflowWidth against a shrink-wrapped 189px
        // layout even though all glyphs fit (187.36px). Assert actual visible line bounds.
        assertFalse(layout.isLineEllipsized(0))
        assertTrue(layout.getLineLeft(0) >= 0f)
        assertTrue(layout.getLineRight(0) <= layout.size.width.toFloat())
        assertTrue(layout.getLineBottom(0) <= layout.size.height.toFloat())
    }
}
