package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.PruningStore
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PruningBlockMetrics
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningCalculator
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningMethods
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.PruningSeasonIds
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.PruningStatus
import com.rork.vinetrack.data.model.builtInWorkTaskTypes
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * Pruning Tracker (in development — System Admin only). Mirrors the iOS
 * `PruningTrackerView`: vineyard dashboard, per-block row-quarter progress,
 * rapid Record Pruning entry (with an optional linked, completed Work Task
 * created in the same flow), rolling rates and projected completion.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PruningTrackerScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val vineyardId = state.selectedVineyardId

    var setups by remember(vineyardId) {
        mutableStateOf(vineyardId?.let { vm.pruningSetups(it) } ?: emptyList())
    }
    var entries by remember(vineyardId) {
        mutableStateOf(vineyardId?.let { vm.pruningEntries(it) } ?: emptyList())
    }
    var selectedPaddockId by rememberSaveable { mutableStateOf<String?>(null) }
    var blockSort by rememberSaveable { mutableStateOf("alphabetical") }

    // Initial fetch + reconcile when the screen opens or the vineyard changes;
    // shows the local cache instantly and merges the server state on top.
    LaunchedEffect(vineyardId, state.isOnline) {
        val id = vineyardId ?: return@LaunchedEffect
        val (mergedSetups, mergedEntries) = vm.refreshPruning(id)
        setups = mergedSetups
        entries = mergedEntries
    }

    val paddocks = remember(state.paddocks) { state.paddocks.sortedBy { it.name.lowercase() } }
    // Block list order — by first actual row number (blocks without rows sink
    // to the bottom, ties fall back to the name) or alphabetical.
    val sortedPaddocks = remember(paddocks, setups, blockSort) {
        if (blockSort == "rowNumber") {
            paddocks.sortedWith(
                compareBy(
                    { paddock ->
                        val setup = setups.firstOrNull { it.paddockId == paddock.id }
                        PruningCalculator.rowRefs(paddock, setup).minOfOrNull { it.number } ?: Int.MAX_VALUE
                    },
                    { it.name.lowercase() },
                )
            )
        } else {
            paddocks
        }
    }
    val selectedPaddock = paddocks.firstOrNull { it.id == selectedPaddockId }

    if (selectedPaddock != null && vineyardId != null) {
        BackHandler { selectedPaddockId = null }
        PruningBlockDetail(
            paddock = selectedPaddock,
            vineyardId = vineyardId,
            setup = setups.firstOrNull { it.paddockId == selectedPaddock.id },
            blockEntries = entries.filter { it.paddockId == selectedPaddock.id }.sortedByDescending { it.date },
            onBack = { selectedPaddockId = null },
            onUpsertSetup = { setups = vm.upsertPruningSetup(vineyardId, it) },
            onAddEntry = { entry, taskDraft ->
                // Ensure the season row exists before the entry references it —
                // recording work on an unconfigured block auto-creates the season.
                var setup = setups.firstOrNull { it.paddockId == entry.paddockId }
                if (setup == null) {
                    setup = PruningBlockSetup(
                        id = PruningSeasonIds.make(vineyardId, entry.paddockId, PruningSeasonIds.currentSeasonYear()),
                        vineyardId = vineyardId,
                        paddockId = entry.paddockId,
                    )
                    setups = vm.upsertPruningSetup(vineyardId, setup)
                }
                val metrics = PruningCalculator.metrics(
                    paddock = selectedPaddock,
                    setup = setup,
                    entries = entries.filter { it.paddockId == entry.paddockId },
                )
                var linked = entry.copy(
                    seasonId = setup.id,
                    estimatedVines = PruningCalculator.vines(entry.segments, metrics.rows),
                )
                // Optionally turn the same submission into ONE completed Work
                // Task through the existing shared work-task flow. The id is
                // client-generated, so offline replay and retries can never
                // create a duplicate task for this entry.
                if (taskDraft != null) {
                    val personHours = taskDraft.labour.sumOf { it.totalHours }
                    val taskId = vm.createWorkTask(
                        taskType = taskDraft.taskType,
                        paddockIds = listOf(entry.paddockId),
                        date = entry.date,
                        durationHours = if (personHours > 0) personHours else entry.labourHours ?: 0.0,
                        notes = taskDraft.notes,
                        markCompleted = true,
                    ) { }
                    if (taskId != null) {
                        linked = linked.copy(workTaskId = taskId)
                        // One canonical work_task_labour_lines row per worker/crew
                        // — through the existing shared labour path (optimistic +
                        // offline queue with a stable client id and a parent-create
                        // gate), so retries and offline replays can never duplicate
                        // the task or its lines.
                        taskDraft.labour.forEach { line ->
                            vm.saveLabourLine(
                                lineId = null,
                                taskId = taskId,
                                workDate = entry.date,
                                operatorCategoryId = line.operatorCategoryId,
                                workerType = line.workerType,
                                workerCount = line.workerCount,
                                hoursPerWorker = line.hoursPerWorker,
                                hourlyRate = line.hourlyRate,
                                notes = null,
                            ) { }
                        }
                    }
                }
                entries = vm.recordPruningEntry(vineyardId, linked)
            },
            onDeleteEntry = { entries = vm.deletePruningEntry(vineyardId, it) },
            onDeleteWorkTask = { vm.deleteWorkTask(it) { } },
            operatorCategories = state.operatorCategories,
            modifier = modifier,
        )
        return
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Pruning Tracker") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "dev") { PruningDevBanner() }
            item(key = "dashboard") {
                PruningDashboardCard(paddocks = paddocks, setups = setups, entries = entries)
            }
            if (paddocks.isEmpty()) {
                item(key = "empty") {
                    PruningCard {
                        Text(
                            "No blocks yet — add blocks in Vineyard Setup to start tracking pruning.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.padding(16.dp),
                        )
                    }
                }
            } else {
                item(key = "block-sort") {
                    BlockSortHeader(sort = blockSort, onSortChange = { blockSort = it })
                }
                items(sortedPaddocks.size, key = { sortedPaddocks[it].id }) { index ->
                    val paddock = sortedPaddocks[index]
                    val setup = setups.firstOrNull { it.paddockId == paddock.id }
                    val blockEntries = entries.filter { it.paddockId == paddock.id }
                    val metrics = PruningCalculator.metrics(paddock, setup, blockEntries)
                    PruningBlockCardItem(
                        paddock = paddock,
                        setup = setup,
                        metrics = metrics,
                        onClick = { selectedPaddockId = paddock.id },
                    )
                }
            }
            item(key = "bottom-space") { Spacer(Modifier.height(24.dp)) }
        }
    }
}

