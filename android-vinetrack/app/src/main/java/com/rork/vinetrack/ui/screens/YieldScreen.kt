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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Assessment
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Calculate
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.Scale
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.SquareFoot
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
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
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.YieldDeterminationInputs
import com.rork.vinetrack.data.YieldDeterminationPrefsStore
import com.rork.vinetrack.data.YieldRepository
import com.rork.vinetrack.data.model.HistoricalBlockResult
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.canonicalVarietyName
import com.rork.vinetrack.data.RegionFormatter
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
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Yield surface — archived seasonal yield records backed by
 * `historical_yield_records`. Lists records grouped by season/year, drills into
 * per-block estimated vs actual tonnes, and lets members record/edit block-level
 * actual yields (consumed by Cost Reports) as well as author sampling estimates.
 * Mirrors the iOS source-of-truth contract via the shared block_results payload.
 */
/** Top-level destinations within the Yields surface, mirroring the iOS hub. */
private enum class YieldDestination { HUB, REPORTS, DETERMINATION, DAMAGE, ESTIMATION, SETTINGS }

@Composable
fun YieldScreen(vm: AppViewModel, state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    var destination by rememberSaveable { mutableStateOf(YieldDestination.HUB) }
    var selectedId by remember { mutableStateOf<String?>(null) }
    var selectedVarietyKey by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    var creatingEstimate by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<HistoricalYieldRecord?>(null) }
    var editingEstimate by remember { mutableStateOf<HistoricalYieldRecord?>(null) }

    // Vineyard-wide per-variety totals, derived from block results matched back to
    // current paddock allocations. Recomputed only when records/paddocks change.
    val varietySummaries = remember(state.yieldRecords, state.paddocks) {
        computeVarietyYieldSummaries(state.yieldRecords, state.paddocks)
    }

    val selected = state.yieldRecords.firstOrNull { it.id == selectedId }
    val selectedVariety = varietySummaries.firstOrNull { it.key == selectedVarietyKey }

    AnimatedContent(
        targetState = when {
            selected != null -> "detail"
            selectedVariety != null -> "variety"
            destination == YieldDestination.REPORTS -> "reports"
            destination == YieldDestination.DETERMINATION -> "determination"
            destination == YieldDestination.DAMAGE -> "damage"
            destination == YieldDestination.ESTIMATION -> "estimation"
            destination == YieldDestination.SETTINGS -> "settings"
            else -> "hub"
        },
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "yield-nav",
        modifier = modifier,
    ) { screen ->
        when (screen) {
            "detail" -> selected?.let { record ->
                YieldDetailView(
                    state = state,
                    record = record,
                    onBack = { selectedId = null },
                    onEdit = { editing = record },
                    onEditEstimate = { editingEstimate = record },
                    onDelete = { vm.deleteYieldRecord(record.id) { ok -> if (ok) selectedId = null } },
                )
            }
            "variety" -> selectedVariety?.let { variety ->
                VarietyYieldDetailView(summary = variety, fmt = state.regionFormatter, onBack = { selectedVarietyKey = null })
            }
            "reports" -> YieldListView(
                state = state,
                varietySummaries = varietySummaries,
                onBack = { destination = YieldDestination.HUB },
                onOpen = { selectedId = it.id },
                onOpenVariety = { selectedVarietyKey = it.key },
                onCreate = { creating = true },
                onCreateEstimate = { creatingEstimate = true },
            )
            "determination" -> YieldDeterminationView(
                state = state,
                onBack = { destination = YieldDestination.HUB },
            )
            "damage" -> DamageRecordsScreen(
                vm = vm,
                state = state,
                onBack = { destination = YieldDestination.HUB },
            )
            "estimation" -> YieldEstimationScreen(
                vm = vm,
                state = state,
                onBack = { destination = YieldDestination.HUB },
            )
            "settings" -> YieldSettingsScreen(
                state = state,
                onBack = { destination = YieldDestination.HUB },
            )
            else -> YieldHubView(
                state = state,
                varietySummaries = varietySummaries,
                onBack = onBack,
                onRecordActual = { creating = true },
                onEstimate = { destination = YieldDestination.ESTIMATION },
                onDetermination = { destination = YieldDestination.DETERMINATION },
                onReports = { destination = YieldDestination.REPORTS },
                onDamage = { destination = YieldDestination.DAMAGE },
                onSettings = { destination = YieldDestination.SETTINGS },
            )
        }
    }

    if (creating) {
        RecordYieldSheet(
            vm = vm,
            state = state,
            onDismiss = { creating = false },
            onSaved = { creating = false },
        )
    }

    if (creatingEstimate) {
        EstimateYieldSheet(
            vm = vm,
            state = state,
            existing = null,
            onDismiss = { creatingEstimate = false },
            onSaved = { creatingEstimate = false },
        )
    }

    editingEstimate?.let { rec ->
        val live = state.yieldRecords.firstOrNull { it.id == rec.id } ?: rec
        EstimateYieldSheet(
            vm = vm,
            state = state,
            existing = live,
            onDismiss = { editingEstimate = null },
            onSaved = { editingEstimate = null },
        )
    }

    editing?.let { rec ->
        // Keep the sheet bound to the latest version of the record from state.
        val live = state.yieldRecords.firstOrNull { it.id == rec.id } ?: rec
        EditYieldActualsSheet(
            vm = vm,
            record = live,
            onDismiss = { editing = null },
            onSaved = { editing = null },
        )
    }
}

