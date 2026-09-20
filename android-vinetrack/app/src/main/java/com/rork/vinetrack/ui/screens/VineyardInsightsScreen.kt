package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.EventNote
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.LocationOff
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.rork.vinetrack.data.VintageResolver
import com.rork.vinetrack.data.insights.PhotoLocationStatus
import com.rork.vinetrack.data.insights.ScoutGrowthStageLink
import com.rork.vinetrack.data.insights.ScoutItem
import com.rork.vinetrack.data.insights.ScoutOption
import com.rork.vinetrack.data.insights.ScoutPhoto
import com.rork.vinetrack.data.insights.ScoutReview
import com.rork.vinetrack.data.insights.ScoutStatus
import com.rork.vinetrack.data.insights.ScoutVisit
import com.rork.vinetrack.data.insights.VineyardInsightsAccess
import com.rork.vinetrack.data.insights.VineyardInsightsCatalog
import com.rork.vinetrack.data.insights.VintageNoteCatalog
import com.rork.vinetrack.data.insights.VintageNoteDraft
import com.rork.vinetrack.data.insights.VintageNoteRules
import com.rork.vinetrack.data.insights.VintageNoteType
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.rememberPhotoCaptureCoordinator
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.LocalDate

/**
 * Vineyard Insights — System Admin preview (SQL 236, Round 1).
 *
 * Hosts Scout, Vintage Notes and the prepared Vintage Report workspace behind
 * a single continuously re-checked access gate.
 */

private enum class InsightsPane { Hub, Scout, Notes, Report }

/** Shown under the disabled Round 1 report controls. Mirrored on iOS. */
const val VINTAGE_REPORT_DISABLED_MESSAGE: String =
    "Vintage Report generation will be enabled after the Scout and Vintage Notes " +
        "data foundation is verified."

@Composable
fun VineyardInsightsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    // Access is resolved on EVERY composition, not once on entry. A restored
    // navigation state, a deep link, a sign-out, or a System Admin row revoked
    // while the screen is open must close the preview — an entry-time check
    // would leave it visible until the user happened to navigate away.
    val access = VineyardInsightsAccess.resolve(
        sessionPhase = state.sessionPhase,
        isSystemAdmin = state.isSystemAdmin,
        selectedVineyardId = state.selectedVineyardId,
        isMemberOfSelectedVineyard = state.currentRole != null,
    )

    if (!access.isAllowed) {
        InsightsUnavailable(access, modifier, onBack)
        return
    }

    var pane by remember { mutableStateOf(InsightsPane.Hub) }

    LaunchedEffect(state.selectedVineyardId) {
        state.selectedVineyardId?.let { vm.syncVineyardInsights(it) }
    }

    when (pane) {
        InsightsPane.Hub -> InsightsHub(modifier, onBack) { pane = it }
        InsightsPane.Scout -> ScoutWorkspace(vm, state, modifier) { pane = InsightsPane.Hub }
        InsightsPane.Notes -> VintageNotesWorkspace(vm, state, modifier) { pane = InsightsPane.Hub }
        InsightsPane.Report -> VintageReportWorkspace(state, modifier) { pane = InsightsPane.Hub }
    }
}