// MARK: - Shared pieces

@Composable
private fun PruningDevBanner() {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Filled.ContentCut, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(13.dp))
        Text(
            "In development — visible to System Admins only",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun PruningCard(content: @Composable ColumnScope.() -> Unit) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground),
        content = content,
    )
}

private fun statusTint(status: PruningStatus): Color = when (status) {
    PruningStatus.NotStarted -> Color(0xFF8E8E93)
    PruningStatus.Ahead -> VineColors.Success
    PruningStatus.OnTrack -> VineColors.Primary
    PruningStatus.AtRisk -> VineColors.Warning
    PruningStatus.Behind -> VineColors.Destructive
    PruningStatus.Complete -> VineColors.LeafGreen
}

@Composable
private fun PruningStatusChipView(status: PruningStatus) {
    val tint = statusTint(status)
    Text(
        status.label,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        color = tint,
        modifier = Modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

/** Progress bar with an optional "time elapsed" marker. */
@Composable
private fun PruningProgressBarView(fraction: Double, elapsedFraction: Double?, tint: Color) {
    val vine = LocalVineColors.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(CircleShape)
            .background(vine.cardBorder.copy(alpha = 0.6f)),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(fraction.coerceIn(0.0, 1.0).toFloat())
                .height(8.dp)
                .clip(CircleShape)
                .background(tint),
        )
        if (elapsedFraction != null) {
            Row(modifier = Modifier.fillMaxWidth()) {
                Spacer(Modifier.weight(elapsedFraction.coerceIn(0.01, 0.99).toFloat()))
                Box(
                    modifier = Modifier
                        .width(2.dp)
                        .height(8.dp)
                        .background(vine.textPrimary.copy(alpha = 0.55f)),
                )
                Spacer(Modifier.weight((1.0 - elapsedFraction.coerceIn(0.01, 0.99)).toFloat()))
            }
        }
    }
}

private fun fmt(value: Double, decimals: Int = 2): String {
    if (value % 1.0 == 0.0 && decimals <= 2) return value.toInt().toString()
    return "%.${decimals}f".format(value).trimEnd('0').trimEnd('.')
}

private fun fmtPercent(fraction: Double): String = "${(fraction * 100).toInt()}%"

private val displayDate: DateTimeFormatter = DateTimeFormatter.ofPattern("d MMM")

private fun fmtDate(date: LocalDate?): String = date?.format(displayDate) ?: "—"

// MARK: - Dashboard

