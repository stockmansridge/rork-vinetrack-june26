package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Settings
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
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.AppPreferencesStore
import com.rork.vinetrack.data.EquipmentItemRepository
import com.rork.vinetrack.data.FuelPurchaseRepository
import com.rork.vinetrack.data.TractorFuelLookupService
import com.rork.vinetrack.data.VineyardMachineRepository
import com.rork.vinetrack.data.model.EquipmentItem
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.machineTypeLabel
import com.rork.vinetrack.data.model.vineyardMachineTypeOptions
import com.rork.vinetrack.data.model.weightedFuelCostPerLitre
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.StatusBadge
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.launch

/**
 * Equipment area — mirrors the iOS `EquipmentManagementView` hub. Owners and
 * managers manage Tractors, Spray Equipment, Vineyard Machines, Other Equipment
 * and Fuel from one place, all backed by the same Supabase tables as iOS
 * (`vineyard_machines`, `spray_equipment`, `equipment_items`, `fuel_purchases`,
 * `tractor_fuel_logs`).
 */
private enum class EquipmentDestination { HUB, TRACTORS, SPRAY, MACHINES, OTHER, FUEL }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EquipmentScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenFuelLog: () -> Unit = {},
) {
    var destination by rememberSaveable { mutableStateOf(EquipmentDestination.HUB) }

    AnimatedContent(
        targetState = destination,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "equipment-nav",
        modifier = modifier,
    ) { dest ->
        when (dest) {
            EquipmentDestination.HUB -> EquipmentHub(
                state = state,
                onBack = onBack,
                onOpen = { destination = it },
            )
            EquipmentDestination.TRACTORS -> VineyardMachineList(
                vm = vm, state = state, tractorsOnly = true,
                onBack = { destination = EquipmentDestination.HUB },
            )
            EquipmentDestination.SPRAY -> SprayEquipmentScreen(
                vm = vm, state = state, onBack = { destination = EquipmentDestination.HUB },
            )
            EquipmentDestination.MACHINES -> VineyardMachineList(
                vm = vm, state = state, tractorsOnly = false,
                onBack = { destination = EquipmentDestination.HUB },
            )
            EquipmentDestination.OTHER -> OtherEquipmentList(
                vm = vm, state = state,
                onBack = { destination = EquipmentDestination.HUB },
            )
            EquipmentDestination.FUEL -> FuelManagementScreen(
                vm = vm, state = state,
                onBack = { destination = EquipmentDestination.HUB },
                onOpenFuelLog = onOpenFuelLog,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EquipmentHub(
    state: AppUiState,
    onBack: (() -> Unit)?,
    onOpen: (EquipmentDestination) -> Unit,
) {
    val vine = LocalVineColors.current
    val tractorCount = state.machines.count { it.machineType == "tractor" }
    val machineCount = state.machines.count { it.machineType != "tractor" }
    val sprayCount = state.sprayEquipment.size
    val otherCount = state.equipmentItems.size
    val purchaseCount = state.fuelPurchases.size
    val fillCount = state.fuelLogs.size

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Equipment") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Spacer(Modifier.height(0.dp))
            EquipmentNavCard(
                icon = Icons.Filled.Agriculture, tint = VineColors.EarthBrown,
                title = "Manage Tractors",
                subtitle = if (tractorCount == 0) "Add tractors for fuel use and trip costing"
                else "$tractorCount tractor${if (tractorCount == 1) "" else "s"}",
                footer = "Tractors used for vineyard work. Used for Fuel Log and trip costing.",
                onClick = { onOpen(EquipmentDestination.TRACTORS) },
            )
            EquipmentNavCard(
                icon = Icons.Filled.Science, tint = VineColors.Info,
                title = "Manage Spray Equipment",
                subtitle = if (sprayCount == 0) "Add spray rigs and tanks"
                else "$sprayCount item${if (sprayCount == 1) "" else "s"}",
                footer = "Spray rigs and tanks used for spray applications. Not used for Fuel Log or machine fuel costing.",
                onClick = { onOpen(EquipmentDestination.SPRAY) },
            )
            EquipmentNavCard(
                icon = Icons.Filled.Settings, tint = VineColors.Indigo,
                title = "Manage Vineyard Machines",
                subtitle = if (machineCount == 0) "Add ATVs, side-by-sides, harvesters…"
                else "$machineCount machine${if (machineCount == 1) "" else "s"}",
                footer = "ATVs, side-by-sides, harvesters, utility vehicles and other powered machines used directly for vineyard work.",
                onClick = { onOpen(EquipmentDestination.MACHINES) },
            )
            EquipmentNavCard(
                icon = Icons.Filled.Inventory2, tint = VineColors.Stone,
                title = "Manage Other Items",
                subtitle = if (otherCount == 0) "Add trailers, implements, tools, irrigation parts…"
                else "$otherCount item${if (otherCount == 1) "" else "s"}",
                footer = "Trailers, implements, tools, irrigation parts, workshop gear and other non-fuel-tracked assets.",
                onClick = { onOpen(EquipmentDestination.OTHER) },
            )
            EquipmentNavCard(
                icon = Icons.Filled.LocalGasStation, tint = VineColors.Pink,
                title = "Fuel",
                subtitle = if (purchaseCount == 0 && fillCount == 0) "Record purchases and fuel fills"
                else "$purchaseCount purchase${if (purchaseCount == 1) "" else "s"} · $fillCount fill${if (fillCount == 1) "" else "s"}",
                footer = "Record fuel purchases for weighted cost per litre, and fuel fills to calculate machine usage over time.",
                onClick = { onOpen(EquipmentDestination.FUEL) },
            )
        }
    }
}

@Composable
private fun EquipmentNavCard(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    footer: String? = null,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        VineyardCard(modifier = Modifier.clickable { onClick() }) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(
                    modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(tint.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center,
                ) { Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp)) }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(title, color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    Text(subtitle, color = vine.textSecondary, fontSize = 12.sp)
                }
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
            }
        }
        if (footer != null) {
            Text(
                footer,
                color = vine.textSecondary,
                fontSize = 11.sp,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}

// MARK: - Vineyard Machines / Tractors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VineyardMachineList(
    vm: AppViewModel,
    state: AppUiState,
    tractorsOnly: Boolean,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"
    val machines = remember(state.machines, tractorsOnly) {
        state.machines.filter { (it.machineType == "tractor") == tractorsOnly }
            .sortedBy { it.displayName.lowercase() }
    }
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<VineyardMachine?>(null) }
    var pendingDelete by remember { mutableStateOf<VineyardMachine?>(null) }
    val title = if (tractorsOnly) "Tractors" else "Vineyard Machines"

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = VineColors.Indigo,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add machine") }
            }
        },
    ) { padding ->
        if (machines.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding).padding(24.dp), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = if (tractorsOnly) Icons.Filled.Agriculture else Icons.Filled.Settings,
                    title = if (tractorsOnly) "No tractors yet" else "No vineyard machines yet",
                    message = if (canManage) {
                        if (tractorsOnly) "Add your tractors to track fuel use and trip costing."
                        else "Add ATVs, side-by-sides, harvesters and other machines to track their fuel use."
                    } else "These are managed by vineyard owners and managers.",
                    actionLabel = if (canManage) "Add" else null,
                    onAction = if (canManage) ({ creating = true }) else null,
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                state.equipmentError?.let { item { Text(it, color = VineColors.Destructive, fontSize = 13.sp) } }
                items(machines.size, key = { machines[it].id }) { idx ->
                    val m = machines[idx]
                    MachineRow(
                        machine = m,
                        fmt = state.regionFormatter,
                        canEdit = canManage && !m.isLegacyTractor,
                        onClick = { if (canManage && !m.isLegacyTractor) editing = m },
                    )
                }
            }
        }
    }

    if (creating) {
        MachineFormSheet(
            vm = vm, existing = null, forceTractor = tractorsOnly,
            onDismiss = { creating = false },
        )
    }
    editing?.let { m ->
        MachineFormSheet(
            vm = vm, existing = m, forceTractor = tractorsOnly,
            onDismiss = { editing = null },
            onDelete = { pendingDelete = m; editing = null },
        )
    }
    pendingDelete?.let { m ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Archive ${m.displayName}?") },
            text = { Text("This removes the machine for everyone. Existing fuel and trip records keep their snapshot.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteVineyardMachine(m.id) {}
                    pendingDelete = null
                }) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun MachineRow(machine: VineyardMachine, fmt: RegionFormatter, canEdit: Boolean, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = if (canEdit) Modifier.clickable { onClick() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.Indigo.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Settings, contentDescription = null, tint = VineColors.Indigo, modifier = Modifier.size(22.dp)) }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(machine.displayName, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(machineTypeLabel(machine.machineType), color = vine.textSecondary, fontSize = 12.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    StatusBadge(
                        if (machine.fuelTrackingEnabled) "Fuel tracking" else "Fuel off",
                        if (machine.fuelTrackingEnabled) VineColors.LeafGreen else VineColors.Stone,
                    )
                    if (machine.availableForJobCosting) StatusBadge("Job costing", VineColors.Info)
                    if (machine.hasFuelUsageRate) {
                        Text(fmt.formatFuelRatePerHour(machine.fuelUsageLPerHour ?: 0.0), color = vine.textSecondary, fontSize = 11.sp)
                    }
                }
                val ids = listOfNotNull(
                    machine.serialNumber?.trim()?.takeIf { it.isNotEmpty() }?.let { "S/N $it" },
                    machine.vinNumber?.trim()?.takeIf { it.isNotEmpty() }?.let { "VIN $it" },
                ).joinToString(" · ")
                if (ids.isNotEmpty()) Text(ids, color = vine.textSecondary, fontSize = 11.sp)
                if (machine.isLegacyTractor && machine.machineType != "tractor") {
                    Text("Managed in Tractors", color = vine.textSecondary, fontSize = 11.sp)
                }
            }
            if (canEdit) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MachineFormSheet(
    vm: AppViewModel,
    existing: VineyardMachine?,
    forceTractor: Boolean,
    onDismiss: () -> Unit,
    onDelete: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val aiSuggestionsEnabled = remember { AppPreferencesStore(context).load().aiSuggestionsEnabled }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var type by remember { mutableStateOf(existing?.machineType ?: if (forceTractor) "tractor" else "atv") }
    var typeMenu by remember { mutableStateOf(false) }
    var fuelTracking by remember { mutableStateOf(existing?.fuelTrackingEnabled ?: true) }
    var jobCosting by remember { mutableStateOf(existing?.availableForJobCosting ?: false) }
    var fuelRate by remember { mutableStateOf(existing?.fuelUsageLPerHour?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var serial by remember { mutableStateOf(existing?.serialNumber ?: "") }
    var vin by remember { mutableStateOf(existing?.vinNumber ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var saving by remember { mutableStateOf(false) }

    val canSave = name.trim().isNotEmpty() && !saving

    fun save() {
        saving = true
        val input = VineyardMachineRepository.MachineInput(
            name = name.trim(),
            machineType = type,
            fuelTrackingEnabled = fuelTracking,
            availableForJobCosting = jobCosting,
            fuelUsageLPerHour = fuelRate.replace(',', '.').toDoubleOrNull() ?: 0.0,
            notes = notes.trim().takeIf { it.isNotEmpty() },
            serialNumber = serial.trim().takeIf { it.isNotEmpty() },
            vinNumber = vin.trim().takeIf { it.isNotEmpty() },
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (existing == null) vm.createVineyardMachine(input, cb) else vm.updateVineyardMachine(existing.id, input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                if (existing == null) "New ${if (forceTractor) "Tractor" else "Machine"}" else "Edit ${existing.displayName}",
                color = vine.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold,
            )
            OutlinedTextField(
                value = name, onValueChange = { name = it },
                label = { Text("Name") }, placeholder = { Text("e.g. John Deere 5075E") },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
            )
            // Machine type picker.
            ExposedDropdownMenuBox(expanded = typeMenu, onExpandedChange = { typeMenu = it }) {
                OutlinedTextField(
                    value = machineTypeLabel(type), onValueChange = {}, readOnly = true,
                    label = { Text("Machine type") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = typeMenu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                androidx.compose.material3.DropdownMenu(expanded = typeMenu, onDismissRequest = { typeMenu = false }) {
                    vineyardMachineTypeOptions.forEach { opt ->
                        DropdownMenuItem(text = { Text(machineTypeLabel(opt)) }, onClick = { type = opt; typeMenu = false })
                    }
                }
            }
            ToggleLine("Fuel tracking enabled", fuelTracking) { fuelTracking = it }
            ToggleLine("Available for job costing", jobCosting) { jobCosting = it }
            OutlinedTextField(
                value = fuelRate, onValueChange = { fuelRate = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                label = { Text("Default fuel usage (L/hr)") }, placeholder = { Text("Optional — e.g. 6.5") },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                supportingText = {
                    Text(
                        if (existing == null) "Used to estimate trip and machinery costs. This can be updated from fuel logs and trip history over time."
                        else "You can manually edit this, estimate it with AI, or let fuel logs and trip history refine it over time.",
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            )
            if (type == "tractor" && aiSuggestionsEnabled) {
                TractorAiFuelLookup(
                    machineName = name,
                    onApply = { lph -> fuelRate = trimNum(lph) },
                )
            }
            OutlinedTextField(
                value = serial, onValueChange = { serial = it },
                label = { Text("Serial number (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = vin, onValueChange = { vin = it },
                label = { Text("VIN number (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = notes, onValueChange = { notes = it },
                label = { Text("Notes") }, modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = { save() }, enabled = canSave, modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Indigo),
            ) { Text(if (existing == null) "Add" else "Save") }
            if (existing != null && onDelete != null) {
                TextButton(onClick = onDelete, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Archive machine", color = VineColors.Destructive)
                }
            }
        }
    }
}

// MARK: - AI fuel lookup (tractors)

/**
 * AI fuel-use estimate for the tractor form — mirrors the iOS `TractorFormSheet`
 * lookup flow. The user confirms the make/model (prefilled from the machine
 * name), runs the lookup, and must explicitly apply a match; nothing is saved
 * until they tap Save on the form itself.
 */
@Composable
private fun TractorAiFuelLookup(
    machineName: String,
    onApply: (Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    // Prefill make/model from the machine name (e.g. "John Deere 5075E").
    var make by remember(machineName) {
        mutableStateOf(guessTractorMake(machineName))
    }
    var model by remember(machineName) {
        mutableStateOf(guessTractorModel(machineName))
    }
    var yearText by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var outcome by remember { mutableStateOf<TractorFuelLookupService.LookupOutcome?>(null) }

    val canSearch = !loading && make.trim().isNotEmpty() && model.trim().isNotEmpty()

    fun runLookup() {
        if (!canSearch) return
        loading = true
        outcome = null
        scope.launch {
            val year = yearText.trim().toIntOrNull()?.takeIf { it in 1900..2100 }
            outcome = TractorFuelLookupService().lookupFuelUsage(make, model, year)
            loading = false
        }
    }

    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = VineColors.Indigo, modifier = Modifier.size(16.dp))
            Text("AI fuel lookup", color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = make, onValueChange = { make = it },
                label = { Text("Make") }, placeholder = { Text("John Deere") },
                singleLine = true, modifier = Modifier.weight(1f),
            )
            OutlinedTextField(
                value = model, onValueChange = { model = it },
                label = { Text("Model") }, placeholder = { Text("5075E") },
                singleLine = true, modifier = Modifier.weight(1f),
            )
        }
        OutlinedTextField(
            value = yearText, onValueChange = { yearText = it.filter { c -> c.isDigit() }.take(4) },
            label = { Text("Year (optional)") }, placeholder = { Text("2018") },
            singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
        Button(
            onClick = { runLookup() }, enabled = canSearch, modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Indigo),
        ) {
            if (loading) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = Color.White)
                Spacer(Modifier.size(8.dp))
                Text("Searching…")
            } else {
                Icon(Icons.Filled.AutoAwesome, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.size(6.dp))
                Text(if (outcome != null) "Search Again" else "Estimate Fuel Use")
            }
        }
        Text(
            "AI estimates are approximate — actual fuel use varies by load, terrain, implement, speed, and conditions.",
            color = vine.textSecondary, fontSize = 11.sp,
        )
        when (val o = outcome) {
            is TractorFuelLookupService.LookupOutcome.Match -> AiLookupResultCard(
                title = "Tractor match found",
                titleColor = VineColors.LeafGreen,
                result = o.result,
                enteredLabel = "$make $model".trim(),
                onApply = { onApply(o.result.fuelUsageLPerHour); outcome = null },
                onDismiss = { outcome = null },
            )
            is TractorFuelLookupService.LookupOutcome.Uncertain -> AiLookupResultCard(
                title = "Uncertain match — please verify",
                titleColor = VineColors.Warning,
                result = o.result,
                enteredLabel = "$make $model".trim(),
                onApply = { onApply(o.result.fuelUsageLPerHour); outcome = null },
                onDismiss = { outcome = null },
            )
            is TractorFuelLookupService.LookupOutcome.NoMatch -> VineyardCard {
                Text(o.message + " You can enter the fuel rate manually.", color = vine.textSecondary, fontSize = 13.sp)
            }
            is TractorFuelLookupService.LookupOutcome.Unavailable -> VineyardCard {
                Text(o.message, color = VineColors.Warning, fontSize = 13.sp)
            }
            null -> Unit
        }
    }
}

/** Confirmation panel for an AI match — the estimate is only applied on tap. */
@Composable
private fun AiLookupResultCard(
    title: String,
    titleColor: Color,
    result: TractorFuelLookupService.FuelLookupResult,
    enteredLabel: String,
    onApply: () -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = titleColor, modifier = Modifier.size(16.dp))
                Text(title, color = titleColor, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
            Text(result.matchedLabel(fallback = enteredLabel), color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text("Estimated fuel use: ${trimNum(result.fuelUsageLPerHour)} L/hr", color = vine.textPrimary, fontSize = 13.sp)
            result.confidence?.takeIf { it.isNotBlank() }?.let {
                Text("Confidence: ${it.replaceFirstChar { c -> c.uppercase() }}", color = vine.textSecondary, fontSize = 11.sp)
            }
            result.notes?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = vine.textSecondary, fontSize = 11.sp)
            }
            Text("Please confirm this looks correct before saving.", color = vine.textSecondary, fontSize = 11.sp)
            Spacer(Modifier.size(2.dp))
            Button(
                onClick = onApply, modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
            ) { Text("Use this match") }
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
                Text("Edit manually", color = vine.textSecondary)
            }
        }
    }
}

/** Multi-word tractor brands recognised when splitting a machine name. */
private val multiWordTractorMakes = listOf(
    "john deere", "new holland", "massey ferguson", "case ih",
)

private fun guessTractorMake(name: String): String {
    val trimmed = name.trim()
    if (trimmed.isEmpty()) return ""
    val lower = trimmed.lowercase()
    multiWordTractorMakes.firstOrNull { lower.startsWith(it) }?.let {
        return trimmed.take(it.length)
    }
    return trimmed.split(" ").first()
}

private fun guessTractorModel(name: String): String {
    val trimmed = name.trim()
    if (trimmed.isEmpty()) return ""
    val make = guessTractorMake(trimmed)
    return trimmed.removePrefix(make).trim()
}

// MARK: - Other Equipment

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OtherEquipmentList(
    vm: AppViewModel,
    state: AppUiState,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val canManage = state.currentRole == "owner" || state.currentRole == "manager" || state.currentRole == "supervisor"
    val items = remember(state.equipmentItems) { state.equipmentItems.sortedBy { it.displayName.lowercase() } }
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<EquipmentItem?>(null) }
    var pendingDelete by remember { mutableStateOf<EquipmentItem?>(null) }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Other Equipment") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = VineColors.Stone,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add item") }
            }
        },
    ) { padding ->
        if (items.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding).padding(24.dp), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = Icons.Filled.Inventory2,
                    title = "No items yet",
                    message = "Add trailers, implements, tools, irrigation parts, workshop gear or other non-fuel-tracked vineyard assets you maintain.",
                    actionLabel = if (canManage) "Add" else null,
                    onAction = if (canManage) ({ creating = true }) else null,
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                state.equipmentError?.let { item { Text(it, color = VineColors.Destructive, fontSize = 13.sp) } }
                items(items.size, key = { items[it].id }) { idx ->
                    val it0 = items[idx]
                    OtherEquipmentRow(item = it0, canEdit = canManage, onClick = { if (canManage) editing = it0 })
                }
            }
        }
    }

    if (creating) {
        OtherEquipmentFormSheet(vm = vm, existing = null, onDismiss = { creating = false })
    }
    editing?.let { item ->
        OtherEquipmentFormSheet(
            vm = vm, existing = item, onDismiss = { editing = null },
            onDelete = { pendingDelete = item; editing = null },
        )
    }
    pendingDelete?.let { item ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete ${item.displayName}?") },
            text = { Text("This removes the item for everyone. This can't be undone.") },
            confirmButton = {
                TextButton(onClick = { vm.deleteEquipmentItem(item.id) {}; pendingDelete = null }) {
                    Text("Delete", color = VineColors.Destructive)
                }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun OtherEquipmentRow(item: EquipmentItem, canEdit: Boolean, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val subtitle = listOfNotNull(
        item.make?.trim()?.takeIf { it.isNotEmpty() },
        item.model?.trim()?.takeIf { it.isNotEmpty() },
        item.serialNumber?.trim()?.takeIf { it.isNotEmpty() }?.let { "S/N $it" },
    ).joinToString(" · ")
    VineyardCard(modifier = if (canEdit) Modifier.clickable { onClick() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.Stone.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Inventory2, contentDescription = null, tint = VineColors.Stone, modifier = Modifier.size(22.dp)) }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(item.displayName, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                if (subtitle.isNotEmpty()) Text(subtitle, color = vine.textSecondary, fontSize = 12.sp)
            }
            if (canEdit) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OtherEquipmentFormSheet(
    vm: AppViewModel,
    existing: EquipmentItem?,
    onDismiss: () -> Unit,
    onDelete: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var make by remember { mutableStateOf(existing?.make ?: "") }
    var model by remember { mutableStateOf(existing?.model ?: "") }
    var serial by remember { mutableStateOf(existing?.serialNumber ?: "") }
    var vin by remember { mutableStateOf(existing?.vinNumber ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var saving by remember { mutableStateOf(false) }
    val canSave = name.trim().isNotEmpty() && !saving

    fun save() {
        saving = true
        val input = EquipmentItemRepository.ItemInput(
            name = name.trim(),
            make = make.trim().takeIf { it.isNotEmpty() },
            model = model.trim().takeIf { it.isNotEmpty() },
            serialNumber = serial.trim().takeIf { it.isNotEmpty() },
            vinNumber = vin.trim().takeIf { it.isNotEmpty() },
            notes = notes.trim(),
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (existing == null) vm.createEquipmentItem(input, cb) else vm.updateEquipmentItem(existing.id, input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (existing == null) "Add Item" else "Edit ${existing.displayName}",
                color = vine.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold,
            )
            OutlinedTextField(
                value = name, onValueChange = { name = it },
                label = { Text("Name") }, placeholder = { Text("e.g. Quad Bike") },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(value = make, onValueChange = { make = it }, label = { Text("Make (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(value = model, onValueChange = { model = it }, label = { Text("Model (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(value = serial, onValueChange = { serial = it }, label = { Text("Serial number (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(value = vin, onValueChange = { vin = it }, label = { Text("VIN number (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("Notes (optional)") }, modifier = Modifier.fillMaxWidth())
            Button(
                onClick = { save() }, enabled = canSave, modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Stone),
            ) { Text(if (existing == null) "Add" else "Save") }
            if (existing != null && onDelete != null) {
                TextButton(onClick = onDelete, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Delete item", color = VineColors.Destructive)
                }
            }
        }
    }
}

// MARK: - Fuel (purchases + link to Fuel Log)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FuelManagementScreen(
    vm: AppViewModel,
    state: AppUiState,
    onBack: () -> Unit,
    onOpenFuelLog: () -> Unit,
) {
    val vine = LocalVineColors.current
    val fmt = state.regionFormatter
    val canManage = state.currentRole == "owner" || state.currentRole == "manager"
    val canViewFinancials = canManage
    val purchases = remember(state.fuelPurchases) { state.fuelPurchases.sortedByDescending { it.date ?: "" } }
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<FuelPurchase?>(null) }
    var pendingDelete by remember { mutableStateOf<FuelPurchase?>(null) }

    val totalVolume = purchases.sumOf { it.volumeLitres }
    val avgCost = weightedFuelCostPerLitre(purchases)

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Fuel") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (canManage) {
                FloatingActionButton(
                    onClick = { creating = true },
                    containerColor = VineColors.Pink,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Add fuel purchase") }
            }
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            state.equipmentError?.let { item { Text(it, color = VineColors.Destructive, fontSize = 13.sp) } }

            item { SectionHeader("Fuel Purchases", onLight = true) }
            if (purchases.isEmpty()) {
                item {
                    VineyardCard {
                        Text(
                            if (canManage) "Record fuel purchases to calculate an average cost per litre."
                            else "No fuel purchases have been recorded yet.",
                            color = vine.textSecondary, fontSize = 13.sp,
                        )
                    }
                }
            } else {
                items(purchases.size, key = { purchases[it].id }) { idx ->
                    FuelPurchaseRow(
                        purchase = purchases[idx],
                        fmt = fmt,
                        canViewFinancials = canViewFinancials,
                        canEdit = canManage,
                        onClick = { if (canManage) editing = purchases[idx] },
                    )
                }
                item {
                    VineyardCard {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text("Season Average", color = vine.textSecondary, fontSize = 12.sp)
                                if (canViewFinancials && avgCost != null) {
                                    Text(fmt.formatFuelCostPerUnit(avgCost), color = VineColors.LeafGreen, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                                } else {
                                    Text("—", color = vine.textSecondary, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                                }
                            }
                            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text("Total Purchased", color = vine.textSecondary, fontSize = 12.sp)
                                Text(fmt.formatFuel(totalVolume, fractionDigits = 0), color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                            }
                        }
                    }
                }
            }

            item { SectionHeader("Fuel Log", onLight = true) }
            item {
                VineyardCard(modifier = Modifier.clickable { onOpenFuelLog() }) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(
                            modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.Pink.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center,
                        ) { Icon(Icons.Filled.LocalGasStation, contentDescription = null, tint = VineColors.Pink, modifier = Modifier.size(22.dp)) }
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text("Open Fuel Log", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                            Text("${state.fuelLogs.size} fill${if (state.fuelLogs.size == 1) "" else "s"} · litres & engine hours per machine", color = vine.textSecondary, fontSize = 12.sp)
                        }
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
                    }
                }
            }
        }
    }

    if (creating) FuelPurchaseFormSheet(vm = vm, existing = null, fmt = fmt, onDismiss = { creating = false })
    editing?.let { p ->
        FuelPurchaseFormSheet(vm = vm, existing = p, fmt = fmt, onDismiss = { editing = null }, onDelete = { pendingDelete = p; editing = null })
    }
    pendingDelete?.let { p ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete fuel purchase?") },
            text = { Text("This removes the purchase for everyone and updates the average cost per litre.") },
            confirmButton = {
                TextButton(onClick = { vm.deleteFuelPurchase(p.id) {}; pendingDelete = null }) {
                    Text("Delete", color = VineColors.Destructive)
                }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun FuelPurchaseRow(
    purchase: FuelPurchase,
    fmt: RegionFormatter,
    canViewFinancials: Boolean,
    canEdit: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    val costPerLitre = if (purchase.volumeLitres > 0) purchase.totalCost / purchase.volumeLitres else 0.0
    VineyardCard(modifier = if (canEdit) Modifier.clickable { onClick() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.Pink.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.LocalGasStation, contentDescription = null, tint = VineColors.Pink, modifier = Modifier.size(22.dp)) }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                if (canViewFinancials) {
                    Text("${fmt.formatFuel(purchase.volumeLitres)} — ${fmt.formatCurrency(purchase.totalCost)}", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                } else {
                    Text(fmt.formatFuel(purchase.volumeLitres), color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(formatPurchaseDate(purchase.date), color = vine.textSecondary, fontSize = 12.sp)
                    if (canViewFinancials) Text(fmt.formatFuelCostPerUnit(costPerLitre), color = VineColors.LeafGreen, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                }
            }
            if (canEdit) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FuelPurchaseFormSheet(
    vm: AppViewModel,
    existing: FuelPurchase?,
    fmt: RegionFormatter,
    onDismiss: () -> Unit,
    onDelete: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var volume by remember { mutableStateOf(existing?.volumeLitres?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var cost by remember { mutableStateOf(existing?.totalCost?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var saving by remember { mutableStateOf(false) }
    val vol = volume.replace(',', '.').toDoubleOrNull() ?: 0.0
    val cst = cost.replace(',', '.').toDoubleOrNull() ?: 0.0
    val canSave = vol > 0 && cst > 0 && !saving

    fun save() {
        saving = true
        val input = FuelPurchaseRepository.PurchaseInput(
            volumeLitres = vol,
            totalCost = cst,
            dateIso = existing?.date ?: Instant.now().toString(),
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onDismiss() }
        if (existing == null) vm.createFuelPurchase(input, cb) else vm.updateFuelPurchase(existing.id, input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                if (existing == null) "New Fuel Purchase" else "Edit Fuel Purchase",
                color = vine.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold,
            )
            OutlinedTextField(
                value = volume, onValueChange = { volume = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                label = { Text("Volume (litres)") }, placeholder = { Text("e.g. 500") },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = cost, onValueChange = { cost = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                label = { Text("Total cost") }, placeholder = { Text("e.g. 950.00") },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            if (vol > 0 && cst > 0) {
                Text("${fmt.formatFuelCostPerUnit(cst / vol)}", color = vine.textSecondary, fontSize = 13.sp)
            }
            Button(
                onClick = { save() }, enabled = canSave, modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Pink),
            ) { Text(if (existing == null) "Add" else "Save") }
            if (existing != null && onDelete != null) {
                TextButton(onClick = onDelete, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Delete purchase", color = VineColors.Destructive)
                }
            }
        }
    }
}

@Composable
private fun ToggleLine(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onChange(!value) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(label, color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Switch(checked = value, onCheckedChange = onChange)
    }
}

private fun trimNum(v: Double): String =
    if (v == v.toLong().toDouble()) v.toLong().toString()
    else String.format(Locale.US, "%.1f", v).trimEnd('0').trimEnd('.')

private fun formatPurchaseDate(iso: String?): String {
    if (iso.isNullOrBlank()) return "—"
    return try {
        val parsed = Date.from(Instant.parse(iso))
        SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(parsed)
    } catch (e: Exception) {
        iso.take(10)
    }
}
