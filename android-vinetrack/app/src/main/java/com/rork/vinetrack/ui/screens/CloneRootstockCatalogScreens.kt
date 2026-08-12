package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.ForkLeft
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.CloneCatalogEntry
import com.rork.vinetrack.data.model.CloneRootstockBrowse
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.RootstockCatalogEntry
import com.rork.vinetrack.data.model.VineyardCloneRow
import com.rork.vinetrack.data.model.VineyardRootstockRow
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.StatusBadge
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Clones + Rootstocks tabs of the Grape Varieties settings area (sql/182).
 * Shows the shared built-in catalogue plus this vineyard's custom records,
 * searchable, with block-allocation usage counts and drill-in detail sheets.
 * Built-in records are read-only; owner/manager can add and archive custom
 * records via the existing sql/182 RPCs. Mirrors the iOS
 * `CloneRootstockManagementViews`.
 */

/** One block allocation using a clone/rootstock (for detail drill-ins). */
internal data class CatalogAllocationUsage(
    val paddock: Paddock,
    val allocation: PaddockVarietyAllocation,
)

internal sealed interface CloneCatalogSelection {
    data class Builtin(val entry: CloneCatalogEntry) : CloneCatalogSelection
    data class Custom(val row: VineyardCloneRow) : CloneCatalogSelection
}

internal sealed interface RootstockCatalogSelection {
    data class Builtin(val entry: RootstockCatalogEntry) : RootstockCatalogSelection
    data class Custom(val row: VineyardRootstockRow) : RootstockCatalogSelection
}

private fun varietyDisplayName(state: AppUiState, key: String): String =
    state.grapeVarieties.firstOrNull { it.varietyKey == key }?.displayName ?: key

private fun cloneUsages(
    paddocks: List<Paddock>,
    entryKey: String,
    matchNames: List<String>,
): List<CatalogAllocationUsage> = paddocks.flatMap { paddock ->
    paddock.varietyAllocations.orEmpty()
        .filter { CloneRootstockBrowse.allocationUsesClone(it.cloneKey, it.clone, entryKey, matchNames) }
        .map { CatalogAllocationUsage(paddock, it) }
}

private fun rootstockUsages(
    paddocks: List<Paddock>,
    entryKey: String,
    matchNames: List<String>,
): List<CatalogAllocationUsage> = paddocks.flatMap { paddock ->
    paddock.varietyAllocations.orEmpty()
        .filter { CloneRootstockBrowse.allocationUsesRootstock(it.rootstockKey, it.rootstock, entryKey, matchNames) }
        .map { CatalogAllocationUsage(paddock, it) }
}

private fun allocationLabel(usage: CatalogAllocationUsage): String {
    val parts = buildList {
        usage.allocation.displayName?.takeIf { it.isNotBlank() }?.let { add(it) }
        usage.allocation.displayPercent?.let { add("${it.toInt()}%") }
    }
    return parts.joinToString(" · ")
}

