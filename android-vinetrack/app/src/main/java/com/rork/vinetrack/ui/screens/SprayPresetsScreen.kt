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
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Science
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
import androidx.compose.material3.rememberModalBottomSheetState
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
import com.rork.vinetrack.data.SavedSprayPresetRepository
import com.rork.vinetrack.data.model.SavedSprayPreset
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Brand colour for tank presets (matches the Spray Management hub row). */
private val PresetTint: Color = VineColors.LeafGreen

/**
 * Reusable tank presets — saved Water Volume, Spray Rate, and Concentration
 * Factor combinations applied to tanks in the spray form. Mirrors the iOS
 * "Tank Presets" section of `SprayPresetsView`: owners/managers can add, edit,
 * and archive; other members get a read-only list. These are tank dosing
 * settings, not chemical mixes or financial data, so all members can view them.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayPresetsScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"

    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<SavedSprayPreset?>(null) }
    var pendingDelete by remember { mutableStateOf<SavedSprayPreset?>(null) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Spray Presets") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = PresetTint,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add tank preset") }
            }
        },
    ) { padding ->
        if (state.savedSprayPresets.isEmpty()) {
            EmptyState(
                icon = Icons.Filled.Science,
                title = "No tank presets yet",
                message = if (canManage) {
                    "Save common Water Volume, Spray Rate, and Concentration Factor combinations to apply them quickly in spray records."
                } else {
                    "The vineyard owner or manager hasn't added any tank presets yet."
                },
                actionLabel = if (canManage) "Add preset" else null,
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
                                "Setup data is managed by vineyard owners and managers.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
                items(state.savedSprayPresets, key = { it.id }) { preset ->
                    SprayPresetRow(
                        preset = preset,
                        canManage = canManage,
                        onEdit = { if (canManage) editing = preset },
                        onDelete = { if (canManage) pendingDelete = preset },
                    )
                }
            }
        }
    }

    if (creating) {
        SprayPresetFormSheet(vm = vm, existing = null, onDismiss = { creating = false })
    }
    editing?.let { preset ->
        SprayPresetFormSheet(vm = vm, existing = preset, onDismiss = { editing = null })
    }
    pendingDelete?.let { preset ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Archive preset?") },
            text = { Text("\"${preset.displayName}\" will no longer be available to apply in spray records. Existing records are unaffected.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteSavedSprayPreset(preset.id) {}
                    pendingDelete = null
                }) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SprayPresetRow(
    preset: SavedSprayPreset,
    canManage: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = if (canManage) Modifier.clickable { onEdit() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(preset.displayName, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp)
                Text(
                    "${trimPreset(preset.waterVolume)} L · ${trimPreset(preset.sprayRatePerHa)} L/ha · CF ${"%.1f".format(preset.concentrationFactor)}",
                    fontSize = 13.sp,
                    color = PresetTint,
                    fontWeight = FontWeight.Medium,
                )
            }
            if (canManage) {
                IconButton(onClick = onDelete) {
                    Icon(Icons.Filled.Delete, contentDescription = "Archive preset", tint = VineColors.Destructive, modifier = Modifier.size(20.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayPresetFormSheet(
    vm: AppViewModel,
    existing: SavedSprayPreset?,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val isEdit = existing != null

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var water by remember {
        mutableStateOf(existing?.waterVolume?.takeIf { it > 0 }?.let { trimPreset(it) } ?: "")
    }
    var rate by remember {
        mutableStateOf(existing?.sprayRatePerHa?.takeIf { it > 0 }?.let { trimPreset(it) } ?: "")
    }
    var concentration by remember {
        mutableStateOf(existing?.concentrationFactor?.takeIf { it > 0 }?.let { trimPreset(it) } ?: "1")
    }
    var saving by remember { mutableStateOf(false) }

    fun save() {
        if (saving) return
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return
        saving = true
        val input = SavedSprayPresetRepository.PresetInput(
            name = trimmedName,
            waterVolume = water.toPresetDouble() ?: 0.0,
            sprayRatePerHa = rate.toPresetDouble() ?: 0.0,
            concentrationFactor = concentration.toPresetDouble()?.takeIf { it > 0 } ?: 1.0,
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (isEdit) vm.updateSavedSprayPreset(existing!!.id, input, cb) else vm.createSavedSprayPreset(input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (isEdit) "Edit preset" else "New tank preset",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Preset name") },
                placeholder = { Text("e.g. Standard tank") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = water,
                    onValueChange = { water = it.numericFilterPreset() },
                    label = { Text("Water L") },
                    placeholder = { Text("1500") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = rate,
                    onValueChange = { rate = it.numericFilterPreset() },
                    label = { Text("L/ha") },
                    placeholder = { Text("750") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }
            OutlinedTextField(
                value = concentration,
                onValueChange = { concentration = it.numericFilterPreset() },
                label = { Text("Concentration factor") },
                placeholder = { Text("1.0") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Tank presets save Water Volume, Spray Rate, and Concentration Factor for quick reuse when logging sprays.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
            Spacer(Modifier.height(4.dp))
            Button(
                onClick = { save() },
                enabled = !saving && name.trim().isNotEmpty(),
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (isEdit) "Save changes" else "Add preset")
            }
        }
    }
}

private fun trimPreset(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)

private fun String.numericFilterPreset(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

private fun String.toPresetDouble(): Double? = replace(',', '.').trim().takeIf { it.isNotBlank() }?.toDoubleOrNull()
