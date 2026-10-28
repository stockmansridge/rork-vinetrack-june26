package com.rork.vinetrack.data

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.ui.components.*
import com.rork.vinetrack.ui.theme.AppTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Production controls with local state, no authentication bypass or operational writes. */
class MobileSprayUXParityAndroidTest {
    @get:Rule val compose = createComposeRule()

    @Test fun fullHeaderRespondsOnceAndBodyDoesNotToggle() {
        var toggles = 0
        compose.setContent {
            AppTheme {
                var expanded by remember { mutableStateOf(false) }
                GuidedStepCard(SprayGuidedStep.APPLICATION, 1, false, true, expanded, "Ready", Color.Green, Color.Green,
                    onToggle = { toggles++; expanded = !expanded }) {
                    Text("Application body")
                }
            }
        }
        val header = compose.onNode(hasText("Application") and hasClickAction())
        for (x in listOf(0.75f, 0.08f, 0.35f, 0.95f)) {
            header.performTouchInput { click(Offset(width * x, height * 0.2f)) }
            compose.onNodeWithText("Application body").assertIsDisplayed()
            compose.onNodeWithText("Application body").performTouchInput { click() }
            compose.onNodeWithText("Application body").assertIsDisplayed()
            header.performClick()
            compose.onNodeWithText("Application body").assertDoesNotExist()
        }
        compose.runOnIdle { assertEquals(8, toggles) }
    }

    @Test fun stablePassChoicesRoundTripAndFullTankInputRetention() {
        var selected: SprayPassConfiguration? = null
        compose.setContent {
            AppTheme {
                var pass by remember { mutableStateOf<SprayPassConfiguration?>(null) }
                var method by remember { mutableStateOf(SprayPlanningMethod.FULL_TANK) }
                var tank by remember { mutableStateOf("600") }
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    SprayPlanningCards(pass, { pass = it; selected = it }, method, { method = it },
                        SprayFullTankSpecification.TARGET_AREA, {}, tank, { tank = it }, "1", {}, "600", {},
                        RegionFormatter(RegionCountry.Australia.recommendedPreset), null)
                }
            }
        }
        for ((label, expected) in listOf("Single Row" to SprayPassConfiguration.STANDARD_PASS, "Over-Row" to SprayPassConfiguration.OVER_ROW, "Not Set" to null)) {
            compose.onNodeWithText(label).performScrollTo().performClick().assertIsSelected()
            for (stable in listOf("Not Set", "Single Row", "Over-Row")) compose.onNodeWithText(stable).assertExists()
            compose.runOnIdle { assertEquals(expected, selected) }
        }
        compose.onNodeWithText(LegacySpraySetup.FULL_TANK_MESSAGE).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("By Area").performScrollTo().performClick()
        compose.onNodeWithText("Calculate the spray using the selected block area.").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Only Full Tanks").performScrollTo().performClick()
        compose.onNodeWithText("600").assertExists()
    }

    @Test fun canopyMissingActionAndSelectedValueConfirmation() {
        var finalSelection = SprayCanopySelection.unconfirmed
        compose.setContent {
            AppTheme {
                var selection by remember { mutableStateOf(SprayCanopySelection.unconfirmed) }
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    if (!selection.isConfirmed) {
                        Text(selection.confirmationTitle)
                        Text(selection.confirmationMessage)
                    }
                    SprayCanopySelector(selection, CanopyWaterRates(), RegionFormatter(RegionCountry.Australia.recommendedPreset), selection.isConfirmed,
                        onSelectionChange = { selection = it; finalSelection = it },
                        onConfirm = { selection = selection.confirm(); finalSelection = selection })
                    if (selection.isConfirmed) Text("Spray at the recommended volume?")
                }
            }
        }
        compose.onNodeWithText("Choose canopy type").assertExists()
        compose.onNodeWithText("VSP").performScrollTo().performClick()
        compose.onNodeWithText("Confirm canopy").assertExists()
        compose.onNodeWithText("You selected VSP · Medium · Low. Confirm this canopy to calculate the recommended spray volume.").assertExists()
        compose.runOnIdle { assertFalse(finalSelection.isConfirmed) }
        compose.onNodeWithText("Confirm Canopy — VSP · Medium · Low").performScrollTo().performClick()
        compose.onNodeWithText("Spray at the recommended volume?").assertExists()
        compose.runOnIdle { assertTrue(finalSelection.isConfirmed) }
    }
}
