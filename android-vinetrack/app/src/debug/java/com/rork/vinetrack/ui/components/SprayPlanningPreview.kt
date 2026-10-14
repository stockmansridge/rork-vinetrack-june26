package com.rork.vinetrack.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.spray.SprayFullTankSpecification
import com.rork.vinetrack.data.spray.SprayPassConfiguration
import com.rork.vinetrack.data.spray.SprayPlanningIntent
import com.rork.vinetrack.data.spray.SprayPlanningMethod

/** Synthetic production-card previews only; no account, store or transport is created. */
@Composable
private fun SprayPlanningPreview(configuration: SprayPassConfiguration, specification: SprayFullTankSpecification, modifier: Modifier = Modifier) {
    val intent = SprayPlanningIntent(configuration, SprayPlanningMethod.FULL_TANK, specification,
        intendedTankLitres = 1500.0,
        targetAreaHa = if (specification == SprayFullTankSpecification.TARGET_AREA) 3.0 else null,
        calibratedLitresPerHectare = if (specification == SprayFullTankSpecification.CALIBRATED_RATE) 500.0 else null)
    MaterialTheme {
        Surface {
            Column(modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Spray Calculator", style = MaterialTheme.typography.titleLarge)
                Text("SYNTHETIC UI PREVIEW • NOT DEVICE ACCEPTANCE", style = MaterialTheme.typography.labelSmall)
                Text("Application volume basis: L/100m controller travel")
                SprayPlanningCards(configuration, {}, SprayPlanningMethod.FULL_TANK, {}, specification, {},
                    "1500", {}, "3", {}, if (configuration == SprayPassConfiguration.STANDARD_PASS) "14" else "28", {},
                    RegionFormatter(), intent.resolve(10.0, 2.8, 500.0), rateUnit = "L/100m", rowSpacingMetres = 2.8)
                SprayConcentrationWarning(listOf("Synthetic sulphur"))
            }
        }
    }
}

@Preview(name = "Single Row • 1500 L / 3 ha", widthDp = 412, heightDp = 1100, showBackground = true)
@Composable
private fun StandardPassPreview() = SprayPlanningPreview(SprayPassConfiguration.STANDARD_PASS, SprayFullTankSpecification.TARGET_AREA)

@Preview(name = "Over-Row • 1500 L / 3 ha", widthDp = 412, heightDp = 1100, showBackground = true)
@Composable
private fun OverRowPreview() = SprayPlanningPreview(SprayPassConfiguration.OVER_ROW, SprayFullTankSpecification.TARGET_AREA)

@Preview(name = "Over-Row • selected L/100m", widthDp = 412, heightDp = 1100, showBackground = true)
@Composable
private fun ControllerRatePreview() = SprayPlanningPreview(SprayPassConfiguration.OVER_ROW, SprayFullTankSpecification.CALIBRATED_RATE)