@Composable
private fun PruningDashboardCard(
    paddocks: List<Paddock>,
    setups: List<PruningBlockSetup>,
    entries: List<PruningEntry>,
) {
    val vine = LocalVineColors.current

    var completedEq = 0.0
    var totalEq = 0.0
    var vinesPruned = 0
    var vinesTotal = 0
    var blocksComplete = 0
    var blocksAtRisk = 0
    var projected: LocalDate? = null
    val vinesByDay = mutableMapOf<String, Double>()
    var vinesForHours = 0.0
    var hours = 0.0

    for (paddock in paddocks) {
        val setup = setups.firstOrNull { it.paddockId == paddock.id }
        val blockEntries = entries.filter { it.paddockId == paddock.id }
        val metrics = PruningCalculator.metrics(paddock, setup, blockEntries)
        completedEq += metrics.completedRowEquivalents
        totalEq += metrics.totalRowEquivalents
        vinesPruned += metrics.vinesPruned
        vinesTotal += metrics.vinesTotal
        if (metrics.status == PruningStatus.Complete) blocksComplete += 1
        if (metrics.status == PruningStatus.Behind || metrics.status == PruningStatus.AtRisk) blocksAtRisk += 1
        metrics.projectedFinish?.let { finish ->
            projected = projected?.let { if (finish.isAfter(it)) finish else it } ?: finish
        }
        for (entry in blockEntries) {
            val vines = PruningCalculator.vines(entry.segments, metrics.rows).toDouble()
            vinesByDay[entry.date] = (vinesByDay[entry.date] ?: 0.0) + vines
            val entryHours = entry.labourHours
            if (entryHours != null && entryHours > 0) {
                vinesForHours += vines
                hours += entryHours
            }
        }
    }

    val fraction = if (totalEq > 0) (completedEq / totalEq).coerceAtMost(1.0) else 0.0
    val vinesPerDay = if (vinesByDay.isNotEmpty()) vinesByDay.values.sum() / vinesByDay.size else null
    val vinesPerHour = if (hours > 0) vinesForHours / hours else null

    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Vineyard Progress", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Spacer(Modifier.weight(1f))
                Text(
                    fmtPercent(fraction),
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = VineColors.LeafGreen,
                )
            }
            PruningProgressBarView(fraction, null, VineColors.LeafGreen)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                DashStat("${vinesPruned}", "Vines pruned", Modifier.weight(1f))
                DashStat("${maxOf(vinesTotal - vinesPruned, 0)}", "Vines remaining", Modifier.weight(1f))
                DashStat(vinesPerDay?.let { fmt(it, 0) } ?: "—", "Vines / day", Modifier.weight(1f))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                DashStat(vinesPerHour?.let { fmt(it, 0) } ?: "—", "Vines / labour hr", Modifier.weight(1f))
                DashStat("$blocksComplete", "Blocks complete", Modifier.weight(1f))
                DashStat("$blocksAtRisk", "Blocks at risk", Modifier.weight(1f))
            }
            if (projected != null) {
                Text(
                    "Projected vineyard completion: ${fmtDate(projected)}",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun DashStat(value: String, label: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Text(label, fontSize = 11.sp, color = vine.textSecondary, textAlign = TextAlign.Center)
    }
}

// MARK: - Block list header

private val blockSortOptions: List<Pair<String, String>> = listOf(
    "rowNumber" to "Row number",
    "alphabetical" to "Block name",
)

@Composable
private fun BlockSortHeader(sort: String, onSortChange: (String) -> Unit) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Blocks", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        Spacer(Modifier.weight(1f))
        Box {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { expanded = true }
                    .padding(horizontal = 6.dp, vertical = 4.dp),
            ) {
                Icon(
                    Icons.Filled.SwapVert,
                    contentDescription = "Sort blocks",
                    tint = VineColors.Primary,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    blockSortOptions.firstOrNull { it.first == sort }?.second ?: "Block name",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.Primary,
                )
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                blockSortOptions.forEach { (key, label) ->
                    DropdownMenuItem(
                        text = { Text(label) },
                        trailingIcon = {
                            if (key == sort) {
                                Icon(
                                    Icons.Filled.Check,
                                    contentDescription = null,
                                    tint = VineColors.Primary,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        },
                        onClick = {
                            onSortChange(key)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

// MARK: - Block card

/** "Rows 5–28" from the block's ACTUAL row numbers (or the fallback range). */
private fun rowRangeLabel(metrics: PruningBlockMetrics): String? {
    val numbers = metrics.rows.map { it.number }
    val low = numbers.minOrNull() ?: return null
    val high = numbers.maxOrNull() ?: return null
    return if (low == high) "Row $low" else "Rows $low–$high"
}

@Composable
private fun PruningBlockCardItem(
    paddock: Paddock,
    setup: PruningBlockSetup?,
    metrics: PruningBlockMetrics,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground)
            .clickable { onClick() }
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        paddock.name,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                        maxLines = 1,
                    )
                    rowRangeLabel(metrics)?.let {
                        Text(it, fontSize = 12.sp, color = vine.textSecondary, maxLines = 1)
                    }
                }
                paddock.primaryVarietyName?.let {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
            PruningStatusChipView(metrics.status)
        }

        if (metrics.rowCount > 0) {
            PruningProgressBarView(metrics.fractionComplete, metrics.timeElapsedFraction, statusTint(metrics.status))
            Row {
                Text(
                    "${fmt(metrics.completedRowEquivalents)} of ${metrics.rowCount} row equivalents",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    fmtPercent(metrics.fractionComplete),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
            }
        } else {
            Text("Row count needed — open to set up", fontSize = 12.sp, color = VineColors.Warning)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            PruningCalculator.parseDate(setup?.dueDate)?.let {
                Text("Due ${fmtDate(it)}", fontSize = 12.sp, color = vine.textSecondary)
            }
            metrics.projectedFinish?.let {
                Text("Est. ${fmtDate(it)}", fontSize = 12.sp, color = vine.textSecondary)
            }
        }
    }
}

// MARK: - Block detail

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PruningBlockDetail(
    paddock: Paddock,
    vineyardId: String,
    setup: PruningBlockSetup?,
    blockEntries: List<PruningEntry>,
    onBack: () -> Unit,
    onUpsertSetup: (PruningBlockSetup) -> Unit,
    onAddEntry: (PruningEntry, PruningWorkTaskDraft?) -> Unit,
    onDeleteEntry: (String) -> Unit,
    onDeleteWorkTask: (String) -> Unit,
    operatorCategories: List<OperatorCategory>,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val metrics = PruningCalculator.metrics(paddock, setup, blockEntries)
    // The block's ACTUAL rows (configured paddock rows in stored order, or
    // clearly-labelled fallback rows generated from the manual row count).
    val rows = metrics.rows

    var selected by remember(paddock.id) { mutableStateOf(setOf<PruningSegment>()) }
    var showEntrySheet by remember { mutableStateOf(false) }
    var showSetupSheet by remember { mutableStateOf(false) }
    var rangeFromIndex by remember(paddock.id) { mutableStateOf(0) }
    var rangeToIndex by remember(paddock.id) { mutableStateOf(0) }
    var entryPendingReversal by remember { mutableStateOf<PruningEntry?>(null) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(paddock.name) },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    IconButton(onClick = { showSetupSheet = true }) {
                        Icon(Icons.Filled.Settings, contentDescription = "Block pruning setup", tint = vine.textPrimary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        bottomBar = {
            if (selected.isNotEmpty()) {
                Surface(color = vine.cardBackground, shadowElevation = 8.dp) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                "${fmt(selected.size / 4.0)} row equivalents",
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                            )
                            Text(
                                "${selected.size} quarters · ~${PruningCalculator.vines(selected, rows)} vines",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                        Button(
                            onClick = { showEntrySheet = true },
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                        ) {
                            Text("Record Pruning", fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        },
    ) { padding ->
        if (metrics.rowCount == 0) {
            Column(
                modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(Icons.Filled.ContentCut, contentDescription = null, tint = VineColors.Cyan, modifier = Modifier.size(36.dp))
                Text("Set up pruning for this block", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Text(
                    "This block has no mapped rows. Enter a row count, due date and crew to start tracking.",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                    textAlign = TextAlign.Center,
                )
                Button(
                    onClick = { showSetupSheet = true },
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                ) { Text("Set Up Block") }
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item(key = "progress") { DetailProgressCard(metrics, setup) }
                item(key = "rates") { DetailRatesCard(metrics, blockEntries) }
                item(key = "grid-header") {
                    RowGridHeader(
                        rows = rows,
                        selectedCount = selected.size,
                        rangeFromIndex = rangeFromIndex,
                        rangeToIndex = rangeToIndex,
                        onRangeFrom = { rangeFromIndex = it },
                        onRangeTo = { rangeToIndex = it },
                        onSelectRange = {
                            if (rows.isNotEmpty()) {
                                val low = minOf(rangeFromIndex, rangeToIndex).coerceIn(0, rows.lastIndex)
                                val high = maxOf(rangeFromIndex, rangeToIndex).coerceIn(0, rows.lastIndex)
                                val additions = mutableSetOf<PruningSegment>()
                                for (index in low..high) {
                                    for (quarter in 1..4) {
                                        val segment = rows[index].segment(quarter)
                                        if (!metrics.completed.contains(segment)) additions.add(segment)
                                    }
                                }
                                selected = selected + additions
                            }
                        },
                        onClear = { selected = emptySet() },
                    )
                }
                items(rows.size, key = { "row-${rows[it].key}" }) { index ->
                    val row = rows[index]
                    PruningRowLine(
                        row = row,
                        completed = metrics.completed,
                        selected = selected,
                        onToggle = { segment ->
                            selected = if (selected.contains(segment)) selected - segment else selected + segment
                        },
                        onToggleRow = {
                            val remaining = (1..4)
                                .map { row.segment(it) }
                                .filter { !metrics.completed.contains(it) }
                            selected = if (remaining.all { selected.contains(it) }) {
                                selected - remaining.toSet()
                            } else {
                                selected + remaining
                            }
                        },
                    )
                }
                item(key = "history") {
                    DetailHistoryCard(blockEntries) { entry ->
                        if (entry.workTaskId != null) {
                            entryPendingReversal = entry
                        } else {
                            onDeleteEntry(entry.id)
                        }
                    }
                }
                item(key = "bottom-space") { Spacer(Modifier.height(24.dp)) }
            }
        }
    }

    if (showEntrySheet) {
        PruningEntrySheet(
            paddock = paddock,
            vineyardId = vineyardId,
            segments = selected.sortedWith(compareBy({ it.row }, { it.quarter })),
            rows = rows,
            defaultMethod = setup?.method ?: "spur",
            defaultWorker = setup?.crew ?: "",
            operatorCategories = operatorCategories,
            onDismiss = { showEntrySheet = false },
            onSave = { entry, taskDraft ->
                onAddEntry(entry, taskDraft)
                selected = emptySet()
                showEntrySheet = false
            },
        )
    }

    // Reversal prompt for entries with a linked Work Task — the pruning entry
    // is always reversed; the user explicitly decides what happens to the task.
    entryPendingReversal?.let { pending ->
        AlertDialog(
            onDismissRequest = { entryPendingReversal = null },
            title = { Text("Linked Work Task") },
            text = {
                Text("This pruning entry has a linked Work Task. What should happen to the task? Reversing the entry always reopens its row quarters.")
            },
            confirmButton = {
                TextButton(onClick = {
                    pending.workTaskId?.let(onDeleteWorkTask)
                    onDeleteEntry(pending.id)
                    entryPendingReversal = null
                }) { Text("Delete Work Task", color = VineColors.Destructive) }
            },
            dismissButton = {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = { entryPendingReversal = null }) { Text("Cancel") }
                    TextButton(onClick = {
                        onDeleteEntry(pending.id)
                        entryPendingReversal = null
                    }) { Text("Keep Work Task") }
                }
            },
        )
    }

    if (showSetupSheet) {
        PruningSetupSheet(
            paddock = paddock,
            vineyardId = vineyardId,
            existing = setup,
            needsRowCount = paddock.rowCount == 0,
            onDismiss = { showSetupSheet = false },
            onSave = { updated ->
                onUpsertSetup(updated)
                showSetupSheet = false
            },
        )
    }
}

@Composable
private fun DetailProgressCard(metrics: PruningBlockMetrics, setup: PruningBlockSetup?) {
    val vine = LocalVineColors.current
    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Progress", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Spacer(Modifier.weight(1f))
                PruningStatusChipView(metrics.status)
            }
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    fmtPercent(metrics.fractionComplete),
                    fontSize = 32.sp,
                    fontWeight = FontWeight.Bold,
                    color = vine.textPrimary,
                )
                Text(
                    "${fmt(metrics.completedRowEquivalents)} of ${metrics.rowCount} row equivalents",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.padding(bottom = 5.dp),
                )
            }
            PruningProgressBarView(metrics.fractionComplete, metrics.timeElapsedFraction, statusTint(metrics.status))
            metrics.timeElapsedFraction?.let { elapsed ->
                Text(
                    "Work ${fmtPercent(metrics.fractionComplete)} · Time ${fmtPercent(elapsed)}",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
            HorizontalDivider(color = vine.cardBorder)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                DetailStat("Vines pruned", "${metrics.vinesPruned} of ${metrics.vinesTotal}", Modifier.weight(1f))
                DetailStat("Due date", fmtDate(PruningCalculator.parseDate(setup?.dueDate)), Modifier.weight(1f))
                DetailStat("Est. finish", fmtDate(metrics.projectedFinish), Modifier.weight(1f))
            }
            setup?.crew?.takeIf { it.isNotBlank() }?.let {
                Text("Crew: $it", fontSize = 12.sp, color = vine.textSecondary)
            }
        }
    }
}

@Composable
private fun DetailStat(label: String, value: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier) {
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    }
}

@Composable
private fun DetailRatesCard(metrics: PruningBlockMetrics, entries: List<PruningEntry>) {
    val vine = LocalVineColors.current
    val today = PruningCalculator.rowEquivalentsPerDay(entries, 1)
    val last3 = PruningCalculator.rowEquivalentsPerDay(entries, 3)
    val last7 = PruningCalculator.rowEquivalentsPerDay(entries, 7)
    val period = PruningCalculator.rowEquivalentsPerDay(entries, null)
    val rate = metrics.ratePerWorkday

    var vinesForHours = 0.0
    var hours = 0.0
    for (entry in entries) {
        val entryHours = entry.labourHours
        if (entryHours != null && entryHours > 0) {
            vinesForHours += PruningCalculator.vines(entry.segments, metrics.rows).toDouble()
            hours += entryHours
        }
    }
    val vinesPerHour = if (hours > 0) vinesForHours / hours else null

    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Daily Rate", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            if (entries.isEmpty()) {
                Text(
                    "Record your first day of pruning to see rates and the estimated finish date.",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    RateStat(today, "Today", Modifier.weight(1f))
                    RateStat(last3, "3 days", Modifier.weight(1f))
                    RateStat(last7, "7 days", Modifier.weight(1f))
                    RateStat(period, "Period", Modifier.weight(1f))
                }
                Text(
                    "Rows per working day (rolling average). Days without entries — e.g. rain days — don't count against the rate.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
                HorizontalDivider(color = vine.cardBorder)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DashStat(rate?.let { fmt(it * metrics.vinesPerRow, 0) } ?: "—", "Vines / day", Modifier.weight(1f))
                    DashStat(vinesPerHour?.let { fmt(it, 0) } ?: "—", "Vines / labour hr", Modifier.weight(1f))
                    DashStat(rate?.let { "${fmt(it * metrics.averageRowLength, 0)} m" } ?: "—", "Row metres / day", Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun RateStat(value: Double?, label: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value?.let { fmt(it) } ?: "—", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
    }
}

// MARK: - Row grid

@Composable
private fun RowGridHeader(
    rows: List<PruningRowRef>,
    selectedCount: Int,
    rangeFromIndex: Int,
    rangeToIndex: Int,
    onRangeFrom: (Int) -> Unit,
    onRangeTo: (Int) -> Unit,
    onSelectRange: () -> Unit,
    onClear: () -> Unit,
) {
    val vine = LocalVineColors.current
    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Rows", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Spacer(Modifier.weight(1f))
                if (selectedCount > 0) {
                    TextButton(onClick = onClear) {
                        Text("Clear", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                    }
                }
            }
            if (rows.firstOrNull()?.isFallback == true) {
                Text(
                    "Using manually entered row count — this block has no configured rows. Map its rows in Vineyard Setup to track real row numbers.",
                    fontSize = 11.sp,
                    color = VineColors.Warning,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Rows", fontSize = 12.sp, color = vine.textSecondary)
                RowLabelPicker(rangeFromIndex, rows, onRangeFrom)
                Text("to", fontSize = 12.sp, color = vine.textSecondary)
                RowLabelPicker(rangeToIndex, rows, onRangeTo)
                Spacer(Modifier.weight(1f))
                OutlinedButton(onClick = onSelectRange) {
                    Text("Select range", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                GridLegend(VineColors.LeafGreen, "Done")
                GridLegend(VineColors.Primary, "Selected")
                GridLegend(vine.cardBorder, "Remaining")
            }
        }
    }
}

@Composable
private fun RowLabelPicker(valueIndex: Int, rows: List<PruningRowRef>, onChange: (Int) -> Unit) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }
    Box {
        Text(
            rows.getOrNull(valueIndex)?.label ?: "—",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = VineColors.Primary,
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .background(vine.cardBorder.copy(alpha = 0.5f))
                .clickable { expanded = true }
                .padding(horizontal = 12.dp, vertical = 6.dp),
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            rows.forEachIndexed { index, row ->
                DropdownMenuItem(
                    text = { Text(row.label) },
                    onClick = {
                        onChange(index)
                        expanded = false
                    },
                )
            }
        }
    }
}

@Composable
private fun GridLegend(color: Color, label: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(modifier = Modifier.size(12.dp).clip(RoundedCornerShape(3.dp)).background(color))
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
    }
}

@Composable
private fun PruningRowLine(
    row: PruningRowRef,
    completed: Set<PruningSegment>,
    selected: Set<PruningSegment>,
    onToggle: (PruningSegment) -> Unit,
    onToggleRow: () -> Unit,
) {
    val vine = LocalVineColors.current
    val rowDone = (1..4).all { completed.contains(row.segment(it)) || selected.contains(row.segment(it)) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            row.label,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = vine.textSecondary,
            modifier = Modifier.width(30.dp),
            textAlign = TextAlign.End,
        )
        Row(modifier = Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            (1..4).forEach { quarter ->
                val segment = row.segment(quarter)
                val isDone = completed.contains(segment)
                val isSelected = selected.contains(segment)
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(28.dp)
                        .clip(RoundedCornerShape(5.dp))
                        .background(
                            when {
                                isDone -> VineColors.LeafGreen
                                isSelected -> VineColors.Primary
                                else -> vine.cardBorder.copy(alpha = 0.6f)
                            }
                        )
                        .then(if (!isDone) Modifier.clickable { onToggle(segment) } else Modifier),
                    contentAlignment = Alignment.Center,
                ) {
                    if (isDone) {
                        Icon(Icons.Filled.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(12.dp))
                    } else if (isSelected) {
                        Icon(Icons.Filled.ContentCut, contentDescription = null, tint = Color.White, modifier = Modifier.size(11.dp))
                    }
                }
            }
        }
        IconButton(onClick = onToggleRow, modifier = Modifier.size(28.dp)) {
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = "Select all of row ${row.label}",
                tint = if (rowDone) VineColors.LeafGreen else vine.textSecondary.copy(alpha = 0.5f),
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

// MARK: - History

@Composable
private fun DetailHistoryCard(entries: List<PruningEntry>, onDelete: (PruningEntry) -> Unit) {
    val vine = LocalVineColors.current
    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Completed Days", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            if (entries.isEmpty()) {
                Text("No entries yet.", fontSize = 13.sp, color = vine.textSecondary)
            } else {
                entries.forEachIndexed { index, entry ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                fmtDate(PruningCalculator.parseDate(entry.date)),
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                            )
                            val parts = mutableListOf<String>()
                            if (entry.worker.isNotBlank()) parts.add(entry.worker)
                            entry.labourHours?.takeIf { it > 0 }?.let { parts.add("${fmt(it, 1)} h") }
                            parts.add(PruningMethods.label(entry.method))
                            Text(parts.joinToString(" · "), fontSize = 12.sp, color = vine.textSecondary)
                            if (entry.notes.isNotBlank()) {
                                Text(entry.notes, fontSize = 12.sp, color = vine.textSecondary, fontStyle = FontStyle.Italic)
                            }
                            if (entry.workTaskId != null) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Icon(
                                        Icons.Filled.Link,
                                        contentDescription = "Linked Work Task",
                                        tint = VineColors.Primary,
                                        modifier = Modifier.size(12.dp),
                                    )
                                    Text("Work Task", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                                }
                            }
                        }
                        Text(
                            "${fmt(entry.rowEquivalents)} rows",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = vine.textPrimary,
                        )
                        IconButton(onClick = { onDelete(entry) }, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Filled.Delete, contentDescription = "Reverse this pruning entry", tint = VineColors.Destructive, modifier = Modifier.size(16.dp))
                        }
                    }
                    if (index < entries.lastIndex) HorizontalDivider(color = vine.cardBorder)
                }
            }
        }
    }
}

