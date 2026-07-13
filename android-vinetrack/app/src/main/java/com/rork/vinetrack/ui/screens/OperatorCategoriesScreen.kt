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
import androidx.compose.material.icons.filled.Person
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
import com.rork.vinetrack.data.OperatorCategoryRepository
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Brand colour for operator costs (matches the Spray Management hub row). */
private val OperatorTint: Color = VineColors.Orange

/**
 * Worker Types — role names with hourly rates assigned to vineyard users to
 * calculate labour costs on trips and work tasks. Owners/managers can add,
 * edit, and archive worker types (the hourly rate is owner/manager-only);
 * other members get a read-only list with rates hidden, matching the iOS
 * `OperatorCategoriesView` financial gating.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OperatorCategoriesScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"
    // Rate visibility mirrors the spray form / chemicals canViewFinancials gate.
    val canViewFinancials = canManage

    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<OperatorCategory?>(null) }
    var pendingDelete by remember { mutableStateOf<OperatorCategory?>(null) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Worker Types") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = OperatorTint,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add worker type") }
            }
        },
    ) { padding ->
        if (state.operatorCategories.isEmpty()) {
            EmptyState(
                icon = Icons.Filled.Person,
                title = "No worker types yet",
                message = if (canManage) {
                    "Add worker types with hourly rates to calculate labour costs on trips and work tasks."
                } else {
                    "The vineyard owner or manager hasn't added any worker types yet."
                },
                actionLabel = if (canManage) "Add worker type" else null,
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
                items(state.operatorCategories, key = { it.id }) { category ->
                    OperatorCategoryRow(
                        category = category,
                        canManage = canManage,
                        canViewFinancials = canViewFinancials,
                        onEdit = { if (canManage) editing = category },
                        onDelete = { if (canManage) pendingDelete = category },
                    )
                }
            }
        }
    }

    if (creating) {
        OperatorCategoryFormSheet(
            vm = vm,
            existing = null,
            onDismiss = { creating = false },
        )
    }
    editing?.let { category ->
        OperatorCategoryFormSheet(
            vm = vm,
            existing = category,
            onDismiss = { editing = null },
        )
    }
    pendingDelete?.let { category ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Archive worker type?") },
            text = { Text("\"${category.displayName}\" will no longer be available for new trips. Existing trips that used it are unaffected.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteOperatorCategory(category.id) {}
                    pendingDelete = null
                }) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun OperatorCategoryRow(
    category: OperatorCategory,
    canManage: Boolean,
    canViewFinancials: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = if (canManage) Modifier.clickable { onEdit() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(category.displayName, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp)
                if (canViewFinancials) {
                    val rate = category.costPerHour
                    Text(
                        if (rate != null && rate > 0) "${formatOperatorCurrency(rate)} / hr" else "No rate set",
                        fontSize = 13.sp,
                        color = if (rate != null && rate > 0) OperatorTint else vine.textSecondary,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
            if (canManage) {
                IconButton(onClick = onDelete) {
                    Icon(Icons.Filled.Delete, contentDescription = "Archive worker type", tint = VineColors.Destructive, modifier = Modifier.size(20.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OperatorCategoryFormSheet(
    vm: AppViewModel,
    existing: OperatorCategory?,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val isEdit = existing != null

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var costPerHour by remember {
        mutableStateOf(existing?.costPerHour?.takeIf { it > 0 }?.let { trimRate(it) } ?: "")
    }
    var saving by remember { mutableStateOf(false) }

    fun save() {
        if (saving) return
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return
        saving = true
        val input = OperatorCategoryRepository.CategoryInput(
            name = trimmedName,
            costPerHour = costPerHour.toRateDouble() ?: 0.0,
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (isEdit) vm.updateOperatorCategory(existing!!.id, input, cb) else vm.createOperatorCategory(input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (isEdit) "Edit Worker Type" else "Add Worker Type",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Worker Type Name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = costPerHour,
                onValueChange = { costPerHour = it.numericFilterRate() },
                label = { Text("Cost per hour (optional)") },
                placeholder = { Text("0.00") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Define worker types with hourly rates. Assign them to vineyard users to calculate labour costs on trips and work tasks.",
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
                else Text(if (isEdit) "Save changes" else "Add Worker Type")
            }
        }
    }
}

/** Compact currency label (e.g. "$50", "$42.50") for hourly rates. */
private fun formatOperatorCurrency(value: Double): String {
    val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong()) else "%,.2f".format(value)
    return "$$rounded"
}

private fun trimRate(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.2f".format(value)

private fun String.numericFilterRate(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

private fun String.toRateDouble(): Double? = replace(',', '.').trim().takeIf { it.isNotBlank() }?.toDoubleOrNull()