// =========================================================================
// Clones tab
// =========================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ClonesCatalogContent(
    vm: AppViewModel,
    state: AppUiState,
    canManage: Boolean,
    adding: Boolean,
    onDismissAdd: () -> Unit,
) {
    val vine = LocalVineColors.current
    var query by rememberSaveable { mutableStateOf("") }
    var varietyFilterKey by rememberSaveable { mutableStateOf<String?>(null) }
    var selection by remember { mutableStateOf<CloneCatalogSelection?>(null) }

    val customRows = remember(state.vineyardClones, state.selectedVineyardId) {
        state.vineyardClones.filter { it.vineyardId == state.selectedVineyardId }
    }
    val builtin = remember(state.cloneCatalog, varietyFilterKey, query, state.grapeVarieties) {
        CloneRootstockBrowse.systemClones(state.cloneCatalog, varietyFilterKey, query)
            .sortedWith(compareBy({ varietyDisplayName(state, it.varietyKey).lowercase() }, { it.displayName.lowercase() }))
    }
    val custom = remember(customRows, varietyFilterKey, query, state.grapeVarieties) {
        CloneRootstockBrowse.customClones(customRows, varietyFilterKey, query)
            .sortedWith(compareBy({ varietyDisplayName(state, it.varietyKey).lowercase() }, { it.displayName.lowercase() }))
    }
    // Variety keys offered in the filter: everything that has at least one clone.
    val filterKeys = remember(state.cloneCatalog, customRows, state.grapeVarieties) {
        (state.cloneCatalog.filter { it.isActive }.map { it.varietyKey } +
            customRows.filter { it.isActive }.map { it.varietyKey })
            .distinct()
            .sortedBy { varietyDisplayName(state, it).lowercase() }
    }
    val usageCounts = remember(state.paddocks, builtin, custom) {
        buildMap {
            builtin.forEach { entry ->
                put(entry.key, cloneUsages(state.paddocks, entry.key, CloneRootstockBrowse.cloneMatchNames(entry)).size)
            }
            custom.forEach { row ->
                put(row.cloneKey, cloneUsages(state.paddocks, row.cloneKey, listOf(row.displayName)).size)
            }
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            CatalogSearchField(
                value = query,
                onValueChange = { query = it },
                placeholder = "Search clones",
            )
        }
        item {
            VarietyFilterDropdown(
                state = state,
                filterKeys = filterKeys,
                selectedKey = varietyFilterKey,
                onSelect = { varietyFilterKey = it },
            )
        }
        if (builtin.isEmpty() && custom.isEmpty()) {
            item {
                EmptyState(
                    icon = Icons.Filled.Spa,
                    title = "No clones found",
                    message = if (query.isBlank()) {
                        "The shared clone catalogue is loading, or no clones match the selected variety."
                    } else {
                        "No clones match \u201C${query.trim()}\u201D."
                    },
                )
            }
        }
        if (builtin.isNotEmpty()) {
            item { SectionHeader("Built-in · ${builtin.size}", onLight = true) }
            items(builtin.size) { index ->
                val entry = builtin[index]
                CloneCatalogCard(
                    title = entry.displayName,
                    varietyName = varietyDisplayName(state, entry.varietyKey),
                    subtitle = entry.subtitle,
                    isCustom = false,
                    usageCount = usageCounts[entry.key] ?: 0,
                    onClick = { selection = CloneCatalogSelection.Builtin(entry) },
                )
            }
        }
        if (custom.isNotEmpty()) {
            item { SectionHeader("Custom — this vineyard · ${custom.size}", onLight = true) }
            items(custom.size) { index ->
                val row = custom[index]
                CloneCatalogCard(
                    title = row.displayName,
                    varietyName = varietyDisplayName(state, row.varietyKey),
                    subtitle = "Custom · this vineyard",
                    isCustom = true,
                    usageCount = usageCounts[row.cloneKey] ?: 0,
                    onClick = { selection = CloneCatalogSelection.Custom(row) },
                )
            }
        }
        item {
            Text(
                "Built-in clones come from the shared catalogue and are read-only. " +
                    "Custom clones belong to this vineyard and sync to every member. " +
                    "\u201CMass selection\u201D is recorded directly on block allocations — it is not a catalogue entry.",
                color = vine.textSecondary, fontSize = 12.sp,
            )
        }
    }

    selection?.let { sel ->
        CloneDetailSheet(
            vm = vm,
            state = state,
            selection = sel,
            canManage = canManage,
            onDismiss = { selection = null },
        )
    }

    if (adding) {
        AddCustomCloneSheet(vm = vm, state = state, onDismiss = onDismissAdd)
    }
}

