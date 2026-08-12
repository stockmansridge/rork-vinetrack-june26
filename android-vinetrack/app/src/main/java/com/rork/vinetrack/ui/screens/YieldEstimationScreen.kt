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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Route
import androidx.compose.material.icons.filled.Scale
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.BunchCountTripLogic
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.YieldSampleGenerator
import com.rork.vinetrack.data.YieldVintageReport
import com.rork.vinetrack.data.model.BunchCountEntry
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.data.model.damageFactor
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.time.Instant
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Bunch Count Trip workflow — the field data-collection tool behind the
 * current Yield Estimate (Yield Reports present the results).
 *
 * Flow: Home (start / resume / history) → Setup (blocks → reuse or generate
 * route at the shared sample density) → full-screen guided sampling map →
 * Completion (per-block summary, bunch weights, damage toggle, estimate
 * preview) → Save Bunch Count Trip.
 *
 * Every completed trip is a dated observation kept forever; the latest
 * completed trip per Block + Vintage drives the current Yield Estimate.
 * Sessions persist/sync through [AppViewModel.saveYieldSession] (offline
 * outbox included), so an interrupted trip resumes exactly where it stopped.
 */
@Composable
fun YieldEstimationScreen(
    vm: AppViewModel,
    state: AppUiState,
    onBack: () -> Unit,
) {
    val vineyardId = state.selectedVineyardId
    // "" = no active trip (home). rememberSaveable keeps resume across config changes.
    var activeTripId by rememberSaveable { mutableStateOf("") }
    var viewingTripId by rememberSaveable { mutableStateOf("") }
    var showSampling by rememberSaveable { mutableStateOf(false) }
    var showCompletion by rememberSaveable { mutableStateOf(false) }
    // Local optimistic draft so typing/taps never wait for state round-trips.
    var localDraft by remember { mutableStateOf<YieldEstimationSession?>(null) }

    val draft = BunchCountTripLogic.activeDraft(state.yieldSessions, vineyardId)
    val completedTrips = BunchCountTripLogic.completedTrips(state.yieldSessions, vineyardId)

    val session: YieldEstimationSession? =
        localDraft?.takeIf { it.id == activeTripId }
            ?: state.yieldSessions.firstOrNull { it.id == activeTripId }

    fun apply(updated: YieldEstimationSession) {
        localDraft = updated
        vm.saveYieldSession(updated)
    }

    fun closeTrip() {
        activeTripId = ""
        localDraft = null
        showSampling = false
        showCompletion = false
    }

    val screen = when {
        session != null && showSampling -> "sampling"
        session != null && showCompletion -> "completion"
        session != null -> "setup"
        viewingTripId.isNotBlank() -> "history"
        else -> "home"
    }

    AnimatedContent(
        targetState = screen,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "bunch-count-trip-nav",
    ) { current ->
        when (current) {
            "sampling" -> session?.let { s ->
                YieldSamplingMapScreen(
                    state = state,
                    session = s,
                    onRecord = { siteId, bunches, recordedBy ->
                        apply(s.recordBunch(siteId, bunches, recordedBy))
                    },
                    onComplete = { showSampling = false; showCompletion = true },
                    onBack = { showSampling = false },
                )
            }
            "completion" -> session?.let { s ->
                TripCompletionScreen(
                    vm = vm,
                    state = state,
                    session = s,
                    onApply = { apply(it) },
                    onSaved = { closeTrip() },
                    onBack = { showCompletion = false },
                )
            }
            "setup" -> session?.let { s ->
                TripSetupScreen(
                    vm = vm,
                    state = state,
                    session = s,
                    onApply = { apply(it) },
                    onStartSampling = { showSampling = true },
                    onCompleteTrip = { showCompletion = true },
                    onDiscard = {
                        vm.deleteYieldSession(s.id)
                        closeTrip()
                    },
                    onBack = { closeTrip() },
                )
            }
            "history" -> {
                val trip = completedTrips.firstOrNull { it.id == viewingTripId }
                if (trip != null) {
                    CompletedTripScreen(
                        vm = vm,
                        state = state,
                        session = trip,
                        onDeleted = { viewingTripId = "" },
                        onBack = { viewingTripId = "" },
                    )
                } else {
                    viewingTripId = ""
                }
            }
            else -> BunchCountTripHome(
                state = state,
                draft = draft,
                completedTrips = completedTrips,
                onStart = {
                    val vid = vineyardId ?: return@BunchCountTripHome
                    val fresh = BunchCountTripLogic.startTrip(vid, state.yieldSamplesPerHectareDefault)
                    apply(fresh)
                    activeTripId = fresh.id
                },
                onResume = { resumed ->
                    activeTripId = resumed.id
                    localDraft = null
                },
                onOpenTrip = { viewingTripId = it.id },
                onBack = onBack,
            )
        }
    }
}