/**
 * Shown when access is refused while the screen is somehow open.
 *
 * Deliberately says nothing about System Admin or about a preview existing —
 * an explanation would disclose the feature to exactly the person who may not
 * have it. A still-restoring session reads as "not yet", never as "denied", so
 * a launch race does not look like a permissions error.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InsightsUnavailable(
    access: VineyardInsightsAccess,
    modifier: Modifier,
    onBack: () -> Unit,
) {
    val restoring = (access as? VineyardInsightsAccess.Unavailable)?.reason ==
        VineyardInsightsAccess.Reason.SessionRestoring
    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text("") }, navigationIcon = { BackNavIcon(onBack) }) },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(Icons.Filled.Lock, contentDescription = null, tint = VineColors.TextSecondaryLight)
            Spacer(Modifier.height(12.dp))
            Text(
                if (restoring) "Loading\u2026" else "This tool is not available.",
                fontSize = 15.sp,
                color = VineColors.TextSecondaryLight,
            )
        }
    }
}

// ---------------------------------------------------------------------- Hub

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InsightsHub(
    modifier: Modifier,
    onBack: () -> Unit,
    onOpen: (InsightsPane) -> Unit,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(VineyardInsightsCatalog.TOOL_TITLE) },
                navigationIcon = { BackNavIcon(onBack) },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            PreviewBadge()
            HubCard(
                title = "Scout",
                subtitle = "Block assessments, observations & photos",
                icon = Icons.Filled.Explore,
                tint = VineColors.LeafGreen,
                actions = listOf("New Scout", "Draft Scouts", "Completed Scouts"),
            ) { onOpen(InsightsPane.Scout) }
            HubCard(
                title = "Vintage Notes",
                subtitle = "Record important events during the vintage",
                icon = Icons.Filled.EventNote,
                tint = VineColors.Orange,
                actions = listOf("Add Vintage Note", "View notes for selected Vintage"),
            ) { onOpen(InsightsPane.Notes) }
            HubCard(
                title = "Vintage Report",
                subtitle = "Build the plain-English story of the vintage",
                icon = Icons.Filled.Article,
                tint = VineColors.Indigo,
                actions = listOf("Open report workspace"),
            ) { onOpen(InsightsPane.Report) }
        }
    }
}

@Composable
private fun PreviewBadge() {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(VineColors.Purple.copy(alpha = 0.14f))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            Icons.Filled.Lock,
            contentDescription = null,
            tint = VineColors.Purple,
            modifier = Modifier.size(14.dp),
        )
        Text(
            VineyardInsightsCatalog.PREVIEW_BADGE,
            color = VineColors.Purple,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun HubCard(
    title: String,
    subtitle: String,
    icon: ImageVector,
    tint: Color,
    actions: List<String>,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(vine.cardBackground)
            .border(BorderStroke(0.5.dp, vine.cardBorder), RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(tint.copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = tint)
            }
            Column(Modifier.weight(1f)) {
                Text(title, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Text(subtitle, fontSize = 13.sp, color = vine.textSecondary)
            }
        }
        actions.forEach { Text("\u2022  $it", fontSize = 13.sp, color = vine.textSecondary) }
    }
}

// -------------------------------------------------------------------- Scout

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScoutWorkspace(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val insights = vm.vineyardInsights
    val visits by insights.visits.collectAsStateWithLifecycle()
    val openId by insights.openVisitId.collectAsStateWithLifecycle()
    val writeFailed by insights.lastWriteFailed.collectAsStateWithLifecycle()
    val current = visits.firstOrNull { it.id == openId }
    var showReview by remember { mutableStateOf(false) }
    var completionError by remember { mutableStateOf<String?>(null) }
    var showAllVintages by remember { mutableStateOf(false) }
    var visitPendingDeletion by remember { mutableStateOf<ScoutVisit?>(null) }
    var reportVisit by remember { mutableStateOf<ScoutVisit?>(null) }
    var cameraError by remember { mutableStateOf<String?>(null) }
    var cameraVisitId by rememberSaveable { mutableStateOf<String?>(null) }
    var cameraAssessmentId by rememberSaveable { mutableStateOf<String?>(null) }
    var cameraItemCode by rememberSaveable { mutableStateOf<String?>(null) }
    val camera = rememberPhotoCaptureCoordinator(
        onPhoto = { uri ->
            val visitId = cameraVisitId
            val assessmentId = cameraAssessmentId
            val item = cameraItemCode?.let(ScoutItem::byCode)
            cameraVisitId = null
            cameraAssessmentId = null
            cameraItemCode = null
            if (uri != null && visitId != null && assessmentId != null && item != null) {
                vm.captureScoutPhoto(visitId, assessmentId, item, uri) { saved ->
                    if (!saved) cameraError = "The photograph could not be read or saved. Try again."
                }
            }
        },
        onError = { message ->
            cameraVisitId = null
            cameraAssessmentId = null
            cameraItemCode = null
            cameraError = message
        },
    )
    reportVisit?.let { visit ->
        ScoutReportScreen(vm = vm, state = state, visit = visit, onBack = { reportVisit = null })
        return
    }

    val currentVintage = VintageResolver.vintageYear(
        LocalDate.now(),
        state.seasonStartMonth,
        state.seasonStartDay,
    )
    val historyVisits = state.selectedVineyardId?.let { vineyardId ->
        insights.visitHistory(vineyardId, if (showAllVintages) null else currentVintage)
    }.orEmpty()

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Scout") },
                navigationIcon = {
                    BackNavIcon { if (current != null) insights.openVisit(null) else onBack() }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item { PreviewBadge() }

            cameraError?.let { error ->
                item { VineyardCard { Text(error, color = VineColors.Destructive); TextButton(onClick = { cameraError = null }) { Text("Dismiss") } } }
            }

            if (writeFailed) {
                item {
                    // An observation that silently failed to save is the worst
                    // outcome this feature can produce, so the failure is shown
                    // rather than swallowed.
                    VineyardCard {
                        Text(
                            "This device could not save your latest change.",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = VineColors.Destructive,
                        )
                        Text(
                            "Earlier work is still saved. Try the change again before " +
                                "leaving this Scout.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            if (current == null) {
                item {
                    VineyardCard {
                        Text("Start a Scout", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "Pick the blocks you are walking. Everything is saved on this " +
                                "device first, so a Scout started out of signal is never lost.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                        Spacer(Modifier.height(12.dp))
                        Button(
                            onClick = {
                                val vineyardId = state.selectedVineyardId ?: return@Button
                                val visit = insights.startVisit(
                                    vineyardId = vineyardId,
                                    scoutUserId = state.currentUserId,
                                    scoutName = state.userDisplayName,
                                    seasonStartMonth = state.seasonStartMonth,
                                    seasonStartDay = state.seasonStartDay,
                                )
                                vm.captureScoutWeather(visit.id)
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                        ) {
                            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("New Scout")
                        }
                    }
                }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { showAllVintages = false }) {
                            Text("Vintage ${VintageYearText.format(currentVintage)}")
                        }
                        OutlinedButton(onClick = { showAllVintages = true }) {
                            Text("All vintages")
                        }
                    }
                }
                item {
                    ScoutList(
                        title = "Scout history",
                        visits = historyVisits,
                        paddocks = state.paddocks,
                        onOpen = { insights.openVisit(it) },
                        onReport = { reportVisit = it },
                        onEdit = { visit ->
                            if (!visit.isEditable) insights.reopenVisit(visit.id)
                            insights.openVisit(visit.id)
                        },
                        onDelete = { visitPendingDeletion = it },
                        syncStatus = insights::syncStatus,
                    )
                }
            } else {
                item { ScoutVisitHeader(vm, state, current) }
                item {
                    ScoutWorkspaceMap(
                        visit = current,
                        blocks = current.assessments.mapNotNull { assessment -> state.paddocks.firstOrNull { it.id == assessment.paddockId } },
                        pins = state.pins,
                    )
                }
                item {
                    ScoutBlockPicker(
                        paddocks = state.paddocks,
                        selectedPaddockIds = current.assessments.map { it.paddockId }.toSet(),
                        enabled = current.isEditable,
                    ) { insights.toggleBlock(current.id, it) }
                }
                items(current.assessments, key = { it.id }) { assessment ->
                    ScoutBlockAssessmentCard(
                        vm = vm,
                        paddock = state.paddocks.firstOrNull { it.id == assessment.paddockId },
                        visitId = current.id,
                        assessmentId = assessment.id,
                        enabled = current.isEditable,
                        observations = assessment.observations,
                        onRequestPhoto = { item ->
                            cameraVisitId = current.id
                            cameraAssessmentId = assessment.id
                            cameraItemCode = item.code
                            camera.takePhoto()
                        },
                    )
                }
                item {
                    Button(
                        onClick = { showReview = true },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Indigo),
                    ) { Text(if (current.isEditable) "Review & complete" else "Review") }
                }
                if (!current.isEditable) {
                    item {
                        OutlinedButton(
                            onClick = { insights.reopenVisit(current.id) },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("Reopen and edit") }
                    }
                }
            }
        }
    }

    visitPendingDeletion?.let { visit ->
        AlertDialog(
            onDismissRequest = { visitPendingDeletion = null },
            title = { Text("Permanently delete this Scout?") },
            text = { Text("The visit, assessments, observations and Scout photos will be permanently removed.") },
            confirmButton = {
                TextButton(onClick = {
                    insights.deleteVisit(visit.id)
                    visitPendingDeletion = null
                }) { Text("Delete permanently", color = VineColors.Destructive) }
            },
            dismissButton = {
                TextButton(onClick = { visitPendingDeletion = null }) { Text("Cancel") }
            },
        )
    }

    val reviewVisit = current
    if (showReview && reviewVisit != null) {
        ScoutReviewDialog(
            review = ScoutReview.of(reviewVisit),
            completionCanRetry = reviewVisit.isEditable || insights.completionNeedsRetry(reviewVisit.id),
            completionError = completionError,
            onDismiss = { showReview = false },
            onViewReport = { reportVisit = reviewVisit },
            onComplete = {
                if (insights.completeVisit(reviewVisit.id)) {
                    completionError = null
                    showReview = false
                    insights.openVisit(null)
                } else {
                    completionError = "The completed Scout could not be saved with its sync obligation. Your field data remains on this device; try Complete again."
                }
            },
        )
    }
}

@Composable
private fun ScoutList(
    title: String,
    visits: List<ScoutVisit>,
    paddocks: List<Paddock>,
    onOpen: (String) -> Unit,
    onReport: (ScoutVisit) -> Unit,
    onEdit: (ScoutVisit) -> Unit,
    onDelete: (ScoutVisit) -> Unit,
    syncStatus: (ScoutVisit) -> String,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Spacer(Modifier.height(8.dp))
        if (visits.isEmpty()) {
            Text("None yet.", fontSize = 13.sp, color = vine.textSecondary)
        }
        visits.forEach { visit ->
            val names = visit.assessments
                .mapNotNull { a -> paddocks.firstOrNull { it.id == a.paddockId }?.name }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onOpen(visit.id) }
                    .padding(vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(visit.scoutDateIso, fontSize = 14.sp, color = vine.textPrimary)
                    Text(
                        "${visit.status.label} • ${visit.scoutNameSnapshot ?: "—"}",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                    Text(
                        syncStatus(visit),
                        fontSize = 12.sp,
                        color = if (syncStatus(visit) == "Synced") VineColors.LeafGreen else VineColors.Warning,
                    )
                    Text(
                        if (names.isEmpty()) "No blocks yet" else "${names.joinToString(", ")} (${names.size})",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                    Text(
                        "${visit.assessments.sumOf { it.attentionItems.size }} attention • " +
                            "${visit.assessments.sumOf { it.photoCount }} photos",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                    visit.visitSummary?.let { Text(it, maxLines = 2, fontSize = 12.sp, color = vine.textPrimary) }
                }
                Text("Vintage ${VintageYearText.format(visit.vintageYear)}", fontSize = 12.sp, color = vine.textSecondary)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { onReport(visit) }) { Text("View Report") }
                TextButton(onClick = { onEdit(visit) }) {
                    Text(if (visit.isEditable) "Edit" else "Reopen and edit")
                }
                TextButton(onClick = { onDelete(visit) }) {
                    Text("Delete", color = VineColors.Destructive)
                }
            }
            HorizontalDivider(color = vine.cardBorder)
        }
    }
}

@Composable
private fun ScoutVisitHeader(vm: AppViewModel, state: AppUiState, visit: ScoutVisit) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Scout visit",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Text(visit.status.label, fontSize = 12.sp, color = vine.textSecondary)
        }
        Spacer(Modifier.height(8.dp))
        Text("Date  ${visit.scoutDateIso}", fontSize = 13.sp, color = vine.textSecondary)
        Text("Vintage ${VintageYearText.format(visit.vintageYear)}", fontSize = 13.sp, color = vine.textSecondary)
        Text(
            "Scout  ${visit.scoutNameSnapshot ?: state.userDisplayName ?: "\u2014"}",
            fontSize = 13.sp,
            color = vine.textSecondary,
        )
        Spacer(Modifier.height(4.dp))
        // Weather never blocks saving and is never invented: when no reading is
        // held the record says so rather than leaving a confident blank.
        val weather = visit.weather
        Text(
            when {
                weather == null -> "Weather not captured"
                weather.isUnavailable -> "Weather unavailable at capture time${weather.source?.let { " • $it" }.orEmpty()}"
                else -> buildString {
                    append("Weather")
                    weather.temperatureCelsius?.let { append(" • ${it}\u00B0C") }
                    weather.humidityPercent?.let { append(" • ${it}% RH") }
                    weather.windSpeedKph?.let { append(" • wind ${it} km/h") }
                    weather.source?.let { append(" • $it") }
                    weather.observedAtIso?.let { append(" • observed $it") }
                    append(" • captured ${weather.capturedAtIso}")
                    if (weather.isStale) append(" • stale")
                }
            },
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        if (visit.isEditable && (weather == null || weather.isUnavailable)) {
            TextButton(onClick = { vm.captureScoutWeather(visit.id) }) { Text("Retry weather") }
        }
        Spacer(Modifier.height(10.dp))
        OutlinedTextField(
            value = visit.visitSummary.orEmpty(),
            onValueChange = { vm.vineyardInsights.setSummary(visit.id, it) },
            label = { Text("Visit summary (optional)") },
            modifier = Modifier.fillMaxWidth(),
            enabled = visit.isEditable,
            minLines = 2,
        )
    }
}

@Composable
private fun ScoutBlockPicker(
    paddocks: List<Paddock>,
    selectedPaddockIds: Set<String>,
    enabled: Boolean,
    onToggle: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("Blocks", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Spacer(Modifier.height(8.dp))
        if (paddocks.isEmpty()) {
            Text("No blocks in this vineyard.", fontSize = 13.sp, color = vine.textSecondary)
        }
        paddocks.forEach { paddock ->
            val selected = paddock.id in selectedPaddockIds
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = enabled) { onToggle(paddock.id) }
                    .padding(vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    if (selected) Icons.Filled.Check else Icons.Filled.Add,
                    contentDescription = null,
                    tint = if (selected) VineColors.LeafGreen else vine.textSecondary,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.size(10.dp))
                Text(paddock.name, fontSize = 14.sp, color = vine.textPrimary)
            }
        }
    }
}

/** Existing block facts, displayed rather than re-asked. */
private fun blockDetailLine(paddock: Paddock?, vintageYear: Int): String {
    if (paddock == null) return "Vintage ${VintageYearText.format(vintageYear)}"
    val parts = mutableListOf<String>()
    paddock.varietyAllocations
        ?.mapNotNull { allocation -> allocation.displayName?.takeIf { it.isNotBlank() } }
        ?.distinct()
        ?.takeIf { it.isNotEmpty() }
        ?.let { parts += it.joinToString(", ") }
    paddock.rows?.size?.takeIf { it > 0 }?.let { parts += "$it rows" }
    parts += "Vintage ${VintageYearText.format(vintageYear)}"
    return parts.joinToString("  \u2022  ")
}

