package com.rork.vinetrack.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.AddAPhoto
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.material.icons.filled.Payments
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.ReceiptLong
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
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
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberDatePickerState
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rork.vinetrack.data.MaintenanceLogRepository
import com.rork.vinetrack.data.model.MaintenanceLog
import com.rork.vinetrack.data.model.SprayEquipment
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.data.model.machineTypeLabel
import com.rork.vinetrack.data.model.resolveMaintenanceEquipmentName
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import coil3.compose.AsyncImage
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Date
import java.util.Locale

/**
 * Stable identity for a piece of equipment selected in the maintenance form.
 * `source` matches `maintenance_logs.equipment_source` ("vineyard_machine" or
 * "spray_equipment"), carrying the snapshot name used when the link can't be
 * resolved later.
 */
private data class EquipmentRef(val source: String, val refId: String, val name: String)

@Composable
fun MaintenanceScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    var selectedLogId by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<MaintenanceLog?>(null) }

    val selectedLog = state.maintenanceLogs.firstOrNull { it.id == selectedLogId }

    // iOS/Work Tasks parity: refresh records automatically when the tool opens.
    LaunchedEffect(Unit) { vm.refreshMaintenanceLogs() }

    AnimatedContent(
        targetState = selectedLog,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "maintenance-nav",
        modifier = modifier,
    ) { log ->
        if (log != null) {
            MaintenanceDetailView(
                vm = vm,
                state = state,
                logId = log.id,
                onBack = { selectedLogId = null },
                onEdit = { editing = it },
            )
        } else {
            MaintenanceListView(
                vm = vm,
                state = state,
                onBack = onBack,
                onSelect = { selectedLogId = it.id },
                onAdd = { creating = true },
            )
        }
    }

    if (creating) {
        MaintenanceSheet(vm, state, existing = null, onDismiss = { creating = false }, onSaved = { creating = false })
    }
    editing?.let { log ->
        MaintenanceSheet(vm, state, existing = log, onDismiss = { editing = null }, onSaved = { editing = null })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaintenanceListView(
    vm: AppViewModel,
    state: AppUiState,
    onBack: (() -> Unit)?,
    onSelect: (MaintenanceLog) -> Unit,
    onAdd: () -> Unit,
) {
    val vine = LocalVineColors.current
    val canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager"
    var search by remember { mutableStateOf("") }
    var refreshing by remember { mutableStateOf(false) }

    val sorted = remember(state.maintenanceLogs) { state.maintenanceLogs.sortedByDescending { it.startEpochMs ?: 0L } }
    val filtered = remember(sorted, search, state.machines, state.sprayEquipment, state.equipmentItems) {
        if (search.isBlank()) sorted else {
            val q = search.trim()
            sorted.filter {
                resolveMaintenanceEquipmentName(it, state.machines, state.sprayEquipment, state.equipmentItems).contains(q, true) ||
                    it.itemName.contains(q, true) ||
                    it.workCompleted.contains(q, true) ||
                    it.partsUsed.contains(q, true)
            }
        }
    }
    val totalParts = remember(state.maintenanceLogs) { state.maintenanceLogs.sumOf { it.partsCost } }
    val totalLabour = remember(state.maintenanceLogs) { state.maintenanceLogs.sumOf { it.labourCost } }
    val totalHours = remember(state.maintenanceLogs) { state.maintenanceLogs.sumOf { it.hours } }
    val recordCount = state.maintenanceLogs.size

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Maintenance Log") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                actions = { IconButton(onClick = onAdd) { Icon(Icons.Filled.Add, contentDescription = "Log maintenance") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        if (state.isLoadingVineyardData && state.maintenanceLogs.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = VineColors.LeafGreen)
            }
            return@Scaffold
        }
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                refreshing = true
                vm.refreshMaintenanceLogs { refreshing = false }
            },
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item(key = "summary") {
                if (canViewFinancials) {
                    VineyardCard {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text("Cost Summary", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                                Text("$recordCount record${if (recordCount == 1) "" else "s"}", fontSize = 14.sp, color = vine.textSecondary)
                            }
                            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text("Total", fontSize = 12.sp, color = vine.textSecondary)
                                Text(formatMoney(totalParts + totalLabour), fontSize = 22.sp, fontWeight = FontWeight.Bold, color = VineColors.EarthBrown)
                            }
                        }
                        Box(Modifier.height(16.dp))
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            MaintMetric(Modifier.weight(1f), Icons.Filled.Build, formatMoney(totalParts), "Parts", VineColors.Orange)
                            MaintMetric(Modifier.weight(1f), Icons.Filled.Payments, formatMoney(totalLabour), "Labour", VineColors.Primary)
                            MaintMetric(Modifier.weight(1f), Icons.Filled.Schedule, "%.1f".format(totalHours), "Labour Hours", VineColors.Olive)
                        }
                    }
                } else {
                    VineyardCard {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Box(
                                modifier = Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(VineColors.EarthBrown.copy(alpha = 0.12f)),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(Icons.Filled.Build, contentDescription = null, tint = VineColors.EarthBrown)
                            }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text("$recordCount record${if (recordCount == 1) "" else "s"}", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                                Text("%.1f total labour hours logged".format(totalHours), fontSize = 12.sp, color = vine.textSecondary)
                            }
                        }
                    }
                }
            }
            item(key = "search") {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    placeholder = { Text("Search logs…") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (filtered.isEmpty()) {
                item(key = "empty") {
                    VineyardCard {
                        Column(
                            Modifier.fillMaxWidth().padding(vertical = 24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Filled.Build, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(40.dp))
                            Text(if (search.isBlank()) "No Maintenance Records" else "No logs found", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            if (search.isBlank()) Text("Tap + to log maintenance work on machinery, pumps, or equipment.", fontSize = 13.sp, color = vine.textSecondary)
                        }
                    }
                }
            } else {
                items(filtered, key = { it.id }) { log ->
                    MaintenanceRow(
                        log = log,
                        equipmentName = resolveMaintenanceEquipmentName(log, state.machines, state.sprayEquipment, state.equipmentItems),
                        canViewFinancials = canViewFinancials,
                        onClick = { onSelect(log) },
                    )
                }
            }
        }
        }
    }
}