/** Attach/replace a bunch count on a site, returning a new session. */
private fun YieldEstimationSession.recordBunch(
    siteId: String,
    bunchesPerVine: Double,
    recordedBy: String,
): YieldEstimationSession = copy(
    sampleSites = sampleSites.map {
        if (it.id == siteId) {
            it.copy(
                bunchCountEntry = BunchCountEntry(
                    bunchesPerVine = bunchesPerVine,
                    recordedAt = Instant.now().toString(),
                    recordedBy = recordedBy,
                ),
            )
        } else {
            it
        }
    },
)

// =============================================================================
// Step 1 — Home: explain the trip, start / resume, past trips
// =============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BunchCountTripHome(
    state: AppUiState,
    draft: YieldEstimationSession?,
    completedTrips: List<YieldEstimationSession>,
    onStart: () -> Unit,
    onResume: (YieldEstimationSession) -> Unit,
    onOpenTrip: (YieldEstimationSession) -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Bunch Count Trips") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(0.dp))

            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Filled.Explore, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(22.dp))
                        Text("Bunch Count Trip", color = vine.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    }
                    Text(
                        "Perform a bunch count trip to update the current yield estimate. " +
                            "Walk the sampling route, count bunches at each sample site, then confirm " +
                            "bunch weights to produce the estimate for each block.",
                        color = vine.textSecondary, fontSize = 13.sp,
                    )
                    Text(
                        "Repeat trips through the season — the latest completed trip drives the current Yield Estimate for its blocks; earlier trips stay in history.",
                        color = vine.textSecondary, fontSize = 12.sp,
                    )
                }
            }

            if (blocks.isEmpty()) {
                VineyardCard {
                    Text(
                        "Map at least one block boundary in Blocks before starting a bunch count trip.",
                        color = vine.textSecondary, fontSize = 13.sp,
                    )
                }
            } else {
                if (draft != null) {
                    VineyardCard(modifier = Modifier.clickable { onResume(draft) }) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(22.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Resume trip in progress", color = vine.textPrimary, fontWeight = FontWeight.SemiBold)
                                Text(
                                    if (draft.totalSiteCount > 0)
                                        "${draft.recordedSiteCount} of ${draft.totalSiteCount} sample sites recorded"
                                    else
                                        "Blocks and route not confirmed yet",
                                    color = vine.textSecondary, fontSize = 12.sp,
                                )
                            }
                        }
                    }
                }

                Button(
                    onClick = onStart,
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Start Bunch Count Trip", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }

            if (completedTrips.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.History, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                    Text("Completed trips", color = vine.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
                completedTrips.forEach { trip ->
                    val estimates = remember(trip, state.paddocks) {
                        YieldSampleGenerator.calculateYieldEstimates(trip, state.paddocks) {
                            if (trip.applyDamage) state.damageRecords.damageFactor(it) else 1.0
                        }
                    }
                    val tonnes = estimates.sumOf { it.estimatedYieldTonnes }
                    val vintage = YieldVintageReport.sessionVintage(trip, state.seasonStartMonth, state.seasonStartDay)
                    VineyardCard(modifier = Modifier.clickable { onOpenTrip(trip) }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(
                                    (trip.completedAt ?: trip.createdAt).take(10),
                                    color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                                )
                                Text(
                                    "Vintage $vintage · ${trip.selectedPaddockIds.size} block${if (trip.selectedPaddockIds.size == 1) "" else "s"} · ${trip.recordedSiteCount} sites",
                                    color = vine.textSecondary, fontSize = 12.sp,
                                )
                            }
                            Text(
                                "${formatTonnes(tonnes)} t",
                                color = VineColors.LeafGreen, fontWeight = FontWeight.Bold, fontSize = 15.sp,
                            )
                        }
                    }
                }
            }
        }
    }
}

