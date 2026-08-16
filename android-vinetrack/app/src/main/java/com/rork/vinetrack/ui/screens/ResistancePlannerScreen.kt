package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
import com.rork.vinetrack.data.resistance.ResistancePlannerUiState
import com.rork.vinetrack.data.resistance.ResistanceRulesets
import com.rork.vinetrack.data.resistance.ResistanceSeasonCalendar
import com.rork.vinetrack.data.resistance.SupabaseResistancePlanRemote
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
 * Resistance Planner — plan a season-long fungicide rotation for a block and disease.
 *
 * A dedicated planning tool, deliberately NOT inside the Spray Calculator: the decisions
 * here are made weeks before a tank is filled, and burying them in a calculator would
 * make the plan a by-product of an individual spray rather than the thing the sprays are
 * drawn from.
 *
 * Every verdict on this screen comes from `ResistanceEngine` via [ResistancePlanner], and
 * every label comes from [ResistancePlannerPresentation]. This file lays out; it never
 * counts and never decides a status.
 *
 * Mirrors `ResistancePlannerView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ResistancePlannerScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val vine = LocalVineColors.current

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
    val nowMs = remember { System.currentTimeMillis() }
    val currentSeasonStartYear = remember(seasonCalendar, nowMs) {
        seasonCalendar.season(nowMs).startYear
    }

    var seasonStartYear by remember(currentSeasonStartYear) {
        mutableStateOf(currentSeasonStartYear)
    }
    var disease by remember { mutableStateOf(ResistanceDisease.POWDERY_MILDEW) }
    var plan by remember { mutableStateOf<ResistancePlan?>(null) }
    var editingPositionId by remember { mutableStateOf<String?>(null) }
    var expandedPositionIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var showStrategy by remember { mutableStateOf(false) }
    var showUnresolvedDetail by remember { mutableStateOf(false) }

    val season = remember(seasonCalendar, seasonStartYear) {
        seasonCalendar.seasonStarting(seasonStartYear)
    }

    // Resistance events are rebuilt from persisted spray records only. Nothing on this
    // screen writes to them: historical applications are immutable input.
    val sourced = remember(state.sprayRecords, seasonCalendar) {
        ResistanceEventSource.events(state.sprayRecords, seasonCalendar)
    }

    LaunchedEffect(vineyardId) {
        val id = vineyardId ?: return@LaunchedEffect
        // Cache first so the screen paints immediately, then reconcile with the server.
        // A plan the grower saved on another device appears once the pull lands; nothing
        // on this screen waits for the network to become interactive.
        planRepository.load(id)
        planRepository.sync(id)
    }

    /** Loads the saved plan for the selected season and disease, or prepares a new one. */
    fun reloadPlan() {
        val id = vineyardId ?: return
        plan = planRepository.plans(season.id, disease).firstOrNull()
            ?: ResistancePlan(
                vineyardId = id,
                seasonId = season.id,
                seasonStartYear = season.startYear,
                disease = disease,
                jurisdiction = jurisdiction,
                createdAtEpochMs = nowMs,
                updatedAtEpochMs = nowMs,
            )
    }

    LaunchedEffect(vineyardId, season.id, disease, jurisdiction) { reloadPlan() }

    /**
     * Applies an edit, persists it, and lets the plan value drive re-evaluation.
     *
     * Every mutation goes through here so re-evaluation can never be forgotten — the
     * rules are sequence-dependent, so a change to position 4 can alter positions 5 and
     * 6, and a stale later warning would be worse than none.
     */
    fun apply(transform: (ResistancePlan) -> ResistancePlan) {
        val current = plan ?: return
        var updated = transform(current)
        ResistanceRulesets.registry
            .current(updated.jurisdiction, updated.crop, updated.disease)
            ?.let { updated = updated.stampingRuleset(it.id, it.rulesetVersion) }
        plan = updated
        // Local commit + outbox. Returns immediately, works offline, and never blocks the
        // edit the grower just made on a network round trip.
        planRepository.save(updated)
    }

    val activePlan = plan
    val chemicalCandidates = remember(state.savedChemicals, disease, vineyard?.country) {
        ResistancePlanChemicalSource.candidates(
            chemicals = state.savedChemicals,
            disease = disease,
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

    val request = remember(activePlan, season, sourced) {
        activePlan?.let {
            ResistancePlanner.Request(
                plan = it,
                season = season,
                seasonCalendar = seasonCalendar,
                events = sourced.events,
                unresolvedApplications = sourced.unresolvedBlockApplications,
            )
        }
    }

    // Every change to group, product, order, block set, disease or season lands in
    // `plan`/`season`, so this single call re-runs the already-tested orchestrator. There
    // is no counting anywhere in this file.
    val evaluation = remember(request) { request?.let { ResistancePlanner.evaluate(it) } }

    val blockNames = remember(state.paddocks) {
        state.paddocks.sortedBy { it.name.lowercase() }.map { it.id to it.name }
    }

    val syncNotice = remember(syncState) {
        when (syncState) {
            ResistancePlanSyncState.LOCAL_ONLY -> ResistancePlanRepository.LOCAL_ONLY_NOTICE
            ResistancePlanSyncState.SYNCED -> ResistancePlanRepository.SYNCED_NOTICE
            ResistancePlanSyncState.PENDING_UPLOAD -> ResistancePlanRepository.PENDING_NOTICE
            ResistancePlanSyncState.FAILED -> ResistancePlanRepository.FAILED_NOTICE
        }
    }

    val ui: ResistancePlannerUiState? =
        remember(evaluation, activePlan, blockNames, currentSeasonStartYear, syncNotice) {
            if (activePlan == null || evaluation == null) {
                null
            } else {
                ResistancePlannerPresentation.state(
                    plan = activePlan,
                    evaluation = evaluation,
                    blockNames = blockNames,
                    currentSeasonStartYear = currentSeasonStartYear,
                    syncNotice = syncNotice,
                    formatDate = formatDate,
                )
            }
        }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = vine.appBackground,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Resistance Planner", fontWeight = FontWeight.SemiBold) },
                navigationIcon = { onBack?.let { BackNavIcon(it) } },
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

            if (ui == null) {
                VineyardCard {
                    Text(
                        "Select a vineyard to plan a resistance strategy.",
                        fontSize = 14.sp,
                        color = vine.textSecondary,
                    )
                }
                Spacer(Modifier.height(24.dp))
                return@Column
            }

            SeasonDiseaseCard(
                ui = ui,
                onSeasonChange = { seasonStartYear = it },
                onDiseaseChange = { disease = it },
            )

            if (!ui.isSupported) {
                UnsupportedCard(ui)
            } else {
                BlockSelectionCard(ui) { blockId ->
                    apply { current ->
                        val ids = current.blockIds.toMutableList()
                        if (!ids.remove(blockId)) ids.add(blockId)
                        current.settingBlockIds(ids, nowMs)
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
                        onAdd = { apply { it.addingPosition(nowMs = nowMs) } },
                        onEdit = { editingPositionId = it },
                        onMoveUp = { id -> apply { it.movingPositionUp(id, nowMs) } },
                        onMoveDown = { id -> apply { it.movingPositionDown(id, nowMs) } },
                        onRemove = { id -> apply { it.removingPosition(id, nowMs) } },
                        onToggleReasons = { id ->
                            expandedPositionIds = if (expandedPositionIds.contains(id)) {
                                expandedPositionIds - id
                            } else {
                                expandedPositionIds + id
                            }
                        },
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
    if (editingId != null && activePlan != null && request != null) {
        val position = activePlan.position(editingId)
        val index = activePlan.positions.indexOfFirst { it.id == editingId }
        if (position != null && index >= 0) {
            ResistancePlanPositionEditorSheet(
                position = position,
                positionIndex = index,
                plannerRequest = request,
                chemicalCandidates = chemicalCandidates,
                jurisdiction = jurisdiction,
                onDismiss = { editingPositionId = null },
                onSave = { updated ->
                    apply { it.replacingPosition(updated, nowMs) }
                    editingPositionId = null
                },
            )
        } else {
            editingPositionId = null
        }
    }
}

// ---------------------------------------------------------------------------
// Season & disease
// ---------------------------------------------------------------------------

@Composable
private fun SeasonDiseaseCard(
    ui: ResistancePlannerUiState,
    onSeasonChange: (Int) -> Unit,
    onDiseaseChange: (ResistanceDisease) -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        // The season is stated as a span, never a bare calendar year: an Australian
        // season starts in one year and finishes in the next, and "2026" would be
        // ambiguous about which side of the new year a spray belongs to.
        PickerRow(label = "Season", value = ui.seasonId) { dismiss ->
            ui.seasonChoices.forEach { choice ->
                DropdownMenuItem(
                    text = { Text(choice.id) },
                    onClick = { onSeasonChange(choice.startYear); dismiss() },
                )
            }
        }
        HorizontalDivider(Modifier.padding(vertical = 10.dp), color = vine.cardBorder)
        PickerRow(label = "Disease", value = ui.disease.label) { dismiss ->
            ui.diseaseChoices.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.label) },
                    onClick = { onDiseaseChange(option); dismiss() },
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(ui.diseaseNote, fontSize = 12.sp, color = vine.textSecondary)
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
    onAdd: () -> Unit,
    onEdit: (String) -> Unit,
    onMoveUp: (String) -> Unit,
    onMoveDown: (String) -> Unit,
    onRemove: (String) -> Unit,
    onToggleReasons: (String) -> Unit,
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
            "Planning positions only. Nothing here is a spray record, and no spray job is created.",
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
                onEdit = { onEdit(position.positionId) },
                onMoveUp = { onMoveUp(position.positionId) },
                onMoveDown = { onMoveDown(position.positionId) },
                onRemove = { onRemove(position.positionId) },
                onToggleReasons = { onToggleReasons(position.positionId) },
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
    onEdit: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onRemove: () -> Unit,
    onToggleReasons: () -> Unit,
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