// MARK: - Entry sheet

/** Work Task creation request captured in the Record Pruning sheet — every
 * other task value (date, block, crew, times) is reused from the pruning
 * entry itself so nothing is entered twice. [labour] carries one costing line
 * per worker/crew row (`work_task_labour_lines`). */
private data class PruningWorkTaskDraft(
    val taskType: String,
    val notes: String,
    val labour: List<PruningLabourDraft>,
)

/** One validated Work Task labour line captured in the Record Pruning sheet. */
private data class PruningLabourDraft(
    val operatorCategoryId: String?,
    val workerType: String,
    val workerCount: Int,
    val hoursPerWorker: Double,
    val hourlyRate: Double?,
) {
    /** Person-hours: worker count × hours per worker (DB `total_hours`). */
    val totalHours: Double get() = workerCount * hoursPerWorker
}

/** Editable labour-line row state inside the Record Pruning sheet. */
private data class PruningLabourRow(
    val key: Int,
    val categoryId: String? = null,
    val workerType: String = "",
    val countText: String = "1",
    val hoursText: String = "",
    val rateText: String = "",
) {
    val workerCount: Int get() = (countText.toIntOrNull() ?: 1).coerceAtLeast(1)
    val hoursPerWorker: Double get() = hoursText.replace(',', '.').toDoubleOrNull() ?: 0.0
    val hourlyRate: Double? get() = rateText.replace(',', '.').toDoubleOrNull()
    /** Person-hours: worker count × hours per worker. */
    val totalHours: Double get() = workerCount * hoursPerWorker
    /** Line cost, or null when no rate was specified (shown as "Not specified"). */
    val totalCost: Double? get() = hourlyRate?.let { totalHours * it }
    val isValid: Boolean get() = hoursPerWorker > 0.0
}