@Composable
private fun CloneCatalogCard(
    title: String,
    varietyName: String,
    subtitle: String,
    isCustom: Boolean,
    usageCount: Int,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp))
                    .background((if (isCustom) VineColors.Orange else VineColors.LeafGreen).copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Spa, contentDescription = null,
                    tint = if (isCustom) VineColors.Orange else VineColors.LeafGreen,
                    modifier = Modifier.size(20.dp),
                )
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        title, color = vine.textPrimary, fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold, maxLines = 1,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    StatusBadge(if (isCustom) "Custom" else "Built-in", if (isCustom) VineColors.Orange else VineColors.LeafGreen)
                }
                val sub = buildList {
                    add(varietyName)
                    if (subtitle.isNotBlank()) add(subtitle)
                    add(if (usageCount == 0) "No allocations" else "$usageCount allocation${if (usageCount == 1) "" else "s"}")
                }
                Text(sub.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp, maxLines = 2)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CloneDetailSheet(
    vm: AppViewModel,
    state: AppUiState,
    selection: CloneCatalogSelection,
    canManage: Boolean,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    var confirmArchive by remember { mutableStateOf(false) }
    var archiving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    val title: String
    val varietyName: String
    val isCustom: Boolean
    val metadata: List<Pair<String, String>>
    val usages: List<CatalogAllocationUsage>
    val customRow: VineyardCloneRow?
    when (selection) {
        is CloneCatalogSelection.Builtin -> {
            val e = selection.entry
            title = e.displayName
            varietyName = varietyDisplayName(state, e.varietyKey)
            isCustom = false
            customRow = null
            metadata = buildList {
                add("Variety" to varietyName)
                add("Clone code" to e.cloneCode)
                e.selectionSystem?.let { add("Selection system" to it) }
                e.sourceCountry?.let { add("Source" to it) }
                if (e.aliases.isNotEmpty()) add("Also known as" to e.aliases.joinToString(", "))
                e.sourceReference?.let { add("Reference" to it) }
            }
            usages = cloneUsages(state.paddocks, e.key, CloneRootstockBrowse.cloneMatchNames(e))
        }
        is CloneCatalogSelection.Custom -> {
            val r = selection.row
            title = r.displayName
            varietyName = varietyDisplayName(state, r.varietyKey)
            isCustom = true
            customRow = r
            metadata = listOf("Variety" to varietyName, "Scope" to "Custom · this vineyard")
            usages = cloneUsages(state.paddocks, r.cloneKey, listOf(r.displayName))
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        CatalogDetailBody(
            title = title,
            badge = if (isCustom) "Custom" else "Built-in",
            badgeTint = if (isCustom) VineColors.Orange else VineColors.LeafGreen,
            metadata = metadata,
            usages = usages,
            usageNoun = "clone",
            error = error,
            archiveVisible = isCustom && canManage,
            archiving = archiving,
            onArchive = { confirmArchive = true },
            readOnlyNote = if (!isCustom) "Built-in catalogue records are read-only." else null,
        )
    }

    if (confirmArchive && customRow != null) {
        AlertDialog(
            onDismissRequest = { confirmArchive = false },
            title = { Text("Archive this custom clone?") },
            text = { Text("It will be hidden from pickers and this list. Blocks that already use it keep their records.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmArchive = false
                    archiving = true
                    error = null
                    vm.archiveCustomClone(customRow.id) { ok ->
                        archiving = false
                        if (ok) onDismiss() else error = "Couldn't archive this clone. Check your connection and try again."
                    }
                }) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmArchive = false }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddCustomCloneSheet(
    vm: AppViewModel,
    state: AppUiState,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val varieties = remember(state.grapeVarieties) {
        state.grapeVarieties.filter { it.isActive }.sortedBy { it.displayName.lowercase() }
    }
    var varietyKey by remember { mutableStateOf<String?>(null) }
    var name by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var menuOpen by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("New Custom Clone", color = vine.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)

            Box {
                OutlinedButton(onClick = { menuOpen = true }, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        varietyKey?.let { varietyDisplayName(state, it) } ?: "Select variety",
                        modifier = Modifier.weight(1f),
                        color = if (varietyKey == null) vine.textSecondary else vine.textPrimary,
                    )
                    Icon(Icons.Filled.ExpandMore, contentDescription = null, tint = vine.textSecondary)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    varieties.forEach { v ->
                        DropdownMenuItem(
                            text = { Text(v.displayName) },
                            onClick = { varietyKey = v.varietyKey; menuOpen = false; error = null },
                        )
                    }
                }
            }

            OutlinedTextField(
                value = name,
                onValueChange = { name = it; error = null },
                label = { Text("Clone name / code") },
                placeholder = { Text("e.g. BVRC 17") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Saved to this vineyard under the selected variety and synced to every member. A clone always belongs to one variety.",
                color = vine.textSecondary, fontSize = 12.sp,
            )
            error?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }

            Button(
                onClick = {
                    val key = varietyKey ?: return@Button
                    saving = true
                    error = null
                    vm.addCustomClone(key, name.trim()) { row ->
                        saving = false
                        if (row != null) onDismiss()
                        else error = "Couldn't save this clone. You need owner/manager access and a connection — reserved or duplicate names are also rejected."
                    }
                },
                enabled = varietyKey != null && name.trim().isNotEmpty() && !saving,
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (saving) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                } else {
                    Text("Save", color = Color.White)
                }
            }
        }
    }
}