// =============================================================================
// Steps 2–5 — Setup: select blocks, reuse/generate route, sample density
// =============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripSetupScreen(
    vm: AppViewModel,
    state: AppUiState,
    session: YieldEstimationSession,
    onApply: (YieldEstimationSession) -> Unit,
    onStartSampling: () -> Unit,
    onCompleteTrip: () -> Unit,
    onDiscard: () -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val bunchWeightStore = remember { com.rork.vinetrack.data.BunchWeightDefaultsStore(context) }
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }

    var selectedSite by remember { mutableStateOf<SampleSite?>(null) }
    var showDiscardConfirm by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }

    val selectedBlocks = blocks.filter { session.isPaddockSelected(it.id) }
    // Shared, tested visibility contract for the simplified route preview
    // (mirrors iOS — map dominant, Start Sampling primary, single Regenerate
    // Path for newly generated routes only).
    val controls = BunchCountTripLogic.routePreviewControls(
        isRouteReused = session.routeSourceSessionId != null,
        recordedSiteCount = session.recordedSiteCount,
        isCompleted = session.isCompleted,
    )
    // Existing routes for the current block selection (excluding this trip).
    val reusable = remember(state.yieldSessions, session.selectedPaddockIds, session.id) {
        BunchCountTripLogic.reusableRoute(state.yieldSessions, session.selectedPaddockIds, session.id)
    }

    fun defaultWeights(base: Map<String, Double>): Map<String, Double> {
        val weights = base.toMutableMap()
        selectedBlocks.forEach { b ->
            if (weights.keys.none { it.equals(b.id, ignoreCase = true) }) {
                weights[b.id] = bunchWeightStore.weightGrams(b.id) / 1000.0
            }
        }
        return weights
    }

    fun generateNewRoute() {
        val sites = YieldSampleGenerator.generateSampleSites(
            blocks, session.selectedPaddockIds, session.samplesPerHectare,
        )
        val path = YieldSampleGenerator.generatePath(blocks, session.selectedPaddockIds, sites)
        onApply(
            session.copy(
                sampleSites = sites,
                pathWaypoints = path,
                blockBunchWeightsKg = defaultWeights(session.blockBunchWeightsKg),
                routeSourceSessionId = null,
            ),
        )
    }

    fun useExistingRoute() {
        val route = reusable ?: return
        val path = YieldSampleGenerator.generatePath(blocks, session.selectedPaddockIds, route.sites)
        onApply(
            session.copy(
                sampleSites = route.sites,
                pathWaypoints = path,
                blockBunchWeightsKg = defaultWeights(session.blockBunchWeightsKg),
                routeSourceSessionId = route.sourceSessionId,
            ),
        )
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Bunch Count Trip") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    // Secondary trip actions — deliberately kept out of the
                    // route preview so Start Sampling stays the single
                    // primary action.
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = "Trip options", tint = vine.textPrimary)
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        if (session.totalSiteCount > 0 && !session.isCompleted) {
                            DropdownMenuItem(
                                text = { Text("Change Route") },
                                onClick = {
                                    menuOpen = false
                                    onApply(session.copy(sampleSites = emptyList(), pathWaypoints = emptyList(), routeSourceSessionId = null))
                                },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text("Discard Trip", color = VineColors.Destructive) },
                            onClick = {
                                menuOpen = false
                                showDiscardConfirm = true
                            },
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        if (session.totalSiteCount > 0) {
            // Route confirmation — the map is the dominant content.
            TripRoutePreview(
                padding = padding,
                blocks = selectedBlocks,
                session = session,
                controls = controls,
                onSiteTap = { selectedSite = it },
                onRegenerate = { generateNewRoute() },
                onStartSampling = onStartSampling,
                onCompleteTrip = onCompleteTrip,
            )
        } else {
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(0.dp))

            // Progress summary.
            VineyardCard {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    EstimationStat("Blocks", selectedBlocks.size.toString(), VineColors.Indigo, Modifier.weight(1f))
                    EstimationStat(
                        "Samples",
                        "${session.recordedSiteCount}/${session.totalSiteCount}",
                        VineColors.Purple,
                        Modifier.weight(1f),
                    )
                    EstimationStat(
                        "Density",
                        "${session.samplesPerHectare}/ha",
                        VineColors.LeafGreen,
                        Modifier.weight(1f),
                    )
                }
            }

            // Step 2 — blocks.
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Blocks to sample", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        TextButton(onClick = {
                            val all = blocks.map { it.id }
                            onApply(session.withSelection(if (selectedBlocks.size == blocks.size) emptyList() else all))
                        }) {
                            Text(if (selectedBlocks.size == blocks.size) "Clear" else "Select all")
                        }
                    }
                    blocks.forEach { block ->
                        val checked = session.isPaddockSelected(block.id)
                        Row(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                                .clickable { onApply(session.toggleBlock(block.id)) }
                                .padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(checked = checked, onCheckedChange = { onApply(session.toggleBlock(block.id)) })
                            Column(modifier = Modifier.weight(1f)) {
                                Text(block.name, color = vine.textPrimary, fontWeight = FontWeight.Medium)
                                Text(
                                    "${YieldVintageReport.varietyLabel(block)} · ${formatArea(block.areaHectares)} ha · ${block.effectiveVineCount} vines",
                                    color = vine.textSecondary,
                                    fontSize = 12.sp,
                                )
                            }
                        }
                    }
                }
            }

            // Steps 3–5 — sample density + route (reuse or generate).
            if (session.totalSiteCount == 0) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Number of samples", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                                Text("Sample sites per hectare — saved as the default for the next trip", color = vine.textSecondary, fontSize = 12.sp)
                            }
                            Stepper(
                                value = session.samplesPerHectare,
                                onChange = {
                                    onApply(session.copy(samplesPerHectare = it))
                                    // A changed count becomes the shared vineyard default (sql/187).
                                    vm.saveYieldSamplingDefault(it)
                                },
                            )
                        }
                        val expected = YieldSampleGenerator.expectedSampleCount(
                            blocks, session.selectedPaddockIds, session.samplesPerHectare,
                        )
                        Text(
                            "${formatArea(YieldSampleGenerator.totalSelectedArea(blocks, session.selectedPaddockIds))} ha selected · ~$expected sample sites",
                            color = vine.textSecondary,
                            fontSize = 12.sp,
                        )

                        if (reusable != null) {
                            Text(
                                "A previous trip already has a route for ${if (selectedBlocks.size == 1) "this block" else "these blocks"}. Reusing it revisits the same sample locations for comparable counts.",
                                color = vine.textSecondary, fontSize = 12.sp,
                            )
                            Button(
                                onClick = { useExistingRoute() },
                                enabled = selectedBlocks.isNotEmpty(),
                                modifier = Modifier.fillMaxWidth().height(48.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Info),
                            ) {
                                Icon(Icons.Filled.Route, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Use Existing Route (${reusable.sites.size} sites)")
                            }
                            OutlinedButton(
                                onClick = { generateNewRoute() },
                                enabled = selectedBlocks.isNotEmpty(),
                                modifier = Modifier.fillMaxWidth().height(48.dp),
                            ) {
                                Icon(Icons.Filled.AutoGraph, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Generate New Route")
                            }
                        } else {
                            Button(
                                onClick = { generateNewRoute() },
                                enabled = selectedBlocks.isNotEmpty(),
                                modifier = Modifier.fillMaxWidth().height(48.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                            ) {
                                Icon(Icons.Filled.AutoGraph, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Generate Route")
                            }
                        }
                    }
                }
            }
        }
        }
    }

    selectedSite?.let { site ->
        BunchCountDialog(
            site = site,
            onDismiss = { selectedSite = null },
            onSave = { bunches ->
                onApply(session.recordBunch(site.id, bunches, state.currentUserId ?: ""))
                selectedSite = null
            },
        )
    }

    if (showDiscardConfirm) {
        AlertDialog(
            onDismissRequest = { showDiscardConfirm = false },
            title = { Text("Discard this trip?") },
            text = { Text("This removes the trip's route and any recorded bunch counts. Completed trips are not affected. This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    showDiscardConfirm = false
                    onDiscard()
                }) { Text("Discard", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showDiscardConfirm = false }) { Text("Cancel") } },
        )
    }
}