/**
 * Yields hub — the landing surface for the yield domain, mirroring the iOS
 * `YieldHubView`. A summary header (estimates / blocks estimated / actuals) sits
 * above gradient option rows that route to recording actuals, the determination
 * calculator, sampling estimates and the full reports list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun YieldHubView(
    state: AppUiState,
    varietySummaries: List<VarietyYieldSummary>,
    onBack: (() -> Unit)?,
    onRecordActual: () -> Unit,
    onEstimate: () -> Unit,
    onDetermination: () -> Unit,
    onReports: () -> Unit,
    onDamage: () -> Unit,
    onSettings: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val records = state.yieldRecords

    // Estimate records are single-block sampling authorings (avg bunches > 0),
    // matching the iOS notion of a "session".
    val estimateRecords = remember(records) {
        records.filter { r -> r.blocks.size == 1 && r.blocks.first().averageBunchesPerVine > 0.0 }
    }
    val blocksEstimated = remember(records) {
        records.flatMap { it.blocks }.map { it.paddockId }.distinct().size
    }
    val actualsCount = remember(records) { records.count { it.totalActualYieldTonnes != null } }

    val latestDetermination = remember(records.size) {
        YieldDeterminationPrefsStore(context).latestTonnesPerHa()
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Yields") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(0.dp))
            // Summary header.
            VineyardCard {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    YieldStat("Sessions", estimateRecords.size.toString(), Icons.Filled.Assessment, VineColors.Purple, Modifier.weight(1f))
                    YieldStat("Blocks Est.", blocksEstimated.toString(), Icons.Filled.SquareFoot, VineColors.Indigo, Modifier.weight(1f))
                    YieldStat("Damage", state.damageRecords.size.toString(), Icons.Filled.Warning, VineColors.Destructive, Modifier.weight(1f))
                }
            }

            YieldHubOptionRow(
                icon = Icons.Filled.Calculate,
                gradient = listOf(VineColors.Purple, VineColors.Pink),
                title = "Pruning Yield Calculator",
                subtitle = "Pruning bud-load potential",
                detail = latestDetermination?.let { "Latest: ${state.regionFormatter.formatYieldPerArea(it)}" },
                onClick = onDetermination,
            )
            YieldHubOptionRow(
                icon = Icons.Filled.Warning,
                gradient = listOf(VineColors.Destructive, VineColors.Orange),
                title = "Record Damage",
                subtitle = "Adjust yield estimates for seasonal damage.",
                detail = state.damageRecords.size.takeIf { it > 0 }?.let { "$it damage record${if (it == 1) "" else "s"}" },
                onClick = onDamage,
            )
            YieldHubOptionRow(
                icon = Icons.Filled.Agriculture,
                gradient = listOf(VineColors.Orange, VineColors.Destructive),
                title = "Yield Estimation",
                subtitle = "Sample sites & bunch counts",
                detail = estimateRecords.size.takeIf { it > 0 }?.let { "$it estimate${if (it == 1) "" else "s"} recorded" },
                onClick = onEstimate,
            )
            YieldHubOptionRow(
                icon = Icons.Filled.EditNote,
                gradient = listOf(VineColors.LeafGreen, VineColors.DarkGreen),
                title = "Record Actual Yield",
                subtitle = "Add harvested tonnes by block & season",
                onClick = onRecordActual,
            )
            YieldHubOptionRow(
                icon = Icons.Filled.Assessment,
                gradient = listOf(VineColors.Indigo, VineColors.Info),
                title = "Yield Reports",
                subtitle = "Compare estimates and harvest results",
                detail = records.size.takeIf { it > 0 }?.let { "$it record${if (it == 1) "" else "s"}" },
                onClick = onReports,
            )
            YieldHubOptionRow(
                icon = Icons.Filled.Scale,
                gradient = listOf(VineColors.Indigo, VineColors.Purple),
                title = "Yield Settings",
                subtitle = "Default bunch weights per block",
                onClick = onSettings,
            )

            Row(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                    .background(vine.cardBackground).padding(12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.Info, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                Text(
                    "Actual yield records are used by Cost Reports to calculate cost per tonne.",
                    color = vine.textSecondary, fontSize = 12.sp,
                )
            }
        }
    }
}

@Composable
private fun YieldHubOptionRow(
    icon: ImageVector,
    gradient: List<Color>,
    title: String,
    subtitle: String,
    detail: String? = null,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp))
                    .background(Brush.linearGradient(gradient)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Text(subtitle, color = vine.textSecondary, fontSize = 12.sp, maxLines = 1)
                detail?.let { Text(it, color = vine.textSecondary, fontSize = 11.sp) }
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

/**
 * Yield Determination calculator, mirroring the iOS
 * `YieldDeterminationCalculatorView`. Computes potential yield from pruning
 * bud-load inputs for a chosen block, persisting per-block inputs and the latest
 * t/ha result on-device so the hub can surface a "Latest" detail.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun YieldDeterminationView(
    state: AppUiState,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val store = remember { YieldDeterminationPrefsStore(context) }
    val paddocks = state.paddocks

    var blockId by remember { mutableStateOf(paddocks.firstOrNull()?.id) }
    var blockMenu by remember { mutableStateOf(false) }
    val block = paddocks.firstOrNull { it.id == blockId }

    var pruneMethod by remember { mutableStateOf("Spur") }
    var bunchesPerBud by remember { mutableStateOf("1.5") }
    var budsPerSpur by remember { mutableStateOf("2") }
    var spursPerVine by remember { mutableStateOf("6") }
    var budsPerCane by remember { mutableStateOf("10") }
    var canesPerVine by remember { mutableStateOf("4") }
    var vinesPerHa by remember { mutableStateOf("") }
    var bunchWeight by remember { mutableStateOf("120") }
    var savedToast by remember { mutableStateOf(false) }

    // Load persisted inputs (or seed defaults from the block) when the block changes.
    androidx.compose.runtime.LaunchedEffect(blockId) {
        val saved = store.loadInputs(blockId)
        if (saved != null) {
            pruneMethod = saved.pruneMethod
            bunchesPerBud = saved.bunchesPerBud
            budsPerSpur = saved.budsPerSpur
            spursPerVine = saved.spursPerVine
            budsPerCane = saved.budsPerCane
            canesPerVine = saved.canesPerVine
            vinesPerHa = saved.vinesPerHa
            bunchWeight = saved.bunchWeight
        } else {
            val b = paddocks.firstOrNull { it.id == blockId }
            vinesPerHa = if (b != null && b.areaHectares > 0 && b.effectiveVineCount > 0) {
                (b.effectiveVineCount / b.areaHectares).toInt().toString()
            } else ""
        }
    }

    fun persist() {
        store.saveInputs(
            blockId,
            YieldDeterminationInputs(
                pruneMethod, bunchesPerBud, budsPerSpur, spursPerVine,
                budsPerCane, canesPerVine, vinesPerHa, bunchWeight,
            ),
        )
    }

    fun d(s: String): Double = s.replace(',', '.').toDoubleOrNull() ?: 0.0
    val budsPerVine = if (pruneMethod == "Spur") d(budsPerSpur) * d(spursPerVine) else d(budsPerCane) * d(canesPerVine)
    val bunchesPerHa = d(bunchesPerBud) * budsPerVine * d(vinesPerHa)
    val yieldKgPerHa = bunchesPerHa * d(bunchWeight) / 1000.0
    val yieldTonnesPerHa = yieldKgPerHa / 1000.0
    val totalYieldTonnes = block?.takeIf { it.areaHectares > 0 }?.let { yieldTonnesPerHa * it.areaHectares }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Pruning Yield Calculator") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            Column(
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp).padding(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Spacer(Modifier.height(0.dp))
                // Block picker.
                SectionHeader("Block", onLight = true)
                VineyardCard {
                    if (paddocks.isEmpty()) {
                        Text("No blocks available", color = vine.textSecondary, fontSize = 13.sp)
                    } else {
                        ExposedDropdownMenuBox(expanded = blockMenu, onExpandedChange = { blockMenu = it }) {
                            OutlinedTextField(
                                value = block?.name ?: "Select\u2026",
                                onValueChange = {},
                                readOnly = true,
                                label = { Text("Block") },
                                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = blockMenu) },
                                modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                            )
                            ExposedDropdownMenu(expanded = blockMenu, onDismissRequest = { blockMenu = false }) {
                                paddocks.forEach { opt ->
                                    DropdownMenuItem(
                                        text = { Text(opt.name) },
                                        onClick = { blockId = opt.id; blockMenu = false },
                                    )
                                }
                            }
                        }
                        block?.let {
                            Spacer(Modifier.height(10.dp))
                            CalcLine("Area", "${formatHaY(it.areaHectares)} ha")
                            CalcLine("Vines", it.effectiveVineCount.toString())
                        }
                    }
                }

                // Pruning method.
                SectionHeader("Pruning Method", onLight = true)
                VineyardCard {
                    Row(
                        modifier = Modifier.fillMaxWidth().selectableGroup(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        listOf("Spur", "Cane").forEach { method ->
                            val selected = pruneMethod == method
                            Box(
                                modifier = Modifier.weight(1f).clip(RoundedCornerShape(8.dp))
                                    .background(if (selected) VineColors.LeafGreen else vine.appBackground)
                                    .clickable { pruneMethod = method; persist() }
                                    .padding(vertical = 10.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    method,
                                    color = if (selected) Color.White else vine.textPrimary,
                                    fontSize = 14.sp,
                                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        if (pruneMethod == "Spur") "Spur pruning: short canes (spurs) left with a set number of buds each."
                        else "Cane pruning: longer canes retained on each vine with multiple buds per cane.",
                        color = vine.textSecondary, fontSize = 12.sp,
                    )
                }

                // Inputs.
                SectionHeader("Inputs", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        CalcInput("Bunches / Bud", bunchesPerBud) { bunchesPerBud = it; persist() }
                        if (pruneMethod == "Spur") {
                            CalcInput("Buds / Spur", budsPerSpur) { budsPerSpur = it; persist() }
                            CalcInput("Spurs / Vine", spursPerVine) { spursPerVine = it; persist() }
                        } else {
                            CalcInput("Buds / Cane", budsPerCane) { budsPerCane = it; persist() }
                            CalcInput("Canes / Vine", canesPerVine) { canesPerVine = it; persist() }
                        }
                        CalcInput("Vines / Ha", vinesPerHa) { vinesPerHa = it; persist() }
                        CalcInput("Bunch Weight (g)", bunchWeight) { bunchWeight = it; persist() }
                    }
                }

                // Calculated.
                SectionHeader("Calculated", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        CalcLine("Buds / Vine", String.format(Locale.getDefault(), "%.0f", budsPerVine))
                        CalcLine("Bunches / Ha", String.format(Locale.getDefault(), "%.0f", bunchesPerHa))
                        CalcLine("Yield / Ha (kg)", String.format(Locale.getDefault(), "%.1f", yieldKgPerHa))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Yield / Ha (t)", color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                            Text(
                                "${formatTonnes(yieldTonnesPerHa)} t",
                                color = VineColors.LeafGreen, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                            )
                        }
                        totalYieldTonnes?.let {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("Block Total", color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                                Text(
                                    String.format(Locale.getDefault(), "%.1f t", it),
                                    color = VineColors.LeafGreen, fontSize = 17.sp, fontWeight = FontWeight.Bold,
                                )
                            }
                        }
                    }
                }

                Text(
                    if (pruneMethod == "Spur")
                        "Yield / Ha = Bunches/Bud \u00d7 Buds/Spur \u00d7 Spurs/Vine \u00d7 Vines/Ha \u00d7 Bunch Weight"
                    else "Yield / Ha = Bunches/Bud \u00d7 Buds/Cane \u00d7 Canes/Vine \u00d7 Vines/Ha \u00d7 Bunch Weight",
                    color = vine.textSecondary, fontSize = 12.sp,
                )

                Button(
                    onClick = {
                        store.saveLatestResult(yieldTonnesPerHa)
                        savedToast = true
                    },
                    enabled = yieldTonnesPerHa > 0,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                ) {
                    Text("Save Result")
                }
            }

            androidx.compose.animation.AnimatedVisibility(
                visible = savedToast,
                modifier = Modifier.align(Alignment.TopCenter).padding(top = 8.dp),
            ) {
                Text(
                    "Saved",
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(20.dp)).background(VineColors.DarkGreen)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
    }

    androidx.compose.runtime.LaunchedEffect(savedToast) {
        if (savedToast) {
            kotlinx.coroutines.delay(1500)
            savedToast = false
        }
    }
}

@Composable
private fun CalcLine(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Text(value, color = vine.textSecondary, fontSize = 15.sp)
    }
}

@Composable
private fun CalcInput(label: String, value: String, onChange: (String) -> Unit) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
        OutlinedTextField(
            value = value,
            onValueChange = { onChange(it.filter { c -> c.isDigit() || c == '.' }) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.width(120.dp),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun YieldListView(
    state: AppUiState,
    varietySummaries: List<VarietyYieldSummary>,
    onBack: (() -> Unit)?,
    onOpen: (HistoricalYieldRecord) -> Unit,
    onOpenVariety: (VarietyYieldSummary) -> Unit,
    onCreate: () -> Unit,
    onCreateEstimate: () -> Unit,
) {
    val vine = LocalVineColors.current
    var createMenu by remember { mutableStateOf(false) }
    val records = remember(state.yieldRecords) {
        state.yieldRecords.sortedWith(compareByDescending<HistoricalYieldRecord> { it.year }.thenByDescending { it.archivedEpochMs ?: 0L })
    }
    val grouped = remember(records) { records.groupBy { it.year }.toSortedMap(compareByDescending { it }) }

    val totalActual = records.sumOf { it.totalActualYieldTonnes ?: 0.0 }
    val totalEstimated = records.sumOf { it.totalYieldTonnes }
    val totalArea = records.sumOf { it.totalAreaHectares }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Yield Reports") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            Box {
                FloatingActionButton(
                    onClick = { createMenu = true },
                    containerColor = VineColors.Primary,
                    contentColor = Color.White,
                ) {
                    Icon(Icons.Filled.Add, contentDescription = "Add yield record")
                }
                DropdownMenu(expanded = createMenu, onDismissRequest = { createMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("New sampling estimate") },
                        leadingIcon = { Icon(Icons.Filled.Agriculture, contentDescription = null, tint = VineColors.LeafGreen) },
                        onClick = { createMenu = false; onCreateEstimate() },
                    )
                    DropdownMenuItem(
                        text = { Text("Record actual yield") },
                        leadingIcon = { Icon(Icons.Filled.Scale, contentDescription = null, tint = VineColors.Info) },
                        onClick = { createMenu = false; onCreate() },
                    )
                }
            }
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            if (records.isEmpty()) {
                Column(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
                    if (!state.isOnline) {
                        EmptyState(
                            icon = Icons.Filled.Scale,
                            title = "No saved yield records",
                            message = "You're offline and there are no yield records saved on this device. Reconnect to load your team's records.",
                        )
                    } else {
                        EmptyState(
                            icon = Icons.Filled.Scale,
                            title = "No yield records yet",
                            message = "Record a block's actual yield at harvest to track tonnes and feed cost-per-tonne reporting.",
                        )
                    }
                    state.yieldError?.let {
                        Text(it, color = VineColors.Destructive, fontSize = 13.sp, modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp))
                    }
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    state.yieldError?.let { err ->
                        item { Text(err, color = VineColors.Destructive, fontSize = 13.sp) }
                    }

                    item {
                        VineyardCard {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                YieldStat("Actual", formatTonnes(totalActual), Icons.Filled.Scale, VineColors.Info, Modifier.weight(1f))
                                YieldStat("Estimated", formatTonnes(totalEstimated), Icons.Filled.Agriculture, VineColors.LeafGreen, Modifier.weight(1f))
                                YieldStat("Area", "${formatHaY(totalArea)} ha", Icons.Filled.SquareFoot, VineColors.Orange, Modifier.weight(1f))
                            }
                        }
                    }

                    grouped.forEach { (year, yearRecords) ->
                        item(key = "hdr-$year") {
                            SectionHeader("$year · ${yearRecords.size} record${if (yearRecords.size == 1) "" else "s"}", onLight = true)
                        }
                        items(yearRecords.size, key = { yearRecords[it].id }) { idx ->
                            YieldRecordCard(record = yearRecords[idx], fmt = state.regionFormatter, onClick = { onOpen(yearRecords[idx]) })
                        }
                    }

                    if (varietySummaries.isNotEmpty()) {
                        item(key = "variety-hdr") { SectionHeader("By Variety", onLight = true) }
                        items(varietySummaries.size, key = { "var-${varietySummaries[it].key}" }) { idx ->
                            VarietyYieldCard(summary = varietySummaries[idx], fmt = state.regionFormatter, onClick = { onOpenVariety(varietySummaries[idx]) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun YieldStat(label: String, value: String, icon: ImageVector, tint: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        Text(value, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary, maxLines = 1)
        Text(label, fontSize = 12.sp, color = vine.textSecondary)
    }
}

@Composable
private fun YieldRecordCard(record: HistoricalYieldRecord, fmt: RegionFormatter, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val blockSummary = when {
        record.blocks.size == 1 -> record.blocks.first().paddockName
        record.blocks.isEmpty() -> "No blocks"
        else -> "${record.blocks.size} blocks"
    }
    val actual = record.totalActualYieldTonnes
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(46.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Scale, contentDescription = null, tint = VineColors.DarkGreen, modifier = Modifier.size(22.dp))
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(record.season.ifBlank { "${record.year}" }, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                    if (actual != null) StatusBadge("Actual", VineColors.Info)
                }
                val parts = buildList {
                    add(blockSummary)
                    if (record.totalAreaHectares > 0) add("${formatHaY(record.totalAreaHectares)} ha")
                    if (record.yieldPerHectare > 0) add(fmt.formatYieldPerArea(record.yieldPerHectare))
                }
                Text(parts.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp, maxLines = 1)
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text("${formatTonnes(actual ?: record.totalYieldTonnes)} t", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                Text(if (actual != null) "actual" else "est.", color = vine.textSecondary, fontSize = 11.sp)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@Composable
private fun YieldDetailView(
    state: AppUiState,
    record: HistoricalYieldRecord,
    onBack: () -> Unit,
    onEdit: () -> Unit,
    onEditEstimate: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    var confirmDelete by remember { mutableStateOf(false) }
    val actual = record.totalActualYieldTonnes
    // An estimate record is a single block authored from sampling inputs.
    val isEstimate = record.blocks.size == 1 && record.blocks.first().averageBunchesPerVine > 0.0

    Box(modifier = Modifier.fillMaxSize().background(vine.appBackground)) {
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
            Row(modifier = Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = vine.textPrimary) }
                Text("Yield Record", color = vine.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                if (isEstimate) {
                    IconButton(onClick = onEditEstimate) { Icon(Icons.Filled.Agriculture, contentDescription = "Edit estimate", tint = VineColors.Orange) }
                }
                IconButton(onClick = onEdit) { Icon(Icons.Filled.Edit, contentDescription = "Edit actuals", tint = VineColors.LeafGreen) }
                IconButton(onClick = { confirmDelete = true }) { Icon(Icons.Filled.Delete, contentDescription = "Delete", tint = VineColors.Destructive) }
            }

            Column(modifier = Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(
                            modifier = Modifier.size(54.dp).clip(RoundedCornerShape(14.dp)).background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center,
                        ) { Icon(Icons.Filled.Scale, contentDescription = null, tint = VineColors.DarkGreen, modifier = Modifier.size(24.dp)) }
                        Column(modifier = Modifier.weight(1f)) {
                            Text(record.season.ifBlank { "Season ${record.year}" }, color = vine.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                            Text("Year ${record.year}", color = vine.textSecondary, fontSize = 13.sp)
                        }
                    }
                }

                VineyardCard {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        YieldStat("Estimated", "${formatTonnes(record.totalYieldTonnes)} t", Icons.Filled.Agriculture, VineColors.LeafGreen, Modifier.weight(1f))
                        YieldStat("Actual", actual?.let { "${formatTonnes(it)} t" } ?: "—", Icons.Filled.Scale, VineColors.Info, Modifier.weight(1f))
                    }
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        YieldStat("Est. ${state.regionFormatter.yieldPerAreaUnit()}", if (record.yieldPerHectare > 0) formatTonnes(state.regionFormatter.perAreaValue(record.yieldPerHectare)) else "—", Icons.Filled.SquareFoot, VineColors.Orange, Modifier.weight(1f))
                        YieldStat("Area", "${formatHaY(record.totalAreaHectares)} ha", Icons.Filled.SquareFoot, VineColors.EarthBrown, Modifier.weight(1f))
                    }
                    record.estimateAccuracyPercent?.let { accuracy ->
                        Spacer(Modifier.height(12.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                                .background(accuracyColor(accuracy).copy(alpha = 0.12f)).padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Icon(Icons.Filled.TrackChanges, contentDescription = null, tint = accuracyColor(accuracy), modifier = Modifier.size(20.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Estimate Accuracy", color = vine.textSecondary, fontSize = 12.sp)
                                Text("how close your estimate was to harvest", color = vine.textSecondary, fontSize = 11.sp)
                            }
                            Text(String.format(Locale.getDefault(), "%.1f%%", accuracy), color = accuracyColor(accuracy), fontSize = 18.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }

                if (record.blocks.isNotEmpty()) {
                    SectionHeader("Block Results", onLight = true)
                    VineyardCard {
                        record.blocks.forEachIndexed { idx, block ->
                            YieldBlockRow(block, state.regionFormatter)
                            if (idx < record.blocks.lastIndex) {
                                Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder).padding(vertical = 0.dp))
                            }
                        }
                    }
                }

                record.notes.takeIf { it.isNotBlank() }?.let {
                    VineyardCard {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(Icons.Filled.Notes, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                            Text(it, color = vine.textPrimary, fontSize = 14.sp)
                        }
                    }
                }

                Text(
                    "Actual yields feed Cost Reports' cost-per-tonne calculations.",
                    color = vine.textSecondary, fontSize = 12.sp,
                )
            }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete yield record?") },
            text = { Text("This removes the archived yield record for everyone. This can't be undone.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; onDelete() }) {
                    Text("Delete", color = VineColors.Destructive)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun YieldBlockRow(block: HistoricalBlockResult, fmt: RegionFormatter) {
    val vine = LocalVineColors.current
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(block.paddockName, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text("${formatTonnes(block.actualYieldTonnes ?: block.yieldTonnes)} t", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
        }
        val parts = buildList {
            if (block.areaHectares > 0) add("${formatHaY(block.areaHectares)} ha")
            val perHa = block.actualYieldPerHectare ?: block.yieldPerHectare.takeIf { it > 0 }
            perHa?.let { add(fmt.formatYieldPerArea(it)) }
            if (block.actualYieldTonnes != null) {
                add("est. ${formatTonnes(block.yieldTonnes)} t")
                block.yieldVarianceTonnes?.let { v ->
                    val sign = if (v >= 0) "+" else ""
                    add("$sign${formatTonnes(v)} t vs est.")
                }
            }
        }
        if (parts.isNotEmpty()) {
            Text(parts.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp)
        }
        block.estimateAccuracyPercent?.let { accuracy ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.Filled.TrackChanges, contentDescription = null, tint = accuracyColor(accuracy), modifier = Modifier.size(13.dp))
                Text(
                    String.format(Locale.getDefault(), "%.0f%% accurate", accuracy),
                    color = accuracyColor(accuracy), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RecordYieldSheet(
    vm: AppViewModel,
    state: AppUiState,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val paddocks = state.paddocks

    var year by remember { mutableIntStateOf(Calendar.getInstance().get(Calendar.YEAR)) }
    var season by remember { mutableStateOf("") }
    var block by remember { mutableStateOf(paddocks.firstOrNull()) }
    var variety by remember { mutableStateOf(block?.primaryVarietyName ?: "") }
    var tonnesText by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }
    var blockMenu by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    val tonnes = tonnesText.trim().toDoubleOrNull()
    val canSave = block != null && tonnes != null && tonnes >= 0 && !saving

    fun save() {
        val chosen = block ?: return
        val t = tonnes ?: return
        if (saving) return
        saving = true
        vm.createYieldRecord(
            YieldRepository.CreateInput(
                year = year,
                season = season.trim(),
                paddockId = chosen.id,
                paddockName = chosen.name,
                areaHectares = chosen.areaHectares,
                totalVines = chosen.effectiveVineCount,
                variety = variety.trim().ifBlank { null },
                actualYieldTonnes = t,
                notes = notes.trim().ifBlank { null },
            ),
        ) { ok -> saving = false; if (ok) onSaved() }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Record actual yield", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            // Season / year.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Year", color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                IconButton(onClick = { if (year > 2000) year -= 1 }) { Text("–", fontSize = 22.sp, color = VineColors.LeafGreen) }
                Text("$year", color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                IconButton(onClick = { if (year < 2100) year += 1 }) { Text("+", fontSize = 20.sp, color = VineColors.LeafGreen) }
            }

            OutlinedTextField(
                value = season,
                onValueChange = { season = it },
                label = { Text("Season (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            // Block picker.
            if (paddocks.isEmpty()) {
                Text("No blocks available. Add a block first.", color = vine.textSecondary, fontSize = 13.sp)
            } else {
                ExposedDropdownMenuBox(expanded = blockMenu, onExpandedChange = { blockMenu = it }) {
                    OutlinedTextField(
                        value = block?.name ?: "Select a block",
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Block / paddock") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = blockMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = blockMenu, onDismissRequest = { blockMenu = false }) {
                        paddocks.forEach { opt ->
                            DropdownMenuItem(
                                text = { Text(opt.name) },
                                onClick = {
                                    block = opt
                                    if (variety.isBlank()) variety = opt.primaryVarietyName ?: ""
                                    blockMenu = false
                                },
                            )
                        }
                    }
                }
            }

            block?.takeIf { it.areaHectares > 0 }?.let {
                Text("Area: ${formatHaY(it.areaHectares)} ha", color = vine.textSecondary, fontSize = 12.sp)
            }

            OutlinedTextField(
                value = variety,
                onValueChange = { variety = it },
                label = { Text("Variety (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            OutlinedTextField(
                value = tonnesText,
                onValueChange = { tonnesText = it.filter { c -> c.isDigit() || c == '.' } },
                label = { Text("Actual yield (tonnes)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            if (tonnes != null && (block?.areaHectares ?: 0.0) > 0) {
                Text(state.regionFormatter.formatYieldPerArea(tonnes / block!!.areaHectares), color = vine.textSecondary, fontSize = 12.sp)
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth().height(90.dp),
            )

            state.yieldError?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }

            Button(
                onClick = { save() },
                enabled = canSave,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text("Save yield record")
            }
        }
    }
}

/**
 * Sampling-based estimate authoring. Captures the sampling snapshot (avg
 * bunches/vine, bunch weight, vines, samples, crop viability) for a single
 * block, previews the computed estimated tonnes / t-ha live, and persists into
 * `historical_yield_records` via the iOS-compatible `block_results` contract.
 * When [existing] is non-null the sheet edits that estimate in place, leaving
 * any recorded actual untouched.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EstimateYieldSheet(
    vm: AppViewModel,
    state: AppUiState,
    existing: HistoricalYieldRecord?,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val paddocks = state.paddocks
    val existingBlock = existing?.blocks?.firstOrNull()

    var year by remember { mutableIntStateOf(existing?.year ?: Calendar.getInstance().get(Calendar.YEAR)) }
    var season by remember { mutableStateOf(existing?.season ?: "") }
    var block by remember {
        mutableStateOf(
            existingBlock?.let { eb -> paddocks.firstOrNull { it.id == eb.paddockId } } ?: paddocks.firstOrNull(),
        )
    }
    var variety by remember {
        mutableStateOf(
            existingBlock?.paddockName?.substringAfter(" \u2014 ", "")?.takeIf { it.isNotBlank() }
                ?: block?.primaryVarietyName ?: "",
        )
    }
    var bunchesText by remember { mutableStateOf(existingBlock?.averageBunchesPerVine?.takeIf { it > 0 }?.let { formatPlain(it) } ?: "") }
    var bunchWeightText by remember { mutableStateOf(existingBlock?.averageBunchWeightGrams?.takeIf { it > 0 }?.let { formatPlain(it) } ?: "120") }
    var vinesText by remember { mutableStateOf((existingBlock?.totalVines?.takeIf { it > 0 } ?: block?.effectiveVineCount ?: 0).toString()) }
    var samplesText by remember { mutableStateOf(existingBlock?.samplesRecorded?.takeIf { it > 0 }?.toString() ?: "") }
    var viabilityText by remember { mutableStateOf(existingBlock?.damageFactor?.let { formatPlain(it * 100.0) } ?: "100") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var blockMenu by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    val bunches = bunchesText.trim().toDoubleOrNull()
    val bunchWeight = bunchWeightText.trim().toDoubleOrNull()
    val vines = vinesText.trim().toIntOrNull()
    val viability = viabilityText.trim().toDoubleOrNull()
    val damageFactor = (viability ?: 100.0).coerceIn(0.0, 100.0) / 100.0
    val area = block?.areaHectares ?: 0.0

    val estimatedTonnes: Double? = if (bunches != null && bunchWeight != null && vines != null && vines >= 0) {
        (vines.toDouble() * bunches) * (bunchWeight / 1000.0) * damageFactor / 1000.0
    } else null
    val perHectare: Double? = estimatedTonnes?.let { if (area > 0) it / area else null }

    val canSave = block != null && bunches != null && bunches >= 0 &&
        bunchWeight != null && bunchWeight >= 0 && vines != null && vines >= 0 && !saving

    fun save() {
        val chosen = block ?: return
        if (!canSave) return
        saving = true
        val input = YieldRepository.EstimateInput(
            year = year,
            season = season.trim(),
            paddockId = chosen.id,
            paddockName = chosen.name,
            areaHectares = chosen.areaHectares,
            totalVines = vines ?: chosen.effectiveVineCount,
            averageBunchesPerVine = bunches ?: 0.0,
            averageBunchWeightGrams = bunchWeight ?: 0.0,
            damageFactor = damageFactor,
            samplesRecorded = samplesText.trim().toIntOrNull() ?: 0,
            variety = variety.trim().ifBlank { null },
            notes = notes.trim().ifBlank { null },
        )
        val done: (Boolean) -> Unit = { ok -> saving = false; if (ok) onSaved() }
        if (existing != null) vm.updateYieldEstimate(existing, input, done)
        else vm.createYieldEstimate(input, done)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(if (existing != null) "Edit sampling estimate" else "New sampling estimate", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Year", color = vine.textPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
                IconButton(onClick = { if (year > 2000) year -= 1 }) { Text("\u2013", fontSize = 22.sp, color = VineColors.LeafGreen) }
                Text("$year", color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                IconButton(onClick = { if (year < 2100) year += 1 }) { Text("+", fontSize = 20.sp, color = VineColors.LeafGreen) }
            }

            OutlinedTextField(
                value = season,
                onValueChange = { season = it },
                label = { Text("Season (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            if (paddocks.isEmpty()) {
                Text("No blocks available. Add a block first.", color = vine.textSecondary, fontSize = 13.sp)
            } else {
                ExposedDropdownMenuBox(expanded = blockMenu, onExpandedChange = { blockMenu = it }) {
                    OutlinedTextField(
                        value = block?.name ?: "Select a block",
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Block / paddock") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = blockMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = blockMenu, onDismissRequest = { blockMenu = false }) {
                        paddocks.forEach { opt ->
                            DropdownMenuItem(
                                text = { Text(opt.name) },
                                onClick = {
                                    block = opt
                                    if (variety.isBlank()) variety = opt.primaryVarietyName ?: ""
                                    // Re-seed vine count from the newly chosen block when untouched/empty.
                                    if (vinesText.isBlank() || vinesText.toIntOrNull() == 0) vinesText = opt.effectiveVineCount.toString()
                                    blockMenu = false
                                },
                            )
                        }
                    }
                }
            }

            block?.takeIf { it.areaHectares > 0 }?.let {
                Text("Area: ${formatHaY(it.areaHectares)} ha", color = vine.textSecondary, fontSize = 12.sp)
            }

            OutlinedTextField(
                value = variety,
                onValueChange = { variety = it },
                label = { Text("Variety (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = bunchesText,
                    onValueChange = { bunchesText = it.filter { c -> c.isDigit() || c == '.' } },
                    label = { Text("Avg bunches/vine") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = bunchWeightText,
                    onValueChange = { bunchWeightText = it.filter { c -> c.isDigit() || c == '.' } },
                    label = { Text("Bunch wt (g)") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = vinesText,
                    onValueChange = { vinesText = it.filter { c -> c.isDigit() } },
                    label = { Text("Total vines") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = viabilityText,
                    onValueChange = { viabilityText = it.filter { c -> c.isDigit() || c == '.' } },
                    label = { Text("Viable %") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }

            OutlinedTextField(
                value = samplesText,
                onValueChange = { samplesText = it.filter { c -> c.isDigit() } },
                label = { Text("Sample sites recorded (optional)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
            )

            // Live estimate preview.
            VineyardCard {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    YieldStat("Estimated", estimatedTonnes?.let { "${formatTonnes(it)} t" } ?: "\u2014", Icons.Filled.Agriculture, VineColors.LeafGreen, Modifier.weight(1f))
                    YieldStat("Est. ${state.regionFormatter.yieldPerAreaUnit()}", perHectare?.let { formatTonnes(state.regionFormatter.perAreaValue(it)) } ?: "\u2014", Icons.Filled.SquareFoot, VineColors.Orange, Modifier.weight(1f))
                }
            }
            Text(
                "Estimate = total vines \u00d7 avg bunches/vine \u00d7 bunch weight \u00d7 viable %. Record the actual yield later from the record.",
                color = vine.textSecondary, fontSize = 11.sp,
            )

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth().height(90.dp),
            )

            state.yieldError?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }

            Button(
                onClick = { save() },
                enabled = canSave,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (existing != null) "Save estimate" else "Create estimate")
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditYieldActualsSheet(
    vm: AppViewModel,
    record: HistoricalYieldRecord,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    // Per-block actual yield text, seeded from the stored actuals.
    val actualsText = remember(record.id) {
        mutableStateMapOf<String, String>().apply {
            record.blocks.forEach { b -> put(b.id, b.actualYieldTonnes?.let { formatPlain(it) } ?: "") }
        }
    }
    var notes by remember(record.id) { mutableStateOf(record.notes) }
    var saving by remember { mutableStateOf(false) }

    fun save() {
        if (saving) return
        saving = true
        val map: Map<String, Double?> = record.blocks.associate { b ->
            b.id to actualsText[b.id]?.trim()?.takeIf { it.isNotBlank() }?.toDoubleOrNull()
        }
        vm.updateYieldActuals(record, map, notes) { ok -> saving = false; if (ok) onSaved() }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Edit actual yields", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(record.season.ifBlank { "Season ${record.year}" }, fontSize = 14.sp, color = vine.textSecondary)

            record.blocks.forEach { block ->
                val parsed = actualsText[block.id]?.trim()?.takeIf { it.isNotBlank() }?.toDoubleOrNull()
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(block.paddockName, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    OutlinedTextField(
                        value = actualsText[block.id] ?: "",
                        onValueChange = { actualsText[block.id] = it.filter { c -> c.isDigit() || c == '.' } },
                        label = { Text("Actual tonnes") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (parsed != null) {
                        val variance = parsed - block.yieldTonnes
                        val vSign = if (variance >= 0) "+" else ""
                        val vColor = if (variance >= 0) VineColors.LeafGreen else VineColors.Destructive
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Est. ${formatTonnes(block.yieldTonnes)} t", color = vine.textSecondary, fontSize = 11.sp)
                            Text("$vSign${formatTonnes(variance)} t", color = vColor, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                            if (parsed > 0) {
                                val accuracy = ((1 - kotlin.math.abs(parsed - block.yieldTonnes) / parsed) * 100).coerceAtLeast(0.0)
                                Text(String.format(Locale.getDefault(), "%.0f%% accurate", accuracy), color = accuracyColor(accuracy), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    } else {
                        Text("Estimated ${formatTonnes(block.yieldTonnes)} t · leave blank to clear", color = vine.textSecondary, fontSize = 11.sp)
                    }
                }
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth().height(90.dp),
            )

            Button(
                onClick = { save() },
                enabled = !saving,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text("Save changes")
            }
        }
    }
}

/**
 * Aggregated yield for a single grape variety across every loaded yield record.
 * Derived (read-only) by attributing each block result's tonnes/area to the
 * variety/varieties currently allocated on the matching paddock. Mixed blocks
 * are split proportionally by allocation percent; blocks whose paddock or
 * allocation can't be resolved fall under an "Unknown variety" bucket.
 */
