package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
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
import androidx.compose.ui.platform.testTag
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
import com.rork.vinetrack.data.YieldSamplingSiteRepository
import com.rork.vinetrack.data.YieldSiteSetSource
import com.rork.vinetrack.data.ConfirmedYieldSites
import com.rork.vinetrack.data.RowAttachment
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.toSampleSite
import com.rork.vinetrack.data.YieldSamplingNavigation
import com.rork.vinetrack.data.YieldSampleGenerator
import com.rork.vinetrack.data.YieldVintageReport
import com.rork.vinetrack.data.model.BunchCountEntry
import com.rork.vinetrack.data.model.PanelCountEntry
import com.rork.vinetrack.data.model.PanelCountMeasurement
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.data.remainingYieldMultiplierForVintage
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.data.model.QuadrantCountMeasurement
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.time.Instant
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** Allows native tests to exclude an emulator map renderer without replacing workflow controls. */
internal val LocalYieldMapPreview = androidx.compose.runtime.staticCompositionLocalOf<(@Composable () -> Unit)?> { null }

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
    var showCountMethod by rememberSaveable { mutableStateOf(false) }
    var showPermanentSites by rememberSaveable { mutableStateOf(false) }
    var viewingTripId by rememberSaveable { mutableStateOf("") }
    var showSampling by rememberSaveable { mutableStateOf(false) }
    var showCompletion by rememberSaveable { mutableStateOf(false) }
    // Local optimistic draft so typing/taps never wait for state round-trips.
    var localDraft by remember { mutableStateOf<YieldEstimationSession?>(null) }

    val visibleTrips = state.yieldSessions.filter { !it.isQuadrantCount || state.isSystemAdmin }
    val draft = BunchCountTripLogic.activeDraft(visibleTrips, vineyardId)
    val completedTrips = BunchCountTripLogic.completedTrips(visibleTrips, vineyardId)

    val session: YieldEstimationSession? =
        localDraft?.takeIf { it.id == activeTripId && (!it.isQuadrantCount || state.isSystemAdmin) }
            ?: visibleTrips.firstOrNull { it.id == activeTripId }

    fun apply(updated: YieldEstimationSession): Boolean {
        var saved = false
        vm.saveYieldSession(updated) { accepted ->
            saved = accepted
            if (accepted) localDraft = updated
        }
        return saved
    }

    fun startCount(method: String) {
        if (method == "quadrant" && !state.isSystemAdmin) return
        if (method !in setOf("per_vine", "quadrant", "panel")) return
        val vid = vineyardId ?: return
        val fresh = BunchCountTripLogic.startTrip(vid, state.yieldSamplesPerHectareDefault).let {
            when (method) {
                "quadrant" -> it.copy(countMethod = "quadrant", quadrantSectionLengthCm = 60.0)
                "panel" -> it.copy(countMethod = "panel")
                else -> it
            }
        }
        vm.saveYieldSession(fresh) { accepted ->
            if (accepted) { localDraft = fresh; activeTripId = fresh.id }
        }
        showCountMethod = false
    }
    if (showCountMethod) {
        AlertDialog(onDismissRequest = { showCountMethod = false },
            title = { Text("Choose Yield Estimate Count Method") },
            text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { startCount("per_vine") }) { Text("1. Bunches Per Vine Count") }
                TextButton(onClick = { startCount("quadrant") }, enabled = state.isSystemAdmin) {
                    Text("2. Quadrant Count" + if (state.isSystemAdmin) "" else " (System Admin only)")
                }
                TextButton(onClick = { startCount("panel") }) { Text("3. Panel Count") }
            } },
            confirmButton = { TextButton(onClick = { showCountMethod = false }) { Text("Cancel") } })
    }

    fun closeTrip() {
        activeTripId = ""
        localDraft = null
        showSampling = false
        showCompletion = false
    }

    val screen = when {
        showPermanentSites -> "permanentSites"
        session != null && showSampling -> "sampling"
        session != null && showCompletion -> "completion"
        session != null -> "setup"
        viewingTripId.isNotBlank() -> "history"
        else -> "home"
    }

    if (state.yieldSessionError?.startsWith("Trip could not be saved") == true) {
        AlertDialog(onDismissRequest = { vm.clearYieldSessionError() },
            title = { Text("Trip not saved") },
            text = { Text(state.yieldSessionError) },
            confirmButton = { TextButton(onClick = { vm.clearYieldSessionError() }) { Text("OK") } })
    }

    androidx.activity.compose.BackHandler(enabled = screen != "home") {
        if (showPermanentSites) showPermanentSites = false
        else { viewingTripId = ""; closeTrip() }
    }

    AnimatedContent(
        targetState = screen,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "bunch-count-trip-nav",
    ) { current ->
        when (current) {
            "permanentSites" -> YieldPermanentSamplingSitesScreen(state) { showPermanentSites = false }
            "sampling" -> session?.let { s ->
                YieldSamplingMapScreen(
                    state = state,
                    session = s,
                    onRecord = { siteId, bunches, recordedBy ->
                        apply(s.recordBunch(siteId, bunches, recordedBy))
                    },
                    onQuadrantRecord = { siteId, measurement ->
                        state.isSystemAdmin && apply(s.recordQuadrant(siteId, measurement, state.currentUserId ?: ""))
                    },
                    onPanelRecord = { siteId, measurement ->
                        apply(s.recordPanel(siteId, measurement, state.currentUserId ?: ""))
                    },
                    onComplete = { showSampling = false; showCompletion = true },
                    onBack = { closeTrip() },
                )
            }
            "completion" -> session?.let { s ->
                TripCompletionScreen(
                    vm = vm,
                    state = state,
                    session = s,
                    onApply = { apply(it) },
                    onSaved = { closeTrip() },
                    onBack = { closeTrip() },
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
                    showCountMethod = true
                },
                onPermanentSites = { showPermanentSites = true },
                onResume = { resumed ->
                    activeTripId = resumed.id
                    localDraft = null
                    // Recorded drafts open at their editable sample list/map,
                    // not the setup-only route preview.
                    showSampling = resumed.sampleSites.isNotEmpty() && !resumed.isCompleted
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
): YieldEstimationSession = if (isQuadrantCount || isPanelCount) this else copy(
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

private fun YieldEstimationSession.recordPanel(
    siteId: String, measurement: PanelCountMeasurement, recordedBy: String,
): YieldEstimationSession {
    if (!isPanelCount || isCompleted) return this
    val checked = PanelCountMeasurement.make(measurement.totalBunches, measurement.plantedPositions,
        measurement.fruitingVines, measurement.missingPositions,
        measurement.nonproductiveVines, measurement.panelLengthMetres) ?: return this
    return copy(sampleSites = sampleSites.map { site ->
        if (site.id.equals(siteId, true)) site.copy(
            bunchCountEntry = null,
            panelCountEntry = PanelCountEntry(checked, Instant.now().toString(), recordedBy),
        ) else site
    })
}

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
    onPermanentSites: () -> Unit,
    onResume: (YieldEstimationSession) -> Unit,
    onOpenTrip: (YieldEstimationSession) -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    // One resolver refresh for the list, not one complete vineyard refresh per history row.
    val weights = rememberYieldMasterWeights(state)

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Yield Estimate Trips") },
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
                        Text("Yield Estimate Trip", color = vine.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    }
                    Text(
                        "Choose a count method and collect yield samples by block. " +
                            "Permanent sampling locations are optional.",
                        color = vine.textSecondary, fontSize = 13.sp,
                    )
                    Text(
                        "Completed trips remain in history. The active estimate selection is unchanged until the new methods are enabled.",
                        color = vine.textSecondary, fontSize = 12.sp,
                    )
                }
            }

            // Keep the primary action directly below the introduction, even with a draft.
                Button(
                    onClick = onStart,
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                    enabled = blocks.isNotEmpty(),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Info),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Start Yield Estimate Trip", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
                OutlinedButton(
                    onClick = onPermanentSites,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("yield.sites.open"),
                    enabled = blocks.isNotEmpty(),
                ) { Text("Set Permanent Locations (Optional)", color = VineColors.Purple) }

            if (blocks.isEmpty()) {
                VineyardCard {
                    Text(
                        "Map at least one block boundary in Blocks before starting a yield estimate trip.",
                        color = vine.textSecondary, fontSize = 13.sp,
                    )
                }
            } else {
                if (draft != null) {
                    VineyardCard(modifier = Modifier.testTag("yield.resume").clickable { onResume(draft) }) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(22.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(if (draft.isQuadrantCount) "Resume Quadrant Count" else "Resume trip in progress", color = vine.textPrimary, fontWeight = FontWeight.SemiBold)
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

                if (draft != null) {
                    Text("Draft · Recorded Observations", color = vine.textSecondary)
                    Column(modifier = Modifier.fillMaxWidth()
                        .testTag("yield.draft.recorded.open")
                        .clickable { onResume(draft) }) {
                        if (draft.isPanelCount) PanelCountSummary(draft)
                        else CurrentTripEstimateSummary(state, draft, detailed = false)
                        Text("Tap to review, correct or delete a recorded sample",
                            color = VineColors.Info, fontSize = 13.sp)
                    }
                }
            }

            if (completedTrips.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.History, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                    Text("Completed trips", color = vine.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
                completedTrips.forEach { trip ->
                    val tripVintage = YieldVintageReport.sessionVintage(
                        trip, state.seasonStartMonth, state.seasonStartDay,
                    )
                    val currentEstimate = remember(trip, state.paddocks, weights, state.damageRecords, state.seasonStartMonth, state.seasonStartDay) {
                        com.rork.vinetrack.data.CurrentYieldEstimate.trip(trip, state.paddocks, weights) { block ->
                            state.damageRecords.remainingYieldMultiplierForVintage(block, state.paddocks, tripVintage, state.seasonStartMonth, state.seasonStartDay)
                        }
                    }
                    VineyardCard(modifier = Modifier.testTag("yield.completed.${trip.id.lowercase()}").clickable { onOpenTrip(trip) }) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(currentEstimate.blocks.joinToString(", ") { it.name }.ifBlank { "Block unavailable" },
                                    color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 2)
                                Text(currentEstimate.blocks.map { it.varieties }.filter { it.isNotBlank() }.distinct().joinToString(", "),
                                    color = vine.textSecondary, fontSize = 12.sp, maxLines = 2)
                                Text((trip.completedAt ?: trip.createdAt).take(10), color = vine.textSecondary, fontSize = 12.sp)
                            }
                            Text(currentEstimate.totalTonnes?.let { String.format(java.util.Locale.US, "%.3f t", it) } ?: "Bunch weight required",
                                color = VineColors.LeafGreen, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, modifier = Modifier.widthIn(max = 120.dp))
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "Open trip", tint = vine.textSecondary)
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
    onApply: (YieldEstimationSession) -> Boolean,
    onStartSampling: () -> Unit,
    onCompleteTrip: () -> Unit,
    onDiscard: () -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    // Block areas are stored in canonical hectares; display follows the
    // vineyard's Region & Units.
    val blockAreaFmt = LocalRegionFormatter.current

    var selectedSite by remember { mutableStateOf<SampleSite?>(null) }
    var showDiscardConfirm by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val siteRepo = remember(context) { YieldSamplingSiteRepository(SessionStore(context)) }
    val siteScope = rememberCoroutineScope()
    var verifiedSources by remember { mutableStateOf<Map<String, ConfirmedYieldSites>>(emptyMap()) }
    var savedLocationBlocks by remember { mutableStateOf<Set<String>>(emptySet()) }
    var loadingSources by remember { mutableStateOf(false) }
    var preparingRoute by remember { mutableStateOf(false) }
    var routeSourceError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(state.selectedVineyardId, session.selectedPaddockIds, session.sampleSites.isEmpty()) {
        val vid = state.selectedVineyardId ?: return@LaunchedEffect
        if (session.sampleSites.isNotEmpty() || session.selectedPaddockIds.isEmpty()) return@LaunchedEffect
        loadingSources = true
        val verified = mutableMapOf<String, ConfirmedYieldSites>()
        try {
            for (selected in blocks.filter { session.isPaddockSelected(it.id) }) {
                siteRepo.confirmed(vid, selected.id)?.let { verified[selected.id.lowercase()] = it }
            }
            verifiedSources = verified
            savedLocationBlocks = savedLocationBlocks.intersect(verified.keys)
            routeSourceError = null
        } catch (e: Exception) {
            verifiedSources = emptyMap()
            savedLocationBlocks = emptySet()
            routeSourceError = "Could not read confirmed sampling sites: ${e.message}"
        } finally {
            loadingSources = false
        }
    }

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

    // Historical payload weights are preserved, never seeded from device defaults.
    fun defaultWeights(base: Map<String, Double>): Map<String, Double> = base

    fun generateNewRoute() {
        if (preparingRoute || loadingSources) return
        val vid = state.selectedVineyardId ?: return
        val selectedSnapshot = selectedBlocks.toList()
        val chosenSnapshot = savedLocationBlocks
        siteScope.launch {
            preparingRoute = true
            routeSourceError = null
            try {
                // The server is the authority. Refetch every selected saved set
                // before mutating the local session; never substitute silently.
                val saved = mutableMapOf<String, ConfirmedYieldSites>()
                for (block in selectedSnapshot.filter { it.id.lowercase() in chosenSnapshot }) {
                    val check = siteRepo.confirmed(vid, block.id)
                        ?: throw IllegalStateException("Saved sites for ${block.name} are no longer confirmed.")
                    require(check.sites.isNotEmpty() && check.sites.all {
                        RowAttachment.containsPoint(block, it.latitude, it.longitude)
                    }) { "Saved sites for ${block.name} are outside the block. Review and confirm them." }
                    saved[block.id.lowercase()] = check
                }
                require(state.selectedVineyardId == vid &&
                    selectedSnapshot.map { it.id.lowercase() }.toSet() ==
                        session.selectedPaddockIds.map { it.lowercase() }.toSet()) {
                    "Vineyard/block selection changed; please retry."
                }
                val generated = YieldSampleGenerator.generateSampleSites(
                    blocks, session.selectedPaddockIds, session.samplesPerHectare
                )
                val combined = mutableListOf<SampleSite>()
                val versions = mutableMapOf<String, YieldSiteSetSource>()
                var globalIndex = 1
                for (block in selectedSnapshot) {
                    val fromServer = saved[block.id.lowercase()]
                    if (fromServer != null) {
                        for (site in fromServer.sites.sortedBy { it.siteNumber }) {
                            combined += site.toSampleSite(block, globalIndex++)
                        }
                        versions[block.id.lowercase()] = YieldSiteSetSource(
                            setKey = fromServer.set.setKey,
                            siteSetId = fromServer.set.id,
                            version = fromServer.set.version,
                        )
                    } else {
                        for (site in generated.filter { it.paddockId.equals(block.id, true) }
                            .sortedBy { it.siteIndex }) {
                            combined += site.copy(siteIndex = globalIndex++)
                        }
                    }
                }
                check(combined.isNotEmpty() && combined.map { it.id.lowercase() }.toSet().size == combined.size) {
                    "Unable to generate unique sites for this block selection."
                }
                val path = YieldSampleGenerator.generatePath(blocks, session.selectedPaddockIds, combined)
                if (!onApply(session.copy(
                    sampleSites = combined,
                    pathWaypoints = path,
                    blockBunchWeightsKg = defaultWeights(session.blockBunchWeightsKg),
                    routeSourceSessionId = null,
                    siteSetVersions = versions,
                ))) {
                    routeSourceError = "The route could not be saved locally. No sites were advanced."
                }
            } catch (e: Exception) {
                routeSourceError = "Could not prepare sampling route: ${e.message}"
            } finally {
                preparingRoute = false
            }
        }
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
                siteSetVersions = emptyMap(),
            ),
        )
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(if (session.isQuadrantCount) "Quadrant Count" else "Yield Estimate Trip") },
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
                                    onApply(session.copy(sampleSites = emptyList(), pathWaypoints = emptyList(), routeSourceSessionId = null, siteSetVersions = emptyMap()))
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
                                    "${YieldVintageReport.varietyLabel(block)} · ${blockAreaFmt.formatArea(block.areaHectares)} · ${block.authoritativeVineCount} vines",
                                    color = vine.textSecondary,
                                    fontSize = 12.sp,
                                )
                            }
                        }
                    }
                }
            }

            if (selectedBlocks.isNotEmpty()) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Sampling Locations by Block", fontWeight = FontWeight.Bold, color = vine.textPrimary)
                        Text("Choose confirmed saved locations, or generate a new route for each selected block.",
                            color = vine.textSecondary, fontSize = 12.sp)
                        if (loadingSources) LinearProgressIndicator(Modifier.fillMaxWidth())
                        selectedBlocks.forEach { block ->
                            val found = verifiedSources[block.id.lowercase()]
                            if (found == null) {
                                Text("${block.name}: Generate Sampling Locations",
                                    color = vine.textSecondary, fontSize = 12.sp)
                            } else {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Checkbox(
                                        checked = savedLocationBlocks.contains(block.id.lowercase()),
                                        onCheckedChange = { useSaved ->
                                            savedLocationBlocks = if (useSaved) savedLocationBlocks + block.id.lowercase()
                                                else savedLocationBlocks - block.id.lowercase()
                                        },
                                        enabled = !preparingRoute && !loadingSources,
                                    )
                                    Column {
                                        Text(block.name, color = vine.textPrimary)
                                        Text("Use Saved Permanent Locations · v${found.set.version} · ${found.sites.size} sites",
                                            color = vine.textSecondary, fontSize = 12.sp)
                                    }
                                }
                            }
                        }
                        routeSourceError?.let { Text(it, color = VineColors.Destructive, fontSize = 12.sp) }
                    }
                }
            }

            // Steps 3–5 — sample density + route (reuse or generate).
            if (session.totalSiteCount == 0) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        // Number of samples is an integer density per HECTARE.
                        // Do not convert to a decimal display or constrain the
                        // input to a 36dp two-line stepper. Keep one clear field
                        // and obvious +/- controls, matching the iOS editor.
                        var densityText by rememberSaveable(session.id) {
                            mutableStateOf(session.samplesPerHectare.toString())
                        }
                        LaunchedEffect(session.samplesPerHectare) {
                            if (densityText.toIntOrNull() != session.samplesPerHectare) {
                                densityText = session.samplesPerHectare.toString()
                            }
                        }
                        fun setDensity(n: Int) {
                            if (n !in 1..500) return
                            densityText = n.toString()
                            if (n != session.samplesPerHectare) {
                                onApply(session.copy(samplesPerHectare = n))
                                vm.saveYieldSamplingDefault(n)
                            }
                        }
                        Text("Number of samples per hectare", fontWeight = FontWeight.Bold, color = vine.textPrimary, fontSize = 16.sp)
                        Text("Whole-number sample sites/ha · saved as the default for the next trip",
                            color = vine.textSecondary, fontSize = 12.sp)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            IconButton(onClick = { setDensity((densityText.toIntOrNull() ?: session.samplesPerHectare) - 1) },
                                enabled = (densityText.toIntOrNull() ?: session.samplesPerHectare) > 1) {
                                Icon(Icons.Filled.Remove, contentDescription = "Fewer sample sites")
                            }
                            OutlinedTextField(
                                value = densityText,
                                onValueChange = { entered ->
                                    val digits = entered.filter(Char::isDigit).take(3)
                                    densityText = digits
                                    digits.toIntOrNull()?.let(::setDensity)
                                },
                                modifier = Modifier.width(124.dp).testTag("yield.samplesPerHectare.input"),
                                label = { Text("Sites/ha") },
                                singleLine = true,
                                textStyle = androidx.compose.ui.text.TextStyle(
                                    fontWeight = FontWeight.Bold, fontSize = 18.sp, textAlign = TextAlign.Center),
                                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Number),
                                isError = (densityText.toIntOrNull() ?: 0) !in 1..500,
                            )
                            IconButton(onClick = { setDensity((densityText.toIntOrNull() ?: session.samplesPerHectare) + 1) },
                                enabled = (densityText.toIntOrNull() ?: session.samplesPerHectare) < 500) {
                                Icon(Icons.Filled.Add, contentDescription = "More sample sites")
                            }
                        }
                        if ((densityText.toIntOrNull() ?: 0) !in 1..500) {
                            Text("Enter a whole number from 1 to 500 before generating a route.",
                                color = VineColors.Warning, fontSize = 12.sp)
                        }
                        val expected = YieldSampleGenerator.expectedSampleCount(
                            blocks, session.selectedPaddockIds, session.samplesPerHectare,
                        )
                        Text(
                            "${blockAreaFmt.formatArea(YieldSampleGenerator.totalSelectedArea(blocks, session.selectedPaddockIds))} selected · ~$expected sample sites",
                            color = vine.textSecondary,
                            fontSize = 12.sp,
                        )

                        if (reusable != null && savedLocationBlocks.isEmpty()) {
                            Text(
                                "A previous trip already has a route for ${if (selectedBlocks.size == 1) "this block" else "these blocks"}. Reusing it revisits the same sample locations for comparable counts.",
                                color = vine.textSecondary, fontSize = 12.sp,
                            )
                            Button(
                                onClick = { useExistingRoute() },
                                enabled = selectedBlocks.isNotEmpty() && (densityText.toIntOrNull() ?: 0) in 1..500,
                                modifier = Modifier.fillMaxWidth().height(48.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Info),
                            ) {
                                Icon(Icons.Filled.Route, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Use Existing Route (${reusable.sites.size} sites)")
                            }
                            OutlinedButton(
                                onClick = { generateNewRoute() },
                                enabled = selectedBlocks.isNotEmpty() && (densityText.toIntOrNull() ?: 0) in 1..500,
                                modifier = Modifier.fillMaxWidth().height(48.dp),
                            ) {
                                Icon(Icons.Filled.AutoGraph, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Generate New Route")
                            }
                        } else {
                            Button(
                                onClick = { generateNewRoute() },
                                enabled = selectedBlocks.isNotEmpty() && (densityText.toIntOrNull() ?: 0) in 1..500,
                                modifier = Modifier.fillMaxWidth().height(48.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                            ) {
                                Icon(Icons.Filled.AutoGraph, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(if (savedLocationBlocks.isEmpty()) "Generate Route" else "Prepare Route (${savedLocationBlocks.size} saved blocks)")
                            }
                        }
                    }
                }
            }
        }
        }
    }

    selectedSite?.let { site ->
        CountMethodDialog(
            site = site, session = session, state = state,
            onQuadrantSave = { measurement ->
                val saved = state.isSystemAdmin && onApply(session.recordQuadrant(site.id, measurement, state.currentUserId ?: ""))
                if (saved) selectedSite = null
                saved
            },
            onPanelSave = { measurement ->
                val saved = onApply(session.recordPanel(site.id, measurement, state.currentUserId ?: ""))
                if (saved) selectedSite = null
                saved
            },
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
    return copy(selectedPaddockIds = selected, sampleSites = emptyList(), pathWaypoints = emptyList(), routeSourceSessionId = null, siteSetVersions = emptyMap())
}

private fun YieldEstimationSession.withSelection(ids: List<String>): YieldEstimationSession =
    copy(selectedPaddockIds = ids, sampleSites = emptyList(), pathWaypoints = emptyList(), routeSourceSessionId = null, siteSetVersions = emptyMap())

// =============================================================================
// Step 10–13 — Completion: per-block summary, bunch weights, damage, save
// =============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripCompletionScreen(
    vm: AppViewModel,
    state: AppUiState,
    session: YieldEstimationSession,
    onApply: (YieldEstimationSession) -> Boolean,
    onSaved: () -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    var showSaveConfirm by remember { mutableStateOf(false) }

    val selectedBlocks = blocks.filter { session.isPaddockSelected(it.id) }

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
            if (session.isPanelCount) {
                PanelCountSummary(session)
            } else {
                Text("Shared Master Bunch Weights · configure missing weights in the Portal",
                    color = vine.textSecondary, fontSize = 13.sp)
                CurrentTripEstimateSummary(state, session)
            }

            // Damage applies to a calculated estimate, not to raw panel evidence.
            if (!session.isPanelCount) VineyardCard {
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


            Button(
                onClick = { showSaveConfirm = true },
                enabled = session.recordedSiteCount > 0,
                modifier = Modifier.fillMaxWidth().height(52.dp),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.DarkGreen),
            ) {
                Icon(Icons.Filled.DoneAll, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Save Yield Estimate Trip", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }

    if (showSaveConfirm) {
        AlertDialog(
            onDismissRequest = { showSaveConfirm = false },
            title = { Text("Save Yield Estimate Trip?") },
            text = { Text(if (session.isPanelCount)
                "This locks the dated Panel Count observations. They stay separate from the current Yield Estimate until you explicitly select a validated source."
                else "This completes the trip as a dated observation. It becomes the latest estimate for its blocks; earlier trips stay in history. Counts and weights can no longer be edited.") },
            confirmButton = {
                TextButton(onClick = {
                    val completed = session.copy(
                        isCompleted = true,
                        completedAt = session.completedAt ?: Instant.now().toString(),
                        blockVineCounts = selectedBlocks
                            .associate { it.id.lowercase() to it.authoritativeVineCount },
                    )
                    vm.saveYieldSession(completed) { accepted ->
                        if (accepted) {
                            showSaveConfirm = false
                            onSaved()
                        }
                    }
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

    val vintage = YieldVintageReport.sessionVintage(session, state.seasonStartMonth, state.seasonStartDay)

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(session.countMethodName + " · Yield Estimate Trip") },
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
                    "Completed ${com.rork.vinetrack.data.model.parseIsoToEpochMs(session.completedAt ?: session.createdAt)?.let { state.regionFormatter.formatDate(it) } ?: "Not recorded"} · Vintage $vintage",
                    color = vine.textPrimary,
                    fontWeight = FontWeight.Medium,
                )
            }

            if (session.isPanelCount) PanelCountSummary(session)
            else CurrentTripEstimateSummary(state, session)

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
private fun Stepper(value: Int, displayValue: String, onChange: (Int) -> Unit) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { if (value > 1) onChange(value - 1) }) {
            Icon(Icons.Filled.Remove, contentDescription = "Fewer", tint = vine.textPrimary)
        }
        Text(
            displayValue,
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
    val preview = LocalYieldMapPreview.current
    if (preview != null) {
        Box(modifier.fillMaxWidth()) { preview() }
        return
    }
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
                    snippet = site.panelCountEntry?.let { "${it.measurement.totalBunches} bunches in panel" }
                        ?: site.bunchCountEntry?.let { "${formatBunches(it.bunchesPerVine)} bunches/vine" }
                        ?: "Tap to record",
                    icon = yieldSiteIcon(site.siteIndex, site.isRecorded, false),
                    onClick = {
                        onSiteTap(site)
                        true
                    },
                )
            }
        }
    }
}

