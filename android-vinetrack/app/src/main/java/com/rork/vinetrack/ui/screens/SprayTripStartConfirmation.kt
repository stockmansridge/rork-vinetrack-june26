package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
    onDismiss: () -> Unit,
    onStart: (Double?) -> Unit,
    modifier: Modifier = Modifier,
) {
    var hoursText by remember { mutableStateOf("") }
    val parsedHours = hoursText.trim().replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }
    AlertDialog(
        modifier = modifier,
        onDismissRequest = onDismiss,
        title = { Text("Start Trip") },
        text = {
            Column {
                Text("Machine: ${machineName.ifBlank { "Not selected" }}")
                OutlinedTextField(
                    value = hoursText,
                    onValueChange = { hoursText = it.filter { char -> char.isDigit() || char == '.' || char == ',' } },
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
        confirmButton = { TextButton(onClick = { onStart(parsedHours) }) { Text("Start Trip") } },
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