data class VarietyYieldSummary(
    val key: String,
    val displayName: String,
    val estimatedTonnes: Double,
    val actualTonnes: Double?,
    val areaHectares: Double,
    val contributions: List<VarietyYieldContribution>,
) {
    /** Prefer actual t/ha when actuals exist, otherwise estimated. */
    val tonnesPerHectare: Double?
        get() {
            if (areaHectares <= 0) return null
            val tonnes = actualTonnes ?: estimatedTonnes
            return tonnes / areaHectares
        }
}

/** One block-in-a-season slice contributing to a [VarietyYieldSummary]. */
data class VarietyYieldContribution(
    val recordId: String,
    val seasonLabel: String,
    val blockName: String,
    val sharePercent: Double,
    val estimatedTonnes: Double,
    val actualTonnes: Double?,
    val areaHectares: Double,
)

private const val UNKNOWN_VARIETY_KEY = "__unknown__"

/**
 * Build vineyard-wide per-variety yield totals from archived records. Matches
 * each block result back to its current paddock allocations (variety-key-first
 * is unnecessary here since block results store no variety; we resolve via
 * paddockId), splitting mixed-variety blocks by allocation percent. Prefers
 * actual tonnes where recorded, otherwise estimated. Sorted by the larger of
 * actual/estimated tonnes descending, with "Unknown variety" last.
 */