/** Number and completion mark are map content, not UI controls. Recorded sites stay green even when selected. */
@Composable
private fun yieldSiteIcon(number: Int, recorded: Boolean, selected: Boolean): com.google.android.gms.maps.model.BitmapDescriptor {
    val density = androidx.compose.ui.platform.LocalDensity.current
    val size = with(density) { 46.dp.roundToPx() }
    return remember(number, recorded, selected, size) {
        val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        val s = size.toFloat()
        paint.color = if (selected) android.graphics.Color.rgb(30, 110, 230) else android.graphics.Color.WHITE
        canvas.drawCircle(s / 2, s / 2, s * .48f, paint)
        paint.color = if (recorded) android.graphics.Color.rgb(25, 130, 65) else android.graphics.Color.rgb(180, 95, 0)
        canvas.drawCircle(s / 2, s / 2, s * .40f, paint)
        paint.color = android.graphics.Color.WHITE
        paint.typeface = android.graphics.Typeface.DEFAULT_BOLD
        paint.textSize = s * if (number >= 100) .30f else .38f
        paint.textAlign = android.graphics.Paint.Align.CENTER
        canvas.drawText(number.toString(), s / 2, s * if (recorded) .51f else .64f, paint)
        if (recorded) {
            paint.style = android.graphics.Paint.Style.STROKE; paint.strokeWidth = s * .055f
            canvas.drawPath(android.graphics.Path().apply { moveTo(s * .38f, s * .67f); lineTo(s * .47f, s * .76f); lineTo(s * .64f, s * .59f) }, paint)
        }
        BitmapDescriptorFactory.fromBitmap(bitmap)
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
internal fun YieldSamplingMapScreen(
    state: AppUiState,
    session: YieldEstimationSession,
    onRecord: (siteId: String, bunches: Double, recordedBy: String) -> Boolean,
    onQuadrantRecord: (String, QuadrantCountMeasurement) -> Boolean,
    onPanelRecord: (String, PanelCountMeasurement) -> Boolean,
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
    var selectedSiteId by rememberSaveable(session.id) { mutableStateOf(session.sampleSites.firstOrNull { !it.isRecorded }?.id ?: session.sampleSites.firstOrNull()?.id) }
    var showSites by remember { mutableStateOf(false) }
    var confirmPartial by remember { mutableStateOf(false) }
    var saveError by remember { mutableStateOf<String?>(null) }

    val camera = rememberCameraPositionState()
    var samplingMapLoaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        here = tracker.currentLocation()
    }
    // Frame the sample sites (falling back to the selected blocks' geometry)
    // once the map is laid out.
    val siteCoordinates = session.sampleSites.map { Triple(it.id, it.latitude, it.longitude) }
    LaunchedEffect(samplingMapLoaded, siteCoordinates) {
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
    val nearest = session.sampleSites.firstOrNull { it.id == selectedSiteId }
        ?: YieldSamplingNavigation.ordered(session.sampleSites).firstOrNull()
    // GPS supplies distance guidance only; it never replaces an operator's selected sample.
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
        BoxWithConstraints(modifier = Modifier.fillMaxSize().padding(padding)) {
            // The satellite map must remain dominant, including on smaller
            // devices and with larger accessibility text. A scrollable compact
            // control panel may occupy at most 40% of the available height.
            val guidanceMaxHeight = maxHeight * 0.40f
            Column(modifier = Modifier.fillMaxSize()) {
                Box(modifier = Modifier.fillMaxWidth().weight(1f).testTag("yield.sampling.map")) {
                val preview = LocalYieldMapPreview.current
                if (preview != null) preview() else GoogleMap(
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
                        Marker(
                            state = MarkerState(position = LatLng(site.latitude, site.longitude)),
                            title = "Sample ${site.siteIndex}",
                            snippet = "${site.paddockName} · Row ${site.rowNumber}" + if (site.isRecorded) " · Recorded" else " · Not recorded",
                            icon = yieldSiteIcon(site.siteIndex, site.isRecorded, site.id == nearest?.id),
                            onClick = { selectedSiteId = site.id; true },
                        )
                    }
                }
            }

            // Compact, scrollable field controls free most of the viewport
            // for moving around the rows on the satellite map. All original
            // Prev/Skip/Record/List/Finish actions remain available.
            VineyardCard(
                modifier = Modifier
                    .padding(horizontal = 10.dp, vertical = 6.dp)
                    .heightIn(max = guidanceMaxHeight)
                    .verticalScroll(rememberScrollState())
                    .testTag("yield.sampling.controls"),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.MyLocation, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(
                            when {
                                allRecorded -> "All sample sites recorded"
                                nearest == null -> "No sample sites"
                                nearestDistance == null -> "Next: Sample ${nearest.siteIndex}"
                                else -> "Next: Sample ${nearest.siteIndex} · ${nearestDistance.roundToInt()} m away"
                            },
                            color = vine.textPrimary,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                            maxLines = 2,
                        )
                        IconButton(onClick = { scope.launch { here = tracker.currentLocation() } }) {
                            Icon(Icons.Filled.MyLocation, contentDescription = "Refresh location", tint = vine.textSecondary)
                        }
                    }
                    Text(
                        "Sample ${session.recordedSiteCount} of ${session.totalSiteCount} recorded" +
                            (currentBlockName?.takeIf { it.isNotBlank() }?.let { " · $it" } ?: "") +
                            (nearest?.let { " · Row ${it.rowNumber}" } ?: ""),
                        color = vine.textSecondary,
                        fontSize = 12.sp,
                        maxLines = 2,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        OutlinedButton(
                            onClick = { nearest?.let { selectedSiteId = YieldSamplingNavigation.previous(session.sampleSites, it.id) } },
                            enabled = nearest != null && YieldSamplingNavigation.previous(session.sampleSites, nearest.id) != null,
                            modifier = Modifier.weight(0.8f).heightIn(min = 48.dp),
                            contentPadding = PaddingValues(horizontal = 4.dp),
                        ) { Text("Prev", fontSize = 12.sp, maxLines = 1) }
                        OutlinedButton(
                            onClick = { nearest?.let { selectedSiteId = YieldSamplingNavigation.next(session.sampleSites, it.id) } },
                            enabled = nearest != null,
                            modifier = Modifier.weight(0.8f).heightIn(min = 48.dp),
                            contentPadding = PaddingValues(horizontal = 4.dp),
                        ) { Text("Skip", fontSize = 12.sp, maxLines = 1) }
                        Button(
                            onClick = { nearest?.let { recordingSite = it }; saveError = null },
                            enabled = nearest != null,
                            modifier = Modifier.weight(1.8f).heightIn(min = 48.dp).testTag("yield.record.next"),
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                            contentPadding = PaddingValues(horizontal = 6.dp),
                        ) { Text("Record & Next", fontSize = 12.sp, maxLines = 1) }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        TextButton(onClick = { showSites = true }, modifier = Modifier.weight(1f).heightIn(min = 44.dp)) {
                            Text("Sample list", maxLines = 1)
                        }
                        TextButton(
                            onClick = { if (YieldSamplingNavigation.needsPartialConfirmation(session.sampleSites)) confirmPartial = true else onComplete() },
                            enabled = YieldSamplingNavigation.canFinish(session.sampleSites),
                            modifier = Modifier.weight(1f).heightIn(min = 44.dp),
                        ) { Text("Finish (${session.recordedSiteCount}/${session.totalSiteCount})", maxLines = 1) }
                    }
                    saveError?.let { Text(it, color = VineColors.Destructive) }
                }
            }
        }
    }
}

    if (confirmPartial) AlertDialog(onDismissRequest = { confirmPartial = false }, title = { Text("Finish with incomplete samples?") },
        text = { Text("${session.recordedSiteCount} of ${session.totalSiteCount} recorded. Unrecorded sites remain unrecorded, not zero. Estimates use only real samples and may be less representative.") },
        confirmButton = { TextButton(onClick = { confirmPartial = false; onComplete() }) { Text("Finish Anyway") } },
        dismissButton = { TextButton(onClick = { confirmPartial = false }) { Text("Keep Sampling") } })
    if (showSites) AlertDialog(onDismissRequest = { showSites = false }, title = { Text("Choose sample") },
        text = { androidx.compose.foundation.lazy.LazyColumn {
            items(session.sampleSites.size) { index ->
                val site = YieldSamplingNavigation.ordered(session.sampleSites)[index]
                TextButton(onClick = { selectedSiteId = site.id; showSites = false }) {
                    Text("${site.siteIndex} · ${site.paddockName} · Row ${site.rowNumber} · " + if (site.isRecorded) "Recorded" else "Not recorded")
                }
            }
        } }, confirmButton = { TextButton(onClick = { showSites = false }) { Text("Done") } })
    recordingSite?.let { site ->
        CountMethodDialog(
            site = site, session = session, state = state, saveLabel = "Record & Next",
            onQuadrantSave = { measurement ->
                val saved = state.isSystemAdmin && onQuadrantRecord(site.id, measurement)
                if (saved) { selectedSiteId = YieldSamplingNavigation.next(session.sampleSites, site.id, justRecorded = true); recordingSite = null }
                else saveError = "Could not save this sample. It has not been advanced; retry before leaving."
                saved
            },
            onPanelSave = { measurement ->
                val saved = onPanelRecord(site.id, measurement)
                if (saved) {
                    selectedSiteId = YieldSamplingNavigation.next(session.sampleSites, site.id, justRecorded = true)
                    recordingSite = null
                } else {
                    saveError = "Panel measurement was not saved. Please retry."
                }
                saved
            },
            onDismiss = { recordingSite = null },
            onSave = { bunches ->
                if (onRecord(site.id, bunches, state.currentUserId ?: "")) {
                    selectedSiteId = YieldSamplingNavigation.next(session.sampleSites, site.id, justRecorded = true)
                    recordingSite = null
                } else saveError = "Could not save this sample. It has not been advanced; retry before leaving."
            },
        )
    }
}

