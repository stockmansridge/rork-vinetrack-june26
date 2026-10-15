package com.rork.vinetrack.data

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rork.vinetrack.data.chemical.*
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.ui.screens.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Isolated production chemical card and callbacks; no account, network or vineyard writes. */
class SprayChemicalEditorAndroidTest {
    @get:Rule val compose = createComposeRule()
    private val chemical = SavedChemical(id = "editor-fixture", vineyardId = "isolated", name = "Editor fixture", unit = "L")
    private fun line() = CalcChemLine(chemical.id, null, SprayCalculator.RateBasis.PER_100L, 10.0, "L")

    private fun mount(initial: CalcChemLine): () -> CalcChemLine {
        var current = initial
        compose.setContent {
            var edited by remember { mutableStateOf(initial) }
            var shown by remember { mutableStateOf(true) }
            current = edited
            MaterialTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    TextButton(onClick = {
                        edited = CalcChemLine(edited.chemicalId, edited.selectedRateId, edited.basis, edited.rateAmount, edited.rateUnit).also {
                            it.overrideText = edited.overrideText; it.operationalSource = edited.operationalSource
                        }
                        shown = !shown
                    }) { Text("Reopen card") }
                    if (shown) CalcChemicalLineCard(edited, listOf(chemical), {}, {}, {}, {})
                }
            }
        }
        return { current }
    }

    @Test fun dotAndCommaUseTheSamePhysicalRateThroughProductionEditor() {
        val current = mount(line())
        val field = compose.onNodeWithContentDescription("applicationRateField")
        listOf("25,75" to 25.75, "25.75" to 25.75, "0.75" to 0.75,
            "0,75" to 0.75, "1250.5" to 1250.5, "1250,5" to 1250.5).forEach { (raw, expected) ->
            field.performScrollTo().performTextReplacement(raw)
            field.assertTextEquals(raw)
            compose.runOnIdle { assertEquals(expected, effectiveRateDisplay(chemical, current()), 0.000001) }
            field.performImeAction()
            field.assertTextEquals(raw)
            field.performClick()
            compose.onNodeWithText("Reopen card").performScrollTo().performClick()
            compose.onNodeWithText("Reopen card").performClick()
            field.performScrollTo().assertTextEquals(raw)
            compose.runOnIdle { assertEquals(expected, effectiveRateDisplay(chemical, current()), 0.000001) }
        }
    }

    @Test fun invalidNonblankDraftNeverReusesRecommendedOrOperationalDose() {
        val current = mount(line())
        val field = compose.onNodeWithContentDescription("applicationRateField")
        listOf(".", "25,", "25.", "25,7.5", "-2", "0", "NaN", "abc").forEach { raw ->
            field.performScrollTo().performTextReplacement(raw)
            field.assertTextEquals(raw)
            compose.runOnIdle { assertTrue("Unresolved $raw", effectiveRateDisplay(chemical, current()).isNaN()) }
            field.performImeAction()
            field.assertTextEquals(raw)
        }
        field.performTextClearance()
        compose.runOnIdle {
            assertEquals(10.0, effectiveRateDisplay(chemical, current()), 0.0)
            current().operationalSource = OperationalRateResolver.Source.PROGRAM_STEP
            current().overrideText = "25,7.5"
            assertTrue(effectiveRateDisplay(chemical, current()).isNaN())
        }
    }

    @Test fun explicitPresetAndBasisSelectionRetainIdentityWithoutBorrowingDrafts() {
        val use = ChemicalRegisteredUse(crop = "Grapevines", targetRaw = "Mildew", directionId = "direction",
            rates = listOf(ChemicalLabelRate(label = "Label range", basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
                minValue = 10.0, maxValue = 30.0, unit = "L", rateId = "range")))
        val product = chemical.copy(registeredUses = listOf(use))
        val selected = line()
        val rates = SprayRegisteredUseRates.vineyardRates(product)
        val range = rates.first { it.requiresManualRate }
        applySuggestedRate(selected, range)
        assertTrue(effectiveRateDisplay(product, selected).isNaN())
        val preset = rates.first { it.preset == SprayRatePreset.MIDPOINT }
        applySuggestedRate(selected, preset)
        assertEquals(preset.id, selected.selectedRateId)
        assertEquals(20.0, effectiveRateDisplay(product, selected), 0.0)
        selected.overrideText = "25,75"
        assertEquals(25.75, effectiveRateDisplay(product, selected), 0.0)
        val area = preset.copy(id = "explicit-area", basis = SprayCalculator.RateBasis.PER_HECTARE, labelRange = null)
        applySuggestedRate(selected, area)
        assertEquals("", selected.overrideText)
        assertEquals(SprayCalculator.RateBasis.PER_HECTARE, selected.basis)
        assertEquals("explicit-area", selected.selectedRateId)
    }
}
