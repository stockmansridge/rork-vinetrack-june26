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
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.SyncProblem
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
import androidx.compose.runtime.rememberCoroutineScope
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
import com.rork.vinetrack.data.VintageResolver
import com.rork.vinetrack.data.model.PruningSeasonIds
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.PruningStatus
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.builtInWorkTaskTypes
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.PendingSyncItem
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID
import kotlin.math.roundToInt

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
    val scope = rememberCoroutineScope()

    // Sync-integrity contract: pruning writes still sitting in the outbox.
    // Progress must never look fully synced while these exist.
    val pruningPendingItems = remember(state.pendingSyncItems) {
        state.pendingSyncItems.filter { it.entityType == "pruning_season" || it.entityType == "pruning_entry" }
    }

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
            onEditEntry = { entry, action ->
                var updated = entry
                when (action) {
                    is PruningEditTaskAction.UpdateLinked -> {
                        val taskId = entry.workTaskId
                        if (taskId != null) {
                            // Person-hours convention: the entry's labour hours =
                            // sum of live labour-line person-hours — entry and
                            // task never disagree.
                            val personHours = action.lines.sumOf { it.workerCount * it.hoursPerWorker }
                            vm.updateWorkTask(
                                taskId = taskId,
                                taskType = action.taskType,
                                paddockIds = listOf(entry.paddockId),
                                date = entry.date,
                                durationHours = personHours,
                                notes = action.notes,
                            ) { }
                            // Labour-line diff: stable ids update the canonical
                            // rows, new lines get repo-minted ids, removed lines
                            // soft-delete — retries can never duplicate.
                            action.lines.forEach { line ->
                                vm.saveLabourLine(
                                    lineId = line.lineId,
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
                            action.removedLineIds.forEach { vm.deleteLabourLine(it) { } }
                            updated = updated.copy(labourHours = personHours.takeIf { it > 0 })
                        }
                    }
                    is PruningEditTaskAction.CreateNew -> {
                        val personHours = action.draft.labour.sumOf { it.totalHours }
                        val taskId = vm.createWorkTask(
                            taskType = action.draft.taskType,
                            paddockIds = listOf(entry.paddockId),
                            date = entry.date,
                            durationHours = if (personHours > 0) personHours else entry.labourHours ?: 0.0,
                            notes = action.draft.notes,
                            markCompleted = true,
                        ) { }
                        if (taskId != null) {
                            updated = updated.copy(
                                workTaskId = taskId,
                                labourHours = personHours.takeIf { it > 0 } ?: entry.labourHours,
                            )
                            action.draft.labour.forEach { line ->
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
                    is PruningEditTaskAction.Unlink -> {
                        // Explicit user choice from the unlink dialog — never silent.
                        if (action.deleteTask) entry.workTaskId?.let { id -> vm.deleteWorkTask(id) { } }
                        updated = updated.copy(workTaskId = null)
                    }
                    PruningEditTaskAction.None -> Unit
                }
                entries = vm.editPruningEntry(vineyardId, updated)
            },
            onDeleteEntry = { entries = vm.deletePruningEntry(vineyardId, it) },
            onDeleteWorkTask = { vm.deleteWorkTask(it) { } },
            operatorCategories = state.operatorCategories,
            workTasks = state.workTasks,
            taskLabourLines = state.taskLabourLines,
            taskLinesTaskId = state.taskLinesTaskId,
            onLoadTaskLines = { vm.loadTaskLines(it) },
            seasonStartMonth = state.seasonStartMonth,
            seasonStartDay = state.seasonStartDay,
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
            if (pruningPendingItems.isNotEmpty()) {
                item(key = "pending-sync-warning") {
                    PruningPendingSyncCard(
                        items = pruningPendingItems,
                        canRetry = state.isOnline,
                        isRetrying = state.isRetryingSync,
                        onRetry = {
                            if (state.canRetrySync) vm.retryPendingSync()
                            val id = vineyardId ?: return@PruningPendingSyncCard
                            scope.launch {
                                val (mergedSetups, mergedEntries) = vm.refreshPruning(id)
                                setups = mergedSetups
                                entries = mergedEntries
                            }
                        },
                    )
                }
            }
            item(key = "dashboard") {
                PruningDashboardCard(
                    paddocks = paddocks,
                    setups = setups,
                    entries = entries,
                    seasonStartMonth = state.seasonStartMonth,
                    seasonStartDay = state.seasonStartDay,
                )
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

/**
 * Visible warning while pruning writes remain in the outbox — pending count,
 * needs-attention count, the last error, and a retry that routes through the
 * ordered replay pipeline plus a pruning refresh. Never hides failed pruning
 * writes behind a synced-looking dashboard.
 */
@Composable
private fun PruningPendingSyncCard(
    items: List<PendingSyncItem>,
    canRetry: Boolean,
    isRetrying: Boolean,
    onRetry: () -> Unit,
) {
    val vine = LocalVineColors.current
    val attention = items.count { it.status == "blocked" || it.status == "failed" }
    val lastError = items.firstOrNull { !it.rawDetail.isNullOrBlank() }?.rawDetail
        ?: items.firstOrNull { !it.friendlyDetail.isNullOrBlank() }?.friendlyDetail
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(VineColors.Warning.copy(alpha = 0.12f))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Filled.SyncProblem,
                contentDescription = null,
                tint = VineColors.Warning,
                modifier = Modifier.size(20.dp),
            )
            Text(
                "Pruning changes pending sync",
                fontWeight = FontWeight.SemiBold,
                fontSize = 15.sp,
                color = vine.textPrimary,
            )
        }
        Text(
            (if (items.size == 1) "1 recorded change hasn't" else "${items.size} recorded changes haven't") +
                " reached the server yet. The progress below includes this device's unsynced work.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        if (attention > 0) {
            Text(
                if (attention == 1) "1 item needs attention" else "$attention items need attention",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = VineColors.Destructive,
            )
        }
        if (lastError != null) {
            Text("Last error: $lastError", fontSize = 11.sp, color = VineColors.Destructive)
        }
        if (canRetry) {
            Button(
                onClick = onRetry,
                enabled = !isRetrying,
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Warning),
            ) {
                Icon(
                    Icons.Filled.Refresh,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    if (isRetrying) "Retrying…" else "Retry sync",
                    modifier = Modifier.padding(start = 6.dp),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
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

/**
 * Shared display rule (matches iOS + portal RPC): round(fraction × 100),
 * never truncate — truncation made Android show 3% where iOS showed 4%.
 */
private fun fmtPercent(fraction: Double): String = "${PruningCalculator.displayPercent(fraction)}%"

private val displayDate: DateTimeFormatter = DateTimeFormatter.ofPattern("d MMM")

private fun fmtDate(date: LocalDate?): String = date?.format(displayDate) ?: "—"

// MARK: - Dashboard

@Composable
private fun PruningDashboardCard(
    paddocks: List<Paddock>,
    setups: List<PruningBlockSetup>,
    entries: List<PruningEntry>,
    seasonStartMonth: Int = 7,
    seasonStartDay: Int = 1,
) {
    val vine = LocalVineColors.current

    // Technical pruning season (calendar-year grouping used by sync) AND the
    // production/costing vintage — both shown so "Season 2026" is never read
    // as the costing vintage. Mirrors the sql/119 resolver (matches iOS).
    val seasonVintageLabel = remember(seasonStartMonth, seasonStartDay) {
        val seasonYear = PruningSeasonIds.currentSeasonYear()
        val vintage = VintageResolver.vintageYear(LocalDate.now(), seasonStartMonth, seasonStartDay)
        "$seasonYear Winter Pruning · Vintage $vintage"
    }

    // SHARED CONTRACT: the dashboard is `PruningCalculator.vineyardSummary`
    // — the exact aggregation the SQL 115 RPC implements and the fixture
    // tests verify. Never aggregate here in the view.
    val summary = PruningCalculator.vineyardSummary(paddocks, setups, entries)
    val vinesPruned = summary.vinesPruned
    val fraction = summary.fraction
    val vinesPerDay = summary.vinesPerDay
    val vinesPerHour = summary.vinesPerLabourHour
    val blocksComplete = summary.blocksComplete
    val blocksAtRisk = summary.blocksAtRisk
    val projected = summary.projectedFinish

    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                    Text("Vineyard Progress", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    Text(seasonVintageLabel, fontSize = 12.sp, color = vine.textSecondary)
                }
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
                DashStat("${summary.vinesRemaining}", "Vines remaining", Modifier.weight(1f))
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
    onEditEntry: (PruningEntry, PruningEditTaskAction) -> Unit,
    onDeleteEntry: (String) -> Unit,
    onDeleteWorkTask: (String) -> Unit,
    operatorCategories: List<OperatorCategory>,
    workTasks: List<WorkTask>,
    taskLabourLines: List<WorkTaskLabourLine>,
    taskLinesTaskId: String?,
    onLoadTaskLines: (String) -> Unit,
    seasonStartMonth: Int,
    seasonStartDay: Int,
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
    /** Entry being edited — its own quarters unlock in the grid so the user
     * can add/remove/replace them before saving through the edit form. */
    var editingEntry by remember(paddock.id) { mutableStateOf<PruningEntry?>(null) }

    // Quarters locked in the grid. While editing, the entry's own quarters
    // become toggleable; quarters completed by OTHER entries stay locked —
    // the server refuses to steal them anyway (sql/120).
    val lockedSegments = editingEntry.let { editing ->
        if (editing == null) metrics.completed
        else metrics.completed - PruningCalculator.completedSegments(listOf(editing), rows)
    }

    fun beginEdit(entry: PruningEntry) {
        editingEntry = entry
        selected = PruningCalculator.completedSegments(listOf(entry), rows)
        entry.workTaskId?.let(onLoadTaskLines)
    }

    fun cancelEdit() {
        editingEntry = null
        selected = emptySet()
    }

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
            if (selected.isNotEmpty() || editingEntry != null) {
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
                            Text(
                                if (editingEntry == null) "Record Pruning" else "Save Changes",
                                fontWeight = FontWeight.SemiBold,
                            )
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
                editingEntry?.let { editing ->
                    item(key = "edit-banner") {
                        PruningEditBanner(entry = editing, onCancel = { cancelEdit() })
                    }
                }
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
                                        if (!lockedSegments.contains(segment)) additions.add(segment)
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
                        completed = lockedSegments,
                        selected = selected,
                        onToggle = { segment ->
                            selected = if (selected.contains(segment)) selected - segment else selected + segment
                        },
                        onToggleRow = {
                            val remaining = (1..4)
                                .map { row.segment(it) }
                                .filter { !lockedSegments.contains(it) }
                            selected = if (remaining.all { selected.contains(it) }) {
                                selected - remaining.toSet()
                            } else {
                                selected + remaining
                            }
                        },
                    )
                }
                item(key = "history") {
                    DetailHistoryCard(
                        entries = blockEntries,
                        onEdit = { beginEdit(it) },
                    ) { entry ->
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
        val editing = editingEntry
        PruningEntrySheet(
            paddock = paddock,
            vineyardId = vineyardId,
            segments = selected.sortedWith(compareBy({ it.row }, { it.quarter })),
            rows = rows,
            defaultMethod = setup?.method ?: "spur",
            defaultWorker = setup?.crew ?: "",
            operatorCategories = operatorCategories,
            existingEntry = editing,
            linkedTask = editing?.workTaskId?.let { id -> workTasks.firstOrNull { it.id == id } },
            linkedTaskLines = if (editing?.workTaskId != null && taskLinesTaskId == editing.workTaskId) {
                taskLabourLines.filter { it.workTaskId == editing.workTaskId }
            } else {
                emptyList()
            },
            seasonStartMonth = seasonStartMonth,
            seasonStartDay = seasonStartDay,
            onDismiss = { showEntrySheet = false },
            onSave = { entry, taskDraft ->
                onAddEntry(entry, taskDraft)
                selected = emptySet()
                showEntrySheet = false
            },
            onSaveEdit = { entry, action ->
                onEditEntry(entry, action)
                selected = emptySet()
                editingEntry = null
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

    // SHARED CONTRACT (SQL 115): exact per-day vine totals and person-hour
    // rates — full precision throughout, rounded once at display. Never sum
    // per-entry rounded values or approximate via vines-per-row.
    val vinesPerDay = PruningCalculator.exactVinesPerDay(entries, metrics.rows)
    val vinesPerHour = PruningCalculator.vinesPerLabourHour(entries, metrics.rows)

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
                    DashStat(vinesPerDay?.let { fmt(it, 0) } ?: "—", "Vines / day", Modifier.weight(1f))
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
                    Text(
                        "Select range",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Primary,
                        maxLines = 1,
                        softWrap = false,
                    )
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
            maxLines = 1,
            softWrap = false,
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
private fun DetailHistoryCard(
    entries: List<PruningEntry>,
    onEdit: (PruningEntry) -> Unit,
    onDelete: (PruningEntry) -> Unit,
) {
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
                        IconButton(onClick = { onEdit(entry) }, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Filled.Edit, contentDescription = "Edit this pruning entry", tint = VineColors.Primary, modifier = Modifier.size(16.dp))
                        }
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

// MARK: - Edit banner

/** Blue in-context banner while a pruning entry is being edited — the grid
 * unlocks the entry's own quarters underneath it. */
@Composable
private fun PruningEditBanner(entry: PruningEntry, onCancel: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(VineColors.Primary.copy(alpha = 0.10f))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            Icons.Filled.Edit,
            contentDescription = null,
            tint = VineColors.Primary,
            modifier = Modifier.size(20.dp),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                "Editing ${fmtDate(PruningCalculator.parseDate(entry.date))} entry",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
            )
            Text(
                "Tap quarters to adjust the selection, then Save Changes.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
        TextButton(onClick = onCancel) {
            Text("Cancel", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
        }
    }
}

// MARK: - Entry sheet

/** What happens to the linked Work Task when a pruning entry edit saves. */
sealed interface PruningEditTaskAction {
    /** No Work Task involvement — the entry edit stands alone. */
    data object None : PruningEditTaskAction

    /** Synchronise the existing linked task's header and labour lines.
     * [lines] carry stable ids for existing rows (update the canonical
     * `work_task_labour_lines` row) and null ids for new rows;
     * [removedLineIds] soft-delete through the normal labour workflow. */
    data class UpdateLinked(
        val taskType: String,
        val notes: String,
        val lines: List<PruningEditLabourLine>,
        val removedLineIds: Set<String>,
    ) : PruningEditTaskAction

    /** Create ONE Work Task for an entry that never had one. */
    data class CreateNew(val draft: PruningWorkTaskDraft) : PruningEditTaskAction

    /** Explicit user choice from the unlink dialog — never silent. */
    data class Unlink(val deleteTask: Boolean) : PruningEditTaskAction
}

/** One labour line in a pruning edit — stable [lineId] for existing rows so
 * the update lands on the canonical row instead of duplicating it. */
data class PruningEditLabourLine(
    val lineId: String?,
    val operatorCategoryId: String?,
    val workerType: String,
    val workerCount: Int,
    val hoursPerWorker: Double,
    val hourlyRate: Double?,
)

/** Work Task creation request captured in the Record Pruning sheet — every
 * other task value (date, block, crew, times) is reused from the pruning
 * entry itself so nothing is entered twice. [labour] carries one costing line
 * per worker/crew row (`work_task_labour_lines`). */
data class PruningWorkTaskDraft(
    val taskType: String,
    val notes: String,
    val labour: List<PruningLabourDraft>,
)

/** One validated Work Task labour line captured in the Record Pruning sheet. */
data class PruningLabourDraft(
    val operatorCategoryId: String?,
    val workerType: String,
    val workerCount: Int,
    val hoursPerWorker: Double,
    val hourlyRate: Double?,
) {
    /** Person-hours: worker count × hours per worker (DB `total_hours`). */
    val totalHours: Double get() = workerCount * hoursPerWorker
}

/** Editable labour-line row state inside the Record Pruning sheet. For lines
 * loaded from an existing linked Work Task, [lineId] is the REAL
 * `work_task_labour_lines` row id, so edits update the canonical row instead
 * of duplicating it. */
private data class PruningLabourRow(
    val key: Int,
    val lineId: String? = null,
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
    /** Non-null puts the SAME form into edit mode: fields preload from this
     * entry, [segments] carries the edited quarter set, and saving routes
     * through the offline edit queue + `update_pruning_entry` RPC (sql/120). */
    existingEntry: PruningEntry? = null,
    /** The linked Work Task when it exists in the local store. */
    linkedTask: WorkTask? = null,
    /** The linked task's live labour lines (stable ids preserved for the diff). */
    linkedTaskLines: List<WorkTaskLabourLine> = emptyList(),
    seasonStartMonth: Int = 7,
    seasonStartDay: Int = 1,
    onSaveEdit: (PruningEntry, PruningEditTaskAction) -> Unit = { _, _ -> },
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    val isEditing = existingEntry != null
    val hasLinkedTask = existingEntry?.workTaskId != null

    var date by remember { mutableStateOf(PruningCalculator.parseDate(existingEntry?.date) ?: LocalDate.now()) }
    var showDatePicker by remember { mutableStateOf(false) }
    var worker by remember { mutableStateOf(existingEntry?.worker ?: defaultWorker) }
    var hoursText by remember { mutableStateOf(existingEntry?.labourHours?.let { fmt(it, 1) } ?: "") }
    var includeTimes by remember { mutableStateOf(existingEntry?.startTime != null || existingEntry?.finishTime != null) }
    var startTime by remember { mutableStateOf(existingEntry?.startTime ?: "") }
    var finishTime by remember { mutableStateOf(existingEntry?.finishTime ?: "") }
    var method by remember { mutableStateOf(existingEntry?.method ?: defaultMethod) }
    var notes by remember { mutableStateOf(existingEntry?.notes ?: "") }
    var createTask by remember { mutableStateOf(false) }
    var taskType by remember { mutableStateOf(linkedTask?.taskType?.takeIf { it.isNotBlank() } ?: "Pruning") }
    // Edit-mode Work Task state: default ON so the linked task's date, work
    // type, notes and labour lines follow the edit unless the user opts out.
    var updateLinkedTask by remember { mutableStateOf(true) }
    var showUnlinkDialog by remember { mutableStateOf(false) }
    var unlinkKeepTask by remember { mutableStateOf(false) }
    var unlinkDeleteTask by remember { mutableStateOf(false) }
    /** Stable ids of the linked task's live lines when the editor opened —
     * lines missing from the saved set soft-delete through the normal flow. */
    var originalLineIds by remember { mutableStateOf(setOf<String>()) }
    // Labour costing lines for the linked Work Task. The first row is seeded
    // from the pruning form's Worker/Crew + Labour hours when the toggle turns
    // on (or from the entry while the linked task's real lines load), so
    // nothing is entered twice.
    var labourRows by remember {
        mutableStateOf(
            if (existingEntry?.workTaskId != null) {
                listOf(
                    PruningLabourRow(
                        key = 0,
                        workerType = existingEntry.worker,
                        hoursText = existingEntry.labourHours?.let { fmt(it, 1) } ?: "",
                    )
                )
            } else {
                emptyList()
            }
        )
    }
    var nextLabourKey by remember { mutableStateOf(1) }
    var labourSeeded by remember { mutableStateOf(false) }

    // The linked task's REAL labour lines replace the fallback seed exactly
    // once when they arrive (they may load async) — stable line ids preserved
    // so the edit updates canonical rows instead of duplicating them.
    LaunchedEffect(linkedTaskLines) {
        if (hasLinkedTask && !labourSeeded && linkedTaskLines.isNotEmpty()) {
            labourRows = linkedTaskLines.mapIndexed { index, line ->
                PruningLabourRow(
                    key = 100 + index,
                    lineId = line.id,
                    categoryId = line.operatorCategoryId,
                    workerType = line.workerType,
                    countText = "${line.workerCount}",
                    hoursText = fmt(line.hoursPerWorker),
                    rateText = line.hourlyRate?.let { fmt(it) } ?: "",
                )
            }
            originalLineIds = linkedTaskLines.map { it.id }.toSet()
            nextLabourKey = 100 + linkedTaskLines.size
            labourSeeded = true
        }
    }

    val willUnlink = unlinkKeepTask || unlinkDeleteTask
    /** Whether the Work Task costing fields (work type + labour lines) are
     * active: creating a new task, or updating an existing linked one. */
    val showsTaskFields = if (isEditing && hasLinkedTask) {
        updateLinkedTask && !willUnlink && linkedTask != null
    } else {
        createTask
    }

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
            Text(
                if (isEditing) "Edit Pruning Record — ${paddock.name}" else "Record Pruning — ${paddock.name}",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )
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
            if (showsTaskFields) {
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

            if (isEditing && hasLinkedTask) {
                if (willUnlink) {
                    Text(
                        if (unlinkDeleteTask) {
                            "The Work Task will be deleted and unlinked when you save."
                        } else {
                            "The Work Task will be kept but unlinked when you save."
                        },
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Warning,
                    )
                    TextButton(onClick = {
                        unlinkKeepTask = false
                        unlinkDeleteTask = false
                    }) {
                        Text("Keep Work Task linked", color = VineColors.Primary, fontWeight = FontWeight.SemiBold)
                    }
                } else if (linkedTask != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "Update linked Work Task",
                            fontSize = 14.sp,
                            color = vine.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Switch(checked = updateLinkedTask, onCheckedChange = { updateLinkedTask = it })
                    }
                    if (updateLinkedTask) {
                        WorkTaskTypePicker(builtInWorkTaskTypes, taskType) { taskType = it }
                        Text(
                            "Title: Pruning — ${paddock.name} · Status: ${if (linkedTask.isFinalized) "Completed" else linkedTask.status ?: "Open"}",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textSecondary,
                        )
                    }
                    TextButton(onClick = { showUnlinkDialog = true }) {
                        Text("Unlink Work Task…", color = VineColors.Destructive, fontWeight = FontWeight.SemiBold)
                    }
                } else {
                    Text(
                        "The linked Work Task isn't on this device yet — its costing fields can't be edited here.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                    TextButton(onClick = { showUnlinkDialog = true }) {
                        Text("Unlink Work Task…", color = VineColors.Destructive, fontWeight = FontWeight.SemiBold)
                    }
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (isEditing) "Create a Work Task for this pruning record" else "Create a Work Task for this pruning work",
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
                }
            }
            if (showsTaskFields) {
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
                    if (isEditing && hasLinkedTask) {
                        "Saving synchronises the task's date, work type, notes and the labour lines above — stable ids, so retries never duplicate the task or its lines. The pruning record stays the source of truth for row completion."
                    } else {
                        "The Work Task reuses this record's date, block, crew, times and notes — nothing is entered twice. It is created as completed with these labour lines and appears in the Work Tasks tool. Rates left blank show as “Not specified”."
                    },
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            if (existingEntry != null) {
                PruningEditSummaryCard(
                    original = existingEntry,
                    newQuarters = segments.size,
                    newHours = if (showsTaskFields) {
                        labourPersonHours.takeIf { it > 0 }
                    } else {
                        hoursText.replace(',', '.').toDoubleOrNull()
                    },
                    labourCost = if (showsTaskFields && hasRatedLine) labourTotalCost else null,
                    vintage = VintageResolver.vintageYear(date, seasonStartMonth, seasonStartDay),
                )
            }

            Button(
                onClick = {
                    if (existingEntry != null) {
                        // Person-hours convention: with a live task, the entry's
                        // labour hours = sum of the labour-line person-hours.
                        val entryHours = if (showsTaskFields) {
                            labourPersonHours.takeIf { it > 0 }
                        } else {
                            hoursText.replace(',', '.').toDoubleOrNull()
                        }
                        val updated = existingEntry.copy(
                            date = date.toString(),
                            segments = segments,
                            worker = worker.trim(),
                            labourHours = entryHours,
                            startTime = if (includeTimes) startTime.trim().ifBlank { null } else null,
                            finishTime = if (includeTimes) finishTime.trim().ifBlank { null } else null,
                            method = method,
                            notes = notes.trim(),
                            estimatedVines = PruningCalculator.vines(segments, rows),
                        )
                        val keptLineIds = labourRows.filter { it.isValid }.mapNotNull { it.lineId }.toSet()
                        val action: PruningEditTaskAction = when {
                            willUnlink && hasLinkedTask ->
                                PruningEditTaskAction.Unlink(deleteTask = unlinkDeleteTask)
                            hasLinkedTask && showsTaskFields -> PruningEditTaskAction.UpdateLinked(
                                taskType = taskType,
                                notes = composePruningTaskNotes(segments, rows, method, notes.trim()),
                                lines = labourRows.filter { it.isValid }.map { row ->
                                    PruningEditLabourLine(
                                        lineId = row.lineId,
                                        operatorCategoryId = row.categoryId,
                                        workerType = row.workerType.trim(),
                                        workerCount = row.workerCount,
                                        hoursPerWorker = row.hoursPerWorker,
                                        hourlyRate = row.hourlyRate,
                                    )
                                },
                                removedLineIds = originalLineIds - keptLineIds,
                            )
                            !hasLinkedTask && createTask -> PruningEditTaskAction.CreateNew(
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
                            )
                            else -> PruningEditTaskAction.None
                        }
                        onSaveEdit(updated, action)
                    } else {
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
                    }
                },
                enabled = if (isEditing) {
                    !showsTaskFields || labourValid
                } else {
                    segments.isNotEmpty() && (!createTask || labourValid)
                },
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    when {
                        isEditing -> "Save Changes"
                        segments.size == 1 -> "Record 1 quarter"
                        else -> "Record ${segments.size} quarters"
                    },
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

    // Never a silent unlink — the user explicitly chooses what happens to the
    // linked Work Task (mirrors the iOS confirmation dialog).
    if (showUnlinkDialog) {
        AlertDialog(
            onDismissRequest = { showUnlinkDialog = false },
            title = { Text("Remove the Work Task link from this pruning record?") },
            text = {
                Text("The pruning record keeps its quarters either way — unlinking only affects Work Task reporting.")
            },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = {
                        unlinkKeepTask = true
                        unlinkDeleteTask = false
                        showUnlinkDialog = false
                    }) { Text("Keep Work Task but unlink") }
                    TextButton(onClick = {
                        unlinkDeleteTask = true
                        unlinkKeepTask = false
                        showUnlinkDialog = false
                    }) { Text("Delete Work Task and unlink", color = VineColors.Destructive) }
                    TextButton(onClick = { showUnlinkDialog = false }) { Text("Cancel") }
                }
            },
        )
    }
}

/** Before-save summary so the user sees exactly what the edit changes. */
@Composable
private fun PruningEditSummaryCard(
    original: PruningEntry,
    newQuarters: Int,
    newHours: Double?,
    labourCost: Double?,
    vintage: Int,
) {
    val vine = LocalVineColors.current
    val oldQuarters = original.segments.size
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("Edit Summary", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        EditSummaryRow("Quarters", "$oldQuarters → $newQuarters")
        EditSummaryRow("Row equivalents", "${fmt(oldQuarters / 4.0)} → ${fmt(newQuarters / 4.0)}")
        EditSummaryRow(
            "Person-hours",
            "${original.labourHours?.let { "${fmt(it, 1)} h" } ?: "—"} → ${newHours?.let { "${fmt(it, 1)} h" } ?: "—"}",
        )
        if (labourCost != null) {
            EditSummaryRow("Labour cost", fmtCurrency(labourCost))
        }
        EditSummaryRow("Vintage", "$vintage")
        Text(
            "Quarters completed by other entries are never taken over — any conflict is reported after sync.",
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun EditSummaryRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row {
        Text(label, fontSize = 13.sp, color = vine.textSecondary)
        Spacer(Modifier.weight(1f))
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
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
