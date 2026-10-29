package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.ui.Alignment
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayStartRateReview
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.model.TractorFuelLog
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.VineyardMachine

/** Operational confirmation used immediately before live spray tracking starts. */
@Composable
fun SprayTripStartConfirmation(
    machineName: String,
    latestEngineHours: Double?,
    tanks: List<SprayTank>,
    scopeKey: String,
    onDismiss: () -> Unit,
    onStart: (Double?) -> Unit,
    modifier: Modifier = Modifier,
) {
    var hoursText by rememberSaveable { mutableStateOf("") }
    val recipeEvidence = SprayStartRateReview.evidence(tanks)
    // Consent is session-local: never restore it after process death or a scope change.
    var confirmedRates by remember(recipeEvidence, scopeKey) { mutableStateOf(false) }
    var showRateHelp by rememberSaveable { mutableStateOf(false) }
    val validRecipe = SprayStartRateReview.isReviewable(tanks)
    val parsedHours = com.rork.vinetrack.data.SprayStartEngineHours.parse(hoursText)
    val validHours = com.rork.vinetrack.data.SprayStartEngineHours.isValid(hoursText)
    AlertDialog(
        modifier = modifier,
        onDismissRequest = onDismiss,
        title = { Text("Start Trip") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Confirm actual chemical rates", modifier = Modifier.weight(1f))
                    IconButton(onClick = { showRateHelp = true }) { Icon(Icons.Outlined.Info, contentDescription = "Actual chemical rates help") }
                }
                SprayStartRateReview.lines(tanks).forEach { Text(it, modifier = Modifier.padding(bottom = 6.dp)) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = confirmedRates, onCheckedChange = { confirmedRates = it }, enabled = validRecipe)
                    Text("I confirm these actual rates")
                }
                if (!validRecipe) Text("Review the chemical rates and tank water before starting.")
                Text("Machine: ${machineName.ifBlank { "Not selected" }}")
                OutlinedTextField(
                    value = hoursText,
                    onValueChange = { hoursText = it },
                    isError = !validHours,
                    supportingText = { if (!validHours) Text("Enter non-negative hours, or leave blank.") },
                    label = { Text("Start engine hours (optional)") },
                    placeholder = { Text(latestEngineHours?.let { "Last recorded ${sprayEngineHoursLabel(it)}" } ?: "hrs") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                )
                if (latestEngineHours != null) Text("Last recorded: ${sprayEngineHoursLabel(latestEngineHours)} hrs")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        confirmButton = { TextButton(enabled = validHours && confirmedRates && validRecipe, onClick = { onStart(parsedHours) }) { Text("Start Trip") } },
    )
    if (showRateHelp) AlertDialog(
        onDismissRequest = { showRateHelp = false },
        title = { Text("Actual chemical rates") },
        text = { Text("Confirm the rates you will actually apply, not just suggested label rates. Per-100 L values show the actual tank concentration, including concentration factor. Go back to Products to change a rate. The confirmed mix is saved with this Trip; later tank actuals remain separate.") },
        confirmButton = { TextButton(onClick = { showRateHelp = false }) { Text("Close") } },
    )
}

private fun sprayEngineHoursLabel(hours: Double): String =
    if (hours % 1.0 == 0.0) hours.toLong().toString() else "%.1f".format(hours)

fun sprayTripMachineName(trip: Trip, machines: List<VineyardMachine>): String =
    trip.machineId?.let { id -> machines.firstOrNull { it.id == id }?.displayName }
        ?: trip.tractorId?.let { id -> machines.firstOrNull { it.legacyTractorId == id || it.id == id }?.displayName }
        ?: "Not selected"

fun latestSprayTripEngineHours(trip: Trip, machines: List<VineyardMachine>, logs: List<TractorFuelLog>): Double? {
    val machine = trip.machineId?.let { id -> machines.firstOrNull { it.id == id } }
        ?: trip.tractorId?.let { id -> machines.firstOrNull { it.legacyTractorId == id || it.id == id } }
    return logs.asSequence()
        .filter { log ->
            log.engineHours?.isFinite() == true && machine != null &&
                (log.machineId == machine.id || (log.machineId == null && log.tractorId == machine.legacyTractorId))
        }
        .maxByOrNull { it.fillEpochMs ?: Long.MIN_VALUE }
        ?.engineHours
}