/**
 * Simplified pre-start route confirmation — the map dominates the screen;
 * the only actions are Start Sampling (plus a single Regenerate Path for
 * newly generated routes). Bunch weights stay at the completion stage;
 * progress and Complete Estimation appear only once sampling has started;
 * delete/change-route live in the top-bar overflow menu. Mirrors iOS.
 */
@Composable
private fun TripRoutePreview(
    padding: PaddingValues,
    blocks: List<Paddock>,
    session: YieldEstimationSession,
    controls: BunchCountTripLogic.RoutePreviewControls,
    onSiteTap: (SampleSite) -> Unit,
    onRegenerate: () -> Unit,
    onStartSampling: () -> Unit,
    onCompleteTrip: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier.fillMaxSize().padding(padding)
            .padding(horizontal = 16.dp).padding(bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SamplePreviewMap(
            blocks = blocks,
            session = session,
            onSiteTap = onSiteTap,
            modifier = Modifier.weight(1f),
        )
        if (controls.showsReuseIndicator) {
            Text(
                "Using previous sampling route",
                color = vine.textSecondary,
                fontSize = 12.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (controls.showsRegeneratePath) {
            OutlinedButton(
                onClick = onRegenerate,
                modifier = Modifier.fillMaxWidth().height(48.dp),
            ) {
                Icon(Icons.Filled.AutoGraph, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Regenerate Path")
            }
        }
        if (controls.showsStartSampling) {
            Button(
                onClick = onStartSampling,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Info),
            ) {
                Icon(Icons.Filled.Explore, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    if (controls.startSamplingIsContinue) "Continue Sampling" else "Start Sampling",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
        if (controls.showsProgress) {
            LinearProgressIndicator(
                progress = { session.recordedSiteCount.toFloat() / session.totalSiteCount },
                modifier = Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)),
                color = VineColors.LeafGreen,
                trackColor = vine.cardBackground,
            )
            Text(
                "Sample ${session.recordedSiteCount} of ${session.totalSiteCount} recorded",
                color = vine.textSecondary, fontSize = 12.sp,
            )
        }
        if (controls.showsCompleteAction) {
            Button(
                onClick = onCompleteTrip,
                modifier = Modifier.fillMaxWidth().height(48.dp),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.DarkGreen),
            ) {
                Icon(Icons.Filled.DoneAll, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Complete Estimation")
            }
        }
    }
}

private fun YieldEstimationSession.toggleBlock(blockId: String): YieldEstimationSession {
    val selected = selectedPaddockIds.toMutableList()
    val idx = selected.indexOfFirst { it.equals(blockId, ignoreCase = true) }
    if (idx >= 0) selected.removeAt(idx) else selected.add(blockId)
    // Changing the block set invalidates the generated/reused route.
    return copy(selectedPaddockIds = selected, sampleSites = emptyList(), pathWaypoints = emptyList(), routeSourceSessionId = null)
}

private fun YieldEstimationSession.withSelection(ids: List<String>): YieldEstimationSession =
    copy(selectedPaddockIds = ids, sampleSites = emptyList(), pathWaypoints = emptyList(), routeSourceSessionId = null)

// =============================================================================
// Step 10–13 — Completion: per-block summary, bunch weights, damage, save
// =============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripCompletionScreen(
    vm: AppViewModel,
    state: AppUiState,
    session: YieldEstimationSession,
    onApply: (YieldEstimationSession) -> Unit,
    onSaved: () -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val bunchWeightStore = remember { com.rork.vinetrack.data.BunchWeightDefaultsStore(context) }
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    var editingWeightFor by remember { mutableStateOf<Paddock?>(null) }
    var showSaveConfirm by remember { mutableStateOf(false) }

    val selectedBlocks = blocks.filter { session.isPaddockSelected(it.id) }
    // Base (no damage) and current damage factor per block — the base is
    // always shown so applying damage never hides the field observation.
    val baseEstimates = remember(session, blocks) {
        YieldSampleGenerator.calculateYieldEstimates(session, blocks) { 1.0 }
    }
    val fmt = state.regionFormatter
    val baseTotal = baseEstimates.sumOf { it.estimatedYieldTonnes }
    val adjustedTotal = baseEstimates.sumOf {
        it.estimatedYieldTonnes * state.damageRecords.damageFactor(it.paddockId)
    }
    val displayTotal = if (session.applyDamage) adjustedTotal else baseTotal

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Complete Estimation") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(0.dp))

            if (session.recordedSiteCount < session.totalSiteCount) {
                VineyardCard {
                    Text(
                        "${session.totalSiteCount - session.recordedSiteCount} sample site${if (session.totalSiteCount - session.recordedSiteCount == 1) "" else "s"} not recorded — the estimate uses the recorded samples only.",
                        color = VineColors.Orange, fontSize = 13.sp,
                    )
                }
            }

            // Per-block summary + bunch weight confirmation.
            Text("Confirm average bunch weight for each block", color = vine.textSecondary, fontSize = 13.sp)
            selectedBlocks.forEach { block ->
                val base = baseEstimates.firstOrNull { it.paddockId.equals(block.id, ignoreCase = true) } ?: return@forEach
                val factor = state.damageRecords.damageFactor(block.id)
                val adjusted = base.estimatedYieldTonnes * factor
                val display = if (session.applyDamage) adjusted else base.estimatedYieldTonnes
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(block.name, color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                                Text(YieldVintageReport.varietyLabel(block), color = vine.textSecondary, fontSize = 12.sp)
                            }
                            Text("${formatTonnes(display)} t", color = VineColors.LeafGreen, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        }
                        Text(
                            "${base.samplesRecorded}/${base.samplesTotal} samples · ${formatBunches(base.averageBunchesPerVine)} bunches/vine · ${base.totalVines} vines",
                            color = vine.textSecondary, fontSize = 12.sp,
                        )
                        if (block.areaHectares > 0) {
                            Text(
                                fmt.formatYieldPerArea(display / block.areaHectares),
                                color = vine.textSecondary, fontSize = 12.sp,
                            )
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                                .clickable { editingWeightFor = block }.padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Filled.Scale, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Average bunch weight", color = vine.textPrimary, modifier = Modifier.weight(1f), fontSize = 13.sp)
                            Text(
                                "${formatGrams(session.bunchWeightKg(block.id))} g",
                                color = VineColors.Info, fontWeight = FontWeight.SemiBold,
                            )
                        }
                        if (session.applyDamage && factor < 1.0) {
                            Text(
                                "Base ${formatTonnes(base.estimatedYieldTonnes)} t → damage adjusted ${formatTonnes(adjusted)} t (${((1 - factor) * 100).roundToInt()}% loss)",
                                color = VineColors.Orange, fontSize = 12.sp,
                            )
                        }
                    }
                }
            }

            // Step 12 — damage adjustment (presentation-time; base is preserved).
            VineyardCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Apply recorded damage", color = vine.textPrimary, fontWeight = FontWeight.SemiBold)
                        Text(
                            "Adjusts the displayed estimate by current damage records. The base bunch-count estimate is always kept.",
                            color = vine.textSecondary, fontSize = 12.sp,
                        )
                    }
                    Switch(
                        checked = session.applyDamage,
                        onCheckedChange = { onApply(session.copy(applyDamage = it)) },
                    )
                }
            }

            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row {
                        Text("Yield Estimate", color = vine.textPrimary, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        Text("${formatTonnes(displayTotal)} t", color = VineColors.LeafGreen, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                    }
                    if (session.applyDamage && adjustedTotal < baseTotal) {
                        Text("Base estimate ${formatTonnes(baseTotal)} t before damage", color = vine.textSecondary, fontSize = 12.sp)
                    }
                }
            }

            Button(
                onClick = { showSaveConfirm = true },
                enabled = session.recordedSiteCount > 0,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.DarkGreen),
            ) {
                Icon(Icons.Filled.DoneAll, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Save Bunch Count Trip", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }

    editingWeightFor?.let { block ->
        BunchWeightDialog(
            blockName = block.name,
            currentKg = session.bunchWeightKg(block.id),
            onDismiss = { editingWeightFor = null },
            onSave = { kg ->
                val weights = session.blockBunchWeightsKg.toMutableMap()
                weights[block.id] = kg
                onApply(session.copy(blockBunchWeightsKg = weights))
                // Sync the edited weight back as the block's default (matches iOS).
                bunchWeightStore.setWeightGrams(block.id, kg * 1000.0)
                editingWeightFor = null
            },
        )
    }

    if (showSaveConfirm) {
        AlertDialog(
            onDismissRequest = { showSaveConfirm = false },
            title = { Text("Save Bunch Count Trip?") },
            text = { Text("This completes the trip as a dated observation. It becomes the latest estimate for its blocks; earlier trips stay in history. Counts and weights can no longer be edited.") },
            confirmButton = {
                TextButton(onClick = {
                    onApply(session.copy(isCompleted = true, completedAt = Instant.now().toString()))
                    showSaveConfirm = false
                    onSaved()
                }) { Text("Save Trip") }
            },
            dismissButton = { TextButton(onClick = { showSaveConfirm = false }) { Text("Cancel") } },
        )
    }
}

// =============================================================================
// History — read-only completed trip
// =============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CompletedTripScreen(
    vm: AppViewModel,
    state: AppUiState,
    session: YieldEstimationSession,
    onDeleted: () -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    var showDeleteConfirm by remember { mutableStateOf(false) }

    val baseEstimates = remember(session, blocks) {
        YieldSampleGenerator.calculateYieldEstimates(session, blocks) { 1.0 }
    }
    val vintage = YieldVintageReport.sessionVintage(session, state.seasonStartMonth, state.seasonStartDay)

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Bunch Count Trip") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(0.dp))

            Row(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                    .background(VineColors.DarkGreen.copy(alpha = 0.12f)).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(Icons.Filled.Lock, contentDescription = null, tint = VineColors.DarkGreen, modifier = Modifier.size(20.dp))
                Text(
                    "Completed ${(session.completedAt ?: session.createdAt).take(10)} · Vintage $vintage",
                    color = vine.textPrimary,
                    fontWeight = FontWeight.Medium,
                )
            }

            baseEstimates.filter { it.samplesRecorded > 0 }.forEach { e ->
                val factor = state.damageRecords.damageFactor(e.paddockId)
                val display = if (session.applyDamage) e.estimatedYieldTonnes * factor else e.estimatedYieldTonnes
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row {
                            Text(e.paddockName, color = vine.textPrimary, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Text("${formatTonnes(display)} t", color = VineColors.LeafGreen, fontWeight = FontWeight.Bold)
                        }
                        Text(
                            "${e.samplesRecorded}/${e.samplesTotal} samples · ${formatBunches(e.averageBunchesPerVine)} bunches/vine · ${formatGrams(e.averageBunchWeightKg)} g/bunch",
                            color = vine.textSecondary, fontSize = 12.sp,
                        )
                        if (session.applyDamage && factor < 1.0) {
                            Text(
                                "Base ${formatTonnes(e.estimatedYieldTonnes)} t before damage adjustment",
                                color = vine.textSecondary, fontSize = 12.sp,
                            )
                        }
                    }
                }
            }

            SamplePreviewMap(
                blocks = blocks.filter { session.isPaddockSelected(it.id) },
                session = session,
                onSiteTap = {},
            )

            TextButton(onClick = { showDeleteConfirm = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Delete Trip", color = VineColors.Destructive)
            }
        }
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("Delete this trip?") },
            text = { Text("This removes the trip's bunch counts and estimate for everyone. If it is the latest trip, the previous trip becomes the current estimate. This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteYieldSession(session.id)
                    showDeleteConfirm = false
                    onDeleted()
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel") } },
        )
    }
}

