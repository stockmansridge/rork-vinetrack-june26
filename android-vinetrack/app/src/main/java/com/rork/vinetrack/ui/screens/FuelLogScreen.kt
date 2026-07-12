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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Calculate
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.FuelLogRepository
import com.rork.vinetrack.data.FuelPurchaseRepository
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.VineyardMachineRepository
import com.rork.vinetrack.data.model.FuelPurchase
import com.rork.vinetrack.data.model.TractorFuelLog
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.FuelRateResult
import com.rork.vinetrack.data.model.fuelLogGroupKey
import com.rork.vinetrack.data.model.fuelRate
import com.rork.vinetrack.data.model.resolveFuelLogMachineName
import com.rork.vinetrack.data.model.weightedFuelCostPerLitre
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Date
import java.util.Locale

/** Brand colour for the fuel surface (matches the Home Operational Tools card). */
private val FuelTint: Color = VineColors.Pink

/**
 * Fuel Log operational tool hub — mirrors the Work Tasks hub pattern (summary
 * card, tabs, record list, add workflow, auto-refresh on open) and is the one
 * home for both canonical fuel record types shared with iOS and the portal:
 * - Fuel Purchases → `fuel_purchases` (fuel bought from a supplier)
 * - Equipment Refuelling → `tractor_fuel_logs` (fills per vineyard machine)
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FuelLogScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val fmt = state.regionFormatter

    // Tabs: 0 = Purchases, 1 = Refuelling.
    var tab by rememberSaveable { mutableStateOf(0) }

    var creatingFill by remember { mutableStateOf(false) }
    var editingFill by remember { mutableStateOf<TractorFuelLog?>(null) }
    var creatingPurchase by remember { mutableStateOf(false) }
    var editingPurchase by remember { mutableStateOf<FuelPurchase?>(null) }
    var pendingDeletePurchase by remember { mutableStateOf<FuelPurchase?>(null) }

    // Mirror iOS access control: owners/managers manage purchases and any fill
    // and view financials; other members may only edit their own fills.
    val canManageSetup = state.currentRole == "owner" || state.currentRole == "manager"
    val canViewFinancials = canManageSetup
    val currentUserId = state.currentUserId

    // Auto-refresh on open so the summary and lists are current without a
    // manual reload — cached records stay visible while it runs.
    LaunchedEffect(Unit) { vm.refreshFuelData() }

    val purchases = remember(state.fuelPurchases) {
        state.fuelPurchases.filter { it.deletedAt == null }.sortedByDescending { it.date ?: "" }
    }

    // Season scope — same shared vineyard season boundary as Work Tasks.
    val seasonStartMs = remember(state.seasonStartMonth, state.seasonStartDay) {
        seasonStartDate(state.seasonStartMonth, state.seasonStartDay)
    }
    val seasonPurchases = remember(purchases, seasonStartMs) {
        purchases.filter { (purchaseEpochMs(it.date) ?: 0L) >= seasonStartMs }
    }
    val seasonLitresPurchased = seasonPurchases.sumOf { it.volumeLitres }
    val seasonPurchaseCost = seasonPurchases.sumOf { it.totalCost }
    val seasonAvgCost = weightedFuelCostPerLitre(seasonPurchases)
    val seasonLitresFilled = remember(state.fuelLogs, seasonStartMs) {
        state.fuelLogs.filter { (it.fillEpochMs ?: 0L) >= seasonStartMs }.sumOf { it.litresAdded }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Fuel Log") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            if (tab == 0) {
                if (canManageSetup) {
                    FloatingActionButton(
                        onClick = { creatingPurchase = true },
                        containerColor = FuelTint,
                        contentColor = Color.White,
                    ) { Icon(Icons.Filled.Add, contentDescription = "Add fuel purchase") }
                }
            } else {
                FloatingActionButton(
                    onClick = { creatingFill = true },
                    containerColor = FuelTint,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, contentDescription = "Record fuel fill") }
            }
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                FuelSummaryCard(
                    fmt = fmt,
                    purchaseCount = purchases.size,
                    fillCount = state.fuelLogs.size,
                    seasonStartMs = seasonStartMs,
                    seasonLitresPurchased = seasonLitresPurchased,
                    seasonPurchaseCost = seasonPurchaseCost,
                    seasonAvgCost = seasonAvgCost,
                    seasonLitresFilled = seasonLitresFilled,
                    canViewFinancials = canViewFinancials,
                )
                FuelTabSelector(selected = tab, onSelect = { tab = it })
            }
            Spacer(Modifier.height(12.dp))
            Box(Modifier.weight(1f)) {
                if (tab == 0) {
                    FuelPurchaseList(
                        state = state,
                        purchases = purchases,
                        fmt = fmt,
                        canViewFinancials = canViewFinancials,
                        canManage = canManageSetup,
                        onAdd = { creatingPurchase = true },
                        onEdit = { editingPurchase = it },
                    )
                } else {
                    FuelLogList(
                        state = state,
                        modifier = Modifier.fillMaxSize(),
                        canViewFinancials = canViewFinancials,
                        canEdit = { log -> canManageSetup || (log.operatorUserId != null && log.operatorUserId == currentUserId) },
                        onAdd = { creatingFill = true },
                        onEdit = { editingFill = it },
                    )
                }
            }
        }
    }

    if (creatingFill) {
        FuelSheet(vm, state, existing = null, canManageSetup = canManageSetup, onDismiss = { creatingFill = false }, onSaved = { creatingFill = false })
    }
    editingFill?.let { log ->
        FuelSheet(vm, state, existing = log, canManageSetup = canManageSetup, onDismiss = { editingFill = null }, onSaved = { editingFill = null })
    }
    if (creatingPurchase) {
        FuelPurchaseFormSheet(vm = vm, existing = null, fmt = fmt, onDismiss = { creatingPurchase = false })
    }
    editingPurchase?.let { p ->
        FuelPurchaseFormSheet(
            vm = vm,
            existing = p,
            fmt = fmt,
            onDismiss = { editingPurchase = null },
            onDelete = { pendingDeletePurchase = p; editingPurchase = null },
        )
    }
    pendingDeletePurchase?.let { p ->
        AlertDialog(
            onDismissRequest = { pendingDeletePurchase = null },
            title = { Text("Delete fuel purchase?") },
            text = { Text("This removes the purchase for everyone and updates the average cost per litre.") },
            confirmButton = {
                TextButton(onClick = { vm.deleteFuelPurchase(p.id) {}; pendingDeletePurchase = null }) {
                    Text("Delete", color = VineColors.Destructive)
                }
            },
            dismissButton = { TextButton(onClick = { pendingDeletePurchase = null }) { Text("Cancel") } },
        )
    }
}

// MARK: - Hub summary + tabs

@Composable
private fun FuelSummaryCard(
    fmt: RegionFormatter,
    purchaseCount: Int,
    fillCount: Int,
    seasonStartMs: Long,
    seasonLitresPurchased: Double,
    seasonPurchaseCost: Double,
    seasonAvgCost: Double?,
    seasonLitresFilled: Double,
    canViewFinancials: Boolean,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Fuel Summary", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                    Text(
                        "$purchaseCount purchase${if (purchaseCount == 1) "" else "s"} · $fillCount fill${if (fillCount == 1) "" else "s"}",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }
                if (canViewFinancials) {
                    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Purchased · This Season", fontSize = 11.sp, color = vine.textSecondary)
                        Text(
                            fmt.formatCurrency(seasonPurchaseCost),
                            fontSize = 20.sp,
                            fontWeight = FontWeight.Bold,
                            color = VineColors.LeafGreen,
                        )
                        Text(
                            "From " + SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(seasonStartMs)),
                            fontSize = 10.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FuelMetricCell(Modifier.weight(1f), "Purchased", fmt.formatFuel(seasonLitresPurchased, fractionDigits = 0), FuelTint)
                if (canViewFinancials) {
                    FuelMetricCell(
                        Modifier.weight(1f),
                        "Avg Cost / L",
                        seasonAvgCost?.let { fmt.formatFuelCostPerUnit(it) } ?: "Not specified",
                        VineColors.LeafGreen,
                    )
                }
                FuelMetricCell(Modifier.weight(1f), "Filled", fmt.formatFuel(seasonLitresFilled, fractionDigits = 0), VineColors.Cyan)
            }
        }
    }
}

@Composable
private fun FuelMetricCell(modifier: Modifier, title: String, value: String, tint: Color) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier.clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.08f)).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(title, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = tint, maxLines = 1)
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, maxLines = 1)
    }
}

@Composable
private fun FuelTabSelector(selected: Int, onSelect: (Int) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        listOf("Purchases", "Refuelling").forEachIndexed { idx, label ->
            val active = idx == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(9.dp))
                    .background(if (active) FuelTint else Color.Transparent)
                    .clickable { onSelect(idx) }
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (active) Color.White else vine.textSecondary,
                )
            }
        }
    }
}

// MARK: - Fuel purchases (moved here from the Equipment area)

@Composable
private fun FuelPurchaseList(
    state: AppUiState,
    purchases: List<FuelPurchase>,
    fmt: RegionFormatter,
    canViewFinancials: Boolean,
    canManage: Boolean,
    onAdd: () -> Unit,
    onEdit: (FuelPurchase) -> Unit,
) {
    when {
        state.isLoadingVineyardData && purchases.isEmpty() -> {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = FuelTint)
            }
        }
        purchases.isEmpty() && !state.isOnline -> {
            Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = Icons.Filled.LocalGasStation,
                    title = "No saved fuel purchases",
                    message = "You're offline and there are no fuel purchases saved on this device. Reconnect to load your team's purchases.",
                )
            }
        }
        purchases.isEmpty() -> {
            Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = Icons.Filled.LocalGasStation,
                    title = "No fuel purchases yet",
                    message = if (canManage) "Record fuel purchases to calculate the weighted cost per litre used in trip and machine costing."
                    else "No fuel purchases have been recorded yet.",
                    actionLabel = if (canManage) "Add fuel purchase" else null,
                    onAction = if (canManage) onAdd else null,
                )
            }
        }
        else -> {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(purchases, key = { it.id }) { purchase ->
                    FuelPurchaseRow(
                        purchase = purchase,
                        fmt = fmt,
                        canViewFinancials = canViewFinancials,
                        canEdit = canManage,
                        onClick = { if (canManage) onEdit(purchase) },
                    )
                }
                item {
                    Text(
                        "Purchases drive the weighted average fuel cost per litre used by trip and machine costing.",
                        color = LocalVineColors.current.textSecondary,
                        fontSize = 12.sp,
                    )
                }
            }
        }
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
    val costPerLitre = if (purchase.volumeLitres > 0) purchase.totalCost / purchase.volumeLitres else null
    VineyardCard(modifier = if (canEdit) Modifier.clickable { onClick() } else Modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(FuelTint.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.LocalGasStation, contentDescription = null, tint = FuelTint, modifier = Modifier.size(22.dp)) }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                if (canViewFinancials) {
                    Text(
                        "${fmt.formatFuel(purchase.volumeLitres)} — ${fmt.formatCurrency(purchase.totalCost)}",
                        color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    )
                } else {
                    Text(fmt.formatFuel(purchase.volumeLitres), color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(formatPurchaseDate(purchase.date), color = vine.textSecondary, fontSize = 12.sp)
                    if (canViewFinancials && costPerLitre != null) {
                        Text(fmt.formatFuelCostPerUnit(costPerLitre), color = VineColors.LeafGreen, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    }
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
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    var volume by remember { mutableStateOf(existing?.volumeLitres?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var cost by remember { mutableStateOf(existing?.totalCost?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var dateMs by remember { mutableStateOf(purchaseEpochMs(existing?.date) ?: System.currentTimeMillis()) }
    var showDatePicker by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var saveError by remember { mutableStateOf<String?>(null) }
    val vol = volume.replace(',', '.').toDoubleOrNull() ?: 0.0
    val cst = cost.replace(',', '.').toDoubleOrNull() ?: 0.0
    val canSave = vol > 0 && cst > 0 && !saving

    fun save() {
        saving = true
        saveError = null
        val input = FuelPurchaseRepository.PurchaseInput(
            volumeLitres = vol,
            totalCost = cst,
            dateIso = Instant.ofEpochMilli(dateMs).toString(),
        )
        val cb: (Boolean) -> Unit = { ok ->
            saving = false
            if (ok) onDismiss() else saveError = "Couldn't save the purchase. Check your connection and try again."
        }
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
            OutlinedButton(onClick = { showDatePicker = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.CalendarMonth, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("  " + formatPurchaseDate(Instant.ofEpochMilli(dateMs).toString()))
            }
            if (vol > 0 && cst > 0) {
                Text(fmt.formatFuelCostPerUnit(cst / vol), color = vine.textSecondary, fontSize = 13.sp)
            }
            saveError?.let { Text(it, color = VineColors.Destructive, fontSize = 12.sp) }
            Button(
                onClick = { save() }, enabled = canSave, modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = FuelTint),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (existing == null) "Add" else "Save")
            }
            if (existing != null && onDelete != null) {
                TextButton(onClick = onDelete, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Delete purchase", color = VineColors.Destructive)
                }
            }
        }
    }

    if (showDatePicker) {
        val dpState = rememberDatePickerState(initialSelectedDateMillis = dateMs)
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    dpState.selectedDateMillis?.let { dateMs = it }
                    showDatePicker = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { showDatePicker = false }) { Text("Cancel") } },
        ) { DatePicker(state = dpState) }
    }
}

/** Epoch millis for an ISO purchase date, tolerating date-only values. */
private fun purchaseEpochMs(iso: String?): Long? {
    if (iso.isNullOrBlank()) return null
    return try {
        Instant.parse(iso).toEpochMilli()
    } catch (e: Exception) {
        try {
            SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(iso.take(10))?.time
        } catch (e2: Exception) {
            null
        }
    }
}