@Composable
private fun BunchCountDialog(
    site: SampleSite,
    saveLabel: String = "Record",
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
                modifier = Modifier.testTag("yield.record.confirm"),
                enabled = value != null && value.isFinite() && value >= 0,
                onClick = { value?.let(onSave) },
            ) { Text(saveLabel) }
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
private fun formatGrams(kg: Double): String = (kg * 1000).roundToInt().toString()
private fun formatBunches(b: Double): String = String.format("%.1f", b)
private fun trimNumber(d: Double): String = if (d == d.toLong().toDouble()) d.toLong().toString() else d.toString()

private fun YieldEstimationSession.recordQuadrant(siteId: String, measurement: QuadrantCountMeasurement, recordedBy: String): YieldEstimationSession {
    if (!isQuadrantCount || isCompleted) return this
    return copy(quadrantSectionLengthCm = measurement.sectionLengthCm, sampleSites = sampleSites.map { site ->
        if (site.id == siteId) site.copy(bunchCountEntry = BunchCountEntry(measurement.bunchesPerVine,
            Instant.now().toString(), recordedBy, quadrant = measurement)) else site
    })
}

@Composable
private fun CountMethodDialog(
    site: SampleSite,
    saveLabel: String = "Record",
    session: YieldEstimationSession,
    state: AppUiState,
    onDismiss: () -> Unit,
    onSave: (Double) -> Unit,
    onQuadrantSave: (QuadrantCountMeasurement) -> Boolean,
    onPanelSave: (PanelCountMeasurement) -> Boolean,
) {
    if (session.isPanelCount) {
        PanelCountDialog(site = site, saveLabel = saveLabel, onDismiss = onDismiss, onSave = onPanelSave)
        return
    }
    if (!session.isQuadrantCount) {
        BunchCountDialog(site = site, saveLabel = saveLabel, onDismiss = onDismiss, onSave = onSave)
        return
    }
    if (!state.isSystemAdmin) return
    val original = site.bunchCountEntry?.quadrant
    val block = state.paddocks.firstOrNull { it.id.equals(site.paddockId, true) }
    val spacing = original?.vineSpacingCm ?: block?.vineSpacing?.times(100)
    var count by rememberSaveable(site.id) { mutableStateOf(original?.rawBunchCount?.let(::trimNumber) ?: "") }
    var length by rememberSaveable(site.id) { mutableStateOf(trimNumber(original?.sectionLengthCm ?: session.quadrantSectionLengthCm ?: 60.0)) }
    val parsedCount = count.replace(',', '.').toDoubleOrNull()
    val parsedLength = length.replace(',', '.').toDoubleOrNull()
    val measurement = if (parsedCount != null && parsedLength != null)
        QuadrantCountMeasurement.make(parsedCount, parsedLength, spacing, state.isSystemAdmin) else null
    AlertDialog(onDismissRequest = onDismiss,
        title = { Text("Quadrant Count - Sample ${site.siteIndex}") },
        text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("${site.paddockName} - Row ${site.rowNumber}", fontSize = 13.sp)
            OutlinedTextField(value = length, onValueChange = { length = it }, label = { Text("Count section (cm)") },
                singleLine = true, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal))
            Text(spacing?.let { "Vine spacing: ${trimNumber(it)} cm" } ?: "Set vine spacing in Blocks before counting.", fontSize = 13.sp)
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { count = trimNumber(kotlin.math.max(0.0, (parsedCount ?: 0.0) - 1)) }) { Text("-") }
                OutlinedTextField(value = count, onValueChange = { count = it }, label = { Text("Bunches in section") },
                    singleLine = true, modifier = Modifier.weight(1f),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Number))
                TextButton(onClick = { count = trimNumber((parsedCount ?: 0.0) + 1) }) { Text("+") }
            }
            measurement?.let { Text("Estimated: ${formatBunches(it.bunchesPerVine)} bunches/vine", fontSize = 13.sp) }
        } },
        confirmButton = { TextButton(modifier = Modifier.testTag("yield.record.confirm"), enabled = measurement != null, onClick = { measurement?.let { onQuadrantSave(it) } }) { Text(saveLabel) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
}