// =============================================================================
// Shared components
// =============================================================================

@Composable
private fun EstimationStat(label: String, value: String, color: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, color = color, fontWeight = FontWeight.Bold, fontSize = 18.sp)
        Text(label, color = vine.textSecondary, fontSize = 11.sp)
    }
}

@Composable
private fun Stepper(value: Int, onChange: (Int) -> Unit) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { if (value > 1) onChange(value - 1) }) {
            Icon(Icons.Filled.Remove, contentDescription = "Fewer", tint = vine.textPrimary)
        }
        Text(
            "$value",
            color = vine.textPrimary,
            fontWeight = FontWeight.Bold,
            fontSize = 16.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.width(36.dp),
        )
        IconButton(onClick = { if (value < 100) onChange(value + 1) }) {
            Icon(Icons.Filled.Add, contentDescription = "More", tint = vine.textPrimary)
        }
    }
}

@Composable
private fun SamplePreviewMap(
    blocks: List<Paddock>,
    session: YieldEstimationSession,
    onSiteTap: (SampleSite) -> Unit,
    modifier: Modifier = Modifier.height(300.dp),
) {
    val camera = rememberCameraPositionState()
    val allPoints = remember(blocks, session.sampleSites) {
        blocks.flatMap { it.polygonPoints ?: emptyList() }.map { LatLng(it.latitude, it.longitude) } +
            session.sampleSites.map { LatLng(it.latitude, it.longitude) }
    }
    var mapLoaded by remember { mutableStateOf(false) }
    // Frame only after the map has a measured size; re-frame when content changes.
    LaunchedEffect(mapLoaded, allPoints) {
        if (!mapLoaded) return@LaunchedEffect
        camera.fitToContent(points = allPoints, paddingPx = 120)
    }
    Box(modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = camera,
            properties = MapProperties(mapType = MapType.HYBRID),
            uiSettings = MapUiSettings(zoomControlsEnabled = false, mapToolbarEnabled = false),
            onMapLoaded = { mapLoaded = true },
        ) {
            blocks.forEach { block ->
                val pts = block.polygonPoints?.map { LatLng(it.latitude, it.longitude) } ?: emptyList()
                if (pts.size >= 3) {
                    Polygon(
                        points = pts,
                        fillColor = VineColors.LeafGreen.copy(alpha = 0.08f),
                        strokeColor = VineColors.LeafGreen.copy(alpha = 0.6f),
                        strokeWidth = 3f,
                    )
                }
            }
            if (session.pathWaypoints.size >= 2) {
                Polyline(
                    points = session.pathWaypoints.map { LatLng(it.latitude, it.longitude) },
                    color = VineColors.Info.copy(alpha = 0.8f),
                    width = 5f,
                )
            }
            session.sampleSites.forEach { site ->
                Marker(
                    state = MarkerState(position = LatLng(site.latitude, site.longitude)),
                    title = "Sample ${site.siteIndex}",
                    snippet = site.bunchCountEntry?.let { "${formatBunches(it.bunchesPerVine)} bunches/vine" } ?: "Tap to record",
                    icon = BitmapDescriptorFactory.defaultMarker(
                        if (site.isRecorded) BitmapDescriptorFactory.HUE_GREEN else BitmapDescriptorFactory.HUE_ORANGE,
                    ),
                    onClick = {
                        onSiteTap(site)
                        true
                    },
                )
            }
        }
    }
}

