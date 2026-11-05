package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.PanelCountMeasurement
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.ui.theme.VineColors

/** Post-to-post panel observations. No guessed zero for skipped sites, no
 * conversion to per-vine count, and never an implicit active Yield Estimate.
 */
@Composable
internal fun PanelCountDialog(
    site: SampleSite,
    saveLabel: String = "Record Panel",
    onDismiss: () -> Unit,
    onSave: (PanelCountMeasurement) -> Boolean,
) {
    val prior = site.panelCountEntry?.measurement
    var total by rememberSaveable(site.id, "total") { mutableStateOf(prior?.totalBunches?.toString() ?: "") }
    var planted by rememberSaveable(site.id, "planted") { mutableStateOf(prior?.plantedPositions?.toString() ?: "") }
    var fruiting by rememberSaveable(site.id, "fruiting") { mutableStateOf(prior?.fruitingVines?.toString() ?: "") }
    var missing by rememberSaveable(site.id, "missing") { mutableStateOf(prior?.missingPositions?.toString() ?: "") }
    var nonproductive by rememberSaveable(site.id, "nonproductive") { mutableStateOf(prior?.nonproductiveVines?.toString() ?: "") }
    var panelLength by rememberSaveable(site.id, "length") { mutableStateOf(prior?.panelLengthMetres?.toString() ?: "") }
    var saveFailed by rememberSaveable(site.id, "failed") { mutableStateOf(false) }
    val optionalLength = if (panelLength.isBlank()) null else panelLength.replace(',', '.').toDoubleOrNull()
    val measurement = if (panelLength.isNotBlank() && optionalLength == null) null else {
        val t = total.toIntOrNull()
        val p = planted.toIntOrNull()
        val f = fruiting.toIntOrNull()
        val m = missing.toIntOrNull()
        val n = nonproductive.toIntOrNull()
        if (t == null || p == null || f == null || m == null || n == null) null
        else PanelCountMeasurement.make(t, p, f, m, n, optionalLength)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Panel Count · Sample ${site.siteIndex}") },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 450.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("Count all bunches between two posts. Include missing and nonproductive planting positions in the panel total.",
                    fontSize = 13.sp)
                Text(site.paddockName + (site.yieldRowReference?.let { " · Row $it" } ?: "") +
                    (site.yieldPanelReference?.let { " · Panel $it" } ?: ""), fontSize = 13.sp)
                @Composable
                fun integerField(label: String, value: String, change: (String) -> Unit) {
                    OutlinedTextField(
                        value = value,
                        onValueChange = { change(it.filter(Char::isDigit)) },
                        label = { Text(label) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                integerField("Total bunches counted", total) { total = it }
                integerField("Planted positions, including missing", planted) { planted = it }
                integerField("Fruiting vines counted", fruiting) { fruiting = it }
                integerField("Missing positions", missing) { missing = it }
                integerField("Nonproductive vines", nonproductive) { nonproductive = it }
                OutlinedTextField(
                    value = panelLength,
                    onValueChange = { panelLength = it.filter { ch -> ch.isDigit() || ch == '.' || ch == ',' } },
                    label = { Text("Panel length (metres, optional)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (measurement == null) {
                    Text("Total planted positions must equal fruiting + missing + nonproductive. Enter whole numbers and at least one planted position.",
                        color = VineColors.Orange, fontSize = 12.sp)
                } else {
                    Text("${"%.2f".format(measurement.bunchesPerPlantingPosition)} bunches per planted position",
                        color = VineColors.LeafGreen, fontSize = 13.sp)
                }
                Text("This raw observation does not automatically replace the current Yield Estimate.",
                    fontSize = 12.sp)
                if (saveFailed) Text("The panel count could not be saved. Your form is unchanged; retry.",
                    color = VineColors.Destructive, fontSize = 12.sp)
            }
        },
        confirmButton = {
            TextButton(
                enabled = measurement != null,
                modifier = Modifier.testTag("yield.panel.record"),
                onClick = { measurement?.let { if (!onSave(it)) saveFailed = true } },
            ) { Text(saveLabel) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
