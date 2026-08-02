package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowDropUp
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PruningActivityBlockContext
import com.rork.vinetrack.data.model.PruningActivityColumn
import com.rork.vinetrack.data.model.PruningActivityFilter
import com.rork.vinetrack.data.model.PruningActivityReport
import com.rork.vinetrack.data.model.PruningActivityRow
import com.rork.vinetrack.data.model.PruningActivitySort
import com.rork.vinetrack.data.model.PruningActivitySortDirection
import com.rork.vinetrack.data.model.PruningActivityStatus
import com.rork.vinetrack.data.model.PruningActivitySummary
import com.rork.vinetrack.data.model.PruningActivityTaskLink
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningCalculator
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt

/**
 * Full vineyard-wide Pruning Activity Report — every pruning record for the
 * selected vineyard and growing season in one sortable, filterable table.
 *
 * Data source: the SAME server-authoritative pruning cache the tracker uses
 * (`PruningStore` + `PruningSyncCoordinator`, fed by `record_pruning_entry` /
 * `update_pruning_entry` / `delete_pruning_entry` and the
 * `pruning_row_segments` attribution). Rows are projected through the shared
 * [PruningActivityReport] contract, which iOS mirrors field for field.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PruningActivityReportScreen(
    auditEntries: List<PruningEntry>,
    setups: List<PruningBlockSetup>,
    paddocks: List<Paddock>,
    workTasks: List<WorkTask>,
    labourLines: List<WorkTaskLabourLine>,
    members: List<VineyardMember>,
    canViewCosting: Boolean,
    onBack: () -> Unit,
    onEditEntry: (PruningEntry) -> Unit,
    onReverseEntry: (PruningEntry) -> Unit,
    onDeleteWorkTask: (String) -> Unit,
    onOpenWorkTasks: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current

    // Block context resolved ONCE per block (name, variety, rows) — the report
    // never looks an entity up per record.
    val blockContexts = remember(paddocks, setups) {
        paddocks.associate { paddock ->
            val setup = setups.firstOrNull { it.paddockId == paddock.id }
            paddock.id to PruningActivityBlockContext(
                name = paddock.name,
                variety = paddock.primaryVarietyName,
                rows = PruningCalculator.rowRefs(paddock, setup),
            )
        }
    }
    val workTaskTitles = remember(workTasks) { workTasks.associate { it.id to it.displayLabel } }
    // One pass over the labour lines — never one lookup per record.
    val labourCosts = remember(labourLines, canViewCosting) {
        if (!canViewCosting) {
            emptyMap()
        } else {
            labourLines
                .filter { it.hourlyRate != null && it.deletedAt == null }
                .groupBy { it.workTaskId }
                .mapValues { (_, lines) -> lines.sumOf { it.resolvedCost } }
        }
    }
    val accountNames = remember(members) { members.associate { it.userId to it.name } }

    val allRows = remember(auditEntries, blockContexts, workTaskTitles, labourCosts, accountNames) {
        PruningActivityReport.rows(
            entries = auditEntries,
            blocks = blockContexts,
            workTaskTitles = workTaskTitles,
            labourCosts = labourCosts,
            accountNames = accountNames,
        )
    }

    val seasons = remember(allRows) {
        (allRows.map { it.seasonYear }.filter { it > 0 } + LocalDate.now().year)
            .distinct()
            .sortedDescending()
    }

    // Sort + season survive configuration change and process restore; ad-hoc
    // filters intentionally do not.
    var sortColumnKey by rememberSaveable { mutableStateOf<String?>(null) }
    var sortAscending by rememberSaveable { mutableStateOf(false) }
    var season by rememberSaveable { mutableStateOf(LocalDate.now().year) }
    var search by rememberSaveable { mutableStateOf("") }
    var showFilters by rememberSaveable { mutableStateOf(false) }
    var selectedRowId by rememberSaveable { mutableStateOf<String?>(null) }
    var reversalTargetId by rememberSaveable { mutableStateOf<String?>(null) }
    var filter by remember { mutableStateOf(PruningActivityFilter()) }

    val sort = PruningActivitySort(PruningActivityColumn.fromKey(sortColumnKey), sortAscending)
    val appliedFilter = filter.copy(seasonYear = season.takeIf { it > 0 }, search = search)

    val rows = remember(allRows, appliedFilter, sort) {
        PruningActivityReport.sorted(PruningActivityReport.filtered(allRows, appliedFilter), sort)
    }
    val summary = remember(rows, canViewCosting) { PruningActivityReport.summary(rows, canViewCosting) }
    val columns = remember(canViewCosting) {
        PruningActivityColumn.displayOrder.filter { canViewCosting || !it.isCosting }
    }

    val selectedRow = rows.firstOrNull { it.id == selectedRowId }
        ?: allRows.firstOrNull { it.id == selectedRowId }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Activity Report") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    IconButton(onClick = { showFilters = true }) {
                        Icon(
                            Icons.Filled.FilterList,
                            contentDescription = "Filter the pruning activity report",
                            tint = if (appliedFilter.hasRestrictions) VineColors.Primary else vine.textPrimary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            SummaryStrip(summary = summary, canViewCosting = canViewCosting)

            OutlinedTextField(
                value = search,
                onValueChange = { search = it },
                singleLine = true,
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, tint = vine.textSecondary) },
                placeholder = { Text("Worker, block, variety, row, task, notes", fontSize = 13.sp) },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp)
                    .semantics { contentDescription = "Search pruning records" },
            )

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                Text(
                    "Season $season · ${rows.size} record${if (rows.size == 1) "" else "s"}",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                if (appliedFilter.hasRestrictions) {
                    TextButton(onClick = {
                        filter = PruningActivityFilter()
                        search = ""
                    }) { Text("Clear filters", fontSize = 12.sp) }
                }
                if (sort.column != null) {
                    TextButton(onClick = {
                        sortColumnKey = null
                        sortAscending = false
                    }) { Text("Reset sort", fontSize = 12.sp) }
                }
            }

            HorizontalDivider(color = vine.cardBorder)

            if (rows.isEmpty()) {
                EmptyReportState(hasAnyRecords = allRows.isNotEmpty())
            } else {
                ReportTable(
                    rows = rows,
                    columns = columns,
                    sort = sort,
                    onSort = { column ->
                        val next = sort.cycled(column)
                        sortColumnKey = next.column?.key
                        sortAscending = next.ascending
                    },
                    onOpen = { selectedRowId = it.id },
                )
            }
        }
    }

    if (showFilters) {
        PruningActivityFilterSheet(
            filter = appliedFilter,
            season = season,
            seasons = seasons,
            workers = allRows.mapNotNull { it.worker }.distinct().sorted(),
            blocks = paddocks.sortedBy { it.name.lowercase() }.map { it.id to it.name },
            varieties = allRows.mapNotNull { it.variety }.distinct().sorted(),
            matchCount = rows.size,
            onSeasonChange = { season = it },
            onFilterChange = { filter = it.copy(seasonYear = null, search = "") },
            onDismiss = { showFilters = false },
        )
    }

    if (selectedRow != null) {
        val entry = auditEntries.firstOrNull { it.id == selectedRow.id }
        PruningActivityDetailSheet(
            row = selectedRow,
            canViewCosting = canViewCosting,
            onDismiss = { selectedRowId = null },
            onEdit = {
                selectedRowId = null
                entry?.let(onEditEntry)
            },
            onOpenWorkTask = {
                selectedRowId = null
                onOpenWorkTasks()
            },
            onReverse = {
                selectedRowId = null
                if (entry != null) {
                    if (entry.workTaskId != null) reversalTargetId = entry.id else onReverseEntry(entry)
                }
            },
        )
    }

    // Reversal prompt for entries with a linked Work Task — the pruning entry
    // is always reversed; the user explicitly decides what happens to the task.
    val reversalTarget = auditEntries.firstOrNull { it.id == reversalTargetId }
    if (reversalTarget != null) {
        AlertDialog(
            onDismissRequest = { reversalTargetId = null },
            title = { Text("Linked Work Task") },
            text = {
                Text("This pruning entry has a linked Work Task. What should happen to the task? Reversing the entry always reopens its row quarters.")
            },
            confirmButton = {
                TextButton(onClick = {
                    reversalTarget.workTaskId?.let(onDeleteWorkTask)
                    onReverseEntry(reversalTarget)
                    reversalTargetId = null
                }) { Text("Delete Work Task", color = VineColors.Destructive) }
            },
            dismissButton = {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = { reversalTargetId = null }) { Text("Cancel") }
                    TextButton(onClick = {
                        onReverseEntry(reversalTarget)
                        reversalTargetId = null
                    }) { Text("Keep Work Task") }
                }
            },
        )
    }
}

// MARK: - Summary strip

@Composable
private fun SummaryStrip(summary: PruningActivitySummary, canViewCosting: Boolean) {
    val vine = LocalVineColors.current
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .background(vine.cardBackground)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        SummaryChip("${summary.jobs}", "Jobs")
        SummaryChip(fmtWhole(summary.vines), "Vines")
        SummaryChip("${fmtDecimal(summary.labourHours, 1)} h", "Labour hours")
        SummaryChip(summary.averageVinesPerHour?.let { fmtWhole(it) } ?: "—", "Avg vines / hr")
        if (canViewCosting) {
            SummaryChip(summary.labourCost?.let { "$" + fmtDecimal(it, 2) } ?: "—", "Labour cost")
        }
        SummaryChip("${summary.activeRecords}", "Active")
        SummaryChip("${summary.reversedRecords}", "Reversed", muted = true)
    }
}

@Composable
private fun SummaryChip(value: String, label: String, muted: Boolean = false) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(vine.appBackground)
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .semantics { contentDescription = "$label: $value" },
    ) {
        Text(
            value,
            fontSize = 14.sp,
            fontWeight = FontWeight.Bold,
            color = if (muted) vine.textSecondary else vine.textPrimary,
        )
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
    }
}

// MARK: - Table

/**
 * Report table: heading row pinned above a lazily rendered body, the whole
 * table scrolling horizontally as one so headings and cells stay aligned.
 */
