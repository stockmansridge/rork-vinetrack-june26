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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.OpenInNew
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
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
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
import com.rork.vinetrack.data.PruningActivityTaskLink
import com.rork.vinetrack.data.PruningWorkTaskLinkDraft
import com.rork.vinetrack.data.WorkTaskLabourCosting
import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PieceRateCosting
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
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.formatLabourCurrency
import com.rork.vinetrack.ui.components.formatLabourHours
import com.rork.vinetrack.ui.LocalRegionFormatter
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
 *    finish, operational duration, notes, linked Work Task. Switching the
 *    focused block never resets or duplicates these.
 *  * ALLOCATION level, per block: the rows and quarters pruned in THAT block,
 *    its row equivalents and its vine estimate.
 *  * WORK TASK level, in the linked task: labour type, hourly rate, number of
 *    people, hours per person, person-hours and labour cost. The activity NO
 *    LONGER offers a standalone editable hourly rate — [WorkTaskLabourCosting]
 *    resolves cost from the linked task's labour lines, falling back to a
 *    historical activity rate only for legacy records.
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
    /**
     * Live labour lines of the LINKED Work Task — the authoritative source of
     * person-hours and labour cost for this activity.
     */
    labourLines: List<WorkTaskLabourLine>,
    canViewCosting: Boolean,
    /**
     * Labour types of this vineyard, so the create flow offers the SAME saved
     * worker types and rates the Work Task editor does.
     */
    operatorCategories: List<OperatorCategory> = emptyList(),
    /** Supervisors and above — may agree a piece rate in the field. */
    canEnterPricing: Boolean = false,
    initialDraft: PruningActivityDraft,
    isEditing: Boolean,
    /** Set when the last server answer refused quarters in this activity. */
    reconciliation: PruningActivityReconciliation? = null,
    onSave: (PruningActivityDraft) -> Unit,
    onReverse: (() -> Unit)? = null,
    /**
     * Creates ONE Work Task for the whole activity and returns its canonical
     * client id, or null when the task could not be created. Offline the task
     * is queued with that same id, and the activity push waits for it.
     */
    onCreateWorkTask: ((PruningActivityDraft, PruningWorkTaskLinkDraft) -> String?)? = null,
    /**
     * Opens the linked Work Task in place. Rendered INSIDE this screen, so the
     * draft — every block and quarter selection — survives the round trip.
     */
    workTaskDetail: (@Composable (taskId: String, onClose: () -> Unit) -> Unit)? = null,
    /**
     * sql/200: persists a task-side link change (taskId, activityId-or-null).
     * Costs live on WORK TASKS; this activity only DERIVES from linked tasks.
     */
    onSetTaskLink: ((String, String?) -> Unit)? = null,
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
    var showTaskPicker by rememberSaveable { mutableStateOf(false) }
    var taskCreateDraft by remember { mutableStateOf<PruningWorkTaskLinkDraft?>(null) }
    var openTaskId by rememberSaveable { mutableStateOf<String?>(null) }

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

    // The linked Work Task opens IN PLACE. `draft` is remembered above this
    // branch, so opening the task and coming back cannot lose a single block or
    // quarter selection.
    val detail = workTaskDetail
    val detailTaskId = openTaskId
    if (detailTaskId != null && detail != null) {
        BackHandler { openTaskId = null }
        detail(detailTaskId) { openTaskId = null }
        return
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
                    canViewCosting = canViewCosting,
                    onDraftChange = { draft = it },
                    onPickDate = { showDatePicker = true },
                )
            }

            // Which blocks are in this activity. Blocks and rows come BEFORE
            // labour: the piece-rate vine count is derived from this selection,
            // so a job can only be costed once the operator has chosen what was
            // worked.
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

            // Labour & Work Task — ALSO activity level. One link on the parent,
            // never one per block. Placed AFTER the blocks so the piece-rate
            // quantity can be derived from the rows already chosen.
            item(key = "work-task") {
                PruningActivityWorkTaskCard(
                    draft = draft,
                    workTasks = workTasks,
                    labourLines = labourLines,
                    canViewCosting = canViewCosting,
                    canCreate = onCreateWorkTask != null,
                    onLinkExisting = { showTaskPicker = true },
                    onCreate = { taskCreateDraft = PruningActivityTaskLink.createDraft(draft) },
                    onOpenTask = { openTaskId = it },
                    canOpen = workTaskDetail != null,
                    onUnlinkTask = { task ->
                        // Both records survive an unlink: the task remains a
                        // standalone cost record; the activity stops deriving
                        // from it. The legacy mirror promotes to the next task.
                        onSetTaskLink?.invoke(task.id, null)
                        if (draft.workTaskId == task.id) {
                            val remaining = PruningActivityTaskLink
                                .linkedTasks(draft, workTasks)
                                .filter { it.id != task.id && it.pruningActivityId == draft.id }
                            draft = draft.copy(workTaskId = remaining.firstOrNull()?.id)
                        }
                    },
                    onUnlinkMissing = { draft = PruningActivityTaskLink.unlink(draft) },
                )
            }

            // Combined summary — every block in this activity, before Save.
            item(key = "summary") {
                PruningActivitySummaryCard(
                    draft = draft,
                    blockNameOf = { blocksById[it]?.name ?: "Block" },
                    varietyOf = { blocksById[it]?.primaryVarietyName },
                    workTasks = workTasks,
                    labourLines = labourLines,
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

        if (showTaskPicker) {
            PruningWorkTaskPickerSheet(
                tasks = workTasks,
                linkedId = draft.workTaskId,
                onDismiss = { showTaskPicker = false },
                onSelect = { task ->
                    showTaskPicker = false
                    // sql/200: persist the task-side origin link; the legacy
                    // mirror fills only when empty. Allocations are untouched.
                    onSetTaskLink?.invoke(task.id, draft.id)
                    if (draft.workTaskId == null) {
                        draft = PruningActivityTaskLink.link(draft, task.id)
                    }
                },
            )
        }

        taskCreateDraft?.let { pending ->
            // Hectares under this activity's blocks — the denominator for cost/ha.
            val activityHectares = remember(draft, blocksById) {
                PruningActivityTaskLink.paddockIds(draft)
                    .mapNotNull { blocksById[it]?.areaHectares }
                    .sum()
                    .takeIf { it > 0.0 }
            }
            PruningWorkTaskCreateDialog(
                draft = draft,
                task = pending,
                operatorCategories = operatorCategories,
                canViewCosting = canViewCosting,
                canEnterPricing = canEnterPricing,
                hectares = activityHectares,
                onChange = { taskCreateDraft = it },
                onDismiss = { taskCreateDraft = null },
                onConfirm = {
                    // The LIVE draft is passed, so the task's date, hours and
                    // blocks match what the operator is actually recording.
                    val created = onCreateWorkTask?.invoke(draft, pending)
                    if (created != null && draft.workTaskId == null) {
                        // First task also fills the legacy mirror (sql/200);
                        // the task-side origin link is written by the creator.
                        draft = PruningActivityTaskLink.link(draft, created)
                    }
                    taskCreateDraft = null
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
 * The parent activity's own OPERATIONAL fields. Rendered ONCE: date, crew,
 * method, start/finish, operational duration and notes belong to the whole job
 * and are never apportioned or duplicated across blocks.
 *
 * There is deliberately NO editable hourly rate here. Rate, people, hours per
 * person and cost live on the linked Work Task's labour lines, so there is only
 * ever one authoritative rate. A historical activity rate is still shown
 * read-only, clearly labelled as legacy.
 */
@Composable
private fun PruningActivityFieldsCard(
    draft: PruningActivityDraft,
    canViewCosting: Boolean,
    onDraftChange: (PruningActivityDraft) -> Unit,
    onPickDate: () -> Unit,
) {
    val vine = LocalVineColors.current
    var methodOpen by remember { mutableStateOf(false) }
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

            draft.durationHours?.let { hours ->
                Text(
                    "Elapsed ${fmt(hours, 1)} h between start and finish — not multiplied by the crew size.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
            // LEGACY ONLY, read-only: activities recorded before the Work Task
            // repair carry their own hours/rate. Never editable and never
            // combined with Work Task totals — costs are edited on Work Tasks.
            if (draft.labourHours != null || (canViewCosting && draft.hourlyRate != null)) {
                Text(
                    listOfNotNull(
                        draft.labourHours?.let { "${fmt(it, 1)} h" },
                        draft.hourlyRate?.takeIf { canViewCosting }?.let { "${fmt(it, 2)}/h" },
                        draft.labourCost?.takeIf { canViewCosting }?.let { "${fmt(it, 2)} recorded" },
                    ).joinToString(" · ", prefix = "Legacy labour record: ") +
                        " — read-only. Costs now live on the linked Work Tasks.",
                    fontSize = 11.sp,
                    color = VineColors.Warning,
                )
            }

            OutlinedTextField(
                value = draft.notes,
                onValueChange = { onDraftChange(draft.copy(notes = it)) },
                label = { Text("Notes") },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

// MARK: - Work Task (activity level)

/**
 * The activity's Work Task link AND its labour. ONE link on the parent draft
 * ([PruningActivityDraft.workTaskId]) — never a copy on any
 * `BlockPruningSelection` — with the full workflow the single-block editor had:
 * create a task for this job, link an existing one, open the linked task, or
 * unlink it. Every action only rewrites the parent's link, so block and quarter
 * selections survive untouched.
 *
 * The linked tasks' labour lines are the AUTHORITATIVE labour record: task
 * title, status, total person-hours, total labour cost (subject to costing
 * permission). Costs are edited INSIDE each Work Task (sql/200) — never on
 * the activity.
 */
@Composable
private fun PruningActivityWorkTaskCard(
    draft: PruningActivityDraft,
    workTasks: List<WorkTask>,
    labourLines: List<WorkTaskLabourLine>,
    canViewCosting: Boolean,
    canCreate: Boolean,
    canOpen: Boolean,
    onLinkExisting: () -> Unit,
    onCreate: () -> Unit,
    onOpenTask: (String) -> Unit,
    onUnlinkTask: (WorkTask) -> Unit,
    onUnlinkMissing: () -> Unit,
) {
    val vine = LocalVineColors.current
    // sql/200: EVERY linked task — task-side origin links plus the legacy
    // activity-side mirror, de-duplicated, in date order.
    val linkedAll = PruningActivityTaskLink.linkedTasks(draft, workTasks)
    val unresolvable = PruningActivityTaskLink.hasUnresolvableLink(draft, workTasks)
    val linesByTask = remember(labourLines) { PruningActivityTaskLink.linesByTask(labourLines) }
    val aggregate = remember(linkedAll, linesByTask) {
        PruningActivityTaskLink.aggregate(linkedAll, linesByTask)
    }
    PruningCard {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Work Tasks", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Spacer(Modifier.weight(1f))
                if (linkedAll.isNotEmpty() || unresolvable) {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = if (unresolvable && linkedAll.isEmpty()) VineColors.Warning else VineColors.LeafGreen,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
            Text(
                "Costs live on Work Tasks — add one per crew or cost arrangement. " +
                    "This activity derives its labour hours and total cost from the tasks linked here.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )

            if (linkedAll.isEmpty() && !unresolvable) {
                Text("No cost recorded", fontSize = 13.sp, color = vine.textSecondary)
            }
            if (linkedAll.isEmpty() && unresolvable) {
                // NEVER cleared silently: the link is real server state that
                // this device simply hasn't pulled yet.
                Text(
                    "This activity is linked to a Work Task that hasn't reached this device yet. It stays linked — pull to refresh, or unlink deliberately.",
                    fontSize = 12.sp,
                    color = VineColors.Warning,
                )
                TextButton(onClick = onUnlinkMissing) {
                    Text("Unlink missing task", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Destructive)
                }
            }
            linkedAll.forEach { task ->
                val lines = linesByTask[task.id].orEmpty()
                val totals = WorkTaskLabourCosting.totals(lines)
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(VineColors.LeafGreen.copy(alpha = 0.10f))
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        task.displayLabel,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    Text(
                        listOfNotNull(
                            task.date?.takeIf { it.isNotBlank() }?.take(10),
                            task.paddockName?.takeIf { it.isNotBlank() },
                            if (task.isComplete) "Completed" else "To do",
                        ).joinToString(" · "),
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                    // The task's CANONICAL labour summary, under its chosen
                    // costing method — piece-rate and hourly never combined.
                    if (task.isPieceRate) {
                        Text(
                            pieceRateSummaryLabel(task, totals.personHours, canViewCosting),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                    } else {
                        Text(
                            listOfNotNull(
                                "${formatLabourHours(totals.personHours)} h",
                                totals.cost
                                    ?.takeIf { canViewCosting }
                                    ?.let { formatLabourCurrency(it) },
                                "${totals.lineCount} labour line${if (totals.lineCount == 1) "" else "s"}",
                            ).joinToString(" · "),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (totals.isEmpty) VineColors.Warning else vine.textPrimary,
                        )
                        if (totals.isEmpty) {
                            Text(
                                "No labour recorded yet — open the task to add labour lines.",
                                fontSize = 11.sp,
                                color = VineColors.Warning,
                            )
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (canOpen) {
                            TextButton(onClick = { onOpenTask(task.id) }) {
                                Text("Open", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                            }
                        }
                        TextButton(onClick = { onUnlinkTask(task) }) {
                            Text("Unlink", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Destructive)
                        }
                    }
                }
            }
            if (!aggregate.isEmpty) {
                // "2 Work Tasks · 22.0 labour hours · $810.00 total" — DERIVED.
                Text(
                    listOfNotNull(
                        "${aggregate.taskCount} Work Task${if (aggregate.taskCount == 1) "" else "s"}",
                        aggregate.hours?.let { "${formatLabourHours(it)} labour hours" },
                        if (canViewCosting) {
                            aggregate.cost?.let { "${formatLabourCurrency(it)} total" } ?: "cost not specified"
                        } else {
                            null
                        },
                    ).joinToString(" · ") + ". Edit costs inside each Work Task — this activity updates automatically.",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (canCreate) {
                    Button(
                        onClick = onCreate,
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                    ) {
                        Icon(
                            Icons.Filled.Add,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(15.dp),
                        )
                        Spacer(Modifier.width(5.dp))
                        Text("Add Work Task", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    }
                }
                OutlinedButton(onClick = onLinkExisting) {
                    Text(
                        "Link existing",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Primary,
                    )
                }
            }
            Text(
                "Unlinking keeps the Work Task as a standalone cost record — only this activity's link is removed.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
    }
}

/**
 * One-line summary of a PIECE-RATE job. The agreed rate is a commercial term,
 * so it is shown only to roles that may review pricing; everyone else sees the
 * operational quantity and hours.
 */
private fun pieceRateSummaryLabel(
    task: WorkTask,
    personHours: Double,
    canViewCosting: Boolean,
): String {
    val vines = task.pieceVineCount
    val rate = task.pieceRatePerVine
    val parts = mutableListOf<String>()
    if (canViewCosting && vines != null && rate != null) {
        parts += "${PieceRateCosting.vineCountLabel(vines)} vines × ${PieceRateCosting.rateLabel(rate)}"
        task.pieceRateCost?.let { parts += PieceRateCosting.currencyLabel(it) }
    } else if (vines != null && vines > 0) {
        parts += "${PieceRateCosting.vineCountLabel(vines)} vines priced per vine"
    }
    if (personHours > 0) parts += "${formatLabourHours(personHours)} recorded"
    return if (parts.isEmpty()) {
        "Piece rate · add the agreed rate per vine below."
    } else {
        "Piece rate · " + parts.joinToString(" · ")
    }
}

/** Searchable picker over EVERY live Work Task of the vineyard. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PruningWorkTaskPickerSheet(
    tasks: List<WorkTask>,
    linkedId: String?,
    onDismiss: () -> Unit,
    onSelect: (WorkTask) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf("") }
    val results = remember(tasks, query) { PruningActivityTaskLink.search(tasks, query) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Link a Work Task", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search by work type, block or date") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            if (results.isEmpty()) {
                Text(
                    if (query.isBlank()) "This vineyard has no Work Tasks yet." else "No tasks match \"$query\".",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
            }
            LazyColumn(
                modifier = Modifier.fillMaxWidth().height(360.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(results.size, key = { results[it].id }) { index ->
                    val task = results[index]
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(task) }
                            .padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                task.displayLabel,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                            )
                            Text(
                                listOfNotNull(
                                    task.date?.takeIf { it.isNotBlank() }?.take(10),
                                    task.paddockName?.takeIf { it.isNotBlank() },
                                    "${fmt(task.durationHours, 1)} h",
                                ).joinToString(" · "),
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                        if (task.id == linkedId) {
                            Icon(
                                Icons.Filled.CheckCircle,
                                contentDescription = "Currently linked",
                                tint = VineColors.LeafGreen,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                    HorizontalDivider(color = vine.cardBorder)
                }
            }
        }
    }
}

/**
 * Creates ONE COMPLETE Work Task for the whole activity — INCLUDING how it is
 * paid.
 *
 * Date, duration and blocks come from the activity itself, so the shared labour
 * is recorded once and never apportioned per block. The costing basis is agreed
 * HERE, in this one flow: the user chooses Hourly or Piece Rate, enters the
 * figures, sees the calculated cost, and only then creates the task. Nothing is
 * left to a second edit on another screen.
 *
 * The Kotlin twin of the Swift `PruningWorkTaskCreateSheet`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PruningWorkTaskCreateDialog(
    draft: PruningActivityDraft,
    task: PruningWorkTaskLinkDraft,
    operatorCategories: List<OperatorCategory>,
    canViewCosting: Boolean,
    canEnterPricing: Boolean,
    hectares: Double?,
    onChange: (PruningWorkTaskLinkDraft) -> Unit,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val vine = LocalVineColors.current
    // Named `region` because this file already has a private `fmt(value, decimals)` helper.
    val region = LocalRegionFormatter.current
    var showIssues by remember { mutableStateOf(false) }
    var hoursText by remember { mutableStateOf(task.hoursPerWorker?.let { fmt(it, 2) } ?: "") }
    var rateText by remember { mutableStateOf(task.hourlyRate?.let { fmt(it, 2) } ?: "") }
    var ratePerVineText by remember { mutableStateOf(task.ratePerVine?.let { fmt(it, 2) } ?: "") }
    var typeMenuOpen by remember { mutableStateOf(false) }

    val categories = remember(operatorCategories) {
        operatorCategories.filter { it.deletedAt == null }.sortedBy { it.displayName.lowercase() }
    }
    val pieceIssues = PieceRateCosting.validate(task.ratePerVine, task.vineCount)
    val rateIssue = if (showIssues) {
        PieceRateCosting.message(pieceIssues, PieceRateCosting.PieceRateField.RATE_PER_VINE)
    } else {
        null
    }
    val cost = task.estimatedCost
    val costPerHa = PieceRateCosting.costPerHectare(cost, hectares)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Create Work Task") },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Text(
                    "One task for this whole activity: ${draft.date} · " +
                        draft.blockSummary.ifBlank { "no blocks yet" } +
                        ". Linked with a stable id, so an offline retry can never create a second task.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                OutlinedTextField(
                    value = task.taskType,
                    onValueChange = { onChange(task.copy(taskType = it)) },
                    label = { Text("Work type") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = task.notes,
                    onValueChange = { onChange(task.copy(notes = it)) },
                    label = { Text("Task notes") },
                    modifier = Modifier.fillMaxWidth(),
                )

                // THE single switch between the two costing methods (sql/188),
                // offered BEFORE any figure is entered so nobody fills in the
                // wrong basis.
                if (canEnterPricing) {
                    Text(
                        "How is this job paid?",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                        WorkTaskCostingMethod.entries.forEachIndexed { index, method ->
                            SegmentedButton(
                                selected = task.costingMethod == method,
                                onClick = { onChange(task.copy(costingMethod = method)) },
                                shape = SegmentedButtonDefaults.itemShape(
                                    index = index,
                                    count = WorkTaskCostingMethod.entries.size,
                                ),
                            ) {
                                Text(method.label, fontSize = 12.sp)
                            }
                        }
                    }
                    Text(
                        if (task.isPieceRate) {
                            "Paid per vine. The agreed rate is multiplied by the vines in the quarters selected for this activity — hours never change a piece-rate cost."
                        } else {
                            "Paid per hour. People × hours per person × hourly rate."
                        },
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }

                if (task.isPieceRate) {
                    // The agreed rate, and the quantity it applies to — the
                    // activity's OWN vine total, so the operator confirms a
                    // number rather than counting one.
                    OutlinedTextField(
                        value = ratePerVineText,
                        onValueChange = {
                            ratePerVineText = it
                            onChange(task.copy(ratePerVine = parsePruningDecimal(it)))
                        },
                        label = { Text("Rate per vine") },
                        prefix = { Text("$") },
                        singleLine = true,
                        isError = rateIssue != null,
                        supportingText = rateIssue?.let { { Text(it, color = VineColors.Destructive) } },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    PruningCostingRow(
                        "Rows selected",
                        "${draft.blockCount} block(s) · ${draft.totalQuarters} quarters",
                    )
                    PruningCostingRow(
                        "Vines in this job",
                        PieceRateCosting.vineCountLabel(task.vineCount),
                        emphasise = true,
                    )
                    Text(
                        "Counted automatically from the quarters selected above — each row's own vine count, or your manual count where you set one. A row with two of its four quarters selected counts half its vines.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                } else {
                    // The STANDARD hourly labour inputs — the same fields,
                    // defaults and arithmetic as an ordinary Work Task labour
                    // line, so this flow writes a real labour line rather than
                    // inventing a second hourly calculation.
                    Box {
                        OutlinedButton(
                            onClick = { typeMenuOpen = true },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                task.workerType.ifBlank { "Choose labour type" },
                                fontSize = 13.sp,
                                color = if (task.workerType.isBlank()) vine.textSecondary else vine.textPrimary,
                            )
                        }
                        DropdownMenu(expanded = typeMenuOpen, onDismissRequest = { typeMenuOpen = false }) {
                            categories.forEach { category ->
                                val savedRate = WorkTaskLabourCosting.defaultRate(category)
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            if (canViewCosting && savedRate != null) {
                                                "${category.displayName} · ${PieceRateCosting.rateLabel(savedRate)}/h"
                                            } else {
                                                category.displayName
                                            },
                                        )
                                    },
                                    onClick = {
                                        typeMenuOpen = false
                                        // The labour type's saved rate is the
                                        // DEFAULT; an explicit edit is never
                                        // overwritten.
                                        val applyRate = savedRate != null && rateText.isBlank()
                                        if (applyRate) rateText = fmt(savedRate, 2)
                                        onChange(
                                            task.copy(
                                                operatorCategoryId = category.id,
                                                workerType = category.displayName,
                                                hourlyRate = if (applyRate) savedRate else task.hourlyRate,
                                            ),
                                        )
                                    },
                                )
                            }
                            if (categories.isEmpty()) {
                                DropdownMenuItem(
                                    text = { Text("Add labour types in Settings → Worker Types") },
                                    onClick = { typeMenuOpen = false },
                                )
                            }
                        }
                    }
                    OutlinedTextField(
                        value = task.workerCount.toString(),
                        onValueChange = {
                            onChange(task.copy(workerCount = it.filter { c -> c.isDigit() }.toIntOrNull() ?: 0))
                        },
                        label = { Text("Number of people") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = hoursText,
                        onValueChange = {
                            hoursText = it
                            onChange(task.copy(hoursPerWorker = parsePruningDecimal(it)))
                        },
                        label = { Text("Hours per person") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (canViewCosting) {
                        OutlinedTextField(
                            value = rateText,
                            onValueChange = {
                                rateText = it
                                onChange(task.copy(hourlyRate = parsePruningDecimal(it)))
                            },
                            label = { Text("Hourly rate") },
                            prefix = { Text("$") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    Text(
                        "Hours per person — not the whole crew's combined total. Leave the hours blank to create the task now and record the crew's hours later.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }

                // The calculated cost, BEFORE Create. Nobody should have to
                // create a task to discover what it costs.
                HorizontalDivider(color = vine.cardBorder)
                if (task.isPieceRate) {
                    PruningCostingRow(
                        "Calculation",
                        "${PieceRateCosting.vineCountLabel(task.vineCount)} × " +
                            PieceRateCosting.rateLabel(task.ratePerVine ?: 0.0),
                    )
                } else {
                    PruningCostingRow("Person-hours", "${fmt(task.personHours, 1)} h")
                }
                PruningCostingRow(
                    "Estimated labour cost",
                    cost?.let { PieceRateCosting.currencyLabel(it) } ?: "Not specified",
                    emphasise = true,
                    tint = if (cost == null) vine.textSecondary else VineColors.LeafGreen,
                )
                if (costPerHa != null) {
                    // `costPerHectare` is canonical per-hectare, so an acre vineyard
                    // must see the cost re-based, not a per-hectare figure relabelled.
                    PruningCostingRow(
                        "Cost per ${region.areaUnitAbbreviation}",
                        region.formatCostPerArea(costPerHa),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    showIssues = true
                    if (task.isValid) onConfirm()
                },
                enabled = task.trimmedType.isNotEmpty(),
            ) {
                Text(
                    "Create and link",
                    color = if (task.trimmedType.isNotEmpty()) VineColors.Primary else vine.textSecondary,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/** One label/value line in the create dialog's costing preview. */
@Composable
private fun PruningCostingRow(
    label: String,
    value: String,
    emphasise: Boolean = false,
    tint: Color? = null,
) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(label, fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
        Text(
            value,
            fontSize = if (emphasise) 14.sp else 12.sp,
            fontWeight = if (emphasise) FontWeight.Bold else FontWeight.SemiBold,
            color = tint ?: vine.textPrimary,
        )
    }
}

/** Lenient decimal parse — accepts a comma decimal mark, rejects nonsense. */
private fun parsePruningDecimal(text: String): Double? =
    text.trim().replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() }

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
    workTasks: List<WorkTask>,
    labourLines: List<WorkTaskLabourLine>,
    canViewCosting: Boolean,
) {
    val vine = LocalVineColors.current
    val linkedTask = remember(workTasks, draft.workTaskId) {
        PruningActivityTaskLink.linkedTask(draft, workTasks)
    }
    // sql/200: EVERY linked task — task-side origin links plus the legacy
    // mirror. With more than one, the summary shows the DERIVED aggregate of
    // all of them, never just the primary/mirror task.
    val linkedTasks = remember(workTasks, draft.id, draft.workTaskId) {
        PruningActivityTaskLink.linkedTasks(draft, workTasks)
    }
    val multiTaskAggregate = remember(linkedTasks, labourLines) {
        if (linkedTasks.size > 1) {
            PruningActivityTaskLink.aggregate(
                linkedTasks,
                PruningActivityTaskLink.linesByTask(labourLines),
            )
        } else {
            null
        }
    }
    // Labour is resolved with the task's COSTING METHOD applied first: a
    // piece-rate job is costed from its own snapshot (even with no labour lines
    // at all), an hourly job from its lines, and the historical activity value
    // is used ONLY for legacy records. They are mutually exclusive, so nothing
    // can be counted twice.
    val labour = remember(
        labourLines,
        linkedTask,
        draft.workTaskId,
        draft.labourHours,
        draft.hourlyRate,
        canViewCosting,
    ) {
        val taskLines = draft.workTaskId
            ?.let { id -> labourLines.filter { it.workTaskId == id && it.deletedAt == null } }
            .orEmpty()
        PieceRateCosting.resolveActivityLabour(
            task = linkedTask,
            lines = taskLines,
            legacyHours = draft.labourHours,
            legacyRate = draft.hourlyRate,
            includeCost = canViewCosting,
        )
    }
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
                ).joinToString(" · "),
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
            if (multiTaskAggregate != null) {
                // Multi-task activity: the combined figure — e.g.
                // "2 Work Tasks · 22 h person-hours · labour cost $810".
                Text(
                    listOfNotNull(
                        "${multiTaskAggregate.taskCount} Work Tasks",
                        multiTaskAggregate.hours?.let { "${formatLabourHours(it)} person-hours" },
                        multiTaskAggregate.cost?.takeIf { canViewCosting }
                            ?.let { "labour cost ${formatLabourCurrency(it)}" },
                    ).joinToString(" · ") + " — combined across every linked Work Task.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            } else Text(
                when (labour.source) {
                    // The piece-rate record IS the labour-cost record. Hours,
                    // when present, are operational only and never move it.
                    WorkTaskLabourCosting.LabourSource.PIECE_RATE -> listOfNotNull(
                        linkedTask?.pieceVineCount?.let { vines ->
                            linkedTask.pieceRatePerVine?.let { rate ->
                                "${PieceRateCosting.vineCountLabel(vines)} vines × " +
                                    "${PieceRateCosting.rateLabel(rate)} per vine"
                            }
                        },
                        labour.cost?.let { "labour cost ${PieceRateCosting.currencyLabel(it)}" },
                        labour.hours?.takeIf { it > 0 }?.let {
                            "${formatLabourHours(it)} person-hours recorded for productivity only"
                        },
                    ).joinToString(" · ").ifEmpty {
                        "Paid per vine — add the agreed rate per vine to cost this job."
                    }.let { if (it.startsWith("Paid")) it else "Piece rate · $it" }

                    WorkTaskLabourCosting.LabourSource.WORK_TASK_LINES -> listOfNotNull(
                        labour.hours?.let { "${formatLabourHours(it)} person-hours from the Work Task" },
                        labour.cost?.let { "labour cost ${formatLabourCurrency(it)}" },
                    ).joinToString(" · ").ifEmpty { "Labour recorded on the linked Work Task." }

                    WorkTaskLabourCosting.LabourSource.LEGACY_ACTIVITY -> listOfNotNull(
                        labour.hours?.let { "${formatLabourHours(it)} legacy activity hours" },
                        labour.cost?.let { "legacy cost ${formatLabourCurrency(it)}" },
                    ).joinToString(" · ") + " — add Work Task labour lines to replace it."

                    WorkTaskLabourCosting.LabourSource.NONE ->
                        "No labour recorded — link a Work Task and add labour lines to cost this job."
                },
                fontSize = 11.sp,
                color = if (labour.isLegacy) VineColors.Warning else vine.textSecondary,
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
