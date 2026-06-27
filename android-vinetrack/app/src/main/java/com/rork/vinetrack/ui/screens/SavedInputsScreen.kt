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
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
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
import com.rork.vinetrack.data.SavedInputRepository
import com.rork.vinetrack.data.model.SavedInput
import com.rork.vinetrack.data.model.savedInputTypeDisplayName
import com.rork.vinetrack.data.model.savedInputTypes
import com.rork.vinetrack.data.model.savedInputUnits
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Brand colour for the Saved Inputs surface (seeding/spreading material). */
private val InputTint: Color = VineColors.LeafGreen

/**
 * Saved Inputs library — reusable seed/fertiliser/compost/etc. products with an
 * optional owner/manager-only cost per unit. Used to price seeding,
 * spreading and fertilising trips. Mirrors the iOS Saved Inputs management
 * surface and the financial gating used across the app.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SavedInputsScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"
    val canViewFinancials = canManage

    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<SavedInput?>(null) }
    var pendingDelete by remember { mutableStateOf<SavedInput?>(null) }
    var search by remember { mutableStateOf("") }
    val filtered = remember(state.savedInputs, search) {
        if (search.isBlank()) state.savedInputs
        else state.savedInputs.filter {
            it.displayName.contains(search.trim(), true) ||
                it.inputTypeDisplayName.contains(search.trim(), true) ||
                (it.supplier?.contains(search.trim(), true) == true)
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Saved Inputs") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = InputTint,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add input") }
            }
        },
    ) { padding ->
        if (state.savedInputs.isEmpty()) {
            EmptyState(
                icon = Icons.Filled.Grass,
                title = "No Saved Inputs",
                message = if (canManage) {
                    "Add seed, fertiliser and other inputs with a cost per unit so seeding and spreading trips can be costed automatically."
                } else {
                    "The vineyard owner or manager hasn't added any saved inputs yet."
                },
                actionLabel = if (canManage) "Add input" else null,
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
                item(key = "search") {
                    OutlinedTextField(
                        value = search,
                        onValueChange = { search = it },
                        placeholder = { Text("Search inputs...") },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (filtered.isEmpty()) {
                    item(key = "no-match") {
                        Text(
                            "No inputs match your search.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.padding(vertical = 12.dp),
                        )
                    }
                }
                items(filtered, key = { it.id }) { input ->
                    SavedInputRow(
                        input = input,
                        canManage = canManage,
                        canViewFinancials = canViewFinancials,
                        onEdit = { if (canManage) editing = input },
                        onDelete = { if (canManage) pendingDelete = input },
                    )
                }
            }
        }
    }

    if (creating) {
        SavedInputFormSheet(vm = vm, existing = null, canViewFinancials = canViewFinancials, onDismiss = { creating = false })
    }
    editing?.let { input ->
        SavedInputFormSheet(vm = vm, existing = input, canViewFinancials = canViewFinancials, onDismiss = { editing = null })
    }
    pendingDelete?.let { input ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Archive ${input.displayName}?") },
            text = { Text("This input will be hidden from active lists but kept for historical trip records.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteSavedInput(input.id) {}
                    pendingDelete = null
                }) { Text("Archive Input", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SavedInputRow(
    input: SavedInput,
    canManage: Boolean,
    canViewFinancials: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = if (canManage) Modifier.clickable { onEdit() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(input.displayName, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp)
                val meta = buildList {
                    add(input.inputTypeDisplayName)
                    input.supplier?.takeIf { it.isNotBlank() }?.let { add(it) }
                }.joinToString(" · ")
                if (meta.isNotEmpty()) {
                    Text(meta, fontSize = 13.sp, color = vine.textSecondary)
                }
                if (canViewFinancials) {
                    val cost = input.costPerUnit
                    Text(
                        if (cost != null && cost > 0) "${formatInputCurrency(cost)} / ${input.unit}" else "No cost set",
                        fontSize = 13.sp,
                        color = if (cost != null && cost > 0) InputTint else vine.textSecondary,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
            if (canManage) {
                IconButton(onClick = onDelete) {
                    Icon(Icons.Filled.Delete, contentDescription = "Archive input", tint = VineColors.Destructive, modifier = Modifier.size(20.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SavedInputFormSheet(
    vm: AppViewModel,
    existing: SavedInput?,
    canViewFinancials: Boolean,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val isEdit = existing != null

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var inputType by remember { mutableStateOf(existing?.inputType?.takeIf { it in savedInputTypes } ?: "seed") }
    var unit by remember { mutableStateOf(existing?.unit?.takeIf { it in savedInputUnits } ?: "kg") }
    var supplier by remember { mutableStateOf(existing?.supplier ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var costPerUnit by remember {
        mutableStateOf(existing?.costPerUnit?.takeIf { it > 0 }?.let { trimInputNum(it) } ?: "")
    }
    var typeMenu by remember { mutableStateOf(false) }
    var unitMenu by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    fun save() {
        if (saving) return
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return
        saving = true
        val form = SavedInputRepository.InputForm(
            name = trimmedName,
            inputType = inputType,
            unit = unit,
            costPerUnit = if (canViewFinancials) costPerUnit.inputDoubleSafe() else existing?.costPerUnit,
            supplier = supplier.trim().ifBlank { null },
            notes = notes.trim().ifBlank { null },
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (isEdit) vm.updateSavedInput(existing!!.id, form, cb) else vm.createSavedInput(form, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (isEdit) "Edit input" else "New input",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Input / product name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                ExposedDropdownMenuBox(
                    expanded = typeMenu,
                    onExpandedChange = { typeMenu = it },
                    modifier = Modifier.weight(1f),
                ) {
                    OutlinedTextField(
                        value = savedInputTypeDisplayName(inputType),
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Type") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = typeMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = typeMenu, onDismissRequest = { typeMenu = false }) {
                        savedInputTypes.forEach { t ->
                            DropdownMenuItem(
                                text = { Text(savedInputTypeDisplayName(t)) },
                                onClick = { inputType = t; typeMenu = false },
                            )
                        }
                    }
                }
                ExposedDropdownMenuBox(
                    expanded = unitMenu,
                    onExpandedChange = { unitMenu = it },
                    modifier = Modifier.weight(1f),
                ) {
                    OutlinedTextField(
                        value = unit,
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Unit") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = unitMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = unitMenu, onDismissRequest = { unitMenu = false }) {
                        savedInputUnits.forEach { u ->
                            DropdownMenuItem(text = { Text(u) }, onClick = { unit = u; unitMenu = false })
                        }
                    }
                }
            }
            if (canViewFinancials) {
                OutlinedTextField(
                    value = costPerUnit,
                    onValueChange = { costPerUnit = it.inputNumericFilter() },
                    label = { Text("Cost per $unit (optional)") },
                    placeholder = { Text("0.00") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "Visible to owners and managers only. Used to price seed/input cost on seeding and spreading trips.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
            OutlinedTextField(
                value = supplier,
                onValueChange = { supplier = it },
                label = { Text("Supplier (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(4.dp))
            Button(
                onClick = { save() },
                enabled = !saving && name.trim().isNotEmpty(),
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (isEdit) "Save changes" else "Add input")
            }
        }
    }
}

/** Compact currency label (e.g. "$50", "$42.50") for input costs. */
private fun formatInputCurrency(value: Double): String {
    val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong()) else "%,.2f".format(value)
    return "$$rounded"
}

private fun trimInputNum(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.2f".format(value)

private fun String.inputNumericFilter(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

private fun String.inputDoubleSafe(): Double? =
    replace(',', '.').trim().takeIf { it.isNotBlank() }?.toDoubleOrNull()
