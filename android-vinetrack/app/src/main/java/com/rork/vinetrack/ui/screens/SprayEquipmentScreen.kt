package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.SprayEquipmentRepository
import com.rork.vinetrack.data.model.SprayEquipment
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Brand colour for spray equipment (matches the Spray Management hub row). */
private val EquipmentTint: Color = VineColors.EarthBrown

/**
 * Spray rigs & tanks — asset-register items used for spray applications. Mirrors
 * the iOS `SprayEquipmentManagementView`: owners/managers can add, edit, and
 * archive equipment; other members get a read-only list. Tank capacity is not a
 * financial field, so it is shown to everyone. Only `name` + `tankCapacityLitres`
 * are surfaced, matching the iOS form.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayEquipmentScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"

    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<SprayEquipment?>(null) }
    var pendingDelete by remember { mutableStateOf<SprayEquipment?>(null) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Spray Rigs & Tanks") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = EquipmentTint,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add equipment") }
            }
        },
    ) { padding ->
        if (state.sprayEquipment.isEmpty()) {
            EmptyState(
                icon = Icons.Filled.Build,
                title = "No Spray Rigs",
                message = if (canManage) {
                    "Add your spray rigs and tanks for spray planning."
                } else {
                    "No spray rigs or tanks have been added yet."
                },
                actionLabel = if (canManage) "Add equipment" else null,
                onAction = if (canManage) ({ creating = true }) else null,
                modifier = Modifier.fillMaxSize().padding(padding),
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (!canManage) {
                    item(key = "locked-note") {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Filled.Lock, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(14.dp))
                            Text(
                                "Spray rigs and tanks are managed by vineyard owners and managers.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
                items(state.sprayEquipment, key = { it.id }) { equipment ->
                    SprayEquipmentRow(
                        equipment = equipment,
                        canManage = canManage,
                        onEdit = { if (canManage) editing = equipment },
                        onDelete = { if (canManage) pendingDelete = equipment },
                    )
                }
                item(key = "footer-note") {
                    Text(
                        "Spray rigs and tanks used for spray applications. Not used for Fuel Log or machine fuel costing.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
    }

    if (creating) {
        SprayEquipmentFormSheet(vm = vm, existing = null, onDismiss = { creating = false })
    }
    editing?.let { equipment ->
        SprayEquipmentFormSheet(vm = vm, existing = equipment, onDismiss = { editing = null })
    }
    pendingDelete?.let { equipment ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Archive equipment?") },
            text = { Text("\"${equipment.displayName}\" will no longer be available for new spray records. Existing records that used it are unaffected.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteSprayEquipment(equipment.id) {}
                    pendingDelete = null
                }) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SprayEquipmentRow(
    equipment: SprayEquipment,
    canManage: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = if (canManage) Modifier.clickable { onEdit() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(equipment.displayName, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp)
                val capacity = equipment.tankCapacityLitres
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Filled.WaterDrop, contentDescription = null, tint = EquipmentTint, modifier = Modifier.size(13.dp))
                    Text(
                        if (capacity != null && capacity > 0) "${trimCapacity(capacity)} L tank" else "No tank capacity set",
                        fontSize = 13.sp,
                        color = if (capacity != null && capacity > 0) EquipmentTint else vine.textSecondary,
                        fontWeight = FontWeight.Medium,
                    )
                }
                val ids = listOfNotNull(
                    equipment.serialNumber?.trim()?.takeIf { it.isNotEmpty() }?.let { "S/N $it" },
                    equipment.vinNumber?.trim()?.takeIf { it.isNotEmpty() }?.let { "VIN $it" },
                ).joinToString(" · ")
                if (ids.isNotEmpty()) Text(ids, color = vine.textSecondary, fontSize = 12.sp)
            }
            if (canManage) {
                IconButton(onClick = onDelete) {
                    Icon(Icons.Filled.Delete, contentDescription = "Archive equipment", tint = VineColors.Destructive, modifier = Modifier.size(20.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayEquipmentFormSheet(
    vm: AppViewModel,
    existing: SprayEquipment?,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val isEdit = existing != null

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var capacity by remember {
        mutableStateOf(existing?.tankCapacityLitres?.takeIf { it > 0 }?.let { trimCapacity(it) } ?: "")
    }
    var serial by remember { mutableStateOf(existing?.serialNumber ?: "") }
    var vin by remember { mutableStateOf(existing?.vinNumber ?: "") }
    var saving by remember { mutableStateOf(false) }

    fun save() {
        if (saving) return
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return
        saving = true
        val input = SprayEquipmentRepository.EquipmentInput(
            name = trimmedName,
            tankCapacityLitres = capacity.toCapacityDouble() ?: 0.0,
            serialNumber = serial.trim().takeIf { it.isNotEmpty() },
            vinNumber = vin.trim().takeIf { it.isNotEmpty() },
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (isEdit) vm.updateSprayEquipment(existing!!.id, input, cb) else vm.createSprayEquipment(input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (isEdit) "Edit equipment" else "New equipment",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Equipment name") },
                placeholder = { Text("e.g. Main sprayer") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = capacity,
                onValueChange = { capacity = it.numericFilterCapacity() },
                label = { Text("Tank capacity (litres, optional)") },
                placeholder = { Text("e.g. 400") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = serial,
                onValueChange = { serial = it },
                label = { Text("Serial number (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = vin,
                onValueChange = { vin = it },
                label = { Text("VIN number (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Spray rigs and tanks used for spray applications. Tank capacity prefills tank volumes in spray records.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
            Spacer(Modifier.height(4.dp))
            Button(
                onClick = { save() },
                enabled = !saving && name.trim().isNotEmpty(),
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (isEdit) "Save changes" else "Add equipment")
            }
        }
    }
}

private fun trimCapacity(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)

private fun String.numericFilterCapacity(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

private fun String.toCapacityDouble(): Double? = replace(',', '.').trim().takeIf { it.isNotBlank() }?.toDoubleOrNull()
