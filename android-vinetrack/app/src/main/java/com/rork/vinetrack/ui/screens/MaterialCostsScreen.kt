package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.material.MaterialCategoryCatalog
import com.rork.vinetrack.data.material.MaterialLibraryEntry
import com.rork.vinetrack.data.material.MaterialMoney
import com.rork.vinetrack.data.material.MaterialUnitCatalog
import com.rork.vinetrack.data.material.VineyardMaterial
import com.rork.vinetrack.data.material.WorkTaskMaterial
import com.rork.vinetrack.data.material.WorkTaskMaterialCosting
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.math.BigDecimal
import java.math.RoundingMode

internal fun materialCurrency(value: BigDecimal, formatter: RegionFormatter): String =
    "${formatter.currencySymbol}${value.setScale(2, RoundingMode.HALF_UP).toPlainString()}"

private fun materialDecimal(value: BigDecimal): String = value.stripTrailingZeros().toPlainString()

@Composable
fun WorkTaskMaterialCostsSection(
    vm: AppViewModel,
    state: AppUiState,
    taskId: String,
    modifier: Modifier = Modifier,
) {
    if (!vm.materialCostsAccess().isAllowed) return
    val vine = LocalVineColors.current
    val formatter = LocalRegionFormatter.current
    val lines = remember(state.taskMaterials, taskId) {
        WorkTaskMaterialCosting.lines(state.taskMaterials, taskId)
    }
    val total = remember(lines) { WorkTaskMaterialCosting.total(lines) }
    var showPicker by remember { mutableStateOf(false) }
    var selectedEntry by remember { mutableStateOf<MaterialLibraryEntry?>(null) }
    var editingLine by remember { mutableStateOf<WorkTaskMaterial?>(null) }
    var deletingLine by remember { mutableStateOf<WorkTaskMaterial?>(null) }

    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionHeader("Material Costs", onLight = true)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { showPicker = true }) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp), tint = VineColors.PrimaryAccent)
                Text("  Add Material", color = VineColors.PrimaryAccent)
            }
        }
        VineyardCard {
            if (state.materialLibraryLoading && lines.isEmpty()) {
                Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(modifier = Modifier.size(22.dp), color = VineColors.LeafGreen)
                }
            } else if (lines.isEmpty()) {
                Text("No materials added", color = vine.textSecondary, fontSize = 14.sp, modifier = Modifier.padding(vertical = 8.dp))
            } else {
                lines.forEachIndexed { index, line ->
                    if (index > 0) HorizontalDivider(color = vine.cardBorder)
                    MaterialTaskLineRow(line, formatter) { editingLine = line }
                }
            }
            HorizontalDivider(color = vine.cardBorder)
            Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Material Total", modifier = Modifier.weight(1f), fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Text(materialCurrency(total, formatter), fontWeight = FontWeight.Bold, color = VineColors.PrimaryAccent)
            }
            state.materialLibraryError?.let {
                Text("Using the saved material library. Refresh failed; pending changes will retry automatically.", color = VineColors.Warning, fontSize = 12.sp)
            }
        }
    }

    if (showPicker) {
        MaterialPickerDialog(vm.materialLibrary(), formatter, onDismiss = { showPicker = false }) {
            showPicker = false
            selectedEntry = it
        }
    }
    selectedEntry?.let { entry ->
        TaskMaterialEditorDialog(
            entry = entry,
            existing = null,
            formatter = formatter,
            isBusy = state.taskLineBusy,
            onDismiss = { selectedEntry = null },
            onSave = { quantity, unit, cost ->
                vm.saveTaskMaterial(
                    materialId = null,
                    taskId = taskId,
                    baseMaterialId = entry.baseMaterialId,
                    vineyardMaterialId = entry.vineyardMaterialId,
                    materialName = entry.name,
                    category = entry.category,
                    unit = unit,
                    quantity = quantity,
                    unitCost = cost,
                    notes = null,
                ) { if (it) selectedEntry = null }
            },
        )
    }
    editingLine?.let { line ->
        TaskMaterialEditorDialog(
            entry = null,
            existing = line,
            formatter = formatter,
            isBusy = state.taskLineBusy,
            onDismiss = { editingLine = null },
            onDelete = { deletingLine = line },
            onSave = { quantity, unit, cost ->
                vm.saveTaskMaterial(
                    materialId = line.id,
                    taskId = taskId,
                    baseMaterialId = line.baseMaterialId,
                    vineyardMaterialId = line.vineyardMaterialId,
                    materialName = line.materialName,
                    category = line.category,
                    unit = unit,
                    quantity = quantity,
                    unitCost = cost,
                    notes = line.notes,
                ) { if (it) editingLine = null }
            },
        )
    }
    deletingLine?.let { line ->
        AlertDialog(
            onDismissRequest = { deletingLine = null },
            title = { Text("Remove material?") },
            text = { Text("${line.materialName} will be removed from this task. The vineyard library will not be changed.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteTaskMaterial(line.id, taskId) { if (it) { deletingLine = null; editingLine = null } }
                }) { Text("Remove", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { deletingLine = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun MaterialTaskLineRow(line: WorkTaskMaterial, formatter: RegionFormatter, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(line.materialName, color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(
                "${materialDecimal(line.quantity)} ${line.unit} × ${materialCurrency(line.unitCost, formatter)}",
                color = vine.textSecondary,
                fontSize = 12.sp,
            )
        }
        Text(materialCurrency(line.totalCost, formatter), color = vine.textPrimary, fontWeight = FontWeight.Bold)
        Icon(Icons.Filled.Edit, contentDescription = "Edit material", tint = vine.textSecondary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun MaterialPickerDialog(
    entries: List<MaterialLibraryEntry>,
    formatter: RegionFormatter,
    onDismiss: () -> Unit,
    onSelect: (MaterialLibraryEntry) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val filtered = remember(entries, query) { entries.filter { it.name.contains(query.trim(), ignoreCase = true) } }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Material") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    label = { Text("Search materials") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = 480.dp)) {
                    MaterialCategoryCatalog.ordered.forEach { category ->
                        val grouped = filtered.filter { it.category == category }
                        if (grouped.isNotEmpty()) {
                            item(key = "header-$category") {
                                Text(category, fontWeight = FontWeight.Bold, color = VineColors.PrimaryAccent, modifier = Modifier.padding(top = 10.dp, bottom = 4.dp))
                            }
                            items(grouped, key = { it.id }) { entry ->
                                Column(
                                    Modifier.fillMaxWidth().clickable { onSelect(entry) }.padding(vertical = 9.dp),
                                    verticalArrangement = Arrangement.spacedBy(2.dp),
                                ) {
                                    Text(entry.name, fontWeight = FontWeight.SemiBold)
                                    Text(
                                        entry.defaultUnitCost?.let { "${entry.unit} • ${materialCurrency(it, formatter)}" } ?: "${entry.unit} • No default cost",
                                        fontSize = 12.sp,
                                    )
                                }
                            }
                        }
                    }
                    if (filtered.isEmpty()) item { Text("No materials match your search.", modifier = Modifier.padding(vertical = 16.dp)) }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TaskMaterialEditorDialog(
    entry: MaterialLibraryEntry?,
    existing: WorkTaskMaterial?,
    formatter: RegionFormatter,
    isBusy: Boolean,
    onDismiss: () -> Unit,
    onDelete: (() -> Unit)? = null,
    onSave: (BigDecimal, String, BigDecimal) -> Unit,
) {
    var quantityText by remember(existing?.id, entry?.id) { mutableStateOf(existing?.quantity?.let(::materialDecimal) ?: "") }
    var unit by remember(existing?.id, entry?.id) { mutableStateOf(existing?.unit ?: entry?.unit ?: "Each") }
    var costText by remember(existing?.id, entry?.id) { mutableStateOf(existing?.unitCost?.let(::materialDecimal) ?: entry?.defaultUnitCost?.let(::materialDecimal) ?: "") }
    var unitMenu by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val quantity = quantityText.replace(',', '.').toBigDecimalOrNull()
    val cost = costText.replace(',', '.').toBigDecimalOrNull()
    val total = if (quantity != null && cost != null) MaterialMoney.lineTotal(quantity, cost) else BigDecimal.ZERO
    val name = existing?.materialName ?: entry?.name ?: "Material"

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (existing == null) "Add Material" else "Edit Material") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(name, fontWeight = FontWeight.SemiBold)
                OutlinedTextField(
                    value = quantityText,
                    onValueChange = { quantityText = it.filter { c -> c.isDigit() || c == '.' || c == ',' }; error = null },
                    label = { Text("Quantity") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                ExposedDropdownMenuBox(expanded = unitMenu, onExpandedChange = { unitMenu = it }) {
                    OutlinedTextField(
                        value = unit,
                        onValueChange = { unit = it },
                        label = { Text("Unit") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = unitMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryEditable),
                    )
                    ExposedDropdownMenu(expanded = unitMenu, onDismissRequest = { unitMenu = false }) {
                        MaterialUnitCatalog.suggested.forEach { suggestion ->
                            DropdownMenuItem(text = { Text(suggestion) }, onClick = { unit = suggestion; unitMenu = false })
                        }
                    }
                }
                OutlinedTextField(
                    value = costText,
                    onValueChange = { costText = it.filter { c -> c.isDigit() || c == '.' || c == ',' }; error = null },
                    label = { Text("Unit Cost") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(Modifier.fillMaxWidth()) {
                    Text("Material Total", modifier = Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                    Text(materialCurrency(total, formatter), fontWeight = FontWeight.Bold, color = VineColors.PrimaryAccent)
                }
                if (existing != null) Text("To replace the material, remove this line and add the new material.", fontSize = 12.sp)
                error?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }
            }
        },
        confirmButton = {
            Button(enabled = !isBusy, onClick = {
                when {
                    quantity == null -> error = "Enter a quantity."
                    quantity <= BigDecimal.ZERO -> error = "Quantity must be greater than zero."
                    unit.isBlank() -> error = "Enter a unit."
                    cost == null || cost < BigDecimal.ZERO -> error = "Enter a valid unit cost."
                    else -> onSave(quantity, MaterialUnitCatalog.normalised(unit), cost)
                }
            }) { Text("Save") }
        },
        dismissButton = {
            Row {
                onDelete?.let { delete ->
                    TextButton(onClick = delete) { Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive); Text(" Remove", color = VineColors.Destructive) }
                }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MaterialLibraryScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    if (!vm.materialCostsAccess().isAllowed) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val vine = LocalVineColors.current
    val formatter = LocalRegionFormatter.current
    var query by remember { mutableStateOf("") }
    var editingEntry by remember { mutableStateOf<MaterialLibraryEntry?>(null) }
    var editingMaterial by remember { mutableStateOf<VineyardMaterial?>(null) }
    var addingCustom by remember { mutableStateOf(false) }
    val entries = remember(state.materialCatalogue, state.vineyardMaterials, query) {
        vm.materialLibrary().filter { it.name.contains(query.trim(), ignoreCase = true) }
    }
    val inactive = remember(state.vineyardMaterials, state.selectedVineyardId) {
        state.vineyardMaterials.filter { it.vineyardId == state.selectedVineyardId && it.isCustom && !it.isActive && it.deletedAt == null }
    }

    LaunchedEffect(state.selectedVineyardId) { vm.loadMaterialLibrary() }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Material Library") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
                actions = {
                    IconButton(onClick = { vm.loadMaterialLibrary() }) { Icon(Icons.Filled.Refresh, contentDescription = "Retry refresh") }
                    IconButton(onClick = { addingCustom = true }) { Icon(Icons.Filled.Add, contentDescription = "Add custom material") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    label = { Text("Search materials") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
            }
            if (state.materialLibraryLoading && entries.isEmpty()) {
                item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
            }
            state.materialLibraryError?.let {
                item {
                    VineyardCard {
                        Text("Showing the saved library. Refresh failed; pending changes will retry automatically.", color = VineColors.Warning, fontSize = 13.sp)
                        TextButton(onClick = { vm.loadMaterialLibrary() }) { Text("Retry") }
                    }
                }
            }
            MaterialCategoryCatalog.ordered.forEach { category ->
                val grouped = entries.filter { it.category == category }
                if (grouped.isNotEmpty()) {
                    item(key = "category-$category") { SectionHeader(category, onLight = true) }
                    item(key = "card-$category") {
                        VineyardCard {
                            grouped.forEachIndexed { index, entry ->
                                if (index > 0) HorizontalDivider(color = vine.cardBorder)
                                MaterialLibraryRow(entry, formatter) { editingEntry = entry }
                            }
                        }
                    }
                }
            }
            if (inactive.isNotEmpty()) {
                item { SectionHeader("Inactive Custom Materials", onLight = true) }
                item {
                    VineyardCard {
                        inactive.forEachIndexed { index, material ->
                            if (index > 0) HorizontalDivider(color = vine.cardBorder)
                            Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(material.name, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                                    Text("${material.category} • ${material.unit}", fontSize = 12.sp, color = vine.textSecondary)
                                }
                                TextButton(onClick = { saveExistingLibraryMaterial(vm, material, isActive = true) }) { Text("Reactivate") }
                            }
                        }
                    }
                }
            }
            item { Spacer(Modifier.padding(bottom = 12.dp)) }
        }
    }

    if (addingCustom) LibraryMaterialEditorDialog(vm, state, null, null, formatter, onDismiss = { addingCustom = false })
    editingEntry?.let { entry ->
        val material = entry.vineyardMaterialId?.let { id -> state.vineyardMaterials.firstOrNull { it.id == id } }
        LibraryMaterialEditorDialog(vm, state, entry, material, formatter, onDismiss = { editingEntry = null })
    }
    editingMaterial?.let { material ->
        LibraryMaterialEditorDialog(vm, state, null, material, formatter, onDismiss = { editingMaterial = null })
    }
}

@Composable
private fun MaterialLibraryRow(entry: MaterialLibraryEntry, formatter: RegionFormatter, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(entry.name, color = vine.textPrimary, fontWeight = FontWeight.SemiBold)
            Text(entry.defaultUnitCost?.let { "${entry.unit} • Default cost: ${materialCurrency(it, formatter)}" } ?: "${entry.unit} • No default cost", color = vine.textSecondary, fontSize = 12.sp)
        }
        if (entry.isCustom) Text("Custom", color = VineColors.PrimaryAccent, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        Icon(Icons.Filled.Edit, contentDescription = "Edit material", tint = vine.textSecondary, modifier = Modifier.padding(start = 8.dp).size(18.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LibraryMaterialEditorDialog(
    vm: AppViewModel,
    state: AppUiState,
    entry: MaterialLibraryEntry?,
    existing: VineyardMaterial?,
    formatter: RegionFormatter,
    onDismiss: () -> Unit,
) {
    val isStandard = entry != null && !entry.isCustom
    var name by remember(existing?.id, entry?.id) { mutableStateOf(existing?.name ?: entry?.name ?: "") }
    var category by remember(existing?.id, entry?.id) { mutableStateOf(existing?.category ?: entry?.category ?: MaterialCategoryCatalog.OTHER) }
    var unit by remember(existing?.id, entry?.id) { mutableStateOf(existing?.unit ?: entry?.unit ?: "Each") }
    var costText by remember(existing?.id, entry?.id) { mutableStateOf(existing?.defaultUnitCost?.let(::materialDecimal) ?: entry?.defaultUnitCost?.let(::materialDecimal) ?: "") }
    var categoryMenu by remember { mutableStateOf(false) }
    var unitMenu by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmDeactivate by remember { mutableStateOf(false) }

    fun save() {
        val cost = costText.replace(',', '.').toBigDecimalOrNull()
        when {
            name.isBlank() -> error = "Enter a material name."
            unit.isBlank() -> error = "Enter a unit."
            costText.isNotBlank() && (cost == null || cost < BigDecimal.ZERO) -> error = "Enter a valid unit cost."
            isStandard && entry?.baseMaterialId == null -> error = "Connect once to load the standard catalogue before setting its default price."
            else -> vm.saveVineyardMaterial(
                materialId = existing?.id ?: entry?.vineyardMaterialId,
                baseMaterialId = if (isStandard) entry?.baseMaterialId else null,
                name = if (isStandard) entry?.name.orEmpty() else name.trim(),
                category = if (isStandard) entry?.category.orEmpty() else category,
                unit = MaterialUnitCatalog.normalised(unit),
                defaultUnitCost = cost,
                isCustom = !isStandard,
                isActive = true,
            ) { if (it) onDismiss() else error = "Material could not be saved. Check access and try again." }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (isStandard) "Standard Material" else if (existing == null) "Add Custom Material" else "Edit Custom Material") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (isStandard) Text(name, fontWeight = FontWeight.SemiBold) else OutlinedTextField(name, { name = it; error = null }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                ExposedDropdownMenuBox(expanded = categoryMenu, onExpandedChange = { if (!isStandard) categoryMenu = it }) {
                    OutlinedTextField(category, {}, readOnly = true, enabled = !isStandard, label = { Text("Category") }, trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(categoryMenu) }, modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable))
                    ExposedDropdownMenu(expanded = categoryMenu, onDismissRequest = { categoryMenu = false }) {
                        MaterialCategoryCatalog.ordered.forEach { value -> DropdownMenuItem(text = { Text(value) }, onClick = { category = value; categoryMenu = false }) }
                    }
                }
                ExposedDropdownMenuBox(expanded = unitMenu, onExpandedChange = { unitMenu = it }) {
                    OutlinedTextField(unit, { unit = it }, label = { Text("Unit") }, trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(unitMenu) }, modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryEditable))
                    ExposedDropdownMenu(expanded = unitMenu, onDismissRequest = { unitMenu = false }) {
                        MaterialUnitCatalog.suggested.forEach { value -> DropdownMenuItem(text = { Text(value) }, onClick = { unit = value; unitMenu = false }) }
                    }
                }
                OutlinedTextField(costText, { costText = it.filter { c -> c.isDigit() || c == '.' || c == ',' }; error = null }, label = { Text("Default Unit Cost (optional)") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth(), singleLine = true)
                Text("Changing this default never changes existing Work Task snapshots.", fontSize = 12.sp)
                error?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }
            }
        },
        confirmButton = { Button(onClick = ::save) { Text("Save") } },
        dismissButton = {
            Row {
                if (existing?.isCustom == true && existing.isActive) {
                    TextButton(onClick = { confirmDeactivate = true }) { Text("Deactivate", color = VineColors.Destructive) }
                }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )

    if (confirmDeactivate && existing != null) {
        AlertDialog(
            onDismissRequest = { confirmDeactivate = false },
            title = { Text("Deactivate material?") },
            text = { Text("It will disappear from new task selection but remain on historical Work Tasks.") },
            confirmButton = { TextButton(onClick = { saveExistingLibraryMaterial(vm, existing, isActive = false); onDismiss() }) { Text("Deactivate", color = VineColors.Destructive) } },
            dismissButton = { TextButton(onClick = { confirmDeactivate = false }) { Text("Cancel") } },
        )
    }
}

private fun saveExistingLibraryMaterial(vm: AppViewModel, material: VineyardMaterial, isActive: Boolean) {
    vm.saveVineyardMaterial(
        materialId = material.id,
        baseMaterialId = material.baseMaterialId,
        name = material.name,
        category = material.category,
        unit = material.unit,
        defaultUnitCost = material.defaultUnitCost,
        isCustom = material.isCustom,
        isActive = isActive,
    )
}