@Composable
private fun ScoutBlockAssessmentCard(
    vm: AppViewModel,
    paddock: Paddock?,
    visitId: String,
    assessmentId: String,
    enabled: Boolean,
    observations: List<com.rork.vinetrack.data.insights.ScoutObservation>,
    onRequestPhoto: (ScoutItem) -> Unit,
) {
    val vine = LocalVineColors.current
    val insights = vm.vineyardInsights
    val visit = insights.visit(visitId)
    val appState by vm.ui.collectAsStateWithLifecycle()

    var showStagePicker by remember { mutableStateOf(false) }
    var confirmUnlink by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var messageIsError by remember { mutableStateOf(false) }

    VineyardCard {
        Text(
            paddock?.name ?: "Block",
            fontSize = 16.sp,
            fontWeight = FontWeight.Bold,
            color = vine.textPrimary,
        )
        Text(
            blockDetailLine(paddock, visit?.vintageYear ?: 0),
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        Spacer(Modifier.height(10.dp))

        ScoutItem.entries.forEach { item ->
            val observation = observations.firstOrNull { it.item == item }
            SectionHeader(item.label, onLight = true)
            Spacer(Modifier.height(6.dp))

            when {
                item == ScoutItem.GROWTH_STAGE -> {
                    // The displayed stage is read from the CANONICAL record, not
                    // from a value cached here, so a correction made in the
                    // Growth Stage workflow shows through rather than the Scout
                    // presenting a stale copy.
                    val linkedRecord = observation?.linkedGrowthStageRecordId?.let { id ->
                        appState.growthRecords.firstOrNull { it.id == id }
                    }
                    val canonicalLabel = linkedRecord?.let { record ->
                        GrowthStage.byCode(record.stageCode)?.displayName
                            ?: record.stageLabel
                            ?: record.stageCode
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = enabled) { showStagePicker = true }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                canonicalLabel
                                    ?: observation?.valueLabel
                                    ?: "Tap to select current E-L stage",
                                fontSize = 14.sp,
                                color = if (canonicalLabel == null &&
                                    observation?.valueLabel == null
                                ) {
                                    vine.textSecondary
                                } else {
                                    vine.textPrimary
                                },
                            )
                            if (observation?.linkedGrowthStageRecordId != null) {
                                Text(
                                    "Linked to a Growth Stage record",
                                    fontSize = 11.sp,
                                    color = vine.textSecondary,
                                )
                            }
                        }
                        Icon(
                            Icons.Filled.Add,
                            contentDescription = null,
                            tint = VineColors.LeafGreen,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    if (observation?.linkedGrowthStageRecordId != null && enabled) {
                        TextButton(onClick = { confirmUnlink = true }) {
                            Text("Remove link", color = VineColors.Destructive, fontSize = 12.sp)
                        }
                    }
                    Text(
                        "Recording an E-L stage here creates the same Growth Stage " +
                            "record as the normal workflow \u2014 never a second value.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
                item.isFreeText -> {
                    OutlinedTextField(
                        value = observation?.notes.orEmpty(),
                        onValueChange = {
                            insights.setObservationNotes(visitId, assessmentId, item, it)
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = enabled,
                        minLines = 2,
                        label = { Text("Notes (optional)") },
                    )
                }
                else -> {
                    VineyardInsightsCatalog.options(item).forEach { option ->
                        OptionRow(
                            option = option,
                            selected = observation?.valueCode == option.code,
                            enabled = enabled,
                        ) { insights.setObservationValue(visitId, assessmentId, item, option) }
                    }
                    OutlinedTextField(
                        value = observation?.notes.orEmpty(),
                        onValueChange = {
                            insights.setObservationNotes(visitId, assessmentId, item, it)
                        },
                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                        enabled = enabled,
                        label = { Text("Notes (optional)") },
                    )
                }
            }

            val photos = observation?.photos.orEmpty()
            ScoutPhotoRow(
                photos = photos,
                enabled = enabled,
                bytesFor = { insights.photoBytes(it) },
                onAdd = { onRequestPhoto(item) },
                onDelete = { photo ->
                    insights.deletePhoto(visitId, assessmentId, item, photo.id)
                },
                onRetry = {
                    visit?.vineyardId?.let { vm.retryVineyardInsightsPhotos(it) }
                },
            )
            Spacer(Modifier.height(14.dp))
        }

        message?.let {
            Text(
                it,
                fontSize = 12.sp,
                color = if (messageIsError) VineColors.Destructive else vine.textSecondary,
            )
        }
    }

    if (showStagePicker) {
        val blockId = paddock?.id
        ScoutGrowthStagePickerSheet(
            vm = vm,
            onDismiss = { showStagePicker = false },
            onPicked = { stage ->
                showStagePicker = false
                if (blockId == null) {
                    message = "This block is no longer available."
                    messageIsError = true
                } else {
                    vm.captureScoutGrowthStage(
                        visitId = visitId,
                        assessmentId = assessmentId,
                        paddockId = blockId,
                        stage = stage,
                    ) { ok, text ->
                        message = text
                        messageIsError = !ok
                    }
                }
            },
        )
    }

    if (confirmUnlink) {
        AlertDialog(
            onDismissRequest = { confirmUnlink = false },
            title = { Text("Remove the link to this Growth Stage record?") },
            // Stated before the operator commits: the phenology record is not
            // being deleted, only this Scout's reference to it.
            text = { Text(ScoutGrowthStageLink.RETENTION_NOTICE) },
            confirmButton = {
                TextButton(
                    onClick = {
                        insights.unlinkGrowthStageRecord(visitId, assessmentId)
                        confirmUnlink = false
                        message = ScoutGrowthStageLink.RETENTION_NOTICE
                        messageIsError = false
                    },
                ) { Text("Remove link", color = VineColors.Destructive) }
            },
            dismissButton = {
                TextButton(onClick = { confirmUnlink = false }) { Text("Keep link") }
            },
        )
    }
}

/**
 * Wraps the EXISTING [GrowthStagePickList] and [GrowthStageConfirm] components
 * so Scout reuses the production picker rather than presenting its own list of
 * stages that could drift from the vineyard's enabled catalogue.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScoutGrowthStagePickerSheet(
    vm: AppViewModel,
    onDismiss: () -> Unit,
    onPicked: (GrowthStage) -> Unit,
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val imagesByCode = remember(state.growthStageImages) {
        state.growthStageImages.associateBy { it.stageCode }
    }
    var searchText by remember { mutableStateOf("") }
    var pending by remember { mutableStateOf<GrowthStage?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        val stage = pending
        if (stage == null) {
            GrowthStagePickList(
                vm = vm,
                imagesByCode = imagesByCode,
                searchText = searchText,
                onSearchChange = { searchText = it },
                onPick = { chosen ->
                    // Same rule as the Growth screen: a stage with reference
                    // imagery gets the confirmation step.
                    val hasImage = imagesByCode[chosen.code] != null ||
                        GrowthStageBundledImages.hasBundled(chosen.code)
                    if (hasImage) pending = chosen else onPicked(chosen)
                },
            )
        } else {
            GrowthStageConfirm(
                vm = vm,
                stage = stage,
                image = imagesByCode[stage.code],
                onConfirm = { onPicked(stage) },
                onBack = { pending = null },
            )
        }
    }
}

/**
 * Photographs for one item: multiple, retained, and immediately visible.
 *
 * Previews come from the LOCAL bytes, so a photograph looks identical before,
 * during and after upload. An operator must never be left wondering whether a
 * photograph "took" because it renders differently while still pending.
 */
@Composable
private fun ScoutPhotoRow(
    photos: List<ScoutPhoto>,
    enabled: Boolean,
    bytesFor: (ScoutPhoto) -> ByteArray?,
    onAdd: () -> Unit,
    onDelete: (ScoutPhoto) -> Unit,
    onRetry: () -> Unit,
) {
    val vine = LocalVineColors.current
    val blockOnly = photos.count { it.locationStatus == PhotoLocationStatus.UNAVAILABLE }
    val failed = photos.count { it.uploadFailed }

    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        if (photos.isNotEmpty()) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(photos, key = { it.id }) { photo ->
                    ScoutPhotoThumbnail(
                        photo = photo,
                        bytes = bytesFor(photo),
                        canDelete = enabled,
                    ) { onDelete(photo) }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onAdd, enabled = enabled) {
                Icon(
                    Icons.Filled.PhotoCamera,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.size(6.dp))
                Text(if (photos.isEmpty()) "Add photograph" else "Add another")
            }
            if (failed > 0) {
                Spacer(Modifier.size(10.dp))
                // The photographs themselves are safe on this device; only the
                // upload failed, so Retry is offered rather than an error that
                // implies the evidence is gone.
                OutlinedButton(onClick = onRetry) { Text("Retry upload") }
            }
        }
        if (blockOnly > 0) {
            // Stated plainly rather than hidden: a photo without a qualifying
            // fix is block-associated, and presenting it as positioned would
            // be a false claim about evidence.
            Text(
                "$blockOnly ${PhotoLocationStatus.UNAVAILABLE.label}",
                fontSize = 11.sp,
                color = VineColors.Warning,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        if (failed > 0) {
            Text(
                "$failed photograph" + (if (failed == 1) "" else "s") +
                    " saved here but not yet uploaded.",
                fontSize = 11.sp,
                color = VineColors.Warning,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun ScoutPhotoThumbnail(
    photo: ScoutPhoto,
    bytes: ByteArray?,
    canDelete: Boolean,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    Box(
        modifier = Modifier
            .size(72.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(vine.cardBorder.copy(alpha = 0.3f)),
    ) {
        if (bytes != null) {
            AsyncImage(
                model = bytes,
                contentDescription = if (
                    photo.locationStatus == PhotoLocationStatus.GPS_CONFIRMED
                ) {
                    "Photograph with confirmed location"
                } else {
                    "Photograph, location unavailable"
                },
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(
                Icons.Filled.PhotoCamera,
                contentDescription = null,
                tint = vine.textSecondary,
                modifier = Modifier.size(20.dp).align(Alignment.Center),
            )
        }
        if (photo.locationStatus == PhotoLocationStatus.UNAVAILABLE) {
            Icon(
                Icons.Filled.LocationOff,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(3.dp)
                    .size(14.dp),
            )
        } else if (photo.uploadFailed) {
            Icon(
                Icons.Filled.Warning,
                contentDescription = null,
                tint = VineColors.Warning,
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(3.dp)
                    .size(14.dp),
            )
        }
        if (canDelete) {
            Icon(
                Icons.Filled.Delete,
                contentDescription = "Delete photograph",
                tint = Color.White,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(2.dp)
                    .size(16.dp)
                    .clickable(onClick = onDelete),
            )
        }
    }
}

@Composable
private fun OptionRow(
    option: ScoutOption,
    selected: Boolean,
    enabled: Boolean,
    onSelect: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onSelect)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (selected) Icons.Filled.Check else Icons.Filled.Add,
            contentDescription = null,
            tint = if (selected) VineColors.LeafGreen else vine.textSecondary,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.size(10.dp))
        Text(
            option.label,
            fontSize = 14.sp,
            color = vine.textPrimary,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

@Composable
private fun PhotoRow(
    photoCount: Int,
    blockOnlyCount: Int,
    enabled: Boolean,
    onAdd: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = onAdd, enabled = enabled) {
                Icon(Icons.Filled.PhotoCamera, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.size(6.dp))
                Text("Add photo")
            }
            Spacer(Modifier.size(10.dp))
            if (photoCount > 0) {
                Text(
                    "$photoCount photo" + if (photoCount == 1) "" else "s",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }
        if (blockOnlyCount > 0) {
            // Stated plainly rather than hidden: a photo without a qualifying
            // fix is block-associated, and presenting it as positioned would
            // be a false claim about evidence.
            Text(
                "$blockOnlyCount ${PhotoLocationStatus.UNAVAILABLE.label}",
                fontSize = 11.sp,
                color = VineColors.Warning,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun ScoutReviewDialog(
    review: ScoutReview,
    completionCanRetry: Boolean,
    completionError: String?,
    onDismiss: () -> Unit,
    onViewReport: () -> Unit,
    onComplete: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Review Scout") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Blocks assessed: ${review.blocksAssessed}")
                Text("Blocks still incomplete: ${review.blocksIncomplete}")
                Text("E-L observations created: ${review.growthStageObservations}")
                Text("Items marked as needing attention: ${review.attentionItems}")
                Text("Photographs: ${review.photoCount}")
                Text("Other issues: ${review.otherIssues}")
                Text("General recommendations: ${review.generalRecommendations}")
                Spacer(Modifier.height(8.dp))
                Text(
                    review.blockedReason() ?: ScoutReview.COMPLETION_HINT,
                    fontSize = 12.sp,
                    color = VineColors.TextSecondaryLight,
                )
                completionError?.let {
                    Text(it, fontSize = 12.sp, color = VineColors.Destructive)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onComplete, enabled = completionCanRetry && review.canComplete) {
                Text("Complete Scout")
            }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onViewReport) { Text("View Report") }
                TextButton(onClick = onDismiss) { Text("Keep editing") }
            }
        },
    )
}

// ------------------------------------------------------------ Vintage Notes

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VintageNotesWorkspace(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val insights = vm.vineyardInsights
    val allNotes by insights.notes.collectAsStateWithLifecycle()
    val noteTypesByVineyard by insights.noteTypesByVineyard.collectAsStateWithLifecycle()
    var draft by remember { mutableStateOf(VintageNoteDraft()) }
    var showPicker by remember { mutableStateOf(false) }
    var isEditing by remember { mutableStateOf(false) }
    var isCreating by remember { mutableStateOf(false) }
    var showAllVintages by remember { mutableStateOf(false) }
    var notePendingDeletion by remember { mutableStateOf<com.rork.vinetrack.data.insights.VintageNote?>(null) }

    val vintage = VintageResolver.vintageYear(
        draft.date,
        state.seasonStartMonth,
        state.seasonStartDay,
    )
    val notes = remember(allNotes, vintage, showAllVintages, state.selectedVineyardId) {
        state.selectedVineyardId?.let { vineyardId ->
            VintageNoteRules.history(allNotes, vineyardId, if (showAllVintages) null else vintage)
        }.orEmpty()
    }
    val customTypes = state.selectedVineyardId?.let { vineyardId ->
        noteTypesByVineyard[vineyardId] ?: insights.noteTypes(vineyardId)
    }.orEmpty()

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Vintage Notes") },
                navigationIcon = { BackNavIcon(onBack) },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item { PreviewBadge() }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { showAllVintages = false }) { Text("Vintage $vintage") }
                    OutlinedButton(onClick = { showAllVintages = true }) { Text("All vintages") }
                }
            }
            if (!isCreating && !isEditing) {
                item {
                    Button(
                        onClick = {
                            draft = VintageNoteDraft()
                            isCreating = true
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = null)
                        Spacer(Modifier.size(6.dp))
                        Text("New Note")
                    }
                }
            } else item {
                VineyardCard {
                    Text(
                        if (isEditing) "Edit Vintage Note" else "Add Vintage Note",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = vine.textPrimary,
                    )
                    Spacer(Modifier.height(10.dp))

                    Text("Date", fontSize = 12.sp, color = vine.textSecondary)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        OutlinedButton(onClick = { draft = draft.copy(date = draft.date.minusDays(1)) }) {
                            Text("\u2212")
                        }
                        Text(
                            draft.date.toString(),
                            fontSize = 16.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        OutlinedButton(onClick = { draft = draft.copy(date = draft.date.plusDays(1)) }) {
                            Text("+")
                        }
                    }
                    Spacer(Modifier.height(8.dp))

                    // The Vintage moves with the date so the observer can see
                    // which season they are filing against before they save.
                    Text("Vintage  $vintage", fontSize = 14.sp, color = vine.textPrimary)
                    Text(VintageNoteRules.VINTAGE_SERVER_NOTE, fontSize = 11.sp, color = vine.textSecondary)
                    Spacer(Modifier.height(10.dp))

                    OutlinedButton(onClick = { showPicker = true }, modifier = Modifier.fillMaxWidth()) {
                        Text(draft.noteTypeLabel ?: "Note type (optional)")
                    }
                    Spacer(Modifier.height(8.dp))

                    OutlinedTextField(
                        value = draft.notes,
                        onValueChange = { draft = draft.copy(notes = it) },
                        label = { Text("Notes (optional)") },
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 3,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Observation made by  ${state.userDisplayName ?: "\u2014"}",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )

                    draft.blockedReason?.let {
                        Spacer(Modifier.height(6.dp))
                        Text(it, fontSize = 12.sp, color = VineColors.Destructive)
                    }

                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = {
                                val vineyardId = state.selectedVineyardId ?: return@Button
                                insights.saveNote(
                                    draft = draft,
                                    vineyardId = vineyardId,
                                    observedByUserId = state.currentUserId,
                                    observerName = state.userDisplayName,
                                    seasonStartMonth = state.seasonStartMonth,
                                    seasonStartDay = state.seasonStartDay,
                                )
                                draft = VintageNoteDraft()
                                isEditing = false
                                isCreating = false
                            },
                            enabled = draft.canSave,
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                        ) { Text("Save note") }
                        if (isEditing) {
                            OutlinedButton(onClick = {
                                draft = VintageNoteDraft()
                                isEditing = false
                                isCreating = false
                            }) { Text("Cancel") }
                        }
                    }
                }
            }

            item {
                SectionHeader(
                    if (showAllVintages) "All Vintage Notes" else "Notes for Vintage $vintage",
                    onLight = true,
                )
            }

            if (notes.isEmpty()) {
                item {
                    VineyardCard {
                        Text("No notes for this Vintage yet.", fontSize = 13.sp, color = vine.textSecondary)
                    }
                }
            }

            items(notes, key = { it.id }) { note ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                note.displayType(),
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                            )
                            Text(note.noteDateIso, fontSize = 12.sp, color = vine.textSecondary)
                        }
                        if (note.isEdited) {
                            Text("Edited", fontSize = 11.sp, color = vine.textSecondary)
                        }
                    }
                    val preview = note.preview()
                    if (preview.isNotEmpty()) {
                        Spacer(Modifier.height(6.dp))
                        Text(preview, fontSize = 13.sp, color = vine.textPrimary)
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(note.observerNameSnapshot ?: "\u2014", fontSize = 12.sp, color = vine.textSecondary)
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = {
                            isEditing = true
                            isCreating = false
                            draft = VintageNoteDraft(
                                id = note.id,
                                date = runCatching { LocalDate.parse(note.noteDateIso) }
                                    .getOrDefault(LocalDate.now()),
                                noteTypeId = note.noteTypeId,
                                noteTypeLabel = note.noteTypeLabelSnapshot,
                                notes = note.notes.orEmpty(),
                            )
                        }) {
                            Icon(Icons.Filled.Edit, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.size(4.dp))
                            Text("Edit")
                        }
                        TextButton(onClick = { notePendingDeletion = note }) {
                            Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.size(4.dp))
                            Text("Delete")
                        }
                    }
                }
            }
        }
    }

    notePendingDeletion?.let { note ->
        AlertDialog(
            onDismissRequest = { notePendingDeletion = null },
            title = { Text("Permanently delete this Vintage Note?") },
            text = { Text("This note will be permanently removed from every synced device.") },
            confirmButton = {
                TextButton(onClick = {
                    insights.deleteNote(note.id)
                    notePendingDeletion = null
                }) { Text("Delete permanently", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { notePendingDeletion = null }) { Text("Cancel") } },
        )
    }

    if (showPicker) {
        NoteTypePicker(
            customTypes = customTypes,
            onDismiss = { showPicker = false },
            onAddCustom = { label ->
                state.selectedVineyardId?.let { insights.addCustomNoteType(it, label) }
            },
        ) { type ->
            draft = draft.copy(
                noteTypeId = type.persistedIdentity,
                noteTypeLabel = type.label,
            )
            showPicker = false
        }
    }
}