@Composable
private fun ReportTable(
    rows: List<PruningActivityRow>,
    columns: List<PruningActivityColumn>,
    sort: PruningActivitySort,
    onSort: (PruningActivityColumn) -> Unit,
    onOpen: (PruningActivityRow) -> Unit,
) {
    val vine = LocalVineColors.current
    val totalWidth: Dp = columns.fold(0.dp) { acc, column -> acc + columnWidth(column) }

    Column(modifier = Modifier.fillMaxSize().horizontalScroll(rememberScrollState())) {
        Row(
            modifier = Modifier
                .width(totalWidth)
                .background(vine.cardBackground)
                .height(40.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            columns.forEach { column ->
                HeaderCell(column = column, sort = sort, onSort = onSort)
            }
        }
        HorizontalDivider(color = vine.cardBorder)
        LazyColumn(modifier = Modifier.width(totalWidth).weight(1f)) {
            items(rows.size, key = { rows[it].id }) { index ->
                val row = rows[index]
                Row(
                    modifier = Modifier
                        .width(totalWidth)
                        .height(48.dp)
                        .background(if (row.isReversed) vine.textSecondary.copy(alpha = 0.07f) else Color.Transparent)
                        .clickable { onOpen(row) }
                        .semantics { contentDescription = rowAccessibilityLabel(row) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    columns.forEach { column -> BodyCell(row, column) }
                }
                HorizontalDivider(color = vine.cardBorder)
            }
            item(key = "bottom-space") {
                Spacer(Modifier.height(24.dp).navigationBarsPadding())
            }
        }
    }
}

@Composable
private fun HeaderCell(
    column: PruningActivityColumn,
    sort: PruningActivitySort,
    onSort: (PruningActivityColumn) -> Unit,
) {
    val vine = LocalVineColors.current
    val direction = sort.direction(column)
    val label = when (direction) {
        PruningActivitySortDirection.Ascending -> "${column.label}, sorted ascending. Activate to sort descending."
        PruningActivitySortDirection.Descending -> "${column.label}, sorted descending. Activate to clear the sort."
        PruningActivitySortDirection.None ->
            if (column.isSortable) "${column.label}, unsorted. Activate to sort ascending." else column.label
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .width(columnWidth(column))
            .height(40.dp)
            .then(if (column.isSortable) Modifier.clickable { onSort(column) } else Modifier)
            .padding(horizontal = 8.dp)
            .semantics { contentDescription = label },
    ) {
        Text(
            column.label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = vine.textPrimary,
            maxLines = 1,
        )
        when (direction) {
            PruningActivitySortDirection.Ascending ->
                Icon(Icons.Filled.ArrowDropUp, contentDescription = null, tint = VineColors.Primary, modifier = Modifier.size(14.dp))
            PruningActivitySortDirection.Descending ->
                Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = VineColors.Primary, modifier = Modifier.size(14.dp))
            PruningActivitySortDirection.None -> Unit
        }
    }
}

@Composable
private fun BodyCell(row: PruningActivityRow, column: PruningActivityColumn) {
    val vine = LocalVineColors.current
    Box(
        contentAlignment = Alignment.CenterStart,
        modifier = Modifier.width(columnWidth(column)).height(48.dp).padding(horizontal = 8.dp),
    ) {
        when (column) {
            PruningActivityColumn.Status -> StatusBadge(row.status)
            PruningActivityColumn.WorkTask -> if (row.hasWorkTask) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Filled.Link, contentDescription = null, tint = VineColors.Primary, modifier = Modifier.size(12.dp))
                    Text(
                        row.workTaskTitle ?: "Work Task",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Primary,
                        maxLines = 1,
                    )
                }
            } else {
                Text("—", fontSize = 12.sp, color = vine.textSecondary)
            }
            else -> Text(
                cellValue(row, column),
                fontSize = 12.sp,
                color = if (row.isReversed) vine.textSecondary else vine.textPrimary,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun StatusBadge(status: PruningActivityStatus) {
    val vine = LocalVineColors.current
    val tint = when (status) {
        PruningActivityStatus.Active -> VineColors.Primary
        PruningActivityStatus.Edited -> VineColors.Indigo
        PruningActivityStatus.Reversed -> vine.textSecondary
    }
    Text(
        status.label,
        fontSize = 10.sp,
        fontWeight = FontWeight.SemiBold,
        color = tint,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

@Composable
private fun EmptyReportState(hasAnyRecords: Boolean) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            if (hasAnyRecords) "No records match these filters" else "No pruning activity yet",
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            color = vine.textPrimary,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            if (hasAnyRecords) {
                "Adjust the season, date range or filters to see more records."
            } else {
                "Record pruning on a block and every job will appear here."
            },
            fontSize = 13.sp,
            color = vine.textSecondary,
        )
    }
}

// MARK: - Detail sheet

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PruningActivityDetailSheet(
    row: PruningActivityRow,
    canViewCosting: Boolean,
    onDismiss: () -> Unit,
    onEdit: () -> Unit,
    onOpenWorkTask: () -> Unit,
    onReverse: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text("Pruning Record", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            if (row.isReversed) {
                Text(
                    "Reversed — audit history only. This record no longer contributes to pruning totals and can't be edited or reversed again.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
            DetailLine("Status", row.status.label)
            DetailLine("Date", cellValue(row, PruningActivityColumn.Date))
            DetailLine("Worker or crew", row.worker)
            DetailLine("Block", row.blockName)
            DetailLine("Variety", row.variety)
            DetailLine("Rows", row.rowRangeLabel)
            DetailLine("Quarters completed", row.quartersLabel)
            DetailLine("Row equivalents", fmtDecimal(row.rowEquivalents, 2))
            DetailLine("Vines completed", row.vines?.let { fmtWhole(it) })
            DetailLine("Method", row.method)

            Spacer(Modifier.height(6.dp))
            Text("Labour", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            DetailLine("Labour hours", row.labourHours?.let { fmtDecimal(it, 1) })
            DetailLine("Start time", row.startTime)
            DetailLine("Finish time", row.finishTime)
            DetailLine("Duration", row.durationHours?.let { "${fmtDecimal(it, 1)} h" })
            DetailLine("Vines per hour", row.vinesPerHour?.let { fmtWhole(it) })
            if (canViewCosting) {
                DetailLine("Labour cost", row.labourCost?.let { "$" + fmtDecimal(it, 2) })
            }

            Spacer(Modifier.height(6.dp))
            Text("Record", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            DetailLine("Work Task", if (row.hasWorkTask) (row.workTaskTitle ?: "Work Task") else null)
            DetailLine("Notes", row.notes)
            DetailLine("Entered by", row.enteredBy)
            DetailLine("Created", row.createdAtMs?.let { fmtStamp(it) })
            DetailLine("Last updated", row.updatedAtMs?.let { fmtStamp(it) })

            Spacer(Modifier.height(10.dp))
            if (!row.isReversed) {
                TextButton(onClick = onEdit, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Edit, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Edit record")
                }
            }
            if (row.hasWorkTask) {
                TextButton(onClick = onOpenWorkTask, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Link, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Open Work Tasks")
                }
            }
            if (!row.isReversed) {
                TextButton(onClick = onReverse, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Undo, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Reverse record", color = VineColors.Destructive)
                }
            }
        }
    }
}

/** Genuinely unavailable values render as "—" — never as a false zero. */
@Composable
private fun DetailLine(label: String, value: String?) {
    val vine = LocalVineColors.current
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.width(150.dp))
        Text(
            value?.takeIf { it.isNotBlank() } ?: "—",
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textPrimary,
            modifier = Modifier.weight(1f),
        )
    }
}

// MARK: - Filter sheet

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PruningActivityFilterSheet(
    filter: PruningActivityFilter,
    season: Int,
    seasons: List<Int>,
    workers: List<String>,
    blocks: List<Pair<String, String>>,
    varieties: List<String>,
    matchCount: Int,
    onSeasonChange: (Int) -> Unit,
    onFilterChange: (PruningActivityFilter) -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var seasonMenu by remember { mutableStateOf(false) }
    var datePickerFor by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Filters", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            Text("Growing season", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Box {
                TextButton(onClick = { seasonMenu = true }) { Text("Season $season") }
                DropdownMenu(expanded = seasonMenu, onDismissRequest = { seasonMenu = false }) {
                    seasons.forEach { year ->
                        DropdownMenuItem(
                            text = { Text("Season $year") },
                            onClick = {
                                onSeasonChange(year)
                                seasonMenu = false
                            },
                        )
                    }
                }
            }

            Text("Date range", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { datePickerFor = "from" }) { Text("From: ${filter.dateFrom ?: "Any"}") }
                TextButton(onClick = { datePickerFor = "to" }) { Text("To: ${filter.dateTo ?: "Any"}") }
                if (filter.dateFrom != null || filter.dateTo != null) {
                    TextButton(onClick = { onFilterChange(filter.copy(dateFrom = null, dateTo = null)) }) {
                        Text("Any date")
                    }
                }
            }

            Text("Status", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PruningActivityStatus.entries.forEach { status ->
                    FilterChip(
                        selected = status in filter.statuses,
                        onClick = {
                            val next = filter.statuses.toMutableSet()
                            if (!next.add(status)) next.remove(status)
                            onFilterChange(filter.copy(statuses = next))
                        },
                        label = { Text(status.label, fontSize = 12.sp) },
                    )
                }
            }

            Text("Linked Work Task", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PruningActivityTaskLink.entries.forEach { option ->
                    FilterChip(
                        selected = filter.taskLink == option,
                        onClick = { onFilterChange(filter.copy(taskLink = option)) },
                        label = { Text(option.label, fontSize = 12.sp) },
                    )
                }
            }

            if (workers.isNotEmpty()) {
                Text("Worker or crew", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                ChipFlow(
                    options = workers.map { it to it },
                    selected = filter.workers,
                    onToggle = { value ->
                        val next = filter.workers.toMutableSet()
                        if (!next.add(value)) next.remove(value)
                        onFilterChange(filter.copy(workers = next))
                    },
                )
            }

            if (blocks.isNotEmpty()) {
                Text("Block", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                ChipFlow(
                    options = blocks,
                    selected = filter.blocks,
                    onToggle = { value ->
                        val next = filter.blocks.toMutableSet()
                        if (!next.add(value)) next.remove(value)
                        onFilterChange(filter.copy(blocks = next))
                    },
                )
            }

            if (varieties.isNotEmpty()) {
                Text("Variety", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                ChipFlow(
                    options = varieties.map { it to it },
                    selected = filter.varieties,
                    onToggle = { value ->
                        val next = filter.varieties.toMutableSet()
                        if (!next.add(value)) next.remove(value)
                        onFilterChange(filter.copy(varieties = next))
                    },
                )
            }

            Text(
                "$matchCount record${if (matchCount == 1) "" else "s"} match the current filters.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { onFilterChange(PruningActivityFilter()) }) {
                    Text("Clear filters", color = VineColors.Destructive)
                }
                TextButton(onClick = onDismiss) { Text("Done") }
            }
        }
    }

    val pickerTarget = datePickerFor
    if (pickerTarget != null) {
        val existing = if (pickerTarget == "from") filter.dateFrom else filter.dateTo
        val initialMillis = runCatching {
            LocalDate.parse(existing).atStartOfDay(ZoneId.of("UTC")).toInstant().toEpochMilli()
        }.getOrNull()
        val pickerState = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
        DatePickerDialog(
            onDismissRequest = { datePickerFor = null },
            confirmButton = {
                TextButton(onClick = {
                    val millis = pickerState.selectedDateMillis
                    if (millis != null) {
                        val iso = Instant.ofEpochMilli(millis).atZone(ZoneId.of("UTC")).toLocalDate().toString()
                        onFilterChange(
                            if (pickerTarget == "from") filter.copy(dateFrom = iso) else filter.copy(dateTo = iso)
                        )
                    }
                    datePickerFor = null
                }) { Text("Set") }
            },
            dismissButton = { TextButton(onClick = { datePickerFor = null }) { Text("Cancel") } },
        ) {
            DatePicker(state = pickerState)
        }
    }
}