/** Compact currency label (e.g. "$42.50") matching the Work Tasks screen. */
private fun fmtCurrency(value: Double): String =
    if (value % 1.0 == 0.0) "$%,d".format(value.toLong()) else "$%,.2f".format(value)

/** Distinct selected row numbers grouped into compact ranges, e.g. "44–46, 50". */
private fun rowRangeSummary(segments: List<PruningSegment>): String {
    val numbers = segments.map { it.row }.distinct().sorted()
    if (numbers.isEmpty()) return "—"
    val parts = mutableListOf<String>()
    var start = numbers.first()
    var previous = start
    for (number in numbers.drop(1)) {
        if (number == previous + 1) {
            previous = number
            continue
        }
        parts.add(if (start == previous) "$start" else "$start–$previous")
        start = number
        previous = number
    }
    parts.add(if (start == previous) "$start" else "$start–$previous")
    return parts.joinToString(", ")
}

/** Work Task notes composed from the pruning record (matches the iOS format). */
private fun composePruningTaskNotes(
    segments: List<PruningSegment>,
    rows: List<PruningRowRef>,
    method: String,
    userNotes: String,
): String {
    val rowEq = fmt(segments.size / 4.0)
    val vines = PruningCalculator.vines(segments, rows)
    var summary = "Source: Pruning Tracker — Rows ${rowRangeSummary(segments)} · ${segments.size} quarters · $rowEq row equivalents · ~$vines vines · ${PruningMethods.label(method)}"
    if (userNotes.isNotBlank()) summary += "\n$userNotes"
    return summary
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PruningEntrySheet(
    paddock: Paddock,
    vineyardId: String,
    segments: List<PruningSegment>,
    rows: List<PruningRowRef>,
    defaultMethod: String,
    defaultWorker: String,
    operatorCategories: List<OperatorCategory>,
    onDismiss: () -> Unit,
    onSave: (PruningEntry, PruningWorkTaskDraft?) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var date by remember { mutableStateOf(LocalDate.now()) }
    var showDatePicker by remember { mutableStateOf(false) }
    var worker by remember { mutableStateOf(defaultWorker) }
    var hoursText by remember { mutableStateOf("") }
    var includeTimes by remember { mutableStateOf(false) }
    var startTime by remember { mutableStateOf("") }
    var finishTime by remember { mutableStateOf("") }
    var method by remember { mutableStateOf(defaultMethod) }
    var notes by remember { mutableStateOf("") }
    var createTask by remember { mutableStateOf(false) }
    var taskType by remember { mutableStateOf("Pruning") }
    // Labour costing lines for the linked Work Task. The first row is seeded
    // from the pruning form's Worker/Crew + Labour hours when the toggle turns
    // on, so nothing is entered twice.
    var labourRows by remember { mutableStateOf(listOf<PruningLabourRow>()) }
    var nextLabourKey by remember { mutableStateOf(1) }

    // Person-hours convention: with labour lines, the pruning entry's labour
    // hours = sum of all line person-hours (2 workers × 8 h = 16 h).
    val labourPersonHours = labourRows.sumOf { it.totalHours }
    val labourTotalCost = labourRows.sumOf { it.totalCost ?: 0.0 }
    val hasRatedLine = labourRows.any { it.hourlyRate != null }
    val labourValid = labourRows.isNotEmpty() && labourRows.all { it.isValid }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.appBackground) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Record Pruning — ${paddock.name}", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "${segments.size} quarters · ${fmt(segments.size / 4.0)} row equivalents · ~${PruningCalculator.vines(segments, rows)} vines",
                fontSize = 13.sp,
                color = vine.textSecondary,
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(vine.cardBackground)
                    .clickable { showDatePicker = true }
                    .padding(horizontal = 12.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Date", fontSize = 14.sp, color = vine.textPrimary)
                Spacer(Modifier.weight(1f))
                Text(fmtDate(date), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
            }

            OutlinedTextField(
                value = worker,
                onValueChange = { worker = it },
                label = { Text("Worker or crew") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            if (createTask) {
                // Labour hours are derived from the Work Task labour lines below.
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(vine.cardBackground)
                        .padding(horizontal = 12.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Labour hours", fontSize = 14.sp, color = vine.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Text("${fmt(labourPersonHours)} h", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                }
            } else {
                OutlinedTextField(
                    value = hoursText,
                    onValueChange = { hoursText = it },
                    label = { Text("Labour hours") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Record start & finish time", fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                Switch(checked = includeTimes, onCheckedChange = { includeTimes = it })
            }
            if (includeTimes) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = startTime,
                        onValueChange = { startTime = it },
                        label = { Text("Start (HH:mm)") },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = finishTime,
                        onValueChange = { finishTime = it },
                        label = { Text("Finish (HH:mm)") },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                    )
                }
            }

            PruningMethodPicker(method) { method = it }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth(),
            )

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Create a Work Task for this pruning work",
                    fontSize = 14.sp,
                    color = vine.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = createTask, onCheckedChange = { on ->
                    createTask = on
                    if (on && labourRows.isEmpty()) {
                        // Seed the first labour line from the pruning form's
                        // Worker/Crew + Labour hours — nothing is re-entered.
                        labourRows = listOf(
                            PruningLabourRow(key = 0, workerType = worker.trim(), hoursText = hoursText.trim())
                        )
                    }
                })
            }
            if (createTask) {
                WorkTaskTypePicker(builtInWorkTaskTypes, taskType) { taskType = it }
                Text(
                    "Title: Pruning — ${paddock.name} · Status: Completed",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textSecondary,
                )

                Text("Labour lines", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                labourRows.forEachIndexed { index, row ->
                    PruningLabourRowEditor(
                        row = row,
                        categories = operatorCategories,
                        canRemove = labourRows.size > 1,
                        onChange = { updated ->
                            labourRows = labourRows.toMutableList().also { it[index] = updated }
                        },
                        onRemove = {
                            labourRows = labourRows.filterNot { it.key == row.key }
                        },
                    )
                }
                TextButton(onClick = {
                    labourRows = labourRows + PruningLabourRow(key = nextLabourKey)
                    nextLabourKey += 1
                }) {
                    Icon(Icons.Filled.Add, contentDescription = null, tint = VineColors.Primary)
                    Text("  Add worker", color = VineColors.Primary, fontWeight = FontWeight.SemiBold)
                }
                if (labourValid) {
                    Text(
                        "Total: ${fmt(labourPersonHours)} h person-hours" +
                            if (hasRatedLine) " · ${fmtCurrency(labourTotalCost)} labour cost" else "",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textSecondary,
                    )
                } else {
                    Text(
                        "Each labour line needs hours greater than zero.",
                        fontSize = 12.sp,
                        color = VineColors.Destructive,
                    )
                }
                Text(
                    "The Work Task reuses this record's date, block, crew, times and notes — nothing is entered twice. It is created as completed with these labour lines and appears in the Work Tasks tool. Rates left blank show as “Not specified”.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            Button(
                onClick = {
                    val entry = PruningEntry(
                        id = UUID.randomUUID().toString(),
                        vineyardId = vineyardId,
                        paddockId = paddock.id,
                        date = date.toString(),
                        segments = segments,
                        worker = worker.trim(),
                        // Person-hours convention: with labour lines, the entry's
                        // labour hours = sum of line person-hours; otherwise the
                        // manually entered value applies as before.
                        labourHours = if (createTask) {
                            labourPersonHours.takeIf { it > 0 }
                        } else {
                            hoursText.replace(',', '.').toDoubleOrNull()
                        },
                        startTime = if (includeTimes) startTime.trim().ifBlank { null } else null,
                        finishTime = if (includeTimes) finishTime.trim().ifBlank { null } else null,
                        method = method,
                        notes = notes.trim(),
                        createdAtMs = System.currentTimeMillis(),
                    )
                    val draft = if (createTask) {
                        PruningWorkTaskDraft(
                            taskType = taskType,
                            notes = composePruningTaskNotes(segments, rows, method, notes.trim()),
                            labour = labourRows.filter { it.isValid }.map { row ->
                                PruningLabourDraft(
                                    operatorCategoryId = row.categoryId,
                                    workerType = row.workerType.trim(),
                                    workerCount = row.workerCount,
                                    hoursPerWorker = row.hoursPerWorker,
                                    hourlyRate = row.hourlyRate,
                                )
                            },
                        )
                    } else {
                        null
                    }
                    onSave(entry, draft)
                },
                enabled = segments.isNotEmpty() && (!createTask || labourValid),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    if (segments.size == 1) "Record 1 quarter" else "Record ${segments.size} quarters",
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }

    if (showDatePicker) {
        val pickerState = rememberDatePickerState(
            initialSelectedDateMillis = date.atStartOfDay(ZoneId.of("UTC")).toInstant().toEpochMilli()
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let {
                        date = Instant.ofEpochMilli(it).atZone(ZoneId.of("UTC")).toLocalDate()
                    }
                    showDatePicker = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { showDatePicker = false }) { Text("Cancel") } },
        ) {
            DatePicker(state = pickerState)
        }
    }
}

