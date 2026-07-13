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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lock
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.VineyardTripFunction
import com.rork.vinetrack.data.model.builtInTripFunctions
import com.rork.vinetrack.data.model.slugifyTripFunction
import com.rork.vinetrack.data.model.tripFunctionDisplayName
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

private val TripFunctionTint: Color = VineColors.Indigo

/**
 * Settings → Trip Functions: vineyard-scoped custom maintenance operations that
 * appear in the Start Trip picker alongside built-ins. Owners/managers can add,
 * rename, archive and restore; other members get a read-only list. Mirrors the
 * iOS `TripFunctionsSettingsView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TripFunctionsSettingsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"

    val active = remember(state.vineyardTripFunctions) {
        state.vineyardTripFunctions.filter { it.isSelectable }.sortedBy { it.label.lowercase() }
    }
    val archived = remember(state.vineyardTripFunctions) {
        state.vineyardTripFunctions.filter { !it.isSelectable }.sortedBy { it.label.lowercase() }
    }

    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<VineyardTripFunction?>(null) }
    var pendingArchive by remember { mutableStateOf<VineyardTripFunction?>(null) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Trip Functions") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = TripFunctionTint,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add trip function") }
            }
        },
    ) { padding ->
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
                            "Only owners and managers can add or change custom trip functions.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            item(key = "custom-header") {
                SectionHeader("Custom functions", onLight = true)
            }
            if (active.isEmpty()) {
                item(key = "custom-empty") {
                    Text(
                        if (canManage) "No custom functions yet. Tap + to add one."
                        else "No custom functions yet.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )
                }
            } else {
                items(active, key = { it.id }) { fn ->
                    CustomFunctionRow(
                        fn = fn,
                        canManage = canManage,
                        onEdit = { if (canManage) editing = fn },
                        onArchive = { if (canManage) pendingArchive = fn },
                    )
                }
            }

            if (archived.isNotEmpty()) {
                item(key = "archived-header") {
                    Spacer(Modifier.height(6.dp))
                    SectionHeader("Archived", onLight = true)
                }
                items(archived, key = { "archived-${it.id}" }) { fn ->
                    ArchivedFunctionRow(
                        fn = fn,
                        canManage = canManage,
                        onRestore = { if (canManage) vm.restoreTripFunction(fn.id) {} },
                    )
                }
            }

            item(key = "built-in-header") {
                Spacer(Modifier.height(6.dp))
                SectionHeader("Built-in functions", onLight = true)
            }
            item(key = "built-in-note") {
                Text(
                    "Built-in functions are always available and can't be removed.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
            items(builtInTripFunctions, key = { "builtin-${it.first}" }) { (_, label) ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Agriculture, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(10.dp))
                        Text(label, color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                        Text("Built-in", fontSize = 11.sp, color = vine.textSecondary)
                    }
                }
            }
        }
    }

    if (creating) {
        TripFunctionFormSheet(vm = vm, existing = null, onDismiss = { creating = false })
    }
    editing?.let { fn ->
        TripFunctionFormSheet(vm = vm, existing = fn, onDismiss = { editing = null })
    }
    pendingArchive?.let { fn ->
        AlertDialog(
            onDismissRequest = { pendingArchive = null },
            title = { Text("Archive function?") },
            text = { Text("\"${fn.label}\" will no longer appear when starting a trip. Existing trips that used it keep their label.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.archiveTripFunction(fn.id) {}
                    pendingArchive = null
                }) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { pendingArchive = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun CustomFunctionRow(
    fn: VineyardTripFunction,
    canManage: Boolean,
    onEdit: () -> Unit,
    onArchive: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = if (canManage) Modifier.clickable { onEdit() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Agriculture, contentDescription = null, tint = TripFunctionTint, modifier = Modifier.size(20.dp))
            Spacer(Modifier.size(12.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(fn.label, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp)
                Text("custom:${fn.slug}", fontSize = 11.sp, color = vine.textSecondary)
            }
            if (canManage) {
                IconButton(onClick = onEdit) {
                    Icon(Icons.Filled.Edit, contentDescription = "Rename", tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                }
                IconButton(onClick = onArchive) {
                    Icon(Icons.Filled.Archive, contentDescription = "Archive", tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

@Composable
private fun ArchivedFunctionRow(
    fn: VineyardTripFunction,
    canManage: Boolean,
    onRestore: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Archive, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(12.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(fn.label, fontWeight = FontWeight.Medium, color = vine.textPrimary, fontSize = 15.sp)
                Text("custom:${fn.slug}", fontSize = 11.sp, color = vine.textSecondary)
            }
            if (canManage) {
                TextButton(onClick = onRestore) { Text("Restore", color = TripFunctionTint, fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripFunctionFormSheet(
    vm: AppViewModel,
    existing: VineyardTripFunction?,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val isEdit = existing != null

    var label by remember { mutableStateOf(existing?.label ?: "") }
    var saving by remember { mutableStateOf(false) }

    val trimmed = label.trim()
    val slugPreview = if (trimmed.isNotEmpty()) slugifyTripFunction(trimmed) else ""
    val collidesBuiltIn = slugPreview.isNotEmpty() &&
        (builtInTripFunctions.any { it.first == slugPreview } || tripFunctionDisplayName(slugPreview) != null)
    val canSave = !saving && trimmed.isNotEmpty() && !collidesBuiltIn &&
        (!isEdit || trimmed != existing!!.label)

    fun save() {
        if (!canSave) return
        saving = true
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (isEdit) vm.renameTripFunction(existing!!.id, trimmed, cb) else vm.createTripFunction(trimmed, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (isEdit) "Rename Function" else "Add Trip Function",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )
            OutlinedTextField(
                value = label,
                onValueChange = { label = it },
                label = { Text("Label (e.g. Rolling)") },
                singleLine = true,
                isError = collidesBuiltIn,
                modifier = Modifier.fillMaxWidth(),
            )
            when {
                collidesBuiltIn -> Text(
                    "\"$trimmed\" matches a built-in function. Pick another name.",
                    fontSize = 12.sp,
                    color = VineColors.Destructive,
                )
                isEdit -> Text(
                    "The stable slug \"custom:${existing!!.slug}\" stays the same so existing trips keep their reference.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                slugPreview.isNotEmpty() -> Text(
                    "Slug: custom:$slugPreview — generated from the label and stays stable if you rename later.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                else -> Text(
                    "Custom functions appear in the Start Trip operation list.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
            Spacer(Modifier.height(4.dp))
            Button(
                onClick = { save() },
                enabled = canSave,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (isEdit) "Save changes" else "Add Function")
            }
        }
    }
}