@Composable
private fun ChipFlow(
    options: List<Pair<String, String>>,
    selected: Set<String>,
    onToggle: (String) -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
    ) {
        options.forEach { (value, label) ->
            FilterChip(
                selected = value in selected,
                onClick = { onToggle(value) },
                label = { Text(label, fontSize = 12.sp) },
            )
        }
    }
}

// MARK: - Formatting

private val reportDate: DateTimeFormatter = DateTimeFormatter.ofPattern("d MMM yyyy")
private val reportStamp: DateTimeFormatter = DateTimeFormatter.ofPattern("d MMM HH:mm")

private fun fmtWhole(value: Double): String = value.roundToInt().toString()

private fun fmtDecimal(value: Double, decimals: Int): String {
    val text = String.format("%.${decimals}f", value)
    return if (decimals > 0) text.trimEnd('0').trimEnd('.', ',') .ifEmpty { "0" } else text
}

private fun fmtStamp(millis: Long): String =
    Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()).toLocalDateTime().format(reportStamp)

private fun columnWidth(column: PruningActivityColumn): Dp = when (column) {
    PruningActivityColumn.Date -> 100.dp
    PruningActivityColumn.Worker -> 120.dp
    PruningActivityColumn.Block -> 130.dp
    PruningActivityColumn.Variety -> 120.dp
    PruningActivityColumn.Rows -> 76.dp
    PruningActivityColumn.Quarters -> 74.dp
    PruningActivityColumn.Vines -> 72.dp
    PruningActivityColumn.Hours -> 64.dp
    PruningActivityColumn.Start, PruningActivityColumn.Finish -> 68.dp
    PruningActivityColumn.Duration -> 80.dp
    PruningActivityColumn.VinesPerHour -> 80.dp
    PruningActivityColumn.LabourCost -> 100.dp
    PruningActivityColumn.WorkTask -> 130.dp
    PruningActivityColumn.Notes -> 180.dp
    PruningActivityColumn.EnteredBy -> 130.dp
    PruningActivityColumn.Created, PruningActivityColumn.Updated -> 130.dp
    PruningActivityColumn.Status -> 92.dp
}

