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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Science
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.SavedChemicalRepository
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_HECTARE
import com.rork.vinetrack.data.model.ChemicalPurchase
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.chemicalUnitToBase
import java.util.UUID
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Brand colour for the spray chemicals surface (matches the Spray tool). */
private val ChemTint: Color = VineColors.Info

/** Chemical display units, mirroring the iOS `ChemicalUnit` raw values. */
private val chemicalUnits: List<String> = listOf("Litres", "mL", "Kg", "g")

/**
 * Spray chemicals library — the saved products reused across spray records.
 * Owners/managers can add, edit, and archive chemicals (including the
 * owner/manager-only cost per unit); other members get a read-only list with
 * pricing hidden, matching the iOS `ChemicalsManagementView` financial gating.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChemicalsScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"
    // Cost editing/visibility mirrors the spray form's canViewFinancials gate.
    val canViewFinancials = canManage

    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<SavedChemical?>(null) }
    var pendingDelete by remember { mutableStateOf<SavedChemical?>(null) }
    var search by remember { mutableStateOf("") }
    val filteredChemicals = remember(state.savedChemicals, search) {
        if (search.isBlank()) state.savedChemicals
        else state.savedChemicals.filter {
            it.displayName.contains(search.trim(), true) || it.manufacturer.contains(search.trim(), true)
        }
    }
    // Surfaced when the backend refuses a permanent delete because the chemical
    // is referenced by a record. Offers "Archive instead".
    var inUseChem by remember { mutableStateOf<SavedChemical?>(null) }
    var inUseMessage by remember { mutableStateOf("") }

    /**
     * Whether a chemical is referenced by any spray record on this device,
     * mirroring iOS `isSavedChemicalInUseLocally`. When in use, only Archive is
     * offered (the backend would reject a permanent delete anyway).
     */
    fun isInUseLocally(chem: SavedChemical): Boolean =
        state.sprayRecords.any { record ->
            record.tanks.orEmpty().any { tank ->
                tank.chemicals.any { it.savedChemicalId == chem.id }
            }
        }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Chemicals") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = ChemTint,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add chemical") }
            }
        },
    ) { padding ->
        if (state.savedChemicals.isEmpty()) {
            EmptyState(
                icon = Icons.Filled.Science,
                title = "No Chemicals",
                message = if (canManage) {
                    "Add chemicals to quickly select them in spray records."
                } else {
                    "The vineyard owner or manager hasn't added any saved chemicals yet."
                },
                actionLabel = if (canManage) "Add chemical" else null,
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
                        placeholder = { Text("Search chemicals...") },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (filteredChemicals.isEmpty()) {
                    item(key = "no-match") {
                        Text(
                            "No chemicals match your search.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.padding(vertical = 12.dp),
                        )
                    }
                }
                items(filteredChemicals, key = { it.id }) { chem ->
                    ChemicalRow(
                        chemical = chem,
                        canManage = canManage,
                        canViewFinancials = canViewFinancials,
                        onEdit = { if (canManage) editing = chem },
                        onDelete = { if (canManage) pendingDelete = chem },
                    )
                }
            }
        }
    }

    if (creating) {
        ChemicalFormSheet(
            vm = vm,
            existing = null,
            canViewFinancials = canViewFinancials,
            onDismiss = { creating = false },
        )
    }
    editing?.let { chem ->
        ChemicalFormSheet(
            vm = vm,
            existing = chem,
            canViewFinancials = canViewFinancials,
            onDismiss = { editing = null },
        )
    }
    pendingDelete?.let { chem ->
        val inUse = isInUseLocally(chem)
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(if (inUse) "Archive ${chem.displayName}?" else "Delete or archive ${chem.displayName}?") },
            text = {
                Text(
                    if (inUse) {
                        "Archive this chemical? It will be hidden from active chemical lists but kept for historical records."
                    } else {
                        "Archive hides this chemical but keeps it for historical records. Delete Permanently removes it entirely — only available because it has not been used in any spray records on this device. This cannot be undone."
                    }
                )
            },
            confirmButton = {
                Column {
                    TextButton(onClick = {
                        vm.deleteSavedChemical(chem.id) {}
                        pendingDelete = null
                    }) { Text("Archive Chemical") }
                    if (!inUse) {
                        TextButton(onClick = {
                            val target = chem
                            pendingDelete = null
                            vm.hardDeleteSavedChemical(target.id) { outcome ->
                                if (outcome is SavedChemicalRepository.HardDeleteOutcome.InUse) {
                                    inUseChem = target
                                    inUseMessage = outcome.message
                                }
                            }
                        }) { Text("Delete Permanently", color = VineColors.Destructive) }
                    }
                }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }

    // Backend rejected a permanent delete (chemical referenced by a record).
    inUseChem?.let { chem ->
        AlertDialog(
            onDismissRequest = { inUseChem = null },
            title = { Text("Cannot Delete") },
            text = { Text(inUseMessage) },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteSavedChemical(chem.id) {}
                    inUseChem = null
                }) { Text("Archive Instead") }
            },
            dismissButton = { TextButton(onClick = { inUseChem = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ChemicalRow(
    chemical: SavedChemical,
    canManage: Boolean,
    canViewFinancials: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = if (canManage) Modifier.clickable { onEdit() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(chemical.displayName, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp)
                // Active ingredient leads the subtitle (matches iOS ChemicalDetailRow);
                // manufacturer follows when present.
                val subtitle = buildList {
                    chemical.activeIngredient.takeIf { it.isNotBlank() }?.let { add(it) }
                    chemical.manufacturer.takeIf { it.isNotBlank() }?.let { add(it) }
                }.joinToString(" · ")
                if (subtitle.isNotEmpty()) {
                    Text(subtitle, fontSize = 13.sp, color = vine.textSecondary)
                }
                // Group / target-problem chips.
                val chips = buildList {
                    chemical.chemicalGroup.takeIf { it.isNotBlank() }?.let { add(it) }
                    chemical.problem.takeIf { it.isNotBlank() }?.let { add(it) }
                    chemical.modeOfAction.takeIf { it.isNotBlank() }?.let { add("MOA $it") }
                }
                if (chips.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        chips.take(3).forEach { ChemChip(it) }
                    }
                }
                // Dual rate basis lines.
                val rateLines = buildList {
                    chemical.ratePerHaDisplay?.takeIf { it > 0 }?.let { add("${trimNum(it)} ${chemical.unit}/ha") }
                    chemical.ratePer100LDisplay?.takeIf { it > 0 }?.let { add("${trimNum(it)} ${chemical.unit}/100L") }
                }
                if (rateLines.isNotEmpty()) {
                    Text(rateLines.joinToString("  ·  "), fontSize = 13.sp, color = vine.textSecondary)
                }
                if (canViewFinancials) {
                    val cost = chemical.costPerUnit
                    Text(
                        if (cost != null && cost > 0) "${formatChemCurrency(cost)} / ${chemical.unit}" else "No cost set",
                        fontSize = 13.sp,
                        color = if (cost != null && cost > 0) ChemTint else vine.textSecondary,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
            if (canManage) {
                IconButton(onClick = onDelete) {
                    Icon(Icons.Filled.Delete, contentDescription = "Archive chemical", tint = VineColors.Destructive, modifier = Modifier.size(20.dp))
                }
            }
        }
    }
}

/** Small capsule used for chemical group / problem / MOA metadata. */
@Composable
private fun ChemChip(text: String) {
    val vine = LocalVineColors.current
    Text(
        text,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        color = ChemTint,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(ChemTint.copy(alpha = 0.12f))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

/** Form types and the unit set each implies, mirroring iOS `ChemicalFormType`. */
private val liquidUnits: List<String> = listOf("Litres", "mL")
private val solidUnits: List<String> = listOf("Kg", "g")
private fun unitsForForm(form: String): List<String> = if (form == "Solid") solidUnits else liquidUnits
private fun formForUnit(unit: String): String = if (unit == "Kg" || unit == "g") "Solid" else "Liquid"

/** iOS `formatRate`: blank for 0, no decimals for integers, else 2 decimals. */
private fun formatRate(value: Double): String = when {
    value == 0.0 -> ""
    value % 1.0 == 0.0 -> "%.0f".format(value)
    else -> "%.2f".format(value)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChemicalFormSheet(
    vm: AppViewModel,
    existing: SavedChemical?,
    canViewFinancials: Boolean,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val uriHandler = LocalUriHandler.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val isEdit = existing != null

    val existingPerHaId = existing?.rates?.firstOrNull { it.basis == CHEMICAL_RATE_PER_HECTARE }?.id
    val existingPer100LId = existing?.rates?.firstOrNull { it.basis == CHEMICAL_RATE_PER_100L }?.id

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var formType by remember { mutableStateOf(formForUnit(existing?.unit ?: "Litres")) }
    var unit by remember { mutableStateOf(existing?.unit?.takeIf { it in chemicalUnits } ?: "Litres") }
    var activeIngredient by remember { mutableStateOf(existing?.activeIngredient ?: "") }
    var chemicalGroup by remember { mutableStateOf(existing?.chemicalGroup ?: "") }
    var use by remember { mutableStateOf(existing?.use ?: "") }
    var problem by remember { mutableStateOf(existing?.problem ?: "") }
    var manufacturer by remember { mutableStateOf(existing?.manufacturer ?: "") }
    var modeOfAction by remember { mutableStateOf(existing?.modeOfAction ?: "") }
    var labelUrl by remember { mutableStateOf(existing?.labelUrl ?: "") }
    var productUrl by remember { mutableStateOf(existing?.productUrl ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var ratePerHa by remember { mutableStateOf(existing?.ratePerHaDisplay?.let { formatRate(it) } ?: "") }
    var ratePer100L by remember { mutableStateOf(existing?.ratePer100LDisplay?.let { formatRate(it) } ?: "") }
    var trackPurchase by remember { mutableStateOf(existing?.purchase != null) }
    var containerSize by remember { mutableStateOf(existing?.purchase?.containerSizeML?.takeIf { it > 0 }?.let { formatRate(it) } ?: "") }
    var containerUnit by remember { mutableStateOf(existing?.purchase?.containerUnit?.takeIf { it in chemicalUnits } ?: (existing?.unit ?: "Litres")) }
    var cost by remember { mutableStateOf(existing?.purchase?.costDollars?.takeIf { it > 0 }?.let { formatRate(it) } ?: "") }
    var unitMenu by remember { mutableStateOf(false) }
    var containerUnitMenu by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var showAI by remember { mutableStateOf(false) }
    var aiLoading by remember { mutableStateOf(false) }
    var aiError by remember { mutableStateOf<String?>(null) }

    // Keep unit/container-unit valid when the form type flips.
    fun applyFormType(newForm: String) {
        formType = newForm
        val units = unitsForForm(newForm)
        if (unit !in units) unit = units.first()
        if (containerUnit !in units) containerUnit = units.first()
    }

    /** Prefill empty fields from an AI search pick, then deep-fetch details. */
    fun applyAIResult(result: ChemicalInfoService.ChemicalSearchResult) {
        aiError = null
        aiLoading = true
        if (result.name.isNotBlank()) name = result.name
        if (result.brand.isNotBlank()) manufacturer = result.brand
        if (activeIngredient.isBlank()) activeIngredient = result.activeIngredient
        if (chemicalGroup.isBlank()) chemicalGroup = result.chemicalGroup
        if (modeOfAction.isBlank()) modeOfAction = result.modeOfAction
        if (use.isBlank()) use = result.primaryUse
        if (problem.isBlank()) problem = result.primaryUse
        vm.lookupChemicalInfo(result.name.ifBlank { name }) { res ->
            aiLoading = false
            res.onSuccess { info ->
                if (activeIngredient.isBlank()) activeIngredient = info.activeIngredient
                if (manufacturer.isBlank() && info.brand.isNotBlank()) manufacturer = info.brand
                if (chemicalGroup.isBlank()) chemicalGroup = info.chemicalGroup
                if (labelUrl.isBlank()) labelUrl = info.labelURL
                if (productUrl.isBlank()) info.productURL?.let { productUrl = it }
                if (modeOfAction.isBlank()) info.modeOfAction?.let { modeOfAction = it }
                if (use.isBlank()) use = info.primaryUse
                applyFormType(formForUnit(info.defaultUnit))
                unit = info.defaultUnit
                if (ratePerHa.isBlank()) info.ratesPerHectare?.firstOrNull()?.let { ratePerHa = formatRate(it.value) }
                if (ratePer100L.isBlank()) info.ratesPer100L?.firstOrNull()?.let { ratePer100L = formatRate(it.value) }
            }
            res.onFailure { aiError = it.message }
        }
    }

    fun save() {
        if (saving) return
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return
        saving = true
        val perHaDisplay = ratePerHa.toDoubleSafe() ?: 0.0
        val per100LDisplay = ratePer100L.toDoubleSafe() ?: 0.0
        val rates = buildList {
            if (perHaDisplay > 0) add(
                ChemicalRate(
                    id = existingPerHaId ?: UUID.randomUUID().toString(),
                    label = "Per Ha",
                    value = chemicalUnitToBase(unit, perHaDisplay),
                    basis = CHEMICAL_RATE_PER_HECTARE,
                ),
            )
            if (per100LDisplay > 0) add(
                ChemicalRate(
                    id = existingPer100LId ?: UUID.randomUUID().toString(),
                    label = "Per 100L",
                    value = chemicalUnitToBase(unit, per100LDisplay),
                    basis = CHEMICAL_RATE_PER_100L,
                ),
            )
        }
        // Owners/managers author purchase data; others keep the existing snapshot
        // so editing other details never clears pricing (mirrors iOS save()).
        val purchase: ChemicalPurchase? = if (!canViewFinancials) {
            existing?.purchase
        } else if (trackPurchase) {
            val cs = containerSize.toDoubleSafe() ?: 0.0
            val costValue = cost.toDoubleSafe() ?: 0.0
            if (cs > 0 || costValue > 0) {
                ChemicalPurchase(
                    brand = manufacturer.trim(),
                    activeIngredient = activeIngredient.trim(),
                    chemicalGroup = chemicalGroup.trim(),
                    labelUrl = labelUrl.trim(),
                    costDollars = costValue,
                    containerSizeML = cs,
                    containerUnit = containerUnit,
                )
            } else null
        } else null
        val input = SavedChemicalRepository.ChemicalInput(
            name = trimmedName,
            unit = unit,
            ratePerHa = perHaDisplay,
            rates = rates,
            activeIngredient = activeIngredient.trim().ifBlank { null },
            chemicalGroup = chemicalGroup.trim().ifBlank { null },
            use = use.trim().ifBlank { null },
            problem = problem.trim().ifBlank { null },
            manufacturer = manufacturer.trim().ifBlank { null },
            notes = notes.trim().ifBlank { null },
            modeOfAction = modeOfAction.trim().ifBlank { null },
            labelUrl = labelUrl.trim().ifBlank { null },
            productUrl = productUrl.trim().ifBlank { null },
            purchase = purchase,
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (isEdit) vm.updateSavedChemical(existing!!.id, input, cb) else vm.createSavedChemical(input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (isEdit) "Edit chemical" else "New chemical",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            // Search with AI (advisory; must be checked against the label).
            OutlinedButton(
                onClick = { aiError = null; showAI = true },
                enabled = !aiLoading,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (aiLoading) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = ChemTint)
                    Spacer(Modifier.size(8.dp))
                    Text("Looking up...")
                } else {
                    Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = ChemTint, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Search with AI")
                }
            }
            aiError?.let { Text(it, fontSize = 12.sp, color = VineColors.Destructive) }
            Text(
                "AI suggestions must be checked against the current product label, permit, SDS, and local regulations before use.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            SectionLabel("Product")
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Chemical / product name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                listOf("Liquid", "Solid").forEachIndexed { index, f ->
                    SegmentedButton(
                        selected = formType == f,
                        onClick = { applyFormType(f) },
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = 2),
                    ) { Text(f) }
                }
            }
            UnitDropdown(
                label = "Unit",
                value = unit,
                options = unitsForForm(formType),
                expanded = unitMenu,
                onExpandedChange = { unitMenu = it },
                onSelect = { unit = it; unitMenu = false },
                modifier = Modifier.fillMaxWidth(),
            )

            SectionLabel("Details")
            OutlinedTextField(
                value = activeIngredient,
                onValueChange = { activeIngredient = it },
                label = { Text("Active ingredient") },
                placeholder = { Text("e.g. Glyphosate 360 g/L") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = chemicalGroup,
                    onValueChange = { chemicalGroup = it },
                    label = { Text("Chemical group") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = modeOfAction,
                    onValueChange = { modeOfAction = it },
                    label = { Text("MOA") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
            }
            OutlinedTextField(
                value = use,
                onValueChange = { use = it },
                label = { Text("Use (e.g. Fungicide)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = problem,
                onValueChange = { problem = it },
                label = { Text("Target problem (e.g. Powdery Mildew)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = manufacturer,
                onValueChange = { manufacturer = it },
                label = { Text("Manufacturer") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            UrlField(
                label = "Official label URL",
                value = labelUrl,
                onValueChange = { labelUrl = it },
                onOpen = { resolveUrl(labelUrl)?.let { runCatching { uriHandler.openUri(it) } } },
            )
            UrlField(
                label = "Product page URL",
                value = productUrl,
                onValueChange = { productUrl = it },
                onOpen = { resolveUrl(productUrl)?.let { runCatching { uriHandler.openUri(it) } } },
            )
            Text(
                "Use the label URL only for the official product label. Product pages are for manufacturer info and are never shown as the label.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            SectionLabel("Rates")
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = ratePerHa,
                    onValueChange = { ratePerHa = it.numericFilter() },
                    label = { Text("Rate/ha") },
                    suffix = { Text("$unit/ha", fontSize = 12.sp, color = vine.textSecondary) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = ratePer100L,
                    onValueChange = { ratePer100L = it.numericFilter() },
                    label = { Text("Rate/100L") },
                    suffix = { Text("$unit/100L", fontSize = 12.sp, color = vine.textSecondary) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }
            Text(
                "Enter either or both. The spray calculator lets the operator pick which basis to use per job.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            if (canViewFinancials) {
                SectionLabel("Purchase tracking")
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Text("Track purchase info", fontSize = 15.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                    Switch(checked = trackPurchase, onCheckedChange = { trackPurchase = it })
                }
                if (trackPurchase) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedTextField(
                            value = containerSize,
                            onValueChange = { containerSize = it.numericFilter() },
                            label = { Text("Container size") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.weight(1f),
                        )
                        UnitDropdown(
                            label = "Unit",
                            value = containerUnit,
                            options = unitsForForm(formType),
                            expanded = containerUnitMenu,
                            onExpandedChange = { containerUnitMenu = it },
                            onSelect = { containerUnit = it; containerUnitMenu = false },
                            modifier = Modifier.weight(1f),
                        )
                    }
                    OutlinedTextField(
                        value = cost,
                        onValueChange = { cost = it.numericFilter() },
                        label = { Text("Cost") },
                        placeholder = { Text("0.00") },
                        prefix = { Text("$") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        "Used to calculate chemical cost in spray reports. Visible to owners and managers only.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            SectionLabel("Notes")
            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                minLines = 3,
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
                else Text(if (isEdit) "Save changes" else "Add chemical")
            }
        }
    }

    if (showAI) {
        ChemicalAILookupSheet(
            vm = vm,
            initialQuery = name,
            onDismiss = { showAI = false },
            onSelect = { result ->
                showAI = false
                applyAIResult(result)
            },
        )
    }
}

/** Small grey section header used inside the chemical form. */
@Composable
private fun SectionLabel(text: String) {
    val vine = LocalVineColors.current
    Text(text.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun UnitDropdown(
    label: String,
    value: String,
    options: List<String>,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = onExpandedChange, modifier = modifier) {
        OutlinedTextField(
            value = value,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { onExpandedChange(false) }) {
            options.forEach { o ->
                DropdownMenuItem(text = { Text(o) }, onClick = { onSelect(o) })
            }
        }
    }
}

/** URL text field with a trailing open-in-browser button when the URL is valid. */
@Composable
private fun UrlField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    onOpen: () -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        trailingIcon = {
            if (resolveUrl(value) != null) {
                IconButton(onClick = onOpen) {
                    Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = "Open $label", tint = ChemTint, modifier = Modifier.size(20.dp))
                }
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

/** Normalise a typed URL to an openable https link, or null when invalid. */
private fun resolveUrl(raw: String): String? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return null
    val withScheme = if (trimmed.startsWith("http://", true) || trimmed.startsWith("https://", true)) {
        trimmed
    } else {
        "https://$trimmed"
    }
    val host = withScheme.substringAfter("://").substringBefore("/")
    return if (host.contains(".")) withScheme else null
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChemicalAILookupSheet(
    vm: AppViewModel,
    initialQuery: String,
    onDismiss: () -> Unit,
    onSelect: (ChemicalInfoService.ChemicalSearchResult) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf(initialQuery) }
    var results by remember { mutableStateOf<List<ChemicalInfoService.ChemicalSearchResult>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun runSearch() {
        val trimmed = query.trim()
        if (trimmed.isEmpty() || loading) return
        error = null
        loading = true
        vm.searchChemicals(trimmed) { res ->
            loading = false
            res.onSuccess {
                results = it
                if (it.isEmpty()) error = "No products found."
            }
            res.onFailure { error = it.message; results = emptyList() }
        }
    }

    LaunchedEffect(Unit) {
        if (initialQuery.trim().isNotEmpty() && results.isEmpty()) runSearch()
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Search with AI", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text("Product or active ingredient") },
                singleLine = true,
                trailingIcon = {
                    IconButton(onClick = { runSearch() }, enabled = !loading && query.trim().isNotEmpty()) {
                        Icon(Icons.Filled.Search, contentDescription = "Search")
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "AI suggestions must be checked against the current label, permit, SDS, and local regulations before use.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
            if (loading) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text("Searching...", color = vine.textSecondary)
                }
            }
            error?.let { Text(it, fontSize = 13.sp, color = VineColors.Destructive) }
            results.forEachIndexed { index, item ->
                if (index > 0) HorizontalDivider()
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(item) }
                        .padding(vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    if (item.brand.isNotBlank()) {
                        Text(item.brand, fontWeight = FontWeight.Bold, fontSize = 15.sp, color = vine.textPrimary)
                    }
                    Text(
                        item.name,
                        fontSize = 14.sp,
                        color = if (item.brand.isBlank()) vine.textPrimary else vine.textSecondary,
                    )
                    if (item.activeIngredient.isNotBlank()) {
                        Text("Active: ${item.activeIngredient}", fontSize = 12.sp, color = vine.textSecondary)
                    }
                    val chips = buildList {
                        item.chemicalGroup.takeIf { it.isNotBlank() }?.let { add(it) }
                        item.modeOfAction.takeIf { it.isNotBlank() }?.let { add("MOA $it") }
                    }
                    if (chips.isNotEmpty()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) { chips.forEach { ChemChip(it) } }
                    }
                    if (item.primaryUse.isNotBlank()) {
                        Text(item.primaryUse, fontSize = 12.sp, color = vine.textSecondary)
                    }
                }
            }
        }
    }
}

/** Compact currency label (e.g. "$50", "$42.50") for chemical costs. */
private fun formatChemCurrency(value: Double): String {
    val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong()) else "%,.2f".format(value)
    return "$$rounded"
}

private fun trimNum(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)

private fun String.numericFilter(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

private fun String.toDoubleSafe(): Double? = replace(',', '.').trim().takeIf { it.isNotBlank() }?.toDoubleOrNull()