// =========================================================================
// Rootstocks tab
// =========================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RootstocksCatalogContent(
    vm: AppViewModel,
    state: AppUiState,
    canManage: Boolean,
    adding: Boolean,
    onDismissAdd: () -> Unit,
) {
    val vine = LocalVineColors.current
    var query by rememberSaveable { mutableStateOf("") }
    var selection by remember { mutableStateOf<RootstockCatalogSelection?>(null) }

    val customRows = remember(state.vineyardRootstocks, state.selectedVineyardId) {
        state.vineyardRootstocks.filter { it.vineyardId == state.selectedVineyardId }
    }
    val builtin = remember(state.rootstockCatalog, query) {
        CloneRootstockBrowse.systemRootstocks(state.rootstockCatalog, query)
            .sortedBy { it.displayName.lowercase() }
    }
    val custom = remember(customRows, query) {
        CloneRootstockBrowse.customRootstocks(customRows, query)
            .sortedBy { it.displayName.lowercase() }
    }
    val usageCounts = remember(state.paddocks, builtin, custom) {
        buildMap {
            builtin.forEach { entry ->
                put(entry.key, rootstockUsages(state.paddocks, entry.key, CloneRootstockBrowse.rootstockMatchNames(entry)).size)
            }
            custom.forEach { row ->
                put(row.rootstockKey, rootstockUsages(state.paddocks, row.rootstockKey, listOf(row.displayName)).size)
            }
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            CatalogSearchField(
                value = query,
                onValueChange = { query = it },
                placeholder = "Search rootstocks",
            )
        }
        if (builtin.isEmpty() && custom.isEmpty()) {
            item {
                EmptyState(
                    icon = Icons.Filled.ForkLeft,
                    title = "No rootstocks found",
                    message = if (query.isBlank()) {
                        "The shared rootstock catalogue is loading."
                    } else {
                        "No rootstocks match \u201C${query.trim()}\u201D."
                    },
                )
            }
        }
        if (builtin.isNotEmpty()) {
            item { SectionHeader("Built-in · ${builtin.size}", onLight = true) }
            items(builtin.size) { index ->
                val entry = builtin[index]
                RootstockCatalogCard(
                    title = entry.displayName,
                    subtitle = entry.parentage ?: "",
                    aliases = entry.aliases,
                    isCustom = false,
                    usageCount = usageCounts[entry.key] ?: 0,
                    onClick = { selection = RootstockCatalogSelection.Builtin(entry) },
                )
            }
        }
        if (custom.isNotEmpty()) {
            item { SectionHeader("Custom — this vineyard · ${custom.size}", onLight = true) }
            items(custom.size) { index ->
                val row = custom[index]
                RootstockCatalogCard(
                    title = row.displayName,
                    subtitle = "Custom · this vineyard",
                    aliases = emptyList(),
                    isCustom = true,
                    usageCount = usageCounts[row.rootstockKey] ?: 0,
                    onClick = { selection = RootstockCatalogSelection.Custom(row) },
                )
            }
        }
        item {
            Text(
                "Built-in rootstocks come from the shared catalogue and are read-only. " +
                    "Custom rootstocks belong to this vineyard and sync to every member. " +
                    "\u201COwn roots / ungrafted\u201D is recorded directly on block allocations — it is not a catalogue entry.",
                color = vine.textSecondary, fontSize = 12.sp,
            )
        }
    }

    selection?.let { sel ->
        RootstockDetailSheet(
            vm = vm,
            state = state,
            selection = sel,
            canManage = canManage,
            onDismiss = { selection = null },
        )
    }

    if (adding) {
        AddCustomRootstockSheet(vm = vm, onDismiss = onDismissAdd)
    }
}

