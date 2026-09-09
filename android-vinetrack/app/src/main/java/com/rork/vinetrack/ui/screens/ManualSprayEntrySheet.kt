package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.rork.vinetrack.data.ManualSprayEntryCoordinator
import com.rork.vinetrack.data.ManualSprayEntryRepository
import com.rork.vinetrack.data.ManualSprayOperationStore
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.ManualSprayBlock
import com.rork.vinetrack.data.model.ManualSprayChemical
import com.rork.vinetrack.data.model.ManualSprayPayload
import com.rork.vinetrack.data.model.ManualSprayPhysicalForm
import com.rork.vinetrack.data.model.ManualSprayTank
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.canManageManualSprays
import com.rork.vinetrack.ui.AppUiState
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ManualSprayEntrySheet(
    state: AppUiState,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!canManageManualSprays(state.currentRole)) {
        AlertDialog(onDismissRequest = onDismiss, confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } }, title = { Text("Manual spray entry unavailable") }, text = { Text("Only Owners, Managers and Supervisors can add completed manual sprays.") })
        return
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val vineyardId = state.selectedVineyardId ?: return
    val coordinator = remember { ManualSprayEntryCoordinator(ManualSprayEntryRepository(SessionStore(context)), ManualSprayOperationStore(context)) }
    var reference by remember { mutableStateOf("") }
    var startUtc by remember { mutableStateOf(Instant.now().minusSeconds(3600).toString()) }
    var endUtc by remember { mutableStateOf(Instant.now().toString()) }
    var tractorId by remember { mutableStateOf<String?>(null) }
    var operatorId by remember { mutableStateOf<String?>(null) }
    var unitId by remember { mutableStateOf<String?>(null) }
    var startHours by remember { mutableStateOf("") }
    var endHours by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }
    var isReviewing by remember { mutableStateOf(false) }
    var isSaving by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val blockIds = remember { mutableStateListOf<String>() }
    val tanks = remember { mutableStateListOf(ManualSprayTank(tankNumber = 1, waterVolumeLitres = 0.0, chemicals = emptyList())) }
    val identity = remember { Triple(UUID.randomUUID().toString(), UUID.randomUUID().toString(), UUID.randomUUID().toString()) }

    fun payload(): ManualSprayPayload = ManualSprayPayload(
        vineyardId = vineyardId, manualEntryId = identity.first, sprayRecordId = identity.second, tripId = identity.third,
        reference = reference, operationType = "Foliar Spray", startUtc = startUtc, endUtc = endUtc,
        vineyardTimeZone = state.seasonZone.id, tractorId = tractorId, operatorUserId = operatorId, sprayEquipmentId = unitId,
        startEngineHours = startHours.toDoubleOrNull(), endEngineHours = endHours.toDoubleOrNull(), notes = notes.takeIf { it.isNotBlank() },
        blocks = state.paddocks.filter { it.id in blockIds }.map { ManualSprayBlock(it.id, it.name) }, tanks = tanks.toList(),
    )

    Dialog(onDismissRequest = onDismiss) {
        Column(modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(if (isReviewing) "Review manual spray" else "Add manual spray")
            if (!isReviewing) {
                OutlinedTextField(reference, { reference = it }, label = { Text("Name or reference") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(startUtc, { startUtc = it }, label = { Text("Start date/time (${state.seasonZone.id})") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(endUtc, { endUtc = it }, label = { Text("End date/time (${state.seasonZone.id})") }, modifier = Modifier.fillMaxWidth())
                ChoiceField("Tractor", tractorId, state.machines.filter { it.isLegacyTractor }.mapNotNull { machine -> machine.legacyTractorId?.let { Triple(it, machine.displayName, it) } }, { tractorId = it })
                ChoiceField("Operator", operatorId, state.members.map { Triple(it.userId, it.name, it.userId) }, { operatorId = it })
                ChoiceField("Spray unit", unitId, state.sprayEquipment.map { Triple(it.id, it.name, it.id) }, { unitId = it })
                OutlinedTextField(startHours, { startHours = it }, label = { Text("Start engine hours (optional)") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(endHours, { endHours = it }, label = { Text("End engine hours (optional)") }, modifier = Modifier.fillMaxWidth())
                Text("Blocks")
                state.paddocks.forEach { block -> Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) { Checkbox(block.id in blockIds, { checked -> if (checked) blockIds.add(block.id) else blockIds.remove(block.id) }); Text(block.name) } }
                tanks.toList().forEachIndexed { index, tank ->
                    Text("Tank ${tank.tankNumber}")
                    OutlinedTextField(tank.waterVolumeLitres.takeIf { it != 0.0 }?.toString().orEmpty(), { value -> tanks[index] = tank.copy(waterVolumeLitres = value.toDoubleOrNull() ?: 0.0) }, label = { Text("Actual water (L)") }, modifier = Modifier.fillMaxWidth())
                    tank.chemicals.forEachIndexed { chemicalIndex, chemical ->
                        Text("${chemical.name} · ${chemical.productCategory} · ${chemical.physicalForm.name}")
                        OutlinedTextField(displayAmount(chemical).toString(), { value -> val updated = chemical.copy(actualAmountBase = toBase(value.toDoubleOrNull() ?: 0.0, chemical.unit)); tanks[index] = tanks[index].copy(chemicals = tanks[index].chemicals.toMutableList().also { it[chemicalIndex] = updated }) }, label = { Text("Actual amount (${chemical.unit})") }, modifier = Modifier.fillMaxWidth())
                    }
                    ChemicalChoice(state.savedChemicals, { product -> tanks[index] = tanks[index].copy(chemicals = tanks[index].chemicals + product.toManualChemical()) })
                    if (index > 0) TextButton(onClick = { tanks.removeAt(index); tanks.indices.forEach { i -> tanks[i] = tanks[i].copy(tankNumber = i + 1) } }) { Text("Remove tank") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { Button(onClick = { tanks += ManualSprayTank(tankNumber = tanks.size + 1, waterVolumeLitres = 0.0, chemicals = emptyList()) }) { Text("Add tank") }; Button(onClick = { tanks.lastOrNull()?.let { tanks += it.copied(tanks.size + 1) } }) { Text("Copy previous") } }
                OutlinedTextField(notes, { notes = it }, label = { Text("Notes (optional)") }, modifier = Modifier.fillMaxWidth())
                Text("Station weather can be retrieved after save. Manual weather remains available when station history is unavailable.")
            } else {
                Text("Completed · Manual entry")
                Text("$reference\n$startUtc — $endUtc\n${blockIds.size} blocks · ${tanks.size} tanks · ${tanks.sumOf { it.waterVolumeLitres }} L")
            }
            message?.let { Text(it) }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = if (isReviewing) ({ isReviewing = false }) else onDismiss) { Text(if (isReviewing) "Back" else "Cancel") }
                Button(enabled = !isSaving, onClick = {
                    val candidate = payload(); val error = candidate.validationError()
                    if (error != null) message = error else if (!isReviewing) isReviewing = true else scope.launch {
                        isSaving = true
                        val response = runCatching { coordinator.save(candidate, 0) }.getOrElse { message = it.message; null }
                        isSaving = false
                        if (response?.serverConfirmed == true) onSaved() else message = "Saved on this device — awaiting sync"
                    }
                }) { Text(if (isReviewing) "Save manual spray" else "Review") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun ChoiceField(label: String, selected: String?, choices: List<Triple<String, String, String>>, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded, { expanded = !expanded }) {
        OutlinedTextField(choices.firstOrNull { it.first == selected }?.second.orEmpty(), {}, readOnly = true, label = { Text(label) }, trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) }, modifier = Modifier.menuAnchor().fillMaxWidth())
        ExposedDropdownMenu(expanded, { expanded = false }) { choices.forEach { choice -> DropdownMenuItem({ Text(choice.second) }, { onSelect(choice.first); expanded = false }) } }
    }
}

@Composable private fun ChemicalChoice(products: List<SavedChemical>, onSelect: (SavedChemical) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    TextButton(onClick = { expanded = true }) { Text("Add chemical from store") }
    DropdownMenu(expanded, { expanded = false }) { products.forEach { product -> DropdownMenuItem({ Text(product.name) }, { onSelect(product); expanded = false }) } }
}

private fun SavedChemical.toManualChemical(): ManualSprayChemical {
    val form = if (productForm.lowercase() == "solid" || unit in setOf("Kg", "g")) ManualSprayPhysicalForm.solid else ManualSprayPhysicalForm.liquid
    return ManualSprayChemical(savedChemicalId = id, name = name, actualAmountBase = 0.0, unit = unit, productCategory = productCategory.ifBlank { use }, physicalForm = form)
}
private fun toBase(value: Double, unit: String): Double = if (unit == "Litres" || unit == "Kg") value * 1000.0 else value
private fun displayAmount(chemical: ManualSprayChemical): Double = if (chemical.unit == "Litres" || chemical.unit == "Kg") chemical.actualAmountBase / 1000.0 else chemical.actualAmountBase