/**
 * Steps 7–9 — full-screen GPS-guided sampling map. Shows the block boundary,
 * route, completed vs remaining sample locations and the operator's live
 * position; guides site-to-site with a distance read-out and records bunch
 * counts. GPS proximity is guidance only — any site can be recorded by
 * tapping its marker (manual entry is never blocked by GPS precision).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun YieldSamplingMapScreen(
    state: AppUiState,
    session: YieldEstimationSession,
    onRecord: (siteId: String, bunches: Double, recordedBy: String) -> Unit,
    onComplete: () -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tracker = remember { LocationTracker(context) }
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }

    var here by remember { mutableStateOf<CoordinatePoint?>(null) }
    var recordingSite by remember { mutableStateOf<SampleSite?>(null) }

    val camera = rememberCameraPositionState()
    var samplingMapLoaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        here = tracker.currentLocation()
    }
    // Frame the sample sites (falling back to the selected blocks' geometry)
    // once the map is laid out.
    LaunchedEffect(samplingMapLoaded, session.sampleSites) {
        if (!samplingMapLoaded) return@LaunchedEffect
        val pts = session.sampleSites.map { LatLng(it.latitude, it.longitude) }.ifEmpty {
            blocks.filter { session.isPaddockSelected(it.id) }
                .flatMap { it.polygonPoints ?: emptyList() }
                .map { LatLng(it.latitude, it.longitude) }
        }
        camera.fitToContent(points = pts, paddingPx = 120)
    }

    val unrecorded = session.sampleSites.filter { !it.isRecorded }
    val allRecorded = session.totalSiteCount > 0 && unrecorded.isEmpty()
    val nearest = remember(here, session.sampleSites) {
        val h = here ?: return@remember unrecorded.firstOrNull()
        unrecorded.minByOrNull { metresBetween(h.latitude, h.longitude, it.latitude, it.longitude) }
    }
    val nearestDistance = nearest?.let { n ->
        here?.let { h -> metresBetween(h.latitude, h.longitude, n.latitude, n.longitude) }
    }
    // Which block the user is currently sampling (multi-block trips).
    val currentBlockName = nearest?.paddockName?.ifBlank {
        blocks.firstOrNull { it.id.equals(nearest.paddockId, ignoreCase = true) }?.name ?: ""
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(currentBlockName?.takeIf { it.isNotBlank() }?.let { "Sampling · $it" } ?: "Sampling") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                GoogleMap(
                    modifier = Modifier.fillMaxSize(),
                    cameraPositionState = camera,
                    properties = MapProperties(mapType = MapType.HYBRID, isMyLocationEnabled = tracker.hasPermission),
                    uiSettings = MapUiSettings(zoomControlsEnabled = false, mapToolbarEnabled = false),
                    onMapLoaded = { samplingMapLoaded = true },
                ) {
                    blocks.filter { session.isPaddockSelected(it.id) }.forEach { block ->
                        val pts = block.polygonPoints?.map { LatLng(it.latitude, it.longitude) } ?: emptyList()
                        if (pts.size >= 3) {
                            Polygon(
                                points = pts,
                                fillColor = VineColors.LeafGreen.copy(alpha = 0.08f),
                                strokeColor = VineColors.LeafGreen.copy(alpha = 0.6f),
                                strokeWidth = 3f,
                            )
                        }
                    }
                    if (session.pathWaypoints.size >= 2) {
                        Polyline(
                            points = session.pathWaypoints.map { LatLng(it.latitude, it.longitude) },
                            color = VineColors.Info.copy(alpha = 0.7f),
                            width = 4f,
                        )
                    }
                    session.sampleSites.forEach { site ->
                        val hue = when {
                            site.id == nearest?.id -> BitmapDescriptorFactory.HUE_AZURE
                            site.isRecorded -> BitmapDescriptorFactory.HUE_GREEN
                            else -> BitmapDescriptorFactory.HUE_ORANGE
                        }
                        Marker(
                            state = MarkerState(position = LatLng(site.latitude, site.longitude)),
                            title = "Sample ${site.siteIndex}",
                            icon = BitmapDescriptorFactory.defaultMarker(hue),
                            onClick = { recordingSite = site; true },
                        )
                    }
                }
            }

            // Guidance / record bar.
            VineyardCard(modifier = Modifier.padding(12.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.MyLocation, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(
                            when {
                                allRecorded -> "All sample sites recorded"
                                nearest == null -> "No sample sites"
                                nearestDistance == null -> "Next: Sample ${nearest.siteIndex}"
                                else -> "Next: Sample ${nearest.siteIndex} · ${nearestDistance.roundToInt()} m away"
                            },
                            color = vine.textPrimary,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(onClick = { scope.launch { here = tracker.currentLocation() } }) {
                            Icon(Icons.Filled.MyLocation, contentDescription = "Refresh location", tint = vine.textSecondary)
                        }
                    }
                    Text(
                        "Sample ${session.recordedSiteCount} of ${session.totalSiteCount} recorded" +
                            (currentBlockName?.takeIf { it.isNotBlank() }?.let { " · $it" } ?: ""),
                        color = vine.textSecondary,
                        fontSize = 12.sp,
                    )
                    if (allRecorded) {
                        Button(
                            onClick = onComplete,
                            modifier = Modifier.fillMaxWidth().height(48.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.DarkGreen),
                        ) {
                            Icon(Icons.Filled.DoneAll, contentDescription = null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Complete Estimation")
                        }
                    } else {
                        Button(
                            onClick = { nearest?.let { recordingSite = it } },
                            enabled = nearest != null,
                            modifier = Modifier.fillMaxWidth().height(48.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                        ) {
                            Icon(Icons.Filled.CheckCircle, contentDescription = null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(if (nearest != null) "Record Sample ${nearest.siteIndex}" else "Done")
                        }
                    }
                }
            }
        }
    }

    recordingSite?.let { site ->
        BunchCountDialog(
            site = site,
            onDismiss = { recordingSite = null },
            onSave = { bunches ->
                onRecord(site.id, bunches, state.currentUserId ?: "")
                recordingSite = null
            },
        )
    }
}

@Composable
private fun BunchCountDialog(
    site: SampleSite,
    onDismiss: () -> Unit,
    onSave: (Double) -> Unit,
) {
    var text by remember { mutableStateOf(site.bunchCountEntry?.bunchesPerVine?.let { trimNumber(it) } ?: "") }
    val value = text.toDoubleOrNull()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sample ${site.siteIndex} · Row ${site.rowNumber}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Number of bunches per vine at this site", fontSize = 13.sp)
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it.filter { c -> c.isDigit() || c == '.' } },
                    singleLine = true,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = value != null && value >= 0,
                onClick = { value?.let(onSave) },
            ) { Text("Record") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun BunchWeightDialog(
    blockName: String,
    currentKg: Double,
    onDismiss: () -> Unit,
    onSave: (Double) -> Unit,
) {
    var text by remember { mutableStateOf(formatGrams(currentKg)) }
    val grams = text.toDoubleOrNull()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(blockName) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Average bunch weight (grams)", fontSize = 13.sp)
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it.filter { c -> c.isDigit() || c == '.' } },
                    singleLine = true,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = grams != null && grams > 0,
                onClick = { grams?.let { onSave(it / 1000.0) } },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// MARK: - formatting / geometry helpers

private fun metresBetween(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val mPerDegLat = 111_320.0
    val mPerDegLon = 111_320.0 * cos(((lat1 + lat2) / 2) * Math.PI / 180.0)
    val dLat = (lat2 - lat1) * mPerDegLat
    val dLon = (lon2 - lon1) * mPerDegLon
    return sqrt(dLat * dLat + dLon * dLon)
}

private fun formatTonnes(t: Double): String = if (t >= 100) t.roundToInt().toString() else String.format("%.1f", t)
private fun formatArea(ha: Double): String = String.format("%.2f", ha)
private fun formatGrams(kg: Double): String = (kg * 1000).roundToInt().toString()
private fun formatBunches(b: Double): String = String.format("%.1f", b)
private fun trimNumber(d: Double): String = if (d == d.toLong().toDouble()) d.toLong().toString() else d.toString()
