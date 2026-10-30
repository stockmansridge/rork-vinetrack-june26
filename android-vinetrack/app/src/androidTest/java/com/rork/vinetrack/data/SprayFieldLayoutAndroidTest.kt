package com.rork.vinetrack.data

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.ui.components.SprayCanopySelector
import com.rork.vinetrack.ui.components.SprayVolumeBasisSelector
import com.rork.vinetrack.ui.screens.TrackingSetupContent
import com.rork.vinetrack.ui.screens.SprayTripStartConfirmation
import com.rork.vinetrack.ui.theme.AppTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Rendered production controls only, no accounts, HTTP, route changes or GPS simulation. */
class SprayFieldLayoutAndroidTest {
    @get:Rule val compose = createComposeRule()

    @Test fun metricNarrowDefaultFont() = verifyLayout(320, 1f, RegionCountry.Australia)
    @Test fun imperialNarrowLargeFont() = verifyLayout(320, 1.5f, RegionCountry.UnitedStates)
    @Test fun metricHandsetLargeFont() = verifyLayout(360, 1.5f, RegionCountry.Australia)
    @Test fun imperialHandsetDefaultFont() = verifyLayout(360, 1f, RegionCountry.UnitedStates)

    private fun verifyLayout(width: Int, scale: Float, country: RegionCountry) {
        val formatter = RegionFormatter(country.recommendedPreset)
        val format = SprayCarrierRegionalFormat(formatter)
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, scale)) {
                AppTheme(darkTheme = false) {
                    var basis by remember { mutableStateOf(SprayCarrierBasis.LITRES_PER_100_METRES) }
                    var canopy by remember { mutableStateOf(SprayCanopySelection().chooseType(SprayCalculator.CanopyType.VSP)) }
                    var pattern by remember { mutableStateOf(TrackingPattern.FREE_DRIVE) }
                    Column(Modifier.width(width.dp).verticalScroll(rememberScrollState()).padding(16.dp)) {
                        SprayVolumeBasisSelector(SprayCarrierBasis.entries, basis, format, { basis = it })
                        SprayCanopySelector(canopy, CanopyWaterRates(), formatter, false,
                            onSelectionChange = { canopy = it }, onConfirm = {})
                        TrackingSetupContent(pattern, { pattern = it }, false, emptyList(), null, {}, true, {}, emptyList(), emptyList())
                    }
                }
            }
        }
        val areaLabel = format.carrierBasisLabel(SprayCarrierBasis.LITRES_PER_HECTARE)
        compose.onNodeWithText("Total water").performScrollTo().assertHeightIsAtLeast(48.dp).performClick().assertIsSelected()
        compose.onNodeWithText(areaLabel).performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithText("Total water").assertIsNotSelected()
        for (label in listOf("Total water", areaLabel, format.carrierBasisLabel(SprayCarrierBasis.LITRES_PER_100_METRES))) {
            assertTextNotClipped(label)
        }
        compose.onNodeWithText("Small").performScrollTo().performClick().assertIsSelected()
        val small = compose.onNodeWithText("Small").captureToImage().toPixelMap()
        val medium = compose.onNodeWithText("Medium").captureToImage().toPixelMap()
        assertNotEquals("Selected canopy needs a different container, not just a tick", small[small.width / 2, 6], medium[medium.width / 2, 6])
        compose.onNodeWithText("Full").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithText("Small").assertIsNotSelected()
        for (label in listOf("Small", "Medium", "Large", "Full")) assertTextNotClipped(label)
        for (pattern in TrackingPattern.entries) {
            compose.onNodeWithText(pattern.title).performScrollTo().assertHeightIsAtLeast(48.dp).performClick().assertIsSelected()
            assertTextNotClipped(pattern.title)
            assertTextNotClipped(pattern.subtitle)
        }
    }

    private fun assertTextNotClipped(text: String) {
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(text, useUnmergedTree = true).performScrollTo().performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue("Missing rendered text layout: $text", layouts.isNotEmpty())
        assertTrue("Clipped text: $text; " + layouts.joinToString { "size=${it.size} widthOverflow=${it.didOverflowWidth} heightOverflow=${it.didOverflowHeight} lines=${it.lineCount} lastBottom=${it.getLineBottom(it.lineCount - 1)} font=${it.layoutInput.style.fontSize} maxLines=${it.layoutInput.maxLines} constraints=${it.layoutInput.constraints}" }, layouts.none { it.hasVisualOverflow })
    }

    @Test fun consentIsInvalidatedByScopeAndRecipeChanges() {
        val scope = mutableStateOf("block-A|geometry-A|route-A")
        val water = mutableStateOf(1000.0)
        var launches = 0
        compose.setContent {
            AppTheme {
                SprayTripStartConfirmation(
                    machineName = "Fixture tractor", latestEngineHours = null,
                    tanks = listOf(com.rork.vinetrack.data.model.SprayTank("tank", waterVolume = water.value,
                        chemicals = listOf(com.rork.vinetrack.data.model.SprayChemical("product", "Product",
                            volumePerTank = 1000.0, ratePerHa = 1000.0)))),
                    scopeKey = "actor|vineyard|trip", scopeEvidence = scope.value,
                    onDismiss = {}, onStart = { launches++ },
                )
            }
        }
        val start = compose.onNode(hasText("Start Trip") and hasClickAction())
        start.assertIsNotEnabled()
        compose.onNode(isToggleable()).performScrollTo().performClick()
        start.assertIsEnabled()
        // Identical tank quantities must not carry consent to another block/route.
        compose.runOnIdle { scope.value = "block-B|geometry-B|route-B" }
        start.assertIsNotEnabled()
        compose.onNode(isToggleable()).performScrollTo().performClick()
        start.assertIsEnabled()
        compose.runOnIdle { water.value = 900.0 }
        start.assertIsNotEnabled()
        compose.onNode(isToggleable()).performScrollTo().performClick()
        start.performClick()
        compose.runOnIdle { assertEquals(1, launches) }
    }

    @Test fun engineHoursBlankAndEnteredCallbacksAndInvalidInput() {
        var launches = 0
        var hours: Double? = -1.0
        compose.setContent {
            var visible by remember { mutableStateOf(true) }
            AppTheme {
                if (visible) SprayTripStartConfirmation(
                    machineName = "Fixture tractor", latestEngineHours = null,
                    tanks = listOf(com.rork.vinetrack.data.model.SprayTank("tank", waterVolume = 1000.0,
                        chemicals = listOf(com.rork.vinetrack.data.model.SprayChemical("product", "Product",
                            volumePerTank = 1000.0, ratePerHa = 1000.0)))),
                    scopeKey = "isolated-layout-fixture", onDismiss = {},
                    onStart = { launches++; hours = it },
                )
            }
        }
        compose.onNode(hasText("Start Trip") and hasClickAction()).assertIsNotEnabled()
        compose.onNode(isToggleable()).performScrollTo().performClick()
        compose.onNode(hasText("Start Trip") and hasClickAction()).performClick()
        compose.runOnIdle { assertEquals(1, launches); assertNull(hours) }
        compose.onNodeWithText("Start engine hours (optional)").performTextInput("123.5")
        compose.onNode(hasText("Start Trip") and hasClickAction()).performClick()
        compose.runOnIdle { assertEquals(2, launches); assertEquals(123.5, hours!!, 0.0) }
        compose.onNodeWithText("Start engine hours (optional)").performTextReplacement("-1")
        compose.onNode(hasText("Start Trip") and hasClickAction()).assertIsNotEnabled()
        compose.runOnIdle { assertEquals(2, launches) }
    }
}
