package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Scale
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.YieldSampleGenerator
import com.rork.vinetrack.data.model.BunchCountEntry
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Yield Estimation working-session flow (Android Stage Q), porting the iOS
 * `YieldEstimationView` + `YieldSamplingNavigationView`. Operators pick blocks,
 * generate row-clipped sample sites at a chosen density, record bunch counts per
 * site (on the map or via the GPS-guided sampling screen), set per-block bunch
 * weights, then lock the estimation and view the per-block yield report.
 *
 * The single working session per vineyard is persisted/synced through the view
 * model ([AppViewModel.saveYieldSession] / [AppViewModel.deleteYieldSession]).
 */
@Composable
fun YieldEstimationScreen(
    vm: AppViewModel,
    state: AppUiState,
    onBack: () -> Unit,
) {
    val vineyardId = state.selectedVineyardId
    val freshId = rememberSaveable { UUID.randomUUID().toString() }
    val freshCreatedAt = rememberSaveable { Instant.now().toString() }

    // Server/cached session for this vineyard (source of truth once synced).
    val existing = state.yieldSessions.firstOrNull { it.vineyardId.equals(vineyardId, ignoreCase = true) }
    // Local in-progress draft; falls back to the synced session, then a fresh one.
    var draft by remember { mutableStateOf<YieldEstimationSession?>(null) }
    val session = draft ?: existing ?: YieldEstimationSession(
        id = freshId,
        vineyardId = vineyardId ?: "",
        createdAt = freshCreatedAt,
    )

    fun apply(updated: YieldEstimationSession) {
        draft = updated
        vm.saveYieldSession(updated)
    }

    var showSampling by rememberSaveable { mutableStateOf(false) }

    AnimatedContent(
        targetState = showSampling,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "yield-estimation-nav",
    ) { sampling ->
        if (sampling) {
            YieldSamplingMapScreen(
                state = state,
                session = session,
                onRecord = { siteId, bunches, recordedBy ->
                    apply(session.recordBunch(siteId, bunches, recordedBy))
                },
                onBack = { showSampling = false },
            )
        } else {
            YieldEstimationAuthoring(
                vm = vm,
                state = state,
                session = session,
                onApply = { apply(it) },
                onStartSampling = { showSampling = true },
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun YieldEstimationAuthoring(
    vm: AppViewModel,
    state: AppUiState,
    session: YieldEstimationSession,
    onApply: (YieldEstimationSession) -> Unit,
    onStartSampling: () -> Unit,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val bunchWeightStore = remember { com.rork.vinetrack.data.BunchWeightDefaultsStore(context) }
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }

    var selectedSite by remember { mutableStateOf<SampleSite?>(null) }
    var editingWeightFor by remember { mutableStateOf<Paddock?>(null) }
    var showDeleteConfirm by remember { mutableStateOf(false) }
    var showCompleteConfirm by remember { mutableStateOf(false) }

    val locked = session.isCompleted
    val selectedBlocks = blocks.filter { session.isPaddockSelected(it.id) }
    val estimates = remember(session, blocks) {
        YieldSampleGenerator.calculateYieldEstimates(session, blocks)
    }
    val totalTonnes = estimates.sumOf { it.estimatedYieldTonnes }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Yield Estimation") },
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

            if (locked) {
                CompletedBanner(session)
            }

            // Summary header.
            VineyardCard {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    EstimationStat(
                        "Blocks",
                        selectedBlocks.size.toString(),
                        VineColors.Indigo,
                        Modifier.weight(1f),
                    )
                    EstimationStat(
                        "Sites",
                        "${session.recordedSiteCount}/${session.totalSiteCount}",
                        VineColors.Purple,
                        Modifier.weight(1f),
                    )
                    EstimationStat(
                        "Est. tonnes",
                        formatTonnes(totalTonnes),
                        VineColors.LeafGreen,
                        Modifier.weight(1f),
                    )
                }
            }

            if (blocks.isEmpty()) {
                VineyardCard {
                    Text(
                        "Map at least one block boundary in Blocks to generate sample sites.",
                        color = vine.textSecondary,
                        fontSize = 13.sp,
                    )
                }
                return@Column
            }

            // Progress.
            if (session.totalSiteCount > 0) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Sampling progress", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        LinearProgressIndicator(
                            progress = {
                                if (session.totalSiteCount == 0) 0f
                                else session.recordedSiteCount.toFloat() / session.totalSiteCount
                            },
                            modifier = Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)),
                            color = VineColors.LeafGreen,
                            trackColor = vine.cardBackground,
                        )
                        Text(
                            "${session.recordedSiteCount} of ${session.totalSiteCount} sites recorded",
                            color = vine.textSecondary,
                            fontSize = 12.sp,
                        )
                    }
                }
            }

            // Map preview with sites + path.
            if (session.totalSiteCount > 0) {
                SamplePreviewMap(
                    blocks = selectedBlocks,
                    session = session,
                    onSiteTap = { if (!locked) selectedSite = it },
                )
                if (!locked) {
                    Button(
                        onClick = onStartSampling,
                        modifier = Modifier.fillMaxWidth().height(50.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Info),
                    ) {
                        Icon(Icons.Filled.Explore, contentDescription = null, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(if (session.recordedSiteCount > 0) "Continue Sampling" else "Start Sampling")
                    }
                }
            }

            if (!locked) {
                // Block selection.
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
                                        "${formatArea(block.areaHectares)} ha · ${block.rowCount} rows · ${block.effectiveVineCount} vines",
                                        color = vine.textSecondary,
                                        fontSize = 12.sp,
                                    )
                                }
                            }
                        }
                    }
                }

                // Samples per hectare + generate.
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Samples per hectare", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                                Text("Used to space sample sites along the rows", color = vine.textSecondary, fontSize = 12.sp)
                            }
                            Stepper(
                                value = session.samplesPerHectare,
                                onChange = { onApply(session.copy(samplesPerHectare = it)) },
                            )
                        }
                        val expected = YieldSampleGenerator.expectedSampleCount(
                            blocks, session.selectedPaddockIds, session.samplesPerHectare,
                        )
                        Text(
                            "${formatArea(YieldSampleGenerator.totalSelectedArea(blocks, session.selectedPaddockIds))} ha selected · ~$expected sites",
                            color = vine.textSecondary,
                            fontSize = 12.sp,
                        )
                        Button(
                            onClick = {
                                val sites = YieldSampleGenerator.generateSampleSites(
                                    blocks, session.selectedPaddockIds, session.samplesPerHectare,
                                )
                                val path = YieldSampleGenerator.generatePath(blocks, session.selectedPaddockIds, sites)
                                val weights = session.blockBunchWeightsKg.toMutableMap()
                                selectedBlocks.forEach { b ->
                                    weights.putIfAbsent(b.id, bunchWeightStore.weightGrams(b.id) / 1000.0)
                                }
                                onApply(
                                    session.copy(
                                        sampleSites = sites,
                                        pathWaypoints = path,
                                        blockBunchWeightsKg = weights,
                                    ),
                                )
                            },
                            enabled = selectedBlocks.isNotEmpty(),
                            modifier = Modifier.fillMaxWidth().height(48.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                        ) {
                            Icon(Icons.Filled.AutoGraph, contentDescription = null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(if (session.totalSiteCount > 0) "Regenerate Sample Sites" else "Generate Sample Sites")
                        }
                    }
                }

                // Per-block bunch weight.
                if (session.totalSiteCount > 0) {
                    VineyardCard {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("Average bunch weight", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            selectedBlocks.forEach { block ->
                                Row(
                                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                                        .clickable { editingWeightFor = block }.padding(vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(Icons.Filled.Scale, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(8.dp))
                                    Text(block.name, color = vine.textPrimary, modifier = Modifier.weight(1f))
                                    Text(
                                        "${formatGrams(session.bunchWeightKg(block.id))} g",
                                        color = vine.textSecondary,
                                        fontWeight = FontWeight.Medium,
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Report.
            if (estimates.any { it.samplesRecorded > 0 }) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("Estimate report", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        estimates.forEach { e ->
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Row {
                                    Text(e.paddockName, color = vine.textPrimary, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                                    Text("${formatTonnes(e.estimatedYieldTonnes)} t", color = VineColors.LeafGreen, fontWeight = FontWeight.SemiBold)
                                }
                                Text(
                                    "${e.samplesRecorded}/${e.samplesTotal} sites · ${formatBunches(e.averageBunchesPerVine)} bunches/vine · ${e.totalVines} vines",
                                    color = vine.textSecondary,
                                    fontSize = 12.sp,
                                )
                            }
                        }
                    }
                }
            }

            // Complete / delete actions.
            if (!locked && session.recordedSiteCount > 0) {
                Button(
                    onClick = { showCompleteConfirm = true },
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.DarkGreen),
                ) {
                    Icon(Icons.Filled.DoneAll, contentDescription = null, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Complete Estimation")
                }
            }

            if (locked) {
                OutlinedButton(
                    onClick = {
                        // Start a fresh estimation: delete the locked one.
                        vm.deleteYieldSession(session.id)
                        onBack()
                    },
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                ) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Start New Estimation")
                }
            }

            if (session.totalSiteCount > 0 || existingHasData(session)) {
                TextButton(
                    onClick = { showDeleteConfirm = true },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Delete Estimation", color = VineColors.Destructive)
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

    if (showCompleteConfirm) {
        AlertDialog(
            onDismissRequest = { showCompleteConfirm = false },
            title = { Text("Complete Estimation?") },
            text = { Text("This locks all values for this yield estimation job. Bunch counts and weights can no longer be edited.") },
            confirmButton = {
                TextButton(onClick = {
                    onApply(session.copy(isCompleted = true, completedAt = Instant.now().toString()))
                    showCompleteConfirm = false
                }) { Text("Complete") }
            },
            dismissButton = { TextButton(onClick = { showCompleteConfirm = false }) { Text("Cancel") } },
        )
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("Delete Estimation?") },
            text = { Text("Delete this yield estimation? This will remove sample sites and bunch counts for this job. This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteYieldSession(session.id)
                    showDeleteConfirm = false
                    onBack()
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel") } },
        )
    }
}

private fun existingHasData(session: YieldEstimationSession): Boolean =
    session.selectedPaddockIds.isNotEmpty() || session.totalSiteCount > 0

private fun YieldEstimationSession.toggleBlock(blockId: String): YieldEstimationSession {
    val selected = selectedPaddockIds.toMutableList()
    val idx = selected.indexOfFirst { it.equals(blockId, ignoreCase = true) }
    if (idx >= 0) selected.removeAt(idx) else selected.add(blockId)
    // Changing the block set invalidates generated sites/path.
    return copy(selectedPaddockIds = selected, sampleSites = emptyList(), pathWaypoints = emptyList())
}

private fun YieldEstimationSession.withSelection(ids: List<String>): YieldEstimationSession =
    copy(selectedPaddockIds = ids, sampleSites = emptyList(), pathWaypoints = emptyList())

@Composable
private fun CompletedBanner(session: YieldEstimationSession) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(VineColors.DarkGreen.copy(alpha = 0.12f)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null, tint = VineColors.DarkGreen, modifier = Modifier.size(20.dp))
        Text(
            "Estimation completed and locked.",
            color = vine.textPrimary,
            fontWeight = FontWeight.Medium,
        )
    }
}

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
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
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
) {
    val camera = rememberCameraPositionState()
    val allPoints = remember(blocks, session.sampleSites) {
        blocks.flatMap { it.polygonPoints ?: emptyList() }.map { LatLng(it.latitude, it.longitude) } +
            session.sampleSites.map { LatLng(it.latitude, it.longitude) }
    }
    var mapLoaded by remember { mutableStateOf(false) }
    // Frame only after the map has a measured size; re-frame when content changes.
    androidx.compose.runtime.LaunchedEffect(mapLoaded, allPoints) {
        if (!mapLoaded) return@LaunchedEffect
        camera.fitToContent(points = allPoints, paddingPx = 120)
    }
    Box(modifier = Modifier.fillMaxWidth().height(300.dp).clip(RoundedCornerShape(14.dp))) {
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
                    title = "Site ${site.siteIndex}",
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
 * Full-screen GPS-guided sampling map (ports `YieldSamplingNavigationView`).
 * Shows the operator's live position, highlights the nearest unrecorded site
 * with a live distance read-out, and records bunch counts site-by-site.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun YieldSamplingMapScreen(
    state: AppUiState,
    session: YieldEstimationSession,
    onRecord: (siteId: String, bunches: Double, recordedBy: String) -> Unit,
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
    androidx.compose.runtime.LaunchedEffect(Unit) {
        here = tracker.currentLocation()
    }
    // Frame the sample sites (falling back to the selected blocks' geometry)
    // once the map is laid out.
    androidx.compose.runtime.LaunchedEffect(samplingMapLoaded, session.sampleSites) {
        if (!samplingMapLoaded) return@LaunchedEffect
        val pts = session.sampleSites.map { LatLng(it.latitude, it.longitude) }.ifEmpty {
            blocks.filter { session.isPaddockSelected(it.id) }
                .flatMap { it.polygonPoints ?: emptyList() }
                .map { LatLng(it.latitude, it.longitude) }
        }
        camera.fitToContent(points = pts, paddingPx = 120)
    }

    val unrecorded = session.sampleSites.filter { !it.isRecorded }
    val nearest = remember(here, session.sampleSites) {
        val h = here ?: return@remember null
        unrecorded.minByOrNull { metresBetween(h.latitude, h.longitude, it.latitude, it.longitude) }
    }
    val nearestDistance = nearest?.let { n ->
        here?.let { h -> metresBetween(h.latitude, h.longitude, n.latitude, n.longitude) }
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Sampling") },
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
                            title = "Site ${site.siteIndex}",
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
                                nearest == null -> "All sites recorded"
                                nearestDistance == null -> "Locating you…"
                                else -> "Next: Site ${nearest.siteIndex} · ${nearestDistance.roundToInt()} m away"
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
                        "${session.recordedSiteCount} of ${session.totalSiteCount} sites recorded",
                        color = vine.textSecondary,
                        fontSize = 12.sp,
                    )
                    Button(
                        onClick = { nearest?.let { recordingSite = it } },
                        enabled = nearest != null,
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                    ) {
                        Icon(Icons.Filled.CheckCircle, contentDescription = null, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(if (nearest != null) "Record Site ${nearest.siteIndex}" else "Done")
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
        title = { Text("Site ${site.siteIndex} · Row ${site.rowNumber}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Average bunches per vine at this site", fontSize = 13.sp)
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