fun computeVarietyYieldSummaries(
    records: List<HistoricalYieldRecord>,
    paddocks: List<Paddock>,
): List<VarietyYieldSummary> {
    if (records.isEmpty()) return emptyList()
    val paddockById = paddocks.associateBy { it.id }

    data class Acc(
        var displayName: String,
        var estimated: Double = 0.0,
        var actual: Double = 0.0,
        var hasActual: Boolean = false,
        var area: Double = 0.0,
        val contributions: MutableList<VarietyYieldContribution> = mutableListOf(),
    )

    val acc = LinkedHashMap<String, Acc>()

    fun bucket(key: String, name: String): Acc = acc.getOrPut(key) { Acc(displayName = name) }

    records.forEach { record ->
        val seasonLabel = record.season.ifBlank { "Season ${record.year}" }
        record.blocks.forEach { block ->
            val paddock = paddockById[block.paddockId]
            val allocations = paddock?.varietyAllocations.orEmpty()
                .filter { !it.displayName.isNullOrBlank() }

            // Build (key, displayName, share) splits for this block.
            val splits: List<Triple<String, String, Double>> = if (allocations.isEmpty()) {
                listOf(Triple(UNKNOWN_VARIETY_KEY, "Unknown variety", 1.0))
            } else {
                val totalPct = allocations.sumOf { it.displayPercent ?: 0.0 }
                allocations.map { a ->
                    val name = a.displayName!!
                    val key = a.varietyKey?.takeIf { it.isNotBlank() }
                        ?: "name:${canonicalVarietyName(name)}"
                    val share = if (totalPct > 0) (a.displayPercent ?: 0.0) / totalPct
                    else 1.0 / allocations.size
                    Triple(key, name, share)
                }
            }

            splits.forEach { (key, name, share) ->
                if (share <= 0) return@forEach
                val b = bucket(key, name)
                val est = block.yieldTonnes * share
                val area = block.areaHectares * share
                b.estimated += est
                b.area += area
                val actual = block.actualYieldTonnes?.let { it * share }
                if (actual != null) {
                    b.actual += actual
                    b.hasActual = true
                }
                b.contributions.add(
                    VarietyYieldContribution(
                        recordId = record.id,
                        seasonLabel = seasonLabel,
                        blockName = block.paddockName,
                        sharePercent = share * 100.0,
                        estimatedTonnes = est,
                        actualTonnes = actual,
                        areaHectares = area,
                    ),
                )
            }
        }
    }

    return acc.entries
        .map { (key, a) ->
            VarietyYieldSummary(
                key = key,
                displayName = a.displayName,
                estimatedTonnes = a.estimated,
                actualTonnes = if (a.hasActual) a.actual else null,
                areaHectares = a.area,
                contributions = a.contributions.sortedWith(
                    compareByDescending<VarietyYieldContribution> { it.actualTonnes ?: it.estimatedTonnes },
                ),
            )
        }
        .sortedWith(
            compareBy<VarietyYieldSummary> { it.key == UNKNOWN_VARIETY_KEY }
                .thenByDescending { it.actualTonnes ?: it.estimatedTonnes },
        )
}