/**
 * One editable Work Task labour line: worker/crew name (with an optional
 * worker-type picker that seeds the hourly rate, mirroring the Work Tasks
 * labour sheet), worker count, hours per worker and optional hourly rate.
 */
@Composable
private fun PruningLabourRowEditor(
    row: PruningLabourRow,
    categories: List<OperatorCategory>,
    canRemove: Boolean,
    onChange: (PruningLabourRow) -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    var categoryMenu by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            OutlinedTextField(
                value = row.workerType,
                onValueChange = { onChange(row.copy(workerType = it)) },
                label = { Text("Worker or crew member") },
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
            if (categories.isNotEmpty()) {
                Box {
                    IconButton(onClick = { categoryMenu = true }) {
                        Icon(Icons.Filled.ArrowDropDown, contentDescription = "Choose worker type", tint = VineColors.Primary)
                    }
                    DropdownMenu(expanded = categoryMenu, onDismissRequest = { categoryMenu = false }) {
                        categories.forEach { category ->
                            DropdownMenuItem(
                                text = {
                                    val rate = category.costPerHour
                                    Text(if (rate != null && rate > 0) "${category.displayName} · ${fmtCurrency(rate)}/h" else category.displayName)
                                },
                                onClick = {
                                    // Worker-type default rate seeds an empty rate
                                    // field — same behaviour as the Work Task sheet.
                                    val seededRate = if (row.rateText.isBlank()) {
                                        category.costPerHour?.takeIf { it > 0 }?.let { fmt(it) } ?: row.rateText
                                    } else {
                                        row.rateText
                                    }
                                    onChange(row.copy(categoryId = category.id, workerType = category.displayName, rateText = seededRate))
                                    categoryMenu = false
                                },
                            )
                        }
                    }
                }
            }
            if (canRemove) {
                IconButton(onClick = onRemove) {
                    Icon(Icons.Filled.Delete, contentDescription = "Remove labour line", tint = VineColors.Destructive)
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = row.countText,
                onValueChange = { text -> onChange(row.copy(countText = text.filter { it.isDigit() })) },
                label = { Text("Workers") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
            OutlinedTextField(
                value = row.hoursText,
                onValueChange = { text -> onChange(row.copy(hoursText = text.filter { it.isDigit() || it == '.' || it == ',' })) },
                label = { Text("Hrs / worker") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
            OutlinedTextField(
                value = row.rateText,
                onValueChange = { text -> onChange(row.copy(rateText = text.filter { it.isDigit() || it == '.' || it == ',' })) },
                label = { Text("Rate $/h") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
        }
        Text(
            "${fmt(row.totalHours)} h · " + (row.totalCost?.let { fmtCurrency(it) } ?: "Cost not specified"),
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun WorkTaskTypePicker(options: List<String>, value: String, onChange: (String) -> Unit) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(vine.cardBackground)
                .clickable { expanded = true }
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Work type", fontSize = 14.sp, color = vine.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(value, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option) },
                    onClick = {
                        onChange(option)
                        expanded = false
                    },
                )
            }
        }
    }
}

@Composable
private fun PruningMethodPicker(value: String, onChange: (String) -> Unit) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(vine.cardBackground)
                .clickable { expanded = true }
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Pruning method", fontSize = 14.sp, color = vine.textPrimary)
            Spacer(Modifier.weight(1f))
            Text(PruningMethods.label(value), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            PruningMethods.all.forEach { (key, label) ->
                DropdownMenuItem(
                    text = { Text(label) },
                    onClick = {
                        onChange(key)
                        expanded = false
                    },
                )
            }
        }
    }
}

// MARK: - Setup sheet

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PruningSetupSheet(
    paddock: Paddock,
    vineyardId: String,
    existing: PruningBlockSetup?,
    needsRowCount: Boolean,
    onDismiss: () -> Unit,
    onSave: (PruningBlockSetup) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var startDate by remember { mutableStateOf(PruningCalculator.parseDate(existing?.startDate)) }
    var dueDate by remember { mutableStateOf(PruningCalculator.parseDate(existing?.dueDate)) }
    var pickerTarget by remember { mutableStateOf<String?>(null) }
    var method by remember { mutableStateOf(existing?.method ?: "spur") }
    var crew by remember { mutableStateOf(existing?.crew ?: "") }
    var workingDays by remember { mutableStateOf(existing?.workingDays?.toSet() ?: setOf(1, 2, 3, 4, 5)) }
    var rowCountText by remember { mutableStateOf(existing?.rowCountOverride?.toString() ?: "") }
    var hoursText by remember { mutableStateOf(existing?.estimatedLabourHours?.let { fmt(it, 1) } ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }

    val dayLabels = listOf(1 to "Mon", 2 to "Tue", 3 to "Wed", 4 to "Thu", 5 to "Fri", 6 to "Sat", 7 to "Sun")

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.appBackground) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Pruning Setup", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            if (needsRowCount) {
                OutlinedTextField(
                    value = rowCountText,
                    onValueChange = { rowCountText = it },
                    label = { Text("Number of rows") },
                    supportingText = { Text("This block has no mapped rows — enter the row count manually.") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
            }

            SetupDateRow("Pruning start date", startDate, onPick = { pickerTarget = "start" }, onClear = { startDate = null })
            SetupDateRow("Pruning due date", dueDate, onPick = { pickerTarget = "due" }, onClear = { dueDate = null })

            Text("Working days", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                dayLabels.forEach { (day, label) ->
                    val isOn = workingDays.contains(day)
                    Text(
                        label,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (isOn) Color.White else vine.textPrimary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (isOn) VineColors.Primary else vine.cardBackground)
                            .clickable {
                                workingDays = if (isOn) {
                                    if (workingDays.size > 1) workingDays - day else workingDays
                                } else {
                                    workingDays + day
                                }
                            }
                            .padding(vertical = 8.dp),
                    )
                }
            }
            Text("Used to project the estimated completion date.", fontSize = 11.sp, color = vine.textSecondary)

            OutlinedTextField(
                value = crew,
                onValueChange = { crew = it },
                label = { Text("Assigned crew") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            PruningMethodPicker(method) { method = it }
            OutlinedTextField(
                value = hoursText,
                onValueChange = { hoursText = it },
                label = { Text("Estimated labour hours (optional)") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth(),
            )

            Button(
                onClick = {
                    onSave(
                        PruningBlockSetup(
                            id = existing?.id ?: PruningSeasonIds.make(vineyardId, paddock.id, PruningSeasonIds.currentSeasonYear()),
                            vineyardId = vineyardId,
                            paddockId = paddock.id,
                            seasonYear = existing?.seasonYear ?: PruningSeasonIds.currentSeasonYear(),
                            startDate = startDate?.toString(),
                            dueDate = dueDate?.toString(),
                            method = method,
                            crew = crew.trim(),
                            workingDays = workingDays.sorted(),
                            rowCountOverride = if (needsRowCount) rowCountText.toIntOrNull() else existing?.rowCountOverride,
                            estimatedLabourHours = hoursText.replace(',', '.').toDoubleOrNull(),
                            notes = notes.trim(),
                        )
                    )
                },
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Save", fontWeight = FontWeight.SemiBold)
            }
        }
    }

    if (pickerTarget != null) {
        val initial = (if (pickerTarget == "start") startDate else dueDate) ?: LocalDate.now()
        val pickerState = rememberDatePickerState(
            initialSelectedDateMillis = initial.atStartOfDay(ZoneId.of("UTC")).toInstant().toEpochMilli()
        )
        DatePickerDialog(
            onDismissRequest = { pickerTarget = null },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let {
                        val picked = Instant.ofEpochMilli(it).atZone(ZoneId.of("UTC")).toLocalDate()
                        if (pickerTarget == "start") startDate = picked else dueDate = picked
                    }
                    pickerTarget = null
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickerTarget = null }) { Text("Cancel") } },
        ) {
            DatePicker(state = pickerState)
        }
    }
}

@Composable
private fun SetupDateRow(label: String, value: LocalDate?, onPick: () -> Unit, onClear: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .clickable { onPick() }
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 14.sp, color = vine.textPrimary)
        Spacer(Modifier.weight(1f))
        Text(
            value?.let { fmtDate(it) } ?: "Not set",
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (value != null) VineColors.Primary else vine.textSecondary,
        )
        if (value != null) {
            TextButton(onClick = onClear) {
                Text("Clear", fontSize = 12.sp, color = VineColors.Destructive)
            }
        }
    }
}