private fun cellValue(row: PruningActivityRow, column: PruningActivityColumn): String = when (column) {
    PruningActivityColumn.Date -> row.date?.format(reportDate) ?: row.dateIso
    PruningActivityColumn.Worker -> row.worker ?: "—"
    PruningActivityColumn.Block -> row.blockName
    PruningActivityColumn.Variety -> row.variety ?: "—"
    PruningActivityColumn.Rows -> row.rowRangeLabel ?: "—"
    PruningActivityColumn.Quarters -> row.quartersLabel ?: "—"
    PruningActivityColumn.Vines -> row.vines?.let { fmtWhole(it) } ?: "—"
    PruningActivityColumn.Hours -> row.labourHours?.let { fmtDecimal(it, 1) } ?: "—"
    PruningActivityColumn.Start -> row.startTime ?: "—"
    PruningActivityColumn.Finish -> row.finishTime ?: "—"
    PruningActivityColumn.Duration -> row.durationHours?.let { "${fmtDecimal(it, 1)} h" } ?: "—"
    PruningActivityColumn.VinesPerHour -> row.vinesPerHour?.let { fmtWhole(it) } ?: "—"
    PruningActivityColumn.LabourCost -> row.labourCost?.let { "$" + fmtDecimal(it, 2) } ?: "—"
    PruningActivityColumn.WorkTask -> row.workTaskTitle ?: "—"
    PruningActivityColumn.Notes -> row.notes ?: "—"
    PruningActivityColumn.EnteredBy -> row.enteredBy ?: "—"
    PruningActivityColumn.Created -> row.createdAtMs?.let { fmtStamp(it) } ?: "—"
    PruningActivityColumn.Updated -> row.updatedAtMs?.let { fmtStamp(it) } ?: "—"
    PruningActivityColumn.Status -> row.status.label
}

private fun rowAccessibilityLabel(row: PruningActivityRow): String {
    val parts = mutableListOf(row.date?.format(reportDate) ?: row.dateIso)
    row.worker?.let { parts.add(it) }
    parts.add(row.blockName)
    row.vines?.let { parts.add("${fmtWhole(it)} vines") }
    parts.add(row.status.label)
    return parts.joinToString(", ")
}
