package com.rork.vinetrack.data

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.screens.LocalYieldMapPreview
import com.rork.vinetrack.ui.screens.YieldSamplingMapScreen
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real sampling controls; renderer excluded. Not GPS/map gesture or Portal acceptance. */
class Issue49YieldSamplingAndroidTest {
    @get:Rule val compose = createComposeRule()
    private fun seed() = YieldEstimationSession("trip", "vineyard", "2026-11-02T00:00:00Z", sampleSites = (1..19).map { i ->
        SampleSite("site$i", "block", "Block", i, -33.0, 149.0, i,
            if (i <= 4) BunchCountEntry(10.0 + i, "2026-11-02T00:00:00Z") else null)
    }, blockBunchWeightsKg = mapOf("block" to 0.15))

    @Test fun fourOfNineteenSkipPreviousManualSelectAndPartialFinishKeepMeasurements() {
        val seed = seed(); var saves = 0; var finishes = 0
        compose.setContent { MaterialTheme {
            CompositionLocalProvider(LocalYieldMapPreview provides { Text("Map excluded") }) {
                YieldSamplingMapScreen(AppUiState(), seed, { _, _, _ -> saves++; true }, { _, _ -> false }, { finishes++ }, {})
            }
        } }
        compose.onNodeWithText("Sample 5 · Row 5 · Block").assertExists()
        compose.onNodeWithText("Skip").performClick()
        compose.onNodeWithText("Sample 6 · Row 6 · Block").assertExists()
        compose.onNodeWithText("Prev").performClick()
        compose.onNodeWithText("Sample 5 · Row 5 · Block").assertExists()
        compose.onNodeWithText("Sample list").performClick()
        compose.onNodeWithText("3 · Block · Row 3 · Recorded").performClick()
        compose.onNodeWithText("Sample 3 · Row 3 · Block").assertExists()
        compose.onNodeWithText("Finish Sampling (4/19)").performClick()
        compose.onNodeWithText("Finish with incomplete samples?").assertExists()
        compose.runOnIdle { assertEquals(0, finishes); assertEquals(0, saves) }
        compose.onNodeWithText("Keep Sampling").performClick()
        compose.onNodeWithText("Finish Sampling (4/19)").performClick()
        compose.onNodeWithText("Finish Anyway").performClick()
        compose.runOnIdle { assertEquals(1, finishes); assertEquals(0, saves); assertEquals(4, seed.recordedSiteCount); assertEquals(15, seed.sampleSites.count { !it.isRecorded }); assertEquals(0.15, seed.bunchWeightKg("block"), 0.0) }
    }
    @Test fun failedSaveKeepsDialogAndSelectionThenConfirmedSaveAdvances() {
        var canSave = false
        var written: Pair<String, Double>? = null
        compose.setContent { MaterialTheme {
            CompositionLocalProvider(LocalYieldMapPreview provides { Text("Map excluded") }) {
                YieldSamplingMapScreen(AppUiState(), seed(), { id, count, _ -> if (canSave) { written = id to count; true } else false }, { _, _ -> false }, {}, {})
            }
        } }
        compose.onNodeWithTag("yield.record.next").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("17")
        compose.onNodeWithTag("yield.record.confirm").performClick()
        compose.onNodeWithText("Sample 5 · Row 5").assertExists()
        compose.runOnIdle { assertNull(written); canSave = true }
        compose.onNodeWithTag("yield.record.confirm").performClick()
        compose.onNodeWithText("Sample 6 · Row 6 · Block").assertExists()
        compose.runOnIdle { assertEquals("site5" to 17.0, written) }
    }
}
