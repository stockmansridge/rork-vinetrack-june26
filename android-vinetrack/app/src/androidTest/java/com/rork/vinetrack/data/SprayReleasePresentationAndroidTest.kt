package com.rork.vinetrack.data

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.ui.components.SprayPlanningCards
import com.rork.vinetrack.ui.screens.SprayStartActualFields
import com.rork.vinetrack.ui.theme.AppTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Render actual shipping controls at handset width; no account or backend mutations. */
class SprayReleasePresentationAndroidTest {
    @get:Rule val compose = createComposeRule()

    @Test fun lightDefault() = verify(false, 1f)
    @Test fun darkDefault() = verify(true, 1f)
    @Test fun lightLargeText() = verify(false, 1.5f)
    @Test fun darkLargeText() = verify(true, 1.5f)

    private fun verify(dark: Boolean, scale: Float) {
        var retained: Map<String, String> = emptyMap()
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, scale)) {
                AppTheme(darkTheme = dark) {
                    var pass by remember { mutableStateOf<SprayPassConfiguration?>(null) }
                    var draft by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
                    Column(Modifier.width(320.dp).verticalScroll(rememberScrollState()).padding(8.dp)) {
                        SprayPlanningCards(pass, { pass = it }, SprayPlanningMethod.BY_AREA, {},
                            SprayFullTankSpecification.TARGET_AREA, {}, "", {}, "", {}, "", {},
                            RegionFormatter(RegionCountry.Australia.recommendedPreset), null)
                        SprayStartActualFields(listOf(
                            SprayTank("first", waterVolume = 294.7, chemicals = listOf(
                                SprayChemical("product", "Fixture product", volumePerTank = 700.0, ratePerHa = 700.0, unit = "Kg"))),
                            SprayTank("second", tankNumber = 2, waterVolume = 120.0)), draft,
                            { draft = it; retained = it })
                    }
                }
            }
        }
        for (label in listOf("Not Set", "Single Row", "2 Row")) {
            val node = compose.onNodeWithText(label)
            node.performScrollTo().performClick().assertIsSelected()
            val layouts = mutableListOf<TextLayoutResult>()
            compose.onNodeWithText(label, useUnmergedTree = true)
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertTrue("Missing rendered layout: $label", layouts.isNotEmpty())
            assertTrue("Pass label clipped: $label scale=$scale; " + layouts.joinToString { "size=${it.size} width=${it.didOverflowWidth} height=${it.didOverflowHeight} lines=${it.lineCount} bottom=${it.getLineBottom(it.lineCount - 1)} constraints=${it.layoutInput.constraints}" }, layouts.none { it.hasVisualOverflow || it.lineCount != 1 })
        }
        compose.onNodeWithText("Actual water (L)").performScrollTo().assertTextContains("")
        compose.runOnIdle { assertTrue("Calculated amounts must never populate actual drafts", retained.isEmpty()) }
        compose.onNodeWithText("Actual water (L)").performTextInput("300")
        compose.onNodeWithText("Actual Fixture product (Kg)").performScrollTo().performTextInput("0.75")
        compose.runOnIdle {
            assertEquals(mapOf("water" to "300", "chemical:0" to "0.75"), retained)
        }
        compose.onNodeWithText("Enter actual amounts for later tanks when you mix them.").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Water Calculated – 294.7 L", substring = true).performScrollTo().assertIsDisplayed()
    }
}
