package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningActivityListing
import com.rork.vinetrack.data.model.PruningActivityReconciliation
import com.rork.vinetrack.data.model.PruningAllocationEditor
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningCalculator
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningMethods
import com.rork.vinetrack.data.model.PruningRowRef
import com.rork.vinetrack.data.model.PruningSeasonSelection
import com.rork.vinetrack.data.model.PruningSegment
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * MULTI-BLOCK PRUNING ACTIVITY EDITOR (sql/166).
 *
 * One activity, one crew, one date, one set of labour hours — across ONE OR
 * MANY blocks. The strict split the whole feature rests on:
 *
 *  * ACTIVITY level, shown ONCE at the top: date, worker/crew, method, start,
 *    finish, labour hours, hourly rate (where authorised), notes, linked Work
 *    Task. Switching the focused block never resets or duplicates these.
 *  * ALLOCATION level, per block: the rows and quarters pruned in THAT block,
 *    its row equivalents and its vine estimate.
 *
 * Every allocation mutation goes through [PruningAllocationEditor], so
 * selections in one block can never be lost by focusing another.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PruningActivityEditorScreen(
    paddocks: List<Paddock>,
    setups: List<PruningBlockSetup>,
    /** Active entries of the vineyard — the quarters already completed. */
    entries: List<PruningEntry>,
    workTasks: List<WorkTask>,
    canViewCosting: Boolean,
    initialDraft: PruningActivityDraft,
    isEditing: Boolean,
    /** Set when the last server answer refused quarters in this activity. */
    reconciliation: PruningActivityReconciliation? = null,
    onSave: (PruningActivityDraft) -> Unit,
    onReverse: (() -> Unit)? = null,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    var draft by remember(initialDraft.id) { mutableStateOf(initialDraft) }
    var showBlockPicker by rememberSaveable { mutableStateOf(false) }
    var showDatePicker by rememberSaveable { mutableStateOf(false) }
    var showDiscardPrompt by rememberSaveable { mutableStateOf(false) }
    var showReversePrompt by rememberSaveable { mutableStateOf(false) }
    var removePrompt by remember { mutableStateOf<String?>(null) }

    val isDirty = draft != initialDraft
    val leave: () -> Unit = { if (isDirty) showDiscardPrompt = true else onBack() }
    BackHandler(onBack = leave)

    val blocksById = remember(paddocks) { paddocks.associateBy { it.id } }
    val focusedId = draft.focusedPaddockId
    val focusedPaddock = focusedId?.let { blocksById[it] }

    /**
     * The rows of one block, always through the shared calculator so the grid,
     * the vine estimate and every report agree.
     */
    fun rowsOf(paddock: Paddock): List<PruningRowRef> =
        PruningCalculator.rowRefs(paddock, PruningSeasonSelection.setupFor(setups, paddock.id))

    /**
     * Quarters ALREADY completed in this block by another record. This
     * activity's own allocations are excluded, so editing keeps its quarters
     * selectable instead of showing them as locked.
     */
    fun lockedIn(paddock: Paddock): Set<PruningSegment> {
        val ownIds = draft.allocations.values.map { it.allocationIdFor(draft.id) }.toSet()
        val others = entries.filter { it.paddockId == paddock.id && it.id !in ownIds && !it.isReversed }
        return PruningCalculator.completedSegments(others, rowsOf(paddock))
    }

    /** Re-derives THIS block's vine estimate after any selection change. */
    fun withVines(next: PruningActivityDraft, paddockId: String): PruningActivityDraft {
        val paddock = blocksById[paddockId] ?: return next
        val allocation = next.allocations[paddockId] ?: return next
        val vines = PruningCalculator.vines(allocation.segments, rowsOf(paddock))
        return PruningAllocationEditor.setEstimatedVines(next, paddockId, vines)
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(if (isEditing) "Edit Pruning Activity" else "New Pruning Activity") },
                navigationIcon = { BackNavIcon(leave) },
                actions = {
                    if (isEditing && onReverse != null && !draft.isReversed) {
                        IconButton(onClick = { showReversePrompt = true }) {
                            Icon(
                                Icons.Filled.Delete,
                                contentDescription = "Reverse this activity",
                                tint = VineColors.Destructive,
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (reconciliation != null && reconciliation.activityId == draft.id) {
                item(key = "reconciliation") {
                    PruningReconciliationCard(
                        reconciliation = reconciliation,
                        blockNameOf = { blocksById[it]?.name ?: "Block" },
                        onOpenBlock = { paddockId ->
                            draft = PruningAllocationEditor.focus(
                                draft,
                                paddockId,
                                blocksById[paddockId]?.name.orEmpty(),
                            )
                        },
                    )
                }
            }

            // ACTIVITY level — exactly once, never per block.
            item(key = "activity") {
                PruningActivityFieldsCard(
                    draft = draft,
                    workTasks = workTasks,
                    canViewCosting = canViewCosting,
                    onDraftChange = { draft = it },
                    onPickDate = { showDatePicker = true },
                )
            }

            // Which blocks are in this activity.
            item(key = "blocks") {
                PruningActivityBlockStrip(
                    draft = draft,
                    blockNameOf = { blocksById[it]?.name ?: "Block" },
                    onFocus = { id ->
                        draft = PruningAllocationEditor.focus(draft, id, blocksById[id]?.name.orEmpty())
                    },
                    onAddBlock = { showBlockPicker = true },
                )
            }

            if (focusedPaddock == null) {
                item(key = "no-focus") {
                    PruningCard {
                        Column(
                            modifier = Modifier.padding(18.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                "Add a block to start",
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                            )
                            Text(
                                "Pick the first block this crew pruned, select the rows or quarters, then add another block if the same job covered more than one.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
            } else {
                val rows = rowsOf(focusedPaddock)
                val locked = lockedIn(focusedPaddock)
                val selected = draft.allocations[focusedPaddock.id]?.segments?.toSet().orEmpty()
                item(key = "focus-header-${focusedPaddock.id}") {
                    PruningFocusedBlockHeader(
                        paddock = focusedPaddock,
                        rows = rows,
                        selectedCount = selected.size,
                        conflicts = reconciliation?.conflicts(focusedPaddock.id).orEmpty().size,
                        onSelectRange = { from, to ->
                            val range = rows.filter { it.number in from..to }
                            val additions = range.flatMap { row -> (1..4).map { row.segment(it) } }
                                .filterNot { it in locked }
                            draft = withVines(
                                PruningAllocationEditor.setSegments(
                                    draft,
                                    focusedPaddock.id,
                                    (selected + additions).toList(),
                                    focusedPaddock.name,
                                ),
                                focusedPaddock.id,
                            )
                        },
                        onClearBlock = {
                            draft = withVines(
                                PruningAllocationEditor.setSegments(
                                    draft,
                                    focusedPaddock.id,
                                    emptyList(),
                                    focusedPaddock.name,
                                ),
                                focusedPaddock.id,
                            )
                        },
                        onRemoveBlock = { removePrompt = focusedPaddock.id },
                    )
                }
                if (rows.isEmpty()) {
                    item(key = "no-rows") {
                        PruningCard {
                            Text(
                                "${focusedPaddock.name} has no rows yet. Map its rows, or set a manual row count in the Pruning Tracker block setup, then record against it.",
                                fontSize = 12.sp,
                                color = VineColors.Warning,
                                modifier = Modifier.padding(14.dp),
                            )
                        }
                    }
                } else {
                    items(rows.size, key = { "row-${focusedPaddock.id}-${rows[it].key}" }) { index ->
                        val row = rows[index]
                        PruningEditorRowLine(
                            row = row,
                            locked = locked,
                            selected = selected,
                            onToggle = { segment ->
                                draft = withVines(
                                    PruningAllocationEditor.toggleSegment(
                                        draft,
                                        focusedPaddock.id,
                                        segment,
                                        focusedPaddock.name,
                                    ),
                                    focusedPaddock.id,
                                )
                            },
                            onToggleRow = {
                                val all = (1..4).map { row.segment(it) }.filterNot { it in locked }
                                val hasAll = all.isNotEmpty() && all.all { it in selected }
                                val next = if (hasAll) selected - all.toSet() else selected + all
                                draft = withVines(
                                    PruningAllocationEditor.setSegments(
                                        draft,
                                        focusedPaddock.id,
                                        next.toList(),
                                        focusedPaddock.name,
                                    ),
                                    focusedPaddock.id,
                                )
                            },
                        )
                    }
                }
            }

            // Combined summary — every block in this activity, before Save.
            item(key = "summary") {
                PruningActivitySummaryCard(
                    draft = draft,
                    blockNameOf = { blocksById[it]?.name ?: "Block" },
                    varietyOf = { blocksById[it]?.primaryVarietyName },
                    canViewCosting = canViewCosting,
                )
            }

            item(key = "save") {
                Button(
                    onClick = {
                        onSave(PruningAllocationEditor.pruneEmptyBlocks(draft))
                        onBack()
                    },
                    enabled = draft.canSave,
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = VineColors.Primary,
                        disabledContainerColor = vine.cardBorder,
                    ),
                ) {
                    Text(
                        if (isEditing) "Save changes" else "Record activity",
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (draft.canSave) Color.White else vine.textSecondary,
                    )
                }
            }
            item(key = "bottom") { Spacer(Modifier.height(24.dp)) }
        }

        if (showBlockPicker) {
            PruningActivityBlockPickerSheet(
                blocks = paddocks,
                draft = draft,
                onDismiss = { showBlockPicker = false },
                onSelect = { paddock ->
                    showBlockPicker = false
                    draft = PruningAllocationEditor.focus(draft, paddock.id, paddock.name)
                },
            )
        }

        if (showDatePicker) {
            val initialMillis = runCatching {
                LocalDate.parse(draft.date).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            }.getOrDefault(System.currentTimeMillis())
            val pickerState = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
            DatePickerDialog(
                onDismissRequest = { showDatePicker = false },
                confirmButton = {
                    TextButton(onClick = {
                        pickerState.selectedDateMillis?.let { millis ->
                            val picked = Instant.ofEpochMilli(millis).atZone(ZoneId.of("UTC")).toLocalDate()
                            // A date change re-resolves EVERY allocation's season
                            // server-side (sql/161 per allocation); the client
                            // simply carries the new date on the parent.
                            draft = draft.copy(date = picked.toString())
                        }
                        showDatePicker = false
                    }) { Text("OK") }
                },
                dismissButton = {
                    TextButton(onClick = { showDatePicker = false }) { Text("Cancel") }
                },
            ) {
                DatePicker(state = pickerState)
            }
        }

        removePrompt?.let { paddockId ->
            AlertDialog(
                onDismissRequest = { removePrompt = null },
                title = { Text("Remove ${blocksById[paddockId]?.name ?: "block"}?") },
                text = {
                    Text(
                        "Only this block's rows and quarters leave the activity. The crew, hours, times and notes stay exactly as they are.",
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        draft = PruningAllocationEditor.removeBlock(draft, paddockId)
                        removePrompt = null
                    }) { Text("Remove block", color = VineColors.Destructive) }
                },
                dismissButton = {
                    TextButton(onClick = { removePrompt = null }) { Text("Keep") }
                },
            )
        }

        if (showDiscardPrompt) {
            AlertDialog(
                onDismissRequest = { showDiscardPrompt = false },
                title = { Text("Discard changes?") },
                text = { Text("This activity has unsaved changes. Discarding loses every block selection made here.") },
                confirmButton = {
                    TextButton(onClick = {
                        showDiscardPrompt = false
                        onBack()
                    }) { Text("Discard", color = VineColors.Destructive) }
                },
                dismissButton = {
                    TextButton(onClick = { showDiscardPrompt = false }) { Text("Keep editing") }
                },
            )
        }

        if (showReversePrompt && onReverse != null) {
            AlertDialog(
                onDismissRequest = { showReversePrompt = false },
                title = { Text("Reverse this activity?") },
                text = {
                    Text(
                        "${draft.blockSummary} — all ${draft.totalQuarters} quarters in this activity will be reopened. " +
                            "The record stays visible as reversed audit history.",
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        showReversePrompt = false
                        onReverse()
                        onBack()
                    }) { Text("Reverse activity", color = VineColors.Destructive) }
                },
                dismissButton = {
                    TextButton(onClick = { showReversePrompt = false }) { Text("Cancel") }
                },
            )
        }
    }
}

// MARK: - Activity-level fields

/**
 * The parent activity's own fields. Rendered ONCE: labour, timing, rate, notes
 * and the Work Task link belong to the whole job and are never apportioned or
 * duplicated across blocks.
 */
@Composable
private fun PruningActivityFieldsCard(
    draft: PruningActivityDraft,
    workTasks: List<WorkTask>,
    canViewCosting: Boolean,
    onDraftChange: (PruningActivityDraft) -> Unit,
    onPickDate: () -> Unit,
) {
    val vine = LocalVineColors.current
    var methodOpen by remember { mutableStateOf(false) }
    var taskOpen by remember { mutableStateOf(false) }
    val dateLabel = remember(draft.date) {
        runCatching {
            LocalDate.parse(draft.date).format(DateTimeFormatter.ofPattern("d MMM yyyy"))
        }.getOrDefault(draft.date)
    }
    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("This activity", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(
                "Recorded once for the whole job — season ${draft.seasonYear}" +
                    (draft.vintageYear?.let { " · Vintage $it" } ?: ""),
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Date", fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.width(96.dp))
                Text(
                    dateLabel,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.Primary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(vine.cardBorder.copy(alpha = 0.5f))
                        .clickable(onClick = onPickDate)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }

            OutlinedTextField(
                value = draft.worker,
                onValueChange = { onDraftChange(draft.copy(worker = it)) },
                label = { Text("Worker or crew") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Method", fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.width(96.dp))
                Box {
                    Text(
                        PruningMethods.label(draft.method),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Primary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(vine.cardBorder.copy(alpha = 0.5f))
                            .clickable { methodOpen = true }
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                    DropdownMenu(expanded = methodOpen, onDismissRequest = { methodOpen = false }) {
                        PruningMethods.all.forEach { (key, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = {
                                    onDraftChange(draft.copy(method = key))
                                    methodOpen = false
                                },
                            )
                        }
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = draft.startTime.orEmpty(),
                    onValueChange = { onDraftChange(draft.copy(startTime = it.ifBlank { null })) },
                    label = { Text("Start") },
                    placeholder = { Text("07:30") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = draft.finishTime.orEmpty(),
                    onValueChange = { onDraftChange(draft.copy(finishTime = it.ifBlank { null })) },
                    label = { Text("Finish") },
                    placeholder = { Text("15:30") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = draft.labourHours?.let { fmt(it, 2) }.orEmpty(),
                    onValueChange = {
                        onDraftChange(draft.copy(labourHours = it.replace(',', '.').toDoubleOrNull()))
                    },
                    label = { Text("Labour hours") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                if (canViewCosting) {
                    OutlinedTextField(
                        value = draft.hourlyRate?.let { fmt(it, 2) }.orEmpty(),
                        onValueChange = {
                            onDraftChange(draft.copy(hourlyRate = it.replace(',', '.').toDoubleOrNull()))
                        },
                        label = { Text("Hourly rate") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            draft.durationHours?.let { hours ->
                Text(
                    "Elapsed ${fmt(hours, 1)} h" +
                        (draft.labourCost?.let { " · labour cost ${fmt(it, 2)} (whole activity)" } ?: ""),
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }

            OutlinedTextField(
                value = draft.notes,
                onValueChange = { onDraftChange(draft.copy(notes = it)) },
                label = { Text("Notes") },
                modifier = Modifier.fillMaxWidth(),
            )

            val linked = workTasks.firstOrNull { it.id == draft.workTaskId }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Work Task", fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.width(96.dp))
                Box(modifier = Modifier.weight(1f)) {
                    Text(
                        linked?.displayLabel ?: "Not linked",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (linked != null) VineColors.Primary else vine.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(vine.cardBorder.copy(alpha = 0.4f))
                            .clickable { taskOpen = true }
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                    DropdownMenu(expanded = taskOpen, onDismissRequest = { taskOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Not linked") },
                            onClick = {
                                onDraftChange(draft.copy(workTaskId = null))
                                taskOpen = false
                            },
                        )
                        workTasks.take(30).forEach { task ->
                            DropdownMenuItem(
                                text = { Text("${task.displayLabel} · ${task.date.orEmpty()}") },
                                onClick = {
                                    onDraftChange(draft.copy(workTaskId = task.id))
                                    taskOpen = false
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Included blocks

/** Chips for every block in the activity, with its quarter count, plus "Add another block". */
@Composable
private fun PruningActivityBlockStrip(
    draft: PruningActivityDraft,
    blockNameOf: (String) -> String,
    onFocus: (String) -> Unit,
    onAddBlock: () -> Unit,
) {
    val vine = LocalVineColors.current
    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Blocks", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Spacer(Modifier.weight(1f))
                OutlinedButton(onClick = onAddBlock) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp), tint = VineColors.Primary)
                    Spacer(Modifier.width(4.dp))
                    Text("Add another block", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                }
            }
            if (draft.allocations.isEmpty()) {
                Text("No blocks in this activity yet.", fontSize = 12.sp, color = vine.textSecondary)
            } else {
                draft.allocations.values.sortedBy { it.paddockId }.forEach { allocation ->
                    val isFocused = allocation.paddockId == draft.focusedPaddockId
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(
                                if (isFocused) VineColors.Primary.copy(alpha = 0.12f)
                                else vine.cardBorder.copy(alpha = 0.35f)
                            )
                            .clickable { onFocus(allocation.paddockId) }
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        if (!allocation.isEmpty) {
                            Icon(
                                Icons.Filled.CheckCircle,
                                contentDescription = "Included in this activity",
                                tint = VineColors.LeafGreen,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                        Text(
                            allocation.blockName.ifBlank { blockNameOf(allocation.paddockId) },
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            if (allocation.isEmpty) "Nothing selected" else
                                "${allocation.quarters} q · ${fmt(allocation.rowEquivalents)} rows",
                            fontSize = 12.sp,
                            color = if (allocation.isEmpty) VineColors.Warning else vine.textSecondary,
                        )
                    }
                }
            }
        }
    }
}

/**
 * Searchable chooser listing EVERY active block in the vineyard, with a
 * selected-state badge for the blocks already included in this activity.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PruningActivityBlockPickerSheet(
    blocks: List<Paddock>,
    draft: PruningActivityDraft,
    onDismiss: () -> Unit,
    onSelect: (Paddock) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf("") }
    val results = remember(blocks, query) {
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) blocks else blocks.filter {
            it.name.lowercase().contains(needle) ||
                it.primaryVarietyName?.lowercase()?.contains(needle) == true
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Add a block", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search blocks or varieties") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            if (results.isEmpty()) {
                Text("No blocks match \"$query\".", fontSize = 13.sp, color = vine.textSecondary)
            }
            LazyColumn(
                modifier = Modifier.fillMaxWidth().height(360.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(results.size, key = { results[it].id }) { index ->
                    val paddock = results[index]
                    val allocation = draft.allocations[paddock.id]
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(paddock) }
                            .padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(paddock.name, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            paddock.primaryVarietyName?.takeIf { it.isNotBlank() }?.let {
                                Text(it, fontSize = 12.sp, color = vine.textSecondary)
                            }
                        }
                        if (allocation != null) {
                            Text(
                                if (allocation.isEmpty) "In activity" else "In activity · ${allocation.quarters} q",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.LeafGreen,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(VineColors.LeafGreen.copy(alpha = 0.14f))
                                    .padding(horizontal = 8.dp, vertical = 4.dp),
                            )
                        }
                    }
                    HorizontalDivider(color = vine.cardBorder)
                }
            }
        }
    }
}

// MARK: - Focused block

@Composable
private fun PruningFocusedBlockHeader(
    paddock: Paddock,
    rows: List<PruningRowRef>,
    selectedCount: Int,
    conflicts: Int,
    onSelectRange: (Int, Int) -> Unit,
    onClearBlock: () -> Unit,
    onRemoveBlock: () -> Unit,
) {
    val vine = LocalVineColors.current
    var fromIndex by remember(paddock.id, rows.size) { mutableStateOf(0) }
    var toIndex by remember(paddock.id, rows.size) { mutableStateOf(rows.lastIndex.coerceAtLeast(0)) }
    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(paddock.name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    Text(
                        listOfNotNull(
                            paddock.primaryVarietyName?.takeIf { it.isNotBlank() },
                            "$selectedCount quarters selected",
                        ).joinToString(" · "),
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
                IconButton(onClick = onRemoveBlock) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "Remove ${paddock.name} from this activity",
                        tint = VineColors.Destructive,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            if (conflicts > 0) {
                Text(
                    "$conflicts quarter(s) here were already recorded by another activity and were not counted.",
                    fontSize = 11.sp,
                    color = VineColors.Warning,
                )
            }
            if (rows.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Rows", fontSize = 12.sp, color = vine.textSecondary)
                    PruningRowNumberPicker(fromIndex, rows) { fromIndex = it }
                    Text("to", fontSize = 12.sp, color = vine.textSecondary)
                    PruningRowNumberPicker(toIndex, rows) { toIndex = it }
                    Spacer(Modifier.weight(1f))
                    OutlinedButton(onClick = {
                        val a = rows.getOrNull(fromIndex)?.number ?: return@OutlinedButton
                        val b = rows.getOrNull(toIndex)?.number ?: return@OutlinedButton
                        onSelectRange(minOf(a, b), maxOf(a, b))
                    }) {
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
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onClearBlock) {
                    Text("Clear this block", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                }
                TextButton(onClick = onRemoveBlock) {
                    Text(
                        "Remove block from activity",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Destructive,
                    )
                }
            }
        }
    }
}

@Composable
private fun PruningRowNumberPicker(valueIndex: Int, rows: List<PruningRowRef>, onChange: (Int) -> Unit) {
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

/** One row of the focused block's quarter grid. */
@Composable
private fun PruningEditorRowLine(
    row: PruningRowRef,
    locked: Set<PruningSegment>,
    selected: Set<PruningSegment>,
    onToggle: (PruningSegment) -> Unit,
    onToggleRow: () -> Unit,
) {
    val vine = LocalVineColors.current
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
                val isLocked = locked.contains(segment)
                val isSelected = selected.contains(segment)
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(28.dp)
                        .clip(RoundedCornerShape(5.dp))
                        .background(
                            when {
                                isLocked -> VineColors.LeafGreen
                                isSelected -> VineColors.Primary
                                else -> vine.cardBorder.copy(alpha = 0.6f)
                            }
                        )
                        .then(if (!isLocked) Modifier.clickable { onToggle(segment) } else Modifier),
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        isLocked -> Icon(
                            Icons.Filled.Check,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(12.dp),
                        )
                        isSelected -> Icon(
                            Icons.Filled.ContentCut,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(11.dp),
                        )
                    }
                }
            }
        }
        IconButton(onClick = onToggleRow, modifier = Modifier.size(28.dp)) {
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = "Select all of row ${row.label}",
                tint = vine.textSecondary.copy(alpha = 0.5f),
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

// MARK: - Summary + reconciliation

/**
 * Everything the activity will save, per block AND combined. Labour appears in
 * the combined line only — never repeated per block, so no total can count it
 * twice.
 */
@Composable
private fun PruningActivitySummaryCard(
    draft: PruningActivityDraft,
    blockNameOf: (String) -> String,
    varietyOf: (String) -> String?,
    canViewCosting: Boolean,
) {
    val vine = LocalVineColors.current
    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Activity summary", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            if (draft.activeAllocations.isEmpty()) {
                Text(
                    "Select at least one quarter in one block to save this activity.",
                    fontSize = 12.sp,
                    color = VineColors.Warning,
                )
            }
            draft.activeAllocations.forEach { allocation ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row {
                        Text(
                            allocation.blockName.ifBlank { blockNameOf(allocation.paddockId) },
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            "${fmt(allocation.rowEquivalents)} rows",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                    }
                    Text(
                        listOfNotNull(
                            varietyOf(allocation.paddockId)?.takeIf { it.isNotBlank() },
                            "Rows ${PruningActivityListing.rowRangeLabel(allocation.rows)}",
                            "${allocation.quarters} quarters",
                            "${allocation.estimatedVines} vines",
                        ).joinToString(" · "),
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
                HorizontalDivider(color = vine.cardBorder)
            }
            Row {
                Text(
                    PruningActivityListing.blockLabel(draft.activeAllocations.map { it.blockName }),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = vine.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "${fmt(draft.totalRowEquivalents)} rows total",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = VineColors.Primary,
                )
            }
            Text(
                listOfNotNull(
                    "${draft.blockCount} block(s)",
                    "${draft.totalQuarters} quarters",
                    "${draft.totalEstimatedVines} vines",
                    draft.labourHours?.let { "${fmt(it, 1)} labour h (whole activity)" },
                    draft.labourCost?.takeIf { canViewCosting }?.let { "cost ${fmt(it, 2)}" },
                ).joinToString(" · "),
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
    }
}

/**
 * The server's reconciliation of the last save. A save with refused quarters is
 * never presented as fully successful: the user is told exactly what landed and
 * can open the affected block to review the conflicting quarters.
 */
@Composable
internal fun PruningReconciliationCard(
    reconciliation: PruningActivityReconciliation,
    blockNameOf: (String) -> String,
    onOpenBlock: ((String) -> Unit)? = null,
    onDismiss: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val tint = if (reconciliation.hasConflicts) VineColors.Warning else VineColors.LeafGreen
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(tint.copy(alpha = 0.12f))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(
                if (reconciliation.hasConflicts) Icons.Filled.ContentCut else Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(18.dp),
            )
            Text(
                reconciliation.headline,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
                modifier = Modifier.weight(1f),
            )
            if (onDismiss != null) {
                TextButton(onClick = onDismiss) {
                    Text("Dismiss", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                }
            }
        }
        Text(reconciliation.detail, fontSize = 12.sp, color = vine.textSecondary)
        reconciliation.seasonYear?.let { season ->
            Text(
                "Filed under $season Winter Pruning" +
                    (reconciliation.vintageYear?.let { " · Vintage $it" } ?: ""),
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
        if (reconciliation.hasConflicts && onOpenBlock != null) {
            reconciliation.conflictBlockIds.forEach { paddockId ->
                val quarters = reconciliation.conflicts(paddockId)
                TextButton(onClick = { onOpenBlock(paddockId) }) {
                    Text(
                        "Review ${blockNameOf(paddockId)} (${quarters.size}): ${quarters.take(4).joinToString(", ") { it.label }}" +
                            if (quarters.size > 4) "…" else "",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Primary,
                    )
                }
            }
        }
    }
}
