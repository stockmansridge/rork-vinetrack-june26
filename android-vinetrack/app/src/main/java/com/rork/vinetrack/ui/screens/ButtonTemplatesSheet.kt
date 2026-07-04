package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.ButtonTemplate
import com.rork.vinetrack.data.ButtonTemplateEntry
import com.rork.vinetrack.data.ButtonTemplateStore
import com.rork.vinetrack.data.model.LauncherButton
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Android parity for the iOS `ButtonTemplateListView` + `EditButtonTemplateSheet`.
 * Lists the device-local button templates for a mode, lets owners/managers
 * add / edit / delete them, and "Apply" a template — which converts its four
 * entries into the eight paired Left/Right launcher buttons and saves them
 * through the shared `vineyard_button_configs` contract via
 * [AppViewModel.saveLauncherButtons].
 *
 * A single bottom sheet toggles between the list and the editor so nested modal
 * sheets are avoided.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ButtonTemplatesSheet(
    vm: AppViewModel,
    state: AppUiState,
    mode: String,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { ButtonTemplateStore(context) }
    val vineyardId = state.selectedVineyardId
    val canManage = state.canEditLauncherButtons
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    var templates by remember(mode, vineyardId) {
        mutableStateOf(if (vineyardId != null) store.templates(vineyardId, mode) else emptyList())
    }
    // null = list view; otherwise the template being edited (a fresh blank one for "new").
    var editing by remember { mutableStateOf<ButtonTemplate?>(null) }
    var isCreating by remember { mutableStateOf(false) }

    fun reload() {
        if (vineyardId != null) templates = store.templates(vineyardId, mode)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            val target = editing
            if (target == null) {
                TemplateListContent(
                    vm = vm,
                    state = state,
                    mode = mode,
                    templates = templates,
                    canManage = canManage,
                    onNew = {
                        isCreating = true
                        editing = ButtonTemplate(
                            vineyardId = vineyardId ?: "",
                            mode = mode,
                            entries = ButtonTemplateStore.defaultTemplate(vineyardId ?: "", mode).entries,
                        )
                    },
                    onEdit = { isCreating = false; editing = it },
                    onDelete = { store.delete(it); reload() },
                    onApplied = onDismiss,
                    onClose = onDismiss,
                )
            } else {
                EditTemplateContent(
                    mode = mode,
                    template = target,
                    isCreating = isCreating,
                    onCancel = { editing = null },
                    onSave = { saved ->
                        if (isCreating) store.add(saved) else store.update(saved)
                        editing = null
                        reload()
                    },
                )
            }
        }
    }
}

@Composable
private fun TemplateListContent(
    vm: AppViewModel,
    state: AppUiState,
    mode: String,
    templates: List<ButtonTemplate>,
    canManage: Boolean,
    onNew: () -> Unit,
    onEdit: (ButtonTemplate) -> Unit,
    onDelete: (ButtonTemplate) -> Unit,
    onApplied: () -> Unit,
    onClose: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(
            "${if (mode == "Growth") "Growth" else "Repairs"} Templates",
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            color = vine.textPrimary,
            modifier = Modifier.weight(1f),
        )
        if (canManage) {
            IconButton(onClick = onNew) {
                Icon(Icons.Filled.Add, contentDescription = "New template", tint = VineColors.Primary)
            }
        }
    }
    Text(
        "Save sets of buttons and apply them in one tap. Applying a template replaces the live ${if (mode == "Growth") "Growth" else "Repairs"} buttons and syncs to iOS and the web portal.",
        fontSize = 13.sp,
        color = vine.textSecondary,
    )

    if (templates.isEmpty()) {
        Text(
            "No templates yet. Create one to quickly apply different button sets.",
            fontSize = 13.sp,
            color = vine.textSecondary,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(vine.textSecondary.copy(alpha = 0.08f))
                .padding(14.dp),
        )
    } else {
        templates.forEach { template ->
            TemplateRow(
                template = template,
                canManage = canManage,
                busy = state.buttonConfigBusy,
                onEdit = { onEdit(template) },
                onDelete = { onDelete(template) },
                onApply = {
                    vm.saveLauncherButtons(mode, template.toLauncherButtons(mode)) { ok ->
                        if (ok) onApplied()
                    }
                },
            )
        }
    }

    state.buttonConfigError?.let { err ->
        Text(err, fontSize = 12.sp, color = VineColors.Destructive)
    }

    if (!canManage) {
        Text(
            "Setup data is managed by vineyard owners and managers.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }

    TextButton(onClick = onClose, modifier = Modifier.fillMaxWidth()) { Text("Done") }
}

@Composable
private fun TemplateRow(
    template: ButtonTemplate,
    canManage: Boolean,
    busy: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onApply: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.appBackground)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                template.name.ifBlank { "Untitled" },
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
                modifier = Modifier.weight(1f),
            )
            if (canManage) {
                IconButton(onClick = onEdit, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Filled.Edit, contentDescription = "Edit", tint = vine.textSecondary, modifier = Modifier.size(20.dp))
                }
                IconButton(onClick = onDelete, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Filled.Delete, contentDescription = "Delete", tint = VineColors.Destructive, modifier = Modifier.size(20.dp))
                }
            }
        }
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            template.entries.forEach { entry ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Box(modifier = Modifier.size(14.dp).clip(CircleShape).background(launcherColor(entry.color)))
                    Text(entry.name.ifBlank { "Untitled" }, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
        }
        Text("${template.entries.size} buttons \u2022 Rows paired L/R", fontSize = 11.sp, color = vine.textSecondary)
        if (canManage) {
            Button(
                onClick = onApply,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
            ) {
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Filled.CheckCircle, contentDescription = null, modifier = Modifier.size(18.dp))
                    Box(Modifier.size(6.dp))
                    Text("Apply")
                }
            }
        }
    }
}

