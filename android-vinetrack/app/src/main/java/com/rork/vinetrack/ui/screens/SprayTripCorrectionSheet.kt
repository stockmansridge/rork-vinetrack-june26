package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.reporting.SprayReportPayloadV1
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.rememberGuardedSheetState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayTripCorrectionSheet(
    vm: AppViewModel,
    state: AppUiState,
    report: SprayReportPayloadV1,
    onDismiss: () -> Unit,
    onSaved: (SprayReportPayloadV1) -> Unit,
    modifier: Modifier = Modifier,
) {
    var machineId by remember(report) { mutableStateOf(report.equipment.machineId) }
    var sprayEquipmentId by remember(report) { mutableStateOf(report.equipment.sprayEquipmentId) }
    var fuel by remember(report) { mutableStateOf(report.equipment.fuelConsumptionLPerHour?.toString().orEmpty()) }
    var start by remember(report) { mutableStateOf(report.equipment.startEngineHours?.toString().orEmpty()) }
    var end by remember(report) { mutableStateOf(report.equipment.endEngineHours?.toString().orEmpty()) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun number(value: String): Double? = value.trim().replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() }
    val fuelValue = number(fuel)
    val startValue = number(start)
    val endValue = number(end)
    val validation = when {
        fuel.isNotBlank() && (fuelValue == null || fuelValue <= 0 || fuelValue >= 1000) -> "Fuel use must be greater than 0 and below 1000 L/hr."
        start.isNotBlank() && (startValue == null || startValue < 0) -> "Enter valid start engine hours."
        end.isNotBlank() && (endValue == null || endValue < 0) -> "Enter valid end engine hours."
        startValue != null && endValue != null && endValue < startValue -> "End engine hours cannot be lower than start engine hours."
        else -> null
    }

    ModalBottomSheet(onDismissRequest = { if (!saving) onDismiss() }, sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)) {
        Column(
            modifier = modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Correct equipment & fuel", fontWeight = FontWeight.Bold)
            Text("Machine", fontWeight = FontWeight.SemiBold)
            ChoiceRow("Not recorded", machineId == null) { machineId = null }
            state.machines.filter { it.vineyardId == report.identity.vineyardId }.forEach { machine ->
                ChoiceRow(machine.displayName, machineId == machine.id) { machineId = machine.id }
            }
            Text("Spray unit", fontWeight = FontWeight.SemiBold)
            ChoiceRow("Not recorded", sprayEquipmentId == null) { sprayEquipmentId = null }
            state.sprayEquipment.filter { it.vineyardId == report.identity.vineyardId }.forEach { unit ->
                ChoiceRow(unit.displayName, sprayEquipmentId == unit.id) { sprayEquipmentId = unit.id }
            }
            NumberField("Fuel use (L/hr)", fuel) { fuel = it }
            NumberField("Start engine hours", start) { start = it }
            NumberField("End engine hours", end) { end = it }
            Text(error ?: validation ?: "Saving creates an audited correction. Blank means not recorded.")
            Button(
                onClick = {
                    saving = true
                    error = null
                    vm.correctSprayTripMetadata(
                        report.identity.tripId, report.metadataCorrectionVersion, machineId,
                        report.equipment.tractorId, sprayEquipmentId, report.trip.operatorId,
                        fuelValue, startValue, endValue,
                    ) { result ->
                        saving = false
                        result.onSuccess(onSaved).onFailure { error = "The correction could not be saved. Refresh and try again." }
                    }
                },
                enabled = !saving && validation == null,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (saving) CircularProgressIndicator() else Text("Save correction")
            }
        }
    }
}

@Composable
private fun ChoiceRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Text(label)
    }
}

@Composable
private fun NumberField(label: String, value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = { onChange(it.filter { char -> char.isDigit() || char == '.' || char == ',' }) },
        label = { Text(label) },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
}