@Composable
private fun MaintMetric(modifier: Modifier, icon: ImageVector, value: String, label: String, tint: Color) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Text(value, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary, maxLines = 1)
        Text(label, fontSize = 12.sp, color = vine.textSecondary)
    }
}

/** Compact label + value pair shown in the log row metric grid (iOS parity). */
private data class RowMetric(val label: String, val value: String, val emphasised: Boolean = false)

@Composable
private fun MaintenanceRow(log: MaintenanceLog, equipmentName: String, canViewFinancials: Boolean, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    // Mirrors the iOS row grid: Labour Hours, Machine hours, then financials
    // (Parts / Labour / emphasised Total) for owners and managers only.
    val metrics = remember(log, canViewFinancials) {
        buildList {
            add(RowMetric("Labour Hours", "%.1f h".format(log.hours)))
            log.machineHours?.takeIf { it > 0 }?.let { add(RowMetric("Machine", "%.0f mh".format(it))) }
            if (canViewFinancials) {
                add(RowMetric("Parts", formatMoney(log.partsCost)))
                add(RowMetric("Labour", formatMoney(log.labourCost)))
                add(RowMetric("Total", formatMoney(log.totalCost), emphasised = true))
            }
        }
    }
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.EarthBrown),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Build, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        equipmentName,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                    if (log.hasInvoicePhoto) {
                        Icon(Icons.Filled.Description, contentDescription = "Invoice attached", tint = vine.textSecondary, modifier = Modifier.size(14.dp))
                    }
                    Text(formatMaintDate(log.startEpochMs) ?: "—", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary, maxLines = 1)
                }
                log.workCompleted.takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary, maxLines = 2)
                }
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    metrics.chunked(2).forEach { pair ->
                        Row(Modifier.fillMaxWidth()) {
                            pair.forEach { m -> RowMetricCell(m, Modifier.weight(1f)) }
                            if (pair.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RowMetricCell(metric: RowMetric, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(metric.label, fontSize = 12.sp, color = vine.textSecondary, maxLines = 1)
        Text(
            metric.value,
            fontSize = 12.sp,
            fontWeight = if (metric.emphasised) FontWeight.Bold else FontWeight.SemiBold,
            color = if (metric.emphasised) VineColors.EarthBrown else vine.textPrimary,
            maxLines = 1,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaintenanceDetailView(
    vm: AppViewModel,
    state: AppUiState,
    logId: String,
    onBack: () -> Unit,
    onEdit: (MaintenanceLog) -> Unit,
) {
    val vine = LocalVineColors.current
    val log = state.maintenanceLogs.firstOrNull { it.id == logId }

    LaunchedEffect(log == null) { if (log == null) onBack() }
    if (log == null) return

    val equipmentName = resolveMaintenanceEquipmentName(log, state.machines, state.sprayEquipment, state.equipmentItems)
    // Financials are visible to owners/managers only, matching iOS.
    val canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager"
    val creatorName = resolveCreatorName(log.createdBy, state.members)

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(equipmentName, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                },
                actions = {
                    IconButton(onClick = { onEdit(log) }) { Icon(Icons.Filled.Notes, contentDescription = "Edit log") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Details", onLight = true)
                VineyardCard {
                    DetailRowM(Icons.Filled.Agriculture, "Equipment", equipmentName, VineColors.Orange)
                    DividerM(vine.cardBorder)
                    DetailRowM(Icons.Filled.Schedule, "Date", formatMaintDate(log.startEpochMs) ?: "—", VineColors.Cyan)
                    creatorName?.let {
                        DividerM(vine.cardBorder)
                        DetailRowM(Icons.Filled.Person, "Logged by", it, VineColors.Primary)
                    }
                    log.machineHours?.takeIf { it > 0 }?.let {
                        DividerM(vine.cardBorder)
                        DetailRowM(Icons.Filled.Speed, "Machine hours", "${trimNum(it)} h", VineColors.Indigo)
                    }
                    if (log.hours > 0) {
                        DividerM(vine.cardBorder)
                        DetailRowM(Icons.Filled.Build, "Labour time", "${trimNum(log.hours)} h", VineColors.EarthBrown)
                    }
                }
            }

            if (log.workCompleted.isNotBlank() || log.partsUsed.isNotBlank()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Work", onLight = true)
                    VineyardCard {
                        if (log.workCompleted.isNotBlank()) {
                            Text("Work completed", color = vine.textSecondary, fontSize = 13.sp)
                            Text(log.workCompleted, color = vine.textPrimary, fontSize = 14.sp, modifier = Modifier.padding(top = 2.dp))
                        }
                        if (log.partsUsed.isNotBlank()) {
                            if (log.workCompleted.isNotBlank()) Spacer(Modifier.height(12.dp))
                            Text("Parts used", color = vine.textSecondary, fontSize = 13.sp)
                            Text(log.partsUsed, color = vine.textPrimary, fontSize = 14.sp, modifier = Modifier.padding(top = 2.dp))
                        }
                    }
                }
            }

            if (log.totalCost > 0 && canViewFinancials) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Cost", onLight = true)
                    VineyardCard {
                        CostRowM("Parts", formatMoney(log.partsCost), vine.textSecondary, vine.textPrimary)
                        DividerM(vine.cardBorder)
                        CostRowM("Labour", formatMoney(log.labourCost), vine.textSecondary, vine.textPrimary)
                        DividerM(vine.cardBorder)
                        CostRowM("Total", formatMoney(log.totalCost), vine.textPrimary, VineColors.PrimaryAccent, emphasise = true)
                        if (log.hours > 0) {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text("Cost per Hour", fontSize = 12.sp, color = vine.textSecondary)
                                Spacer(Modifier.weight(1f))
                                Text(
                                    "${formatMoney(log.totalCost / log.hours)}/hr",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = vine.textSecondary,
                                )
                            }
                        }
                    }
                }
            }

            if (log.hasInvoicePhoto) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Invoice", onLight = true)
                    MaintenanceInvoiceCard(vm, log.photoPath)
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EquipmentDetailView(state: AppUiState, equipment: EquipmentRef, onBack: () -> Unit) {
    val vine = LocalVineColors.current
    val machine = state.machines.firstOrNull { it.id == equipment.refId }
    val logs = remember(state.maintenanceLogs, equipment) {
        if (equipment.source == "spray_equipment") {
            state.maintenanceLogs.filter { it.equipmentSource == "spray_equipment" && it.equipmentRefId == equipment.refId }
        } else {
            machine?.let { logsForMachine(state.maintenanceLogs, it) } ?: emptyList()
        }.sortedByDescending { it.startEpochMs ?: 0L }
    }
    val totalSpend = logs.sumOf { it.totalCost }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(equipment.name, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            VineyardCard {
                DetailRowM(
                    if (equipment.source == "spray_equipment") Icons.Filled.WaterDrop else Icons.Filled.Agriculture,
                    "Type",
                    if (equipment.source == "spray_equipment") "Spray equipment" else machineTypeLabel(machine?.machineType),
                    if (equipment.source == "spray_equipment") VineColors.Cyan else VineColors.Orange,
                )
                if (totalSpend > 0) {
                    DividerM(vine.cardBorder)
                    DetailRowM(Icons.Filled.Payments, "Total maintenance", formatMoney(totalSpend), VineColors.PrimaryAccent)
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Maintenance history · ${logs.size}", onLight = true)
                if (logs.isEmpty()) {
                    VineyardCard {
                        Text("No maintenance logged for this item yet.", color = vine.textSecondary, fontSize = 14.sp, modifier = Modifier.padding(vertical = 6.dp))
                    }
                } else {
                    logs.forEach { log ->
                        VineyardCard {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Box(
                                    modifier = Modifier.size(36.dp).clip(CircleShape).background(VineColors.EarthBrown.copy(alpha = 0.15f)),
                                    contentAlignment = Alignment.Center,
                                ) { Icon(Icons.Filled.Build, contentDescription = null, tint = VineColors.EarthBrown, modifier = Modifier.size(18.dp)) }
                                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(formatMaintDate(log.startEpochMs) ?: "—", color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                                    log.workCompleted.takeIf { it.isNotBlank() }?.let {
                                        Text(it, color = vine.textSecondary, fontSize = 13.sp, maxLines = 2)
                                    }
                                }
                                if (log.totalCost > 0) {
                                    Text(formatMoney(log.totalCost), color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaintenanceSheet(
    vm: AppViewModel,
    state: AppUiState,
    existing: MaintenanceLog?,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    // Equipment options grouped like the iOS picker: machines/tractors, spray
    // equipment, and Other Equipment & Assets, with a "None" choice.
    val machineOptions = remember(state.machines) {
        state.machines.map { EquipmentRef("vineyard_machine", it.id, it.displayName) }
    }
    val sprayOptions = remember(state.sprayEquipment) {
        state.sprayEquipment.map { EquipmentRef("spray_equipment", it.id, it.displayName) }
    }
    val otherOptions = remember(state.equipmentItems) {
        state.equipmentItems.map { EquipmentRef("equipment_item", it.id, it.displayName) }
    }
    var equipment by remember {
        mutableStateOf(
            existing?.equipmentRefId?.let { ref ->
                when (existing.equipmentSource) {
                    // Legacy "tractor" links resolve to the machine mirroring that tractor.
                    "vineyard_machine", "tractor" -> state.machines
                        .firstOrNull { it.id == ref || it.legacyTractorId == ref }
                        ?.let { EquipmentRef("vineyard_machine", it.id, it.displayName) }
                    "spray_equipment" -> sprayOptions.firstOrNull { it.refId == ref }
                    "equipment_item" -> otherOptions.firstOrNull { it.refId == ref }
                    else -> null
                }
            },
        )
    }
    var itemName by remember { mutableStateOf(existing?.itemName ?: "") }
    var dateMs by remember { mutableStateOf(existing?.startEpochMs ?: System.currentTimeMillis()) }
    var machineHoursText by remember { mutableStateOf(existing?.machineHours?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var labourHoursText by remember { mutableStateOf(existing?.hours?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var workCompleted by remember { mutableStateOf(existing?.workCompleted ?: "") }
    var partsUsed by remember { mutableStateOf(existing?.partsUsed ?: "") }
    var partsCostText by remember { mutableStateOf(existing?.partsCost?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var labourCostText by remember { mutableStateOf(existing?.labourCost?.takeIf { it > 0 }?.let { trimNum(it) } ?: "") }
    var equipMenu by remember { mutableStateOf(false) }
    var showDatePicker by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    // Photo picked for a brand-new log (uploaded after the log row is created).
    var pendingPhotoUri by remember { mutableStateOf<Uri?>(null) }

    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        if (existing != null) vm.uploadMaintenancePhoto(existing, uri) {} else pendingPhotoUri = uri
    }

    // The snapshot name is the linked equipment name when one is selected,
    // otherwise the free-text item name.
    val resolvedName = equipment?.name ?: itemName.trim()
    val canSave = resolvedName.isNotBlank() && !saving

    // Financial fields are gated by role, matching iOS (owner/manager only).
    val canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager"
    // Deleting lives in the edit sheet and matches the iOS role rules
    // (owner/manager/supervisor — iOS Role.canDelete).
    val canDelete = state.currentRole == "owner" || state.currentRole == "manager" || state.currentRole == "supervisor"
    var confirmDelete by remember { mutableStateOf(false) }
    val costTotal = (partsCostText.replace(',', '.').toDoubleOrNull() ?: 0.0) +
        (labourCostText.replace(',', '.').toDoubleOrNull() ?: 0.0)

    fun save() {
        if (!canSave) return
        saving = true
        val input = MaintenanceLogRepository.MaintenanceInput(
            itemName = resolvedName,
            equipmentSource = equipment?.source,
            equipmentRefId = equipment?.refId,
            hours = labourHoursText.replace(',', '.').toDoubleOrNull() ?: 0.0,
            machineHours = machineHoursText.replace(',', '.').toDoubleOrNull(),
            workCompleted = workCompleted.trim(),
            partsUsed = partsUsed.trim(),
            partsCost = partsCostText.replace(',', '.').toDoubleOrNull() ?: 0.0,
            labourCost = labourCostText.replace(',', '.').toDoubleOrNull() ?: 0.0,
            date = Instant.ofEpochMilli(dateMs).toString(),
            isArchived = existing?.isArchived ?: false,
            isFinalized = existing?.isFinalized ?: false,
        )
        val cb: (Boolean) -> Unit = { ok -> saving = false; if (ok) onSaved() }
        if (existing == null) vm.createMaintenanceLog(input, pendingPhotoUri, cb) else vm.updateMaintenanceLog(existing.id, input, cb)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(if (existing == null) "Log maintenance" else "Edit maintenance", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            // Equipment picker (sets the snapshot name when chosen).
            ExposedDropdownMenuBox(expanded = equipMenu, onExpandedChange = { equipMenu = it }) {
                OutlinedTextField(
                    value = equipment?.name ?: "No linked equipment",
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Equipment") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = equipMenu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(expanded = equipMenu, onDismissRequest = { equipMenu = false }) {
                    DropdownMenuItem(text = { Text("No linked equipment") }, onClick = { equipment = null; equipMenu = false })
                    val pick: (EquipmentRef) -> Unit = { opt ->
                        equipment = opt
                        if (itemName.isBlank()) itemName = opt.name
                        equipMenu = false
                    }
                    if (machineOptions.isNotEmpty()) {
                        EquipmentGroupLabel("Machines & Tractors")
                        machineOptions.forEach { opt ->
                            DropdownMenuItem(text = { Text(opt.name) }, onClick = { pick(opt) })
                        }
                    }
                    if (sprayOptions.isNotEmpty()) {
                        EquipmentGroupLabel("Spray Equipment")
                        sprayOptions.forEach { opt ->
                            DropdownMenuItem(text = { Text(opt.name) }, onClick = { pick(opt) })
                        }
                    }
                    if (otherOptions.isNotEmpty()) {
                        EquipmentGroupLabel("Other Equipment & Assets")
                        otherOptions.forEach { opt ->
                            DropdownMenuItem(text = { Text(opt.name) }, onClick = { pick(opt) })
                        }
                    }
                }
            }

            // Free-text item name — required when no equipment is linked.
            OutlinedTextField(
                value = itemName,
                onValueChange = { itemName = it },
                label = { Text(if (equipment == null) "Item name" else "Item name (snapshot)") },
                singleLine = true,
                enabled = equipment == null,
                modifier = Modifier.fillMaxWidth(),
            )

            OutlinedButton(onClick = { showDatePicker = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Schedule, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("  " + (formatMaintDate(dateMs) ?: "Pick date"))
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = machineHoursText,
                    onValueChange = { machineHoursText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                    label = { Text("Machine hours") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = labourHoursText,
                    onValueChange = { labourHoursText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                    label = { Text("Labour hrs") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }

            OutlinedTextField(
                value = workCompleted,
                onValueChange = { workCompleted = it },
                label = { Text("Work completed") },
                placeholder = { Text("Describe work completed...") },
                modifier = Modifier.fillMaxWidth().height(90.dp),
            )

            OutlinedTextField(
                value = partsUsed,
                onValueChange = { partsUsed = it },
                label = { Text("Parts used (optional)") },
                placeholder = { Text("List parts used...") },
                modifier = Modifier.fillMaxWidth().height(80.dp),
            )

            // Costs — iOS-parity stacked card: Parts Cost, Labour Cost, auto Total.
            if (canViewFinancials) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Costs", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(vine.cardBackground, RoundedCornerShape(12.dp))
                            .border(1.dp, vine.cardBorder, RoundedCornerShape(12.dp))
                            .padding(horizontal = 16.dp),
                    ) {
                        CostInputRowM(
                            label = "Parts Cost",
                            value = partsCostText,
                            onValueChange = { partsCostText = it },
                        )
                        HorizontalDivider(color = vine.cardBorder)
                        CostInputRowM(
                            label = "Labour Cost",
                            value = labourCostText,
                            onValueChange = { labourCostText = it },
                        )
                        HorizontalDivider(color = vine.cardBorder)
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("Total", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            Spacer(Modifier.weight(1f))
                            Text(
                                formatMoneyExact(costTotal),
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.EarthBrown,
                            )
                        }
                    }
                }
            }

            MaintenancePhotoSection(
                vm = vm,
                log = existing,
                pendingPhotoUri = pendingPhotoUri,
                busy = state.maintenancePhotoBusy,
                onPick = { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                onRemove = { if (existing != null) vm.removeMaintenancePhoto(existing) {} else pendingPhotoUri = null },
            )

            Button(
                onClick = { save() },
                enabled = canSave,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (existing == null) "Save log" else "Save changes")
            }

            if (existing != null && canDelete) {
                TextButton(onClick = { confirmDelete = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    Text("  Delete Record", color = VineColors.Destructive)
                }
            }
        }
    }

    if (confirmDelete && existing != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete Record") },
            text = { Text("Are you sure you want to delete this maintenance record?") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    vm.deleteMaintenanceLog(existing.id) {}
                    onSaved()
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
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

/** Read-only invoice photo card for the maintenance detail view. */
@Composable
private fun MaintenanceInvoiceCard(vm: AppViewModel, photoPath: String?) {
    val vine = LocalVineColors.current
    var signedUrl by remember(photoPath) { mutableStateOf<String?>(null) }
    var unavailable by remember(photoPath) { mutableStateOf(false) }

    LaunchedEffect(photoPath) {
        signedUrl = null
        unavailable = false
        if (!photoPath.isNullOrBlank()) {
            vm.requestMaintenancePhotoUrl(photoPath) { url ->
                signedUrl = url
                unavailable = url.isNullOrBlank()
            }
        }
    }

    var showFull by remember(photoPath) { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(4f / 3f)
            .clip(RoundedCornerShape(12.dp))
            .background(vine.textSecondary.copy(alpha = 0.1f))
            .clickable(enabled = signedUrl != null) { showFull = true },
        contentAlignment = Alignment.Center,
    ) {
        val url = signedUrl
        when {
            url != null -> {
                AsyncImage(
                    model = url,
                    contentDescription = "Invoice photo",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxWidth().aspectRatio(4f / 3f),
                )
                // iOS-parity expand affordance — tap opens the invoice full screen.
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(8.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(Color.Black.copy(alpha = 0.45f))
                        .padding(6.dp),
                ) {
                    Icon(Icons.Filled.OpenInFull, contentDescription = "View full screen", tint = Color.White, modifier = Modifier.size(14.dp))
                }
            }
            unavailable -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.ReceiptLong, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                Text("Invoice unavailable offline", fontSize = 13.sp, color = vine.textSecondary)
            }
            else -> CircularProgressIndicator(color = VineColors.PrimaryAccent)
        }
    }

    val fullUrl = signedUrl
    if (showFull && fullUrl != null) {
        Dialog(onDismissRequest = { showFull = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                AsyncImage(
                    model = fullUrl,
                    contentDescription = "Invoice photo",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize(),
                )
                IconButton(
                    onClick = { showFull = false },
                    modifier = Modifier.align(Alignment.TopStart).padding(top = 32.dp, start = 8.dp),
                ) { Icon(Icons.Filled.Close, contentDescription = "Close", tint = Color.White) }
            }
        }
    }
}

/**
 * Invoice/receipt photo control for the maintenance form. Shows the attached
 * image (loaded through a signed URL for the private bucket), or an "Add photo"
 * affordance. For a new log the picked [pendingPhotoUri] is previewed locally
 * and uploaded once the row is saved.
 */
@Composable
private fun MaintenancePhotoSection(
    vm: AppViewModel,
    log: MaintenanceLog?,
    pendingPhotoUri: Uri?,
    busy: Boolean,
    onPick: () -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    val photoPath = log?.photoPath
    var signedUrl by remember(photoPath) { mutableStateOf<String?>(null) }
    var photoUnavailable by remember(photoPath) { mutableStateOf(false) }

    LaunchedEffect(photoPath) {
        signedUrl = null
        photoUnavailable = false
        if (!photoPath.isNullOrBlank()) {
            vm.requestMaintenancePhotoUrl(photoPath) { url ->
                signedUrl = url
                photoUnavailable = url.isNullOrBlank()
            }
        }
    }

    val hasImage = pendingPhotoUri != null || !photoPath.isNullOrBlank()

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Invoice photo", fontSize = 13.sp, color = vine.textSecondary)

        if (hasImage) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(4f / 3f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(vine.textSecondary.copy(alpha = 0.1f)),
                contentAlignment = Alignment.Center,
            ) {
                val model: Any? = pendingPhotoUri ?: signedUrl
                if (model != null) {
                    AsyncImage(
                        model = model,
                        contentDescription = "Invoice photo",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxWidth().aspectRatio(4f / 3f),
                    )
                } else if (photoUnavailable) {
                    Text("Photo unavailable offline", fontSize = 13.sp, color = vine.textSecondary)
                } else {
                    CircularProgressIndicator(color = VineColors.PrimaryAccent)
                }
                if (busy) {
                    Box(
                        modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)),
                        contentAlignment = Alignment.Center,
                    ) { CircularProgressIndicator(color = Color.White) }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onPick, enabled = !busy, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Filled.PhotoCamera, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Replace")
                }
                TextButton(onClick = onRemove, enabled = !busy) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    Text("  Remove", color = VineColors.Destructive)
                }
            }
        } else {
            OutlinedButton(onClick = onPick, enabled = !busy, modifier = Modifier.fillMaxWidth()) {
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = VineColors.PrimaryAccent)
                } else {
                    Icon(Icons.Filled.AddAPhoto, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Add invoice photo")
                }
            }
        }
    }
}

@Composable
private fun DetailRowM(icon: ImageVector, label: String, value: String, tint: Color) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(28.dp).clip(CircleShape).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp)) }
        Text(label, color = vine.textSecondary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(value, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun CostRowM(label: String, value: String, labelColor: Color, valueColor: Color, emphasise: Boolean = false) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = labelColor, fontSize = if (emphasise) 15.sp else 14.sp, fontWeight = if (emphasise) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.weight(1f))
        Text(value, color = valueColor, fontSize = if (emphasise) 16.sp else 14.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun DividerM(color: Color) {
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(color))
}

/** Maintenance logs for a machine, matching by id or the legacy tractor id. */
private fun logsForMachine(logs: List<MaintenanceLog>, machine: VineyardMachine): List<MaintenanceLog> =
    logs.filter {
        (it.equipmentSource == "vineyard_machine" || it.equipmentSource == "tractor") &&
            (it.equipmentRefId == machine.id || (machine.legacyTractorId != null && it.equipmentRefId == machine.legacyTractorId))
    }

private fun formatMaintDate(epochMs: Long?): String? {
    epochMs ?: return null
    return SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(epochMs))
}

/**
 * Resolve the "Logged by" display name for a maintenance record. `created_by`
 * stores the creator's user id, so it is resolved against the vineyard member
 * list; legacy iOS rows that carry a plain name are shown as-is, and
 * unresolvable ids are hidden rather than surfaced as raw UUIDs.
 */
private fun resolveCreatorName(createdBy: String?, members: List<VineyardMember>): String? {
    val raw = createdBy?.trim()?.takeIf { it.isNotBlank() } ?: return null
    members.firstOrNull { it.userId == raw }?.let { return it.name }
    val isUuid = runCatching { java.util.UUID.fromString(raw) }.isSuccess
    return if (isUuid) null else raw
}

/** Non-tappable group header inside the equipment dropdown, mirroring iOS picker sections. */
@Composable
private fun EquipmentGroupLabel(title: String) {
    val vine = LocalVineColors.current
    Text(
        title,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        color = vine.textSecondary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

private fun trimNum(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)

private fun formatMoney(value: Double): String {
    val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong()) else "%,.2f".format(value)
    return "$$rounded"
}

/** Always-two-decimals money display, used for the form's auto Total row. */
private fun formatMoneyExact(value: Double): String = "$%,.2f".format(value)

/**
 * iOS-style editable cost row: label on the left, "$" prefix plus a right-aligned
 * inline decimal field on the right. Blank input is treated as 0 by the caller.
 */
@Composable
private fun CostInputRowM(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 15.sp, color = vine.textPrimary)
        Spacer(Modifier.weight(1f))
        Text("$ ", fontSize = 15.sp, color = vine.textSecondary)
        BasicTextField(
            value = value,
            onValueChange = { input -> onValueChange(input.filter { c -> c.isDigit() || c == '.' || c == ',' }) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            textStyle = TextStyle(fontSize = 15.sp, color = vine.textPrimary, textAlign = TextAlign.End),
            cursorBrush = SolidColor(VineColors.PrimaryAccent),
            modifier = Modifier.width(96.dp),
            decorationBox = { innerTextField ->
                Box(contentAlignment = Alignment.CenterEnd) {
                    if (value.isEmpty()) {
                        Text("0.00", fontSize = 15.sp, color = vine.textSecondary.copy(alpha = 0.5f))
                    }
                    innerTextField()
                }
            },
        )
    }
}