@Composable
private fun RootstockCatalogCard(
    title: String,
    subtitle: String,
    aliases: List<String>,
    isCustom: Boolean,
    usageCount: Int,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp))
                    .background((if (isCustom) VineColors.Orange else VineColors.Indigo).copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.ForkLeft, contentDescription = null,
                    tint = if (isCustom) VineColors.Orange else VineColors.Indigo,
                    modifier = Modifier.size(20.dp),
                )
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        title, color = vine.textPrimary, fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold, maxLines = 1,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    StatusBadge(if (isCustom) "Custom" else "Built-in", if (isCustom) VineColors.Orange else VineColors.Indigo)
                }
                val sub = buildList {
                    if (subtitle.isNotBlank()) add(subtitle)
                    if (aliases.isNotEmpty()) add("aka ${aliases.joinToString(", ")}")
                    add(if (usageCount == 0) "No allocations" else "$usageCount allocation${if (usageCount == 1) "" else "s"}")
                }
                Text(sub.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp, maxLines = 2)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RootstockDetailSheet(
    vm: AppViewModel,
    state: AppUiState,
    selection: RootstockCatalogSelection,
    canManage: Boolean,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    var confirmArchive by remember { mutableStateOf(false) }
    var archiving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    val title: String
    val isCustom: Boolean
    val metadata: List<Pair<String, String>>
    val usages: List<CatalogAllocationUsage>
    val customRow: VineyardRootstockRow?
    when (selection) {
        is RootstockCatalogSelection.Builtin -> {
            val e = selection.entry
            title = e.displayName
            isCustom = false
            customRow = null
            metadata = buildList {
                e.parentage?.let { add("Parentage" to it) }
                if (e.aliases.isNotEmpty()) add("Also known as" to e.aliases.joinToString(", "))
                e.sourceReference?.let { add("Reference" to it) }
            }
            usages = rootstockUsages(state.paddocks, e.key, CloneRootstockBrowse.rootstockMatchNames(e))
        }
        is RootstockCatalogSelection.Custom -> {
            val r = selection.row
            title = r.displayName
            isCustom = true
            customRow = r
            metadata = listOf("Scope" to "Custom · this vineyard")
            usages = rootstockUsages(state.paddocks, r.rootstockKey, listOf(r.displayName))
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        CatalogDetailBody(
            title = title,
            badge = if (isCustom) "Custom" else "Built-in",
            badgeTint = if (isCustom) VineColors.Orange else VineColors.Indigo,
            metadata = metadata,
            usages = usages,
            usageNoun = "rootstock",
            error = error,
            archiveVisible = isCustom && canManage,
            archiving = archiving,
            onArchive = { confirmArchive = true },
            readOnlyNote = if (!isCustom) "Built-in catalogue records are read-only." else null,
        )
    }

    if (confirmArchive && customRow != null) {
        AlertDialog(
            onDismissRequest = { confirmArchive = false },
            title = { Text("Archive this custom rootstock?") },
            text = { Text("It will be hidden from pickers and this list. Blocks that already use it keep their records.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmArchive = false
                    archiving = true
                    error = null
                    vm.archiveCustomRootstock(customRow.id) { ok ->
                        archiving = false
                        if (ok) onDismiss() else error = "Couldn't archive this rootstock. Check your connection and try again."
                    }
                }) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmArchive = false }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddCustomRootstockSheet(
    vm: AppViewModel,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    var name by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("New Custom Rootstock", color = vine.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)

            OutlinedTextField(
                value = name,
                onValueChange = { name = it; error = null },
                label = { Text("Rootstock name") },
                placeholder = { Text("e.g. Trial Stock 7") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Saved to this vineyard and synced to every member. Names that duplicate a built-in rootstock are rejected — pick the catalogue record instead.",
                color = vine.textSecondary, fontSize = 12.sp,
            )
            error?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }

            Button(
                onClick = {
                    saving = true
                    error = null
                    vm.addCustomRootstock(name.trim()) { row ->
                        saving = false
                        if (row != null) onDismiss()
                        else error = "Couldn't save this rootstock. You need owner/manager access and a connection — reserved names and duplicates of built-ins are rejected."
                    }
                },
                enabled = name.trim().isNotEmpty() && !saving,
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (saving) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
                } else {
                    Text("Save", color = Color.White)
                }
            }
        }
    }
}

