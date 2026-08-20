package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rork.vinetrack.data.PlanSprayJob
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceEventSource
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistancePlan
import com.rork.vinetrack.data.resistance.ResistancePlanChemicalSource
import com.rork.vinetrack.data.resistance.ResistancePlanPositionStatus
import com.rork.vinetrack.data.resistance.ResistancePlanRepository
import com.rork.vinetrack.data.resistance.ResistancePlanStore
import com.rork.vinetrack.data.resistance.ResistancePlanSyncState
import com.rork.vinetrack.data.resistance.ResistancePlanner
import com.rork.vinetrack.data.resistance.ResistancePlannerPosition
import com.rork.vinetrack.data.resistance.ResistancePlannerPresentation
import com.rork.vinetrack.data.resistance.ResistancePlannerSeasonChoice
import com.rork.vinetrack.data.resistance.ResistancePlannerUiState
import com.rork.vinetrack.data.resistance.ResistanceRulesets
import com.rork.vinetrack.data.resistance.ResistanceSeasonCalendar
import com.rork.vinetrack.data.resistance.SupabaseResistancePlanRemote
import com.rork.vinetrack.data.resistance.displayLabel
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Resistance Planner — the PLAN LIST first, then one plan's editor.
 *
 * Opening the Planner always lands on the list: every live plan for the selected
 * vineyard, filterable by season and disease. A vineyard may legitimately hold several
 * plans for the SAME season and disease (a trial-block plan, a "plan B"), so nothing
 * here ever auto-selects a plan — tapping a row opens the editor by stable
 * `resistance_plans.id`, and back always returns to this list.
 *
 * Every verdict in the editor comes from `ResistanceEngine` via [ResistancePlanner],
 * and every label comes from [ResistancePlannerPresentation]. This file lays out; it
 * never counts and never decides a status.
 *
 * Mirrors `ResistancePlannerView.swift` + `ResistancePlanEditorView.swift`.
 */
@Composable
fun ResistancePlannerScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val context = LocalContext.current

    // Server-authoritative with a local cache. The remote is attached only when Supabase
    // is configured; without it the repository degrades to a device-local cache rather
    // than failing, so the Planner still works for a signed-out or offline grower.
    val session = remember { SessionStore(context) }
    val planRepository = remember(session) {
        ResistancePlanRepository(
            local = ResistancePlanStore(context),
            remote = if (SupabaseClient.isConfigured) SupabaseResistancePlanRemote(session) else null,
            currentUserId = { session.userId },
        )
    }
    val plans by planRepository.plans.collectAsStateWithLifecycle()
    val syncState by planRepository.syncState.collectAsStateWithLifecycle()
    val conflicts by planRepository.conflicts.collectAsStateWithLifecycle()

    val vineyard = state.selectedVineyard
    val vineyardId = state.selectedVineyardId
    val jurisdiction = remember(vineyard?.country) {
        ResistanceJurisdiction.fromCountryCode(vineyard?.country)
    }
    val seasonCalendar = remember(state.seasonStartMonth, state.seasonStartDay, vineyard?.timezone) {
        ResistanceSeasonCalendar(
            startMonth = state.seasonStartMonth,
            startDay = state.seasonStartDay,
            timeZoneId = vineyard?.timezone?.takeIf { it.isNotBlank() }
                ?: TimeZone.getDefault().id,
        )
    }
    val currentSeasonStartYear = remember(seasonCalendar) {
        seasonCalendar.season(System.currentTimeMillis()).startYear
    }

    LaunchedEffect(vineyardId) {
        val id = vineyardId ?: return@LaunchedEffect
        // Cache first so the screen paints immediately, then reconcile with the server.
        // A plan the grower saved on another device appears once the pull lands; nothing
        // on this screen waits for the network to become interactive.
        planRepository.load(id)
        planRepository.sync(id)
    }

    val syncNotice = remember(syncState) {
        when (syncState) {
            ResistancePlanSyncState.LOCAL_ONLY -> ResistancePlanRepository.LOCAL_ONLY_NOTICE
            ResistancePlanSyncState.SYNCED -> ResistancePlanRepository.SYNCED_NOTICE
            ResistancePlanSyncState.PENDING_UPLOAD -> ResistancePlanRepository.PENDING_NOTICE
            ResistancePlanSyncState.SYNCING -> ResistancePlanRepository.SYNCING_NOTICE
            ResistancePlanSyncState.FAILED -> ResistancePlanRepository.FAILED_NOTICE
            // Never FAILED_NOTICE: a conflict cannot be fixed by retrying, so telling the
            // grower it "will retry" would promise something that deterministically fails.
            ResistancePlanSyncState.CONFLICT -> ResistancePlanRepository.CONFLICT_NOTICE
        }
    }

    // The ONLY navigation state: which plan is open, by stable id. Never re-resolved
    // by season/disease — two plans for the same season and disease must never swap
    // under the editor. Back clears it and lands on the list, never on another plan.
    var openPlanId by rememberSaveable { mutableStateOf<String?>(null) }

    val listDateFormatter = remember { SimpleDateFormat("d MMM yyyy", Locale.getDefault()) }

    val open = openPlanId
    if (open == null) {
        ResistancePlanListContent(
            plans = plans,
            hasVineyard = vineyardId != null,
            syncNotice = syncNotice,
            isPending = { planRepository.isPending(it) },
            hasConflict = { id -> conflicts.any { it.rowId == id } },
            newPlanSeasonChoices = ResistancePlannerPresentation.seasonChoices(
                currentStartYear = currentSeasonStartYear,
                selectedStartYear = currentSeasonStartYear,
            ),
            formatListDate = { listDateFormatter.format(Date(it)) },
            onOpen = { openPlanId = it },
            onCreate = create@{ seasonStartYear, disease, name ->
                val id = vineyardId ?: return@create
                val now = System.currentTimeMillis()
                // Created immediately with a device-minted id, then opened. Creating
                // before first edit gives the plan its stable identity up front — the
                // same id the server, other devices and spray jobs will use.
                var plan = ResistancePlan(
                    vineyardId = id,
                    seasonId = ResistanceSeasonCalendar.seasonId(seasonStartYear),
                    seasonStartYear = seasonStartYear,
                    disease = disease,
                    jurisdiction = jurisdiction,
                    notes = name,
                    createdAtEpochMs = now,
                    updatedAtEpochMs = now,
                )
                ResistanceRulesets.registry
                    .current(plan.jurisdiction, plan.crop, plan.disease)
                    ?.let { plan = plan.stampingRuleset(it.id, it.rulesetVersion) }
                planRepository.save(plan)
                openPlanId = plan.id
            },
            // New stable plan AND position ids — see ResistancePlan.duplicated. The copy
            // stays in the list (not auto-opened) so both plans sit visibly side by side.
            // createdBy is left null; the sql/196 attribution guard stamps the uploader.
            onDuplicate = { plan ->
                planRepository.save(plan.duplicated(nowMs = System.currentTimeMillis(), by = null))
            },
            onRename = { plan, name ->
                planRepository.save(plan.settingNotes(name, System.currentTimeMillis()))
            },
            // Soft-delete via the existing tombstone contract (sql/196): the archive
            // propagates to the server and other devices.
            onArchive = { planRepository.delete(it.id) },
            onBack = onBack,
            modifier = modifier,
        )
    } else {
        androidx.activity.compose.BackHandler { openPlanId = null }
        ResistancePlanEditorContent(
            vm = vm,
            state = state,
            planRepository = planRepository,
            plan = plans.firstOrNull { it.id == open },
            seasonCalendar = seasonCalendar,
            currentSeasonStartYear = currentSeasonStartYear,
            syncNotice = syncNotice,
            onBack = { openPlanId = null },
            modifier = modifier,
        )
    }
}