private fun formatPurchaseDate(iso: String?): String {
    val ms = purchaseEpochMs(iso) ?: return "Not specified"
    return SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(ms))
}

/** Most recent earlier fill for the same machine (used for the display L/hr). */
private fun previousFillForMachine(all: List<TractorFuelLog>, current: TractorFuelLog): TractorFuelLog? {
    val key = fuelLogGroupKey(current)
    val curMs = current.fillEpochMs ?: Long.MAX_VALUE
    return all
        .filter { it.id != current.id && fuelLogGroupKey(it) == key && (it.fillEpochMs ?: 0L) < curMs }
        .maxByOrNull { it.fillEpochMs ?: 0L }
}

@Composable
private fun FuelLogList(
    state: AppUiState,
    modifier: Modifier,
    canViewFinancials: Boolean,
    canEdit: (TractorFuelLog) -> Boolean,
    onAdd: () -> Unit,
    onEdit: (TractorFuelLog) -> Unit,
) {
    val logs = state.fuelLogs
    when {
        state.isLoadingVineyardData && logs.isEmpty() -> {
            Box(modifier, contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = FuelTint)
            }
        }
        logs.isEmpty() && !state.isOnline -> {
            Box(modifier.padding(24.dp), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = Icons.Filled.LocalGasStation,
                    title = "No saved fuel fills",
                    message = "You're offline and there are no fuel fills saved on this device. Reconnect to load your team's fuel log.",
                )
            }
        }
        logs.isEmpty() && state.machines.isEmpty() -> {
            Box(modifier.padding(24.dp), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = Icons.Filled.LocalGasStation,
                    title = "No fuel fills yet",
                    message = "No vineyard machines with fuel tracking enabled yet. Add a vineyard machine to record fuel fills against it.",
                )
            }
        }
        logs.isEmpty() -> {
            Box(modifier.padding(24.dp), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = Icons.Filled.LocalGasStation,
                    title = "No fuel fills yet",
                    message = "No fuel fills recorded yet. Tap + to record litres added and engine hours when you fill a vineyard machine.",
                    actionLabel = "Record fuel fill",
                    onAction = onAdd,
                )
            }
        }
        else -> {
            // Group by machine (machineId preferred, falling back to tractor link),
            // preserving the newest-first order the list already carries.
            val order = remember(logs) { logs.map { fuelLogGroupKey(it) }.distinct() }
            val grouped = remember(logs) { logs.groupBy { fuelLogGroupKey(it) } }
            LazyColumn(
                modifier = modifier,
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                order.forEach { key ->
                    val groupLogs = grouped[key] ?: emptyList()
                    val header = groupLogs.firstOrNull()
                        ?.let { resolveFuelLogMachineName(it, state.machines) } ?: "Machine"
                    item(key = "h-$key") { SectionHeader(header, onLight = true) }
                    items(groupLogs, key = { it.id }) { log ->
                        val previous = previousFillForMachine(logs, log)
                        val rate = fuelRate(log, previous)
                        FuelRow(
                            log = log,
                            litresPerHour = rate.litresPerHour,
                            reliable = rate.isReliable,
                            canViewFinancials = canViewFinancials,
                            onClick = if (canEdit(log)) ({ onEdit(log) }) else null,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FuelRow(
    log: TractorFuelLog,
    litresPerHour: Double?,
    reliable: Boolean,
    canViewFinancials: Boolean,
    onClick: (() -> Unit)?,
) {
    val vine = LocalVineColors.current
    val rowModifier = if (onClick != null) Modifier.clickable { onClick() } else Modifier
    VineyardCard(modifier = rowModifier) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                modifier = Modifier.size(40.dp).clip(CircleShape).background(FuelTint.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.LocalGasStation, contentDescription = null, tint = FuelTint, modifier = Modifier.size(20.dp))
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("${trimNum(log.litresAdded)} L", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp)
                    if (log.filledToFull == true) {
                        Icon(Icons.Filled.WaterDrop, contentDescription = "Filled to full", tint = VineColors.LeafGreen, modifier = Modifier.size(14.dp))
                        Text("Full", fontSize = 11.sp, fontWeight = FontWeight.Medium, color = VineColors.LeafGreen)
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FuelMeta(Icons.Filled.CalendarMonth, formatFuelDate(log.fillEpochMs) ?: "—")
                    log.engineHours?.let { FuelMeta(Icons.Filled.Speed, "${trimNum(it)} hrs") }
                }
                log.operatorName?.takeIf { it.isNotBlank() }?.let { FuelMeta(Icons.Filled.Person, it) }
                if (canViewFinancials) {
                    log.costPerLitre?.takeIf { it > 0 }?.let {
                        Text("$${"%.2f".format(it)}/L", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = VineColors.DarkGreen)
                    }
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                if (litresPerHour != null) {
                    Text(
                        "${trimNum(litresPerHour)} L/h",
                        fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        color = if (reliable) VineColors.LeafGreen else VineColors.Warning,
                    )
                    Text(if (reliable) "calculated" else "estimate", fontSize = 11.sp, color = vine.textSecondary)
                } else {
                    Text("—", fontSize = 14.sp, color = vine.textSecondary)
                }
            }
            if (onClick != null) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
            }
        }
    }
}

@Composable
private fun FuelMeta(icon: ImageVector, text: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(13.dp))
        Text(text, fontSize = 13.sp, color = vine.textSecondary, maxLines = 1)
    }
}