// =========================================================================
// Shared pieces
// =========================================================================

@Composable
private fun CatalogSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
) {
    val vine = LocalVineColors.current
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text(placeholder) },
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, tint = vine.textSecondary) },
        trailingIcon = {
            if (value.isNotEmpty()) {
                IconButton(onClick = { onValueChange("") }) {
                    Icon(Icons.Filled.Close, contentDescription = "Clear search", tint = vine.textSecondary)
                }
            }
        },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun VarietyFilterDropdown(
    state: AppUiState,
    filterKeys: List<String>,
    selectedKey: String?,
    onSelect: (String?) -> Unit,
) {
    val vine = LocalVineColors.current
    var open by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { open = true }, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Filled.Spa, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(8.dp))
            Text(
                selectedKey?.let { varietyDisplayName(state, it) } ?: "All varieties",
                modifier = Modifier.weight(1f),
                color = vine.textPrimary,
            )
            Icon(Icons.Filled.ExpandMore, contentDescription = null, tint = vine.textSecondary)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text("All varieties") },
                onClick = { onSelect(null); open = false },
            )
            filterKeys.forEach { key ->
                DropdownMenuItem(
                    text = { Text(varietyDisplayName(state, key)) },
                    onClick = { onSelect(key); open = false },
                )
            }
        }
    }
}

@Composable
private fun CatalogDetailBody(
    title: String,
    badge: String,
    badgeTint: Color,
    metadata: List<Pair<String, String>>,
    usages: List<CatalogAllocationUsage>,
    usageNoun: String,
    error: String?,
    archiveVisible: Boolean,
    archiving: Boolean,
    onArchive: () -> Unit,
    readOnlyNote: String?,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                title, color = vine.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f, fill = false),
            )
            StatusBadge(badge, badgeTint)
        }

        if (metadata.isNotEmpty()) {
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    metadata.forEach { (label, value) ->
                        Row {
                            Text(label, color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                            Text(
                                value, color = vine.textPrimary, fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                                modifier = Modifier.weight(1.4f),
                            )
                        }
                    }
                }
            }
        }

        SectionHeader("Linked blocks · ${usages.size}", onLight = true)
        if (usages.isEmpty()) {
            VineyardCard {
                Text("No block allocations currently use this $usageNoun.", color = vine.textSecondary, fontSize = 13.sp)
            }
        } else {
            usages.forEach { usage ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Filled.Map, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(usage.paddock.name, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                            val label = allocationLabel(usage)
                            if (label.isNotBlank()) {
                                Text(label, color = vine.textSecondary, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }
        }

        readOnlyNote?.let {
            Text(it, color = vine.textSecondary, fontSize = 12.sp)
        }
        error?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }

        if (archiveVisible) {
            OutlinedButton(
                onClick = onArchive,
                enabled = !archiving,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = VineColors.Destructive),
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (archiving) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Filled.Archive, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Archive Custom Record")
                }
            }
        }
    }
}