// ---------------------------------------------------------------------------
// Plan list
// ---------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ResistancePlanListContent(
    plans: List<ResistancePlan>,
    hasVineyard: Boolean,
    syncNotice: String,
    isPending: (String) -> Boolean,
    hasConflict: (String) -> Boolean,
    newPlanSeasonChoices: List<ResistancePlannerSeasonChoice>,
    formatListDate: (Long) -> String,
    onOpen: (String) -> Unit,
    onCreate: (Int, ResistanceDisease, String?) -> Unit,
    onDuplicate: (ResistancePlan) -> Unit,
    onRename: (ResistancePlan, String?) -> Unit,
    onArchive: (ResistancePlan) -> Unit,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current

    var seasonFilter by rememberSaveable { mutableStateOf<String?>(null) }
    var diseaseFilterRaw by rememberSaveable { mutableStateOf<String?>(null) }
    var showNewPlan by rememberSaveable { mutableStateOf(false) }
    var renamingPlanId by rememberSaveable { mutableStateOf<String?>(null) }
    var archivingPlanId by rememberSaveable { mutableStateOf<String?>(null) }

    val diseaseFilter = diseaseFilterRaw?.let { raw ->
        ResistanceDisease.entries.firstOrNull { it.name == raw }
    }
    // Seasons that actually have plans, newest first.
    val seasonOptions = remember(plans) {
        plans.sortedByDescending { it.seasonStartYear }.map { it.seasonId }.distinct()
    }
    val filtered = remember(plans, seasonFilter, diseaseFilter) {
        plans.filter { plan ->
            (seasonFilter == null || plan.seasonId == seasonFilter) &&
                (diseaseFilter == null || plan.disease == diseaseFilter)
        }
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = vine.appBackground,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Resistance Planner", fontWeight = FontWeight.SemiBold) },
                navigationIcon = { onBack?.let { BackNavIcon(it) } },
                actions = {
                    if (hasVineyard) {
                        IconButton(onClick = { showNewPlan = true }) {
                            Icon(Icons.Filled.Add, contentDescription = "New resistance plan")
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(4.dp))

            if (!hasVineyard) {
                VineyardCard {
                    Text(
                        "Select a vineyard to plan a resistance strategy.",
                        fontSize = 14.sp,
                        color = vine.textSecondary,
                    )
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterMenuChip(
                        label = seasonFilter ?: "All seasons",
                        isActive = seasonFilter != null,
                    ) { dismiss ->
                        DropdownMenuItem(
                            text = { Text("All seasons") },
                            onClick = { seasonFilter = null; dismiss() },
                        )
                        seasonOptions.forEach { seasonId ->
                            DropdownMenuItem(
                                text = { Text(seasonId) },
                                onClick = { seasonFilter = seasonId; dismiss() },
                            )
                        }
                    }
                    FilterMenuChip(
                        label = diseaseFilter?.label ?: "All diseases",
                        isActive = diseaseFilter != null,
                    ) { dismiss ->
                        DropdownMenuItem(
                            text = { Text("All diseases") },
                            onClick = { diseaseFilterRaw = null; dismiss() },
                        )
                        ResistanceDisease.entries.forEach { option ->
                            DropdownMenuItem(
                                text = { Text(option.label) },
                                onClick = { diseaseFilterRaw = option.name; dismiss() },
                            )
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    if (seasonFilter != null || diseaseFilterRaw != null) {
                        TextButton(onClick = { seasonFilter = null; diseaseFilterRaw = null }) {
                            Text("Clear", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }

                if (plans.isEmpty()) {
                    VineyardCard {
                        Text(
                            "No resistance plans yet",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "Plan a season-long FRAC rotation per disease. You can keep several plans for the same season and disease — nothing is ever selected for you.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                        Spacer(Modifier.height(10.dp))
                        Button(onClick = { showNewPlan = true }) {
                            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("New Resistance Plan", fontWeight = FontWeight.SemiBold)
                        }
                    }
                } else if (filtered.isEmpty()) {
                    VineyardCard {
                        Text("No plans match the filter.", fontSize = 13.sp, color = vine.textSecondary)
                        TextButton(onClick = { seasonFilter = null; diseaseFilterRaw = null }) {
                            Text("Clear filters", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                } else {
                    filtered.forEach { plan ->
                        PlanListRow(
                            plan = plan,
                            isPending = isPending(plan.id),
                            hasConflict = hasConflict(plan.id),
                            updatedLabel = formatListDate(plan.updatedAtEpochMs),
                            onOpen = { onOpen(plan.id) },
                            onRename = { renamingPlanId = plan.id },
                            onDuplicate = { onDuplicate(plan) },
                            onArchive = { archivingPlanId = plan.id },
                        )
                    }
                }

                // Where these plans actually live, stated where they are managed.
                Text(syncNotice, fontSize = 11.sp, color = vine.textSecondary)
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    if (showNewPlan) {
        NewResistancePlanDialog(
            seasonChoices = newPlanSeasonChoices,
            onDismiss = { showNewPlan = false },
            onCreate = { year, disease, name ->
                showNewPlan = false
                onCreate(year, disease, name)
            },
        )
    }

    val renaming = renamingPlanId?.let { id -> plans.firstOrNull { it.id == id } }
    if (renaming != null) {
        RenamePlanDialog(
            plan = renaming,
            onDismiss = { renamingPlanId = null },
            onSave = { name ->
                renamingPlanId = null
                onRename(renaming, name)
            },
        )
    }

    val archiving = archivingPlanId?.let { id -> plans.firstOrNull { it.id == id } }
    if (archiving != null) {
        AlertDialog(
            onDismissRequest = { archivingPlanId = null },
            title = { Text("Archive this plan?") },
            text = {
                Text(
                    "Archives \"${archiving.displayTitle}\" for the whole vineyard. " +
                        "Spray jobs and records created from it are never touched.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    archivingPlanId = null
                    onArchive(archiving)
                }) { Text("Archive", color = VineColors.Destructive) }
            },
            dismissButton = {
                TextButton(onClick = { archivingPlanId = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun PlanListRow(
    plan: ResistancePlan,
    isPending: Boolean,
    hasConflict: Boolean,
    updatedLabel: String,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onDuplicate: () -> Unit,
    onArchive: () -> Unit,
) {
    val vine = LocalVineColors.current
    var menuOpen by remember { mutableStateOf(false) }
    val blocks = plan.blockIds.size
    val positions = plan.positions.size

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground)
            .border(0.5.dp, vine.cardBorder, RoundedCornerShape(14.dp))
            .clickable { onOpen() }
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(
                    plan.displayTitle,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(5.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    PlanTag(plan.seasonId)
                    PlanTag(plan.disease.label)
                }
            }
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(
                        Icons.Filled.MoreVert,
                        contentDescription = "Plan actions",
                        tint = vine.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Open") },
                        onClick = { menuOpen = false; onOpen() },
                    )
                    DropdownMenuItem(
                        text = { Text("Rename") },
                        leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null, modifier = Modifier.size(18.dp)) },
                        onClick = { menuOpen = false; onRename() },
                    )
                    DropdownMenuItem(
                        text = { Text("Duplicate") },
                        leadingIcon = { Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp)) },
                        onClick = { menuOpen = false; onDuplicate() },
                    )
                    DropdownMenuItem(
                        text = { Text("Archive", color = VineColors.Destructive) },
                        leadingIcon = {
                            Icon(
                                Icons.Filled.Delete,
                                contentDescription = null,
                                tint = VineColors.Destructive,
                                modifier = Modifier.size(18.dp),
                            )
                        },
                        onClick = { menuOpen = false; onArchive() },
                    )
                }
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(
            "$blocks ${if (blocks == 1) "block" else "blocks"} • " +
                "$positions ${if (positions == 1) "position" else "positions"} • " +
                "Updated $updatedLabel",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        if (hasConflict) {
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.Warning,
                    contentDescription = null,
                    tint = VineColors.Orange,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.size(4.dp))
                Text(
                    "Changes need review",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.Orange,
                )
            }
        } else if (isPending) {
            Spacer(Modifier.height(4.dp))
            Text("Waiting to sync", fontSize = 11.sp, color = VineColors.Orange)
        }
    }
}

@Composable
private fun PlanTag(text: String) {
    Text(
        text,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        color = VineColors.LeafGreen,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(VineColors.LeafGreen.copy(alpha = 0.14f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

@Composable
private fun FilterMenuChip(
    label: String,
    isActive: Boolean,
    content: @Composable (dismiss: () -> Unit) -> Unit,
) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .clip(RoundedCornerShape(50))
                .background(if (isActive) VineColors.LeafGreen.copy(alpha = 0.18f) else vine.cardBackground)
                .border(0.5.dp, vine.cardBorder, RoundedCornerShape(50))
                .clickable { expanded = true }
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                label,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = if (isActive) VineColors.LeafGreen else vine.textPrimary,
            )
            Spacer(Modifier.size(4.dp))
            Icon(
                Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = if (isActive) VineColors.LeafGreen else vine.textSecondary,
                modifier = Modifier.size(16.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            content { expanded = false }
        }
    }
}

/**
 * Season, disease and an optional name for a NEW plan.
 *
 * Duplicates by season+disease are allowed on purpose — the list is the place that
 * tells them apart, and the optional name makes that easy.
 */
@Composable
private fun NewResistancePlanDialog(
    seasonChoices: List<ResistancePlannerSeasonChoice>,
    onDismiss: () -> Unit,
    onCreate: (Int, ResistanceDisease, String?) -> Unit,
) {
    var seasonStartYear by remember {
        mutableStateOf(
            seasonChoices.firstOrNull { it.isSelected }?.startYear
                ?: seasonChoices.firstOrNull()?.startYear
                ?: 0,
        )
    }
    var disease by remember { mutableStateOf(ResistanceDisease.POWDERY_MILDEW) }
    var name by remember { mutableStateOf("") }
    val vine = LocalVineColors.current

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("New Resistance Plan") },
        text = {
            Column {
                PickerRow(
                    label = "Season",
                    value = seasonChoices.firstOrNull { it.startYear == seasonStartYear }?.id
                        ?: ResistanceSeasonCalendar.seasonId(seasonStartYear),
                ) { dismiss ->
                    seasonChoices.forEach { choice ->
                        DropdownMenuItem(
                            text = { Text(choice.id) },
                            onClick = { seasonStartYear = choice.startYear; dismiss() },
                        )
                    }
                }
                PickerRow(label = "Disease", value = disease.label) { dismiss ->
                    ResistanceDisease.entries.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option.label) },
                            onClick = { disease = option; dismiss() },
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Plan name (optional)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    "You can keep several plans for the same season and disease — a name makes them easy to tell apart.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onCreate(seasonStartYear, disease, name.trim().ifBlank { null })
            }) { Text("Create") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun RenamePlanDialog(
    plan: ResistancePlan,
    onDismiss: () -> Unit,
    onSave: (String?) -> Unit,
) {
    var name by remember(plan.id) { mutableStateOf(plan.notes.orEmpty()) }
    val vine = LocalVineColors.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename plan") },
        text = {
            Column {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Plan name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    "Shown in the plan list. Clear it to fall back to season and disease.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(name.trim().ifBlank { null }) }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

// ---------------------------------------------------------------------------
// Plan editor
// ---------------------------------------------------------------------------

/**
 * Editor for ONE plan, opened by stable id. Season and disease are the plan's
 * identity, fixed at creation and shown read-only — the pickers that used to live
 * here silently switched to a DIFFERENT plan, which is exactly what the plan list
 * exists to prevent.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ResistancePlanEditorContent(
    vm: AppViewModel,
    state: AppUiState,
    planRepository: ResistancePlanRepository,
    plan: ResistancePlan?,
    seasonCalendar: ResistanceSeasonCalendar,
    currentSeasonStartYear: Int,
    syncNotice: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current

    if (plan == null) {
        // Archived or removed — possibly on another device, pulled mid-session.
        // Never silently substitute a different plan.
        Scaffold(
            modifier = modifier.fillMaxSize(),
            containerColor = vine.appBackground,
            topBar = {
                CenterAlignedTopAppBar(
                    title = { Text("Resistance Plan", fontWeight = FontWeight.SemiBold) },
                    navigationIcon = { BackNavIcon(onBack) },
                )
            },
        ) { padding ->
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(horizontal = 16.dp),
            ) {
                Spacer(Modifier.height(8.dp))
                VineyardCard {
                    Text("Plan no longer available", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "This plan was archived or removed. Go back to the plan list to pick or create another.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }
            }
        }
        return
    }

    val vineyard = state.selectedVineyard
    var editingPositionId by remember { mutableStateOf<String?>(null) }
    var expandedPositionIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var showStrategy by remember { mutableStateOf(false) }
    var showUnresolvedDetail by remember { mutableStateOf(false) }

    // Plan -> Spray Jobs (sql/201, Stage 5B). The create gate mirrors the
    // spray_jobs INSERT RLS policy (owner/manager only).
    val planSprayJobsMap by vm.planSprayJobs.collectAsStateWithLifecycle()
    val canCreateSprayJobs = state.currentRole == "owner" || state.currentRole == "manager"
    var jobDetail by remember { mutableStateOf<PlanSprayJob?>(null) }
    var recordingJob by remember { mutableStateOf<PlanSprayJob?>(null) }

    val season = remember(seasonCalendar, plan.seasonStartYear) {
        seasonCalendar.seasonStarting(plan.seasonStartYear)
    }

    // Resistance events are rebuilt from persisted spray records only. Nothing on this
    // screen writes to them: historical applications are immutable input.
    val sourced = remember(state.sprayRecords, seasonCalendar) {
        ResistanceEventSource.events(state.sprayRecords, seasonCalendar)
    }

    fun now(): Long = System.currentTimeMillis()

    /**
     * Applies an edit and persists it; the repository publish drives re-evaluation.
     *
     * Every mutation goes through here so re-evaluation can never be forgotten — the
     * rules are sequence-dependent, so a change to position 4 can alter positions 5 and
     * 6, and a stale later warning would be worse than none.
     */
    fun apply(transform: (ResistancePlan) -> ResistancePlan) {
        var updated = transform(plan)
        ResistanceRulesets.registry
            .current(updated.jurisdiction, updated.crop, updated.disease)
            ?.let { updated = updated.stampingRuleset(it.id, it.rulesetVersion) }
        // Local commit + outbox. Returns immediately, works offline, and never blocks the
        // edit the grower just made on a network round trip.
        planRepository.save(updated)
    }

    // Plan-linked spray jobs: push queued creates, pull live rows. Progress is
    // DERIVED — job activity never edits the plan or bumps its revision.
    LaunchedEffect(plan.id) { vm.refreshPlanSprayJobs(plan.id) }
    val planJobs = planSprayJobsMap[plan.id].orEmpty()
    val jobsByPosition = remember(planJobs) { planJobs.groupBy { it.resistancePositionId.orEmpty() } }

    val chemicalCandidates = remember(state.savedChemicals, plan.disease, vineyard?.country) {
        ResistancePlanChemicalSource.candidates(
            chemicals = state.savedChemicals,
            disease = plan.disease,
            vineyardCountry = vineyard?.country,
        )
    }

    val dateFormatter = remember(seasonCalendar.timeZoneId) {
        SimpleDateFormat("d MMM", Locale.getDefault()).apply {
            timeZone = TimeZone.getTimeZone(seasonCalendar.timeZoneId)
        }
    }
    val formatDate: (Long) -> String = remember(dateFormatter) {
        { epochMs -> dateFormatter.format(Date(epochMs)) }
    }

    val request = remember(plan, season, sourced) {
        ResistancePlanner.Request(
            plan = plan,
            season = season,
            seasonCalendar = seasonCalendar,
            events = sourced.events,
            unresolvedApplications = sourced.unresolvedBlockApplications,
        )
    }

    // Every change to group, product, order or block set lands in `plan`, so this
    // single call re-runs the already-tested orchestrator. There is no counting
    // anywhere in this file.
    val evaluation = remember(request) { ResistancePlanner.evaluate(request) }

    val blockNames = remember(state.paddocks) {
        state.paddocks.sortedBy { it.name.lowercase() }.map { it.id to it.name }
    }

    val ui: ResistancePlannerUiState =
        remember(evaluation, plan, blockNames, currentSeasonStartYear, syncNotice) {
            ResistancePlannerPresentation.state(
                plan = plan,
                evaluation = evaluation,
                blockNames = blockNames,
                currentSeasonStartYear = currentSeasonStartYear,
                syncNotice = syncNotice,
                formatDate = formatDate,
            )
        }

    // Executing a plan-linked job: host the Spray Calculator in place (the
    // SpraysScreen pattern). The saved record carries spray_job_id — the
    // job-originated completion link.
    val recording = recordingJob
    if (recording != null) {
        androidx.activity.compose.BackHandler { recordingJob = null }
        SprayCalculatorScreen(
            vm = vm,
            state = state,
            modifier = modifier,
            onBack = { recordingJob = null },
            onSaved = {
                recordingJob = null
                vm.refreshPlanSprayJobs(plan.id)
            },
            onJobStarted = null,
            prefillJobRecord = recording.toPrefillSprayRecord(),
            originSprayJobId = recording.id,
            prefillPaddockIds = plan.blockIds,
        )
        return
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = vine.appBackground,
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        plan.displayTitle,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                navigationIcon = { BackNavIcon(onBack) },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(4.dp))

            PlanHeaderCard(plan)

            if (!ui.isSupported) {
                UnsupportedCard(ui)
            } else {
                BlockSelectionCard(ui) { blockId ->
                    apply { current ->
                        val ids = current.blockIds.toMutableList()
                        if (!ids.remove(blockId)) ids.add(blockId)
                        current.settingBlockIds(ids, now())
                    }
                }

                if (!ui.hasSelectedBlocks) {
                    VineyardCard {
                        Text(
                            ui.chooseBlocksPrompt.orEmpty(),
                            fontSize = 14.sp,
                            color = vine.textSecondary,
                        )
                    }
                } else {
                    HistoryCheckCard(
                        ui = ui,
                        showUnresolvedDetail = showUnresolvedDetail,
                        onToggleUnresolvedDetail = { showUnresolvedDetail = !showUnresolvedDetail },
                    )
                    TimelineCard(ui)
                    PlannedPositionsCard(
                        ui = ui,
                        expandedPositionIds = expandedPositionIds,
                        jobsByPosition = jobsByPosition,
                        canCreateSprayJobs = canCreateSprayJobs,
                        isJobPending = { vm.isPendingSprayJob(it) },
                        onAdd = { apply { it.addingPosition(nowMs = now()) } },
                        onEdit = { editingPositionId = it },
                        onMoveUp = { id -> apply { it.movingPositionUp(id, now()) } },
                        onMoveDown = { id -> apply { it.movingPositionDown(id, now()) } },
                        onRemove = { id -> apply { it.removingPosition(id, now()) } },
                        onToggleReasons = { id ->
                            expandedPositionIds = if (expandedPositionIds.contains(id)) {
                                expandedPositionIds - id
                            } else {
                                expandedPositionIds + id
                            }
                        },
                        onCreateSprayJob = createJob@{ positionId ->
                            val position = plan.position(positionId) ?: return@createJob
                            val ordinal = ui.positions
                                .firstOrNull { it.positionId == positionId }
                                ?.ordinalLabel ?: "Spray"
                            // Freezes the position VERBATIM into the job; prefills
                            // only what the plan genuinely knows (blocks, disease,
                            // planned chemistry identity) — never rates or volumes.
                            vm.createSprayJobFromPlan(
                                plan = plan,
                                position = position,
                                name = "${plan.disease.label} ${plan.seasonId} — $ordinal",
                                target = plan.disease.label,
                                paddockIds = plan.blockIds,
                            )
                        },
                        onOpenJob = { jobDetail = it },
                    )
                    SeasonTotalsCard(ui)
                    StrategyCard(
                        ui = ui,
                        isExpanded = showStrategy,
                        onToggle = { showStrategy = !showStrategy },
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    val editingId = editingPositionId
    if (editingId != null) {
        val position = plan.position(editingId)
        val index = plan.positions.indexOfFirst { it.id == editingId }
        if (position != null && index >= 0) {
            ResistancePlanPositionEditorSheet(
                position = position,
                positionIndex = index,
                plannerRequest = request,
                chemicalCandidates = chemicalCandidates,
                jurisdiction = plan.jurisdiction,
                onDismiss = { editingPositionId = null },
                onSave = { updated ->
                    apply { it.replacingPosition(updated, now()) }
                    editingPositionId = null
                },
            )
        } else {
            editingPositionId = null
        }
    }

    val detailJob = jobDetail
    if (detailJob != null) {
        PlanSprayJobDetailSheet(
            job = detailJob,
            planLabel = plan.displayTitle,
            livePosition = ui.positions.firstOrNull { it.positionId == detailJob.resistancePositionId },
            isPendingSync = vm.isPendingSprayJob(detailJob.id),
            onRecordSpray = {
                jobDetail = null
                recordingJob = detailJob
            },
            onDismiss = { jobDetail = null },
        )
    }
}

// ---------------------------------------------------------------------------
// Plan identity header
// ---------------------------------------------------------------------------

/**
 * Season and disease, read-only. These identify the plan (together with its name)
 * and are fixed at creation; a different season or disease is a different plan,
 * created from the list.
 */
@Composable
private fun PlanHeaderCard(plan: ResistancePlan) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Season", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            // Stated as a span, never a bare calendar year: an Australian season
            // starts in one year and finishes in the next.
            Text(plan.seasonId, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        }
        HorizontalDivider(Modifier.padding(vertical = 10.dp), color = vine.cardBorder)
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Disease", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text(plan.disease.label, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        }
        Spacer(Modifier.height(8.dp))
        Text(ResistancePlannerPresentation.DISEASE_NOTE, fontSize = 12.sp, color = vine.textSecondary)
        Spacer(Modifier.height(4.dp))
        Text(
            "Season and disease identify this plan. For a different season or disease, create another plan from the list.",
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun PickerRow(
    label: String,
    value: String,
    menu: @Composable (dismiss: () -> Unit) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        TextButton(onClick = { expanded = true }) {
            Text(value, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Icon(Icons.Filled.ExpandMore, contentDescription = null, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            menu { expanded = false }
        }
    }
}

@Composable
private fun UnsupportedCard(ui: ResistancePlannerUiState) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(8.dp))
            Text("Strategy not available", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Orange)
        }
        Spacer(Modifier.height(8.dp))
        Text(ui.unsupportedMessage.orEmpty(), fontSize = 14.sp)
        ui.unsupportedDetail?.let {
            Spacer(Modifier.height(6.dp))
            Text(it, fontSize = 12.sp, color = vine.textSecondary)
        }
    }
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

@Composable
private fun BlockSelectionCard(
    ui: ResistancePlannerUiState,
    onToggleBlock: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("Blocks", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(
            ResistancePlannerPresentation.BLOCKS_NEVER_MERGED_NOTE,
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        Spacer(Modifier.height(10.dp))
        ui.blocksEmptyLabel?.let {
            Text(it, fontSize = 13.sp, color = vine.textSecondary)
        }
        ui.blocks.chunked(2).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                row.forEach { block ->
                    AssistChip(
                        onClick = { onToggleBlock(block.id) },
                        modifier = Modifier.weight(1f).heightIn(min = 44.dp),
                        label = {
                            Text(block.name, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 13.sp)
                        },
                        leadingIcon = {
                            Icon(
                                if (block.isSelected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp),
                            )
                        },
                        colors = AssistChipDefaults.assistChipColors(
                            containerColor = if (block.isSelected) {
                                VineColors.LeafGreen.copy(alpha = 0.18f)
                            } else {
                                Color.Transparent
                            },
                            labelColor = if (block.isSelected) VineColors.LeafGreen else vine.textPrimary,
                            leadingIconContentColor = if (block.isSelected) VineColors.LeafGreen else vine.textSecondary,
                        ),
                    )
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// History check
// ---------------------------------------------------------------------------

@Composable
private fun HistoryCheckCard(
    ui: ResistancePlannerUiState,
    showUnresolvedDetail: Boolean,
    onToggleUnresolvedDetail: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("History check", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        // Deliberately ABOVE the plan. A grower who scrolls to a green sequence first has
        // already been reassured before learning the history behind it is incomplete.
        Text(
            "Checked before any recommendation, so a plan never looks settled on top of history that isn't.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        Spacer(Modifier.height(10.dp))
        ui.historyRows.forEach { row ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(bottom = 8.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(vine.cardBorder.copy(alpha = 0.35f))
                    .padding(10.dp),
            ) {
                Text(row.blockName, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.Top) {
                    Icon(
                        if (row.isCompleteEnoughToAssess) Icons.Filled.CheckCircle else Icons.Filled.Warning,
                        contentDescription = null,
                        tint = if (row.isCompleteEnoughToAssess) VineColors.LeafGreen else VineColors.Orange,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.size(6.dp))
                    Column {
                        Text(row.headline, fontSize = 13.sp)
                        row.detailLines.forEach {
                            Text(it, fontSize = 12.sp, color = vine.textSecondary)
                        }
                    }
                }
            }
        }
        ui.unresolvedSummary?.let { summary ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(VineColors.Orange.copy(alpha = 0.12f))
                    .padding(10.dp),
            ) {
                Text(
                    summary.headline,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.Orange,
                )
                Spacer(Modifier.height(4.dp))
                Text(summary.body, fontSize = 12.sp)
                TextButton(onClick = onToggleUnresolvedDetail) {
                    Text(if (showUnresolvedDetail) "Hide details" else "Show details", fontSize = 12.sp)
                }
                if (showUnresolvedDetail) {
                    // Counts by default, records only on request: a vineyard with years
                    // of legacy history would otherwise bury the plan under a list
                    // nobody asked for.
                    Text(summary.detail, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Timeline
// ---------------------------------------------------------------------------

@Composable
private fun TimelineCard(ui: ResistancePlannerUiState) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("Season history", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(10.dp))
        ui.timelines.forEach { timeline ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(bottom = 8.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(vine.cardBorder.copy(alpha = 0.35f))
                    .padding(10.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(timeline.blockName, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.weight(1f))
                    Text(timeline.countLabel, fontSize = 12.sp, color = vine.textSecondary)
                }
                timeline.emptyLabel?.let {
                    Spacer(Modifier.height(4.dp))
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }
                timeline.rows.forEach { row ->
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.Top) {
                        Text("${row.ordinal}.", fontSize = 12.sp, color = vine.textSecondary)
                        Spacer(Modifier.size(8.dp))
                        Column(Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(row.dateLabel, fontSize = 12.sp, color = vine.textSecondary)
                                Spacer(Modifier.size(6.dp))
                                // FRAC identity leads; the brand is supporting detail.
                                // Rotation is a property of the chemistry group, not of
                                // the label on the drum.
                                Text(row.groupsLabel, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                                Spacer(Modifier.size(6.dp))
                                Text(row.availabilityMark, fontSize = 11.sp, color = vine.textSecondary)
                            }
                            row.productLine?.let {
                                Text(
                                    it,
                                    fontSize = 12.sp,
                                    color = vine.textSecondary,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        // Completed work is labelled as such so it can never be mistaken
                        // for a planning slot.
                        Text(
                            row.completedLabel,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = VineColors.LeafGreen,
                        )
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Planned positions
// ---------------------------------------------------------------------------

@Composable
private fun PlannedPositionsCard(
    ui: ResistancePlannerUiState,
    expandedPositionIds: Set<String>,
    jobsByPosition: Map<String, List<PlanSprayJob>>,
    canCreateSprayJobs: Boolean,
    isJobPending: (String) -> Boolean,
    onAdd: () -> Unit,
    onEdit: (String) -> Unit,
    onMoveUp: (String) -> Unit,
    onMoveDown: (String) -> Unit,
    onRemove: (String) -> Unit,
    onToggleReasons: (String) -> Unit,
    onCreateSprayJob: (String) -> Unit,
    onOpenJob: (PlanSprayJob) -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Planned sequence", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onAdd) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(4.dp))
                Text("Add", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Text(
            "Planning positions only — nothing here is a spray record. Create Spray Job hands a position to operations; progress is derived and job activity never edits this plan.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        Spacer(Modifier.height(10.dp))

        ui.positionsEmptyLabel?.let {
            Text(it, fontSize = 12.sp, color = vine.textSecondary)
        }

        ui.positions.forEach { position ->
            PositionCard(
                position = position,
                isExpanded = expandedPositionIds.contains(position.positionId),
                jobs = jobsByPosition[position.positionId].orEmpty(),
                canCreateSprayJobs = canCreateSprayJobs,
                isJobPending = isJobPending,
                onEdit = { onEdit(position.positionId) },
                onMoveUp = { onMoveUp(position.positionId) },
                onMoveDown = { onMoveDown(position.positionId) },
                onRemove = { onRemove(position.positionId) },
                onToggleReasons = { onToggleReasons(position.positionId) },
                onCreateSprayJob = { onCreateSprayJob(position.positionId) },
                onOpenJob = onOpenJob,
            )
        }

        Spacer(Modifier.height(4.dp))
        // Where this plan actually lives is stated where plans are edited, so neither the
        // sharing nor the offline queue is a surprise discovered by losing work.
        Text(ui.syncNotice, fontSize = 11.sp, color = vine.textSecondary)
    }
}

@Composable
private fun PositionCard(
    position: ResistancePlannerPosition,
    isExpanded: Boolean,
    jobs: List<PlanSprayJob>,
    canCreateSprayJobs: Boolean,
    isJobPending: (String) -> Boolean,
    onEdit: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onRemove: () -> Unit,
    onToggleReasons: () -> Unit,
    onCreateSprayJob: () -> Unit,
    onOpenJob: (PlanSprayJob) -> Unit,
) {
    val vine = LocalVineColors.current
    val accent = statusColor(position.status)
    Column(
        Modifier
            .fillMaxWidth()
            .padding(bottom = 10.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBorder.copy(alpha = 0.22f))
            .border(0.5.dp, accent.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(position.ordinalLabel, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                Text(position.chemistryLabel, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                position.timingLabel?.let {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
            StatusBadge(position.status, position.statusLabel)
        }

        position.awaitingChemistryHint?.let {
            Spacer(Modifier.height(6.dp))
            Text(it, fontSize = 12.sp, color = vine.textSecondary)
        }

        position.productCaveats.forEach { caveat ->
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(14.dp))
                Spacer(Modifier.size(6.dp))
                Text(caveat, fontSize = 12.sp, color = VineColors.Orange)
            }
        }

        // The blocks differ, so the summary badge alone would hide a real difference.
        // Per-block rows are always shown in that case.
        if (position.blocksDisagree) {
            Spacer(Modifier.height(8.dp))
            position.blockBreakdown.forEach { block ->
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(block.blockName, fontSize = 12.sp)
                    Spacer(Modifier.weight(1f))
                    Text(
                        block.statusLabel,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = statusColor(block.status),
                    )
                }
            }
        }

        Spacer(Modifier.height(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onEdit) {
                Icon(Icons.Filled.Edit, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.size(4.dp))
                Text("Edit chemistry", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onMoveUp, enabled = position.canMoveUp) {
                Icon(Icons.Filled.ArrowUpward, contentDescription = "Move earlier", modifier = Modifier.size(18.dp))
            }
            IconButton(onClick = onMoveDown, enabled = position.canMoveDown) {
                Icon(Icons.Filled.ArrowDownward, contentDescription = "Move later", modifier = Modifier.size(18.dp))
            }
            IconButton(onClick = onRemove) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = "Remove position",
                    tint = VineColors.Destructive,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        if (position.findings.isNotEmpty()) {
            TextButton(onClick = onToggleReasons) {
                Text(if (isExpanded) "Hide reasons" else "Why?", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Icon(
                    if (isExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                )
            }
            if (isExpanded) {
                position.findings.forEach { finding ->
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .padding(bottom = 6.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(vine.cardBackground.copy(alpha = 0.6f))
                            .padding(8.dp),
                    ) {
                        Text(finding.title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        Text(finding.explanation, fontSize = 12.sp)
                        // Observed vs threshold vs source, so the operator can check the
                        // claim rather than take it on faith.
                        Text(finding.observedLine, fontSize = 11.sp, color = vine.textSecondary)
                        finding.contributingLine?.let {
                            Text(it, fontSize = 11.sp, color = vine.textSecondary)
                        }
                        finding.mixtureUnconfirmedLabel?.let {
                            Text(
                                it,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.Orange,
                            )
                        }
                        Text(finding.sourceLine, fontSize = 11.sp, color = vine.textSecondary)
                    }
                }
            }
        }

        // Spray Jobs created FROM this position (sql/201). Derived display
        // only — nothing here writes back into the plan.
        Spacer(Modifier.height(8.dp))
        HorizontalDivider(color = vine.cardBorder.copy(alpha = 0.5f))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Spray Jobs", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
            Spacer(Modifier.weight(1f))
            if (canCreateSprayJobs) {
                TextButton(onClick = onCreateSprayJob) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.size(4.dp))
                    Text("Create Spray Job", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        if (jobs.isEmpty()) {
            Text(
                "No spray jobs yet. Creating one freezes this position's current intent into the job — later plan edits never rewrite it.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
        jobs.forEach { job ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(vine.cardBackground.copy(alpha = 0.6f))
                    .clickable { onOpenJob(job) }
                    .padding(8.dp),
            ) {
                Text(
                    job.name.ifBlank { "Spray job" },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        (job.status ?: "planned").replaceFirstChar { it.uppercase() },
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                    if (isJobPending(job.id)) {
                        Spacer(Modifier.size(8.dp))
                        Text("Waiting to sync", fontSize = 11.sp, color = VineColors.Orange)
                    }
                    if (job.deviatesFromPlan) {
                        Spacer(Modifier.size(8.dp))
                        Text(
                            "Differs from plan",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = VineColors.Orange,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusBadge(status: ResistancePlanPositionStatus, label: String) {
    val color = statusColor(status)
    Text(
        label,
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = color,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.16f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

/** Colour only. The STATUS itself is decided by the domain, never here. */
private fun statusColor(status: ResistancePlanPositionStatus): Color = when (status) {
    ResistancePlanPositionStatus.GOOD_FIT -> VineColors.LeafGreen
    ResistancePlanPositionStatus.REACHES_STRATEGY_LIMIT -> VineColors.Orange
    ResistancePlanPositionStatus.WOULD_EXCEED_STRATEGY -> VineColors.Destructive
    ResistancePlanPositionStatus.NEEDS_REVIEW -> VineColors.Orange
    ResistancePlanPositionStatus.UNABLE_TO_FULLY_ASSESS -> VineColors.Indigo
}

// ---------------------------------------------------------------------------
// Plan -> Spray Job detail (sql/201, Stage 5B)
// ---------------------------------------------------------------------------

/**
 * Detail sheet for a spray job created from a plan position: WHERE it came
 * from ("From Resistance Plan"), the ORIGINAL frozen intent, the CURRENT
 * proposal with an explicit plan-deviation flag, and the LIVE Resistance
 * Check. Deviation ≠ compliance: a job may differ from the plan yet still be
 * resistance-compliant — compliance is always the engine's call against
 * current history.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlanSprayJobDetailSheet(
    job: PlanSprayJob,
    planLabel: String,
    livePosition: ResistancePlannerPosition?,
    isPendingSync: Boolean,
    onRecordSpray: () -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(job.name.ifBlank { "Spray Job" }, fontSize = 16.sp, fontWeight = FontWeight.Bold)

            JobSheetSection("From Resistance Plan") {
                Text(planLabel, fontSize = 13.sp)
                if (livePosition != null) {
                    Text("Position: ${livePosition.ordinalLabel}", fontSize = 12.sp, color = vine.textSecondary)
                } else {
                    Text(
                        "This position is no longer in the current plan. The job keeps its original intent below.",
                        fontSize = 12.sp,
                        color = VineColors.Orange,
                    )
                }
                job.resistancePlanSourceRevision?.let {
                    Text("Created against plan revision $it", fontSize = 11.sp, color = vine.textSecondary)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        (job.status ?: "planned").replaceFirstChar { it.uppercase() },
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(vine.cardBorder.copy(alpha = 0.4f))
                            .padding(horizontal = 8.dp, vertical = 3.dp),
                    )
                    if (isPendingSync) {
                        Spacer(Modifier.size(8.dp))
                        Text("Waiting to sync", fontSize = 11.sp, color = VineColors.Orange)
                    }
                }
            }

            JobSheetSection("Original planned intent") {
                val snapshot = job.snapshotPosition()
                if (snapshot != null) {
                    Text(
                        job.originalIntentLabel ?: snapshot.groupsLabel,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    snapshot.products.forEach { product ->
                        Text(
                            "• ${product.displayLabel} — ${product.groups.displayLabel}",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                    snapshot.note?.takeIf { it.isNotBlank() }?.let {
                        Text(it, fontSize = 12.sp, color = vine.textSecondary)
                    }
                } else {
                    Text(
                        "No frozen intent — this job was not created from a plan position.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
                Text(
                    "Frozen when the job was created. Editing the plan later never rewrites this.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }

            JobSheetSection("Current proposal") {
                Text(job.currentProposalLabel, fontSize = 13.sp)
                if (job.deviatesFromPlan) {
                    Row(verticalAlignment = Alignment.Top) {
                        Icon(
                            Icons.Filled.Warning,
                            contentDescription = null,
                            tint = VineColors.Orange,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.size(6.dp))
                        Text(
                            "Differs from the original plan — a plan deviation, not a compliance verdict.",
                            fontSize = 12.sp,
                            color = VineColors.Orange,
                        )
                    }
                } else if (job.resistancePositionSnapshot != null) {
                    Text("Matches the original planned intent.", fontSize = 12.sp, color = vine.textSecondary)
                }
                Text(
                    "The job stays fully editable. Changing it is allowed — the deviation is simply shown; resistance compliance is always the engine's call.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }

            JobSheetSection("Live Resistance Check") {
                if (livePosition != null) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Current standing", fontSize = 12.sp, color = vine.textSecondary)
                        Spacer(Modifier.weight(1f))
                        StatusBadge(livePosition.status, livePosition.statusLabel)
                    }
                    livePosition.blockBreakdown.forEach { block ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(block.blockName, fontSize = 12.sp)
                            Spacer(Modifier.weight(1f))
                            Text(
                                block.statusLabel,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = statusColor(block.status),
                            )
                        }
                    }
                    if (job.deviatesFromPlan) {
                        Text(
                            "This check evaluates the position's planned chemistry. The job proposes different products — review before spraying.",
                            fontSize = 12.sp,
                            color = VineColors.Orange,
                        )
                    }
                } else {
                    Text(
                        "The position is no longer in the plan, so there is no live evaluation for it.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
                Text(
                    "Evaluated now, against current spray history. Plan compliance when this job was created guarantees nothing later.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }

            Button(onClick = onRecordSpray, modifier = Modifier.fillMaxWidth()) {
                Text("Record this spray", fontWeight = FontWeight.SemiBold)
            }
            Text(
                "Opens the Spray Calculator prefilled from this job. The saved record will reference this job, completing the Plan → Job → Record chain.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun JobSheetSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    val vine = LocalVineColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBorder.copy(alpha = 0.22f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        content()
    }
}

// ---------------------------------------------------------------------------
// Season totals & strategy
// ---------------------------------------------------------------------------

@Composable
private fun SeasonTotalsCard(ui: ResistancePlannerUiState) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("Season totals", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(
            "Counted from resistance applications, not tank lines — a three-product tank is one application.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        Spacer(Modifier.height(10.dp))
        ui.totals.forEach { totals ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(bottom = 8.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(vine.cardBorder.copy(alpha = 0.35f))
                    .padding(10.dp),
            ) {
                Text(totals.blockName, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Text(totals.sprayCountLabel, fontSize = 12.sp)
                totals.groupLines.forEach {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun StrategyCard(
    ui: ResistancePlannerUiState,
    isExpanded: Boolean,
    onToggle: () -> Unit,
) {
    val vine = LocalVineColors.current
    val strategy = ui.strategy ?: return
    VineyardCard {
        Row(
            Modifier.fillMaxWidth().clickable { onToggle() },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Strategy", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Icon(
                if (isExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
            )
        }
        if (isExpanded) {
            Spacer(Modifier.height(8.dp))
            strategy.organisation?.let {
                Text(it, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
            strategy.strategyName?.let { Text(it, fontSize = 12.sp) }
            strategy.validFromLabel?.let {
                Text(it, fontSize = 12.sp, color = vine.textSecondary)
            }
            strategy.rulesetVersionLabel?.let {
                Text(it, fontSize = 12.sp, color = vine.textSecondary)
            }
            strategy.outdatedWarning?.let {
                Spacer(Modifier.height(4.dp))
                Text(it, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Orange)
            }
            Spacer(Modifier.height(4.dp))
            Text(
                "The Planner supports resistance management. It does not replace the product label or agronomic judgement.",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
        }
    }
}