/**
 * Post-save "Fuel Fill Saved" step, mirroring the iOS calculated-rate summary.
 * Shows the derived L/hr and engine-hours delta, plus — for owners/managers
 * with a linked machine — an explicit "use as machine default" action so real
 * fuel-log data can refine the machine's average fuel usage over time. The
 * machine's stored rate is never changed without the user choosing to.
 */
@Composable
private fun FuelSavedSummary(
    vm: AppViewModel,
    rate: FuelRateResult,
    hoursDelta: Double?,
    machine: VineyardMachine?,
    canApplyDefault: Boolean,
    onDone: () -> Unit,
) {
    val vine = LocalVineColors.current
    var applying by remember { mutableStateOf(false) }
    var applied by remember { mutableStateOf(false) }
    var applyError by remember { mutableStateOf<String?>(null) }
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(22.dp))
            Text("Fuel fill saved", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        }

        VineyardCard {
            val lph = rate.litresPerHour
            if (lph != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Fuel rate", color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    Text(
                        "${trimNum(lph)} L/hr",
                        fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        color = if (rate.isReliable) VineColors.LeafGreen else VineColors.Warning,
                    )
                }
                if (hoursDelta != null) {
                    Spacer(Modifier.size(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Engine hours since last fill", color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                        Text("${trimNum(hoursDelta)} hrs", color = vine.textSecondary, fontSize = 13.sp)
                    }
                }
                Spacer(Modifier.size(8.dp))
                Text(
                    if (rate.isReliable) "Calculated between two full fills."
                    else "Estimate — most accurate when both fills are to a full tank.",
                    color = vine.textSecondary, fontSize = 12.sp,
                )
            } else {
                Text(
                    "Litres per hour could not be calculated for this fill. Add engine hours on consecutive fills for the same machine to track fuel use.",
                    color = vine.textSecondary, fontSize = 13.sp,
                )
            }
        }

        val lph = rate.litresPerHour
        if (lph != null && machine != null && canApplyDefault) {
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (applied) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
                            Text(
                                "Updated ${machine.displayName} default to ${trimNum(lph)} L/hr",
                                color = VineColors.LeafGreen, fontSize = 13.sp, fontWeight = FontWeight.Medium,
                            )
                        }
                    } else {
                        OutlinedButton(
                            onClick = {
                                applying = true
                                applyError = null
                                val input = VineyardMachineRepository.MachineInput(
                                    name = machine.name,
                                    machineType = machine.machineType ?: "tractor",
                                    fuelTrackingEnabled = machine.fuelTrackingEnabled,
                                    availableForJobCosting = machine.availableForJobCosting,
                                    fuelUsageLPerHour = lph,
                                    notes = machine.notes,
                                    serialNumber = machine.serialNumber,
                                    vinNumber = machine.vinNumber,
                                )
                                vm.updateVineyardMachine(machine.id, input) { ok ->
                                    applying = false
                                    if (ok) applied = true
                                    else applyError = "Couldn't update the machine default. Check your connection and try again."
                                }
                            },
                            enabled = !applying,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            if (applying) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.size(8.dp))
                                Text("Updating…")
                            } else {
                                Text("Use ${trimNum(lph)} L/hr as machine default")
                            }
                        }
                        applyError?.let { Text(it, color = VineColors.Destructive, fontSize = 12.sp) }
                        Text(
                            "The machine's default fuel rate is only changed if you choose to update it here.",
                            color = vine.textSecondary, fontSize = 11.sp,
                        )
                    }
                }
            }
        }

        Button(
            onClick = onDone,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = FuelTint),
        ) { Text("Done") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FuelSheet(
    vm: AppViewModel,
    state: AppUiState,
    existing: TractorFuelLog?,
    canManageSetup: Boolean,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    // Machines available for fuel logging (all loaded machines; mirrors iOS,
    // minus the per-machine fuel-tracking flag which Android doesn't load yet).
    val machines = remember(state.machines) { state.machines }
    var machine by remember {
        mutableStateOf(existing?.let { e -> machines.firstOrNull { it.id == e.machineId || (e.tractorId != null && (it.id == e.tractorId || it.legacyTractorId == e.tractorId)) } })
    }
    var litresText by remember { mutableStateOf(existing?.litresAdded?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var engineHoursText by remember { mutableStateOf(existing?.engineHours?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var dateMs by remember { mutableStateOf(existing?.fillEpochMs ?: System.currentTimeMillis()) }
    var operatorName by remember { mutableStateOf(existing?.operatorName ?: "") }
    var costPerLitreText by remember { mutableStateOf(existing?.costPerLitre?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var totalCostText by remember { mutableStateOf(existing?.totalCost?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var filledToFull by remember { mutableStateOf(existing?.filledToFull ?: true) }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var machineMenu by remember { mutableStateOf(false) }
    var showDatePicker by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    // After a successful save, holds the derived rate so we show the calculated
    // L/hr summary before dismissing (mirrors the iOS "Fuel Fill Saved" step).
    var savedRate by remember { mutableStateOf<FuelRateResult?>(null) }
    var savedHoursDelta by remember { mutableStateOf<Double?>(null) }

    val litres = litresText.replace(',', '.').toDoubleOrNull() ?: 0.0
    val canSave = litres > 0 && !saving

    fun save() {
        if (!canSave) return
        saving = true
        // Derive the display rate against the most recent earlier fill for the
        // same machine, so the saved summary can show calculated L/hr.
        val enteredHours = engineHoursText.replace(',', '.').toDoubleOrNull()
        val previewLog = TractorFuelLog(
            id = existing?.id ?: "preview",
            vineyardId = existing?.vineyardId ?: state.selectedVineyardId.orEmpty(),
            machineId = machine?.id,
            tractorId = machine?.legacyTractorId,
            fillDatetime = Instant.ofEpochMilli(dateMs).toString(),
            litresAdded = litres,
            engineHours = enteredHours,
            filledToFull = filledToFull,
        )
        val previous = previousFillForMachine(state.fuelLogs.filter { it.id != existing?.id }, previewLog)
        val rate = fuelRate(previewLog, previous)
        val delta = if (enteredHours != null && previous?.engineHours != null) enteredHours - previous.engineHours else null
        // Prefer machine_id as the link; populate legacy tractor_id only when the
        // machine is backed by a legacy tractor so trip costing keeps working.
        val input = FuelLogRepository.FuelInput(
            machineId = machine?.id,
            tractorId = machine?.legacyTractorId,
            fillDatetime = Instant.ofEpochMilli(dateMs).toString(),
            litresAdded = litres,
            engineHours = engineHoursText.replace(',', '.').toDoubleOrNull(),
            operatorName = operatorName.trim().ifBlank { null },
            costPerLitre = costPerLitreText.replace(',', '.').toDoubleOrNull(),
            totalCost = totalCostText.replace(',', '.').toDoubleOrNull(),
            filledToFull = filledToFull,
            notes = notes.trim().ifBlank { null },
        )
        val cb: (Boolean) -> Unit = { ok ->
            saving = false
            if (ok) {
                savedHoursDelta = delta
                savedRate = rate
            }
        }
        if (existing == null) vm.createFuelLog(input, cb) else vm.updateFuelLog(existing.id, input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        val savedSummary = savedRate
        if (savedSummary != null) {
            FuelSavedSummary(
                vm = vm,
                rate = savedSummary,
                hoursDelta = savedHoursDelta,
                machine = machine,
                canApplyDefault = canManageSetup && machine?.isLegacyTractor == false,
                onDone = onSaved,
            )
            return@ModalBottomSheet
        }
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(if (existing == null) "Record fuel fill" else "Edit fuel fill", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            // Machine picker (optional link).
            ExposedDropdownMenuBox(expanded = machineMenu, onExpandedChange = { machineMenu = it }) {
                OutlinedTextField(
                    value = machine?.displayName ?: "No linked machine",
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Machine") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = machineMenu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(expanded = machineMenu, onDismissRequest = { machineMenu = false }) {
                    DropdownMenuItem(text = { Text("No linked machine") }, onClick = { machine = null; machineMenu = false })
                    machines.forEach { m ->
                        DropdownMenuItem(
                            text = { Text(m.displayName) },
                            onClick = { machine = m; machineMenu = false },
                        )
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = litresText,
                    onValueChange = { litresText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                    label = { Text("Litres added") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = engineHoursText,
                    onValueChange = { engineHoursText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                    label = { Text("Engine hours") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }

            OutlinedButton(onClick = { showDatePicker = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Schedule, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("  " + (formatFuelDate(dateMs) ?: "Pick date"))
            }

            OutlinedTextField(
                value = operatorName,
                onValueChange = { operatorName = it },
                label = { Text("Operator (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Filled to full", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                    Text("Most accurate L/h when both fills are full.", color = vine.textSecondary, fontSize = 12.sp)
                }
                Switch(checked = filledToFull, onCheckedChange = { filledToFull = it })
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = costPerLitreText,
                    onValueChange = { costPerLitreText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                    label = { Text("Cost / litre") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = totalCostText,
                    onValueChange = { totalCostText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                    label = { Text("Total cost") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }

            // Auto-calc: litres × cost per litre → total. Explicit action only —
            // never overwrites a manually entered receipt total on its own, and
            // the total field stays editable afterwards. Zero cost per litre is
            // allowed (internal transfers / free fuel).
            val costPerLitreValue = costPerLitreText.replace(',', '.').toDoubleOrNull()
            val canCalculateTotal = litres > 0 && costPerLitreValue != null && costPerLitreValue >= 0
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                OutlinedButton(
                    onClick = {
                        val cpl = costPerLitreValue ?: return@OutlinedButton
                        totalCostText = String.format(Locale.US, "%.2f", (litres * cpl).coerceAtLeast(0.0))
                    },
                    enabled = canCalculateTotal,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Calculate, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Calculate total")
                }
                Text(
                    if (canCalculateTotal) "Total = litres × cost per litre. You can still edit the total after calculating."
                    else "Enter litres and cost per litre to calculate the total.",
                    color = vine.textSecondary,
                    fontSize = 12.sp,
                )
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth(),
            )

            Button(
                onClick = { save() },
                enabled = canSave,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = FuelTint),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (existing == null) "Save fill" else "Save changes")
            }

            if (existing != null && canManageSetup) {
                TextButton(onClick = { confirmDelete = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive)
                    Text("  Delete fill", color = VineColors.Destructive)
                }
            }
        }
    }

    if (showDatePicker) {
        val dpState = rememberDatePickerState(initialSelectedDateMillis = dateMs)
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    dpState.selectedDateMillis?.let { dateMs = it }
                    showDatePicker = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { showDatePicker = false }) { Text("Cancel") } },
        ) { DatePicker(state = dpState) }
    }

    if (confirmDelete && existing != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete fuel fill?") },
            text = { Text("This removes the fill for your whole team. This can't be undone here.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    vm.deleteFuelLog(existing.id) { ok -> if (ok) onSaved() }
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

private fun formatFuelDate(epochMs: Long?): String? {
    epochMs ?: return null
    return SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(epochMs))
}

private fun trimNum(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)