@Composable
private fun NoteTypePicker(
    customTypes: List<VintageNoteType>,
    onDismiss: () -> Unit,
    onAddCustom: (String) -> VintageNoteType?,
    onSelect: (VintageNoteType) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var showCustom by remember { mutableStateOf(false) }
    var customLabel by remember { mutableStateOf("") }
    val results = remember(query, customTypes) { VintageNoteCatalog.search(query, customTypes) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Note type") },
        text = {
            Column {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    label = { Text("Search") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(8.dp))
                TextButton(onClick = { showCustom = true }) { Text("Add custom note type") }
                LazyColumn(modifier = Modifier.height(320.dp)) {
                    // Grouped, weather first — see VintageNoteCatalog ordering.
                    VintageNoteCatalog.grouped(customTypes).forEach { (group, types) ->
                        item(key = "group-${group.code}") {
                            Text(
                                group.label,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = VineColors.TextSecondaryLight,
                                modifier = Modifier.padding(top = 10.dp, bottom = 4.dp),
                            )
                        }
                        items(
                            types.filter { it in results },
                            key = { "${group.code}-${it.code}" },
                        ) { type ->
                            Text(
                                type.label,
                                fontSize = 14.sp,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { onSelect(type) }
                                    .padding(vertical = 10.dp),
                            )
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
    if (showCustom) {
        AlertDialog(
            onDismissRequest = { showCustom = false },
            title = { Text("Add custom note type") },
            text = {
                OutlinedTextField(
                    value = customLabel,
                    onValueChange = { customLabel = it },
                    label = { Text("Label") },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    onAddCustom(customLabel)?.let { onSelect(it) }
                    customLabel = ""
                    showCustom = false
                }) { Text("Add") }
            },
            dismissButton = { TextButton(onClick = { showCustom = false }) { Text("Cancel") } },
        )
    }
}

// ----------------------------------------------------------- Vintage Report

/**
 * The prepared report workspace.
 *
 * Round 1 deliberately shows an EMPTY report area and disabled controls. There
 * is no template prose and no model call: a plausible-looking narrative
 * produced before the capture data has been reviewed would be indistinguishable
 * from a real one, and a grower would reasonably believe it. The information
 * architecture is settled here so the next round only has to fill it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VintageReportWorkspace(
    state: AppUiState,
    modifier: Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    var vintage by remember {
        mutableStateOf(
            VintageResolver.vintageYear(
                LocalDate.now(),
                state.seasonStartMonth,
                state.seasonStartDay,
            ),
        )
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Vintage Report") },
                navigationIcon = { BackNavIcon(onBack) },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            PreviewBadge()

            VineyardCard {
                Text("Vintage", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Spacer(Modifier.height(8.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    OutlinedButton(onClick = { vintage -= 1 }) { Text("\u2212") }
                    Text("$vintage", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                    OutlinedButton(onClick = { vintage += 1 }) { Text("+") }
                }
            }

            VineyardCard {
                Text("Report status", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Spacer(Modifier.height(6.dp))
                Text("Not generated", fontSize = 14.sp, color = vine.textSecondary)
                Spacer(Modifier.height(12.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(140.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(vine.cardBorder.copy(alpha = 0.25f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("The report will appear here.", fontSize = 13.sp, color = vine.textSecondary)
                }
            }

            VineyardCard {
                Text(
                    "Where the report will come from",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = vine.textPrimary,
                )
                Spacer(Modifier.height(8.dp))
                listOf(
                    "Scout visits and block observations",
                    "Vintage Notes",
                    "Growth Stage records",
                    "Spray dates, blocks, targets and applications",
                    "Rainfall and available weather history",
                    "Frost, heat, wind, hail, smoke and prolonged wet or dry periods",
                    "Work Tasks and operational Trips",
                    "Pruning, thinning, wire lifting, plucking and trimming activity",
                    "Disease pressure and the responses to it",
                    "Yield estimates, damage, picking and actual yield",
                ).forEach { Text("\u2022  $it", fontSize = 13.sp, color = vine.textSecondary) }
                Spacer(Modifier.height(8.dp))
                Text(
                    "The report will state plainly where data is missing, and will not " +
                        "compare a season against an \u201Caverage\u201D unless the baseline " +
                        "period and source coverage are known.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            VineyardCard {
                listOf(
                    "Generate / Re-generate Report",
                    "Add to Existing Report",
                    "Export PDF",
                    "Export Word",
                ).forEach { label ->
                    Button(
                        onClick = {},
                        enabled = false,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    ) { Text(label) }
                }
                Spacer(Modifier.height(8.dp))
                Text(VINTAGE_REPORT_DISABLED_MESSAGE, fontSize = 12.sp, color = vine.textSecondary)
            }
        }
    }
}