@Composable
private fun EditTemplateContent(
    mode: String,
    template: ButtonTemplate,
    isCreating: Boolean,
    onCancel: () -> Unit,
    onSave: (ButtonTemplate) -> Unit,
) {
    val vine = LocalVineColors.current
    // Normalise to exactly four rows.
    val seeded = remember(template.id) {
        (0 until 4).map { i ->
            template.entries.getOrNull(i) ?: ButtonTemplateEntry("", launcherColorTokens.getOrElse(i) { "blue" })
        }
    }
    var name by remember(template.id) { mutableStateOf(template.name) }
    var rows by remember(template.id) { mutableStateOf(seeded) }
    var expandedColorIndex by remember { mutableStateOf<Int?>(null) }

    val colorTokens = rows.map { it.color.lowercase() }
    val hasDuplicateColors = colorTokens.toSet().size != colorTokens.size
    val allNamed = rows.all { it.name.trim().isNotEmpty() }
    val canSave = name.trim().isNotEmpty() && !hasDuplicateColors && allNamed

    Text(
        if (isCreating) "New Template" else "Edit Template",
        fontSize = 20.sp,
        fontWeight = FontWeight.Bold,
        color = vine.textPrimary,
    )
    OutlinedTextField(
        value = name,
        onValueChange = { name = it },
        singleLine = true,
        label = { Text("Template name") },
        modifier = Modifier.fillMaxWidth(),
    )
    Text("Buttons (4 rows, paired Left & Right)", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)

    rows.forEachIndexed { index, row ->
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(launcherColor(row.color))
                        .clickable { expandedColorIndex = if (expandedColorIndex == index) null else index },
                )
                OutlinedTextField(
                    value = row.name,
                    onValueChange = { v -> rows = rows.toMutableList().also { it[index] = row.copy(name = v) } },
                    singleLine = true,
                    label = { Text("Row ${index + 1}") },
                    modifier = Modifier.weight(1f),
                )
                if (mode == "Growth") {
                    IconButton(
                        onClick = { rows = rows.toMutableList().also { it[index] = row.copy(isGrowthStageButton = !row.isGrowthStageButton) } },
                    ) {
                        Icon(
                            Icons.Filled.Grass,
                            contentDescription = "Growth Stage button",
                            tint = if (row.isGrowthStageButton) VineColors.LeafGreen else vine.textSecondary,
                        )
                    }
                }
            }
            if (expandedColorIndex == index) {
                val used = rows.filterIndexed { i, r -> i != index }.map { it.color.lowercase() }.toSet()
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    launcherColorTokens.forEach { token ->
                        val isUsed = used.contains(token)
                        Box(
                            modifier = Modifier
                                .size(28.dp)
                                .clip(CircleShape)
                                .background(launcherColor(token).copy(alpha = if (isUsed) 0.3f else 1f))
                                .then(
                                    if (!isUsed) Modifier.clickable {
                                        rows = rows.toMutableList().also { it[index] = row.copy(color = token) }
                                        expandedColorIndex = null
                                    } else Modifier,
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            if (row.color.equals(token, ignoreCase = true)) {
                                Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            }
        }
    }

    if (hasDuplicateColors) {
        Text("Each button must use a different colour.", fontSize = 12.sp, color = VineColors.Destructive)
    } else if (!allNamed) {
        Text("Every button needs a name.", fontSize = 12.sp, color = VineColors.Destructive)
    }

    // Preview grid (LEFT / RIGHT), mirroring iOS.
    Text("Preview", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
        listOf("LEFT", "RIGHT").forEach { side ->
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(side, fontSize = 10.sp, fontWeight = FontWeight.Black, color = vine.textSecondary, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                rows.forEach { r ->
                    val isLight = r.color.lowercase() in listOf("yellow", "cyan")
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(launcherColor(r.color))
                            .padding(vertical = 8.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            r.name.ifBlank { "Untitled" },
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (isLight) Color.Black else Color.White,
                        )
                    }
                }
            }
        }
    }

    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        OutlinedButton(onClick = onCancel, modifier = Modifier.weight(1f)) { Text("Cancel") }
        Button(
            onClick = {
                onSave(
                    template.copy(
                        name = name.trim(),
                        mode = mode,
                        entries = rows.map { it.copy(name = it.name.trim()) },
                    ),
                )
            },
            enabled = canSave,
            modifier = Modifier.weight(1f),
            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
        ) { Text("Save") }
    }
}

/** Convert a template's four entries to the eight paired Left/Right launcher buttons. */
private fun ButtonTemplate.toLauncherButtons(mode: String): List<LauncherButton> =
    buildList {
        entries.take(4).forEachIndexed { i, entry ->
            val name = entry.name.trim()
            add(LauncherButton(name = name, color = entry.color, index = i, mode = mode, isGrowthStageButton = entry.isGrowthStageButton))
            add(LauncherButton(name = name, color = entry.color, index = i + 4, mode = mode, isGrowthStageButton = entry.isGrowthStageButton))
        }
    }