@Composable
private fun VarietyYieldCard(summary: VarietyYieldSummary, fmt: RegionFormatter, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val isUnknown = summary.key == UNKNOWN_VARIETY_KEY
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(46.dp).clip(RoundedCornerShape(12.dp))
                    .background((if (isUnknown) vine.textSecondary else VineColors.LeafGreen).copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Spa, contentDescription = null, tint = if (isUnknown) vine.textSecondary else VineColors.DarkGreen, modifier = Modifier.size(22.dp))
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(summary.displayName, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                val parts = buildList {
                    if (summary.areaHectares > 0) add("${formatHaY(summary.areaHectares)} ha")
                    summary.tonnesPerHectare?.let { add(fmt.formatYieldPerArea(it)) }
                    val blocks = summary.contributions.map { it.blockName }.distinct().size
                    add("$blocks block${if (blocks == 1) "" else "s"}")
                }
                Text(parts.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp, maxLines = 1)
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                val actual = summary.actualTonnes
                Text("${formatTonnes(actual ?: summary.estimatedTonnes)} t", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                Text(if (actual != null) "actual" else "est.", color = vine.textSecondary, fontSize = 11.sp)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@Composable
private fun VarietyYieldDetailView(summary: VarietyYieldSummary, fmt: RegionFormatter, onBack: () -> Unit) {
    val vine = LocalVineColors.current
    Box(modifier = Modifier.fillMaxSize().background(vine.appBackground)) {
        Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
            Row(modifier = Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = vine.textPrimary) }
                Text("Variety Yield", color = vine.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            }

            Column(modifier = Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(
                            modifier = Modifier.size(54.dp).clip(RoundedCornerShape(14.dp)).background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center,
                        ) { Icon(Icons.Filled.Spa, contentDescription = null, tint = VineColors.DarkGreen, modifier = Modifier.size(24.dp)) }
                        Column(modifier = Modifier.weight(1f)) {
                            Text(summary.displayName, color = vine.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                            val blocks = summary.contributions.map { it.blockName }.distinct().size
                            Text("$blocks block${if (blocks == 1) "" else "s"} · ${summary.contributions.map { it.recordId }.distinct().size} record${if (summary.contributions.map { it.recordId }.distinct().size == 1) "" else "s"}", color = vine.textSecondary, fontSize = 13.sp)
                        }
                    }
                }

                VineyardCard {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        YieldStat("Estimated", "${formatTonnes(summary.estimatedTonnes)} t", Icons.Filled.Agriculture, VineColors.LeafGreen, Modifier.weight(1f))
                        YieldStat("Actual", summary.actualTonnes?.let { "${formatTonnes(it)} t" } ?: "—", Icons.Filled.Scale, VineColors.Info, Modifier.weight(1f))
                    }
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        YieldStat(fmt.yieldPerAreaUnit(), summary.tonnesPerHectare?.let { formatTonnes(fmt.perAreaValue(it)) } ?: "—", Icons.Filled.SquareFoot, VineColors.Orange, Modifier.weight(1f))
                        YieldStat("Area", "${formatHaY(summary.areaHectares)} ha", Icons.Filled.SquareFoot, VineColors.EarthBrown, Modifier.weight(1f))
                    }
                }

                SectionHeader("Contributing Blocks", onLight = true)
                VineyardCard {
                    summary.contributions.forEachIndexed { idx, c ->
                        Column(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(c.blockName, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                                Text("${formatTonnes(c.actualTonnes ?: c.estimatedTonnes)} t", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                            }
                            val parts = buildList {
                                add(c.seasonLabel)
                                if (c.sharePercent < 99.5) add("${c.sharePercent.toInt()}% of block")
                                if (c.areaHectares > 0) add("${formatHaY(c.areaHectares)} ha")
                                if (c.actualTonnes != null) add("est. ${formatTonnes(c.estimatedTonnes)} t")
                            }
                            Text(parts.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp)
                        }
                        if (idx < summary.contributions.lastIndex) {
                            Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                        }
                    }
                }

                Text(
                    "Variety totals are derived from each block's current variety allocation. Mixed-variety blocks are split by allocation share.",
                    color = vine.textSecondary, fontSize = 12.sp,
                )
            }
        }
    }
}

private fun formatTonnes(value: Double): String =
    String.format(Locale.getDefault(), "%.2f", value)

/** Color grading for estimate-accuracy %, mirroring iOS (≥90 green, ≥75 orange, else red). */
private fun accuracyColor(percent: Double): Color = when {
    percent >= 90 -> VineColors.LeafGreen
    percent >= 75 -> VineColors.Orange
    else -> VineColors.Destructive
}

private fun formatPlain(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString()
    else String.format(Locale.getDefault(), "%.2f", value)

private fun formatHaY(value: Double): String =
    if (value >= 10) value.toInt().toString() else String.format(Locale.getDefault(), "%.1f", value)

@Suppress("unused")
private fun formatYieldDate(epochMs: Long?): String? {
    epochMs ?: return null
    return SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(epochMs))
}
