package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
    onStart: (Double?, com.rork.vinetrack.data.spray.SprayStartActualAmounts) -> Unit,
    modifier: Modifier = Modifier,
    scopeEvidence: Any? = null,
    initialDraft: Map<String, String> = emptyMap(),
    onDraftChange: (Map<String, String>) -> Boolean = { true },
    showActualFields: Boolean = true,
    busy: Boolean = false,
    errorMessage: String? = null,
) {
    var hoursText by rememberSaveable { mutableStateOf("") }
    val recipeEvidence = SprayStartRateReview.evidence(tanks)
    val region = com.rork.vinetrack.ui.LocalRegionFormatter.current
    var actualDraft by remember(recipeEvidence, scopeKey, region.settings, java.util.Locale.getDefault()) { mutableStateOf(initialDraft) }
    var draftSaved by remember(recipeEvidence, scopeKey, region.settings, java.util.Locale.getDefault()) { mutableStateOf(true) }
    val actuals = com.rork.vinetrack.data.spray.SprayStartActualAmounts.parse(tanks, actualDraft, region::volumeToCanonical)
    val validRecipe = SprayStartRateReview.isReviewable(tanks)
    val parsedHours = com.rork.vinetrack.data.SprayStartEngineHours.parse(hoursText)
    val validHours = com.rork.vinetrack.data.SprayStartEngineHours.isValid(hoursText)
    AlertDialog(
        modifier = modifier,
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("Start Trip") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (showActualFields) SprayStartActualFields(tanks, actualDraft, onDraftChange = {
                    actualDraft = it
                    draftSaved = onDraftChange(it)
                }, enabled = !busy) else {
                    Text("The actual amounts entered for Tank 1 will be recorded with this spray.")
                }
                if (!draftSaved) Text("Actual amounts could not be retained on this device. Retry before starting.")
                if (!validRecipe) Text("Review the calculated chemical mix before starting.")
                if (actuals == null) Text("Enter actual water and every chemical amount for this tank.")
                errorMessage?.let { Text(it) }
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
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                )
                if (latestEngineHours != null) Text("Last recorded: ${sprayEngineHoursLabel(latestEngineHours)} hrs")
            }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("Cancel") } },
        confirmButton = { TextButton(enabled = !busy && validHours && draftSaved && actuals != null && validRecipe,
            onClick = { actuals?.let { onStart(parsedHours, it) } }) { Text(if (busy) "Starting…" else "Start Trip") } },
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
