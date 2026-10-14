package com.rork.vinetrack.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.spray.*

/** Inline planning controls; no new screen or second chemical engine. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayPlanningCards(
    configuration: SprayPassConfiguration?, onConfiguration: (SprayPassConfiguration) -> Unit,
    method: SprayPlanningMethod, onMethod: (SprayPlanningMethod) -> Unit,
    specification: SprayFullTankSpecification, onSpecification: (SprayFullTankSpecification) -> Unit,
    tankText: String, onTank: (String) -> Unit, areaText: String, onArea: (String) -> Unit,
    rateText: String, onRate: (String) -> Unit, region: RegionFormatter,
    resolution: SprayPlanningResolution?, modifier: Modifier = Modifier,
    rateUnit: String = region.volumePerAreaUnit, rowSpacingMetres: Double? = null,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp)) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Sprayer configuration", fontWeight = FontWeight.SemiBold)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SprayPassConfiguration.entries.forEachIndexed { index, pass ->
                        SegmentedButton(selected = configuration == pass, onClick = { onConfiguration(pass) },
                            shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(pass.title) }
                    }
                }
                if (configuration != null) {
                    SprayPassIllustration(configuration)
                    Text(if (configuration == SprayPassConfiguration.STANDARD_PASS)
                        "Two adjacent half-row faces: one complete-row equivalent per pass."
                        else "Both sides of two complete vine rows per pass.", style = MaterialTheme.typography.bodySmall)
                } else Text("Choose the configuration. Historical configuration is not assumed.", style = MaterialTheme.typography.bodySmall)
                rowSpacingMetres?.let { Text("Vineyard row spacing: ${region.formatLength(it)}") }
                resolution?.effectiveWorkingWidthMetres?.let { Text("Effective working width: ${region.formatLength(it)}") }
                resolution?.controllerLitresPer100mTravel?.let { Text("Controller application: ${region.formatVolumePer100Length(it)}") }
                Text("Physical row spacing stays unchanged. Controller travel and physical vine-row rates are different measures.", style = MaterialTheme.typography.bodySmall)
            }
        }
        Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp)) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Plan spray volume", fontWeight = FontWeight.SemiBold)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SprayPlanningMethod.entries.forEachIndexed { index, option ->
                        SegmentedButton(selected = method == option, onClick = { onMethod(option) },
                            shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(option.title) }
                    }
                }
                if (method == SprayPlanningMethod.FULL_TANK) {
                    PlanningField("Intended tank volume (${region.volumeUnitAbbreviation})", tankText, onTank)
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        SprayFullTankSpecification.entries.forEachIndexed { index, option ->
                            SegmentedButton(selected = specification == option, onClick = { onSpecification(option) },
                                shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(option.title) }
                        }
                    }
                    if (specification == SprayFullTankSpecification.TARGET_AREA)
                        PlanningField("Planned area (${region.areaUnitAbbreviation})", areaText, onArea)
                    else PlanningField("Calibrated rate ($rateUnit)", rateText, onRate)
                    Text("Planned area only. Actual block/row coverage is recorded during the Trip; no partial-block allocation is assumed.", style = MaterialTheme.typography.bodySmall)
                } else Text("Use selected block area and the spray-volume decision below.", style = MaterialTheme.typography.bodySmall)
                if (resolution != null) {
                    Text("Planned area: ${region.formatArea(resolution.plannedAreaHa)}")
                    Text("Intended water: ${region.formatVolume(resolution.intendedLitres)}")
                    Text("Application rate: ${region.formatVolumePerArea(resolution.litresPerHectare)}")
                    resolution.physicalRowLitresPer100m?.let { Text("Physical vine row: ${region.formatVolumePer100Length(it)}") }
                    resolution.controllerLitresPer100mTravel?.let { Text("Controller travel: ${region.formatVolumePer100Length(it)}") }
                    Text("CF ${String.format(java.util.Locale.US, "%.2f", resolution.concentrationFactor)}× — calculation only, not label approval.", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                } else if (method == SprayPlanningMethod.FULL_TANK) {
                    Text("Confirm canopy/configuration; enter positive volume and area/rate within the selected blocks.", style = MaterialTheme.typography.bodySmall)
                }
                Text(SprayPlanningOperationalGate.MIGRATION_MESSAGE, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun PlanningField(title: String, value: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    OutlinedTextField(value, onChange, label = { Text(title) }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() }),
        modifier = modifier.fillMaxWidth())
}

@Composable
private fun SprayPassIllustration(configuration: SprayPassConfiguration, modifier: Modifier = Modifier) {
    Canvas(modifier.fillMaxWidth().height(106.dp).semantics {
        contentDescription = if (configuration == SprayPassConfiguration.STANDARD_PASS)
            "Standard sprayer between two rows, treating adjacent half faces"
        else "Over-row boom with four heads treating both sides of two rows"
    }) {
        val over = configuration == SprayPassConfiguration.OVER_ROW
        val rows = if (over) listOf(0.33f, 0.67f) else listOf(0.18f, 0.82f)
        rows.forEach { x ->
            drawRoundRect(Color(0xFF4E783C), Offset(size.width * x - 9.dp.toPx(), 43.dp.toPx()), Size(18.dp.toPx(), 42.dp.toPx()), CornerRadius(7.dp.toPx()))
            drawLine(Color(0xFF806040), Offset(size.width * x, 76.dp.toPx()), Offset(size.width * x, 96.dp.toPx()), 3.dp.toPx())
        }
        drawRoundRect(Color.Gray, Offset(size.width * 0.5f - 16.dp.toPx(), 51.dp.toPx()), Size(32.dp.toPx(), 32.dp.toPx()), CornerRadius(6.dp.toPx()))
        if (over) {
            drawLine(Color.Gray, Offset(size.width * .23f, 58.dp.toPx()), Offset(size.width * .23f, 24.dp.toPx()), 5.dp.toPx())
            drawLine(Color.Gray, Offset(size.width * .23f, 24.dp.toPx()), Offset(size.width * .77f, 24.dp.toPx()), 5.dp.toPx())
            drawLine(Color.Gray, Offset(size.width * .77f, 24.dp.toPx()), Offset(size.width * .77f, 58.dp.toPx()), 5.dp.toPx())
        }
        val heads = if (over) listOf(.23f, .43f, .57f, .77f) else listOf(.42f, .58f)
        heads.forEachIndexed { index, x ->
            val end = if (over) (if (index < 2) .33f else .67f) else (if (index == 0) .22f else .78f)
            drawLine(Color(0xFF35A7BA), Offset(size.width * x, 61.dp.toPx()), Offset(size.width * end, 61.dp.toPx()), 3.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())))
            drawCircle(Color(0xFF35A7BA), 4.dp.toPx(), Offset(size.width * x, 61.dp.toPx()))
        }
    }
}
